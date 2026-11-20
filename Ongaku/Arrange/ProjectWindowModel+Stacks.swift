//
//  ProjectWindowModel+Stacks.swift
//  Ongaku
//

import AppKit
import OngakuCore

/// Track stacks (summing and folder) and selecting several tracks, for the tracks area and
/// the Track menu.
extension ProjectWindowModel {
  /// The tracks the tracks area shows, top to bottom: every track except the subtracks of
  /// collapsed stacks.
  var displayedTracks: [Track] {
    let hidesTracks = !showsHiddenTracks && project.tracks.contains(where: \.isHidden)
    guard !collapsedStackIDs.isEmpty || hidesTracks else { return project.tracks }
    return project.tracks.filter { track in
      (!hidesTracks || !track.isHidden) && (track.stackID.map { !collapsedStackIDs.contains($0) } ?? true)
    }
  }

  /// Hides the selected tracks (Logic's Hide Track), or shows them if they're all hidden.
  func toggleSelectedTracksHidden() {
    let tracks = project.tracks.filter { selectedTrackIDs.contains($0.id) }
    guard !tracks.isEmpty else { return }
    let hide = !tracks.allSatisfy(\.isHidden)
    perform(SetTracksHidden(Set(tracks.map(\.id)), isHidden: hide))
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

  /// Whether Create Summing or Folder Stack can group the selection: tracks not already in
  /// a stack.
  var canCreateSummingStack: Bool {
    let tracks = project.tracks.filter { selectedTrackIDs.contains($0.id) }
    return !tracks.isEmpty && tracks.allSatisfy { !$0.isStack && $0.stackID == nil }
  }

  /// Logic's Track › Create Track Stack › Summing Stack (Shift-Command-D) for the selected
  /// tracks.
  func createSummingStack() {
    createStack(folder: false)
  }

  /// Logic's Create Track Stack: a summing stack (its subtracks mixed through its channel
  /// strip) or a folder stack (just gathered, with a fader that moves theirs).
  func createStack(folder: Bool) {
    guard canCreateSummingStack else {
      errorMessage = "Select tracks that aren’t already in a stack, then create the stack."
      return
    }
    var stack = makeTrack(name: nextStackName(folder: folder), kind: .aux)
    stack.automationMode = .read
    if folder {
      perform(CreateFolderStack(selectedTrackIDs, stack: stack))
    } else {
      perform(CreateSummingStack(selectedTrackIDs, stack: stack))
    }
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
    return track.isStack ? track.id : track.stackID
  }

  /// "Sum" (or "Folder"), then "Sum 2", "Sum 3"… as in Logic.
  private func nextStackName(folder: Bool) -> String {
    let base = folder ? "Folder" : "Sum"
    let names = Set(project.tracks.map(\.name))
    guard names.contains(base) else { return base }
    var number = 2
    while names.contains("\(base) \(number)") { number += 1 }
    return "\(base) \(number)"
  }
}

// MARK: - Reordering tracks

extension ProjectWindowModel {
  /// The row a track header dragged to `y` (in the headers column) would land above.
  func trackDropRow(at y: CGFloat) -> Int {
    min(max(Int((y / rowHeight).rounded()), 0), displayedTracks.count)
  }

  /// Moves a track to land above a displayed row (or below the last), as dropping its
  /// header there does. Stacks stay whole (see `Project.trackMoveDestination`).
  func moveTrack(_ trackID: Track.ID, toRow row: Int) {
    let tracks = displayedTracks
    let target = tracks.indices.contains(row) ? tracks[row].id : nil
    guard let destination = project.trackMoveDestination(of: trackID, before: target) else { return }
    perform(MoveTrack(trackID, to: destination))
  }
}
