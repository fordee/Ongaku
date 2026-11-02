//
//  ProjectWindowModel+Markers.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// The global tracks under the ruler, as in Logic (G shows them): Arrangement, Marker,
/// Signature and Tempo. This file has the first two; see ProjectWindowModel+TempoTrack.
extension ProjectWindowModel {
  /// How tall each global track row is.
  nonisolated static let globalTrackHeight: CGFloat = 22

  /// The ruler plus the global tracks: where the tracks start.
  var topHeight: CGFloat {
    Layout.rulerHeight + (isGlobalTracksVisible ? Self.globalTrackHeight * 4 + Self.tempoTrackHeight : 0)
  }

  func toggleGlobalTracks() {
    isGlobalTracksVisible.toggle()
  }

  /// Something being renamed in a sheet.
  enum RenameTarget: Identifiable, Equatable {
    case marker(Marker.ID)
    case section(ArrangementSection.ID)

    var id: UUID {
      switch self {
      case .marker(let id), .section(let id): id
      }
    }
  }

  // MARK: - Markers

  /// Navigate › Create Marker: a marker at the playhead (snapped), named in order.
  func createMarker(at position: Tick? = nil) {
    let position = position ?? snap(engine.playheadPosition)
    guard !project.markers.contains(where: { $0.position == position }) else { return }
    let marker = Marker(name: "Marker \(nextMarkerNumber)", position: position)
    perform(AddMarker(marker))
    isGlobalTracksVisible = true
  }

  /// One past the highest "Marker N", rather than the count, so deleting a marker doesn't
  /// lead to two with the same name.
  private var nextMarkerNumber: Int {
    let numbers = project.markers.compactMap { marker -> Int? in
      guard marker.name.hasPrefix("Marker ") else { return nil }
      return Int(marker.name.dropFirst("Marker ".count))
    }
    return (numbers.max() ?? 0) + 1
  }

  /// The previous or next marker from the playhead, as Logic's Option-comma and
  /// Option-period do.
  func goToMarker(forward: Bool) {
    let playhead = engine.playheadPosition
    let target = forward
      ? project.markers.first { $0.position > playhead }
      : project.markers.last { $0.position < playhead }
    if let target {
      engine.locate(to: target.position)
    }
  }

  func moveMarker(_ id: Marker.ID, to position: Tick) {
    guard var marker = project.markers.first(where: { $0.id == id }) else { return }
    marker.position = max(.zero, snap(position))
    perform(UpdateMarker(marker))
  }

  func deleteMarker(_ id: Marker.ID) {
    perform(DeleteMarkers([id]))
  }

  // MARK: - Arrangement

  /// The + on the Arrangement track: an eight-bar section after the last one, named after
  /// the next of Logic's suggestions.
  func addArrangementSection() {
    let tempoMap = project.tempoMap
    let start = project.arrangement.last?.end ?? .zero
    let bar = tempoMap.bar(containing: start)
    let startBar = bar.start == start ? bar.index : bar.index + 1
    let sectionStart = tempoMap.tickPosition(ofBarIndex: startBar)
    let end = tempoMap.tickPosition(ofBarIndex: startBar + 8)
    let names = ArrangementSection.suggestedNames
    let name = names[project.arrangement.count % names.count]
    let section = ArrangementSection(name: name, start: sectionStart, length: end - sectionStart)
    perform(AddArrangementSection(section))
    selectedSectionID = section.id
    isGlobalTracksVisible = true
  }

  /// Drops a dragged section where its left edge lands: before the first section whose
  /// middle it's left of.
  func moveSection(_ id: ArrangementSection.ID, droppedAt position: Tick) {
    let others = project.arrangement.filter { $0.id != id }
    let index = others.firstIndex { position < $0.start + Tick($0.length.rawValue / 2) } ?? others.count
    perform(MoveArrangementSection(id, toIndex: index))
  }

  func renameSection(_ id: ArrangementSection.ID, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var section = project.arrangement.first(where: { $0.id == id }), !trimmed.isEmpty else { return }
    section.name = trimmed
    perform(UpdateArrangementSection(section))
  }

  func renameMarker(_ id: Marker.ID, to name: String) {
    guard var marker = project.markers.first(where: { $0.id == id }) else { return }
    marker.name = name
    perform(UpdateMarker(marker))
  }

  /// Dragging a section's right edge: its length changes, its contents stay where they are.
  func resizeSection(_ id: ArrangementSection.ID, end: Tick) {
    guard var section = project.arrangement.first(where: { $0.id == id }) else { return }
    let snapped = snap(end)
    guard snapped > section.start else { return }
    section.length = snapped - section.start
    perform(UpdateArrangementSection(section))
  }

  func duplicateSection(_ id: ArrangementSection.ID) {
    let command = DuplicateArrangementSection(id)
    perform(command)
    selectedSectionID = command.copyID
  }

  func deleteSection(_ id: ArrangementSection.ID) {
    perform(DeleteArrangementSection(id))
    if selectedSectionID == id { selectedSectionID = nil }
  }

  /// Clicking a section selects it and, as in Logic, the regions in it.
  func selectSection(_ id: ArrangementSection.ID) {
    selectedSectionID = id
    guard let section = project.arrangement.first(where: { $0.id == id }) else { return }
    selectedRegionIDs = Set(project.tracks.flatMap(\.regions).filter { section.range.contains($0.start) }.map(\.id))
  }
}
