//
//  PianoRollModel+Drummer.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

extension ProjectWindowModel {
  /// The kit a track's drummer plays: the Drum Machine's pads, or a General MIDI kit.
  func drummerKit(for track: Track) -> DrummerPerformance.Kit {
    if case .audioUnit(let plugin) = track.channel.instrument, OngakuInstrument(plugin) == .drumMachine {
      return .drumMachine
    }
    return .generalMIDI
  }

  /// The parts of the song a drummer plays through, each as (name, start, end): the
  /// arrangement's sections when there are some, otherwise one stretch to the end of the
  /// last region (at least eight bars), with fills along the way.
  func drummerSections() -> [(name: String, start: Tick, end: Tick)] {
    let sections = project.arrangement.sorted { $0.start < $1.start }
    if !sections.isEmpty {
      return sections.map { ($0.name, $0.start, $0.end) }
    }
    let tempoMap = project.tempoMap
    let lastEnd = project.tracks.filter { !$0.regions.contains { $0.drummer != nil } }.flatMap(\.regions).map(\.end).max() ?? .zero
    let lastBar = max(8, tempoMap.bar(containing: max(.zero, lastEnd - Tick(1))).index + 1)
    return [("Drummer", .zero, tempoMap.tickPosition(ofBarIndex: lastBar))]
  }

  /// The drummer regions on a track, made for `sections`.
  private func drummerRegions(
    for sections: [(name: String, start: Tick, end: Tick)], style: DrummerPerformance.Style, kit: DrummerPerformance.Kit
  ) -> [Region] {
    sections.enumerated().map { index, section in
      var region = Region(
        name: section.name, start: section.start, length: section.end - section.start, content: .midi(MIDISequence()),
        drummer: .forSection(
          named: section.name, style: style, kit: kit, isFirst: index == 0, isLast: index == sections.count - 1,
          seed: UInt64.random(in: 1...UInt64.max)))
      region.renderDrummer(tempoMap: project.tempoMap)
      return region
    }
  }

  /// Whether a track's drummer regions already line up with the song's arrangement
  /// sections (nothing to match when the song has none).
  func drummerMatchesSections(on trackID: Track.ID) -> Bool {
    guard !project.arrangement.isEmpty, let track = project.track(withID: trackID) else { return true }
    let regions = track.regions.filter { $0.drummer != nil }.map { "\($0.start.rawValue)-\($0.end.rawValue)" }
    let sections = project.arrangement.map { "\($0.start.rawValue)-\($0.end.rawValue)" }
    return Set(regions) == Set(sections)
  }

  /// What Match Song Sections would do on a track: each section keeps the drummer region
  /// already playing it (the one over the same bars, else the one with its name), moved to
  /// fit, so the person's settings survive; new sections get a drummer of their own; and
  /// the regions left over (for sections that are gone) are removed.
  func drummerSectionMatch(on trackID: Track.ID) -> (sections: [Region], removed: [Region])? {
    guard let track = project.track(withID: trackID), !project.arrangement.isEmpty else { return nil }
    let existing = track.regions.filter { $0.drummer != nil }.sorted { $0.start < $1.start }
    let sections = drummerSections()
    var kept: [Region?] = sections.map { section in existing.first { $0.start == section.start && $0.end == section.end } }
    for index in sections.indices where kept[index] == nil {
      let claimed = Set(kept.compactMap { $0?.id })
      kept[index] = existing.first { !claimed.contains($0.id) && $0.name == sections[index].name }
    }
    let style = existing.first?.drummer?.style ?? .rock
    let fresh = drummerRegions(for: sections, style: style, kit: drummerKit(for: track))
    let regions = sections.indices.map { index in
      guard var region = kept[index] else { return fresh[index] }
      let section = sections[index]
      region.name = section.name
      region.start = section.start
      region.length = section.end - section.start
      region.isLooped = false
      region.loopedLength = nil
      region.renderDrummer(tempoMap: project.tempoMap)
      return region
    }
    let keptIDs = Set(kept.compactMap { $0?.id })
    return (regions, existing.filter { !keptIDs.contains($0.id) })
  }

  /// Gives a track a drummer region for each arrangement section (see
  /// `drummerSectionMatch(on:)`), as one undoable step.
  func matchDrummerToSections(on trackID: Track.ID) {
    guard let match = drummerSectionMatch(on: trackID), let track = project.track(withID: trackID) else { return }
    // The regions that move are put back in their new places, keeping their identifiers.
    let unchanged = Set(track.regions.filter { region in match.sections.contains { $0 == region } }.map(\.id))
    let changed = match.sections.filter { !unchanged.contains($0.id) }
    let replaced = Set(changed.map(\.id)).intersection(track.regions.map(\.id))
    let old = replaced.union(match.removed.map(\.id))
    var commands: [any EditCommand] = old.isEmpty ? [] : [DeleteRegions(old)]
    commands += changed.map { AddRegion($0, to: trackID) }
    guard !commands.isEmpty, perform(CompositeCommand("Match Song Sections", commands: commands)) else { return }
    if let first = match.sections.first {
      selectedRegionIDs = [first.id]
      openEditor(for: first.id)
      pianoRoll.editorKind = .drummer
    }
  }

  /// Logic's New Drummer Track: a drum kit track with a drummer region for each section of
  /// the song, each played to suit its section (quiet intro, loud chorus, fills between).
  func addDrummerTrack(style: DrummerPerformance.Style = .rock, kit: DrummerPerformance.Kit = .generalMIDI) {
    let existing = Set(project.tracks.map(\.name))
    var name = "Drummer"
    var number = 2
    while existing.contains(name) {
      name = "Drummer \(number)"
      number += 1
    }
    var track = makeTrack(name: name, kind: .softwareInstrument)
    track.channel.instrument = kit == .drumMachine ? .audioUnit(OngakuInstrument.drumMachine.makeReference()) : .generalMIDIPercussion(kit: 0)
    let regions = drummerRegions(for: drummerSections(), style: style, kit: kit)
    let index = selectedTrackID.flatMap(project.trackIndex(for:)).map { $0 + 1 }
    let commands: [any EditCommand] = [AddTrack(track, at: index)] + regions.map { AddRegion($0, to: track.id) }
    guard perform(CompositeCommand("New Drummer Track", commands: commands)) else { return }
    selectedTrackID = track.id
    if let first = regions.first {
      selectedRegionIDs = [first.id]
      openEditor(for: first.id)
      pianoRoll.editorKind = .drummer
    }
  }

  /// A drummer region at `position` on an instrument track: across the arrangement section
  /// there, or eight bars from the bar.
  func createDrummerRegion(on trackID: Track.ID, at position: Tick) {
    guard let track = project.track(withID: trackID), track.kind == .softwareInstrument, playsDrums(track) else { return }
    let tempoMap = project.tempoMap
    let name: String, start: Tick, end: Tick
    if let section = project.arrangement.first(where: { $0.range.contains(position) }) {
      (name, start, end) = (section.name, section.start, section.end)
    } else {
      let bar = tempoMap.bar(containing: max(.zero, position))
      (name, start, end) = ("Drummer", bar.start, tempoMap.tickPosition(ofBarIndex: bar.index + 8))
    }
    // A new region on a drummer track carries on in the style it already plays.
    let style = track.regions.compactMap(\.drummer).first?.style ?? .rock
    var region = Region(
      name: name, start: start, length: end - start, content: .midi(MIDISequence()),
      drummer: .forSection(
        named: name, style: style, kit: drummerKit(for: track), isFirst: start == .zero, isLast: false,
        seed: UInt64.random(in: 1...UInt64.max)))
    region.renderDrummer(tempoMap: tempoMap)
    perform(AddRegion(region, to: trackID), named: "New Drummer Region")
    selectedTrackID = trackID
    selectedRegionIDs = [region.id]
    openEditor(for: region.id)
    pianoRoll.editorKind = .drummer
  }
}

extension PianoRollModel {
  var drummer: DrummerPerformance? { region?.drummer }

  /// The drummer regions an edit changes: the open one, and the other selected drummer
  /// regions with it (as in Logic, editing one of several selected changes them all).
  var editedDrummerRegionIDs: Set<Region.ID> {
    guard let region else { return [] }
    let selected = window.selectedRegionIDs
    guard selected.contains(region.id) else { return [region.id] }
    return Set(selected.filter { window.project.region(withID: $0)?.drummer != nil })
  }

  /// Changes the drummer, as one undoable step.
  func editDrummer(_ actionName: String, _ change: @escaping @Sendable (inout DrummerPerformance) -> Void) {
    let regionIDs = editedDrummerRegionIDs
    guard !regionIDs.isEmpty else { return }
    window.perform(SetDrummerPerformance(for: regionIDs, actionName: actionName, change: change))
  }

  /// The same settings, played differently.
  func newDrummerTake() {
    editDrummer("New Take") { $0.seed = UInt64.random(in: 1...UInt64.max) }
  }

  /// Drummer → MIDI Region, to edit the notes in the Piano Roll.
  func convertDrummerToNotes() {
    let regionIDs = editedDrummerRegionIDs
    guard !regionIDs.isEmpty else { return }
    window.perform(ConvertPatternToNotes(regionIDs))
    editorKind = .pianoRoll
  }
}
