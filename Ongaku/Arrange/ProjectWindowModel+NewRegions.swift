//
//  ProjectWindowModel+NewRegions.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

extension ProjectWindowModel {
  /// Whether an instrument track plays drums (a General MIDI kit or the Drum Machine), so a
  /// new pattern starts with a kit's rows.
  func playsDrums(_ track: Track) -> Bool {
    switch track.channel.instrument {
    case .generalMIDIPercussion: return true
    case .sampler(let instrument): return instrument.preset?.isPercussion ?? false
    case .audioUnit(let plugin): return OngakuInstrument(plugin) == .drumMachine
    default: return false
    }
  }

  /// Creates a one-bar pattern region at the bar containing `position` and opens it in the
  /// Step Sequencer: a kit's rows with a beat to start from on drum tracks, an octave of a
  /// scale otherwise.
  func createPatternRegion(on trackID: Track.ID, at position: Tick) {
    guard let track = project.track(withID: trackID), track.kind == .softwareInstrument else { return }
    let tempoMap = project.tempoMap
    let bar = tempoMap.bar(containing: max(.zero, position))
    let end = tempoMap.tickPosition(ofBarIndex: bar.index + 1)
    let pattern = playsDrums(track) ? StepPattern.drums() : StepPattern.notes()
    var region = Region(name: "Pattern", start: bar.start, length: end - bar.start, content: .midi(MIDISequence()), pattern: pattern)
    region.renderPattern()
    perform(AddRegion(region, to: trackID), named: "New Pattern Region")
    selectedTrackID = trackID
    selectedRegionIDs = [region.id]
    openEditor(for: region.id)
    pianoRoll.editorKind = .stepSequencer
  }

  /// The kinds of region Edit › New … Region makes, as the tracks' right-click menu does.
  enum NewRegionKind: CaseIterable {
    case midi, pattern, drummer, player

    var menuTitle: String {
      switch self {
      case .midi: "New MIDI Region"
      case .pattern: "New Pattern Region"
      case .drummer: "New Drummer Region"
      case .player: "New Player Region"
      }
    }
  }

  /// Whether the selected track can take a new region of `kind`: an instrument track, a
  /// drum track for a drummer, and one that isn't for a session player.
  func canCreateRegionAtPlayhead(_ kind: NewRegionKind) -> Bool {
    guard let track = selectedTrack, track.kind == .softwareInstrument else { return false }
    switch kind {
    case .midi, .pattern: return true
    case .drummer: return playsDrums(track)
    case .player: return !playsDrums(track)
    }
  }

  /// Edit › New … Region: on the selected track, at the playhead.
  func createRegionAtPlayhead(_ kind: NewRegionKind) {
    guard canCreateRegionAtPlayhead(kind), let track = selectedTrack else { return }
    let position = engine.playheadPosition
    switch kind {
    case .midi: createMIDIRegion(on: track.id, at: position)
    case .pattern: createPatternRegion(on: track.id, at: position)
    case .drummer: createDrummerRegion(on: track.id, at: position)
    case .player: createPlayerRegion(on: track.id, at: position)
    }
  }
}
