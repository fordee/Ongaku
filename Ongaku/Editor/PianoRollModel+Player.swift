//
//  PianoRollModel+Player.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

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
