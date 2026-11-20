//
//  EditorKind.swift
//  Ongaku
//

import Foundation

extension PianoRollModel {
  /// Which editor the pane shows, like the tabs over Logic's editors.
  enum EditorKind: String, CaseIterable, Identifiable {
    case pianoRoll, stepEditor, eventList, stepSequencer, drummer, player, takes, pitch, audioFile

    var id: Self { self }

    var title: String {
      switch self {
      case .pianoRoll: "Piano Roll"
      case .stepEditor: "Step Editor"
      case .eventList: "Event List"
      case .stepSequencer: "Step Sequencer"
      case .drummer: "Drummer"
      case .player: "Player"
      case .takes: "Takes"
      case .pitch: "Flex Pitch"
      case .audioFile: "Audio File"
      }
    }
  }
}
