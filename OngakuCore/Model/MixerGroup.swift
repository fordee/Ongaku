//
//  MixerGroup.swift
//  OngakuCore
//

import Foundation

/// A mixer group, as in Logic: tracks in a group move together for the properties it
/// links. Volume and pan move by the same amount on every member (keeping their balance);
/// mute and solo are switched together.
public struct MixerGroup: Identifiable, Codable, Sendable, Equatable {
  /// The group number, from 1 (Logic numbers groups 1–32).
  public var id: Int
  public var name: String
  /// A group can be switched off to adjust one member on its own.
  public var isEnabled: Bool
  public var linksVolume: Bool
  public var linksPan: Bool
  public var linksMute: Bool
  public var linksSolo: Bool

  public static let numbers = 1...32

  public init(
    id: Int, name: String? = nil, isEnabled: Bool = true, linksVolume: Bool = true, linksPan: Bool = false,
    linksMute: Bool = true, linksSolo: Bool = true
  ) {
    self.id = id
    self.name = name ?? "Group \(id)"
    self.isEnabled = isEnabled
    self.linksVolume = linksVolume
    self.linksPan = linksPan
    self.linksMute = linksMute
    self.linksSolo = linksSolo
  }
}

extension Project {
  public func mixerGroup(withID id: Int) -> MixerGroup? {
    groups.first { $0.id == id }
  }

  /// The other tracks a change to `trackID`'s channel strip carries to, and the group.
  public func groupPartners(of trackID: Track.ID) -> (group: MixerGroup, tracks: [Track])? {
    guard let groupID = track(withID: trackID)?.groupID, let group = mixerGroup(withID: groupID), group.isEnabled else { return nil }
    return (group, tracks.filter { $0.groupID == groupID && $0.id != trackID })
  }

  /// The lowest group number not in use, for a new group.
  public var nextGroupNumber: Int? {
    MixerGroup.numbers.first { number in !groups.contains { $0.id == number } }
  }
}
