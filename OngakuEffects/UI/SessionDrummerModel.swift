//
//  SessionDrummerModel.swift
//  OngakuEffects
//

import Foundation
import Observation
import OngakuCore

/// What the Session Drummer's window edits: the song's sections and how each is played.
/// Every edit goes to the drummer straight away, and to the window's undo and A/B as the
/// plug-in's custom settings.
@MainActor
@Observable
final class SessionDrummerModel {
  private(set) var song: DrummerSong
  var selectedSectionID: UUID?
  /// While the pad or a knob is dragged: the selected section's performance as it would be.
  var preview: DrummerPerformance?

  @ObservationIgnored let controller: SessionDrummerController
  @ObservationIgnored private weak var session: PluginSession?

  /// The usual section names, in the order they're offered.
  static let sectionNames = ArrangementSection.suggestedNames

  init(controller: SessionDrummerController, session: PluginSession) {
    self.controller = controller
    self.session = session
    song = controller.song
    selectedSectionID = song.sections.first?.id
    session.customState = PluginSession.CustomState(
      get: { [weak self] in self.flatMap { try? JSONEncoder().encode($0.song) } },
      set: { [weak self] data in
        guard let self, let data, let song = try? JSONDecoder().decode(DrummerSong.self, from: data) else { return }
        self.replace(with: song)
        self.controller.setSong(song)
      })
    controller.onSongReplaced = { [weak self] song in self?.replace(with: song) }
  }

  private func replace(with song: DrummerSong) {
    self.song = song
    if !song.sections.contains(where: { $0.id == selectedSectionID }) {
      selectedSectionID = song.sections.first?.id
    }
  }

  // MARK: - The selected section

  var selectedIndex: Int? { song.sections.firstIndex { $0.id == selectedSectionID } }

  var selectedSection: DrummerSong.Section? { selectedIndex.map { song.sections[$0] } }

  /// The performance shown: the one being dragged, else the selected section's.
  var shownPerformance: DrummerPerformance? { preview ?? selectedSection?.performance }

  /// Where the selected section starts in the song, in bars.
  var selectedStartBar: Int {
    guard let index = selectedIndex else { return 0 }
    return song.sections[..<index].reduce(0) { $0 + max(1, $1.bars) }
  }

  // MARK: - Editing

  /// Changes the song as one undoable step, and plays the change.
  func edit(_ change: (inout DrummerSong) -> Void) {
    let before = try? JSONEncoder().encode(song)
    var changed = song
    change(&changed)
    guard changed != song else { return }
    song = changed
    controller.setSong(changed)
    session?.noteCustomChange(before: before)
  }

  /// Changes the selected section's performance.
  func editSelected(_ change: (inout DrummerPerformance) -> Void) {
    guard let index = selectedIndex else { return }
    edit { song in
      change(&song.sections[index].performance)
      song.sections[index].performance.complexity = min(max(song.sections[index].performance.complexity, 0), 1)
      song.sections[index].performance.loudness = min(max(song.sections[index].performance.loudness, 0), 1)
      song.sections[index].performance.fills = min(max(song.sections[index].performance.fills, 0), 1)
      song.sections[index].performance.swing = min(max(song.sections[index].performance.swing, 0), 1)
    }
  }

  /// The drummer's style is the whole song's, as with a real drummer.
  func setStyle(_ style: DrummerPerformance.Style) {
    edit { song in
      for index in song.sections.indices {
        song.sections[index].performance.style = style
        song.sections[index].performance.swing = style.defaultSwing
      }
    }
  }

  var style: DrummerPerformance.Style { song.sections.first?.performance.style ?? .rock }

  /// The same settings, played another way.
  func newTake() {
    editSelected { $0.seed = UInt64.random(in: 1...UInt64.max) }
  }

  // MARK: - Sections

  /// Adds a section after the selected one, played to suit its name.
  func addSection(named name: String) {
    let style = style
    let at = (selectedIndex ?? song.sections.count - 1) + 1
    let section = DrummerSong.Section(
      name: name, bars: name == "Intro" || name == "Outro" || name == "Breakdown" ? 4 : 8,
      performance: .forSection(
        named: name, style: style, kit: .generalMIDI, isFirst: at == 0, isLast: false,
        seed: UInt64.random(in: 1...UInt64.max)))
    edit { song in
      song.sections.insert(section, at: min(at, song.sections.count))
      song.updateTransitions()
    }
    selectedSectionID = section.id
  }

  func duplicateSelected() {
    guard let index = selectedIndex else { return }
    var copy = song.sections[index]
    copy.id = UUID()
    edit { song in
      song.sections.insert(copy, at: index + 1)
      song.updateTransitions()
    }
    selectedSectionID = copy.id
  }

  func removeSelected() {
    guard let index = selectedIndex, song.sections.count > 1 else { return }
    edit { song in
      song.sections.remove(at: index)
      song.updateTransitions()
    }
    selectedSectionID = song.sections[min(index, song.sections.count - 1)].id
  }

  func moveSelected(by offset: Int) {
    guard let index = selectedIndex, song.sections.indices.contains(index + offset) else { return }
    edit { song in
      song.sections.swapAt(index, index + offset)
      song.updateTransitions()
    }
  }

  /// Renames the selected section, and plays it to suit its new name (keeping its style).
  func renameSelected(_ name: String) {
    guard let index = selectedIndex else { return }
    edit { song in
      let old = song.sections[index].performance
      song.sections[index].name = name
      var performance = DrummerPerformance.forSection(
        named: name, style: old.style, kit: old.kit, isFirst: index == 0, isLast: false, seed: old.seed)
      performance.playsKickAndSnare = old.playsKickAndSnare
      performance.playsCymbals = old.playsCymbals
      performance.playsPercussion = old.playsPercussion
      song.sections[index].performance = performance
      song.updateTransitions()
    }
  }

  func setBars(_ bars: Int) {
    guard let index = selectedIndex else { return }
    edit { $0.sections[index].bars = min(max(bars, DrummerSong.barsRange.lowerBound), DrummerSong.barsRange.upperBound) }
  }

  func setRepeats(_ repeats: Bool) {
    edit { song in
      song.repeats = repeats
      song.updateTransitions()
    }
  }

  // MARK: - MIDI out

  /// The song as a MIDI file in the plug-in's temporary folder, for dragging into the host
  /// or saving.
  func writeMIDIFile(tempo: Double) -> URL? {
    let data = song.midiFile(signature: controller.signature, bpm: tempo > 0 ? tempo : 120)
    let url = FileManager.default.temporaryDirectory.appending(path: "Session Drummer – \(style.title).mid")
    do {
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      return nil
    }
  }
}
