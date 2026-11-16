//
//  ProjectWindowModel+DocumentTitle.swift
//  Ongaku
//

import AppKit

extension ProjectWindowModel {
  /// What the title bar would say about the project: its name ("Untitled" until it's
  /// saved), whether it has been saved anywhere yet, and whether it has unsaved changes.
  struct DocumentTitle: Equatable {
    var name = "Untitled"
    var isSaved = false
    var isEdited = false
    /// Where it's saved, for the tooltip.
    var url: URL?

    var status: String {
      if !isSaved { return "Not saved" }
      return isEdited ? "Edited" : "Saved"
    }
  }

  /// Follows the project's name, file and unsaved changes as it's edited, saved or renamed.
  ///
  /// The name and file come from the window. Unsaved changes come from the document: SwiftUI
  /// doesn't pass them on to the window, whose "edited" flag stays off. The document counts
  /// a change as each edit's undo group closes, so it's read just after that (and after undo
  /// and redo), and whenever the window updates, which catches the end of a save.
  func observeDocumentTitle() {
    documentTitleObservations = []
    documentTitleObservers.forEach(NotificationCenter.default.removeObserver)
    documentTitleObservers = []
    guard let window = hostWindow else { return }
    func observe<Value>(_ keyPath: KeyPath<NSWindow, Value>) -> NSKeyValueObservation {
      window.observe(keyPath) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.updateDocumentTitle() }
      }
    }
    documentTitleObservations = [observe(\.title), observe(\.representedURL), observe(\.isDocumentEdited)]

    let center = NotificationCenter.default
    let undoNotifications: [Notification.Name] = [.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange]
    for name in undoNotifications {
      documentTitleObservers.append(center.addObserver(forName: name, object: window.undoManager, queue: .main) { [weak self] _ in
        // After the document has counted the change, which it does on the same notification.
        MainActor.assumeIsolated {
          Task { @MainActor in self?.updateDocumentTitle() }
        }
      })
    }
    documentTitleObservers.append(center.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.updateDocumentTitle() }
    })
    updateDocumentTitle()
  }

  private func updateDocumentTitle() {
    guard let window = hostWindow else { return }
    let document = window.windowController?.document as? NSDocument
    let url = document?.fileURL ?? window.representedURL
    // A saved project goes by its file's name, without ".ongaku" (the display name keeps
    // the extension when Finder shows all extensions).
    let fallback = document?.displayName ?? (window.title.isEmpty ? "Untitled" : window.title)
    let title = DocumentTitle(
      name: url?.deletingPathExtension().lastPathComponent ?? fallback,
      isSaved: url != nil, isEdited: document?.isDocumentEdited ?? window.isDocumentEdited, url: url)
    if title != documentTitle { documentTitle = title }
  }
}
