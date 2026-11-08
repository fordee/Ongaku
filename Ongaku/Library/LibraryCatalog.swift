//
//  LibraryCatalog.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// The sounds the Library offers for a software instrument track, grouped like Logic's
/// Library: Ongaku's instruments, General MIDI families, drum kits, installed Audio Unit
/// instruments, then each sound library added in Settings as a folder holding its own
/// folders, as they are on disk (a SoundFont or DLS bank with several presets is a folder
/// of its presets).
struct LibraryCatalog {
  /// Categories and items share one outline list, so every ID must be unique across both:
  /// a repeated ID makes the list crash when a category opens.
  struct Category: Identifiable, Equatable {
    var id: String
    var name: String
    /// Folders inside it, listed before its sounds.
    var children: [Category] = []
    var items: [Item]

    /// Its sounds and those in every folder inside it.
    var allItems: [Item] {
      items + children.flatMap(\.allItems)
    }
  }

  struct Item: Identifiable, Equatable {
    enum Sound: Equatable {
      case builtIn(InstrumentSource)
      case audioUnit(InstrumentLibrary.Entry)
      case sampler(SamplerInstrument)
    }

    var id: String
    var name: String
    var sound: Sound

    /// What a track gets when this item is chosen. Audio Units get a fresh reference each
    /// time, since each track keeps its own plug-in settings.
    func makeSource() -> InstrumentSource {
      switch sound {
      case .builtIn(let source): source
      case .audioUnit(let entry): .audioUnit(entry.makeReference())
      case .sampler(let instrument): .sampler(instrument)
      }
    }

    /// Whether this is the instrument a track already has.
    func isLoaded(on source: InstrumentSource?) -> Bool {
      switch (sound, source) {
      case (.builtIn(let mine), let theirs?):
        mine == theirs
      case (.audioUnit(let entry), .audioUnit(let plugin)?):
        entry.componentType == plugin.componentType && entry.componentSubType == plugin.componentSubType
          && entry.componentManufacturer == plugin.componentManufacturer
      case (.sampler(let mine), .sampler(let theirs)?):
        // The same file and preset, from this library or one of the same name.
        mine.path == theirs.path && mine.preset == theirs.preset
          && (mine.libraryID == theirs.libraryID || mine.libraryName == theirs.libraryName)
      default:
        false
      }
    }
  }

  let categories: [Category]

  init(audioUnits: [InstrumentLibrary.Entry], libraries: [SoundLibraries.Library] = []) {
    // Ongaku's own instruments first.
    var categories = [Category(
      id: "ongaku", name: "Ongaku Instruments",
      items: InstrumentLibrary.ongakuInstruments().map { Item(id: "ongaku-\($0.id)", name: $0.name, sound: .audioUnit($0)) })]
    categories += GeneralMIDI.families.map { family in
      Category(
        id: "family-\(family.firstProgram)", name: family.name,
        items: family.programs.map { program in
          Item(id: "gm-\(program)", name: GeneralMIDI.programName(program), sound: .builtIn(.generalMIDI(program: program)))
        })
    }
    categories.append(Category(
      id: "drums", name: "Drum Kits",
      items: GeneralMIDI.drumKits.map { kit in
        Item(id: "kit-\(kit.kit)", name: kit.name, sound: .builtIn(.generalMIDIPercussion(kit: kit.kit)))
      }))
    // One category per manufacturer, in the order the library sorted them.
    var manufacturers: [String] = []
    var byManufacturer: [String: [Item]] = [:]
    for entry in audioUnits {
      if byManufacturer[entry.manufacturer] == nil { manufacturers.append(entry.manufacturer) }
      byManufacturer[entry.manufacturer, default: []].append(Item(id: "au-\(entry.id)", name: entry.name, sound: .audioUnit(entry)))
    }
    categories += manufacturers.map { Category(id: "manufacturer-\($0)", name: $0, items: byManufacturer[$0] ?? []) }
    categories += libraries.flatMap(Self.categories(in:))
    self.categories = categories
  }

  /// A library's playable instruments as a folder of the library's own folders, in the
  /// library's order (folders first, then the sounds beside them).
  static func categories(in library: SoundLibraries.Library) -> [Category] {
    final class Folder {
      let id: String
      let name: String
      var folders: [Folder] = []
      var byName: [String: Folder] = [:]
      var items: [Item] = []

      init(id: String, name: String) {
        self.id = id
        self.name = name
      }

      func folder(_ name: String) -> Folder {
        if let existing = byName[name] { return existing }
        let folder = Folder(id: "\(id)/\(name)", name: name)
        byName[name] = folder
        folders.append(folder)
        return folder
      }

      /// Without folders that hold no sounds.
      var category: Category? {
        let children = folders.compactMap(\.category)
        guard !children.isEmpty || !items.isEmpty else { return nil }
        return Category(id: id, name: name, children: children, items: items)
      }
    }

    let root = Folder(id: "library-\(library.id)", name: library.name)
    func instrument(_ path: String, _ preset: SoundBankPreset? = nil) -> SamplerInstrument {
      SamplerInstrument(libraryID: library.id, libraryName: library.name, path: path, preset: preset)
    }
    for item in library.items where item.kind == .instrument && SamplerInstrument.isPlayable(item.path) {
      let folder = item.folders.reduce(root) { $0.folder($1) }
      if item.presets.count > 1 {
        // A bank of many sounds is a folder of them.
        let bank = folder.folder(item.name)
        bank.items += item.presets.map { preset in
          Item(
            id: "preset-\(library.id)-\(item.path)-\(preset.bank)-\(preset.program)-\(preset.isPercussion)",
            name: preset.name, sound: .sampler(instrument(item.path, preset)))
        }
      } else {
        folder.items.append(Item(
          id: "sampler-\(library.id)-\(item.path)", name: item.presets.first?.name ?? item.name,
          sound: .sampler(instrument(item.path, item.presets.first))))
      }
    }
    return root.category.map { [$0] } ?? []
  }

  /// The categories with items whose name (or the name of a folder they're in) contains
  /// every word of `query`, ignoring case and accents, keeping the folders down to them. An
  /// empty query keeps everything.
  func filtered(by query: String) -> [Category] {
    let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return categories }
    return categories.compactMap { Self.filter($0, words: words, folderNames: []) }
  }

  private static func filter(_ category: Category, words: [String], folderNames: [String]) -> Category? {
    let names = folderNames + [category.name]
    let items = category.items.filter { item in
      words.allSatisfy { word in
        item.name.localizedStandardContains(word) || names.contains { $0.localizedStandardContains(word) }
      }
    }
    let children = category.children.compactMap { filter($0, words: words, folderNames: names) }
    guard !items.isEmpty || !children.isEmpty else { return nil }
    return Category(id: category.id, name: category.name, children: children, items: items)
  }

  /// The folders down to the track's current instrument, outermost first, to open them.
  func categoryPath(containing source: InstrumentSource?) -> [Category.ID] {
    func path(in category: Category) -> [Category.ID]? {
      if category.items.contains(where: { $0.isLoaded(on: source) }) { return [category.id] }
      for child in category.children {
        if let below = path(in: child) { return [category.id] + below }
      }
      return nil
    }
    for category in categories {
      if let found = path(in: category) { return found }
    }
    return []
  }

  /// The folder directly holding the track's current instrument.
  func category(containing source: InstrumentSource?) -> Category.ID? {
    categoryPath(containing: source).last
  }
}
