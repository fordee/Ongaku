//
//  LibraryAndShortcutTests.swift
//  OngakuTests
//

import AppKit
import Foundation
import OngakuCore
@testable import OngakuEngine
@testable import Ongaku
import Testing

@MainActor
struct LibraryAndShortcutTests {
  private let synth = InstrumentLibrary.Entry(
    manufacturer: "Acme", name: "Big Synth", componentType: 0x61756D75, componentSubType: 1, componentManufacturer: 2)

  // MARK: - Library catalog

  @Test func catalogListsGeneralMIDIKitsAndAudioUnits() {
    let catalog = LibraryCatalog(audioUnits: [synth])
    #expect(catalog.categories.count == GeneralMIDI.families.count + 3)
    // Ongaku's own instruments come first, then General MIDI.
    #expect(catalog.categories.first?.name == "Ongaku Instruments")
    #expect(catalog.categories.first?.items.first?.name == "Retro Synth")
    #expect(catalog.categories[1].name == "Piano")
    #expect(catalog.categories[1].items.first?.name == "Acoustic Grand Piano")
    #expect(catalog.categories.first { $0.id == "drums" }?.items.count == GeneralMIDI.drumKits.count)
    #expect(catalog.categories.last?.name == "Acme")
  }

  /// The Library's outline list crashes on repeated IDs.
  @Test func everyCategoryAndItemHasAUniqueID() {
    let catalog = LibraryCatalog(audioUnits: [synth])
    let ids = catalog.categories.map(\.id) + catalog.categories.flatMap(\.items).map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test func searchMatchesEveryWordInNamesOrCategories() {
    let catalog = LibraryCatalog(audioUnits: [synth])
    let pads = catalog.filtered(by: "warm pad")
    #expect(pads.flatMap(\.items).map(\.name) == ["Warm Pad"])
    // "bass" matches the Bass family and other names containing it.
    let bass = catalog.filtered(by: "BASS").flatMap(\.items).map(\.name)
    #expect(bass.contains("Fretless Bass"))
    #expect(bass.contains("Bassoon"))
    #expect(catalog.filtered(by: "808").flatMap(\.items).map(\.name) == ["TR-808 Kit"])
    #expect(catalog.filtered(by: "zzz").isEmpty)
    #expect(catalog.filtered(by: "  ") == catalog.categories)
  }

  @Test func theLoadedSoundIsRecognized() throws {
    let catalog = LibraryCatalog(audioUnits: [synth])
    let rhodes = try #require(catalog.categories.flatMap(\.items).first { $0.name == "Electric Piano 1" })
    #expect(rhodes.isLoaded(on: .generalMIDI(program: 4)))
    #expect(!rhodes.isLoaded(on: .generalMIDI(program: 5)))
    #expect(catalog.category(containing: .generalMIDIPercussion(kit: 25)) == "drums")

    // A plug-in is the same sound whatever its settings and reference ID.
    let synthItem = try #require(catalog.categories.last?.items.first)
    let source = synthItem.makeSource()
    #expect(synthItem.isLoaded(on: source))
    if case .audioUnit(let first) = source, case .audioUnit(let second) = synthItem.makeSource() {
      #expect(first.id != second.id, "Each track gets its own plug-in reference")
    }
  }

  @Test func drumKitsHaveNames() {
    #expect(InstrumentSource.generalMIDIPercussion(kit: 25).displayName == "TR-808 Kit")
    #expect(InstrumentSource.generalMIDIPercussion(kit: 0).displayName == "Standard Kit")
    #expect(InstrumentSource.generalMIDIPercussion(kit: 99).displayName == "Drum Kit")
  }

  // MARK: - Moving by bars

  private func makeWindow() -> ProjectWindowModel {
    ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [Track(name: "Audio 1", kind: .audio)])))
  }

  @Test func periodAndCommaMoveByBars() {
    let window = makeWindow()
    defer { window.engine.shutDown() }
    let bar = Tick.quarterNotes(4)
    window.moveByBars(1)
    #expect(window.engine.playheadPosition == bar)
    window.moveByBars(1)
    #expect(window.engine.playheadPosition == bar * 2)
    window.moveByBars(-1)
    #expect(window.engine.playheadPosition == bar)
    window.moveByBars(-1)
    window.moveByBars(-1)
    #expect(window.engine.playheadPosition == .zero, "Stops at the start")
  }

  @Test func commaInsideABarGoesToItsStart() {
    let window = makeWindow()
    defer { window.engine.shutDown() }
    window.engine.locate(to: .quarterNotes(6))  // bar 2, beat 3
    window.moveByBars(-1)
    #expect(window.engine.playheadPosition == .quarterNotes(4))
  }

  @Test func libraryToggles() {
    let window = makeWindow()
    defer { window.engine.shutDown() }
    #expect(!window.isLibraryVisible)
    window.toggleLibrary()
    #expect(window.isLibraryVisible)
    #expect(window.selectedTrack?.name == "Audio 1")
  }

  /// SwiftUI's menus and the key monitor can both see a single-key shortcut; only the first
  /// to claim a key press acts on it, so G doesn't show and hide the global tracks at once.
  @Test func eachKeyPressIsActedOnOnce() throws {
    func press(_ key: String, at time: TimeInterval) throws -> NSEvent {
      try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: time, windowNumber: 0, context: nil,
        characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 5))
    }
    let monitor = KeyCommandMonitor.shared
    let first = try press("g", at: 1_000)
    #expect(monitor.claim(first))
    #expect(!monitor.claim(first), "The second path leaves the same press alone")
    #expect(monitor.claim(try press("g", at: 1_000.2)), "The next press is a new one")
  }
}
