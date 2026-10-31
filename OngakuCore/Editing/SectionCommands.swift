//
//  SectionCommands.swift
//  OngakuCore
//

import Foundation

// Logic's section edits between the locators: they work on a stretch of time across every
// track at once, so a song can be shortened, opened up or extended. Regions that cross the
// edges of the stretch are split there first; automation points and markers in it go with it.

/// Removes everything between two positions and closes the gap: what came after moves back.
public struct CutSection: EditCommand {
  public var range: Range<Tick>

  public init(_ range: Range<Tick>) {
    self.range = range
  }

  public var actionName: String { "Cut Section" }

  public func apply(to project: inout Project) throws {
    try project.requireSectionRange(range)
    try project.splitRegions(at: range.lowerBound)
    try project.splitRegions(at: range.upperBound)
    let length = range.upperBound - range.lowerBound
    project.remapTimeline { position in
      if range.contains(position) { return nil }
      return position >= range.upperBound ? position - length : position
    }
    project.arrangement = project.arrangement.compactMap { section in
      // Sections lose the part that was cut, and later ones move back.
      let start = section.start >= range.upperBound ? section.start - length : min(section.start, range.lowerBound)
      let end = section.end >= range.upperBound ? section.end - length : min(section.end, range.lowerBound)
      guard end > start else { return nil }
      var moved = section
      moved.start = start
      moved.length = end - start
      return moved
    }
  }
}

/// Opens up empty time between two positions: what came after the first moves later.
public struct InsertSilence: EditCommand {
  public var range: Range<Tick>

  public init(_ range: Range<Tick>) {
    self.range = range
  }

  public var actionName: String { "Insert Silence" }

  public func apply(to project: inout Project) throws {
    try project.requireSectionRange(range)
    try project.splitRegions(at: range.lowerBound)
    let length = range.upperBound - range.lowerBound
    project.remapTimeline { $0 >= range.lowerBound ? $0 + length : $0 }
    for index in project.arrangement.indices {
      if project.arrangement[index].start >= range.lowerBound {
        project.arrangement[index].start = project.arrangement[index].start + length
      } else if project.arrangement[index].end > range.lowerBound {
        // A section the silence falls inside grows by it.
        project.arrangement[index].length = project.arrangement[index].length + length
      }
    }
  }
}

/// Repeats everything between two positions straight after them, `times` times; what came
/// after moves later to make room.
public struct RepeatSection: EditCommand {
  public var range: Range<Tick>
  public var times: Int

  public init(_ range: Range<Tick>, times: Int = 1) {
    self.range = range
    self.times = max(1, times)
  }

  public var actionName: String { "Repeat Section" }

  public func apply(to project: inout Project) throws {
    try project.requireSectionRange(range)
    try project.splitRegions(at: range.lowerBound)
    try project.splitRegions(at: range.upperBound)
    let length = range.upperBound - range.lowerBound
    let added = length * Int64(times)

    // What's in the section, copied before anything moves.
    let copiedRegions: [[Region]] = project.tracks.map { track in
      track.regions.filter { range.contains($0.start) }.flatMap { region in
        (1...times).map { repeatIndex in
          var copy = region
          copy.id = UUID()
          copy.start = region.start + length * Int64(repeatIndex)
          return copy
        }
      }
    }
    let copiedPoints: [[AutomationParameter: [AutomationPoint]]] = project.tracks.map { track in
      Dictionary(uniqueKeysWithValues: track.automation.map { lane in
        (lane.parameter, lane.points.filter { range.contains($0.position) }.flatMap { point in
          (1...times).map { AutomationPoint(position: point.position + length * Int64($0), value: point.value) }
        })
      })
    }
    let copiedMarkers = project.markers.filter { range.contains($0.position) }.flatMap { marker in
      (1...times).map { Marker(name: marker.name, position: marker.position + length * Int64($0)) }
    }

    project.remapTimeline { $0 >= range.upperBound ? $0 + added : $0 }
    for index in project.arrangement.indices where project.arrangement[index].start >= range.upperBound {
      project.arrangement[index].start = project.arrangement[index].start + added
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
  }
}

extension Project {
  func requireSectionRange(_ range: Range<Tick>) throws {
    guard range.lowerBound >= .zero, !range.isEmpty else {
      throw EditError.invalidValue("Set the locators (the cycle range) around the section first.")
    }
  }

  /// Splits every region that crosses `position` there, so section edits cut cleanly.
  mutating func splitRegions(at position: Tick) throws {
    let crossing = tracks.flatMap(\.regions).filter { $0.start < position && position < $0.end }
    for region in crossing {
      do {
        try SplitRegion(region.id, at: position).apply(to: &self)
      } catch {
        throw EditError.invalidValue(
          "“\(region.name)” crosses the edge of the section and can't be split there: \(error.localizedDescription)")
      }
    }
  }
}
