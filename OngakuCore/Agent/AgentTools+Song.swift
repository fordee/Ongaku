//
//  AgentTools+Song.swift
//  OngakuCore
//

import Foundation

/// Tools that set up the song: tempo, meter, key, cycle, sections, markers and chords.
extension AgentToolbox {
  static let songTools: [AgentTool] = [setTempo, setTimeSignature, setKey, setCycle, setArrangement, addMarker, setChords, detectChords]

  static let setTempo = AgentTool(
    name: "set_tempo", title: "Set Tempo",
    description: "Sets the song's tempo in beats per minute, or adds a tempo change at a position.",
    properties: [
      "bpm": Schema.number("Beats per minute, from 5 to 990."),
      "at": Schema.position("Where the tempo changes; leave out to set the song's tempo."),
    ],
    required: ["bpm"]
  ) { arguments, session in
    let bpm = try arguments.double("bpm")
    let position = try arguments.optionalPosition("at", in: session.project) ?? .zero
    try session.performEdit(SetTempo(bpm, at: position), named: "Set Tempo")
    return ["tempo": .number(bpm), "at": AgentNotation.format(position, tempoMap: session.project.tempoMap)]
  }

  static let setTimeSignature = AgentTool(
    name: "set_time_signature", title: "Set Time Signature",
    description: "Sets the song's time signature, or changes it from a bar on. Drummer and session player parts follow.",
    properties: [
      "signature": Schema.string("Such as \"4/4\", \"3/4\", \"6/8\" or \"7/8\"."),
      "bar": Schema.integer("The bar it changes at; leave out to set the song's time signature."),
    ],
    required: ["signature"]
  ) { arguments, session in
    let signature = try AgentNotation.timeSignature(try arguments.string("signature"))
    let bar = try arguments.optionalInt("bar") ?? 1
    guard bar >= 1 else { throw AgentError.invalidArgument("bar", "bars start at 1.") }
    try session.performEdit(SetTimeSignature(signature, atBarIndex: bar - 1), named: "Set Time Signature")
    return ["timeSignature": .string(signature.description), "bar": .int(bar)]
  }

  static let setKey = AgentTool(
    name: "set_key", title: "Set Key",
    description: "Sets the song's key, or adds a key change at a position. Session players and chord progressions use it.",
    properties: [
      "key": Schema.string("Such as \"A minor\", \"Eb major\" or \"F#m\"."),
      "at": Schema.position("Where the key changes; leave out to set the song's key."),
    ],
    required: ["key"]
  ) { arguments, session in
    let key = try AgentNotation.key(try arguments.string("key"))
    let position = try arguments.optionalPosition("at", in: session.project) ?? .zero
    try session.performEdit(SetKey(key, at: position), named: "Set Key")
    return ["key": .string(AgentNotation.name(of: key)), "at": AgentNotation.format(position, tempoMap: session.project.tempoMap)]
  }

  static let setCycle = AgentTool(
    name: "set_cycle", title: "Set Cycle",
    description: "Sets the cycle (loop) range and turns it on or off, so playback repeats a part of the song.",
    properties: [
      "start": Schema.position("Where the cycle starts."),
      "end": Schema.position("Where it ends (the cycle stops just before)."),
      "on": Schema.boolean("Whether playback cycles; on by default."),
    ],
    required: ["start", "end"]
  ) { arguments, session in
    let project = session.project
    let start = try arguments.position("start", in: project)
    let end = try arguments.position("end", in: project)
    guard end > start else { throw AgentError.invalidArgument("end", "the cycle must end after it starts.") }
    let isOn = try arguments.optionalBool("on") ?? true
    try session.performEdit(SetCycle(CycleRange(isEnabled: isOn, start: start, end: end)), named: "Set Cycle")
    return ["on": .bool(isOn), "start": AgentNotation.format(start, tempoMap: project.tempoMap), "end": AgentNotation.format(end, tempoMap: project.tempoMap)]
  }

  static let setArrangement = AgentTool(
    name: "set_arrangement", title: "Set Arrangement",
    description: """
      Lays out the song's sections on the Arrangement track, one after another, replacing the \
      sections there (what's in the tracks doesn't move). Drummer and session player parts \
      and set_chords can then follow them. Logic's usual names are Intro, Verse, Pre-Chorus, \
      Chorus, Bridge, Solo, Breakdown and Outro; the players play each to suit its name.
      """,
    properties: [
      "sections": Schema.array(
        Schema.object(["name": Schema.string("Such as \"Verse\"."), "bars": Schema.number("How long it is.")], required: ["name", "bars"]),
        "The sections, in order."),
      "start": Schema.position("Where the first section starts; the start of the song if left out."),
    ],
    required: ["sections"]
  ) { arguments, session in
    let project = session.project
    let tempoMap = project.tempoMap
    var position = try arguments.optionalPosition("start", in: project) ?? .zero
    var sections: [ArrangementSection] = []
    for (index, item) in try arguments.array("sections").enumerated() {
      let section = AgentArguments(item.objectValue ?? [:])
      let name = try section.string("name").trimmingCharacters(in: .whitespaces)
      let bars = try section.double("bars")
      guard !name.isEmpty, bars > 0 else {
        throw AgentError.invalidArgument("sections", "section \(index + 1) needs a name and a positive number of bars.")
      }
      let end = AgentNotation.end(from: position, bars: bars, tempoMap: tempoMap)
      sections.append(ArrangementSection(name: name, start: position, length: end - position))
      position = end
    }
    guard !sections.isEmpty else { throw AgentError.invalidArgument("sections", "list at least one section.") }
    try session.performEdit(ReplaceArrangement(sections: sections), named: "Set Arrangement")
    let updated = session.project
    return ["sections": .array(updated.arrangement.map { AgentDescriptions.section($0, in: updated) })]
  }

  static let addMarker = AgentTool(
    name: "add_marker", title: "Add Marker",
    description: "Adds a named marker to the Marker track, for a note to the person or a place to come back to.",
    properties: ["name": Schema.string("The marker's name."), "at": Schema.position("Where it goes.")],
    required: ["name", "at"]
  ) { arguments, session in
    let position = try arguments.position("at", in: session.project)
    let marker = Marker(name: try arguments.string("name"), position: position)
    try session.performEdit(AddMarker(marker), named: "Add Marker")
    return ["id": AgentNames.shortID(marker.id), "at": AgentNotation.format(position, tempoMap: session.project.tempoMap)]
  }

  static let setChords = AgentTool(
    name: "set_chords", title: "Set Chords",
    description: """
      Writes chords on the Chord track, replacing the chords in that stretch; session players \
      follow them. Give either "bars" (one string per bar; several chords in a string share \
      the bar evenly, so "F G" is two beats each in 4/4) or "progression" (a name from \
      list_session_players, one chord a bar in the song's key). Say where with "section" or \
      "from"/"to"; bars repeat to fill a section or a "to".
      """,
    properties: [
      "bars": Schema.array(Schema.string("A bar's chords, such as \"Am\" or \"F G7\"."), "Chords bar by bar, such as [\"C\", \"Am\", \"F\", \"G7\"]."),
      "progression": Schema.string("A progression's name from list_session_players, such as \"Pop\"."),
      "section": Schema.string("An arrangement section's id or name; the chords fill it (the first section of that name)."),
      "from": Schema.position("Where the chords start (when there's no section); the start of the song if left out."),
      "to": Schema.position("Where they end; with bars, the bars repeat until here."),
    ]
  ) { arguments, session in
    let project = session.project
    let tempoMap = project.tempoMap
    var start = try arguments.optionalPosition("from", in: project) ?? .zero
    var end = try arguments.optionalPosition("to", in: project)
    if let sectionName = try arguments.optionalString("section") {
      let section = try AgentToolbox.section(sectionName, in: project)
      (start, end) = (section.start, section.end)
    }
    var changes: [ChordChange] = []
    if let bars = try arguments.optionalArray("bars") {
      let barChords = try bars.enumerated().map { index, item -> [Chord] in
        guard let text = item.stringValue else { throw AgentError.invalidArgument("bars", "bar \(index + 1) should be a string of chord symbols.") }
        let chords = try text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "|" }).map { symbol -> Chord in
          guard let chord = Chord(name: String(symbol)) else {
            throw AgentError.invalidArgument("bars", "“\(symbol)” in bar \(index + 1) isn't a chord symbol; use names such as C, Am, F#m7, Bb/D.")
          }
          return chord
        }
        guard !chords.isEmpty else { throw AgentError.invalidArgument("bars", "bar \(index + 1) has no chords.") }
        return chords
      }
      guard !barChords.isEmpty else { throw AgentError.invalidArgument("bars", "list at least one bar.") }
      let firstBar = tempoMap.bar(containing: start).index
      let lastBar = end.map { tempoMap.bar(containing: $0 - Tick(1)).index } ?? (firstBar + barChords.count - 1)
      for barIndex in firstBar...max(firstBar, lastBar) {
        let chords = barChords[(barIndex - firstBar) % barChords.count]
        let barStart = tempoMap.tickPosition(ofBarIndex: barIndex)
        let barLength = tempoMap.timeSignature(atBarIndex: barIndex).ticksPerBar
        for (index, chord) in chords.enumerated() {
          let position = barStart + Tick(barLength.rawValue * Int64(index) / Int64(chords.count))
          // Repeats of the chord already playing are one change.
          if changes.last?.chord != chord { changes.append(ChordChange(position: max(position, start), chord: chord)) }
        }
      }
      end = end ?? tempoMap.tickPosition(ofBarIndex: lastBar + 1)
    } else if let name = try arguments.optionalString("progression") {
      let key = project.key(at: start)
      let library = ChordProgression.library(for: key)
      guard let progression = library.first(where: { AgentNames.simplified($0.name) == AgentNames.simplified(name) }) else {
        throw AgentError.invalidArgument("progression", "there's no “\(name)” progression in \(AgentNotation.name(of: key)); they are \(library.map(\.name).joined(separator: ", ")).")
      }
      guard let to = end else { throw AgentError.missingArgument("to") }
      changes = progression.changes(in: key, from: start, to: to, tempoMap: tempoMap)
    } else {
      throw AgentError.missingArgument("bars")
    }
    guard let end, end > start else { throw AgentError.invalidArgument("to", "the chords must end after they start.") }
    try session.performEdit(SetChords(changes, from: start, to: end), named: "Set Chords")
    let updated = session.project
    return [
      "from": AgentNotation.format(start, tempoMap: tempoMap), "to": AgentNotation.format(end, tempoMap: tempoMap),
      "chords": .array(updated.chords.filter { $0.position >= start && $0.position < end }.map {
        .string("\(AgentNotation.format($0.position, tempoMap: tempoMap)) \($0.chord)")
      }),
    ]
  }

  static let detectChords = AgentTool(
    name: "detect_chords", title: "Detect Chords",
    description: """
      Works out the chords a MIDI region plays (a piano or guitar part, say) and writes them \
      on the Chord track over the region, so session players can follow them.
      """,
    properties: ["region": Schema.region],
    required: ["region"]
  ) { arguments, session in
    let project = session.project
    let region = try arguments.region("region", in: project)
    guard case .midi = region.content else { throw AgentError.notPossible("“\(region.name)” is audio; chords are detected from MIDI notes.") }
    try session.performEdit(DetectChords(from: region.id), named: "Detect Chords")
    let updated = session.project
    let chords = updated.chords.filter { $0.position >= region.start && $0.position < region.end }
    guard !chords.isEmpty else { throw AgentError.notFound("No chords could be told from “\(region.name)”: it needs at least two notes sounding together.") }
    return ["chords": .array(chords.map { .string("\(AgentNotation.format($0.position, tempoMap: updated.tempoMap)) \($0.chord)") })]
  }

  /// An arrangement section by id, or the first one with a name.
  static func section(_ text: String, in project: Project) throws -> ArrangementSection {
    let ids = AgentNames.match(text, among: project.arrangement.map(\.id))
    if ids.count == 1, let section = project.arrangement.first(where: { $0.id == ids[0] }) { return section }
    let sorted = project.arrangement.sorted { $0.start < $1.start }
    if let section = sorted.first(where: { $0.name.compare(text, options: .caseInsensitive) == .orderedSame }) { return section }
    throw AgentError.notFound(
      project.arrangement.isEmpty
        ? "The song has no arrangement sections; add them with set_arrangement."
        : "There's no section “\(text)”; the sections are \(sorted.map(\.name).joined(separator: ", ")).")
  }
}

/// Replaces the Arrangement track's sections without moving what's in the tracks (deleting
/// a section in Logic deletes its contents too, which isn't what laying out a song means).
struct ReplaceArrangement: EditCommand {
  var sections: [ArrangementSection]

  var actionName: String { "Set Arrangement" }

  func apply(to project: inout Project) throws {
    project.arrangement = []
    for section in sections {
      try AddArrangementSection(section).apply(to: &project)
    }
  }
}
