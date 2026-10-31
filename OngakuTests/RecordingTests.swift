//
//  RecordingTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
import Testing

@MainActor
@Suite(.serialized)
struct RecordingTests {
  private func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "RecordingTests-\(UUID().uuidString)-\(name)")
  }

  /// A two-channel "device" buffer: channel 1 counts up from 0, channel 2 counts down from -1.
  private func makeDeviceBuffer(frames: Int, startingAt first: Int) throws -> AVReadOnlyAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<frames {
      channels[0][frame] = Float(first + frame) / 100_000
      channels[1][frame] = -Float(first + frame + 1) / 100_000
    }
    return AVReadOnlyAudioPCMBuffer(copying: buffer)
  }

  @Test func framesBeforeTheTransportStartAreDropped() {
    #expect(AudioTakeRecorder.framesToDrop(bufferPlaybackTime: -0.01, sampleRate: 48_000, frameCount: 4096) == 480)
    #expect(AudioTakeRecorder.framesToDrop(bufferPlaybackTime: -1, sampleRate: 48_000, frameCount: 4096) == 4096)
    #expect(AudioTakeRecorder.framesToDrop(bufferPlaybackTime: 0.2, sampleRate: 48_000, frameCount: 4096) == 0)
  }

  @Test func audioTakesRecordTheSelectedInputAfterThePreRoll() throws {
    let url = temporaryURL("take.caf")
    defer { try? FileManager.default.removeItem(at: url) }
    // Record Input 2 (mono) from a two-channel device.
    let recorder = try AudioTakeRecorder(
      trackID: UUID(), url: url, input: AudioInputSelection(firstChannel: 1, isStereo: false),
      hardwareChannelCount: 2, sampleRate: 48_000)

    // The first buffer starts 10 ms (480 frames) before the transport.
    recorder.append(try makeDeviceBuffer(frames: 1000, startingAt: 0), playbackTime: -0.01)
    recorder.append(try makeDeviceBuffer(frames: 1000, startingAt: 1000), playbackTime: 1000.0 / 48_000 - 0.01)
    let take = try #require(try recorder.finish())
    #expect(take.frameCount == 1520)
    #expect(take.startTime == 0)

    let file = try AVAudioFile(forReading: url)
    #expect(file.length == 1520)
    #expect(file.processingFormat.channelCount == 1)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1520))
    try file.read(into: buffer)
    let samples = try #require(buffer.floatChannelData?[0])
    // Frame 480 of the device's second channel is the first frame kept. 24-bit files keep
    // these values to well within 1e-6.
    #expect(abs(samples[0] - (-481.0 / 100_000)) < 1e-6)
    #expect(abs(samples[1519] - (-2000.0 / 100_000)) < 1e-6)
  }

  /// The Recording settings' file types and bit depths all write files that read back.
  @Test(arguments: RecordingFileType.allCases, RecordingBitDepth.allCases)
  func takesUseTheChosenFileFormat(fileType: RecordingFileType, bitDepth: RecordingBitDepth) throws {
    let url = temporaryURL("take.\(fileType.pathExtension)")
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = try AudioTakeRecorder(
      trackID: UUID(), url: url, input: AudioInputSelection(firstChannel: 0, isStereo: true),
      hardwareChannelCount: 2, sampleRate: 48_000, bitDepth: bitDepth)
    recorder.append(try makeDeviceBuffer(frames: 1000, startingAt: 0), playbackTime: 0)
    #expect(try recorder.finish()?.frameCount == 1000)

    let file = try AVAudioFile(forReading: url)
    #expect(file.length == 1000)
    #expect(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == bitDepth.rawValue)
    #expect(file.fileFormat.settings[AVLinearPCMIsFloatKey] as? Bool == (bitDepth == .float32))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1000))
    try file.read(into: buffer)
    // 16-bit samples are coarser, but frame 999 (0.00999) is still within a step.
    #expect(abs((buffer.floatChannelData?[0][999] ?? 0) - 999.0 / 100_000) < 1e-4)
  }

  @Test func capturedMIDIBecomesNotesCorrectedForOutputLatency() throws {
    var track = Track(name: "Keys", kind: .softwareInstrument)
    track.isRecordArmed = true
    let project = Project(tracks: [track])
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }

    let start: UInt64 = 1_000_000_000
    let latency = 0.01
    func host(_ seconds: Double) -> UInt64 { start + AVAudioTime.hostTime(forSeconds: seconds + latency) }
    let recording = RecordingSession(
      audio: [], midiTrackIDs: [track.id], midiCapture: nil, startPosition: .zero, startHostTime: start,
      outputLatency: latency, inputLatency: 0)
    let plan = PlaybackPlan(project: project, startPosition: .zero)

    // At 120 BPM, beat 2 is 0.5 s and beat 3 is 1 s.
    let takes = engine.midiTakes(
      from: [(host(0.5), [0x90, 60, 100]), (host(1.0), [0x80, 60, 0])],
      recording: recording, plan: plan, stopPosition: Tick(3840))
    let take = try #require(takes.first)
    guard case .midi(let sequence) = take.region.content else {
      Issue.record("Expected MIDI")
      return
    }
    let note = try #require(sequence.notes.first)
    #expect(abs(note.start.rawValue - 960) <= 1)
    #expect(abs(note.length.rawValue - 960) <= 1)
  }

  @Test func recordingMIDIDeliversATake() async throws {
    var track = Track(name: "Keys", kind: .softwareInstrument)
    track.isRecordArmed = true
    let engine = PlaybackEngine(project: Project(tracks: [track])) { _ in nil }
    defer { engine.shutDown() }

    var result: RecordingResult?
    engine.onRecordingFinished = { result = $0 }
    await engine.record()
    #expect(engine.isRecording)
    let capture = try #require(engine.recordingSession?.midiCapture)

    try await Task.sleep(for: .milliseconds(300))
    capture.receive([0x90, 64, 90], atHostTime: mach_absolute_time())
    try await Task.sleep(for: .milliseconds(250))
    capture.receive([0x80, 64, 0], atHostTime: mach_absolute_time())
    try await Task.sleep(for: .milliseconds(100))
    engine.stop()

    #expect(!engine.isRecording)
    let take = try #require(result?.midi.first)
    #expect(take.trackID == track.id)
    #expect(take.region.start == .zero)
    guard case .midi(let sequence) = take.region.content else {
      Issue.record("Expected MIDI")
      return
    }
    #expect(sequence.notes.map(\.pitch) == [64])
    #expect(sequence.notes.first.map { $0.length > Tick(300) } == true)
  }

  /// With a one-bar count-in the playhead waits a bar before moving, and the metronome is
  /// heard for it even though it's switched off.
  @Test func countInDelaysTheStart() async throws {
    var track = Track(name: "Keys", kind: .softwareInstrument)
    track.isRecordArmed = true
    var project = Project(tracks: [track])
    try project.tempoMap.setTempo(240, at: .zero)  // one 4/4 bar a second
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    engine.recordingOptions.countInBars = 1

    await engine.record()
    #expect(engine.isRecording)
    #expect(engine.metronome?.volume == 1, "The count-in is heard")
    try await Task.sleep(for: .milliseconds(600))
    #expect(engine.playheadPosition == .zero, "Still counting in")
    try await Task.sleep(for: .milliseconds(900))
    #expect(engine.playheadPosition > .zero, "Recording has started")
    engine.stop()
    #expect(engine.metronome?.volume == 0, "The metronome is off again")
  }

  @Test func recordingWithNothingArmedExplainsWhy() async {
    let engine = PlaybackEngine(project: Project(tracks: [Track(name: "Keys", kind: .softwareInstrument)])) { _ in nil }
    defer { engine.shutDown() }
    await engine.record()
    #expect(!engine.isRecording)
    #expect(engine.lastError?.contains("Record-enable") == true)
  }
}

// MARK: - MIDI effects played live

extension RecordingTests {
  /// Live MIDI effects with a fixed tempo, recording what they play: each message with the
  /// seconds after `start` it's due (now if it had no time).
  private final class LivePlayer {
    var played: [(bytes: [UInt8], at: Double)] = []
    let start = mach_absolute_time()
  }

  private func live(_ effects: [MIDIEffect], tempo: Double = 120) -> (LiveMIDIEffects, LivePlayer) {
    let player = LivePlayer()
    let effects = LiveMIDIEffects(
      effects: effects,
      play: { bytes, hostTime in
        let time = hostTime ?? mach_absolute_time()
        player.played.append((bytes, AVAudioTime.seconds(forHostTime: time - min(time, player.start))))
      },
      songPosition: { _ in nil }, tempo: { tempo })
    return (effects, player)
  }

  private func wait(_ seconds: Double) async throws {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { try await Task.sleep(for: .milliseconds(5)) }
  }

  @Test func midiInputPlaysEveryTrackItsSentTo() {
    let piano = Track(name: "Piano", kind: .softwareInstrument)
    var synth = Track(name: "Synth", kind: .softwareInstrument)
    synth.channel.midiEffects = [MIDIEffect(.arpeggiator(Arpeggiator(rate: .sixteenth, order: .up)))]
    let engine = PlaybackEngine(project: Project(tracks: [piano, synth])) { _ in nil }
    defer { engine.shutDown() }
    engine.connectMIDIInput(toTracks: [piano.id, synth.id])
    #expect(engine.midiInputTrackIDs == [piano.id, synth.id])
    #expect(Set(engine.liveEffects.keys) == [synth.id], "Only the track with MIDI effects plays through them")
    engine.connectMIDIInput(toTracks: [piano.id])
    #expect(engine.liveEffects.isEmpty, "The synth's effects stop when it's no longer played")
  }

  @Test func instantMIDIEffectsPlayAsTheKeyIsPressed() async throws {
    let (effects, player) = live([MIDIEffect(.chordTrigger(ChordTrigger(chord: .major))), MIDIEffect(.transposer(Transposer(semitones: 2)))])
    effects.receive([0x90, 60, 100], at: mach_absolute_time())
    #expect(player.played.allSatisfy { $0.bytes[0] == 0x90 && $0.bytes[2] == 100 })
    #expect(Set(player.played.map { Int($0.bytes[1]) }) == [62, 66, 69], "D major: the chord, up a tone")
    #expect(player.played.allSatisfy { $0.at < 0.02 }, "Straight away")
    effects.receive([0x80, 60, 0], at: mach_absolute_time())
    try await wait(0.05)
    let offs = player.played.filter { $0.bytes[0] == 0x80 }.map { Int($0.bytes[1]) }
    #expect(Set(offs) == [62, 66, 69], "Letting go stops the whole chord")
    effects.stopAll()
  }

  @Test func theArpeggiatorPlaysLiveOnItsGrid() async throws {
    // Sixteenths at 120 BPM: one every 125 ms.
    let (effects, player) = live([MIDIEffect(.arpeggiator(Arpeggiator(rate: .sixteenth, order: .up)))])
    let pressed = mach_absolute_time()
    effects.receive([0x90, 60, 90], at: pressed)
    effects.receive([0x90, 64, 90], at: pressed)
    try await wait(0.45)
    effects.receive([0x80, 60, 0], at: mach_absolute_time())
    effects.receive([0x80, 64, 0], at: mach_absolute_time())
    try await wait(0.2)
    let ons = player.played.filter { $0.bytes[0] == 0x90 }
    #expect(ons.prefix(4).map { Int($0.bytes[1]) } == [60, 64, 60, 64], "Up and up again")
    let spacing = zip(ons.dropFirst(), ons).map { $0.at - $1.at }.prefix(3)
    #expect(spacing.allSatisfy { abs($0 - 0.125) < 0.004 }, "Scheduled a sixteenth apart: \(spacing)")
    let offs = player.played.filter { $0.bytes[0] == 0x80 }
    #expect(offs.count == ons.count, "Every note stops")
    effects.stopAll()
  }
}
