//
//  AgentTools+Notes.swift
//  OngakuCore
//

import Foundation

/// Tools that write regions and the notes in them.
extension AgentToolbox {
  static let noteTools: [AgentTool] = [
    createRegion, addNotes, deleteNotes, transformNotes, editRegion, copyRegion, deleteRegions,
  ]

  private static let notesSchema = Schema.array(
    [
      "type": ["object", "string"],
      "description": "A note: {\"pitch\": \"C4\", \"start\": 0, \"length\": 1, \"velocity\": 100}, or the same as a string \"C4 0 1 100\" (pitch, start, length, optional velocity). Start and length are in beats (quarter notes) from the region's start; velocity is 1–127 (100 if left out).",
      "properties": [
        "pitch": Schema.pitch,
        "start": Schema.number("Beats from the region's start."),
        "length": Schema.number("In beats: 1 is a quarter note, 0.5 an eighth, 4 a whole note in 4/4."),
        "velocity": Schema.integer("1–127; 100 if left out."),
      ],
    ],
    "The notes.")

  static let createRegion = AgentTool(
    name: "create_region", title: "Create Region",
    description: """
      Adds a MIDI region to an instrument track, optionally with notes (in the same form as \
      add_notes). Returns its id. Regions on one track shouldn't overlap.
      """,
    properties: [
      "track": Schema.track,
      "start": Schema.position("Where the region starts."),
      "bars": Schema.number("How long it is, in bars (or give \"end\")."),
      "end": Schema.position("Where it ends."),
      "name": Schema.string("The region's name; the track's if left out."),
      "notes": notesSchema,
    ],
    required: ["track", "start"]
  ) { arguments, session in
    let project = session.project
    let track = try arguments.track("track", in: project)
    guard track.kind == .softwareInstrument else {
      throw AgentError.notPossible("“\(track.name)” is \(track.kind == .audio ? "an audio" : "an aux") track; MIDI regions go on instrument tracks.")
    }
    let start = try arguments.position("start", in: project)
    let end: Tick
    if let explicitEnd = try arguments.optionalPosition("end", in: project) {
      end = explicitEnd
    } else if let bars = try arguments.optionalDouble("bars") {
      guard bars > 0 else { throw AgentError.invalidArgument("bars", "a region needs a positive length.") }
      end = AgentNotation.end(from: start, bars: bars, tempoMap: project.tempoMap)
    } else {
      throw AgentError.missingArgument("bars")
    }
    guard end > start else { throw AgentError.invalidArgument("end", "the region must end after it starts.") }
    let notes = try arguments.optionalArray("notes").map { try parseNotes($0, isDrums: AgentInstruments.playsDrums(track)) } ?? []
    let name = try arguments.optionalString("name") ?? track.name
    let region = Region(name: name, start: start, length: end - start, content: .midi(MIDISequence(notes: notes)))
    try session.performEdit(AddRegion(region, to: track.id), named: "Create Region")
    var result: [String: AgentValue] = region.description(in: session.project)
    result["notesAdded"] = .int(notes.count)
    if let warning = outsideWarning(notes, regionLength: region.length) { result["warning"] = .string(warning) }
    return .object(result)
  }

  static let addNotes = AgentTool(
    name: "add_notes", title: "Add Notes",
    description: """
      Writes notes into a MIDI region. Start and length are in beats (quarter notes) from the \
      region's start. With "replace", the region's notes are cleared first.
      """,
    properties: [
      "region": Schema.region,
      "notes": notesSchema,
      "replace": Schema.boolean("Clears the region's notes first."),
    ],
    required: ["region", "notes"]
  ) { arguments, session in
    let project = session.project
    let region = try writableRegion(arguments, in: project)
    let track = AgentNames.track(containing: region.id, in: project)
    let notes = try parseNotes(try arguments.array("notes"), isDrums: track.map(AgentInstruments.playsDrums) ?? false)
    guard !notes.isEmpty else { throw AgentError.invalidArgument("notes", "list at least one note.") }
    var commands: [any EditCommand] = []
    if try arguments.optionalBool("replace") == true, case .midi(let sequence) = region.content, !sequence.notes.isEmpty {
      commands.append(DeleteNotes(Set(sequence.notes.map(\.id)), from: region.id))
    }
    commands.append(AddNotes(notes, to: region.id))
    try session.performEdit(CompositeCommand("Add Notes", commands: commands), named: "Add Notes")
    var result: [String: AgentValue] = ["region": AgentNames.shortID(region.id), "notesAdded": .int(notes.count)]
    if case .midi(let sequence)? = session.project.region(withID: region.id)?.content {
      result["notesInRegion"] = .int(sequence.notes.count)
    }
    if let warning = outsideWarning(notes, regionLength: region.length) { result["warning"] = .string(warning) }
    return .object(result)
  }

  static let deleteNotes = AgentTool(
    name: "delete_notes", title: "Delete Notes",
    description: "Deletes notes from a MIDI region: the ones listed, those in a beat range or of a pitch, or all of them.",
    properties: [
      "region": Schema.region,
      "notes": Schema.array(Schema.string("A note's id."), "The notes to delete, by id."),
      "from": Schema.number("Notes starting at or after this beat."),
      "to": Schema.number("Notes starting before this beat."),
      "pitch": Schema.pitch,
    ],
    required: ["region"], isDestructive: true
  ) { arguments, session in
    let region = try writableRegion(arguments, in: session.project)
    let notes = try chosenNotes(arguments, in: region)
    guard !notes.isEmpty else { throw AgentError.notFound("No notes match.") }
    try session.performEdit(DeleteNotes(Set(notes.map(\.id)), from: region.id), named: "Delete Notes")
    return ["region": AgentNames.shortID(region.id), "deleted": .int(notes.count)]
  }

  static let transformNotes = AgentTool(
    name: "transform_notes", title: "Transform Notes",
    description: """
      Changes notes in a MIDI region: transposes them, sets or changes their velocity, sets \
      their length, or quantizes them to a grid. Picks notes as delete_notes does (all if none \
      are chosen).
      """,
    properties: [
      "region": Schema.region,
      "notes": Schema.array(Schema.string("A note's id."), "The notes to change, by id."),
      "from": Schema.number("Notes starting at or after this beat."),
      "to": Schema.number("Notes starting before this beat."),
      "pitch": Schema.pitch,
      "transpose": Schema.integer("Semitones up (or down, if negative)."),
      "velocity": Schema.integer("Sets every velocity (1–127)."),
      "velocityChange": Schema.integer("Adds to every velocity (kept within 1–127)."),
      "length": Schema.number("Sets every length, in beats."),
      "quantize": Schema.string("A grid to move note starts to: \"1/4\", \"1/8\", \"1/16\", \"1/8T\"…"),
      "strength": Schema.number("How far toward the grid quantized notes move, 0–1 (1 if left out)."),
      "swing": Schema.number("Swing for the quantize, 0–1."),
    ],
    required: ["region"]
  ) { arguments, session in
    let region = try writableRegion(arguments, in: session.project)
    let notes = try chosenNotes(arguments, in: region)
    guard !notes.isEmpty else { throw AgentError.notFound("No notes match.") }
    let transpose = try arguments.optionalInt("transpose") ?? 0
    let velocity = try arguments.optionalInt("velocity")
    let velocityChange = try arguments.optionalInt("velocityChange") ?? 0
    let length = try arguments.optionalDouble("length")
    if let velocity, !MIDINote.velocityRange.contains(velocity) { throw AgentError.invalidArgument("velocity", "velocities run from 1 to 127.") }
    if let length, length <= 0 { throw AgentError.invalidArgument("length", "notes need a positive length.") }
    var commands: [any EditCommand] = []
    if transpose != 0 || velocity != nil || velocityChange != 0 || length != nil {
      let changed = try notes.map { note -> MIDINote in
        var changed = note
        changed.pitch += transpose
        guard MIDINote.pitchRange.contains(changed.pitch) else {
          throw AgentError.invalidArgument("transpose", "that would take \(AgentNotation.name(ofPitch: note.pitch)) outside MIDI's range.")
        }
        changed.velocity = min(max((velocity ?? note.velocity) + velocityChange, 1), 127)
        if let length { changed.length = AgentNotation.ticks(beats: length) }
        return changed
      }
      commands.append(UpdateNotes(changed, in: region.id))
    }
    if let grid = try arguments.optionalString("quantize") {
      commands.append(QuantizeNotes(
        in: region.id, noteIDs: Set(notes.map(\.id)), grid: try AgentNotation.grid(grid, key: "quantize"),
        strength: try arguments.optionalAmount("strength") ?? 1, swing: try arguments.optionalAmount("swing") ?? 0))
    }
    guard !commands.isEmpty else { throw AgentError.notPossible("Nothing to change: give transpose, velocity, velocityChange, length or quantize.") }
    try session.performEdit(CompositeCommand("Transform Notes", commands: commands), named: "Transform Notes")
    return ["region": AgentNames.shortID(region.id), "changed": .int(notes.count)]
  }

  static let editRegion = AgentTool(
    name: "edit_region", title: "Edit Region",
    description: """
      Changes a region: renames it, moves it (in time or to another track of the same kind), \
      changes its length (its notes stay where they are), mutes it, loops it, or transposes \
      how it plays. Only what you give changes.
      """,
    properties: [
      "region": Schema.region,
      "name": Schema.string("A new name."),
      "start": Schema.position("Moves the region to start here."),
      "track": Schema.track,
      "bars": Schema.number("A new length in bars (or give \"end\")."),
      "end": Schema.position("A new end."),
      "mute": Schema.boolean("Mutes or unmutes it."),
      "loop": Schema.boolean("Loops it: it repeats until the next region on the track or the loop end."),
      "loopEnd": Schema.position("Where a looped region's repeats stop."),
      "transpose": Schema.integer("Semitones the region plays transposed by (its notes don't change)."),
    ],
    required: ["region"]
  ) { arguments, session in
    let project = session.project
    let tempoMap = project.tempoMap
    let region = try arguments.region("region", in: project)
    var commands: [any EditCommand] = []
    var length = region.length
    if let end = try arguments.optionalPosition("end", in: project) {
      length = end - region.start
    } else if let bars = try arguments.optionalDouble("bars") {
      length = AgentNotation.end(from: region.start, bars: bars, tempoMap: tempoMap) - region.start
    }
    if length != region.length {
      guard length > .zero else { throw AgentError.invalidArgument("end", "the region must end after it starts.") }
      commands.append(TrimRegion(region.id, start: region.start, length: length))
    }
    let start = try arguments.optionalPosition("start", in: project)
    let track = try arguments.optionalTrack("track", in: project)
    if start != nil || track != nil {
      commands.append(MoveRegion(region.id, to: start ?? region.start, track: track?.id))
    }
    if let name = try arguments.optionalString("name") { commands.append(RenameRegion(regionID: region.id, name: name)) }
    if let mute = try arguments.optionalBool("mute") { commands.append(SetRegionMuted(region.id, isMuted: mute)) }
    if let loopEnd = try arguments.optionalPosition("loopEnd", in: project) {
      commands.append(SetRegionLoop(region.id, to: loopEnd))
    } else if let loop = try arguments.optionalBool("loop") {
      commands.append(SetRegionParameter(.looped(loop), for: [region.id]))
    }
    if let transpose = try arguments.optionalInt("transpose") {
      commands.append(SetRegionParameter(.transpose(transpose), for: [region.id]))
    }
    guard !commands.isEmpty else { throw AgentError.notPossible("Nothing to change: give a setting with a new value.") }
    try session.performEdit(CompositeCommand("Edit Region", commands: commands), named: "Edit Region")
    guard let updated = session.project.region(withID: region.id) else { return .null }
    return AgentDescriptions.region(updated, in: session.project)
  }

  static let copyRegion = AgentTool(
    name: "copy_region", title: "Copy Region",
    description: """
      Copies a region to another position (and optionally another track of the same kind), \
      or repeats it end to end a number of times. Returns the copies' ids.
      """,
    properties: [
      "region": Schema.region,
      "to": Schema.position("Where the copy starts (leave out with \"times\" to repeat it straight after itself)."),
      "track": Schema.track,
      "times": Schema.integer("How many copies; with \"to\", they're laid end to end from there."),
    ],
    required: ["region"]
  ) { arguments, session in
    let project = session.project
    let region = try arguments.region("region", in: project)
    let times = try arguments.optionalInt("times") ?? 1
    guard (1...64).contains(times) else { throw AgentError.invalidArgument("times", "make 1 to 64 copies.") }
    let to = try arguments.optionalPosition("to", in: project) ?? region.end
    let track = try arguments.optionalTrack("track", in: project) ?? AgentNames.track(containing: region.id, in: project)
    guard let track else { return .null }
    let copies = (0..<times).map { index in
      var copy = region
      copy.id = UUID()
      copy.start = to + region.length * Int64(index)
      copy.takeFolder = nil
      return copy
    }
    try session.performEdit(CompositeCommand("Copy Region", commands: copies.map { AddRegion($0, to: track.id) }), named: "Copy Region")
    return ["copies": .array(copies.map { AgentDescriptions.region($0, in: session.project) })]
  }

  static let deleteRegions = AgentTool(
    name: "delete_regions", title: "Delete Regions",
    description: "Deletes regions (the person can undo it).",
    properties: ["regions": Schema.array(Schema.string("A region's id."), "The regions to delete.")],
    required: ["regions"], isDestructive: true
  ) { arguments, session in
    let regions = try arguments.regions("regions", in: session.project)
    try session.performEdit(DeleteRegions(Set(regions.map(\.id))), named: regions.count == 1 ? "Delete Region" : "Delete Regions")
    return ["deleted": .int(regions.count)]
  }

  // MARK: - Helpers

  /// Reads notes as objects or "pitch start length velocity" strings.
  static func parseNotes(_ items: [AgentValue], isDrums: Bool) throws -> [MIDINote] {
    try items.enumerated().map { index, item in
      let label = "notes[\(index)]"
      let pitch: Int, start: Double, length: Double, velocity: Int
      if let text = item.stringValue {
        let parts = text.split(separator: " ").map(String.init)
        guard (3...4).contains(parts.count), let parsedStart = Double(parts[1]), let parsedLength = Double(parts[2]) else {
          throw AgentError.invalidArgument(label, "“\(text)” should be \"pitch start length [velocity]\", such as \"C4 0 1 100\".")
        }
        pitch = try AgentNotation.pitch(.string(parts[0]), key: label)
        (start, length) = (parsedStart, parsedLength)
        velocity = parts.count == 4 ? Int(parts[3]) ?? -1 : 100
      } else if let object = item.objectValue {
        let note = AgentArguments(object)
        pitch = try AgentNotation.pitch(try note.value("pitch"), key: label)
        start = try note.double("start")
        // A drum hit's length hardly matters; a sixteenth if it's left out.
        length = try note.optionalDouble("length") ?? (isDrums ? 0.25 : { throw AgentError.missingArgument("\(label).length") }())
        velocity = try note.optionalInt("velocity") ?? 100
      } else {
        throw AgentError.invalidArgument(label, "a note is an object or a \"pitch start length velocity\" string.")
      }
      guard start >= 0 else { throw AgentError.invalidArgument(label, "notes start at beat 0 or later, from the region's start.") }
      guard length > 0 else { throw AgentError.invalidArgument(label, "a note needs a positive length.") }
      guard MIDINote.velocityRange.contains(velocity) else { throw AgentError.invalidArgument(label, "velocity runs from 1 to 127.") }
      let ticks = max(Tick(1), AgentNotation.ticks(beats: length))
      return MIDINote(pitch: pitch, velocity: velocity, start: AgentNotation.ticks(beats: start), length: ticks)
    }
  }

  /// A MIDI region whose notes can be written: not audio, and not one whose notes are
  /// generated.
  private static func writableRegion(_ arguments: AgentArguments, in project: Project) throws -> Region {
    let region = try arguments.region("region", in: project)
    switch AgentDescriptions.regionType(region) {
    case "audio": throw AgentError.notPossible("“\(region.name)” is an audio region; it has no notes.")
    case "drummer", "player", "pattern":
      throw AgentError.notPossible(
        "“\(region.name)” is a \(AgentDescriptions.regionType(region)) region, so its notes are generated. Change it with edit_session_part, or call convert_to_notes first to edit its notes.")
    case "takes": throw AgentError.notPossible("“\(region.name)” is a take folder; its notes can't be edited here.")
    default: return region
    }
  }

  /// The notes delete_notes and transform_notes act on.
  private static func chosenNotes(_ arguments: AgentArguments, in region: Region) throws -> [MIDINote] {
    guard case .midi(let sequence) = region.content else { return [] }
    var notes = sequence.notes
    if let ids = try arguments.optionalArray("notes") {
      let wanted = try ids.map { value -> UUID in
        guard let text = value.stringValue else { throw AgentError.invalidArgument("notes", "list note ids.") }
        let matches = AgentNames.match(text, among: sequence.notes.map(\.id))
        guard matches.count == 1 else { throw AgentError.notFound("There's no note “\(text)” in “\(region.name)”.") }
        return matches[0]
      }
      notes = notes.filter { wanted.contains($0.id) }
    }
    if let from = try arguments.optionalDouble("from") { notes = notes.filter { $0.start >= AgentNotation.ticks(beats: from) } }
    if let to = try arguments.optionalDouble("to") { notes = notes.filter { $0.start < AgentNotation.ticks(beats: to) } }
    if arguments.has("pitch") {
      let pitch = try AgentNotation.pitch(try arguments.value("pitch"))
      notes = notes.filter { $0.pitch == pitch }
    }
    return notes
  }

  private static func outsideWarning(_ notes: [MIDINote], regionLength: Tick) -> String? {
    let outside = notes.filter { $0.start >= regionLength }.count
    guard outside > 0 else { return nil }
    return "\(outside) note\(outside == 1 ? " starts" : "s start") after the region ends, so won't play; lengthen it with edit_region."
  }
}

extension Region {
  fileprivate func description(in project: Project) -> [String: AgentValue] {
    AgentDescriptions.region(self, in: project).objectValue ?? [:]
  }
}

/// Renames a region.
struct RenameRegion: EditCommand {
  var regionID: Region.ID
  var name: String

  var actionName: String { "Rename Region" }

  func apply(to project: inout Project) throws {
    let location = try project.requireRegionLocation(regionID)
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw EditError.invalidValue("A region name can’t be empty.") }
    project.tracks[location.track].regions[location.region].name = trimmed
  }
}
