//
//  LibraryCatalog.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// The sounds the Library offers for a software instrument track, grouped like Logic's
/// Library: General MIDI families, drum kits and installed Audio Unit instruments.
struct LibraryCatalog {
  /// Categories and items share one outline list, so every ID must be unique across both:
  /// a repeated ID makes the list crash when a category opens.
  struct Category: Identifiable, Equatable {
    var id: String
    var name: String
    var items: [Item]
  }

  struct Item: Identifiable, Equatable {
    enum Sound: Equatable {
      case builtIn(InstrumentSource)
      case audioUnit(InstrumentLibrary.Entry)
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
      default:
        false
      }
    }
  }

  let categories: [Category]

  init(audioUnits: [InstrumentLibrary.Entry]) {
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
    self.categories = categories
  }

  /// The categories with items whose name (or category name) contains every word of
  /// `query`, ignoring case and accents. An empty query keeps everything.
  func filtered(by query: String) -> [Category] {
    let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return categories }
    return categories.compactMap { category in
      let items = category.items.filter { item in
        words.allSatisfy { word in
          item.name.localizedStandardContains(word) || category.name.localizedStandardContains(word)
        }
      }
      return items.isEmpty ? nil : Category(id: category.id, name: category.name, items: items)
    }
  }

  /// The category containing the track's current instrument, to open it in the list.
  func category(containing source: InstrumentSource?) -> Category.ID? {
    categories.first { $0.items.contains { $0.isLoaded(on: source) } }?.id
  }
}
