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
  mutating func sortMarkers() {
    markers.sort { $0.position < $1.position }
  }
}
