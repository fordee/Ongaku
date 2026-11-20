//
//  SectionCommands.swift
//  OngakuCore
//

import Foundation

// Logic's section edits between the locators: they work on a stretch of time across every
// track at once, so a song can be shortened, opened up or extended. They share their work
// with the arrangement-marker edits (see TimelineEdits.swift).

/// Removes everything between two positions and closes the gap: what came after moves back.
public struct CutSection: EditCommand {
  public var range: Range<Tick>

  public init(_ range: Range<Tick>) {
    self.range = range
  }

  public var actionName: String { "Cut Section" }

  public func apply(to project: inout Project) throws {
    try project.requireSectionRange(range)
    try project.removeTime(range)
    let length = range.upperBound - range.lowerBound
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
    let length = range.upperBound - range.lowerBound
    try project.insertTime(at: range.lowerBound, length: length)
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
    try project.repeatTime(range, times: times)
    let added = (range.upperBound - range.lowerBound) * Int64(times)
    for index in project.arrangement.indices where project.arrangement[index].start >= range.upperBound {
      project.arrangement[index].start = project.arrangement[index].start + added
    }
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
