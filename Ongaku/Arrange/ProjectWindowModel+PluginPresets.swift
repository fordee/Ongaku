//
//  ProjectWindowModel+PluginPresets.swift
//  Ongaku
//

import AppKit
import AudioToolbox
import OngakuCore
import OngakuEngine
import SwiftUI

extension ProjectWindowModel {
  /// Scoped access to a loaded plug-in on a channel strip, whichever kind it is: the
  /// instrument, a MIDI effect or an insert. Returns whether it's loaded.
  @discardableResult
  func withPluginAudioUnit(_ pluginID: PluginReference.ID, on trackID: Track.ID, _ body: (borrowing AUAudioUnit) -> Void) -> Bool {
    let channel = project.track(withID: trackID)?.channel
    if case .audioUnit(let instrument) = channel?.instrument, instrument.id == pluginID {
      return engine.withInstrumentAudioUnit(forTrack: trackID, body) != nil
    }
    if channel?.midiEffects.contains(where: { $0.plugin?.id == pluginID }) == true {
      return engine.withMIDIEffectAudioUnit(pluginID, onTrack: trackID, body) != nil
    }
    return engine.withInsertAudioUnit(pluginID, onTrack: trackID, body) != nil
  }
}

/// The presets of another maker's plug-in, in its window's title bar as in Logic: the
/// plug-in's own factory presets, and presets saved in Ongaku (see `PluginPresetStore`).
@MainActor
@Observable
final class PluginPresets {
  let plugin: PluginReference
  private let trackID: Track.ID
  private weak var model: ProjectWindowModel?
  private let store: PluginPresetStore
  private(set) var factoryPresets: [String] = []
  private(set) var savedPresets: [String] = []
  /// The preset last chosen or saved here, shown on the menu.
  private(set) var current: String?

  init(plugin: PluginReference, trackID: Track.ID, model: ProjectWindowModel, store: PluginPresetStore = .standard) {
    self.plugin = plugin
    self.trackID = trackID
    self.model = model
    self.store = store
    model.withPluginAudioUnit(plugin.id, on: trackID) { audioUnit in
      factoryPresets = (audioUnit.factoryPresets ?? []).map(\.name)
      current = audioUnit.currentPreset?.name
    }
    savedPresets = store.names(for: plugin)
  }

  func chooseFactoryPreset(_ name: String) {
    model?.withPluginAudioUnit(plugin.id, on: trackID) { audioUnit in
      audioUnit.currentPreset = audioUnit.factoryPresets?.first { $0.name == name }
    }
    current = name
  }

  func chooseSavedPreset(_ name: String) {
    guard let data = store.state(named: name, for: plugin),
      let state = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else {
      model?.errorMessage = "The preset “\(name)” couldn’t be read."
      return
    }
    model?.withPluginAudioUnit(plugin.id, on: trackID) { $0.fullState = state }
    current = name
  }

  /// Saves the plug-in's settings now as a preset.
  func save(named name: String) {
    var data: Data?
    model?.withPluginAudioUnit(plugin.id, on: trackID) { audioUnit in
      data = audioUnit.fullState.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
    }
    guard let data else {
      model?.errorMessage = "“\(plugin.name)” didn’t give its settings to save."
      return
    }
    do {
      try store.save(data, named: name, for: plugin)
      savedPresets = store.names(for: plugin)
      current = name
    } catch {
      model?.errorMessage = "The preset couldn’t be saved: \(error.localizedDescription)"
    }
  }

  func delete(_ name: String) {
    try? store.delete(named: name, for: plugin)
    savedPresets = store.names(for: plugin)
    if current == name { current = nil }
  }

  /// Asks for a name, then saves.
  func saveAs() {
    let alert = NSAlert()
    alert.messageText = "Save Preset"
    alert.informativeText = "Save “\(plugin.name)”’s settings as a preset, to use in any song."
    let field = NSTextField(string: current ?? "")
    field.placeholderString = "Preset name"
    field.frame.size.width = 240
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    if savedPresets.contains(name), !confirmReplacing(name) { return }
    save(named: name)
  }

  private func confirmReplacing(_ name: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Replace “\(name)”?"
    alert.informativeText = "A preset with that name already exists."
    alert.addButton(withTitle: "Replace")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }
}
