//
//  TakeFolder.swift
//  OngakuCore
//

import Foundation

/// One recorded performance in a take folder. Every take lines up with the folder's start:
/// an audio take's `fileStartFrame` is the frame that would play there, and a MIDI take's
/// positions count from there.
public struct Take: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  /// "Take 1", "Take 2"…
  public var name: String
  public var content: RegionContent

  public init(id: UUID = UUID(), name: String, content: RegionContent) {
    self.id = id
    self.name = name
    self.content = content
  }
}

/// A stretch of a take folder and the take that plays there. Positions count from the
/// folder's start.
public struct CompSection: Codable, Sendable, Equatable {
  public var start: Tick
  public var end: Tick
  public var takeID: Take.ID

  public init(start: Tick, end: Tick, takeID: Take.ID) {
    self.start = start
    self.end = end
    self.takeID = takeID
  }

  public var range: Range<Tick> { start..<end }
}

/// Logic's take folder: several takes of the same part, and the comp, which says which take
/// plays where. Parts of the folder no section covers are silent.
///
/// The region's own `content` is always the take of the first comp section (the "lead
/// take"), so editors and drawing work on it as on any region; `Region.leadTakeID` names it.
/// Edits to it are written back into the take whenever the comp changes.
public struct TakeFolder: Codable, Sendable, Equatable {
  /// Oldest first.
  public var takes: [Take]
  /// Sorted by start, never overlapping.
  public var comp: [CompSection]

  public init(takes: [Take], comp: [CompSection]) {
    self.takes = takes
    self.comp = comp
  }

  /// A folder playing one take throughout `length`.
  public init(takes: [Take], playing takeID: Take.ID, length: Tick) {
    self.takes = takes
    comp = [CompSection(start: .zero, end: length, takeID: takeID)]
  }

  public func take(withID id: Take.ID) -> Take? {
    takes.first { $0.id == id }
  }

  /// Quick-swipe comping: `takeID` plays across `range`, replacing whatever played there.
  /// Neighbouring sections of the same take join up.
  public mutating func use(_ takeID: Take.ID, over range: Range<Tick>) {
    guard !range.isEmpty else { return }
    var sections: [CompSection] = []
    for section in comp {
      if section.end <= range.lowerBound || section.start >= range.upperBound {
        sections.append(section)
        continue
      }
      // Keep the parts outside the range.
      if section.start < range.lowerBound {
        sections.append(CompSection(start: section.start, end: range.lowerBound, takeID: section.takeID))
      }
      if section.end > range.upperBound {
        sections.append(CompSection(start: range.upperBound, end: section.end, takeID: section.takeID))
      }
    }
    sections.append(CompSection(start: range.lowerBound, end: range.upperBound, takeID: takeID))
    sections.sort { $0.start < $1.start }
    var joined: [CompSection] = []
    for section in sections {
      if var last = joined.last, last.takeID == section.takeID, last.end == section.start {
        last.end = section.end
        joined[joined.count - 1] = last
      } else {
        joined.append(section)
      }
    }
    comp = joined
  }

  /// Which take plays at a position, if any.
  public func takeID(at position: Tick) -> Take.ID? {
    comp.first { $0.range.contains(position) }?.takeID
  }
}

extension Region {
  /// The take the region's `content` is: the first comp section's, or the first take's.
  public var leadTakeID: Take.ID? {
    guard let folder = takeFolder else { return nil }
    return folder.comp.first?.takeID ?? folder.takes.first?.id
  }

  /// A take's content, with the lead take's coming from the region (where editors change it).
  public func content(ofTake id: Take.ID) -> RegionContent? {
    if id == leadTakeID { return content }
    return takeFolder?.take(withID: id)?.content
  }

  /// Changes the take folder, first saving edits made to the lead take, then making the
  /// region's content the new lead take.
  public mutating func updateTakeFolder(_ change: (inout TakeFolder) -> Void) {
    guard var folder = takeFolder else { return }
    if let lead = leadTakeID, let index = folder.takes.firstIndex(where: { $0.id == lead }) {
      folder.takes[index].content = content
    }
    change(&folder)
    takeFolder = folder
    if let lead = leadTakeID, let take = folder.take(withID: lead) {
      content = take.content
    }
  }
}

extension Project {
  /// How a track's regions play: loops repeated (see `Track.playedRegions`) and each take
  /// folder split into its comp, a plain region per section playing that section's take.
  public func playedRegions(of track: Track) -> [Region] {
    track.playedRegions(until: endPosition).flatMap { region in
      region.takeFolder == nil ? [region] : compRegions(of: region)
    }
  }

  /// Short fades where one comp section meets the next, so the switch doesn't click.
  static let compCrossfade = 0.005

  /// A take folder's comp as plain regions, one per section.
  public func compRegions(of region: Region) -> [Region] {
    guard let folder = region.takeFolder else { return [region] }
    let sections = folder.comp.filter { $0.start < region.length && $0.end > $0.start }
    return sections.enumerated().compactMap { index, section -> Region? in
      guard let content = region.content(ofTake: section.takeID) else { return nil }
      var piece = region
      piece.takeFolder = nil
      piece.isLooped = false
      piece.start = region.start + section.start
      piece.length = min(section.end, region.length) - section.start
      switch content {
      case .audio(var audio):
        guard let frames = try? audioFrames(from: region.start, to: piece.start, fileID: audio.fileID) else { return nil }
        audio.fileStartFrame += frames
        // The folder's own gain and outer fades apply; inner edges get a short fade.
        guard case .audio(let folderAudio) = region.content else { return nil }
        audio.gain = folderAudio.gain
        audio.fadeIn = section.start == .zero ? folderAudio.fadeIn : Self.compCrossfade
        audio.fadeOut = index == sections.count - 1 && section.end >= region.length ? folderAudio.fadeOut : Self.compCrossfade
        piece.content = .audio(audio)
      case .midi(let sequence):
        let notes = sequence.notes.filter { section.range.contains($0.start) }.map { note in
          var moved = note
          moved.start -= section.start
          return moved
        }
        let controls = sequence.controls.filter { section.range.contains($0.position) }.map { event in
          var moved = event
          moved.position -= section.start
          return moved
        }
        piece.content = .midi(MIDISequence(notes: notes, controls: controls))
      }
      return piece
    }
  }
}
