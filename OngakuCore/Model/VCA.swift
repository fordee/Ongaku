//
//  VCA.swift
//  OngakuCore
//

import Foundation

/// Logic's VCA fader: a fader with no audio of its own that moves the faders of every channel
/// strip assigned to it, keeping their balance. Its mute mutes them all.
public struct VCA: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  public var name: String
  /// In decibels, added to each assigned fader.
  public var volume: Double
  public var isMuted: Bool

  public init(id: UUID = UUID(), name: String, volume: Double = 0, isMuted: Bool = false) {
    self.id = id
    self.name = name
    self.volume = volume
    self.isMuted = isMuted
  }
}

extension Project {
  public func vca(withID id: VCA.ID) -> VCA? {
    vcas.first { $0.id == id }
  }

  /// How far each track's fader is moved, in dB, by its folder stack's fader and its VCA.
  /// Tracks they don't move aren't listed.
  public var mixOffsets: [Track.ID: Double] {
    var offsets: [Track.ID: Double] = [:]
    for track in tracks {
      var offset = 0.0
      if let stackID = track.stackID, let folder = self.track(withID: stackID), folder.isFolderStack {
        offset += folder.channel.volume
      }
      if let vcaID = track.channel.vcaID, let vca = vca(withID: vcaID) {
        offset += vca.volume
      }
      if offset != 0 { offsets[track.id] = offset }
    }
    return offsets
  }

  /// The project as it's mixed: each track's fader (and its volume automation) moved by its
  /// folder stack and VCA, and muted or soloed with them. A folder stack's own channel strip
  /// plays nothing, so it's left muted. Playback and bounces both mix this.
  public func mixingFoldersAndVCAs() -> Project {
    guard !vcas.isEmpty || tracks.contains(where: \.isFolderStack) else { return self }
    let offsets = mixOffsets
    let range = ChannelStrip.volumeRange
    func moved(_ decibels: Double, by offset: Double) -> Double {
      decibels <= range.lowerBound ? decibels : min(max(decibels + offset, range.lowerBound), range.upperBound)
    }
    var mixed = self
    for index in mixed.tracks.indices {
      let track = tracks[index]
      let folder = track.stackID.flatMap { self.track(withID: $0) }.flatMap { $0.isFolderStack ? $0 : nil }
      let vca = track.channel.vcaID.flatMap(vca(withID:))
      if folder?.channel.isMuted == true || vca?.isMuted == true { mixed.tracks[index].channel.isMuted = true }
      if folder?.channel.isSoloed == true { mixed.tracks[index].channel.isSoloed = true }
      if track.isFolderStack {
        mixed.tracks[index].channel.isMuted = true
        mixed.tracks[index].channel.isSoloed = false
      }
      guard let offset = offsets[track.id] else { continue }
      mixed.tracks[index].channel.volume = moved(track.channel.volume, by: offset)
      mixed.tracks[index].automation = track.automation.map { lane in
        guard lane.parameter == .volume else { return lane }
        return AutomationLane(
          parameter: .volume,
          points: lane.points.map { AutomationPoint(id: $0.id, position: $0.position, value: moved($0.value, by: offset)) })
      }
    }
    return mixed
  }
}
