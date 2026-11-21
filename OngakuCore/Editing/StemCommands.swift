//
//  StemCommands.swift
//  OngakuCore
//

import Foundation

/// Logic's Stem Splitter result: each stem of an audio region on its own new audio track,
/// in a folder stack below the region's track (or in the region's stack, if its track is
/// already in one), each stem's region where the original was. The original region is muted
/// (or left playing), so the stems can be compared with it.
public struct SplitIntoStems: EditCommand {
  public struct Stem: Sendable {
    public var name: String
    public var file: AudioFileReference

    public init(name: String, file: AudioFileReference) {
      self.name = name
      self.file = file
    }
  }

  public var regionID: Region.ID
  public var stems: [Stem]
  /// The new tracks, one per stem, without regions (the app makes them with the settings'
  /// defaults); and the folder stack's main track (an aux track).
  public var newTracks: [Track]
  public var stack: Track
  public var mutesOriginal: Bool

  public init(_ regionID: Region.ID, stems: [Stem], into newTracks: [Track], stack: Track, mutesOriginal: Bool = true) {
    self.regionID = regionID
    self.stems = stems
    self.newTracks = newTracks
    self.stack = stack
    self.mutesOriginal = mutesOriginal
  }

  public var actionName: String { "Split into Stems" }

  public func apply(to project: inout Project) throws {
    guard let location = project.regionLocation(for: regionID) else { throw EditError.regionNotFound(regionID) }
    let track = project.tracks[location.track]
    let region = track.regions[location.region]
    guard case .audio = region.content else {
      throw EditError.invalidValue("Only audio regions can be split into stems.")
    }
    guard stems.count == newTracks.count, !stems.isEmpty else { throw EditError.invalidValue("There are no stems to add.") }
    for stem in stems { try AddAudioFile(stem.file).apply(to: &project) }

    var tracks: [Track] = []
    for (stem, newTrack) in zip(stems, newTracks) {
      var stemTrack = newTrack
      stemTrack.regions = [Region(
        name: "\(region.name) – \(stem.name)", start: region.start, length: region.length,
        content: .audio(AudioRegionContent(fileID: stem.file.id)))]
      tracks.append(stemTrack)
    }
    // After the region's track, and after its subtracks if it's a stack.
    var insertion = location.track + 1
    while insertion < project.tracks.count, project.tracks[insertion].stackID == track.id { insertion += 1 }
    if let stackID = track.stackID {
      // Already in a stack (they can't nest): the stems join it.
      let isSumming = project.track(withID: stackID)?.isSummingStack == true
      for index in tracks.indices {
        tracks[index].stackID = stackID
        if isSumming { tracks[index].channel.output = .track(stackID) }
      }
      project.tracks.insert(contentsOf: tracks, at: insertion)
    } else {
      var folder = stack
      folder.isFolderStack = true
      folder.stackID = nil
      guard folder.kind == .aux, project.trackIndex(for: folder.id) == nil else {
        throw EditError.invalidValue("The stems' folder must be a new aux track.")
      }
      for index in tracks.indices { tracks[index].stackID = folder.id }
      project.tracks.insert(contentsOf: [folder] + tracks, at: insertion)
    }
    if mutesOriginal {
      project.tracks[location.track].regions[location.region].isMuted = true
    }
  }
}
