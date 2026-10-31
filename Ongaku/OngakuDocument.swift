//
//  OngakuDocument.swift
//  Ongaku
//

import OngakuCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
  /// An `.ongaku` project package. Declared in the app's Info.plist.
  static let ongakuProject = UTType(exportedAs: "net.4dware.ongaku.project")
}

/// What the writer needs to save a package: the project plus imported audio files that
/// haven't been copied into the package yet.
nonisolated struct ProjectSnapshot: Sendable {
  var project: Project
  /// Staged copies of imported audio, by file name inside "Audio Files".
  var stagedAudio: [String: URL]
  /// Freeze files rendered since the document opened, by file name inside "Freeze Files".
  var stagedFreezeFiles: [String: URL] = [:]
}

/// An `.ongaku` project package opened in a window.
@Observable
final class OngakuDocument: Document {
  static let readableContentTypes: [UTType] = [.ongakuProject]

  let editor: ProjectEditor
  /// Where the document lives on disk; `fileURL` is `nil` until the first save.
  @ObservationIgnored private let configuration: URLDocumentConfiguration?
  /// Imported audio waiting to be written into the package, by audio file identifier.
  @ObservationIgnored private var stagedAudio: [AudioFileReference.ID: URL] = [:]
  /// The current settings of plug-ins whose windows are open (set by the window). They only
  /// reach the project when a window closes, so a save takes them from here too.
  @ObservationIgnored var openPluginStates: (@MainActor () -> [SetPluginState])?
  @ObservationIgnored private(set) lazy var stagingDirectory = FileManager.default.temporaryDirectory
    .appending(path: "Ongaku Imports", directoryHint: .isDirectory)
    .appending(path: UUID().uuidString, directoryHint: .isDirectory)

  init(project: Project = .newDefault(), configuration: URLDocumentConfiguration? = nil) {
    editor = ProjectEditor(project: project)
    self.configuration = configuration
  }

  /// The file name without its extension, once the document has been saved.
  var displayName: String? {
    configuration?.fileURL?.deletingPathExtension().lastPathComponent
  }

  // MARK: - Audio files

  /// The readable location of an audio file or freeze file: the staged copy if it was
  /// imported or rendered since the document opened, otherwise the copy inside the package.
  func url(for file: AudioFileReference) -> URL? {
    if let staged = stagedAudio[file.id] {
      return staged
    }
    guard let packageURL = configuration?.fileURL else { return nil }
    let isFreezeFile = editor.project.tracks.contains { $0.freezeFile?.id == file.id }
    let folder = isFreezeFile ? ProjectArchive.freezeFilesDirectoryName : ProjectArchive.audioFilesDirectoryName
    return packageURL
      .appending(path: folder, directoryHint: .isDirectory)
      .appending(path: file.fileName)
  }

  /// A new file for a flexed region's render. Renders can always be made again, so they
  /// stay in the staging folder and aren't saved in the package.
  func newFlexRenderURL() throws -> URL {
    let folder = stagingDirectory.appending(path: "Flex", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appending(path: "Flex \(UUID().uuidString).caf")
  }

  /// Registers a flex render so playback can find it.
  func adoptFlexRender(_ reference: AudioFileReference, at url: URL) {
    stagedAudio[reference.id] = url
  }

  /// A new file in the staging folder for a track's freeze file to be rendered into.
  func newFreezeFileURL() throws -> URL {
    try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    return stagingDirectory.appending(path: "Freeze \(UUID().uuidString).caf")
  }

  /// Registers a freeze file rendered into the staging folder, so it can be played and is
  /// saved with the project. The reference isn't part of the project until `FreezeTrack`.
  func adoptFreezeFile(_ reference: AudioFileReference, at url: URL) {
    stagedAudio[reference.id] = url
  }

  /// Copies an audio file into the document's staging folder.
  ///
  /// The returned reference isn't part of the project yet: callers add it with
  /// `AddAudioFile`, usually in the same command as the region that plays it, so a single
  /// undo removes both. `reservedNames` are names already taken by other files being
  /// imported in the same batch.
  func stageAudio(from source: URL, reservedNames: Set<String> = []) async throws -> AudioFileReference {
    var project = editor.project
    project.audioFiles += reservedNames.map {
      AudioFileReference(fileName: $0, sampleRate: 1, channelCount: 1, frameCount: 1)
    }
    let fileName = AudioImporter.uniqueFileName(for: source, in: project)
    let (reference, stagedURL) = try await AudioImporter.stage(source, as: fileName, in: stagingDirectory)
    stagedAudio[reference.id] = stagedURL
    return reference
  }

  /// Takes ownership of a file recorded into the staging folder: gives it a unique name
  /// based on `preferredName` and registers it as staged audio. The reference isn't part of
  /// the project yet; callers add it with `AddAudioFile`.
  func adoptRecordedAudio(
    at url: URL, sampleRate: Double, channelCount: Int, frameCount: Int64, preferredName: String,
    reservedNames: Set<String> = []
  ) throws -> AudioFileReference {
    var project = editor.project
    project.audioFiles += reservedNames.map {
      AudioFileReference(fileName: $0, sampleRate: 1, channelCount: 1, frameCount: 1)
    }
    // Keep the recording's own file type (CAF, WAV or AIFF, from the Recording settings).
    let fileName = AudioImporter.uniqueFileName(
      for: URL(fileURLWithPath: "\(preferredName).\(url.pathExtension)"), in: project)
    let destination = url.deletingLastPathComponent().appending(path: fileName)
    if destination != url {
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: url, to: destination)
    }
    let reference = AudioFileReference(
      fileName: fileName, sampleRate: sampleRate, channelCount: channelCount, frameCount: frameCount)
    stagedAudio[reference.id] = destination
    return reference
  }

  // MARK: - Reading

  func reader(configuration: sending ReadConfiguration) -> sending FileWrapperDocumentReader<Project> {
    FileWrapperDocumentReader(configuration) { package in
      try await ProjectPackage.read(package)
    }
  }

  @MainActor
  func apply(snapshot: sending Project, previous: sending Project?) async throws {
    editor.load(snapshot)
  }

  // MARK: - Writing

  func writer(configuration: sending WriteConfiguration) -> sending FileWrapperDocumentWriter<ProjectSnapshot> {
    // This closure is created on the main actor and would run there; encoding a big project
    // takes a noticeable moment (170 ms for the 100-track stress song), which stalled the
    // window on every autosave. `ProjectPackage.write` does the work off the main thread.
    FileWrapperDocumentWriter(configuration) { snapshot, previousPackage in
      try await ProjectPackage.write(snapshot, previous: previousPackage)
    }
  }

  @MainActor
  func snapshot(contentType: UTType) async throws -> sending ProjectSnapshot {
    var project = editor.project
    for capture in openPluginStates?() ?? [] {
      try? capture.apply(to: &project)
    }
    var staged: [String: URL] = [:]
    for file in project.audioFiles {
      if let url = stagedAudio[file.id] {
        staged[file.fileName] = url
      }
    }
    var stagedFreezeFiles: [String: URL] = [:]
    for file in project.tracks.compactMap(\.freezeFile) {
      if let url = stagedAudio[file.id] {
        stagedFreezeFiles[file.fileName] = url
      }
    }
    return ProjectSnapshot(project: project, stagedAudio: staged, stagedFreezeFiles: stagedFreezeFiles)
  }
}

/// Builds and reads the file wrapper for an `.ongaku` package. Kept separate from the
/// document so saving and loading can be tested without the document system.
nonisolated enum ProjectPackage {
  /// Reads a package off the main thread.
  @concurrent
  static func read(_ package: sending FileWrapper) async throws -> Project {
    try readProject(from: package)
  }

  /// Builds a package off the main thread (see `makePackage`).
  @concurrent
  static func write(_ snapshot: ProjectSnapshot, previous: sending FileWrapper?) async throws -> sending FileWrapper {
    try makePackage(from: snapshot, previous: previous)
  }

  static func readProject(from package: FileWrapper) throws -> Project {
    guard let data = package.fileWrappers?[ProjectArchive.projectFileName]?.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    var project = try ProjectArchive.decode(data)
    let settings = package.fileWrappers?[ProjectArchive.pluginSettingsDirectoryName]?.fileWrappers
    ProjectArchive.restoringPluginStates(&project) { settings?[$0]?.regularFileContents }
    return project
  }

  /// Starts from the previous package so audio files already in it (which can be large)
  /// are carried over instead of being rewritten on every save.
  static func makePackage(from snapshot: ProjectSnapshot, previous previousPackage: FileWrapper?) throws -> FileWrapper {
    let package = previousPackage ?? FileWrapper(directoryWithFileWrappers: [:])

    if let oldProjectFile = package.fileWrappers?[ProjectArchive.projectFileName] {
      package.removeFileWrapper(oldProjectFile)
    }
    let (stored, pluginStates) = ProjectArchive.separatingLargePluginStates(snapshot.project)
    let projectFile = FileWrapper(regularFileWithContents: try ProjectArchive.encode(stored))
    projectFile.preferredFilename = ProjectArchive.projectFileName
    package.addFileWrapper(projectFile)
    updatePluginSettings(in: package, with: pluginStates)

    let audioFiles: FileWrapper
    if let existing = package.fileWrappers?[ProjectArchive.audioFilesDirectoryName] {
      audioFiles = existing
    } else {
      audioFiles = FileWrapper(directoryWithFileWrappers: [:])
      audioFiles.preferredFilename = ProjectArchive.audioFilesDirectoryName
      package.addFileWrapper(audioFiles)
    }

    // Copy in imported audio that isn't in the package yet. Files that are no longer used
    // are kept, so undoing a delete never loses audio.
    for file in snapshot.project.audioFiles where audioFiles.fileWrappers?[file.fileName] == nil {
      guard let stagedURL = snapshot.stagedAudio[file.fileName] else { continue }
      let wrapper = try FileWrapper(url: stagedURL)
      wrapper.preferredFilename = file.fileName
      audioFiles.addFileWrapper(wrapper)
    }
    try updateFreezeFiles(in: package, from: snapshot)
    return package
  }

  /// Large plug-in states, one file each. Files are named for their contents, so unchanged
  /// ones are left alone; ones no plug-in uses any more are removed (undo keeps the state in
  /// memory, so it's written again if it comes back).
  private static func updatePluginSettings(in package: FileWrapper, with files: [String: Data]) {
    let existing = package.fileWrappers?[ProjectArchive.pluginSettingsDirectoryName]
    if files.isEmpty {
      if let existing { package.removeFileWrapper(existing) }
      return
    }
    let folder: FileWrapper
    if let existing {
      folder = existing
    } else {
      folder = FileWrapper(directoryWithFileWrappers: [:])
      folder.preferredFilename = ProjectArchive.pluginSettingsDirectoryName
      package.addFileWrapper(folder)
    }
    for (name, wrapper) in folder.fileWrappers ?? [:] where files[name] == nil {
      folder.removeFileWrapper(wrapper)
    }
    for (name, data) in files where folder.fileWrappers?[name] == nil {
      let wrapper = FileWrapper(regularFileWithContents: data)
      wrapper.preferredFilename = name
      folder.addFileWrapper(wrapper)
    }
  }

  /// Freeze files can always be rendered again, so unlike audio, the ones no frozen track
  /// plays any more are removed rather than kept for undo.
  private static func updateFreezeFiles(in package: FileWrapper, from snapshot: ProjectSnapshot) throws {
    let used = Set(snapshot.project.tracks.compactMap(\.freezeFile?.fileName))
    let existing = package.fileWrappers?[ProjectArchive.freezeFilesDirectoryName]
    if used.isEmpty {
      if let existing {
        package.removeFileWrapper(existing)
      }
      return
    }
    let folder: FileWrapper
    if let existing {
      folder = existing
    } else {
      folder = FileWrapper(directoryWithFileWrappers: [:])
      folder.preferredFilename = ProjectArchive.freezeFilesDirectoryName
      package.addFileWrapper(folder)
    }
    for (name, wrapper) in folder.fileWrappers ?? [:] where !used.contains(name) {
      folder.removeFileWrapper(wrapper)
    }
    for name in used where folder.fileWrappers?[name] == nil {
      guard let stagedURL = snapshot.stagedFreezeFiles[name] else { continue }
      let wrapper = try FileWrapper(url: stagedURL)
      wrapper.preferredFilename = name
      folder.addFileWrapper(wrapper)
    }
  }
}
