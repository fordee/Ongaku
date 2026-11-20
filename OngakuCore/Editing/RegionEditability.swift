//
//  RegionEditability.swift
//  OngakuCore
//

import Foundation

/// An edit that some kinds of region can't take until something is removed or flattened.
/// Every command checks its edit with `Region.requireEditable(for:)`, so the rules and
/// their messages are the same wherever the edit comes from (a tool, a menu, the Region
/// Inspector or an agent).
public enum RegionEdit: Sendable, CaseIterable {
  case resize, split, join, crossfade, loop, packIntoTakeFolder, flex, retune, stretch, editNotes

  /// The edit as a verb for messages: “To resize “Vocal”…”.
  var verb: String {
    switch self {
    case .resize: "resize"
    case .split: "split"
    case .join: "join"
    case .crossfade: "crossfade"
    case .loop: "loop"
    case .packIntoTakeFolder: "pack"
    case .flex: "flex"
    case .retune: "retune"
    case .stretch: "stretch"
    case .editNotes: "edit"
    }
  }

  /// Edits that move audio against the region's own time, where flex markers, retuned notes
  /// and stretches are placed.
  fileprivate var shiftsRegionTime: Bool {
    switch self {
    case .resize, .split, .join, .crossfade, .loop, .packIntoTakeFolder: true
    case .flex, .retune, .stretch, .editNotes: false
    }
  }
}

extension Region {
  /// Why the region can't take `edit` (a sentence saying how to make it possible), or `nil`
  /// if it can.
  public func reasonCantEdit(_ edit: RegionEdit) -> String? {
    if takeFolder != nil, edit != .editNotes {
      return "“\(name)” is a take folder. Flatten it first to \(edit.verb) it."
    }

    switch edit {
    case .editNotes:
      // Generated notes would be replaced by the next render.
      switch source {
      case .pattern: return "“\(name)” plays a Step Sequencer pattern. Convert it to a MIDI region first to edit its notes."
      case .drummer: return "“\(name)” is played by the Drummer. Convert it to a MIDI region first to edit its notes."
      case .player: return "“\(name)” is played by a session player. Convert it to a MIDI region first to edit its notes."
      case .takeFolder, nil: return nil
      }
    case .flex, .retune, .stretch:
      guard case .audio(let audio) = content else { return "Only audio regions can be \(edit == .retune ? "retuned" : edit.verb + "ed")." }
      if edit == .stretch, !audio.flexMarkers.isEmpty {
        return "To \(edit.verb) “\(name)”, first remove its flex markers (Remove Flex Markers): select it and use the button in the Region Inspector."
      }
      return nil
    default:
      guard edit.shiftsRegionTime, case .audio(let audio) = content else { return nil }
      // Flex markers, retuned notes and stretches are placed in the region's own time, which
      // these edits would shift. They stay when Flex is turned off (hidden), so the message
      // says where to remove them.
      var fixes: [String] = []
      if !audio.flexMarkers.isEmpty { fixes.append("its flex markers (Remove Flex Markers)") }
      if !audio.pitchEdits.isEmpty { fixes.append("its retuned notes (Reset Retuned Notes)") }
      if abs(audio.stretch - 1) > 0.0001 { fixes.append("its Smart Tempo stretch (Remove Stretch)") }
      guard !fixes.isEmpty else { return nil }
      return "To \(edit.verb) “\(name)”, first remove \(fixes.formatted(.list(type: .and))): select it and use the button in the Region Inspector."
    }
  }

  /// Whether the region can take `edit` now.
  public func canEdit(_ edit: RegionEdit) -> Bool { reasonCantEdit(edit) == nil }

  /// Throws, with the reason, if the region can't take `edit`.
  func requireEditable(for edit: RegionEdit) throws {
    if let reason = reasonCantEdit(edit) { throw EditError.invalidValue(reason) }
  }
}
