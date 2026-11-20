//
//  TimelineEdits.swift
//  OngakuCore
//

import Foundation

// The edits that move a stretch of time across every track at once, shared by the section
// edits between the locators (`CutSection`, `InsertSilence`, `RepeatSection`) and the
// arrangement-marker edits (`MoveArrangementSection`, `DeleteArrangementSection`,
// `DuplicateArrangementSection`), so both behave the same: regions crossing an edge are
// split there, and everything on the timeline (regions, automation, markers, key changes,
// chords, tempo and meter changes) goes with the music.

extension Project {
  /// Removes `range` and closes the gap: what came after moves back.
  mutating func removeTime(_ range: Range<Tick>) throws {
    try splitRegions(at: range.lowerBound)
    try splitRegions(at: range.upperBound)
    let length = range.upperBound - range.lowerBound
    remapTimeline(keepingWhatPlaysAt: [range.upperBound]) { position in
      if range.contains(position) { return nil }
      return position >= range.upperBound ? position - length : position
    }
  }

  /// Opens up `length` of empty time at `position`: what came after moves later.
  mutating func insertTime(at position: Tick, length: Tick) throws {
    try splitRegions(at: position)
    remapTimeline(keepingWhatPlaysAt: [position]) { $0 >= position ? $0 + length : $0 }
  }

  /// Plays `range` `times` more times straight after itself; what came after moves later.
  mutating func repeatTime(_ range: Range<Tick>, times: Int) throws {
    try splitRegions(at: range.lowerBound)
    try splitRegions(at: range.upperBound)
    var pinnedChords = pinWhatPlays(at: [range.lowerBound, range.upperBound])
    let length = range.upperBound - range.lowerBound
    let copies = (1...max(1, times)).map { length * Int64($0) }
    let copied = TimelineCopy(of: self, in: range)
    remapTimeline { $0 >= range.upperBound ? $0 + length * Int64(copies.count) : $0 }
    for offset in copies {
      pinnedChords.formUnion(copied.paste(into: &self, offset: offset, pinnedChords: pinnedChords))
    }
    sortChords(droppingRepeated: pinnedChords)
    tempoMap.remapChanges { $0 }  // Drops pasted changes that repeat what already plays.
  }

  /// Moves everything that's placed on the timeline: regions (by their start), automation
  /// points, markers, key changes, chords, and tempo and meter changes. `newPosition`
  /// returns `nil` to delete the item; positions it leaves unchanged stay put.
  ///
  /// What plays at each of `anchors` (tempo, meter, key and chord) is pinned there first, so
  /// the music after an anchor keeps it wherever it moves.
  mutating func remapTimeline(keepingWhatPlaysAt anchors: [Tick] = [], _ newPosition: (Tick) -> Tick?) {
    let pinnedChords = pinWhatPlays(at: anchors)
    for trackIndex in tracks.indices {
      var regions: [Region] = []
      for var region in tracks[trackIndex].regions {
        guard let start = newPosition(region.start) else { continue }
        region.start = start
        regions.append(region)
      }
      tracks[trackIndex].regions = regions
      tracks[trackIndex].sortRegions()
      for laneIndex in tracks[trackIndex].automation.indices {
        let lane = tracks[trackIndex].automation[laneIndex]
        let points = lane.points.compactMap { point -> AutomationPoint? in
          guard let position = newPosition(point.position) else { return nil }
          var moved = point
          moved.position = position
          return moved
        }
        tracks[trackIndex].automation[laneIndex].setPoints(points)
      }
    }
    markers = markers.compactMap { marker in
      guard let position = newPosition(marker.position) else { return nil }
      var moved = marker
      moved.position = position
      return moved
    }
    sortMarkers()
    // Key changes go with the music; the key at the start stays put.
    keyChanges = keyChanges.compactMap { change in
      guard let position = newPosition(change.position), position > .zero else { return nil }
      var moved = change
      moved.position = position
      return moved
    }
    sortKeyChanges()
    removeRedundantKeyChanges()
    chords = chords.compactMap { change in
      guard let position = newPosition(change.position) else { return nil }
      var moved = change
      moved.position = position
      return moved
    }
    sortChords(droppingRepeated: pinnedChords)
    tempoMap.remapChanges(newPosition)
  }

  /// Adds a tempo, meter, key and chord change at each anchor (where none is), repeating
  /// what plays there, so it stays with what follows when time moves. Returns the chord
  /// changes added, which are dropped again if they end up repeating the chord before them.
  @discardableResult
  private mutating func pinWhatPlays(at anchors: [Tick]) -> Set<ChordChange.ID> {
    var pinnedChords: Set<ChordChange.ID> = []
    for anchor in Set(anchors) where anchor > .zero {
      if !tempoMap.tempoChanges.contains(where: { $0.position == anchor }) {
        // Inside a ramp, the pin carries on ramping, so the curve keeps its shape.
        let ramps = tempoMap.tempoChanges.last { $0.position < anchor }?.rampsToNext ?? false
        // Can't throw: the tempo is one the map already holds.
        try? tempoMap.setTempo(tempoMap.tempo(at: anchor), at: anchor)
        tempoMap.setRamp(ramps, at: anchor)
      }
      let bar = tempoMap.bar(containing: anchor)
      if bar.start == anchor, !tempoMap.meterChanges.contains(where: { $0.barIndex == bar.index }) {
        try? tempoMap.setTimeSignature(tempoMap.timeSignature(atBarIndex: bar.index), atBarIndex: bar.index)
      }
      if !keyChanges.contains(where: { $0.position == anchor }) {
        keyChanges.append(KeyChange(position: anchor, key: key(at: anchor)))
        sortKeyChanges()
      }
      if let playing = chords.last(where: { $0.position <= anchor }), playing.position != anchor {
        let pin = ChordChange(position: anchor, chord: playing.chord)
        chords.append(pin)
        pinnedChords.insert(pin.id)
      }
    }
    chords.sort { $0.position < $1.position }
    return pinnedChords
  }

  /// Sorts the Chord track; of `pinned` chords, drops those repeating the chord before.
  private mutating func sortChords(droppingRepeated pinned: Set<ChordChange.ID>) {
    chords.sort { $0.position < $1.position }
    var previous: Chord?
    chords = chords.filter { change in
      defer { previous = change.chord }
      return !(pinned.contains(change.id) && change.chord == previous)
    }
  }
}

/// Everything placed in a stretch of time, copied so it can be pasted further on.
private struct TimelineCopy {
  var regions: [[Region]]
  var points: [[AutomationParameter: [AutomationPoint]]]
  var markers: [Marker]
  var keyChanges: [KeyChange]
  var chords: [ChordChange]
  var tempos: [TempoMap.TempoChange]
  var meters: [(position: Tick, signature: TimeSignature)]

  init(of project: Project, in range: Range<Tick>) {
    regions = project.tracks.map { $0.regions.filter { range.contains($0.start) } }
    points = project.tracks.map { track in
      Dictionary(uniqueKeysWithValues: track.automation.map { lane in
        (lane.parameter, lane.points.filter { range.contains($0.position) })
      })
    }
    markers = project.markers.filter { range.contains($0.position) }
    keyChanges = project.keyChanges.filter { range.contains($0.position) }
    chords = project.chords.filter { range.contains($0.position) }
    tempos = project.tempoMap.tempoChanges.filter { range.contains($0.position) }
    meters = project.tempoMap.meterChanges.map { (project.tempoMap.tickPosition(ofBarIndex: $0.barIndex), $0.signature) }
      .filter { range.contains($0.0) }
  }

  /// Adds the copy `offset` later, with new identifiers. Returns the identifiers of the
  /// copies of `pinnedChords`.
  func paste(into project: inout Project, offset: Tick, pinnedChords: Set<ChordChange.ID>) -> Set<ChordChange.ID> {
    for trackIndex in project.tracks.indices {
      project.tracks[trackIndex].regions += regions[trackIndex].map { region in
        var copy = region
        copy.id = UUID()
        copy.start = region.start + offset
        return copy
      }
      project.tracks[trackIndex].sortRegions()
      for laneIndex in project.tracks[trackIndex].automation.indices {
        let lane = project.tracks[trackIndex].automation[laneIndex]
        let copied = (points[trackIndex][lane.parameter] ?? []).map { AutomationPoint(position: $0.position + offset, value: $0.value) }
        project.tracks[trackIndex].automation[laneIndex].setPoints(lane.points + copied)
      }
    }
    project.markers += markers.map { Marker(name: $0.name, position: $0.position + offset) }
    project.sortMarkers()
    project.keyChanges.removeAll { change in keyChanges.contains { $0.position + offset == change.position } }
    project.keyChanges += keyChanges.map { KeyChange(position: $0.position + offset, key: $0.key) }
    project.sortKeyChanges()
    project.removeRedundantKeyChanges()
    project.chords.removeAll { change in chords.contains { $0.position + offset == change.position } }
    var pinnedCopies: Set<ChordChange.ID> = []
    for change in chords {
      let copy = ChordChange(position: change.position + offset, chord: change.chord)
      if pinnedChords.contains(change.id) { pinnedCopies.insert(copy.id) }
      project.chords.append(copy)
    }
    project.chords.sort { $0.position < $1.position }
    // Can't throw: the tempos and meters are ones the map already holds.
    for tempo in tempos {
      try? project.tempoMap.setTempo(tempo.bpm, at: tempo.position + offset)
      project.tempoMap.setRamp(tempo.rampsToNext, at: tempo.position + offset)
    }
    for meter in meters {
      let bar = project.tempoMap.bar(containing: meter.position + offset)
      guard bar.start == meter.position + offset else { continue }
      try? project.tempoMap.setTimeSignature(meter.signature, atBarIndex: bar.index)
    }
    return pinnedCopies
  }
}
