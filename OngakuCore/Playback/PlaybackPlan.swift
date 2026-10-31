//
//  PlaybackPlan.swift
//  OngakuCore
//

import Foundation

/// Works out what the engine has to schedule for one run of the transport.
///
/// "Playback time" is seconds since the transport started. It keeps increasing while the
/// timeline position jumps back at each cycle repeat, so the plan is a list of *passes*: the
/// first runs from the start position to the cycle end (or the project end), and each later
/// pass replays the cycle.
///
/// The plan is pure value logic with no audio dependencies, so it is fully unit-testable and
/// the engine only has to execute it.
public struct PlaybackPlan: Sendable {
  public struct AudioSegment: Equatable, Sendable {
    public var trackID: Track.ID
    public var regionID: Region.ID
    public var fileID: AudioFileReference.ID
    public var fileStartFrame: Int64
    public var frameCount: Int64
    /// When the segment starts, in seconds of playback time.
    public var playbackTime: Double
    /// The region's gain (and fades) across the segment.
    public var envelope = AudioEnvelope()
  }

  public struct Click: Equatable, Sendable {
    public var playbackTime: Double
    /// The first beat of a bar, which the metronome accents.
    public var isDownbeat: Bool
  }

  private struct Pass {
    var start: Tick
    var end: Tick
    /// Playback time at which this pass starts.
    var playbackOffset: Double
  }

  public let project: Project
  public let startPosition: Tick
  private let firstPass: Pass
  /// The repeating cycle range, if playback loops.
  private let cycle: (start: Tick, end: Tick, duration: Double)?
  /// Each instrument track's notes sorted by start, and each audio track's regions, so a
  /// window only looks at what's near it instead of the whole song.
  private let noteIndex: [TrackNotes]
  private let audioIndex: [(track: Track, regions: [Region])]

  /// A note on the timeline, with its region's bounds.
  /// The track's notes through its MIDI effects. Each note keeps the bounds of the region it
  /// came from (an arpeggio from a chord stops where the chord's region does).
  private static func applyingMIDIEffects(_ effects: [MIDIEffect], to notes: [IndexedNote]) -> [IndexedNote] {
    guard effects.contains(where: { !$0.isBypassed }), !notes.isEmpty else { return notes }
    // The regions' bounds, once each (there are far fewer regions than notes).
    var seen = Set<Tick>()
    let regions = notes.compactMap { seen.insert($0.regionStart).inserted ? ($0.regionStart, $0.regionEnd) : nil }
    let input = notes.map { EffectNote(start: $0.start, end: $0.end, pitch: $0.pitch, velocity: $0.velocity, channel: $0.channel) }
    return effects.process(input).compactMap { note in
      // Effects can move notes (echoes, arpeggio steps) out of their region: they belong to
      // the region they now start in, and are left out between regions.
      guard let bounds = regions.first(where: { note.start >= $0.0 && note.start < $0.1 }) else { return nil }
      return IndexedNote(
        start: note.start, end: min(note.end, bounds.1), regionStart: bounds.0, regionEnd: bounds.1,
        channel: note.channel, pitch: note.pitch, velocity: note.velocity)
    }
  }

  private struct IndexedNote: Sendable {
    var start: Tick
    var end: Tick
    var regionStart: Tick
    var regionEnd: Tick
    var channel: Int
    var pitch: Int
    var velocity: Int
  }

  /// A controller, pitch bend or aftertouch event on the timeline.
  private struct IndexedControl: Sendable {
    var position: Tick
    var lane: ControlLane
    var value: Int
  }

  /// One controller (or pitch bend, or aftertouch) on one channel.
  private struct ControlLane: Hashable, Sendable {
    var kind: MIDIControlEvent.Kind
    var channel: Int
  }

  private struct TrackNotes: Sendable {
    var trackID: Track.ID
    var notes: [IndexedNote]
    /// The longest note, so a window knows how far back a note-off can come from.
    var longest: Tick
    /// Sorted by position.
    var controls: [IndexedControl]
    /// Every controller the track uses, which playback sets to its value at the start of
    /// each pass (see `midiEvents(in:)`).
    var lanes: [ControlLane]
  }

  public init(project: Project, startPosition: Tick) {
    self.project = project
    self.startPosition = startPosition
    let tempoMap = project.tempoMap

    // Like Logic, the cycle only loops if playback starts before the cycle end.
    if project.cycle.isEnabled, project.cycle.length > .zero, startPosition < project.cycle.end {
      firstPass = Pass(start: startPosition, end: project.cycle.end, playbackOffset: 0)
      let duration = tempoMap.seconds(at: project.cycle.end) - tempoMap.seconds(at: project.cycle.start)
      cycle = (project.cycle.start, project.cycle.end, duration)
    } else {
      firstPass = Pass(start: startPosition, end: max(startPosition, project.endPosition), playbackOffset: 0)
      cycle = nil
    }

    var noteIndex: [TrackNotes] = []
    var audioIndex: [(track: Track, regions: [Region])] = []
    for track in project.tracks {
      switch track.kind {
      case .softwareInstrument:
        var notes: [IndexedNote] = []
        var longest = Tick.zero
        var controls: [IndexedControl] = []
        for region in project.playedRegions(of: track) where !region.isMuted {
          guard case .midi(let sequence) = region.content else { continue }
          for event in sequence.controls where event.position >= .zero && event.position < region.length {
            controls.append(IndexedControl(
              position: region.start + event.position, lane: ControlLane(kind: event.kind, channel: event.channel),
              value: event.value))
          }
          for note in region.playedNotes {
            let start = region.start + note.start
            // Notes outside their region never play.
            guard start >= region.start, start < region.end else { continue }
            notes.append(IndexedNote(
              start: start, end: region.start + note.end, regionStart: region.start, regionEnd: region.end,
              channel: note.channel, pitch: note.pitch, velocity: note.velocity))
            longest = max(longest, note.length)
          }
        }
        notes = Self.applyingMIDIEffects(track.channel.midiEffects, to: notes)
        longest = max(longest, notes.map { $0.end - $0.start }.max() ?? .zero)
        notes.sort { $0.start < $1.start }
        controls.sort { $0.position < $1.position }
        var lanes: [ControlLane] = []
        for control in controls where !lanes.contains(control.lane) {
          lanes.append(control.lane)
        }
        noteIndex.append(TrackNotes(trackID: track.id, notes: notes, longest: longest, controls: controls, lanes: lanes))
      case .audio:
        audioIndex.append((track, project.playedRegions(of: track).filter { !$0.isMuted }))
      case .aux:
        break
      }
    }
    self.noteIndex = noteIndex
    self.audioIndex = audioIndex
  }

  /// The timeline ticks a window of playback time covers within a pass, widened by a tick
  /// on each side so rounding can't drop an event; callers still check exact times.
  private func tickRange(of window: Range<Double>, in pass: Pass) -> Range<Tick> {
    let tempoMap = project.tempoMap
    let passStartSeconds = tempoMap.seconds(at: pass.start)
    let from = tempoMap.tickPosition(atSeconds: passStartSeconds + window.lowerBound - pass.playbackOffset) - Tick(1)
    let to = tempoMap.tickPosition(atSeconds: passStartSeconds + window.upperBound - pass.playbackOffset) + Tick(1)
    return from..<max(from, to)
  }

  /// The first index whose element is not before `tick`, by binary search.
  private static func firstIndex<Element>(in elements: [Element], notBefore tick: Tick, key: (Element) -> Tick) -> Int {
    var low = 0
    var high = elements.count
    while low < high {
      let middle = (low + high) / 2
      if key(elements[middle]) < tick {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return low
  }

  private var firstPassDuration: Double {
    project.tempoMap.seconds(at: firstPass.end) - project.tempoMap.seconds(at: firstPass.start)
  }

  /// How long playback lasts before it stops at the project end, or `nil` when cycling.
  public var duration: Double? {
    cycle == nil ? firstPassDuration : nil
  }

  /// The cycle range when playback loops.
  public var cycleRange: Range<Tick>? {
    cycle.map { $0.start..<$0.end }
  }

  /// Which pass a playback time falls in: 0 is the first (from the start position), then one
  /// per repeat of the cycle.
  public func passIndex(atPlaybackTime time: Double) -> Int {
    let firstDuration = firstPassDuration
    guard let cycle, time >= firstDuration, cycle.duration > 0 else { return 0 }
    return 1 + Int(((time - firstDuration) / cycle.duration).rounded(.down))
  }

  /// When a pass reaches the cycle start, in playback time. The first pass may begin inside
  /// the cycle (or before it), so its cycle start can be before playback began.
  public func cycleStartTime(ofPass index: Int) -> Double? {
    guard let cycle else { return nil }
    if index == 0 {
      let tempoMap = project.tempoMap
      return tempoMap.seconds(at: cycle.start) - tempoMap.seconds(at: firstPass.start)
    }
    return firstPassDuration + Double(index - 1) * cycle.duration
  }

  /// The timeline position heard at a playback time.
  public func timelinePosition(atPlaybackTime time: Double) -> Tick {
    let tempoMap = project.tempoMap
    let firstDuration = firstPassDuration
    guard let cycle, time >= firstDuration, cycle.duration > 0 else {
      return tempoMap.tickPosition(atSeconds: tempoMap.seconds(at: firstPass.start) + time)
    }
    let timeIntoCycles = time - firstDuration
    let timeIntoPass = timeIntoCycles - (timeIntoCycles / cycle.duration).rounded(.down) * cycle.duration
    return tempoMap.tickPosition(atSeconds: tempoMap.seconds(at: cycle.start) + timeIntoPass)
  }

  /// The passes that overlap a window of playback time.
  private func passes(overlapping window: Range<Double>) -> [Pass] {
    var result: [Pass] = []
    let firstDuration = firstPassDuration
    if window.lowerBound < firstDuration || cycle == nil {
      result.append(firstPass)
    }
    guard let cycle, cycle.duration > 0, window.upperBound > firstDuration else { return result }

    let firstIndex = max(0, Int(((window.lowerBound - firstDuration) / cycle.duration).rounded(.down)))
    let lastIndex = Int(((window.upperBound - firstDuration) / cycle.duration).rounded(.down))
    for index in firstIndex...lastIndex {
      let offset = firstDuration + Double(index) * cycle.duration
      result.append(Pass(start: cycle.start, end: cycle.end, playbackOffset: offset))
    }
    return result
  }

  private func playbackTime(of position: Tick, in pass: Pass) -> Double {
    pass.playbackOffset + project.tempoMap.seconds(at: position) - project.tempoMap.seconds(at: pass.start)
  }

  // MARK: - Audio

  /// Audio segments that *start* inside a window of playback time.
  ///
  /// The engine calls this for consecutive windows as playback advances. Each segment is
  /// reported exactly once (in the window containing its start) and plays to its end, so
  /// segments are never split at window boundaries and can't click there.
  public func audioSegments(startingIn window: Range<Double>) -> [AudioSegment] {
    var segments: [AudioSegment] = []
    for pass in passes(overlapping: window) {
      let ticks = tickRange(of: window, in: pass)
      for (track, regions) in audioIndex {
        // A segment starts where its region does, or where the pass does for a region
        // already playing then.
        var candidates = regions[Self.firstIndex(in: regions, notBefore: ticks.lowerBound, key: \.start)...]
          .prefix { $0.start < ticks.upperBound }
          .map { $0 }
        if ticks.contains(pass.start) {
          candidates += regions.filter { $0.start < pass.start && $0.end > pass.start }
        }
        for region in candidates {
          guard case .audio(let content) = region.content,
            let file = project.audioFile(withID: content.fileID),
            let segment = segment(for: region, content: content, file: file, track: track, in: pass),
            window.contains(segment.playbackTime)
          else { continue }
          segments.append(segment)
        }
      }
    }
    return segments.sorted { $0.playbackTime < $1.playbackTime }
  }

  private func segment(
    for region: Region, content: AudioRegionContent, file: AudioFileReference, track: Track, in pass: Pass
  ) -> AudioSegment? {
    let start = max(region.start, pass.start)
    let end = min(region.end, pass.end)
    guard start < end else { return nil }

    let tempoMap = project.tempoMap
    func frames(_ from: Tick, _ to: Tick) -> Int64 {
      Int64(((tempoMap.seconds(at: to) - tempoMap.seconds(at: from)) * file.sampleRate).rounded())
    }
    let fileStartFrame = content.fileStartFrame + frames(region.start, start)
    let frameCount = min(frames(start, end), file.frameCount - fileStartFrame)
    guard fileStartFrame >= 0, frameCount > 0 else { return nil }

    guard case .audio(let audio) = region.content else { return nil }
    let regionStartSeconds = tempoMap.seconds(at: region.start)
    let envelope = AudioEnvelope(
      gain: audio.gain <= ChannelStrip.volumeRange.lowerBound ? 0 : pow(10, audio.gain / 20),
      offset: tempoMap.seconds(at: start) - regionStartSeconds,
      regionDuration: tempoMap.seconds(at: region.end) - regionStartSeconds,
      fadeIn: audio.fadeIn, fadeOut: audio.fadeOut)
    return AudioSegment(
      trackID: track.id, regionID: region.id, fileID: file.id,
      fileStartFrame: fileStartFrame, frameCount: frameCount,
      playbackTime: playbackTime(of: start, in: pass), envelope: envelope)
  }

  // MARK: - MIDI

  /// A note-on, note-off or controller (including pitch bend and aftertouch) for an
  /// instrument track.
  public struct MIDIEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
      case noteOn(velocity: Int)
      case noteOff
      case control(MIDIControlEvent.Kind, value: Int)

      /// The order of events at the same time: note-offs, then controllers, then note-ons.
      var rank: Int {
        switch self {
        case .noteOff: 0
        case .control: 1
        case .noteOn: 2
        }
      }
    }

    public var trackID: Track.ID
    public var playbackTime: Double
    public var channel: Int
    public var pitch: Int
    public var kind: Kind

    /// The MIDI 1.0 message bytes.
    public var bytes: [UInt8] {
      let channelNibble = UInt8(clamping: channel & 0x0F)
      switch kind {
      case .noteOn(let velocity):
        return [0x90 | channelNibble, UInt8(clamping: pitch), UInt8(clamping: velocity)]
      case .noteOff:
        return [0x80 | channelNibble, UInt8(clamping: pitch), 0]
      case .control(let control, let value):
        return MIDIControlEvent(kind: control, channel: channel, position: .zero, value: value).bytes
      }
    }
  }

  /// Notes and controllers inside a window of playback time, in time order.
  ///
  /// Notes only play from their start (notes already sounding at the start position aren't
  /// chased). A note is cut off at the end of its region and at the end of a cycle pass, so
  /// nothing hangs when playback jumps back to the cycle start. At equal times note-offs come
  /// first, so a note repeated at the same pitch retriggers cleanly, then controllers, so a
  /// note starts with the volume or bend set at the same moment.
  ///
  /// Controllers *are* chased: at the start of each pass, every controller a track uses is
  /// set to its value at that point (or its neutral value if nothing came before), so
  /// starting mid-song or jumping back to the cycle start sounds as it would playing through.
  public func midiEvents(in window: Range<Double>) -> [MIDIEvent] {
    var events: [MIDIEvent] = []
    for pass in passes(overlapping: window) {
      let ticks = tickRange(of: window, in: pass)
      let passStartsInWindow = window.contains(pass.playbackOffset)
      for track in noteIndex {
        if passStartsInWindow {
          events += chasedControls(of: track, at: pass.start).map { lane, value in
            MIDIEvent(
              trackID: track.trackID, playbackTime: pass.playbackOffset, channel: lane.channel, pitch: 0,
              kind: .control(lane.kind, value: value))
          }
        }
        let controls = track.controls
        var controlIndex = Self.firstIndex(in: controls, notBefore: max(ticks.lowerBound, pass.start), key: \.position)
        while controlIndex < controls.count, controls[controlIndex].position < min(ticks.upperBound, pass.end) {
          let control = controls[controlIndex]
          controlIndex += 1
          // An event right at the pass start was already sent as its chased value.
          guard control.position > pass.start || !passStartsInWindow else { continue }
          let time = playbackTime(of: control.position, in: pass)
          if window.contains(time) {
            events.append(MIDIEvent(
              trackID: track.trackID, playbackTime: time, channel: control.lane.channel, pitch: 0,
              kind: .control(control.lane.kind, value: control.value)))
          }
        }

        // Note-ons start inside the window; a note-off can belong to a note that started up
        // to the longest note's length earlier.
        let notes = track.notes
        var index = Self.firstIndex(in: notes, notBefore: ticks.lowerBound - track.longest, key: \.start)
        while index < notes.count, notes[index].start < ticks.upperBound {
          let note = notes[index]
          index += 1
          let playableStart = max(note.regionStart, pass.start)
          let playableEnd = min(note.regionEnd, pass.end)
          guard note.start >= playableStart, note.start < playableEnd else { continue }
          let end = min(note.end, playableEnd)

          let onTime = playbackTime(of: note.start, in: pass)
          if window.contains(onTime) {
            events.append(MIDIEvent(
              trackID: track.trackID, playbackTime: onTime, channel: note.channel, pitch: note.pitch,
              kind: .noteOn(velocity: note.velocity)))
          }
          let offTime = playbackTime(of: end, in: pass)
          if window.contains(offTime) {
            events.append(MIDIEvent(
              trackID: track.trackID, playbackTime: offTime, channel: note.channel, pitch: note.pitch, kind: .noteOff))
          }
        }
      }
    }
    return events.sorted { lhs, rhs in
      if lhs.playbackTime != rhs.playbackTime { return lhs.playbackTime < rhs.playbackTime }
      return lhs.kind.rank < rhs.kind.rank
    }
  }

  /// Each controller's value at a position: from the last event at or before it, or the
  /// controller's neutral value if it has none yet.
  private func chasedControls(of track: TrackNotes, at position: Tick) -> [(ControlLane, Int)] {
    guard !track.lanes.isEmpty else { return [] }
    var values: [ControlLane: Int] = [:]
    // Walk back from the position until every lane has its latest value.
    var index = Self.firstIndex(in: track.controls, notBefore: position + Tick(1), key: \.position) - 1
    while index >= 0, values.count < track.lanes.count {
      let control = track.controls[index]
      if values[control.lane] == nil {
        values[control.lane] = control.value
      }
      index -= 1
    }
    return track.lanes.map { lane in (lane, values[lane] ?? lane.kind.neutralValue) }
  }

  // MARK: - Automation

  /// A straight change of an automated parameter between two playback times.
  public struct AutomationRamp: Equatable, Sendable {
    public var trackID: Track.ID
    public var parameter: AutomationParameter
    public var startTime: Double
    public var endTime: Double
    /// In the parameter's units (decibels for volume).
    public var startValue: Double
    public var endValue: Double

    /// The value at a playback time inside the ramp.
    public func value(at time: Double) -> Double {
      guard endTime > startTime else { return endValue }
      let fraction = min(max((time - startTime) / (endTime - startTime), 0), 1)
      return startValue + (endValue - startValue) * fraction
    }
  }

  /// The automation of every automated parameter during a window of playback time, as
  /// ramps from point to point. Ramps are cut at the window's edges and at cycle repeats,
  /// so consecutive windows join up seamlessly and a cycle jumps back to the value at the
  /// cycle start. Tracks in Off mode, and parameters without points, are left out.
  public func automationRamps(in window: Range<Double>) -> [AutomationRamp] {
    let tempoMap = project.tempoMap
    var ramps: [AutomationRamp] = []
    for pass in passes(overlapping: window) {
      let passStart = pass.playbackOffset
      let passEnd = pass.playbackOffset + tempoMap.seconds(at: pass.end) - tempoMap.seconds(at: pass.start)
      let from = max(window.lowerBound, passStart)
      let to = min(window.upperBound, passEnd)
      guard from < to else { continue }
      let startSeconds = tempoMap.seconds(at: pass.start)
      let startTick = tempoMap.tickPosition(atSeconds: startSeconds + from - passStart)
      let endTick = tempoMap.tickPosition(atSeconds: startSeconds + to - passStart)
      guard startTick < endTick else { continue }

      for track in project.tracks where track.automationMode.plays {
        for lane in track.automation where !lane.points.isEmpty {
          let breakpoints = lane.breakpoints(in: startTick..<endTick)
          for (a, b) in zip(breakpoints, breakpoints.dropFirst()) where a < b {
            ramps.append(AutomationRamp(
              trackID: track.id, parameter: lane.parameter,
              // The window's own edges are used exactly so windows meet without gaps.
              startTime: a == startTick ? from : playbackTime(of: a, in: pass),
              endTime: b == endTick ? to : playbackTime(of: b, in: pass),
              startValue: lane.value(at: a) ?? 0, endValue: lane.value(at: b) ?? 0))
          }
        }
      }
    }
    return ramps.sorted { $0.startTime < $1.startTime }
  }

  // MARK: - Metronome

  /// Metronome clicks (one per beat) inside a window of playback time.
  public func clicks(in window: Range<Double>) -> [Click] {
    let tempoMap = project.tempoMap
    var clicks: [Click] = []
    for pass in passes(overlapping: window) {
      // Only walk the beats of this pass that can fall inside the window.
      let passStartSeconds = tempoMap.seconds(at: pass.start)
      let from = max(pass.start, tempoMap.tickPosition(atSeconds: passStartSeconds + window.lowerBound - pass.playbackOffset) - 1)
      let to = min(pass.end, tempoMap.tickPosition(atSeconds: passStartSeconds + window.upperBound - pass.playbackOffset) + 1)
      guard from < to else { continue }

      var (barIndex, barStart) = tempoMap.bar(containing: from)
      while barStart < to {
        let signature = tempoMap.timeSignature(atBarIndex: barIndex)
        for beat in 0..<signature.beatsPerBar {
          let position = barStart + signature.ticksPerBeat * Int64(beat)
          guard position >= pass.start, position < pass.end else { continue }
          let time = playbackTime(of: position, in: pass)
          if window.contains(time) {
            clicks.append(Click(playbackTime: time, isDownbeat: beat == 0))
          }
        }
        barIndex += 1
        barStart = tempoMap.tickPosition(ofBarIndex: barIndex)
      }
    }
    return clicks.sorted { $0.playbackTime < $1.playbackTime }
  }

  /// The clicks of a count-in of `bars` bars before `position`, at the tempo and meter
  /// there, with negative playback times that end at 0 (where playback starts), and how long
  /// the count-in lasts.
  public static func countIn(bars: Int, before position: Tick, in tempoMap: TempoMap) -> (clicks: [Click], duration: Double) {
    guard bars > 0 else { return ([], 0) }
    let signature = tempoMap.timeSignature(atBarIndex: tempoMap.bar(containing: position).index)
    let beatSeconds = Double(signature.ticksPerBeat.rawValue) * 60 / (tempoMap.tempo(at: position) * Double(Tick.perQuarterNote))
    let beats = bars * signature.beatsPerBar
    let duration = Double(beats) * beatSeconds
    let clicks = (0..<beats).map { beat in
      Click(playbackTime: Double(beat) * beatSeconds - duration, isDownbeat: beat % signature.beatsPerBar == 0)
    }
    return (clicks, duration)
  }
}

extension Project {
  /// Whether a track is heard, taking mute and solo into account: when any track is soloed,
  /// only soloed tracks play — plus, as in Logic, aux tracks fed by a soloed track (through
  /// sends or outputs), so a soloed vocal keeps its reverb and a soloed subtrack its summing
  /// stack, and the tracks that output into a soloed track, so soloing a summing stack plays
  /// its subtracks.
  public func isTrackAudible(_ trackID: Track.ID) -> Bool {
    guard let track = track(withID: trackID), !track.channel.isMuted else { return false }
    let soloed = tracks.filter { $0.channel.isSoloed }
    guard !soloed.isEmpty, !track.channel.isSoloed else { return true }

    // Upstream: this track's output leads into a soloed track.
    var visited: Set<Track.ID> = [trackID]
    var output = track.channel.output.trackID
    while let next = output, visited.insert(next).inserted, let destination = self.track(withID: next) {
      if destination.channel.isSoloed { return true }
      output = destination.channel.output.trackID
    }

    // Downstream: a soloed track's sends or outputs reach this aux.
    guard track.kind == .aux else { return false }
    var reachable: Set<Track.ID> = []
    var queue = soloed.flatMap(\.routedDestinations)
    while let next = queue.popLast() {
      guard reachable.insert(next).inserted, let destination = self.track(withID: next) else { continue }
      queue += destination.routedDestinations
    }
    return reachable.contains(trackID)
  }
}

/// How loud an audio segment plays from moment to moment: the region's gain, faded in at
/// the region's start and out at its end. Times are seconds.
public struct AudioEnvelope: Equatable, Sendable {
  /// Linear gain.
  public var gain: Double
  /// How far into the region the segment starts (playback can start part-way through).
  public var offset: Double
  public var regionDuration: Double
  public var fadeIn: Double
  public var fadeOut: Double

  public init(gain: Double = 1, offset: Double = 0, regionDuration: Double = .infinity, fadeIn: Double = 0, fadeOut: Double = 0) {
    self.gain = gain
    self.offset = offset
    self.regionDuration = regionDuration
    self.fadeIn = fadeIn
    self.fadeOut = fadeOut
  }

  /// Whether every sample just gets `gain`.
  public var isConstant: Bool {
    fadeIn <= 0 && fadeOut <= 0
  }

  /// The gain `seconds` into the segment.
  public func level(atSecondsIntoSegment seconds: Double) -> Double {
    let position = offset + seconds
    var level = gain
    if fadeIn > 0, position < fadeIn {
      level *= max(0, position / fadeIn)
    }
    if fadeOut > 0, position > regionDuration - fadeOut {
      level *= max(0, (regionDuration - position) / fadeOut)
    }
    return level
  }
}
