//
//  ProjectWindowModel+Editing.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// Copied regions, shared by every project window (MIDI regions paste into any project; audio
/// regions only into the one they came from).
@MainActor
enum RegionPasteboard {
  static var contents: RegionClipboard?
}

extension ProjectWindowModel {
  // MARK: - Edit menu

  /// Edit › Cut, Copy, Paste, Select All and Repeat act on notes when the Piano Roll was
  /// clicked last, otherwise on regions.
  func editCut() { isPianoRollEditing ? pianoRoll.cutSelection() : cutSelection() }
  func editCopy() { isPianoRollEditing ? pianoRoll.copySelection() : copySelection() }
  func editPaste() { isPianoRollEditing ? pianoRoll.paste() : paste() }
  func editSelectAll() { isPianoRollEditing ? pianoRoll.selectAll() : selectAllRegions() }
  func editRepeat() { isPianoRollEditing ? pianoRoll.repeatSelection() : repeatSelection() }

  var canRepeat: Bool {
    isPianoRollEditing ? !pianoRoll.selectedNoteIDs.isEmpty : !selectedRegionIDs.isEmpty
  }

  // MARK: - Cut, copy and paste

  var canPasteRegions: Bool { RegionPasteboard.contents != nil }

  func copySelection() {
    guard let clipboard = RegionClipboard(
      copying: selectedRegionIDs, from: project, trackOrder: displayedTracks.map(\.id))
    else { return }
    RegionPasteboard.contents = clipboard
  }

  func cutSelection() {
    guard !selectedRegionIDs.isEmpty else { return }
    copySelection()
    perform(DeleteRegions(selectedRegionIDs), named: selectedRegionIDs.count == 1 ? "Cut Region" : "Cut Regions")
    selectedRegionIDs = []
  }

  /// Pastes at `position` (the playhead if `nil`) onto `trackID` (the selected track if
  /// `nil`), and selects what was pasted.
  func paste(at position: Tick? = nil, onTrack trackID: Track.ID? = nil) {
    guard let clipboard = RegionPasteboard.contents else { return }
    guard let target = trackID ?? selectedTrackID ?? displayedTracks.first(where: { $0.kind == clipboard.items.first?.trackKind })?.id
    else {
      errorMessage = "Select a track to paste onto."
      return
    }
    let command = PasteRegions(
      clipboard, at: position ?? engine.playheadPosition, onTrack: target, trackOrder: displayedTracks.map(\.id))
    if perform(command) {
      selectedRegionIDs = Set(command.newRegionIDs)
    }
  }

  // MARK: - Repeat, copy-drag and duplicate

  /// Repeats the selected regions straight after themselves, and selects the copies.
  func repeatSelection(times: Int = 1) {
    guard !selectedRegionIDs.isEmpty else { return }
    let command = RepeatRegions(selectedRegionIDs, times: times)
    if perform(command) {
      selectedRegionIDs = Set(command.newRegionIDs)
    }
  }

  /// Option-dragging: copies of the selected regions, moved by a time offset and a number
  /// of (shown) tracks, become the selection.
  func copySelection(by offset: Tick, trackOffset: Int) {
    let order = displayedTracks.map(\.id)
    guard let clipboard = RegionClipboard(copying: selectedRegionIDs, from: project, trackOrder: order),
      let topRow = displayedTracks.firstIndex(where: { track in track.regions.contains { selectedRegionIDs.contains($0.id) } }),
      let start = project.tracks.flatMap(\.regions).filter({ selectedRegionIDs.contains($0.id) }).map(\.start).min()
    else { return }
    let row = min(max(topRow + trackOffset, 0), order.count - 1)
    let command = PasteRegions(clipboard, at: max(.zero, start + offset), onTrack: order[row], trackOrder: order)
    if perform(command, named: clipboard.items.count == 1 ? "Copy Region" : "Copy Regions") {
      selectedRegionIDs = Set(command.newRegionIDs)
    }
  }

  var canDuplicateSelectedTrack: Bool {
    selectedTrack.map { !$0.isSummingStack } ?? false
  }

  func duplicateSelectedTrack() {
    guard let track = selectedTrack else { return }
    let command = DuplicateTrack(track.id)
    if perform(command) {
      selectedTrackID = command.copyID
      selectedRegionIDs = []
    }
  }

  // MARK: - Selecting

  func selectAllRegions() {
    selectedRegionIDs = Set(displayedTracks.flatMap(\.regions).map(\.id))
  }

  func selectAllRegions(onTrack trackID: Track.ID) {
    selectedTrackID = trackID
    selectedRegionIDs = Set(project.track(withID: trackID)?.regions.map(\.id) ?? [])
  }

  /// Logic's Select All Following: the region and every later one on its track.
  func selectAllFollowing(_ regionID: Region.ID) {
    guard let location = project.regionLocation(for: regionID) else { return }
    let track = project.tracks[location.track]
    let start = track.regions[location.region].start
    selectedTrackID = track.id
    selectedRegionIDs = Set(track.regions.filter { $0.start >= start }.map(\.id))
  }

  /// Selects the regions a rubber band touches: shown tracks `rows`, over `range` of time.
  func selectRegions(inRows rows: ClosedRange<Int>, over range: Range<Tick>, extending: Bool) {
    let tracks = displayedTracks
    let rows = rows.clamped(to: 0...max(0, tracks.count - 1))
    guard !tracks.isEmpty else { return }
    let touched = rows.flatMap { tracks[$0].regions }.filter { $0.start < range.upperBound && $0.end > range.lowerBound }
    selectedRegionIDs = extending ? selectedRegionIDs.union(touched.map(\.id)) : Set(touched.map(\.id))
  }

  // MARK: - Sections between the locators

  /// The locators: the cycle range, whether or not cycling is on (as in Logic).
  var locatorRange: Range<Tick>? {
    let cycle = project.cycle
    return cycle.end > cycle.start ? cycle.start..<cycle.end : nil
  }

  func cutSection() {
    guard let range = locatorRange else { return }
    if perform(CutSection(range)) { selectedRegionIDs = [] }
  }

  func insertSilence() {
    guard let range = locatorRange else { return }
    perform(InsertSilence(range))
  }

  func repeatSection(times: Int = 1) {
    guard let range = locatorRange else { return }
    perform(RepeatSection(range, times: times))
  }
}

/// A loop handle being dragged: the region, and where its loops would end.
struct LoopPreview: Equatable {
  var regionID: Region.ID
  var end: Tick
}

extension ProjectWindowModel {
  // MARK: - Loops

  /// Where dragging a region's loop handle to `position` ends its loops: snapped, and no
  /// earlier than the region's own end (which means no loops).
  func loopEnd(for regionID: Region.ID, draggedTo position: Tick) -> Tick? {
    guard let region = project.region(withID: regionID) else { return nil }
    return max(region.end, snap(position))
  }

  func finishLoopDrag(_ preview: LoopPreview) {
    guard let region = project.region(withID: preview.regionID), preview.end != (region.loopEnd ?? region.end) else { return }
    perform(SetRegionLoop(preview.regionID, to: preview.end))
  }

  var selectionHasLoops: Bool {
    project.tracks.flatMap(\.regions).contains { selectedRegionIDs.contains($0.id) && $0.isLooped }
  }

  /// Turns the selected regions' loops into regions of their own, and selects them all.
  func convertLoopsToRegions() {
    let before = Set(project.tracks.flatMap(\.regions).map(\.id))
    if perform(ConvertLoopsToRegions(selectedRegionIDs)) {
      let added = Set(project.tracks.flatMap(\.regions).map(\.id)).subtracting(before)
      selectedRegionIDs.formUnion(added)
    }
  }
}
