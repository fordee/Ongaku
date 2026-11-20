//
//  PianoRollModel+Drummer.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

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
