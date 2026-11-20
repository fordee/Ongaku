//
//  AgentTools+Editing.swift
//  OngakuCore
//

import Foundation

/// Tools for editing the arrangement as the person does with the Scissors and Glue tools,
/// the section commands between the locators, and dragging track headers. Each calls the
/// same command as the app does, so it's refused (with the same reason) where the app's
/// would be.
extension AgentToolbox {
  static let editingTools: [AgentTool] = [splitRegion, joinRegions, editSection, moveTrack]

  static let splitRegion = AgentTool(
    name: "split_region", title: "Split Region",
    description: """
      Cuts a region in two at a position inside it, as the Scissors tool does. Drummer and \
      player regions keep playing their parts in both halves. Returns both regions.
      """,
    properties: [
      "region": Schema.region,
      "at": Schema.position("Where to cut, inside the region."),
    ],
    required: ["region", "at"]
  ) { arguments, session in
    let project = session.project
    let region = try arguments.region("region", in: project)
    let split = SplitRegion(region.id, at: try arguments.position("at", in: project))
    try session.performEdit(split, named: "Split Region")
    let updated = session.project
    let halves = [region.id, split.newRegionID].compactMap { updated.region(withID: $0) }
    return ["regions": .array(halves.map { AgentDescriptions.region($0, in: updated) })]
  }

  static let joinRegions = AgentTool(
    name: "join_regions", title: "Join Regions",
    description: """
      Joins regions on a track into one, from the start of the first to the end of the \
      last, as Edit › Join Regions does. MIDI regions keep the notes they play; audio \
      regions join only if they're pieces of one stretch of the same recording.
      """,
    properties: ["regions": Schema.array(Schema.region, "Two or more regions on one track.")],
    required: ["regions"]
  ) { arguments, session in
    let project = session.project
    let regions = try arguments.regions("regions", in: project)
    guard regions.count > 1 else { throw AgentError.invalidArgument("regions", "list two or more regions to join.") }
    try session.performEdit(JoinRegions(Set(regions.map(\.id))), named: "Join Regions")
    // The joined region keeps the first region's identity.
    guard let first = regions.min(by: { $0.start < $1.start }), let joined = session.project.region(withID: first.id) else { return .null }
    return AgentDescriptions.region(joined, in: session.project)
  }

  static let editSection = AgentTool(
    name: "edit_section", title: "Edit Section",
    description: """
      Changes the song's length between two positions on every track at once, as Logic's \
      section edits between the locators do: "cut" removes the stretch and closes the gap, \
      "insert_silence" opens up empty time there, "repeat" plays it again straight after. \
      Regions crossing the edges are split; markers, automation, chords, tempo, time \
      signature and key changes move with the music.
      """,
    properties: [
      "action": Schema.choice(["cut", "insert_silence", "repeat"], "What to do with the stretch."),
      "start": Schema.position("Where the stretch starts."),
      "end": Schema.position("Where it ends."),
      "times": Schema.integer("For repeat: how many copies (1 if left out)."),
    ],
    required: ["action", "start", "end"], isDestructive: true
  ) { arguments, session in
    let project = session.project
    let start = try arguments.position("start", in: project), end = try arguments.position("end", in: project)
    guard end > start else { throw AgentError.invalidArgument("end", "the stretch must end after it starts.") }
    let range = start..<end
    let command: any EditCommand = switch AgentNames.simplified(try arguments.string("action")) {
    case "cut": CutSection(range)
    case "insertsilence", "insert": InsertSilence(range)
    case "repeat": RepeatSection(range, times: try arguments.optionalInt("times") ?? 1)
    case let other: throw AgentError.invalidArgument("action", "“\(other)” isn't an action; use cut, insert_silence or repeat.")
    }
    try session.performEdit(command, named: command.actionName)
    return ["done": .string(command.actionName), "songEnd": .string(AgentNotation.format(session.project.endPosition, tempoMap: session.project.tempoMap))]
  }

  static let moveTrack = AgentTool(
    name: "move_track", title: "Move Track",
    description: "Moves a track up or down the track list (a summing stack moves with its subtracks).",
    properties: [
      "track": Schema.track,
      "to": Schema.integer("Its new number: 1 puts it at the top."),
    ],
    required: ["track", "to"]
  ) { arguments, session in
    let project = session.project
    let track = try arguments.track("track", in: project)
    let number = try arguments.int("to")
    guard (1...project.tracks.count).contains(number) else {
      throw AgentError.invalidArgument("to", "tracks are numbered 1 to \(project.tracks.count).")
    }
    try session.performEdit(MoveTrack(track.id, to: number - 1), named: "Move Track")
    return ["tracks": .array(session.project.tracks.map { .string($0.name) })]
  }
}
