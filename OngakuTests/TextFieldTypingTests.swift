//
//  TextFieldTypingTests.swift
//  OngakuTests
//

import AppKit
import OngakuCore
@testable import OngakuEngine
@testable import Ongaku
import SwiftUI
import Testing

/// Keys typed into a text field (the tempo, say) reach it once, through the real event
/// path with the single-key shortcut monitor installed and the app's menus in place.
@MainActor
struct TextFieldTypingTests {
  @Observable final class Typed {
    var value = ""
  }

  private struct Field: View {
    @Bindable var text: Typed
    var body: some View {
      TextField("Tempo", text: $text.value).frame(width: 100)
    }
  }

  @Test func eachKeyIsTypedOnce() async throws {
    let model = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [Track(name: "Audio 1", kind: .audio)])))
    defer { model.engine.shutDown() }
    KeyCommandMonitor.shared.install(for: model)
    defer { KeyCommandMonitor.shared.remove(model) }

    let text = Typed()
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 200, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = NSHostingView(rootView: Field(text: text))
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(300))
    let contentView = try #require(window.contentView)
    let field = try #require(editableTextField(in: contentView))
    window.makeFirstResponder(field)
    try #require(window.firstResponder is NSText)

    // A digit, letters that are also single-key shortcuts (G and C), and Space.
    for (key, keyCode) in [("1", 18), ("2", 19), ("g", 5), ("c", 8), (" ", 49)] as [(String, UInt16)] {
      let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
        isARepeat: false, keyCode: keyCode))
      NSApp.postEvent(event, atStart: false)
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(text.value == "12gc ")
    #expect(!model.isGlobalTracksVisible, "G went to the field, not the shortcut")
    #expect(!model.project.cycle.isEnabled, "C went to the field, not the shortcut")
  }

  private func editableTextField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.lazy.compactMap { editableTextField(in: $0) }.first
  }
}
