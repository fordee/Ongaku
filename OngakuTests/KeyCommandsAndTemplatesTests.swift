//
//  KeyCommandsAndTemplatesTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
import OngakuEngine
@testable import Ongaku
import Testing

/// Settings › Key Commands, project templates and the backups kept in a song's package.
@MainActor
@Suite(.serialized)
struct KeyCommandsAndTemplatesTests {
  private func defaults() -> UserDefaults {
    let name = "KeyCommandsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test func keysAreChangedSwappedAndRemembered() {
    let defaults = defaults()
    let bindings = KeyBindings(defaults: defaults)
    #expect(bindings.isDefault && bindings.command(forKey: "x") == .mixer)

    #expect(bindings.assign("m", to: .mixer) == nil)
    #expect(bindings.command(forKey: "m") == .mixer && bindings.command(forKey: "x") == nil)
    // Taking another command's key swaps them.
    #expect(bindings.assign("c", to: .mixer) == .cycle)
    #expect(bindings.key(for: .mixer) == "c" && bindings.key(for: .cycle) == "m")
    // Q (the Piano Roll's Quantize) and Space can't be had.
    #expect(bindings.assign("q", to: .record) == nil && bindings.key(for: .record) == "r")
    #expect(bindings.assign(" ", to: .record) == nil && bindings.key(for: .record) == "r")

    let reopened = KeyBindings(defaults: defaults)
    #expect(reopened.key(for: .mixer) == "c" && reopened.key(for: .cycle) == "m")
    reopened.restoreDefaults()
    #expect(KeyBindings(defaults: defaults).isDefault)
  }

  @Test func templatesStartNewSongs() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "TemplateTests-\(UUID().uuidString)")
    let saved = ProjectTemplates.folder
    ProjectTemplates.folder = folder
    defer {
      ProjectTemplates.folder = saved
      try? FileManager.default.removeItem(at: folder)
    }
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.regions = [Region(name: "Chords", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence()))]
    let song = Project(tempoMap: TempoMap(bpm: 140), tracks: [keys, Track(name: "Vox", kind: .audio)])

    try ProjectTemplates.save(song, as: "  Band/Setup ")
    #expect(ProjectTemplates.names() == ["Band-Setup"])
    AppSettings.pendingTemplate = "Band-Setup"
    let new = AppSettings.makeNewProject()
    #expect(new.tracks.map(\.name) == ["Keys", "Vox"] && new.tracks[0].regions.isEmpty)
    #expect(new.tempoMap.tempo(at: .zero) == 140)
    #expect(AppSettings.pendingTemplate == nil, "A chosen template is used once")
    #expect(throws: EditError.self) { try ProjectTemplates.save(song, as: "   ") }
    try ProjectTemplates.delete("Band-Setup")
    #expect(ProjectTemplates.names().isEmpty)
  }

  @Test func savesKeepBackupsAFewMinutesApart() throws {
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    func projectFile(_ name: String) -> FileWrapper {
      FileWrapper(regularFileWithContents: Data(name.utf8))
    }
    let package = FileWrapper(directoryWithFileWrappers: [:])
    ProjectPackage.keepBackup(of: projectFile("v1"), in: package, now: start)
    ProjectPackage.keepBackup(of: projectFile("v2"), in: package, now: start + 60)  // Too soon.
    ProjectPackage.keepBackup(of: projectFile("v3"), in: package, now: start + 400)
    var backups = package.fileWrappers?[ProjectPackage.backupsDirectoryName]?.fileWrappers ?? [:]
    #expect(backups.count == 2)
    #expect(backups[ProjectPackage.backupFileName(for: start + 400)]?.regularFileContents == Data("v3".utf8))
    #expect(ProjectPackage.backupDate(fromFileName: ProjectPackage.backupFileName(for: start)) == start)

    // Only the newest ten are kept.
    for step in 2...12 {
      ProjectPackage.keepBackup(of: projectFile("v\(step + 2)"), in: package, now: start + Double(step) * 400)
    }
    backups = package.fileWrappers?[ProjectPackage.backupsDirectoryName]?.fileWrappers ?? [:]
    #expect(backups.count == ProjectPackage.maximumBackups)
    #expect(backups[ProjectPackage.backupFileName(for: start)] == nil, "The oldest went")
  }

  @Test func revertingToABackupIsOneUndoableStep() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "BackupTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let packageURL = directory.appending(path: "Song.ongaku")
    let before = Project(tracks: [Track(name: "Before", kind: .audio)])
    let after = Project(tracks: [Track(name: "After", kind: .audio)])
    let first = try ProjectPackage.makePackage(from: ProjectSnapshot(project: before, stagedAudio: [:]), previous: nil)
    try first.write(to: packageURL, options: .atomic, originalContentsURL: nil)
    try ProjectPackage.makePackage(from: ProjectSnapshot(project: after, stagedAudio: [:]), previous: FileWrapper(url: packageURL))
      .write(to: packageURL, options: .atomic, originalContentsURL: nil)
    #expect(FileManager.default.fileExists(atPath: packageURL.appending(path: "Backups").path))

    let date = try #require(ProjectPackage.backups(inPackageAt: packageURL).first)
    let backup = try ProjectPackage.backup(from: date, inPackageAt: packageURL)
    #expect(backup.tracks.map(\.name) == ["Before"])

    let window = ProjectWindowModel(document: OngakuDocument(project: after))
    defer { window.engine.shutDown() }
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    window.undoManager = undoManager
    undoManager.beginUndoGrouping()
    window.revert(to: backup)
    undoManager.endUndoGrouping()
    #expect(window.project.tracks.map(\.name) == ["Before"])
    undoManager.undo()
    #expect(window.project.tracks.map(\.name) == ["After"])
  }
}
