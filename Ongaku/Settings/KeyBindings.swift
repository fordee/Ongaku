//
//  KeyBindings.swift
//  Ongaku
//

import AppKit
import SwiftUI

/// A command with a single-key shortcut that can be changed in Settings › Key Commands, as
/// in Logic's Key Commands editor. Space, Return, Delete, the arrows and the Tool menu's
/// tool keys stay as they are.
enum KeyCommand: String, CaseIterable, Identifiable {
  case record, cycle, metronome, previousBar, nextBar
  case editor, mixer, smartControls, library, loopBrowser, inspector, automation, globalTracks, toolMenu

  var id: Self { self }

  var title: String {
    switch self {
    case .record: "Record"
    case .cycle: "Cycle On/Off"
    case .metronome: "Metronome On/Off"
    case .previousBar: "Back One Bar"
    case .nextBar: "Forward One Bar"
    case .editor: "Show/Hide Editor"
    case .mixer: "Show/Hide Mixer"
    case .smartControls: "Show/Hide Smart Controls"
    case .library: "Show/Hide Library"
    case .loopBrowser: "Show/Hide Loop Browser"
    case .inspector: "Show/Hide Inspector"
    case .automation: "Show/Hide Automation"
    case .globalTracks: "Show/Hide Global Tracks"
    case .toolMenu: "Tool Menu"
    }
  }

  /// Logic's keys.
  var defaultKey: Character {
    switch self {
    case .record: "r"
    case .cycle: "c"
    case .metronome: "k"
    case .previousBar: ","
    case .nextBar: "."
    case .editor: "e"
    case .mixer: "x"
    case .smartControls: "b"
    case .library: "y"
    case .loopBrowser: "o"
    case .inspector: "i"
    case .automation: "a"
    case .globalTracks: "g"
    case .toolMenu: "t"
    }
  }
}

/// Which key plays each `KeyCommand`, kept between launches. The key monitor and the menus
/// both read it, so a changed key shows in the menus and works straight away.
@MainActor
@Observable
final class KeyBindings {
  static let shared = KeyBindings()
  static let defaultsKey = "KeyBindings"

  /// Keys a command can take: letters, digits and punctuation. Q is the Piano Roll's
  /// Quantize, so it isn't offered.
  static let assignableKeys = Set("abcdefghijklmnoprstuvwxyz0123456789,./;'[]-=`")

  private(set) var keys: [KeyCommand: Character]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    var keys = Dictionary(uniqueKeysWithValues: KeyCommand.allCases.map { ($0, $0.defaultKey) })
    for (name, key) in defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:] {
      if let command = KeyCommand(rawValue: name), let key = key.first, Self.assignableKeys.contains(key) { keys[command] = key }
    }
    self.keys = keys
  }

  @ObservationIgnored private let defaults: UserDefaults

  func key(for command: KeyCommand) -> Character {
    keys[command] ?? command.defaultKey
  }

  func command(forKey key: Character) -> KeyCommand? {
    KeyCommand.allCases.first { self.key(for: $0) == key }
  }

  /// The menu item's shortcut.
  func shortcut(for command: KeyCommand) -> KeyboardShortcut {
    KeyboardShortcut(KeyEquivalent(key(for: command)), modifiers: [])
  }

  /// Gives a command a new key. A command that had the key takes this one's old key, so no
  /// two share one. Returns the command that swapped, if any; `nil` also if the key can't be used.
  @discardableResult
  func assign(_ key: Character, to command: KeyCommand) -> KeyCommand? {
    let key = Character(key.lowercased())
    guard Self.assignableKeys.contains(key) else { return nil }
    let previous = self.key(for: command)
    let other = self.command(forKey: key).flatMap { $0 == command ? nil : $0 }
    keys[command] = key
    if let other { keys[other] = previous }
    save()
    return other
  }

  func restoreDefaults() {
    keys = Dictionary(uniqueKeysWithValues: KeyCommand.allCases.map { ($0, $0.defaultKey) })
    save()
  }

  var isDefault: Bool { KeyCommand.allCases.allSatisfy { key(for: $0) == $0.defaultKey } }

  private func save() {
    let changed = keys.filter { $0.value != $0.key.defaultKey }
    defaults.set(Dictionary(uniqueKeysWithValues: changed.map { ($0.key.rawValue, String($0.value)) }), forKey: Self.defaultsKey)
  }
}

extension ProjectWindowModel {
  func run(_ command: KeyCommand) {
    switch command {
    case .record: toggleRecording()
    case .cycle: toggleCycle()
    case .metronome: toggleMetronome()
    case .previousBar: moveByBars(-1)
    case .nextBar: moveByBars(1)
    case .editor: toggleEditor()
    case .mixer: toggleMixer()
    case .smartControls: toggleSmartControls()
    case .library: toggleLibrary()
    case .loopBrowser: toggleLoopBrowser()
    case .inspector: toggleInspector()
    case .automation: toggleAutomation()
    case .globalTracks: toggleGlobalTracks()
    case .toolMenu: showToolMenu()
    }
  }
}
