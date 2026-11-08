//
//  LibraryView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// Logic's Library (Y): the sounds for the selected software instrument track. Clicking one
/// loads it straight away, so you can play through sounds on a MIDI keyboard.
struct LibraryView: View {
  let model: ProjectWindowModel

  @State private var query = ""
  @State private var expanded: Set<LibraryCatalog.Category.ID> = []

  static let width: CGFloat = 240

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Library", symbol: "books.vertical", closeTitle: "Hide Library") {
        model.isLibraryVisible = false
      }

      if let track = model.selectedTrack, track.kind == .softwareInstrument {
        content(for: track)
      } else {
        ContentUnavailableView(
          "No Instrument Track Selected", systemImage: "pianokeys",
          description: Text("Select a software instrument track to choose its sound."))
          .foregroundStyle(Theme.secondaryText)
      }
    }
    .frame(width: Self.width)
    .background(Theme.panel)
  }

  private func content(for track: Track) -> some View {
    let catalog = model.libraryCatalog
    let categories = catalog.filtered(by: query)
    let isSearching = !query.trimmingCharacters(in: .whitespaces).isEmpty
    return VStack(spacing: 0) {
      Text(track.name)
        .font(Theme.font(12, weight: .semibold))
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 8)
      TextField("Search", text: $query)
        .textFieldStyle(.roundedBorder)
        .padding(8)
      // A lazy stack of the open folders' rows rather than an outline List: opening the
      // current sound's category as the view appears made the outline list crash inside
      // SwiftUI.
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(rows(categories, isSearching: isSearching)) { row in
            switch row.kind {
            case .folder(let category, let isOpen):
              CategoryHeader(name: category.name, depth: row.depth, isOpen: isOpen) {
                if expanded.contains(category.id) {
                  expanded.remove(category.id)
                } else {
                  expanded.insert(category.id)
                }
              }
              .disabled(isSearching)
            case .sound(let item):
              LibraryRow(item: item, depth: row.depth, isLoaded: item.isLoaded(on: track.channel.instrument)) {
                model.setInstrument(item.makeSource(), for: track.id)
              }
            }
          }
          if categories.isEmpty {
            Text("No sounds match “\(query)”.")
              .foregroundStyle(.secondary)
              .padding(10)
          }
        }
        .padding(.bottom, 8)
      }
    }
    .onAppear {
      expanded.formUnion(catalog.categoryPath(containing: track.channel.instrument))
    }
    .onChange(of: track.id) {
      expanded.formUnion(catalog.categoryPath(containing: model.selectedTrack?.channel.instrument))
    }
  }

  /// A row of the list: a folder's name, or a sound.
  fileprivate struct Row: Identifiable {
    enum Kind {
      case folder(LibraryCatalog.Category, isOpen: Bool)
      case sound(LibraryCatalog.Item)
    }

    var id: String
    var depth: Int
    var kind: Kind
  }

  /// The rows to show: every folder at the top, and inside each open one (all of them while
  /// searching) its folders, then its sounds.
  private func rows(_ categories: [LibraryCatalog.Category], isSearching: Bool) -> [Row] {
    var rows: [Row] = []
    func add(_ category: LibraryCatalog.Category, depth: Int) {
      let isOpen = isSearching || expanded.contains(category.id)
      rows.append(Row(id: "folder-\(category.id)", depth: depth, kind: .folder(category, isOpen: isOpen)))
      guard isOpen else { return }
      for child in category.children { add(child, depth: depth + 1) }
      rows += category.items.map { Row(id: "sound-\($0.id)", depth: depth + 1, kind: .sound($0)) }
    }
    for category in categories { add(category, depth: 0) }
    return rows
  }
}

/// A category's name with a disclosure chevron. Search results are always open.
private struct CategoryHeader: View {
  let name: String
  var depth = 0
  let isOpen: Bool
  let toggle: () -> Void

  var body: some View {
    Button {
      toggle()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(Theme.font(9, weight: .semibold))
          .foregroundStyle(Theme.tertiaryText)
          .rotationEffect(.degrees(isOpen ? 90 : 0))
          .frame(width: 12)
        Text(name).fontWeight(.medium).lineLimit(1)
        Spacer()
      }
      .padding(.leading, 10 + CGFloat(depth) * 14)
      .padding(.trailing, 10)
      .padding(.vertical, 5)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
  }
}

private struct LibraryRow: View {
  let item: LibraryCatalog.Item
  var depth = 1
  let isLoaded: Bool
  let choose: () -> Void

  var body: some View {
    Button {
      choose()
    } label: {
      HStack {
        Text(item.name).lineLimit(1)
        Spacer()
        if isLoaded {
          Image(systemName: "checkmark").foregroundStyle(Theme.accent)
        }
      }
      .padding(.leading, 14 + CGFloat(depth) * 14)
      .padding(.trailing, 10)
      .padding(.vertical, 4)
      .background(isLoaded ? Theme.accent.opacity(0.28) : .clear)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isLoaded ? .isSelected : [])
  }
}

#Preview {
  var keys = Track(name: "Inst 1", kind: .softwareInstrument)
  keys.channel.instrument = .generalMIDI(program: 4)
  let model = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [keys])))
  return LibraryView(model: model).frame(height: 600)
}

#Preview("With a Sound Library") {
  let bank = [
    SoundBankPreset(name: "Bright Grand", program: 0, bank: 0, isPercussion: false),
    SoundBankPreset(name: "Tine Electric", program: 4, bank: 0, isPercussion: false),
    SoundBankPreset(name: "Vintage Kit", program: 0, bank: 128, isPercussion: true),
  ]
  SoundLibraries.shared = SoundLibraries(previewItems: [
    "Studio Sounds": [
      SoundLibraryItem(path: "Keys/Velvet Rhodes.exs", kind: .instrument, category: .keys),
      SoundLibraryItem(path: "Keys/Vintage/Wurly 200.exs", kind: .instrument, category: .keys),
      SoundLibraryItem(path: "Keys/Vintage/Clavinet D6.exs", kind: .instrument, category: .keys),
      SoundLibraryItem(path: "Strings/Chamber Strings.exs", kind: .instrument, category: .strings),
      SoundLibraryItem(path: "Banks/Studio Bank.sf2", kind: .instrument, presets: bank),
    ],
  ])
  var keys = Track(name: "Keys", kind: .softwareInstrument)
  keys.channel.instrument = .sampler(SamplerInstrument(libraryID: nil, libraryName: "Studio Sounds", path: "Keys/Velvet Rhodes.exs"))
  let model = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [keys])))
  model.selectedTrackID = keys.id
  return LibraryView(model: model).frame(height: 700)
}
