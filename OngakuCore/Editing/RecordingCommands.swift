//
//  RecordingCommands.swift
//  OngakuCore
//

import Foundation

/// Turns Logic's Autopunch on or off, or moves its range.
public struct SetPunch: EditCommand {
  public var punch: CycleRange

  public init(_ punch: CycleRange) {
    self.punch = punch
  }

  public var actionName: String { "Autopunch" }

  public func apply(to project: inout Project) throws {
    guard punch.end > punch.start, punch.start >= .zero else {
      throw EditError.invalidValue("The punch range must end after it starts.")
    }
    project.punch = punch
  }
}

/// Turns Logic's Replace recording on or off.
public struct SetReplaceRecording: EditCommand {
  public var isEnabled: Bool

  public init(_ isEnabled: Bool) {
    self.isEnabled = isEnabled
  }

  public var actionName: String { "Replace" }

  public func apply(to project: inout Project) throws {
    project.isReplaceRecording = isEnabled
  }
}

/// Clears a stretch of a track for a recording in Replace mode: regions crossing its edges
/// are cut there and what's inside goes. A region that can't be cut (a take folder, or
/// flexed audio) is left as it is, so the recording layers over it.
public struct ClearRangeForRecording: EditCommand {
  public var trackID: Track.ID
  public var range: Range<Tick>

  public init(_ range: Range<Tick>, on trackID: Track.ID) {
    self.trackID = trackID
    self.range = range
  }

  public var actionName: String { "Replace" }

  public func apply(to project: inout Project) throws {
    guard !range.isEmpty else { return }
    let index = try project.requireTrackIndex(trackID)
    for edge in [range.lowerBound, range.upperBound] {
      for region in project.tracks[index].regions where region.start < edge && edge < region.end && region.canEdit(.split) {
        try SplitRegion(region.id, at: edge).apply(to: &project)
      }
    }
    project.tracks[index].regions.removeAll { region in
      region.start >= range.lowerBound && region.end <= range.upperBound && region.canEdit(.split)
    }
  }
}

extension Project {
  /// Where a recording made over `range` keeps its takes: with Autopunch on, only where
  /// the range meets the punch; `nil` if it misses the punch entirely.
  public func punchedRange(of range: Range<Tick>) -> Range<Tick>? {
    guard punch.isEnabled else { return range }
    let start = max(range.lowerBound, punch.start), end = min(range.upperBound, punch.end)
    return start < end ? start..<end : nil
  }
}

/// Chooses the MIDI channel an instrument track plays and records from a keyboard (`nil`
/// for every channel), as Logic's MIDI input channel does.
public struct SetMIDIInputChannel: EditCommand {
  public var trackID: Track.ID
  public var channel: Int?

  public init(_ channel: Int?, for trackID: Track.ID) {
    self.trackID = trackID
    self.channel = channel
  }

  public var actionName: String { "MIDI Input Channel" }

  public func apply(to project: inout Project) throws {
    guard channel.map(MIDINote.channelRange.contains) ?? true else {
      throw EditError.invalidValue("MIDI channels run from 1 to 16.")
    }
    let index = try project.requireTrackIndex(trackID)
    guard project.tracks[index].kind == .softwareInstrument else {
      throw EditError.invalidValue("Only instrument tracks play from a MIDI keyboard.")
    }
    project.tracks[index].midiInputChannel = channel
  }
}
