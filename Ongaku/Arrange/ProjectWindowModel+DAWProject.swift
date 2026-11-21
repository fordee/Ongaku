//
//  ProjectWindowModel+DAWProject.swift
//  Ongaku
//

import AppKit
import OngakuCore
import UniformTypeIdentifiers

extension UTType {
  /// DAWproject: a ZIP of the project's XML and files.
  static let dawProject = UTType(filenameExtension: DAWProject.fileExtension, conformingTo: .zip) ?? .zip
}

/// What an import or export couldn't carry over, shown once it's done.
struct InterchangeReport: Identifiable {
  let id = UUID()
  var title: String
  var message: String

  init(title: String, warnings: [String]) {
    self.title = title
    message = warnings.isEmpty
      ? "Everything carried over."
      : "Some things didn't carry over:\n\n" + warnings.prefix(12).map { "• \($0)" }.joined(separator: "\n")
        + (warnings.count > 12 ? "\n• …and \(warnings.count - 12) more." : "")
  }
}

extension ProjectWindowModel {
  /// File › Export Project as DAWproject…: the song for another app (Bitwig, Studio One,
  /// Cubase, Reaper…), with its audio and plug-in settings.
  func exportDAWProject() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.dawProject]
    panel.nameFieldStringValue = "\(documentTitle.name).\(DAWProject.fileExtension)"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let project = projectWithCurrentPluginStates()
    let urls = Dictionary(project.audioFiles.compactMap { file in document.url(for: file).map { (file.id, $0) } }, uniquingKeysWith: { a, _ in a })
    let title = documentTitle.name
    isExportingDAWProject = true
    Task {
      let result: Result<[String], Error> = await Task.detached {
        let export = DAWProject.export(
          project, title: title, audioData: { file in urls[file.id].flatMap { try? Data(contentsOf: $0) } }, pluginState: { $0.state })
        do {
          try ZipArchive.write(export.entries, to: url)
          return .success(export.warnings)
        } catch {
          return .failure(error)
        }
      }.value
      isExportingDAWProject = false
      switch result {
      case .success(let warnings):
        interchangeReport = InterchangeReport(title: "Exported “\(url.lastPathComponent)”", warnings: warnings)
      case .failure(let error):
        errorMessage = "The DAWproject couldn’t be saved: \(error.localizedDescription)"
      }
    }
  }

  /// A DAWproject read by File › Open DAWproject…, put into this (new) window: its audio
  /// copied into the song, then the song loaded.
  func loadImported(_ imported: DAWProject.Import, named name: String) async {
    var replacements: [AudioFileReference.ID: AudioFileReference] = [:]
    var warnings = imported.warnings
    let folder = FileManager.default.temporaryDirectory.appending(path: "DAWproject \(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var used = Set<String>()
    for file in imported.audioFiles {
      var fileName = file.reference.fileName
      if used.contains(fileName) { fileName = "\(UUID().uuidString)-\(fileName)" }
      used.insert(fileName)
      let url = folder.appending(path: fileName)
      do {
        try file.data.write(to: url)
        replacements[file.reference.id] = try await document.stageAudio(from: url, reservedNames: Set(replacements.values.map(\.fileName)))
      } catch {
        warnings.append("“\(file.reference.fileName)” couldn't be read: \(error.localizedDescription)")
      }
    }
    var project = imported.project.replacingAudioFiles(replacements)
    // Regions whose audio couldn't be copied in are left out.
    project.audioFiles = project.audioFiles.filter { file in replacements.values.contains { $0.id == file.id } }
    for index in project.tracks.indices {
      project.tracks[index].regions.removeAll { region in
        guard case .audio(let content) = region.content else { return false }
        return !project.audioFiles.contains { $0.id == content.fileID }
      }
    }
    document.editor.load(project)
    projectDidChange()
    interchangeReport = InterchangeReport(title: "Opened “\(name)”", warnings: warnings)
  }
}

/// File › Open DAWproject…: reads the file, then opens it in a new window.
@MainActor
enum DAWProjectOpener {
  /// The project waiting for the next window to open (see `ContentView`).
  static var pending: (project: DAWProject.Import, name: String)?

  static func choose(thenOpen openWindow: @escaping @MainActor () -> Void) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.dawProject]
    panel.message = "Choose a DAWproject to open as a new song."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      let result: Result<DAWProject.Import, Error> = await Task.detached {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
        do {
          return .success(try DAWProject.read(ZipArchive.read(Data(contentsOf: url))))
        } catch {
          return .failure(error)
        }
      }.value
      switch result {
      case .success(let imported):
        pending = (imported, url.lastPathComponent)
        openWindow()
      case .failure(let error):
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” couldn’t be opened"
        alert.informativeText = error.localizedDescription
        alert.runModal()
      }
    }
  }

  static func take() -> (project: DAWProject.Import, name: String)? {
    defer { pending = nil }
    return pending
  }
}
