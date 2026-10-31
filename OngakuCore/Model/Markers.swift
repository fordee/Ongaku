//
//  Markers.swift
//  OngakuCore
//

import Foundation

/// A named place on the timeline, as on Logic's Marker track.
public struct Marker: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  public var name: String
  public var position: Tick

  public init(id: UUID = UUID(), name: String, position: Tick) {
    self.id = id
    self.name = name
    self.position = position
  }
}

/// A part of the song (Intro, Verse, Chorus…) on Logic's Arrangement track. Moving,
/// duplicating or deleting a section does the same to everything in it.
public struct ArrangementSection: Identifiable, Codable, Sendable, Equatable {
  /// Logic's arrangement marker names, in the order it suggests them.
  public static let suggestedNames = ["Intro", "Verse", "Pre-Chorus", "Chorus", "Bridge", "Solo", "Breakdown", "Outro"]

  public var id: UUID
  public var name: String
  public var start: Tick
  public var length: Tick

  public init(id: UUID = UUID(), name: String, start: Tick, length: Tick) {
    self.id = id
    self.name = name
    self.start = start
    self.length = length
  }

  public var end: Tick { start + length }
  public var range: Range<Tick> { start..<end }

  /// Logic colours sections by name, so every Chorus looks alike.
  public var color: TrackColor {
    switch name.lowercased() {
    case "intro": .teal
    case "verse": .blue
    case "pre-chorus": .purple
    case "chorus": .orange
    case "bridge": .pink
    case "solo": .yellow
    case "breakdown": .green
    case "outro": .red
    default: .gray
    }
  }
}

extension Project {
  /// Moves everything that's placed on the timeline: regions (by their start), automation
  /// points and markers. `newPosition` returns `nil` to delete the item; positions it
  /// leaves unchanged stay put.
  mutating func remapTimeline(_ newPosition: (Tick) -> Tick?) {
    for trackIndex in tracks.indices {
      var regions: [Region] = []
      for var region in tracks[trackIndex].regions {
        guard let start = newPosition(region.start) else { continue }
        region.start = start
        regions.append(region)
      }
      tracks[trackIndex].regions = regions
      tracks[trackIndex].sortRegions()
      for laneIndex in tracks[trackIndex].automation.indices {
        let lane = tracks[trackIndex].automation[laneIndex]
        let points = lane.points.compactMap { point -> AutomationPoint? in
          guard let position = newPosition(point.position) else { return nil }
          var moved = point
          moved.position = position
          return moved
        }
        tracks[trackIndex].automation[laneIndex].setPoints(points)
      }
    }
    markers = markers.compactMap { marker in
      guard let position = newPosition(marker.position) else { return nil }
      var moved = marker
      moved.position = position
      return moved
    }
    sortMarkers()
    // Key changes go with the music; the key at the start stays put.
    keyChanges = keyChanges.compactMap { change in
      guard let position = newPosition(change.position), position > .zero else { return nil }
      var moved = change
      moved.position = position
      return moved
    }
    sortKeyChanges()
    removeRedundantKeyChanges()
  }

  mutating func sortMarkers() {
    markers.sort { $0.position < $1.position }
  }
}
