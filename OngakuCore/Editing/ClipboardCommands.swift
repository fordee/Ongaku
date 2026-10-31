//
//  ClipboardCommands.swift
//  OngakuCore
//

import Foundation

/// Regions that were copied, ready to paste: each with where it was relative to the first
/// one (in time, and in tracks down from the topmost), as Logic keeps them.
public struct RegionClipboard: Sendable, Equatable {
  public struct Item: Sendable, Equatable {
    /// Tracks below the topmost copied region's track.
    public var trackOffset: Int
    public var trackKind: TrackKind
    /// The region, with `start` counted from the earliest copied region's start.
    public var region: Region
  }

  public var items: [Item]
  /// The audio files the regions play, so a paste can tell whether they're in the project.
  public var audioFiles: [AudioFileReference]
  /// From the earliest start to the latest end.
  public var length: Tick

  /// Copies the regions with these identifiers. `trackOrder` is the tracks as shown, which
  /// track offsets count through. Returns `nil` if none of them are on those tracks.
  public init?(copying regionIDs: Set<Region.ID>, from project: Project, trackOrder: [Track.ID]) {
    var found: [(row: Int, kind: TrackKind, region: Region)] = []
    for (row, trackID) in trackOrder.enumerated() {
      guard let track = project.track(withID: trackID) else { continue }
      for region in track.regions where regionIDs.contains(region.id) {
        found.append((row, track.kind, region))
      }
    }
    guard let firstRow = found.map(\.row).min(), let start = found.map(\.region.start).min(),
      let end = found.map(\.region.end).max()
    else { return nil }
    items = found.map { row, kind, region in
      var copy = region
      copy.start = region.start - start
      return Item(trackOffset: row - firstRow, trackKind: kind, region: copy)
    }
    let fileIDs = Set(found.compactMap { item -> AudioFileReference.ID? in
      if case .audio(let audio) = item.region.content { return audio.fileID }
      return nil
    })
    audioFiles = project.audioFiles.filter { fileIDs.contains($0.id) }
    length = end - start
  }
}

/// Pastes copied regions: the first copied region's track lands on `trackID`, the rest keep
/// their places below it and their spacing in time from `position`, as in Logic.
public struct PasteRegions: EditCommand {
  public var clipboard: RegionClipboard
  public var position: Tick
  public var trackID: Track.ID
  /// The tracks as shown, which the clipboard's track offsets count through.
  public var trackOrder: [Track.ID]
  /// The pasted regions' identifiers, in the clipboard's order, so callers can select them.
  public var newRegionIDs: [Region.ID]

  public init(_ clipboard: RegionClipboard, at position: Tick, onTrack trackID: Track.ID, trackOrder: [Track.ID]) {
    self.clipboard = clipboard
    self.position = position
    self.trackID = trackID
    self.trackOrder = trackOrder
    newRegionIDs = clipboard.items.map { _ in UUID() }
  }

  public var actionName: String { clipboard.items.count == 1 ? "Paste Region" : "Paste Regions" }

  public func apply(to project: inout Project) throws {
    guard let firstRow = trackOrder.firstIndex(of: trackID) else { throw EditError.trackNotFound(trackID) }
    for (item, newID) in zip(clipboard.items, newRegionIDs) {
      let row = firstRow + item.trackOffset
      guard trackOrder.indices.contains(row), let trackIndex = project.trackIndex(for: trackOrder[row]) else {
        throw EditError.invalidValue("There aren't enough tracks below to paste onto.")
      }
      let kind = project.tracks[trackIndex].kind
      guard kind == item.trackKind else { throw EditError.trackKindMismatch(expected: item.trackKind, found: kind) }
      if case .audio(let audio) = item.region.content, project.audioFile(withID: audio.fileID) == nil {
        throw EditError.invalidValue("Audio regions can only be pasted into the project they were copied from.")
      }
      var region = item.region
      region.id = newID
      region.start = position + item.region.start
      project.tracks[trackIndex].regions.append(region)
      project.tracks[trackIndex].sortRegions()
    }
  }
}

/// Repeats regions: copies of them, keeping their spacing, laid end to end straight after
/// them (Logic's Repeat Regions), on their own tracks.
public struct RepeatRegions: EditCommand {
  public var regionIDs: Set<Region.ID>
  public var times: Int
  /// The copies' identifiers, so callers can select them.
  public private(set) var newRegionIDs: [Region.ID] = []

  public init(_ regionIDs: Set<Region.ID>, times: Int = 1) {
    self.regionIDs = regionIDs
    self.times = max(1, times)
    newRegionIDs = (0..<(regionIDs.count * self.times)).map { _ in UUID() }
  }

  public var actionName: String { regionIDs.count == 1 ? "Repeat Region" : "Repeat Regions" }

  public func apply(to project: inout Project) throws {
    let regions = project.tracks.flatMap(\.regions).filter { regionIDs.contains($0.id) }.sorted { $0.start < $1.start }
    guard let start = regions.map(\.start).min(), let end = regions.map(\.end).max() else {
      throw EditError.invalidValue("Select the regions to repeat.")
    }
    let span = end - start
    var ids = newRegionIDs.makeIterator()
    for repeatIndex in 1...times {
      for region in regions {
        guard let location = project.regionLocation(for: region.id), let id = ids.next() else { continue }
        var copy = region
        copy.id = id
        copy.start = region.start + span * Int64(repeatIndex)
        project.tracks[location.track].regions.append(copy)
        project.tracks[location.track].sortRegions()
      }
    }
  }
}

/// Duplicates a track, with its regions, channel strip and automation, just below it (and
/// in the same summing stack), like Logic's New Track With Duplicate Settings plus Copy
/// Contents. Its plug-ins are new instances with the same settings.
public struct DuplicateTrack: EditCommand {
  public var trackID: Track.ID
  /// The copy's identifier, so callers can select it.
  public var copyID: Track.ID

  public init(_ trackID: Track.ID, copyID: Track.ID = UUID()) {
    self.trackID = trackID
    self.copyID = copyID
  }

  public var actionName: String { "Duplicate Track" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    let original = project.tracks[index]
    guard !original.isSummingStack else {
      throw EditError.invalidValue("Summing stacks can't be duplicated yet; duplicate their tracks instead.")
    }
    var copy = original
    copy.id = copyID
    copy.name = project.copyName(for: original.name)
    copy.isRecordArmed = false
    copy.freezeFile = nil
    for regionIndex in copy.regions.indices {
      copy.regions[regionIndex].id = UUID()
    }
    // New plug-in instances, and automation that follows them.
    var pluginIDs: [PluginReference.ID: PluginReference.ID] = [:]
    for insertIndex in copy.channel.inserts.indices {
      let newID = UUID()
      pluginIDs[copy.channel.inserts[insertIndex].id] = newID
      copy.channel.inserts[insertIndex].id = newID
    }
    if case .audioUnit(var instrument) = copy.channel.instrument {
      instrument.id = UUID()
      copy.channel.instrument = .audioUnit(instrument)
    }
    var sendIDs: [Send.ID: Send.ID] = [:]
    for sendIndex in copy.channel.sends.indices {
      let newID = UUID()
      sendIDs[copy.channel.sends[sendIndex].id] = newID
      copy.channel.sends[sendIndex].id = newID
    }
    copy.automation = copy.automation.compactMap { lane in
      var lane = lane
      switch lane.parameter {
      case .plugin(var parameter):
        guard let newID = pluginIDs[parameter.pluginID] else { return nil }
        parameter.pluginID = newID
        lane.parameter = .plugin(parameter)
      case .sendLevel(let sendID):
        guard let newID = sendIDs[sendID] else { return nil }
        lane.parameter = .sendLevel(newID)
      default:
        break
      }
      return lane
    }
    project.tracks.insert(copy, at: index + 1)
  }
}

extension Project {
  /// A name for a copy of something called `name`, as Logic numbers copies ("Bass 2").
  func copyName(for name: String) -> String {
    let names = Set(tracks.map(\.name))
    // "Bass 2" copies to "Bass 3": count on from a trailing number.
    var base = name
    var number = 2
    if let space = name.lastIndex(of: " "), let trailing = Int(name[name.index(after: space)...]) {
      base = String(name[..<space])
      number = trailing + 1
    }
    while names.contains("\(base) \(number)") { number += 1 }
    return "\(base) \(number)"
  }
}
