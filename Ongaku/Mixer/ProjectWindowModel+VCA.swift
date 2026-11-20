//
//  ProjectWindowModel+VCA.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// The Mixer's VCA faders, and folder stack faders, which move other tracks' faders.
extension ProjectWindowModel {
  /// A new VCA ("VCA 1", "VCA 2"…), with `trackIDs` assigned to it.
  func addVCA(assigning trackIDs: Set<Track.ID>) {
    let names = Set(project.vcas.map(\.name))
    var number = 1
    while names.contains("VCA \(number)") { number += 1 }
    perform(AddVCA(VCA(name: "VCA \(number)"), assigning: trackIDs))
  }

  /// While a VCA's fader is dragged: its tracks' faders follow, without changing the project.
  func vcaVolumeChanged(_ vcaID: VCA.ID, to decibels: Double) {
    var moved = project
    guard let index = moved.vcas.firstIndex(where: { $0.id == vcaID }) else { return }
    moved.vcas[index].volume = decibels
    let members = moved.tracks.filter { $0.channel.vcaID == vcaID }.map(\.id)
    let offsets = moved.mixOffsets
    engine.setLiveVolumeOffsets(Dictionary(uniqueKeysWithValues: members.map { ($0, offsets[$0] ?? 0) }))
  }

  /// While a folder stack's fader is dragged: its subtracks' faders follow.
  func folderVolumeChanged(_ folderID: Track.ID, to decibels: Double) {
    var moved = project
    guard let index = moved.trackIndex(for: folderID) else { return }
    moved.tracks[index].channel.volume = decibels
    let members = moved.stackMembers(of: folderID).map(\.id)
    let offsets = moved.mixOffsets
    engine.setLiveVolumeOffsets(Dictionary(uniqueKeysWithValues: members.map { ($0, offsets[$0] ?? 0) }))
  }

  func setVCA(_ vcaID: VCA.ID, actionName: String, _ change: (inout VCA) -> Void) {
    guard var vca = project.vca(withID: vcaID) else { return }
    change(&vca)
    perform(UpdateVCA(vca, actionName: actionName))
  }

  /// Assigns a channel strip to a VCA (or none), with the other selected tracks if it's one
  /// of them, as Logic's VCA slot does.
  func assignVCA(_ vcaID: VCA.ID?, to trackID: Track.ID) {
    let trackIDs = selectedTrackIDs.contains(trackID) ? selectedTrackIDs : [trackID]
    perform(AssignVCA(trackIDs.filter { project.track(withID: $0)?.isFolderStack == false }, to: vcaID))
  }
}
