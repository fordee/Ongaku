//
//  LoopCommands.swift
//  OngakuCore
//

import Foundation

/// Sets where a region's loops end, as dragging the upper half of its right edge does in
/// Logic: the region repeats up to `end` (the last repeat stopping part way if need be).
/// An end at or before the region's own end turns looping off.
public struct SetRegionLoop: EditCommand {
  public var regionID: Region.ID
  public var end: Tick

  public init(_ regionID: Region.ID, to end: Tick) {
    self.regionID = regionID
    self.end = end
  }

  public var actionName: String { "Loop Region" }

  public func apply(to project: inout Project) throws {
    let location = try project.requireRegionLocation(regionID)
    var region = project.tracks[location.track].regions[location.region]
    try region.requireNotTakeFolder()
    if end > region.end {
      region.isLooped = true
      region.loopedLength = end - region.start
    } else {
      region.isLooped = false
      region.loopedLength = nil
    }
    project.tracks[location.track].regions[location.region] = region
  }
}

/// Logic's Convert Loops to Regions: each repeat of a looped region becomes a region of its
/// own (a copy, which can then be edited by itself), and the original stops looping.
public struct ConvertLoopsToRegions: EditCommand {
  public var regionIDs: Set<Region.ID>

  public init(_ regionIDs: Set<Region.ID>) {
    self.regionIDs = regionIDs
  }

  public var actionName: String { "Convert Loops to Regions" }

  public func apply(to project: inout Project) throws {
    var converted = false
    for trackIndex in project.tracks.indices {
      let track = project.tracks[trackIndex]
      let looped = track.regions.filter { regionIDs.contains($0.id) && $0.isLooped }
      guard !looped.isEmpty else { continue }
      let played = track.playedRegions(until: project.endPosition)
      for region in looped {
        // The repeats are the played copies of this region after the original.
        let repeats = played.filter { $0.id == region.id && $0.start > region.start }.map { piece in
          var copy = piece
          copy.id = UUID()
          copy.loopedLength = nil
          return copy
        }
        guard let index = project.tracks[trackIndex].regions.firstIndex(where: { $0.id == region.id }) else { continue }
        project.tracks[trackIndex].regions[index].isLooped = false
        project.tracks[trackIndex].regions[index].loopedLength = nil
        project.tracks[trackIndex].regions += repeats
        converted = true
      }
      project.tracks[trackIndex].sortRegions()
    }
    guard converted else { throw EditError.invalidValue("None of the selected regions are looped.") }
  }
}
