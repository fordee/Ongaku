//
//  ProjectPackageTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
import Testing
@testable import Ongaku

struct ProjectPackageTests {
  private let audio = Data("pretend audio".utf8)

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ProjectPackageTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func firstSaveCopiesStagedAudioIntoThePackage() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stagedURL = directory.appending(path: "Take.wav")
    try audio.write(to: stagedURL)

    let file = AudioFileReference(fileName: "Take.wav", sampleRate: 48_000, channelCount: 2, frameCount: 48_000)
    let project = Project(tracks: [Track(name: "Audio 1", kind: .audio)], audioFiles: [file])
    let snapshot = ProjectSnapshot(project: project, stagedAudio: ["Take.wav": stagedURL])

    let packageURL = directory.appending(path: "Song.ongaku")
    try ProjectPackage.makePackage(from: snapshot, previous: nil)
      .write(to: packageURL, options: .atomic, originalContentsURL: nil)

    let savedAudio = packageURL.appending(path: "Audio Files/Take.wav")
    #expect(try Data(contentsOf: savedAudio) == audio)
    let reread = try FileWrapper(url: packageURL)
    #expect(try ProjectPackage.readProject(from: reread) == project)
  }

  /// A sampler's audio (any large plug-in state) is kept in its own file, not in the JSON,
  /// and comes back when the song is opened; small states stay in the JSON.
  @Test func largePluginStatesAreKeptBesideTheProject() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var sampler = OngakuInstrument.sampler.makeReference()
    sampler.state = Data((0..<200_000).map { UInt8($0 % 251) })
    var eq = OngakuEffect.channelEQ.makeReference()
    eq.state = Data("small".utf8)
    var track = Track(name: "Sampler", kind: .softwareInstrument)
    track.channel.instrument = .audioUnit(sampler)
    track.channel.inserts = [eq]
    var project = Project(tracks: [track])

    let packageURL = directory.appending(path: "Song.ongaku")
    try ProjectPackage.makePackage(from: ProjectSnapshot(project: project, stagedAudio: [:]), previous: nil)
      .write(to: packageURL, options: .atomic, originalContentsURL: nil)

    let json = try Data(contentsOf: packageURL.appending(path: "Project.json"))
    #expect(json.count < 20_000, "The sampler's state isn't in the JSON (\(json.count) bytes)")
    let settings = try FileManager.default.contentsOfDirectory(atPath: packageURL.appending(path: "Plug-in Settings").path)
    #expect(settings.count == 1)
    #expect(try ProjectPackage.readProject(from: FileWrapper(url: packageURL)) == project)

    // A change to the state replaces its file; an unchanged project keeps it.
    project.tracks[0].channel.instrument = .audioUnit({ var changed = sampler; changed.state = Data(repeating: 7, count: 100_000); return changed }())
    try ProjectPackage.makePackage(from: ProjectSnapshot(project: project, stagedAudio: [:]), previous: FileWrapper(url: packageURL))
      .write(to: packageURL, options: .atomic, originalContentsURL: packageURL)
    let resaved = try FileManager.default.contentsOfDirectory(atPath: packageURL.appending(path: "Plug-in Settings").path)
    #expect(resaved.count == 1 && resaved != settings, "The old state's file is gone")
    #expect(try ProjectPackage.readProject(from: FileWrapper(url: packageURL)) == project)
  }

  @Test func laterSavesKeepAudioAlreadyInThePackage() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stagedURL = directory.appending(path: "Take.wav")
    try audio.write(to: stagedURL)

    let file = AudioFileReference(fileName: "Take.wav", sampleRate: 48_000, channelCount: 2, frameCount: 48_000)
    var project = Project(tracks: [Track(name: "Audio 1", kind: .audio)], audioFiles: [file])
    let packageURL = directory.appending(path: "Song.ongaku")
    try ProjectPackage.makePackage(from: ProjectSnapshot(project: project, stagedAudio: ["Take.wav": stagedURL]), previous: nil)
      .write(to: packageURL, options: .atomic, originalContentsURL: nil)

    // The staged copy is gone after reopening; the second save must still keep the audio.
    try FileManager.default.removeItem(at: stagedURL)
    project.tracks[0].name = "Vocal"
    let previous = try FileWrapper(url: packageURL)
    try ProjectPackage.makePackage(from: ProjectSnapshot(project: project, stagedAudio: [:]), previous: previous)
      .write(to: packageURL, options: .atomic, originalContentsURL: packageURL)

    #expect(try Data(contentsOf: packageURL.appending(path: "Audio Files/Take.wav")) == audio)
    #expect(try ProjectPackage.readProject(from: FileWrapper(url: packageURL)).tracks.first?.name == "Vocal")
  }

  @Test func packagesWithoutAProjectFileAreRejected() {
    let empty = FileWrapper(directoryWithFileWrappers: [:])
    #expect(throws: CocoaError.self) { try ProjectPackage.readProject(from: empty) }
  }

  /// Saving and opening go through `write` and `read`, which run off the main thread so a big
  /// project doesn't stall the window when it's autosaved.
  @Test @MainActor func packagesRoundTripThroughTheBackgroundWriter() async throws {
    let project = StressTestProject.make()
    let package = try await ProjectPackage.write(ProjectSnapshot(project: project, stagedAudio: [:]), previous: nil)
    let reopened = try await ProjectPackage.read(package)
    #expect(reopened.tracks.count == project.tracks.count)
    #expect(reopened.tracks.map(\.regions.count) == project.tracks.map(\.regions.count))
  }
}
