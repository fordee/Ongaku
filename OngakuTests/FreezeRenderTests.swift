//
//  FreezeRenderTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
@testable import Ongaku
import Testing

/// Freezing renders: the freeze file lines up with the timeline, and a frozen track sounds
/// the same as it did before, in bounces and in the live engine.
@MainActor
@Suite(.serialized)
struct FreezeRenderTests {
  private let folder = FileManager.default.temporaryDirectory.appending(path: "FreezeRenderTests-\(UUID().uuidString)")

  init() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// A quarter-second 1 kHz tone, starting at full amplitude on frame 0.
  private func makeTone() throws -> (URL, AudioFileReference) {
    let url = folder.appending(path: "Tone.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000))
    buffer.frameLength = 12_000
    for channel in 0..<2 {
      for frame in 0..<12_000 {
        buffer.floatChannelData![channel][frame] = 0.5 * cos(2 * .pi * 1_000 * Float(frame) / 48_000)
      }
    }
    try file.write(from: buffer)
    return (url, AudioFileReference(fileName: url.lastPathComponent, sampleRate: 48_000, channelCount: 2, frameCount: 12_000))
  }

  /// The tone on beat 2 of an audio track, through a compressor (256 samples of latency),
  /// with its fader at -6 dB.
  private func toneProject() throws -> (Project, Track.ID, Files) {
    let (url, file) = try makeTone()
    var track = Track(name: "Tone", kind: .audio, regions: [Region.audio(for: file, at: .quarterNotes(1), tempoMap: TempoMap())])
    track.channel.inserts = [BuiltInEffect.compressor.makeReference()]
    track.channel.volume = -6
    let files = Files()
    files.urls[file.id] = url
    return (Project(tracks: [track], audioFiles: [file]), track.id, files)
  }

  /// Where the test's audio and freeze files are.
  private final class Files {
    var urls: [AudioFileReference.ID: URL] = [:]
    func locate(_ file: AudioFileReference) -> URL? { urls[file.id] }
  }

  /// Freezes a track and returns the project with it frozen.
  private func freeze(_ trackID: Track.ID, in project: Project, files: Files) async throws -> (Project, AudioFileReference) {
    let url = folder.appending(path: "Freeze \(UUID().uuidString).caf")
    let reference = try await ProjectBouncer.freeze(trackID, in: project, sampleRate: 48_000, to: url) { files.locate($0) }
    files.urls[reference.id] = url
    var frozen = project
    try FreezeTrack(trackID, file: reference).apply(to: &frozen)
    return (frozen, reference)
  }

  private func bounce(_ project: Project, files: Files, named name: String) async throws -> [Float] {
    let output = folder.appending(path: "\(name).caf")
    let bouncer = ProjectBouncer(project: project) { files.locate($0) }
    let range = try #require(project.bounceRange)
    _ = try await bouncer.bounce(range, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false), to: output)
    return try samples(of: output)
  }

  private func samples(of url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
  }

  private func onset(in samples: [Float]) -> Int? {
    samples.firstIndex { abs($0) > 0.05 }
  }

  @Test func freezeFilesLineUpWithTheTimeline() async throws {
    let (project, trackID, files) = try toneProject()
    let (_, reference) = try await freeze(trackID, in: project, files: files)
    let url = try #require(files.locate(reference))
    let samples = try samples(of: url)
    #expect(onset(in: samples) == 24_000, "The compressor's latency is taken off")
    #expect(reference.sampleRate == 48_000)
    #expect(Int(reference.frameCount) == samples.count)
    #expect(samples.count >= 36_000, "The file runs to the end of the region at least")
    // Pre-fader: the fader's -6 dB isn't in the file.
    let peak = samples.map(abs).max() ?? 0
    #expect(peak > 0.4, "The fader isn't applied (peak \(peak))")
  }

  @Test func frozenTracksBounceTheSameAsBefore() async throws {
    let (project, trackID, files) = try toneProject()
    let before = try await bounce(project, files: files, named: "Before")
    let (frozen, _) = try await freeze(trackID, in: project, files: files)
    let after = try await bounce(frozen, files: files, named: "After")
    #expect(before.count == after.count)
    let difference = zip(before, after).map { abs($0 - $1) }.max() ?? 1
    #expect(difference < 0.0001, "Frozen and unfrozen differ by up to \(difference)")
  }

  @Test func frozenInstrumentsSoundTheSame() async throws {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 80)
    let note = MIDINote(pitch: 72, velocity: 127, start: .quarterNotes(2), length: .quarterNotes(1))
    keys.regions = [Region(name: "Notes", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence(notes: [note])))]
    let project = Project(tracks: [keys])
    let files = Files()
    let before = try await bounce(project, files: files, named: "Keys Before")
    let (frozen, _) = try await freeze(keys.id, in: project, files: files)
    let after = try await bounce(frozen, files: files, named: "Keys After")
    let beforeOnset = try #require(before.firstIndex { abs($0) > 0.001 })
    let afterOnset = try #require(after.firstIndex { abs($0) > 0.001 })
    #expect(abs(beforeOnset - afterOnset) <= 1, "The note starts at \(afterOnset) frozen, \(beforeOnset) live")
    let beforePeak = before.map(abs).max() ?? 0
    let afterPeak = after.map(abs).max() ?? 0
    #expect(abs(beforePeak - afterPeak) < 0.01)
  }

  @Test func frozenTracksStillFollowTheirFader() async throws {
    let (project, trackID, files) = try toneProject()
    var (frozen, _) = try await freeze(trackID, in: project, files: files)
    frozen.tracks[0].channel.isMuted = true
    let samples = try await bounce(frozen, files: files, named: "Muted")
    #expect((samples.map(abs).max() ?? 1) == 0)
  }

  @Test func tracksWithoutRegionsCantBeFrozen() async throws {
    let project = Project(tracks: [Track(name: "Empty", kind: .softwareInstrument)])
    await #expect(throws: BounceError.self) {
      _ = try await ProjectBouncer.freeze(
        project.tracks[0].id, in: project, sampleRate: 48_000, to: folder.appending(path: "Empty.caf")) { _ in nil }
    }
  }

  // MARK: - Live

  @Test func frozenInstrumentsAreUnloadedLive() async throws {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.inserts = [BuiltInEffect.compressor.makeReference()]
    keys.regions = [Region(name: "Notes", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence(notes: [
      MIDINote(pitch: 60, velocity: 100, start: .zero, length: .quarterNotes(1))
    ])))]
    let project = Project(tracks: [keys])
    let files = Files()
    let engine = PlaybackEngine(project: project) { files.locate($0) }
    defer { engine.shutDown() }
    #expect(engine.instruments[keys.id] != nil)

    let (frozen, _) = try await freeze(keys.id, in: project, files: files)
    engine.update(project: frozen)
    #expect(engine.instruments[keys.id] == nil, "The instrument is unloaded")
    #expect(engine.project.tracks[0].kind == .audio, "The track plays its freeze file")
    #expect(engine.compensation.totalLatency == 0, "The compressor is in the file, so nothing is delayed")

    var unfrozen = frozen
    try UnfreezeTrack(keys.id).apply(to: &unfrozen)
    engine.update(project: unfrozen)
    #expect(engine.instruments[keys.id] != nil, "Unfreezing loads the instrument again")
  }

  // MARK: - Saving

  @Test func freezeFilesAreSavedAndRemovedWithTheProject() throws {
    let staged = folder.appending(path: "Staged Freeze.caf")
    try Data([1, 2, 3]).write(to: staged)
    var track = Track(name: "Keys", kind: .softwareInstrument)
    track.freezeFile = AudioFileReference(fileName: "Keys Freeze.caf", sampleRate: 48_000, channelCount: 2, frameCount: 1)
    var project = Project(tracks: [track])

    let package = try ProjectPackage.makePackage(
      from: ProjectSnapshot(project: project, stagedAudio: [:], stagedFreezeFiles: ["Keys Freeze.caf": staged]), previous: nil)
    let freezeFolder = try #require(package.fileWrappers?[ProjectArchive.freezeFilesDirectoryName])
    #expect(freezeFolder.fileWrappers?["Keys Freeze.caf"] != nil)

    project.tracks[0].freezeFile = nil
    let resaved = try ProjectPackage.makePackage(from: ProjectSnapshot(project: project, stagedAudio: [:]), previous: package)
    #expect(resaved.fileWrappers?[ProjectArchive.freezeFilesDirectoryName] == nil, "Unused freeze files are removed")
  }
}
