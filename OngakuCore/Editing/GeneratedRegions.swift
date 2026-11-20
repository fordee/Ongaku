//
//  GeneratedRegions.swift
//  OngakuCore
//

import Foundation

extension Project {
  /// Renders again every generated region (pattern, drummer or player) whose notes may no
  /// longer match what generates them since `previous`: the region is new, or its start,
  /// length or source changed, or, for drummers and players, the tempo map (meter) changed,
  /// and for players also the chords or key.
  ///
  /// `ProjectEditor` runs this after every command, so moving, pasting, repeating or
  /// retiming a generated region always leaves it playing its part from where it now is.
  /// Rendering is repeatable, so a region rendered by its command already is unchanged.
  mutating func renderGeneratedRegions(changedSince previous: Project) {
    let timingChanged = tempoMap != previous.tempoMap
    let chordsChanged =
      timingChanged || chords != previous.chords || keySignature != previous.keySignature
      || keyChanges != previous.keyChanges
    var before: [Region.ID: Region] = [:]
    for track in previous.tracks {
      for region in track.regions where region.isGenerated { before[region.id] = region }
    }
    let timeline = chordTimeline

    for trackIndex in tracks.indices {
      for regionIndex in tracks[trackIndex].regions.indices {
        let region = tracks[trackIndex].regions[regionIndex]
        guard let source = region.source, source.isGenerated else { continue }
        let moved = before[region.id].map {
          $0.start != region.start || $0.length != region.length || $0.source != region.source
        } ?? true
        var rendered = region
        switch source {
        case .pattern:
          guard moved else { continue }
          rendered.renderPattern()
        case .drummer:
          guard moved || timingChanged else { continue }
          rendered.renderDrummer(tempoMap: tempoMap)
        case .player:
          guard moved || chordsChanged else { continue }
          rendered.renderPlayer(tempoMap: tempoMap, chords: timeline)
        case .takeFolder:
          continue
        }
        // Rendering makes new notes (new identifiers); when they play the same as the old
        // ones, keep the old, so nothing looks changed (a frozen track stays frozen).
        if !rendered.content.playsTheSame(as: region.content) {
          tracks[trackIndex].regions[regionIndex] = rendered
        }
      }
    }
  }
}

extension RegionContent {
  /// Whether two MIDI contents hold the same notes and controller events, ignoring the
  /// notes' identifiers.
  func playsTheSame(as other: RegionContent) -> Bool {
    guard case .midi(let mine) = self, case .midi(let theirs) = other else { return self == other }
    guard mine.controls == theirs.controls, mine.notes.count == theirs.notes.count else { return false }
    return zip(mine.notes, theirs.notes).allSatisfy { a, b in
      a.pitch == b.pitch && a.velocity == b.velocity && a.channel == b.channel && a.start == b.start
        && a.length == b.length && a.isMuted == b.isMuted
    }
  }
}
