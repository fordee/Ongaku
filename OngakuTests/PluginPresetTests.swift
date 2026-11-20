//
//  PluginPresetTests.swift
//  OngakuTests
//

import AudioToolbox
import Foundation
@testable import Ongaku
import OngakuCore
@testable import OngakuEngine
import Testing

/// Presets for plug-ins that don't keep their own: saved in Ongaku, chosen from the
/// plug-in window's title bar.
@MainActor
@Suite(.serialized)
struct PluginPresetTests {
  private let folder = FileManager.default.temporaryDirectory.appending(path: "PluginPresetTests-\(UUID().uuidString)")

  @Test func presetsAreSavedListedAndDeletedPerPlugIn() throws {
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = PluginPresetStore(folder: folder)
    let reverb = BuiltInEffect.reverb.makeReference()
    let delay = BuiltInEffect.delay.makeReference()
    try store.save(Data([1]), named: "Big Room", for: reverb)
    try store.save(Data([2]), named: "a/b: .hidden?", for: reverb)
    try store.save(Data([3]), named: "Slap", for: delay)
    #expect(store.names(for: reverb) == ["a-b- .hidden?", "Big Room"].sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    #expect(store.names(for: delay) == ["Slap"], "Each plug-in has its own")
    #expect(store.state(named: "Big Room", for: reverb) == Data([1]))

    try store.save(Data([4]), named: "Big Room", for: reverb)
    #expect(store.state(named: "Big Room", for: reverb) == Data([4]), "Saving again replaces it")
    try store.delete(named: "Big Room", for: reverb)
    #expect(!store.names(for: reverb).contains("Big Room"))
  }

  /// On a loaded plug-in: a factory preset is chosen, settings are saved as a preset and
  /// come back when it's chosen again.
  @Test func presetsSetTheLoadedPlugIn() async throws {
    defer { try? FileManager.default.removeItem(at: folder) }
    let track = Track(name: "Audio 1", kind: .audio)
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [track])))
    defer { window.engine.shutDown() }
    let reverb = BuiltInEffect.reverb.makeReference()
    window.addInsert(reverb, to: track.id)
    window.projectDidChange()
    let plugin = try #require(window.project.track(withID: track.id)?.channel.inserts.first)
    #expect(await window.waitForPlugin(plugin.id, on: track.id), "The reverb loads")

    let presets = PluginPresets(plugin: plugin, trackID: track.id, model: window, store: PluginPresetStore(folder: folder))
    let factory = try #require(presets.factoryPresets.last, "Apple's reverb has factory presets")
    presets.chooseFactoryPreset(factory)
    #expect(presets.current == factory)

    // Apple's reverb: parameter 0 is the wet/dry mix.
    func setMix(_ value: AUValue) {
      window.withPluginAudioUnit(plugin.id, on: track.id) { $0.parameterTree?.parameter(withAddress: 0)?.value = value }
    }
    func mix() -> AUValue? {
      var value: AUValue?
      window.withPluginAudioUnit(plugin.id, on: track.id) { value = $0.parameterTree?.parameter(withAddress: 0)?.value }
      return value
    }
    setMix(12)
    presets.save(named: "Mostly Dry")
    #expect(presets.savedPresets == ["Mostly Dry"])
    setMix(80)
    presets.chooseSavedPreset("Mostly Dry")
    #expect(mix().map { abs($0 - 12) < 0.01 } == true, "Mix is \(String(describing: mix()))")
    #expect(presets.current == "Mostly Dry")

    presets.delete("Mostly Dry")
    #expect(presets.savedPresets.isEmpty)
    #expect(presets.current == nil)
  }
}
