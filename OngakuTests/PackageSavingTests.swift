//
//  PackageSavingTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
@testable import Ongaku
import Testing

/// Saving a song keeps its audio and backups, save after save, as the document system does
/// it: writing the package atomically, and handing each save the package read or last written.
@MainActor
struct PackageSavingTests {
  private let folder = FileManager.default.temporaryDirectory.appending(path: "PackageSavingTests-\(UUID().uuidString)")

  init() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  private func stagedFile(_ name: String) throws -> URL {
    let url = folder.appending(path: name)
    try Data(repeating: 7, count: 4096).write(to: url)
    return url
  }

  private func audioNames(in package: URL) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: package.appending(path: ProjectArchive.audioFilesDirectoryName).path)) ?? [])
  }

  /// The document system doesn't always hand a save the package it read or last wrote; the
  /// one on disk takes its place, so earlier audio and backups survive.
  @Test func savesWithoutAPreviousPackageKeepWhatsSaved() throws {
    let packageURL = folder.appending(path: "Song.ongaku")
    let bounce = AudioFileReference(fileName: "Bounce.caf", sampleRate: 48_000, channelCount: 2, frameCount: 1024)
    let project = Project(tracks: [], audioFiles: [bounce])
    let first = try ProjectPackage.makePackage(
      from: ProjectSnapshot(project: project, stagedAudio: ["Bounce.caf": try stagedFile("Bounce.caf")]), previous: nil)
    try first.write(to: packageURL, options: .atomic, originalContentsURL: nil)

    // The song reopened: nothing staged, and no previous package.
    let second = try ProjectPackage.makePackage(
      from: ProjectSnapshot(project: project, stagedAudio: [:], savedPackageURL: packageURL), previous: nil)
    try second.write(to: packageURL, options: .atomic, originalContentsURL: nil)
    #expect(audioNames(in: packageURL) == ["Bounce.caf"], "The saved audio is kept")
    let saved = try Data(contentsOf: packageURL.appending(path: "\(ProjectArchive.audioFilesDirectoryName)/Bounce.caf"))
    #expect(saved.count == 4096, "with its contents")
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: packageURL.appending(path: ProjectPackage.backupsDirectoryName).path)) ?? []
    #expect(backups.count == 1, "The earlier save is backed up")

    // A previous package that's missing a file the song uses gets it from the saved one.
    let incomplete = FileWrapper(directoryWithFileWrappers: [:])
    let third = try ProjectPackage.makePackage(
      from: ProjectSnapshot(project: project, stagedAudio: [:], savedPackageURL: packageURL), previous: incomplete)
    try third.write(to: packageURL, options: .atomic, originalContentsURL: nil)
    #expect(audioNames(in: packageURL) == ["Bounce.caf"])
  }

  @Test(arguments: [false, true])
  func audioSurvivesLaterSaves(reopening: Bool) throws {
    let packageURL = folder.appending(path: "Song.ongaku")
    let first = AudioFileReference(fileName: "Bounce.caf", sampleRate: 48_000, channelCount: 2, frameCount: 1024)
    var project = Project(tracks: [], audioFiles: [first])

    // Save 1: a new song with staged audio.
    var wrapper = try ProjectPackage.makePackage(
      from: ProjectSnapshot(project: project, stagedAudio: ["Bounce.caf": try stagedFile("Bounce.caf")]), previous: nil)
    try wrapper.write(to: packageURL, options: .atomic, originalContentsURL: nil)
    #expect(audioNames(in: packageURL) == ["Bounce.caf"])

    if reopening {
      wrapper = try FileWrapper(url: packageURL)
    }
    // Save 2: another file staged since; the first is in the package already.
    let second = AudioFileReference(fileName: "Bounce 2.caf", sampleRate: 48_000, channelCount: 2, frameCount: 1024)
    project.audioFiles.append(second)
    wrapper = try ProjectPackage.makePackage(
      from: ProjectSnapshot(project: project, stagedAudio: ["Bounce 2.caf": try stagedFile("Bounce 2.caf")]), previous: wrapper)
    try wrapper.write(to: packageURL, options: .atomic, originalContentsURL: packageURL)
    #expect(audioNames(in: packageURL) == ["Bounce.caf", "Bounce 2.caf"], "reopening: \(reopening)")

    // Save 3: nothing new staged.
    if reopening {
      wrapper = try FileWrapper(url: packageURL)
    }
    wrapper = try ProjectPackage.makePackage(from: ProjectSnapshot(project: project, stagedAudio: [:]), previous: wrapper)
    try wrapper.write(to: packageURL, options: .atomic, originalContentsURL: packageURL)
    #expect(audioNames(in: packageURL) == ["Bounce.caf", "Bounce 2.caf"], "reopening: \(reopening)")
    let backups = (try? FileManager.default.contentsOfDirectory(atPath: packageURL.appending(path: ProjectPackage.backupsDirectoryName).path)) ?? []
    #expect(!backups.isEmpty, "reopening: \(reopening): a backup of an earlier save is kept")
  }
}
