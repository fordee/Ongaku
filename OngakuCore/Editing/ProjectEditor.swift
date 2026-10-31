//
//  ProjectEditor.swift
//  OngakuCore
//

import Foundation
import Observation

/// Owns the live project for one document and applies commands to it with undo support.
///
/// Undo uses snapshots rather than hand-written inverse commands: before a command runs, the
/// current `Project` value is kept, and undo puts it back. Because the model is made of
/// copy-on-write value types, a snapshot only copies the parts of the project that the
/// command changed, and an inverse can never be subtly wrong.
@MainActor
@Observable
public final class ProjectEditor {
  public private(set) var project: Project

  public init(project: Project = .newDefault()) {
    self.project = project
  }

  /// Applies a command and registers it with the undo manager.
  ///
  /// The command runs on a copy of the project, so if it throws, nothing changes.
  /// SwiftUI document autosave relies on the undo registration to detect unsaved changes.
  public func perform(_ command: some EditCommand, undoManager: UndoManager?) throws {
    var updated = project
    try command.apply(to: &updated)
    try updated.checkFrozenTracksUnchanged(from: project)
    updated.removeOrphanedAutomation()
    updated.extendEndPastContent()
    replaceProject(with: updated, actionName: command.actionName, undoManager: undoManager)
  }

  /// Replaces the whole project without an undo step, for example after reading a file.
  public func load(_ project: Project) {
    self.project = project
  }

  private func replaceProject(with newProject: Project, actionName: String, undoManager: UndoManager?) {
    let previous = project
    project = newProject
    // Undoing registers the reverse replacement, which becomes the redo action.
    undoManager?.registerUndo(withTarget: self) { [weak undoManager] editor in
      editor.replaceProject(with: previous, actionName: actionName, undoManager: undoManager)
    }
    undoManager?.setActionName(actionName)
  }
}
