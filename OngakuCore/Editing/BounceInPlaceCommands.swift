//
//  BounceInPlaceCommands.swift
//  OngakuCore
//

import Foundation

/// What a render of one track on its own keeps, as in Logic's Bounce in Place and Export All
/// Tracks dialogs.
public struct TrackRenderOptions: Codable, Sendable, Equatable {
  /// The track's insert plug-ins (its instrument and MIDI effects always play).
  public var includesEffects: Bool
  /// The fader and pan, with their automation. Off, the render is at unity and centre.
  public var includesVolumeAndPan: Bool

  public init(includesEffects: Bool = true, includesVolumeAndPan: Bool = false) {
    self.includesEffects = includesEffects
    self.includesVolumeAndPan = includesVolumeAndPan
  }
}

extension Project {
  /// The project with only one track playing, straight to Stereo Out, for rendering it on
  /// its own: no sends, stack, mute or solo, and Stereo Out at unity with no plug-ins.
  /// `regionIDs` limits it to some of its regions. `nil` if the track has no regions to play.
  public func isolating(
    _ trackID: Track.ID, regionIDs: Set<Region.ID>? = nil, options: TrackRenderOptions
  ) -> Project? {
    guard var track = track(withID: trackID), track.kind.hasRegions else { return nil }
    if let regionIDs { track.regions.removeAll { !regionIDs.contains($0.id) } }
    guard track.regions.contains(where: { !$0.isMuted }) else { return nil }

    if !options.includesEffects { track.channel.inserts = [] }
    let plugins = Set(track.channel.plugins.map(\.id))
    track.automation = track.automation.filter { lane in
      switch lane.parameter {
      case .volume, .pan: options.includesVolumeAndPan
      case .sendLevel: false
      case .plugin(let parameter): plugins.contains(parameter.pluginID)
      }
    }
    if !options.includesVolumeAndPan {
      track.channel.volume = 0
      track.channel.pan = 0
    }
    track.channel.isMuted = false
    track.channel.isSoloed = false
    track.channel.sends = []
    track.channel.output = .stereoOut
    track.stackID = nil
    track.isRecordArmed = false
    track.isInputMonitored = false

    var alone = self
    alone.tracks = [track]
    alone.masterVolume = 0
    alone.stereoOutInserts = []
    return alone
  }

  /// Where the regions of a track (all of them, or `regionIDs`) start and end.
  public func span(ofTrack trackID: Track.ID, regionIDs: Set<Region.ID>? = nil) -> Range<Tick>? {
    let regions = track(withID: trackID)?.regions.filter { regionIDs?.contains($0.id) ?? true } ?? []
    guard let start = regions.map(\.start).min(), let end = regions.map(\.end).max(), start < end else { return nil }
    return start..<end
  }
}

/// Logic's Bounce in Place: a track's regions, rendered through its instrument and plug-ins,
/// become one audio region on a new audio track just below it. The regions bounced can be
/// left, muted or deleted. The file was rendered with `Project.isolating`.
public struct BounceInPlace: EditCommand {
  public enum Source: String, Codable, Sendable, CaseIterable {
    case leave, mute, delete

    public var name: String {
      switch self {
      case .leave: "Leave"
      case .mute: "Mute"
      case .delete: "Delete"
      }
    }
  }

  public var trackID: Track.ID
  public var regionIDs: Set<Region.ID>
  public var file: AudioFileReference
  /// The new track, without regions (the app makes it, with the settings' defaults).
  public var newTrack: Track
  public var source: Source

  public init(_ trackID: Track.ID, regions regionIDs: Set<Region.ID>, file: AudioFileReference, into newTrack: Track, source: Source) {
    self.trackID = trackID
    self.regionIDs = regionIDs
    self.file = file
    self.newTrack = newTrack
    self.source = source
  }

  public var actionName: String { "Bounce in Place" }

  public func apply(to project: inout Project) throws {
    guard let index = project.trackIndex(for: trackID) else { throw EditError.trackNotFound(trackID) }
    let track = project.tracks[index]
    guard let span = project.span(ofTrack: trackID, regionIDs: regionIDs) else {
      throw EditError.invalidValue("There’s nothing on “\(track.name)” to bounce.")
    }
    try AddAudioFile(file).apply(to: &project)

    var bounced = newTrack
    bounced.regions = [Region.audio(for: file, at: span.lowerBound, tempoMap: project.tempoMap, name: "\(track.name) Bounce")]
    // A track in a stack bounces into the stack.
    if let stackID = track.stackID {
      bounced.stackID = stackID
      if project.track(withID: stackID)?.isSummingStack == true { bounced.channel.output = .track(stackID) }
    }
    try AddTrack(bounced, at: index + 1).apply(to: &project)

    switch source {
    case .leave: break
    case .mute:
      for region in project.tracks[index].regions.indices where regionIDs.contains(project.tracks[index].regions[region].id) {
        project.tracks[index].regions[region].isMuted = true
      }
    case .delete:
      project.tracks[index].regions.removeAll { regionIDs.contains($0.id) }
    }
  }
}
