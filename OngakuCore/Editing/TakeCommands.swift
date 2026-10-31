//
//  TakeCommands.swift
//  OngakuCore
//

import Foundation

extension Project {
  /// The track and region indexes of a take folder.
  func requireTakeFolder(_ regionID: Region.ID) throws -> (track: Int, region: Int) {
    let location = try requireRegionLocation(regionID)
    guard tracks[location.track].regions[location.region].takeFolder != nil else {
      throw EditError.invalidValue("The region isn’t a take folder.")
    }
    return location
  }
}

/// Quick-swipe comping: a take plays across part of its folder.
public struct CompTake: EditCommand {
  public var regionID: Region.ID
  public var takeID: Take.ID
  /// Relative to the folder's start.
  public var range: Range<Tick>

  public init(_ takeID: Take.ID, over range: Range<Tick>, in regionID: Region.ID) {
    self.regionID = regionID
    self.takeID = takeID
    self.range = range
  }

  public var actionName: String { "Comp" }

  public func apply(to project: inout Project) throws {
    let location = try project.requireTakeFolder(regionID)
    var region = project.tracks[location.track].regions[location.region]
    guard region.takeFolder?.take(withID: takeID) != nil else { throw EditError.invalidValue("The take no longer exists.") }
    let clamped = max(.zero, range.lowerBound)..<min(region.length, range.upperBound)
    guard !clamped.isEmpty else { return }
    region.updateTakeFolder { $0.use(takeID, over: clamped) }
    project.tracks[location.track].regions[location.region] = region
  }
}

/// Plays one take throughout its folder (choosing a take in Logic's take folder menu).
public struct SelectTake: EditCommand {
  public var regionID: Region.ID
  public var takeID: Take.ID

  public init(_ takeID: Take.ID, in regionID: Region.ID) {
    self.regionID = regionID
    self.takeID = takeID
  }

  public var actionName: String { "Select Take" }

  public func apply(to project: inout Project) throws {
    let location = try project.requireTakeFolder(regionID)
    var region = project.tracks[location.track].regions[location.region]
    guard region.takeFolder?.take(withID: takeID) != nil else { throw EditError.invalidValue("The take no longer exists.") }
    let length = region.length
    region.updateTakeFolder { $0.comp = [CompSection(start: .zero, end: length, takeID: takeID)] }
    project.tracks[location.track].regions[location.region] = region
  }
}

/// Renames a take ("Take 2" to "Best verse", say).
public struct RenameTake: EditCommand {
  public var regionID: Region.ID
  public var takeID: Take.ID
  public var name: String

  public init(_ takeID: Take.ID, in regionID: Region.ID, to name: String) {
    self.regionID = regionID
    self.takeID = takeID
    self.name = name
  }

  public var actionName: String { "Rename Take" }

  public func apply(to project: inout Project) throws {
    let location = try project.requireTakeFolder(regionID)
    var region = project.tracks[location.track].regions[location.region]
    guard region.takeFolder?.take(withID: takeID) != nil else { throw EditError.invalidValue("The take no longer exists.") }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw EditError.invalidValue("A take name can’t be empty.") }
    region.updateTakeFolder { folder in
      if let index = folder.takes.firstIndex(where: { $0.id == takeID }) { folder.takes[index].name = trimmed }
    }
    project.tracks[location.track].regions[location.region] = region
  }
}

/// Removes a take and its parts of the comp (they go silent, unless nothing else was used:
/// then the first take left plays throughout). A folder left with one take becomes a plain
/// region playing it, so a folder's last take is never deleted.
public struct DeleteTake: EditCommand {
  public var regionID: Region.ID
  public var takeID: Take.ID

  public init(_ takeID: Take.ID, from regionID: Region.ID) {
    self.regionID = regionID
    self.takeID = takeID
  }

  public var actionName: String { "Delete Take" }

  public func apply(to project: inout Project) throws {
    let location = try project.requireTakeFolder(regionID)
    var region = project.tracks[location.track].regions[location.region]
    guard let takes = region.takeFolder?.takes, takes.contains(where: { $0.id == takeID }) else {
      throw EditError.invalidValue("The take no longer exists.")
    }
    guard takes.count > 1 else { throw EditError.invalidValue("A take folder’s only take can’t be deleted.") }
    let length = region.length
    region.updateTakeFolder { folder in
      folder.takes.removeAll { $0.id == takeID }
      folder.comp.removeAll { $0.takeID == takeID }
      if folder.comp.isEmpty, let first = folder.takes.first {
        folder.comp = [CompSection(start: .zero, end: length, takeID: first.id)]
      }
    }
    if let folder = region.takeFolder, folder.takes.count == 1, let only = folder.takes.first {
      region.content = only.content
      region.takeFolder = nil
    }
    project.tracks[location.track].regions[location.region] = region
  }
}

/// Replaces a take folder with what its comp plays: for audio, a region per comp section
/// (each playing its take, with short fades where they meet); for MIDI, one region holding
/// each section's notes. As Logic's Flatten.
public struct FlattenTakeFolder: EditCommand {
  public var regionID: Region.ID

  public init(_ regionID: Region.ID) {
    self.regionID = regionID
  }

  public var actionName: String { "Flatten Take Folder" }

  public func apply(to project: inout Project) throws {
    let location = try project.requireTakeFolder(regionID)
    let folder = project.tracks[location.track].regions[location.region]
    var pieces = project.compRegions(of: folder)
    if case .midi = folder.content {
      // One MIDI region, keeping the folder's identity and bounds.
      var notes: [MIDINote] = []
      var controls: [MIDIControlEvent] = []
      for piece in pieces {
        guard case .midi(let sequence) = piece.content else { continue }
        let offset = piece.start - folder.start
        notes += sequence.notes.map { var note = $0; note.start += offset; return note }
        controls += sequence.controls.map { var event = $0; event.position += offset; return event }
      }
      var flat = folder
      flat.takeFolder = nil
      flat.content = .midi(MIDISequence(notes: notes, controls: controls))
      pieces = [flat]
    } else {
      // The first piece keeps the folder's identity.
      for index in pieces.indices {
        pieces[index].id = index == 0 ? folder.id : UUID()
      }
    }
    project.tracks[location.track].regions.remove(at: location.region)
    project.tracks[location.track].regions += pieces
    project.tracks[location.track].sortRegions()
  }
}

/// Packs regions on one track into a take folder, as Logic's Pack Take Folder: each region
/// becomes a take, and the comp plays what the regions played (where they overlap, the
/// later one in the track, which is the one heard on top).
public struct PackTakeFolder: EditCommand {
  public var regionIDs: Set<Region.ID>

  public init(_ regionIDs: Set<Region.ID>) {
    self.regionIDs = regionIDs
  }

  public var actionName: String { "Pack Take Folder" }

  public func apply(to project: inout Project) throws {
    let locations = try regionIDs.map { try project.requireRegionLocation($0) }
    guard let trackIndex = locations.first?.track, locations.allSatisfy({ $0.track == trackIndex }) else {
      throw EditError.invalidValue("Select regions on one track to pack them into a take folder.")
    }
    let regions = project.tracks[trackIndex].regions.filter { regionIDs.contains($0.id) }
    guard regions.count > 1 else { throw EditError.invalidValue("Select two or more regions to pack into a take folder.") }
    for region in regions { try region.requireNotTakeFolder() }

    let start = regions.map(\.start).min() ?? .zero
    let end = regions.map(\.end).max() ?? start
    var takes: [Take] = []
    for (index, region) in regions.enumerated() {
      let offset = region.start - start
      let content: RegionContent
      switch region.content {
      case .audio(var audio):
        // Line the take up with the folder's start: the frame that would play there.
        audio.fileStartFrame -= try project.audioFrames(from: start, to: region.start, fileID: audio.fileID)
        content = .audio(audio)
      case .midi(let sequence):
        let notes = sequence.notes.filter { $0.start >= .zero && $0.start < region.length }.map {
          var note = $0; note.start += offset; return note
        }
        let controls = sequence.controls.filter { $0.position >= .zero && $0.position < region.length }.map {
          var event = $0; event.position += offset; return event
        }
        content = .midi(MIDISequence(notes: notes, controls: controls))
      }
      takes.append(Take(name: "Take \(index + 1)", content: content))
    }

    var folder = TakeFolder(takes: takes, comp: [])
    for (region, take) in zip(regions, takes) {
      folder.use(take.id, over: (region.start - start)..<(region.end - start))
    }
    let lead = folder.comp.first?.takeID ?? takes[0].id
    var packed = regions[0]
    packed.start = start
    packed.length = end - start
    packed.isLooped = false
    packed.content = folder.take(withID: lead)?.content ?? takes[0].content
    packed.takeFolder = folder

    project.tracks[trackIndex].regions.removeAll { regionIDs.contains($0.id) }
    project.tracks[trackIndex].regions.append(packed)
    project.tracks[trackIndex].sortRegions()
  }
}
