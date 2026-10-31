//
//  AgentTools+Tracks.swift
//  OngakuCore
//

import Foundation

/// Tools that add, change and remove tracks.
extension AgentToolbox {
  static let trackTools: [AgentTool] = [createTrack, updateTrack, deleteTracks]

  private static let trackSettings: [String: AgentValue] = [
    "name": Schema.string("The track's name."),
    "instrument": Schema.string("For instrument tracks: a sound from list_instruments, such as \"gm:33\", \"Fingered Bass\", \"drums\", \"TR-808 Kit\" or \"Retro Synth\"."),
    "color": Schema.choice(TrackColor.allCases.map(\.rawValue), "The track's colour."),
    "volumeDb": Schema.number("Fader level in dB, from -96 to +6 (0 is unity)."),
    "pan": Schema.number("-1 is hard left, 0 centre, 1 hard right."),
  ]

  static let createTrack = AgentTool(
    name: "create_track", title: "Create Track",
    description: """
      Adds a track at the bottom: an instrument track (plays MIDI regions through an \
      instrument; the default), an audio track, or an aux (for shared effects). Returns its id.
      """,
    properties: trackSettings.merging([
      "kind": Schema.choice(["instrument", "audio", "aux"], "What kind of track; instrument if left out."),
    ]) { current, _ in current }
  ) { arguments, session in
    let project = session.project
    let kind: TrackKind = switch try arguments.optionalString("kind").map(AgentNames.simplified) {
    case nil, "instrument", "softwareinstrument", "midi": .softwareInstrument
    case "audio": .audio
    case "aux", "bus": .aux
    case let other?: throw AgentError.invalidArgument("kind", "“\(other)” isn't a kind; use instrument, audio or aux.")
    }
    let name = try arguments.optionalString("name")?.trimmingCharacters(in: .whitespaces)
    var track = Track(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? project.nextTrackName(for: kind), kind: kind)
    try applySettings(arguments, to: &track, session: session)
    try session.performEdit(AddTrack(track), named: "Create Track")
    return AgentDescriptions.track(track, in: session.project)
  }

  static let updateTrack = AgentTool(
    name: "update_track", title: "Update Track",
    description: "Changes a track's name, instrument, colour, volume, pan, mute or solo. Only what you give changes.",
    properties: trackSettings.merging([
      "track": Schema.track,
      "mute": Schema.boolean("Mutes or unmutes the track."),
      "solo": Schema.boolean("Solos or unsolos the track."),
    ]) { current, _ in current },
    required: ["track"]
  ) { arguments, session in
    let original = try arguments.track("track", in: session.project)
    var track = original
    try applySettings(arguments, to: &track, session: session)
    if let mute = try arguments.optionalBool("mute") { track.channel.isMuted = mute }
    if let solo = try arguments.optionalBool("solo") { track.channel.isSoloed = solo }
    var commands: [any EditCommand] = []
    if track.name != original.name { commands.append(RenameTrack(track.id, to: track.name)) }
    if track.color != original.color { commands.append(SetTrackColor(track.id, to: track.color)) }
    if track.channel != original.channel { commands.append(SetChannelStrip(track.id, to: track.channel)) }
    guard !commands.isEmpty else { throw AgentError.notPossible("Nothing to change: give a setting with a new value.") }
    try session.performEdit(CompositeCommand("Update Track", commands: commands), named: "Update Track")
    guard let updated = session.project.track(withID: track.id) else { return .null }
    return AgentDescriptions.track(updated, in: session.project)
  }

  static let deleteTracks = AgentTool(
    name: "delete_tracks", title: "Delete Tracks",
    description: "Deletes tracks with everything on them (the person can undo it).",
    properties: ["tracks": Schema.array(Schema.track, "The tracks to delete.")],
    required: ["tracks"], isDestructive: true
  ) { arguments, session in
    let project = session.project
    let tracks = try arguments.array("tracks").map { try AgentNames.track($0, in: project) }
    guard !tracks.isEmpty else { throw AgentError.invalidArgument("tracks", "list at least one track.") }
    try session.performEdit(DeleteTracks(Set(tracks.map(\.id))), named: tracks.count == 1 ? "Delete Track" : "Delete Tracks")
    return ["deleted": .array(tracks.map { .string($0.name) })]
  }

  /// The settings create_track and update_track share.
  @MainActor
  private static func applySettings(_ arguments: AgentArguments, to track: inout Track, session: any AgentSession) throws {
    if let name = try arguments.optionalString("name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
      track.name = name
    }
    if let instrument = try arguments.optionalString("instrument") {
      guard track.kind == .softwareInstrument else {
        throw AgentError.invalidArgument("instrument", "only instrument tracks have an instrument.")
      }
      track.channel.instrument = try AgentInstruments.resolve(instrument, audioUnits: session.installedAudioUnits)
    }
    if let color = try arguments.optionalChoice("color", TrackColor.self) { track.color = color }
    if let volume = try arguments.optionalDouble("volumeDb") {
      guard ChannelStrip.volumeRange.contains(volume) else { throw AgentError.invalidArgument("volumeDb", "the fader runs from -96 to +6 dB.") }
      track.channel.volume = volume
    }
    if let pan = try arguments.optionalDouble("pan") {
      guard ChannelStrip.panRange.contains(pan) else { throw AgentError.invalidArgument("pan", "pan runs from -1 to 1.") }
      track.channel.pan = pan
    }
  }
}
