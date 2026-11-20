//
//  PlaybackEngine+Recording.swift
//  OngakuEngine
//

import AVFAudio
import Foundation
import OngakuCore

/// What a recording produced, for the app to add to the project as one undoable step.
public struct RecordingResult: Sendable {
  public struct AudioTake: Sendable {
    public var trackID: Track.ID
    /// The recorded file, in `recordingDirectory`.
    public var fileURL: URL
    public var sampleRate: Double
    public var channelCount: Int
    public var frameCount: Int64
    /// Where the take starts on the timeline.
    public var start: Tick
    /// When the cycle was on: the cycle, and for each pass recorded, the file frame that
    /// played at the cycle start (negative if recording began after it). Each pass becomes a
    /// take in a take folder over the cycle.
    public var cyclePasses: (cycle: Range<Tick>, startFrames: [Int64])?
  }

  public struct MIDITake: Sendable {
    public var trackID: Track.ID
    /// A take folder when several cycle passes were recorded.
    public var region: Region
  }

  public var audio: [AudioTake] = []
  public var midi: [MIDITake] = []

  public var isEmpty: Bool { audio.isEmpty && midi.isEmpty }
}

/// MIDI played while the song played without recording, for Capture as Recording.
struct CapturedPerformance {
  /// What was played, where on the timeline.
  var events: [(position: Tick, bytes: [UInt8])]
  /// Where the first event was played, and where playing stopped.
  var start: Tick
  var stop: Tick

  /// What a track listening to `accepts` would have recorded.
  func recorder(accepting accepts: ([UInt8]) -> Bool) -> MIDIRecorder {
    var recorder = MIDIRecorder()
    for event in events where accepts(event.bytes) {
      recorder.add(event.bytes, at: event.position)
    }
    recorder.finish(at: stop)
    return recorder
  }
}

/// The takes being captured during one recording.
struct RecordingSession {
  var audio: [AudioTakeRecorder]
  var midiTrackIDs: [Track.ID]
  var midiCapture: MIDICapture?
  var startPosition: Tick
  var startHostTime: UInt64 = 0
  /// Seconds between a sound leaving the engine and the performer hearing it.
  var outputLatency: Double
  /// Seconds between the performer playing and the input tap receiving the sound.
  var inputLatency: Double
}

extension PlaybackEngine {
  public enum RecordingError: LocalizedError {
    case nothingArmed
    case microphoneAccessDenied
    case noRecordingFolder

    public var errorDescription: String? {
      switch self {
      case .nothingArmed: "Record-enable a track first (the R button on its header)."
      case .microphoneAccessDenied:
        "Ongaku Studio doesn’t have permission to use audio input. Turn it on in System Settings › Privacy & Security › Microphone."
      case .noRecordingFolder: "There’s nowhere to save the recording."
      }
    }
  }

  /// Starts recording from the playhead onto every record-enabled track: audio tracks record
  /// their input, instrument tracks record MIDI keyboards.
  public func record() async {
    guard !isRecording else { return }
    let armed = project.tracks.filter { $0.isRecordArmed && $0.kind.canRecord }
    guard !armed.isEmpty else { return fail(.nothingArmed) }
    let audioTracks = armed.filter { $0.kind == .audio }

    var recorders: [AudioTakeRecorder] = []
    var inputLatency = 0.0
    if !audioTracks.isEmpty {
      guard await AVAudioApplication.requestRecordPermission() else { return fail(.microphoneAccessDenied) }
      guard let directory = recordingDirectory else { return fail(.noRecordingFolder) }
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = prepareInput()
        let format = input.outputFormat(forBus: 0)
        inputLatency = input.presentationLatency
        for track in audioTracks {
          let fileName = "\(track.name) \(UUID().uuidString.prefix(6)).\(recordingOptions.fileType.pathExtension)"
          recorders.append(try AudioTakeRecorder(
            trackID: track.id, url: directory.appending(path: fileName), input: track.channel.audioInput ?? .defaultInput,
            hardwareChannelCount: Int(format.channelCount), sampleRate: format.sampleRate,
            bitDepth: recordingOptions.bitDepth))
        }
      } catch {
        lastErrorMessage("Recording couldn’t start: \(error.localizedDescription)")
        return
      }
    }

    let midiTrackIDs = armed.filter { $0.kind == .softwareInstrument }.map(\.id)
    let recording = RecordingSession(
      audio: recorders, midiTrackIDs: midiTrackIDs, midiCapture: midiTrackIDs.isEmpty ? nil : MIDICapture(),
      // The performer hears the mix late by the device's latency and plug-in compensation's.
      startPosition: playheadPosition, outputLatency: engine.outputNode.presentationLatency + compensationSeconds,
      inputLatency: inputLatency)
    startPlayback(from: playheadPosition, recording: recording)
  }

  /// Turns on audio input. The engine has to be stopped to add its input the first time;
  /// like every restart, it goes through `restartEngine`, which reloads the samplers' sounds.
  func prepareInput() -> AVAudioInputNode {
    var input: AVAudioInputNode?
    restartEngine { input = engine.inputNode }
    return input ?? engine.inputNode
  }

  func beginRecording(_ recording: RecordingSession, startHostTime: UInt64) {
    var recording = recording
    recording.startHostTime = startHostTime
    recordingSession = recording
    isRecording = true

    if let capture = recording.midiCapture {
      MIDIInputRouter.shared?.setCapture(capture)
    }
    guard !recording.audio.isEmpty else { return }

    let recorders = recording.audio
    // The performer plays along to what they hear, which is one output latency late, and
    // their sound reaches the tap one input latency after that.
    let compensation = recording.outputLatency + recording.inputLatency
    do {
      try engine.inputNode.installAudioTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, time in
        let seconds = time.hostTime >= startHostTime
          ? AVAudioTime.seconds(forHostTime: time.hostTime - startHostTime)
          : -AVAudioTime.seconds(forHostTime: startHostTime - time.hostTime)
        for recorder in recorders {
          recorder.append(buffer, playbackTime: seconds - compensation)
        }
      }
    } catch {
      lastErrorMessage("Audio input couldn’t be recorded: \(error.localizedDescription)")
    }
  }

  /// Ends the recording, closes the files and hands the takes to the app.
  func finishRecording() {
    guard let recording = recordingSession, let session else {
      recordingSession = nil
      isRecording = false
      return
    }
    recordingSession = nil
    isRecording = false
    MIDIInputRouter.shared?.setCapture(nil)
    if !recording.audio.isEmpty {
      engine.inputNode.removeTap(onBus: 0)
    }

    let now = mach_absolute_time()
    let elapsed = now > session.startHostTime ? AVAudioTime.seconds(forHostTime: now - session.startHostTime) : 0
    let stopPosition = session.plan.timelinePosition(atPlaybackTime: max(0, elapsed - session.latency))
    var result = RecordingResult()

    for recorder in recording.audio {
      do {
        if let take = try recorder.finish() {
          let rate = recorder.format.sampleRate
          result.audio.append(RecordingResult.AudioTake(
            trackID: recorder.trackID, fileURL: recorder.url, sampleRate: rate,
            channelCount: Int(recorder.format.channelCount), frameCount: take.frameCount,
            start: session.plan.timelinePosition(atPlaybackTime: take.startTime),
            cyclePasses: Self.cyclePasses(
              in: session.plan, recordedFrom: take.startTime, frames: take.frameCount, sampleRate: rate)))
        } else {
          try? FileManager.default.removeItem(at: recorder.url)
        }
      } catch {
        lastErrorMessage("A recording couldn’t be saved: \(error.localizedDescription)")
      }
    }

    if let capture = recording.midiCapture {
      result.midi = midiTakes(
        from: capture.takeEvents(), recording: recording, plan: session.plan, stopPosition: stopPosition)
    }
    if !result.isEmpty {
      onRecordingFinished?(result)
    }
  }

  /// The cycle passes a recording covers (each for at least a second), as the file frame at
  /// each one's cycle start. `nil` when the cycle wasn't looping or only one pass was made.
  static func cyclePasses(
    in plan: PlaybackPlan, recordedFrom startTime: Double, frames: Int64, sampleRate: Double
  ) -> (cycle: Range<Tick>, startFrames: [Int64])? {
    guard let cycle = plan.cycleRange else { return nil }
    let endTime = startTime + Double(frames) / sampleRate
    var startFrames: [Int64] = []
    var pass = 0
    while let cycleStart = plan.cycleStartTime(ofPass: pass), cycleStart < endTime {
      let passEnd = plan.cycleStartTime(ofPass: pass + 1) ?? endTime
      let covered = min(passEnd, endTime) - max(cycleStart, startTime)
      if covered >= 1 {
        startFrames.append(Int64(((cycleStart - startTime) * sampleRate).rounded()))
      }
      pass += 1
    }
    return startFrames.count > 1 ? (cycle, startFrames) : nil
  }

  /// Converts captured MIDI into one region per record-enabled instrument track: a take
  /// folder of the cycle passes when the cycle looped, otherwise a plain region.
  func midiTakes(
    from events: [(hostTime: UInt64, bytes: [UInt8])], recording: RecordingSession, plan: PlaybackPlan,
    stopPosition: Tick
  ) -> [RecordingResult.MIDITake] {
    // Each track records only the channel it listens to.
    recording.midiTrackIDs.flatMap { trackID -> [RecordingResult.MIDITake] in
      guard let track = project.track(withID: trackID) else { return [] }
      var single = recording
      single.midiTrackIDs = [trackID]
      return midiTakes(from: events.filter { track.acceptsMIDIInput($0.bytes) }, recordingOne: single, plan: plan, stopPosition: stopPosition)
    }
  }

  /// `midiTakes` for one track (`recording.midiTrackIDs` holds just it).
  private func midiTakes(
    from events: [(hostTime: UInt64, bytes: [UInt8])], recordingOne recording: RecordingSession, plan: PlaybackPlan,
    stopPosition: Tick
  ) -> [RecordingResult.MIDITake] {
    if let cycle = plan.cycleRange, let takes = cycleMIDITakes(from: events, recording: recording, plan: plan, cycle: cycle) {
      return takes
    }
    var recorder = MIDIRecorder()
    for event in events {
      // Notes are played against what the performer hears, one output latency late.
      let seconds = event.hostTime >= recording.startHostTime
        ? AVAudioTime.seconds(forHostTime: event.hostTime - recording.startHostTime)
        : -AVAudioTime.seconds(forHostTime: recording.startHostTime - event.hostTime)
      let position = plan.timelinePosition(atPlaybackTime: max(0, seconds - recording.outputLatency))
      recorder.add(event.bytes, at: position)
    }
    recorder.finish(at: stopPosition)

    return recording.midiTrackIDs.compactMap { trackID in
      guard let track = project.track(withID: trackID),
        var region = recorder.makeRegion(
          name: track.name, recordedFrom: recording.startPosition, to: stopPosition, tempoMap: project.tempoMap)
      else { return nil }
      region.id = UUID()
      return RecordingResult.MIDITake(trackID: trackID, region: region)
    }
  }

  /// One take per cycle pass in which something was played, as take folders over the cycle;
  /// `nil` if only one pass had anything in it (that records as a plain region).
  private func cycleMIDITakes(
    from events: [(hostTime: UInt64, bytes: [UInt8])], recording: RecordingSession, plan: PlaybackPlan, cycle: Range<Tick>
  ) -> [RecordingResult.MIDITake]? {
    var recorders: [Int: MIDIRecorder] = [:]
    for event in events {
      let seconds = event.hostTime >= recording.startHostTime
        ? AVAudioTime.seconds(forHostTime: event.hostTime - recording.startHostTime)
        : -AVAudioTime.seconds(forHostTime: recording.startHostTime - event.hostTime)
      let time = max(0, seconds - recording.outputLatency)
      recorders[plan.passIndex(atPlaybackTime: time), default: MIDIRecorder()]
        .add(event.bytes, at: plan.timelinePosition(atPlaybackTime: time))
    }
    // Notes still held at the end of a pass end with it.
    let sequences = recorders.keys.sorted().compactMap { pass -> MIDISequence? in
      var recorder = recorders[pass]!
      recorder.finish(at: cycle.upperBound)
      return recorder.makeSequence(relativeTo: cycle.lowerBound)
    }
    guard sequences.count > 1 else { return nil }
    return recording.midiTrackIDs.compactMap { trackID in
      guard let track = project.track(withID: trackID) else { return nil }
      let takes = sequences.enumerated().map { index, sequence in
        Take(name: "Take \(index + 1)", content: .midi(sequence))
      }
      let length = cycle.upperBound - cycle.lowerBound
      // The last take plays, as in Logic.
      let region = Region(
        name: track.name, start: cycle.lowerBound, length: length, content: takes[takes.count - 1].content,
        takeFolder: TakeFolder(takes: takes, playing: takes[takes.count - 1].id, length: length))
      return RecordingResult.MIDITake(trackID: trackID, region: region)
    }
  }

  // MARK: - Capture as Recording

  /// Starts remembering what's played while the song plays without recording.
  func beginPerformanceCapture() {
    let capture = MIDICapture()
    performanceCapture = capture
    MIDIInputRouter.shared?.setCapture(capture)
  }

  /// Keeps what was played (if anything) as the last performance, as playback stops.
  func endPerformanceCapture() {
    guard let capture = performanceCapture else { return }
    performanceCapture = nil
    MIDIInputRouter.shared?.setCapture(nil)
    guard let session, recordingSession == nil else { return }
    let stop = session.plan.timelinePosition(atPlaybackTime: elapsedPlaybackTime(of: session))
    if let performance = Self.performance(from: capture.capturedSoFar(), session: session, outputLatency: performanceOutputLatency, stop: stop) {
      lastPerformance = performance
    }
  }

  /// Logic's Capture as Recording: what was played while the song played without
  /// recording (or is being played now), as takes for `trackIDs`, as if it had been
  /// recorded. `nil` if nothing was played.
  public func capturedPerformance(for trackIDs: [Track.ID]) -> RecordingResult? {
    var performance = lastPerformance
    if let capture = performanceCapture, let session {
      let now = session.plan.timelinePosition(atPlaybackTime: elapsedPlaybackTime(of: session))
      performance = Self.performance(from: capture.capturedSoFar(), session: session, outputLatency: performanceOutputLatency, stop: now)
        ?? performance
    }
    guard let performance else { return nil }
    var result = RecordingResult()
    result.midi = trackIDs.compactMap { trackID in
      guard let track = project.track(withID: trackID), track.kind == .softwareInstrument,
        var region = performance.recorder(accepting: track.acceptsMIDIInput).makeRegion(
          name: track.name, recordedFrom: performance.start, to: performance.stop, tempoMap: project.tempoMap)
      else { return nil }
      region.id = UUID()
      return RecordingResult.MIDITake(trackID: trackID, region: region)
    }
    return result.isEmpty ? nil : result
  }

  /// Notes are played against what's heard: the device's latency and compensation's late.
  private var performanceOutputLatency: Double {
    engine.outputNode.presentationLatency + compensationSeconds
  }

  private func elapsedPlaybackTime(of session: Session) -> Double {
    let now = mach_absolute_time()
    let elapsed = now > session.startHostTime ? AVAudioTime.seconds(forHostTime: now - session.startHostTime) : 0
    return max(0, elapsed - session.latency)
  }

  /// Played MIDI as positions on the timeline. With the cycle on, only the last pass
  /// played is kept, as Logic does.
  static func performance(
    from events: [(hostTime: UInt64, bytes: [UInt8])], session: Session, outputLatency: Double, stop: Tick
  ) -> CapturedPerformance? {
    let plan = session.plan
    let played = events.map { event in
      let seconds = event.hostTime >= session.startHostTime
        ? AVAudioTime.seconds(forHostTime: event.hostTime - session.startHostTime)
        : -AVAudioTime.seconds(forHostTime: session.startHostTime - event.hostTime)
      return (time: max(0, seconds - outputLatency), bytes: event.bytes)
    }
    let lastPass = plan.cycleRange == nil ? nil : played.map { plan.passIndex(atPlaybackTime: $0.time) }.max()
    var positioned: [(position: Tick, bytes: [UInt8])] = []
    for event in played where lastPass == nil || plan.passIndex(atPlaybackTime: event.time) == lastPass {
      positioned.append((plan.timelinePosition(atPlaybackTime: event.time), event.bytes))
    }
    guard let start = positioned.map(\.position).min() else { return nil }
    // A cycle pass ends at the cycle's end; otherwise where playback stopped.
    let end = lastPass != nil ? (plan.cycleRange?.upperBound ?? stop) : stop
    let performance = CapturedPerformance(events: positioned, start: start, stop: max(end, start))
    guard performance.recorder(accepting: { _ in true }).makeSequence(relativeTo: start) != nil else { return nil }
    return performance
  }

  private func fail(_ error: RecordingError) {
    lastErrorMessage(error.localizedDescription)
  }
}
