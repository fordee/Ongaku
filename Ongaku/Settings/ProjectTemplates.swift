//
//  ProjectTemplates.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// Your own project templates (File › Save as Template…): each a project's setup, kept as a
/// file in the app's Application Support folder, to start new songs from.
enum ProjectTemplates {
  static let fileExtension = "ongakutemplate"

  /// Where they're kept; `folder` can be changed for tests.
  nonisolated(unsafe) static var folder = URL.applicationSupportDirectory.appending(path: "Templates", directoryHint: .isDirectory)

  /// The templates' names, alphabetically.
  static func names() -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == fileExtension }
      .map { $0.deletingPathExtension().lastPathComponent }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  /// Saves a project's setup (see `Project.template`) under `name`, replacing a template of
  /// that name.
  static func save(_ project: Project, as name: String) throws {
    let name = cleaned(name)
    guard !name.isEmpty else { throw EditError.invalidValue("Give the template a name.") }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try ProjectArchive.encode(project.template()).write(to: url(for: name), options: .atomic)
  }

  /// A new song from the template called `name`.
  static func newProject(from name: String) throws -> Project {
    try ProjectArchive.decode(Data(contentsOf: url(for: name))).fromTemplate()
  }

  static func delete(_ name: String) throws {
    try FileManager.default.removeItem(at: url(for: name))
  }

  private static func url(for name: String) -> URL {
    folder.appending(path: "\(cleaned(name)).\(fileExtension)")
  }

  /// A name that's safe as a file name.
  static func cleaned(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines).replacing(/[\/:]/, with: "-")
  }
}

/// The templates' names, for menus and Settings, kept up to date as they're saved and deleted.
@MainActor
@Observable
final class TemplateList {
  static let shared = TemplateList()
  private(set) var names = ProjectTemplates.names()

  func refresh() {
    names = ProjectTemplates.names()
  }

  func save(_ project: Project, as name: String) throws {
    try ProjectTemplates.save(project, as: name)
    refresh()
  }

  func delete(_ name: String) throws {
    try ProjectTemplates.delete(name)
    refresh()
  }
}

extension AppSettings {
  /// What New Project starts with when a template was chosen in File › New from Template
  /// (used once), or in Settings › General.
  @MainActor static var pendingTemplate: String?

  /// Settings › General's choice, when it's one of your templates: "template:<name>".
  static let userTemplatePrefix = "template:"

  /// The project a new window opens with: a template chosen in File › New from Template, the
  /// template chosen in Settings, or a built-in start.
  @MainActor static func makeNewProject() -> Project {
    let pending = pendingTemplate
    pendingTemplate = nil
    let chosen = UserDefaults.standard.string(forKey: newProjectTemplateKey) ?? ""
    let name = pending ?? (chosen.hasPrefix(userTemplatePrefix) ? String(chosen.dropFirst(userTemplatePrefix.count)) : nil)
    if let name, let project = try? ProjectTemplates.newProject(from: name) { return project }
    return newProjectTemplate.makeProject()
  }
}

extension ProjectWindowModel {
  /// File › Revert to Backup: the song as it was saved then, as one step that can be undone.
  /// A frozen track whose freeze file has since gone is unfrozen.
  func revert(toBackupFrom date: Date) {
    do {
      revert(to: try document.backup(from: date))
    } catch {
      errorMessage = "The backup couldn’t be opened: \(error.localizedDescription)"
    }
  }

  func revert(to backup: Project) {
    var backup = backup
    for index in backup.tracks.indices {
      if let file = backup.tracks[index].freezeFile, document.url(for: file).map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
        backup.tracks[index].freezeFile = nil
      }
    }
    engine.stop()
    perform(RevertProject(to: backup))
  }
}
