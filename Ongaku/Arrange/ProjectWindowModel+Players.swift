//
//  ProjectWindowModel+Players.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// A chord being typed on the Chord track: a new one at a position, or one being changed.
struct ChordEdit: Identifiable, Equatable {
  let id = UUID()
  var position: Tick
  var changeID: UUID?
}

/// The Chord track and the session players (Bass Player, Keyboard Player) that follow it.
extension ProjectWindowModel {
  // MARK: - The Chord track

  /// The own chords of the key at `position`, as suggestions when adding one (I ii iii IV
  /// V vi vii° in major).
  func diatonicChords(at position: Tick) -> [Chord] {
    let key = project.key(at: position)
    let steps: [(Int, Chord.Quality)] = key.mode == .major
      ? [(0, .major), (2, .minor), (4, .minor), (5, .major), (7, .major), (9, .minor), (11, .diminished)]
      : [(0, .minor), (2, .diminished), (3, .major), (5, .minor), (7, .minor), (8, .major), (10, .major)]
    return steps.map { Chord(root: key.tonic + $0.0, quality: $0.1) }
  }

  /// Puts a chord at a position (snapped; see `snapChord`), from its name. Returns false if
  /// the name isn't a chord.
  @discardableResult
  func setChord(named name: String, at position: Tick) -> Bool {
    guard let chord = Chord(name: name) else {
      errorMessage = "“\(name)” isn't a chord name Ongaku Studio knows. Try something like C, Am7, F♯m or G/B."
      return false
    }
    perform(SetChord(chord, at: snapChord(position)))
    isGlobalTracksVisible = true
    return true
  }

  /// Changes a chord on the track to another, keeping its place.
  @discardableResult
  func changeChord(_ id: UUID, toName name: String) -> Bool {
    guard let change = project.chords.first(where: { $0.id == id }) else { return false }
    return setChord(named: name, at: change.position)
  }

  func moveChord(_ id: UUID, to position: Tick) {
    perform(MoveChord(id, to: snapChord(position)))
  }

  func deleteChord(_ id: UUID) {
    perform(DeleteChords([id]))
  }

  /// Clicking a chord selects it, so Delete removes it (until something else is clicked).
  func selectChord(_ id: UUID) {
    selectedChordID = id
    activeEditingArea = .chordTrack
  }

  /// Fills the Chord track over a MIDI region with the chords in its notes.
  func detectChords(from regionID: Region.ID) {
    perform(DetectChords(from: regionID))
    isGlobalTracksVisible = true
  }

  /// Whether a region's notes can be read for chords: played MIDI, not drums or a part
  /// that's generated (a player's would only give back the chords it follows).
  func canDetectChords(in region: Region) -> Bool {
    guard case .midi = region.content, region.player == nil, region.drummer == nil, region.pattern == nil,
      let location = project.regionLocation(for: region.id)
    else { return false }
    return !playsDrums(project.tracks[location.track])
  }

  /// The selected regions Track › Detect Chords reads.
  var chordDetectionRegionIDs: [Region.ID] {
    project.tracks.flatMap(\.regions).filter { selectedRegionIDs.contains($0.id) && canDetectChords(in: $0) }.map(\.id)
  }

  /// Track › Detect Chords: fills the Chord track from the selected MIDI regions, as one
  /// undoable step.
  func detectChordsInSelection() {
    let regionIDs = chordDetectionRegionIDs
    guard !regionIDs.isEmpty else { return }
    perform(CompositeCommand("Detect Chords", commands: regionIDs.map { DetectChords(from: $0) }))
    isGlobalTracksVisible = true
  }

  // MARK: - Progressions

  /// The progressions that suit the key at `position`.
  func progressions(at position: Tick) -> [ChordProgression] { ChordProgression.library(for: project.key(at: position)) }

  /// A progression's chords in the key at `position`, for menus: "C G Am F".
  func chordNames(_ progression: ChordProgression, at position: Tick) -> String {
    let chords = progression.chords(in: project.key(at: position))
    let names = chords.prefix(8).map(\.description).joined(separator: " ")
    return chords.count > 8 ? names + " …" : names
  }

  /// Where a progression goes from a position: across the arrangement section there, else
  /// eight bars from the bar.
  func progressionRange(at position: Tick) -> (name: String, start: Tick, end: Tick) {
    if let section = project.arrangement.first(where: { $0.range.contains(position) }) {
      return (section.name, section.start, section.end)
    }
    let bar = project.tempoMap.bar(containing: max(.zero, position))
    return ("8 Bars", bar.start, project.tempoMap.tickPosition(ofBarIndex: bar.index + 8))
  }

  /// Puts a progression on the Chord track from `start` to `end`, replacing the chords there,
  /// in the key at `start`.
  func fillChords(with progression: ChordProgression, from start: Tick, to end: Tick) {
    let changes = progression.changes(in: project.key(at: start), from: start, to: end, tempoMap: project.tempoMap)
    perform(SetChords(changes, from: start, to: end, actionName: "\(progression.name) Progression"))
    isGlobalTracksVisible = true
  }

  /// Chords for each section of the song, in the key the section starts in: a progression
  /// for the verses, another for the choruses and the bridge, the song coming home to the
  /// key's chord at the end.
  func songChordCommands(song: Int) -> [any EditCommand] {
    let sections = drummerSections()
    return sections.enumerated().map { index, section in
      let key = project.key(at: section.start)
      let progression = ChordProgression.forSection(named: section.name, key: key, song: song)
      let changes = progression.changes(
        in: key, from: section.start, to: section.end, tempoMap: project.tempoMap, endsHome: index == sections.count - 1)
      return SetChords(changes, from: section.start, to: section.end)
    }
  }

  /// Writes chords for the whole song, replacing the Chord track.
  func writeSongChords() {
    let commands: [any EditCommand] = [DeleteChords(Set(project.chords.map(\.id)))] + songChordCommands(song: Int.random(in: 0..<1000))
    perform(CompositeCommand("Write Chords for the Song", commands: commands))
    isGlobalTracksVisible = true
  }

  /// Where a chord goes: on the window's Snap grid, but never between sixteenths (with Snap
  /// off, a triplet grid or Control held, the nearest sixteenth), as the players read the
  /// chords a sixteenth at a time.
  func snapChord(_ position: Tick) -> Tick {
    let mode = AppSettings.snapMode
    let snapped = [.off, .eighthTriplet, .sixteenthTriplet].contains(mode) ? max(.zero, position) : snap(max(.zero, position))
    let barStart = project.tempoMap.bar(containing: snapped).start
    let sixteenths = (Double((snapped - barStart).rawValue) / 240).rounded()
    return max(.zero, barStart + Tick(240) * Int64(sixteenths))
  }

  // MARK: - Players

  /// The General MIDI sound a player starts with: fingered bass, or an electric piano.
  static func defaultSound(for instrument: PlayerPerformance.Instrument) -> InstrumentSource {
    instrument == .bass ? .generalMIDI(program: 33) : .generalMIDI(program: 4)
  }

  /// A player track: a track with a player region for each section of the song, each played
  /// to suit its section, following the Chord track.
  func addPlayerTrack(_ instrument: PlayerPerformance.Instrument, style: PlayerPerformance.Style? = nil) {
    let style = style ?? (instrument == .bass ? .rootNotes : .pad)
    let baseName = instrument == .bass ? "Bass Player" : "Keyboard Player"
    let existing = Set(project.tracks.map(\.name))
    var name = baseName
    var number = 2
    while existing.contains(name) {
      name = "\(baseName) \(number)"
      number += 1
    }
    var track = makeTrack(name: name, kind: .softwareInstrument)
    track.channel.instrument = Self.defaultSound(for: instrument)
    let sections = drummerSections()
    // With no chords to follow, the song gets some (a player on one chord isn't much use).
    var withChords = project
    var chordCommands: [any EditCommand] = []
    if project.chords.isEmpty {
      chordCommands = songChordCommands(song: Int.random(in: 0..<1000))
      for command in chordCommands { try? command.apply(to: &withChords) }
    }
    let regions = sections.enumerated().map { index, section in
      var region = Region(
        name: section.name, start: section.start, length: section.end - section.start, content: .midi(MIDISequence()),
        player: .forSection(named: section.name, style: style, isLast: index == sections.count - 1, seed: UInt64.random(in: 1...UInt64.max)))
      region.renderPlayer(in: withChords)
      return region
    }
    let index = selectedTrackID.flatMap(project.trackIndex(for:)).map { $0 + 1 }
    let commands: [any EditCommand] = chordCommands + [AddTrack(track, at: index)] + regions.map { AddRegion($0, to: track.id) }
    guard perform(CompositeCommand("New \(baseName) Track", commands: commands)) else { return }
    if !chordCommands.isEmpty { isGlobalTracksVisible = true }
    selectedTrackID = track.id
    if let first = regions.first {
      selectedRegionIDs = [first.id]
      openEditor(for: first.id)
      pianoRoll.editorKind = .player
    }
  }

  /// A player region at `position` on an instrument track that isn't a drum track: across
  /// the arrangement section there, or eight bars from the bar.
  func createPlayerRegion(on trackID: Track.ID, at position: Tick) {
    guard let track = project.track(withID: trackID), track.kind == .softwareInstrument, !playsDrums(track) else { return }
    let tempoMap = project.tempoMap
    let name: String, start: Tick, end: Tick
    if let section = project.arrangement.first(where: { $0.range.contains(position) }) {
      (name, start, end) = (section.name, section.start, section.end)
    } else {
      let bar = tempoMap.bar(containing: max(.zero, position))
      (name, start, end) = ("Player", bar.start, tempoMap.tickPosition(ofBarIndex: bar.index + 8))
    }
    // A new region carries on in the track's style, or suits the track's sound.
    let style = track.regions.compactMap(\.player).first?.style ?? (Self.soundsLikeBass(track) ? .rootNotes : .pad)
    var region = Region(
      name: name, start: start, length: end - start, content: .midi(MIDISequence()),
      player: .forSection(named: name, style: style, isLast: false, seed: UInt64.random(in: 1...UInt64.max)))
    region.renderPlayer(in: project)
    perform(AddRegion(region, to: trackID), named: "New Player Region")
    selectedTrackID = trackID
    selectedRegionIDs = [region.id]
    openEditor(for: region.id)
    pianoRoll.editorKind = .player
  }

  /// Whether a track's sound is a bass (General MIDI programs 33–40).
  static func soundsLikeBass(_ track: Track) -> Bool {
    if case .generalMIDI(let program) = track.channel.instrument { return (32...39).contains(program) }
    return false
  }
}

extension PianoRollModel {
  var player: PlayerPerformance? { region?.player }

  /// The player regions an edit changes: the open one, with the other selected player
  /// regions of the same instrument.
  var editedPlayerRegionIDs: Set<Region.ID> {
    guard let region, let instrument = region.player?.instrument else { return [] }
    let selected = window.selectedRegionIDs
    guard selected.contains(region.id) else { return [region.id] }
    return Set(selected.filter { window.project.region(withID: $0)?.player?.instrument == instrument })
  }

  func editPlayer(_ actionName: String, _ change: @escaping @Sendable (inout PlayerPerformance) -> Void) {
    let regionIDs = editedPlayerRegionIDs
    guard !regionIDs.isEmpty else { return }
    window.perform(SetPlayerPerformance(for: regionIDs, actionName: actionName, change: change))
  }

  func newPlayerTake() {
    editPlayer("New Take") { $0.seed = UInt64.random(in: 1...UInt64.max) }
  }

  func convertPlayerToNotes() {
    let regionIDs = editedPlayerRegionIDs
    guard !regionIDs.isEmpty else { return }
    window.perform(ConvertPatternToNotes(regionIDs))
    editorKind = .pianoRoll
  }
}
