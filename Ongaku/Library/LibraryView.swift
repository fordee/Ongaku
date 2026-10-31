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
      // A lazy stack rather than an outline List: opening the current sound's category as the
      // view appears made the outline list crash inside SwiftUI.
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(categories) { category in
            let isOpen = isSearching || expanded.contains(category.id)
            CategoryHeader(name: category.name, isOpen: isOpen) {
              if expanded.contains(category.id) {
                expanded.remove(category.id)
              } else {
                expanded.insert(category.id)
              }
            }
            .disabled(isSearching)
            if isOpen {
              ForEach(category.items) { item in
                LibraryRow(item: item, isLoaded: item.isLoaded(on: track.channel.instrument)) {
                  model.setInstrument(item.makeSource(), for: track.id)
                }
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
      if let current = catalog.category(containing: track.channel.instrument) {
        expanded.insert(current)
      }
    }
    .onChange(of: track.id) {
      if let current = catalog.category(containing: model.selectedTrack?.channel.instrument) {
        expanded.insert(current)
      }
    }
  }

}

/// A category's name with a disclosure chevron. Search results are always open.
private struct CategoryHeader: View {
  let name: String
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
        Text(name).fontWeight(.medium)
        Spacer()
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
  }
}

private struct LibraryRow: View {
  let item: LibraryCatalog.Item
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
      .padding(.leading, 28)
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
