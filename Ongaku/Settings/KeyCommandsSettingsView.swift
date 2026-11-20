//
//  KeyCommandsSettingsView.swift
//  Ongaku
//

import AppKit
import SwiftUI

/// Settings › Key Commands: the single-key shortcuts, each changed by clicking it and
/// pressing a new key, as in Logic's Key Commands editor.
struct KeyCommandsSettingsView: View {
  @State private var bindings = KeyBindings.shared
  /// The command waiting for its new key.
  @State private var recording: KeyCommand?
  @State private var note: String?

  var body: some View {
    Form {
      Section {
        ForEach(KeyCommand.allCases) { command in
          LabeledContent(command.title) {
            Button(recording == command ? "Press a key…" : Self.keyName(bindings.key(for: command))) {
              startRecording(command)
            }
            .frame(minWidth: 110)
            .help("Click, then press the new key. Escape cancels.")
            .accessibilityLabel("\(command.title) key")
            .accessibilityValue(Self.keyName(bindings.key(for: command)))
          }
        }
      } footer: {
        Text(note ?? "Single keys work wherever you last clicked in a project window, except while typing. Space, Return, Delete, the arrow keys and the Tool menu's keys don't change.")
          .foregroundStyle(note == nil ? .secondary : Color.orange)
      }
      Section {
        Button("Restore Logic’s Keys") {
          bindings.restoreDefaults()
          note = nil
        }
        .disabled(bindings.isDefault)
      }
    }
    .settingsPaneStyle()
    .onDisappear { stopRecording() }
  }

  private func startRecording(_ command: KeyCommand) {
    recording = command
    note = nil
    KeyCommandMonitor.shared.keyRecorder = { event in
      guard let command = recording else { return false }
      // Escape cancels.
      if event.keyCode == 53 {
        stopRecording()
        return true
      }
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .function])
      guard modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased().first,
        KeyBindings.assignableKeys.contains(key)
      else {
        note = "That key can’t be used: choose a letter, digit or punctuation key, without ⌘, ⌥, ⌃ or ⇧. (Q is the Piano Roll’s Quantize.)"
        NSSound.beep()
        return true
      }
      if let swapped = bindings.assign(key, to: command) {
        note = "\(Self.keyName(key)) was \(swapped.title); that now has \(Self.keyName(bindings.key(for: swapped)))."
      }
      stopRecording()
      return true
    }
  }

  private func stopRecording() {
    recording = nil
    KeyCommandMonitor.shared.keyRecorder = nil
  }

  static func keyName(_ key: Character) -> String {
    switch key {
    case ",": "Comma (,)"
    case ".": "Period (.)"
    default: key.uppercased()
    }
  }
}

extension View {
  /// The grouped look every Settings pane has.
  func settingsPaneStyle() -> some View {
    formStyle(.grouped)
      .scrollIndicators(.never)
      .fixedSize(horizontal: false, vertical: true)
  }
}

#Preview {
  KeyCommandsSettingsView().frame(width: 720)
}
