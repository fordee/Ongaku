//
//  ProjectWindowModel+Stacks.swift
//  Ongaku
//

import AppKit
import OngakuCore

/// Summing stacks and selecting several tracks, for the tracks area and the Track menu.
extension ProjectWindowModel {
  /// The tracks the tracks area shows, top to bottom: every track except the subtracks of
  /// collapsed stacks.
  var displayedTracks: [Track] {
    guard !collapsedStackIDs.isEmpty else { return project.tracks }
    return project.tracks.filter { track in track.stackID.map { !collapsedStackIDs.contains($0) } ?? true }
  }

  /// Selects a track from a click on its header: Shift adds the tracks between it and the
  /// last one clicked, Command adds or removes just it, as in Logic.
  func selectTrack(_ trackID: Track.ID, modifiers: NSEvent.ModifierFlags = []) {
    if modifiers.contains(.shift), let anchor = selectedTrackID {
      let tracks = displayedTracks
      guard let from = tracks.firstIndex(where: { $0.id == anchor }), let to = tracks.firstIndex(where: { $0.id == trackID }) else {
        selectedTrackID = trackID
        return
      }
      let range = Set(tracks[min(from, to)...max(from, to)].map(\.id))
      selectedTrackID = trackID
      selectedTrackIDs = range
    } else if modifiers.contains(.command) {
      var selection = selectedTrackIDs
      if selection.contains(trackID), selection.count > 1 {
        selection.remove(trackID)
        selectedTrackID = selection.contains(selectedTrackID ?? trackID) ? selectedTrackID : selection.first
      } else {
        selection.insert(trackID)
        selectedTrackID = trackID
      }
      selectedTrackIDs = selection
    } else {
      selectedTrackID = trackID
    }
  }

  /// Whether Create Summing Stack can group the selection: tracks not already in a stack.
  var canCreateSummingStack: Bool {
    let tracks = project.tracks.filter { selectedTrackIDs.contains($0.id) }
    return !tracks.isEmpty && tracks.allSatisfy { !$0.isSummingStack && $0.stackID == nil }
  }

  /// Logic's Track › Create Track Stack › Summing Stack (Shift-Command-D) for the selected
  /// tracks.
  func createSummingStack() {
    guard canCreateSummingStack else {
      errorMessage = "Select tracks that aren’t already in a stack, then create the stack."
      return
    }
    var stack = makeTrack(name: nextStackName(), kind: .aux)
    stack.automationMode = .read
    perform(CreateSummingStack(selectedTrackIDs, stack: stack))
    selectedTrackID = stack.id
  }

  /// Logic's Flatten Stack: the subtracks become ordinary tracks again.
  func flattenStack(_ stackID: Track.ID) {
    perform(FlattenStack(stackID))
    collapsedStackIDs.remove(stackID)
  }

  func isStackCollapsed(_ stackID: Track.ID) -> Bool {
    collapsedStackIDs.contains(stackID)
  }

  /// Folds a stack's subtracks away or shows them again. If a hidden subtrack was selected,
  /// the stack takes over the selection.
  func toggleStackCollapsed(_ stackID: Track.ID) {
    if collapsedStackIDs.remove(stackID) == nil {
      collapsedStackIDs.insert(stackID)
      if let selected = selectedTrack, selected.stackID == stackID {
        selectedTrackID = stackID
      }
    }
  }

  /// The stack the selected track belongs to (or is), for the Track menu.
  var selectedStackID: Track.ID? {
    guard let track = selectedTrack else { return nil }
    return track.isSummingStack ? track.id : track.stackID
  }

  /// "Sum", then "Sum 2", "Sum 3"… as in Logic.
  private func nextStackName() -> String {
    let names = Set(project.tracks.map(\.name))
    guard names.contains("Sum") else { return "Sum" }
    var number = 2
    while names.contains("Sum \(number)") { number += 1 }
    return "Sum \(number)"
  }
}
