//
//  VCACommands.swift
//  OngakuCore
//

import Foundation

/// Adds a VCA fader to the mixer, assigning `trackIDs` to it.
public struct AddVCA: EditCommand {
  public var vca: VCA
  public var trackIDs: Set<Track.ID>

  public init(_ vca: VCA, assigning trackIDs: Set<Track.ID> = []) {
    self.vca = vca
    self.trackIDs = trackIDs
  }

  public var actionName: String { "New VCA" }

  public func apply(to project: inout Project) throws {
    guard project.vca(withID: vca.id) == nil else { throw EditError.duplicateID(vca.id) }
    project.vcas.append(vca)
    try AssignVCA(trackIDs, to: vca.id).apply(to: &project)
  }
}

/// Removes a VCA; its channel strips keep their own faders.
public struct DeleteVCA: EditCommand {
  public var vcaID: VCA.ID

  public init(_ vcaID: VCA.ID) {
    self.vcaID = vcaID
  }

  public var actionName: String { "Delete VCA" }

  public func apply(to project: inout Project) throws {
    guard project.vca(withID: vcaID) != nil else { throw EditError.invalidValue("That VCA no longer exists.") }
    project.vcas.removeAll { $0.id == vcaID }
    for index in project.tracks.indices where project.tracks[index].channel.vcaID == vcaID {
      project.tracks[index].channel.vcaID = nil
    }
  }
}

/// Changes a VCA's level, mute or name.
public struct UpdateVCA: EditCommand {
  public var vca: VCA
  public var actionName: String

  public init(_ vca: VCA, actionName: String = "VCA") {
    self.vca = vca
    self.actionName = actionName
  }

  public func apply(to project: inout Project) throws {
    guard let index = project.vcas.firstIndex(where: { $0.id == vca.id }) else {
      throw EditError.invalidValue("That VCA no longer exists.")
    }
    var vca = vca
    vca.volume = min(max(vca.volume, ChannelStrip.volumeRange.lowerBound), ChannelStrip.volumeRange.upperBound)
    project.vcas[index] = vca
  }
}

/// Assigns channel strips to a VCA, or takes them off theirs (`nil`).
public struct AssignVCA: EditCommand {
  public var trackIDs: Set<Track.ID>
  public var vcaID: VCA.ID?

  public init(_ trackIDs: Set<Track.ID>, to vcaID: VCA.ID?) {
    self.trackIDs = trackIDs
    self.vcaID = vcaID
  }

  public var actionName: String { "Assign VCA" }

  public func apply(to project: inout Project) throws {
    if let vcaID, project.vca(withID: vcaID) == nil { throw EditError.invalidValue("That VCA no longer exists.") }
    for id in trackIDs {
      project.tracks[try project.requireTrackIndex(id)].channel.vcaID = vcaID
    }
  }
}
