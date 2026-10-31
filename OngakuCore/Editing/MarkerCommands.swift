//
//  MarkerCommands.swift
//  OngakuCore
//

import Foundation

// MARK: - Markers

public struct AddMarker: EditCommand {
  public var marker: Marker

  public init(_ marker: Marker) {
    self.marker = marker
  }

  public var actionName: String { "Create Marker" }

  public func apply(to project: inout Project) throws {
    guard marker.position >= .zero else { throw EditError.invalidValue("Markers can’t be before the project start.") }
    guard !project.markers.contains(where: { $0.id == marker.id }) else { throw EditError.duplicateID(marker.id) }
    project.markers.append(marker)
    project.sortMarkers()
  }
}

public struct DeleteMarkers: EditCommand {
  public var markerIDs: Set<Marker.ID>

  public init(_ markerIDs: Set<Marker.ID>) {
    self.markerIDs = markerIDs
  }

  public var actionName: String { markerIDs.count == 1 ? "Delete Marker" : "Delete Markers" }

  public func apply(to project: inout Project) throws {
    project.markers.removeAll { markerIDs.contains($0.id) }
  }
}

/// Moves or renames a marker.
public struct UpdateMarker: EditCommand {
  public var marker: Marker

  public init(_ marker: Marker) {
    self.marker = marker
  }

  public var actionName: String { "Change Marker" }

  public func apply(to project: inout Project) throws {
    guard let index = project.markers.firstIndex(where: { $0.id == marker.id }) else {
      throw EditError.invalidValue("The marker no longer exists.")
    }
    guard marker.position >= .zero else { throw EditError.invalidValue("Markers can’t be before the project start.") }
    let name = marker.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw EditError.invalidValue("Markers need a name.") }
    project.markers[index] = marker
    project.markers[index].name = name
    project.sortMarkers()
  }
}

// MARK: - Arrangement

/// Adds a section to the Arrangement track. Sections can't overlap.
public struct AddArrangementSection: EditCommand {
  public var section: ArrangementSection

  public init(_ section: ArrangementSection) {
    self.section = section
  }

  public var actionName: String { "Add Arrangement Marker" }

  public func apply(to project: inout Project) throws {
    guard section.start >= .zero, section.length > .zero else {
      throw EditError.invalidValue("A section needs a positive length and can’t start before the project start.")
    }
    guard !project.arrangement.contains(where: { $0.range.overlaps(section.range) }) else {
      throw EditError.invalidValue("Arrangement sections can’t overlap.")
    }
    project.arrangement.append(section)
    project.arrangement.sort { $0.start < $1.start }
  }
}

/// Renames or resizes a section. Its contents don't move.
public struct UpdateArrangementSection: EditCommand {
  public var section: ArrangementSection

  public init(_ section: ArrangementSection) {
    self.section = section
  }

  public var actionName: String { "Change Arrangement Marker" }

  public func apply(to project: inout Project) throws {
    guard let index = project.arrangement.firstIndex(where: { $0.id == section.id }) else {
      throw EditError.invalidValue("The section no longer exists.")
    }
    guard section.start >= .zero, section.length > .zero else {
      throw EditError.invalidValue("A section needs a positive length and can’t start before the project start.")
    }
    guard !project.arrangement.contains(where: { $0.id != section.id && $0.range.overlaps(section.range) }) else {
      throw EditError.invalidValue("Arrangement sections can’t overlap.")
    }
    project.arrangement[index] = section
    project.arrangement.sort { $0.start < $1.start }
  }
}

/// Moves a section to another place in the song order, as dragging it in Logic's
/// Arrangement track does: the sections are laid end to end again from where the first one
/// starts, and everything in each one (regions that start in it, automation, markers)
/// moves with it.
public struct MoveArrangementSection: EditCommand {
  public var sectionID: ArrangementSection.ID
  /// Where it goes in the order of sections, counted without it.
  public var index: Int

  public init(_ sectionID: ArrangementSection.ID, toIndex index: Int) {
    self.sectionID = sectionID
    self.index = index
  }

  public var actionName: String { "Move Arrangement Marker" }

  public func apply(to project: inout Project) throws {
    guard let from = project.arrangement.firstIndex(where: { $0.id == sectionID }) else {
      throw EditError.invalidValue("The section no longer exists.")
    }
    let old = project.arrangement
    var order = old
    let moved = order.remove(at: from)
    order.insert(moved, at: min(max(0, index), order.count))
    guard order.map(\.id) != old.map(\.id), let firstStart = old.first?.start else { return }

    // Lay the sections out end to end, then move each one's contents by as much as it moved.
    var cursor = firstStart
    var shifts: [(range: Range<Tick>, offset: Tick)] = []
    var placed: [ArrangementSection] = []
    for var section in order {
      shifts.append((section.range, cursor - section.start))
      section.start = cursor
      placed.append(section)
      cursor = cursor + section.length
    }
    project.remapTimeline { position in
      guard let shift = shifts.first(where: { $0.range.contains(position) }) else { return position }
      return position + shift.offset
    }
    project.arrangement = placed
  }
}

/// Deletes a section and everything in it, and closes the gap: what comes after moves
/// back, as in Logic.
public struct DeleteArrangementSection: EditCommand {
  public var sectionID: ArrangementSection.ID

  public init(_ sectionID: ArrangementSection.ID) {
    self.sectionID = sectionID
  }

  public var actionName: String { "Delete Arrangement Marker" }

  public func apply(to project: inout Project) throws {
    guard let section = project.arrangement.first(where: { $0.id == sectionID }) else {
      throw EditError.invalidValue("The section no longer exists.")
    }
    project.remapTimeline { position in
      if section.range.contains(position) { return nil }
      return position >= section.end ? position - section.length : position
    }
    project.arrangement.removeAll { $0.id == sectionID }
    for index in project.arrangement.indices where project.arrangement[index].start >= section.end {
      project.arrangement[index].start = project.arrangement[index].start - section.length
    }
  }
}

/// Inserts a copy of a section, and everything in it, straight after it; what comes after
/// moves later to make room.
public struct DuplicateArrangementSection: EditCommand {
  public var sectionID: ArrangementSection.ID
  /// The copy's identifier, so callers can select it.
  public var copyID: ArrangementSection.ID

  public init(_ sectionID: ArrangementSection.ID, copyID: ArrangementSection.ID = UUID()) {
    self.sectionID = sectionID
    self.copyID = copyID
  }

  public var actionName: String { "Duplicate Arrangement Marker" }

  public func apply(to project: inout Project) throws {
    guard let section = project.arrangement.first(where: { $0.id == sectionID }) else {
      throw EditError.invalidValue("The section no longer exists.")
    }
    let length = section.length
    // What's in the section, copied before anything moves.
    let copiedRegions: [[Region]] = project.tracks.map { track in
      track.regions.filter { section.range.contains($0.start) }.map { region in
        var copy = region
        copy.id = UUID()
        copy.start = copy.start + length
        return copy
      }
    }
    let copiedPoints: [[AutomationParameter: [AutomationPoint]]] = project.tracks.map { track in
      Dictionary(uniqueKeysWithValues: track.automation.map { lane in
        (lane.parameter, lane.points.filter { section.range.contains($0.position) }.map {
          AutomationPoint(position: $0.position + length, value: $0.value)
        })
      })
    }
    let copiedMarkers = project.markers.filter { section.range.contains($0.position) }.map {
      Marker(name: $0.name, position: $0.position + length)
    }

    project.remapTimeline { $0 >= section.end ? $0 + length : $0 }
    for index in project.arrangement.indices where project.arrangement[index].start >= section.end {
      project.arrangement[index].start = project.arrangement[index].start + length
    }
    for trackIndex in project.tracks.indices {
      project.tracks[trackIndex].regions += copiedRegions[trackIndex]
      project.tracks[trackIndex].sortRegions()
      for laneIndex in project.tracks[trackIndex].automation.indices {
        let lane = project.tracks[trackIndex].automation[laneIndex]
        project.tracks[trackIndex].automation[laneIndex].setPoints(lane.points + (copiedPoints[trackIndex][lane.parameter] ?? []))
      }
    }
    project.markers += copiedMarkers
    project.sortMarkers()
    project.arrangement.append(ArrangementSection(id: copyID, name: section.name, start: section.end, length: length))
    project.arrangement.sort { $0.start < $1.start }
  }
}
