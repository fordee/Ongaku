//
//  LoopBrowserView.swift
//  Ongaku
//

import AppKit
import OngakuCore
import OngakuEngine
import SwiftUI

/// What the Loop Browser is showing; kept by the window so it survives hiding the browser.
@MainActor
@Observable
final class LoopBrowserState {
  /// Loops, of any family, key, tempo or genre.
  static let defaultFilter: SoundLibraryFilter = {
    var filter = SoundLibraryFilter()
    filter.kinds = [.loop]
    return filter
  }()

  var filter = LoopBrowserState.defaultFilter
  /// One library, or all of them.
  var libraryID: UUID?
  /// Only loops within 10% of the song's tempo at the playhead.
  var nearSongTempo = false
}

/// Logic's Loop Browser (O): the loops and samples in the sound libraries added in Settings,
/// filtered by instrument family, key, tempo and genre. Click a sound to hear it in the
/// song's tempo and key; drag it into the tracks area to add it. Tagged loops follow the
/// song's tempo and key there too.
struct LoopBrowserView: View {
  let model: ProjectWindowModel

  static let width: CGFloat = 310

  private var libraries: SoundLibraries { .shared }

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Loops", symbol: "infinity", closeTitle: "Hide Loop Browser") {
        model.isLoopBrowserVisible = false
      }
      if libraries.libraries.isEmpty {
        NoLibrariesView()
      } else {
        LoopBrowserContent(model: model, state: model.loopBrowser)
      }
    }
    .frame(width: Self.width)
    .background(Theme.panel)
    .onDisappear { LoopPreviewer.shared.stop() }
  }
}

/// Before any library has been added: what libraries are, and a button to add one.
private struct NoLibrariesView: View {
  var body: some View {
    VStack(spacing: 14) {
      Spacer()
      Image(systemName: "music.note.list")
        .font(.system(size: 34))
        .foregroundStyle(Theme.accent)
      Text("Add a Loop Library")
        .font(Theme.font(14, weight: .semibold))
      Text("Ongaku Studio’s built-in sounds are instruments; loops and samples come from libraries you add. Choose a folder of them — Logic Pro’s or GarageBand’s sound library, or any sample pack. Tagged loops follow your song’s tempo and key.")
        .font(Theme.font(11))
        .foregroundStyle(Theme.secondaryText)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      Button("Add Library…") { SoundLibraries.chooseFolders() }
        .controlSize(.large)
      Spacer()
    }
    .padding(20)
  }
}

private struct LoopBrowserContent: View {
  let model: ProjectWindowModel
  @Bindable var state: LoopBrowserState

  @State private var results: [Result] = []
  @State private var genres: [String] = []

  private var libraries: SoundLibraries { .shared }

  struct Result: Identifiable, Equatable {
    var libraryID: UUID
    var item: SoundLibraryItem
    var id: String { "\(libraryID.uuidString)/\(item.path)" }
  }

  /// Everything the results depend on, to recompute them when it changes.
  private struct Query: Equatable {
    var filter: SoundLibraryFilter
    var libraryID: UUID?
    var songTempo: Double?
    var revision: Int
  }

  private var songTempo: Double {
    model.project.tempoMap.tempo(at: model.engine.playheadPosition)
  }

  private var query: Query {
    Query(filter: state.filter, libraryID: state.libraryID, songTempo: state.nearSongTempo ? songTempo : nil, revision: libraries.revision)
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 8) {
        Picker("Show", selection: kinds) {
          Text("Loops").tag(KindChoice.loops)
          Text("One-Shots").tag(KindChoice.oneShots)
          Text("All").tag(KindChoice.all)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        TextField("Search Loops", text: $state.filter.text)
          .textFieldStyle(.roundedBorder)

        CategoryGrid(selection: $state.filter.categories)

        HStack(spacing: 6) {
          libraryMenu
          keyMenu
          tempoMenu
          genreMenu
        }
        .controlSize(.small)
      }
      .padding(10)

      HStack {
        Text(countText)
          .font(Theme.font(10))
          .foregroundStyle(Theme.secondaryText)
        if let scanning = scanningText {
          Text(scanning)
            .font(Theme.font(10))
            .foregroundStyle(Theme.tertiaryText)
        }
        Spacer()
        if state.filter != LoopBrowserState.defaultFilter || state.libraryID != nil || state.nearSongTempo {
          Button("Reset") {
            state.filter = LoopBrowserState.defaultFilter
            state.libraryID = nil
            state.nearSongTempo = false
          }
          .buttonStyle(.link)
          .font(Theme.font(10))
        }
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 4)

      Rectangle().fill(Theme.separator).frame(height: 1)

      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(results) { result in
            LoopRow(model: model, result: result)
          }
        }
      }
      .overlay {
        if results.isEmpty {
          Text(libraries.libraries.allSatisfy { $0.items.isEmpty } ? "The libraries are still being indexed." : "No sounds match.")
            .font(Theme.font(11))
            .foregroundStyle(Theme.secondaryText)
        }
      }
    }
    .task(id: query) {
      // Wait for typing to pause.
      if !results.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
      guard !Task.isCancelled else { return }
      update(for: query)
    }
  }

  private func update(for query: Query) {
    var filter = query.filter
    if let tempo = query.songTempo { filter.tempoRange = (tempo * 0.9)...(tempo * 1.1) }
    let words = filter.searchWords
    var found: [Result] = []
    var genreSet: Set<String> = []
    for library in libraries.libraries where query.libraryID == nil || library.id == query.libraryID {
      for (item, text) in zip(library.items, library.searchTexts) where item.kind != .instrument {
        if let genre = item.genre { genreSet.insert(genre) }
        if filter.matches(item, searchText: text, words: words) {
          found.append(Result(libraryID: library.id, item: item))
        }
      }
    }
    found.sort { $0.item.name.localizedStandardCompare($1.item.name) == .orderedAscending }
    results = found
    genres = genreSet.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  private var countText: String {
    results.count == 1 ? "1 sound" : "\(results.count.formatted()) sounds"
  }

  private var scanningText: String? {
    let scanning = libraries.libraries.contains { if case .scanning = $0.status { true } else { false } }
    return scanning ? "Indexing…" : nil
  }

  // MARK: - Filters

  private enum KindChoice: Hashable {
    case loops, oneShots, all
  }

  private var kinds: Binding<KindChoice> {
    Binding {
      switch state.filter.kinds {
      case [.loop]: .loops
      case [.oneShot]: .oneShots
      default: .all
      }
    } set: { choice in
      switch choice {
      case .loops: state.filter.kinds = [.loop]
      case .oneShots: state.filter.kinds = [.oneShot]
      case .all: state.filter.kinds = [.loop, .oneShot]
      }
    }
  }

  private var libraryMenu: some View {
    Menu {
      Picker("Library", selection: $state.libraryID) {
        Text("All Libraries").tag(UUID?.none)
        Divider()
        ForEach(libraries.libraries) { library in
          Text(library.name).tag(UUID?.some(library.id))
        }
      }
      .pickerStyle(.inline)
      Divider()
      Button("Add Library…") { SoundLibraries.chooseFolders() }
    } label: {
      Text(state.libraryID.flatMap { libraries.library(withID: $0)?.name } ?? "All")
    }
    .help("Library")
  }

  private var keyMenu: some View {
    Menu {
      Picker("Key", selection: $state.filter.keyTonic) {
        Text("Any Key").tag(Int?.none)
        Divider()
        ForEach(0..<12, id: \.self) { tonic in
          Text(KeySignature.noteNames[tonic]).tag(Int?.some(tonic))
        }
      }
      .pickerStyle(.inline)
    } label: {
      Text(state.filter.keyTonic.map { KeySignature.noteNames[$0] } ?? "Key")
    }
    .help("Key")
  }

  private var tempoMenu: some View {
    let ranges: [(String, ClosedRange<Double>)] = [
      ("Under 80", 0...80), ("80–100", 80...100), ("100–120", 100...120), ("120–140", 120...140), ("Over 140", 140...999),
    ]
    let label: String = if state.nearSongTempo {
      "≈ \(Int(songTempo.rounded()))"
    } else if let range = state.filter.tempoRange, let name = ranges.first(where: { $0.1 == range })?.0 {
      name
    } else {
      "Tempo"
    }
    return Menu {
      Button("Any Tempo") {
        state.filter.tempoRange = nil
        state.nearSongTempo = false
      }
      Button("Near the Song’s Tempo (\(Int(songTempo.rounded())) BPM)") {
        state.filter.tempoRange = nil
        state.nearSongTempo = true
      }
      Divider()
      ForEach(ranges, id: \.0) { name, range in
        Button("\(name) BPM") {
          state.nearSongTempo = false
          state.filter.tempoRange = range
        }
      }
    } label: {
      Text(label)
    }
    .help("Tempo")
  }

  private var genreMenu: some View {
    Menu {
      Picker("Genre", selection: $state.filter.genre) {
        Text("Any Genre").tag(String?.none)
        if !genres.isEmpty { Divider() }
        ForEach(genres, id: \.self) { genre in
          Text(genre).tag(String?.some(genre))
        }
      }
      .pickerStyle(.inline)
    } label: {
      Text(state.filter.genre ?? "Genre")
    }
    .help("Genre")
  }
}

/// Logic's grid of instrument buttons: click to show only that family, click more to add
/// them, click a lit one to turn it off.
private struct CategoryGrid: View {
  @Binding var selection: Set<SoundCategory>

  private let columns = [GridItem(.adaptive(minimum: 66), spacing: 4)]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 4) {
      ForEach(SoundCategory.allCases, id: \.self) { category in
        let isOn = selection.contains(category)
        Button {
          if isOn { selection.remove(category) } else { selection.insert(category) }
        } label: {
          HStack(spacing: 4) {
            Image(systemName: category.symbol)
              .font(Theme.font(9))
            Text(category == .percussion ? "Perc" : category.displayName)
              .font(Theme.font(10, weight: .medium))
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 4)
          .foregroundStyle(isOn ? Color.black : Theme.text)
          .background(
            RoundedRectangle(cornerRadius: 5)
              .fill(isOn ? category.color : Theme.raised)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 5)
              .strokeBorder(category.color.opacity(isOn ? 0 : 0.45), lineWidth: 1)
          )
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(category.displayName)
        .accessibilityLabel(category.displayName)
        .accessibilityAddTraits(isOn ? .isSelected : [])
      }
    }
  }
}

/// One sound: click to preview, drag into the tracks area to add.
private struct LoopRow: View {
  let model: ProjectWindowModel
  let result: LoopBrowserContent.Result

  @State private var isHovering = false

  private var item: SoundLibraryItem { result.item }
  private var url: URL? { SoundLibraries.shared.library(withID: result.libraryID)?.url(for: item) }
  private var isPlaying: Bool { LoopPreviewer.shared.isPlaying(item, in: result.libraryID) }

  var body: some View {
    HStack(spacing: 8) {
      ZStack {
        RoundedRectangle(cornerRadius: 4)
          .fill(badgeColor.opacity(isPlaying ? 1 : 0.85))
        Image(systemName: isPlaying ? "speaker.wave.2.fill" : badgeSymbol)
          .font(Theme.font(10, weight: .semibold))
          .foregroundStyle(.black.opacity(0.75))
          .symbolEffect(.variableColor.iterative, isActive: isPlaying)
      }
      .frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(item.name)
          .font(Theme.font(11))
          .lineLimit(1)
        Text(details)
          .font(Theme.font(9))
          .foregroundStyle(Theme.secondaryText)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      if let keyName = item.keyName {
        Text(keyName)
          .font(Theme.font(9, weight: .medium))
          .foregroundStyle(Theme.secondaryText)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(isPlaying ? Theme.accent.opacity(0.25) : isHovering ? Theme.raised.opacity(0.6) : .clear)
    .contentShape(.rect)
    .onHover { isHovering = $0 }
    .onTapGesture { preview() }
    .draggable(url ?? URL(fileURLWithPath: "/")) {
      Label(item.name, systemImage: badgeSymbol)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(badgeColor))
        .foregroundStyle(.black)
    }
    .contextMenu {
      Button("Preview") { preview() }
      Button("Add at Playhead") { addAtPlayhead() }
      Divider()
      Button("Show in Finder") {
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
    }
    .help(item.path)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isButton)
    .accessibilityHint("Click to hear it; drag it into the tracks area to add it.")
  }

  /// Blue for audio loops and green for loops with MIDI, as in Logic; grey for one-shots.
  private var badgeColor: Color {
    switch item.kind {
    case .loop: item.hasMIDI ? Theme.play : Theme.accent
    case .oneShot, .instrument, .impulseResponse: Color(hex: 0xA0A0A6)
    }
  }

  private var badgeSymbol: String {
    switch item.kind {
    case .loop: item.hasMIDI ? "pianokeys" : "waveform"
    case .oneShot, .instrument, .impulseResponse: "dot.radiowaves.right"
    }
  }

  private var details: String {
    var parts: [String] = []
    if item.kind == .loop {
      if let beats = item.beats { parts.append(beats == 1 ? "1 beat" : "\(beats) beats") }
      if let tempo = item.tempo { parts.append("\(Int(tempo.rounded())) BPM") }
    } else if let duration = item.duration {
      parts.append(duration < 10 ? String(format: "%.1f s", duration) : "\(Int(duration.rounded())) s")
    }
    if let category = item.category { parts.append(category.displayName) }
    if let genre = item.genre { parts.append(genre) }
    return parts.joined(separator: " · ")
  }

  private func preview() {
    guard let url else { return }
    LoopPreviewer.shared.toggle(item, at: url, in: result.libraryID, project: model.project, position: model.engine.playheadPosition)
  }

  private func addAtPlayhead() {
    guard let url else { return }
    LoopPreviewer.shared.stop()
    let position = model.snap(model.engine.playheadPosition)
    Task { await model.importAudio([url], at: position, onTrack: model.selectedTrackID) }
  }
}

extension SoundCategory {
  var symbol: String {
    switch self {
    case .drums: "circle.circle"
    case .percussion: "hands.clap"
    case .bass: "guitars"
    case .guitar: "guitars.fill"
    case .piano: "pianokeys"
    case .keys: "pianokeys.inverse"
    case .synth: "waveform.path"
    case .strings: "music.quarternote.3"
    case .brass: "megaphone"
    case .woodwind: "wind"
    case .mallets: "bell"
    case .vocals: "music.mic"
    case .fx: "sparkles"
    case .other: "ellipsis"
    }
  }

  /// Each family's colour on the Loop Browser's buttons.
  var color: Color {
    switch self {
    case .drums: Color(hex: 0xE8C14C)
    case .percussion: Color(hex: 0xE89A4C)
    case .bass: Color(hex: 0xE8734C)
    case .guitar: Color(hex: 0xD9A066)
    case .piano: Color(hex: 0x7FB8F0)
    case .keys: Color(hex: 0x6FA3E8)
    case .synth: Color(hex: 0xA98CF0)
    case .strings: Color(hex: 0xE06C8C)
    case .brass: Color(hex: 0xE8B34C)
    case .woodwind: Color(hex: 0x8CD9A0)
    case .mallets: Color(hex: 0x6CD9D0)
    case .vocals: Color(hex: 0xF08CC8)
    case .fx: Color(hex: 0x9CE86C)
    case .other: Color(hex: 0xA0A0A6)
    }
  }
}

#Preview("Loop Browser") {
  func loop(_ path: String, _ beats: Int, _ tempo: Double, _ key: Int?, _ category: SoundCategory, genre: String, midi: Bool = false) -> SoundLibraryItem {
    SoundLibraryItem(
      path: path, kind: .loop, duration: Double(beats) * 60 / tempo, beats: beats, tempo: tempo, keyTonic: key,
      keyMode: key == nil ? nil : .minor, category: category, genre: genre, hasMIDI: midi)
  }
  SoundLibraries.shared = SoundLibraries(previewItems: [
    "Sample Pack": [
      loop("Drums/Boom Bap Beat 01.wav", 8, 90, nil, .drums, genre: "Hip Hop"),
      loop("Drums/Dusty Break.wav", 16, 94, nil, .drums, genre: "Hip Hop"),
      loop("Bass/Rubber Bass.wav", 8, 92, 9, .bass, genre: "Funk"),
      loop("Keys/Late Night Rhodes.caf", 16, 88, 2, .keys, genre: "Soul", midi: true),
      loop("Strings/Silver Strings.caf", 8, 100, 4, .strings, genre: "Cinematic", midi: true),
      loop("Synth/Neon Arp.wav", 4, 124, 7, .synth, genre: "Electronic"),
      loop("Vocals/Ooh Chops.wav", 8, 120, 0, .vocals, genre: "Pop"),
      SoundLibraryItem(path: "One Shots/Kick Thump.wav", kind: .oneShot, duration: 0.4, category: .drums),
    ],
  ])
  let model = ProjectWindowModel(document: OngakuDocument(project: .previewSong))
  return LoopBrowserView(model: model).frame(height: 700)
}

#Preview("No Libraries") {
  SoundLibraries.shared = SoundLibraries(previewItems: [:])
  let model = ProjectWindowModel(document: OngakuDocument(project: .previewSong))
  return LoopBrowserView(model: model).frame(height: 500)
}
