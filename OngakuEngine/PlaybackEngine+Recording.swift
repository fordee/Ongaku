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

  /// Turns on audio input. The engine has to be stopped to add its input the first time.
  func prepareInput() -> AVAudioInputNode {
    guard engine.isRunning else {
      let input = engine.inputNode
      engine.prepare()
      try? engine.start()
      return input
    }
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

  private func fail(_ error: RecordingError) {
    lastErrorMessage(error.localizedDescription)
  }
}
