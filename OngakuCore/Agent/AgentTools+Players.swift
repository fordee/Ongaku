//
//  AgentTools+Players.swift
//  OngakuCore
//

import Foundation

/// Tools for Ongaku's session players: the Drummer, and the Bass and Keys players that
/// follow the Chord track.
extension AgentToolbox {
  static let sessionPlayerTools: [AgentTool] = [addDrummer, addSessionPlayer, editSessionPart, convertToNotes]

  private static let spanProperties: [String: AgentValue] = [
    "sections": Schema.array(
      Schema.string("A section's name (every section of that name) or id."),
      "The arrangement sections to play; every section if left out (or the whole song when there are none)."),
    "from": Schema.position("Instead of sections: where the part starts."),
    "to": Schema.position("Where the part ends (with \"from\")."),
  ]

  private static let performanceProperties: [String: AgentValue] = [
    "complexity": Schema.number("Simple (0) to busy (1); each section's own if left out."),
    "loudness": Schema.number("Soft (0) to loud (1); each section's own if left out."),
    "swing": Schema.number("Straight (0) to a triplet feel (1)."),
  ]

  static let addDrummer = AgentTool(
    name: "add_drummer", title: "Add Drummer",
    description: """
      Adds a session drummer, as Logic's Drummer does: a region for each section, each played \
      to suit it (quiet intro, loud chorus, fills into the next section). Makes a Drummer \
      track unless you give a drum track; regions already there in those bars are replaced. \
      Styles are in list_session_players.
      """,
    properties: spanProperties.merging(performanceProperties) { current, _ in current }.merging([
      "style": Schema.choice(DrummerPerformance.Style.allCases.map(\.rawValue), "How the drummer plays; rock if left out."),
      "track": Schema.track,
      "kit": Schema.choice(["generalMIDI", "drumMachine"], "For a new track: a General MIDI kit (the default) or Ongaku's Drum Machine."),
      "fills": Schema.number("No fills (0) to many, long fills (1)."),
      "feel": Schema.choice(DrummerPerformance.Feel.allCases.map(\.rawValue), "Where the backbeat falls."),
      "timekeeper": Schema.choice(DrummerPerformance.Timekeeper.allCases.map(\.rawValue), "What keeps time."),
    ]) { current, _ in current }
  ) { arguments, session in
    let project = session.project
    let style = try arguments.optionalChoice("style", DrummerPerformance.Style.self) ?? .rock
    var commands: [any EditCommand] = []
    let track: Track
    if let existing = try arguments.optionalTrack("track", in: project) {
      guard existing.kind == .softwareInstrument, AgentInstruments.playsDrums(existing) else {
        throw AgentError.notPossible("“\(existing.name)” doesn't play drums; leave out \"track\" for a new Drummer track, or set its instrument to \"drums\" first.")
      }
      track = existing
    } else {
      let kit: DrummerPerformance.Kit = try arguments.optionalString("kit").map(AgentNames.simplified) == "drummachine" ? .drumMachine : .generalMIDI
      var new = Track(name: uniqueTrackName("Drummer", in: project), kind: .softwareInstrument)
      new.channel.instrument = kit == .drumMachine ? .audioUnit(OngakuInstrument.drumMachine.makeReference()) : .generalMIDIPercussion(kit: 0)
      commands.append(AddTrack(new))
      track = new
    }
    let kit: DrummerPerformance.Kit = {
      if case .audioUnit(let plugin) = track.channel.instrument, OngakuInstrument(plugin) == .drumMachine { return .drumMachine }
      return .generalMIDI
    }()
    let spans = try AgentToolbox.spans(arguments, in: project)
    let complexity = try arguments.optionalAmount("complexity"), loudness = try arguments.optionalAmount("loudness")
    let fills = try arguments.optionalAmount("fills"), swing = try arguments.optionalAmount("swing")
    let feel = try arguments.optionalChoice("feel", DrummerPerformance.Feel.self)
    let timekeeper = try arguments.optionalChoice("timekeeper", DrummerPerformance.Timekeeper.self)
    let regions = spans.enumerated().map { index, span in
      var part = DrummerPerformance.forSection(
        named: span.name, style: style, kit: kit, isFirst: span.start == .zero || index == 0,
        isLast: index == spans.count - 1 && span.end >= (project.arrangement.map(\.end).max() ?? span.end),
        seed: UInt64.random(in: 1...UInt64.max))
      if let complexity { part.complexity = complexity }
      if let loudness { part.loudness = loudness }
      if let fills { part.fills = fills }
      if let swing { part.swing = swing }
      if let feel { part.feel = feel }
      if let timekeeper { part.timekeeper = timekeeper }
      var region = Region(name: span.name, start: span.start, length: span.end - span.start, content: .midi(MIDISequence()), drummer: part)
      region.renderDrummer(tempoMap: project.tempoMap)
      return region
    }
    commands += replacingCommands(regions, on: track)
    try session.performEdit(CompositeCommand("Add Drummer", commands: commands), named: "Add Drummer")
    return partResult(track: track, regions: regions, in: session.project)
  }

  static let addSessionPlayer = AgentTool(
    name: "add_session_player", title: "Add Session Player",
    description: """
      Adds a Bass or Keys session player, as Logic's Bass Player and Keyboard Player do: a \
      region for each section that plays along with the Chord track (set chords first) in a \
      style from list_session_players. Makes a track unless you give one; regions already \
      there in those bars are replaced.
      """,
    properties: spanProperties.merging(performanceProperties) { current, _ in current }.merging([
      "instrument": Schema.choice(["bass", "keys"], "Which player."),
      "style": Schema.choice(PlayerPerformance.Style.allCases.map(\.rawValue), "How they play; root notes for bass and pad for keys if left out."),
      "track": Schema.track,
      "sound": Schema.string("For a new track: its instrument from list_instruments (fingered bass or an electric piano if left out)."),
      "register": Schema.integer("Octaves up (1) or down (-1) from the instrument's usual range."),
    ]) { current, _ in current },
    required: ["instrument"]
  ) { arguments, session in
    let project = session.project
    let instrument = try arguments.choice("instrument", PlayerPerformance.Instrument.self)
    let style = try arguments.optionalChoice("style", PlayerPerformance.Style.self) ?? (instrument == .bass ? .rootNotes : .pad)
    guard style.instrument == instrument else {
      throw AgentError.invalidArgument("style", "\(style.rawValue) is a \(style.instrument.rawValue) style; \(instrument.rawValue) styles are \(PlayerPerformance.Style.styles(for: instrument).map(\.rawValue).joined(separator: ", ")).")
    }
    guard !project.chords.isEmpty else {
      throw AgentError.notPossible("The Chord track is empty, so the player has nothing to follow. Call set_chords first.")
    }
    var commands: [any EditCommand] = []
    let track: Track
    if let existing = try arguments.optionalTrack("track", in: project) {
      guard existing.kind == .softwareInstrument, !AgentInstruments.playsDrums(existing) else {
        throw AgentError.notPossible("A session player needs an instrument track that doesn't play drums.")
      }
      track = existing
    } else {
      var new = Track(name: uniqueTrackName(instrument == .bass ? "Bass Player" : "Keyboard Player", in: project), kind: .softwareInstrument)
      new.channel.instrument = try arguments.optionalString("sound").map { try AgentInstruments.resolve($0, audioUnits: session.installedAudioUnits, key: "sound") }
        ?? (instrument == .bass ? .generalMIDI(program: 33) : .generalMIDI(program: 4))
      commands.append(AddTrack(new))
      track = new
    }
    let spans = try AgentToolbox.spans(arguments, in: project)
    let complexity = try arguments.optionalAmount("complexity"), loudness = try arguments.optionalAmount("loudness")
    let swing = try arguments.optionalAmount("swing"), register = try arguments.optionalInt("register")
    if let register, !PlayerPerformance.registerRange.contains(register) {
      throw AgentError.invalidArgument("register", "use -1, 0 or 1.")
    }
    let regions = spans.enumerated().map { index, span in
      var part = PlayerPerformance.forSection(
        named: span.name, style: style, isLast: index == spans.count - 1, seed: UInt64.random(in: 1...UInt64.max))
      if let complexity { part.complexity = complexity }
      if let loudness { part.loudness = loudness }
      if let swing { part.swing = swing }
      if let register { part.register = register }
      var region = Region(name: span.name, start: span.start, length: span.end - span.start, content: .midi(MIDISequence()), player: part)
      region.renderPlayer(in: project)
      return region
    }
    commands += replacingCommands(regions, on: track)
    try session.performEdit(CompositeCommand("Add Session Player", commands: commands), named: "Add Session Player")
    return partResult(track: track, regions: regions, in: session.project)
  }

  static let editSessionPart = AgentTool(
    name: "edit_session_part", title: "Edit Session Part",
    description: """
      Changes drummer or session player regions: their style and settings, or a new take \
      (the same settings played differently). Give regions, or a track to change all its \
      drummer and player regions (optionally only in some sections).
      """,
    properties: performanceProperties.merging([
      "regions": Schema.array(Schema.string("A region's id."), "The regions to change."),
      "track": Schema.track,
      "sections": Schema.array(Schema.string("A section's name or id."), "With \"track\": only its regions in these sections."),
      "style": Schema.string("A drummer or player style from list_session_players."),
      "newTake": Schema.boolean("Plays the part again differently."),
      "fills": Schema.number("Drummer: no fills (0) to many (1)."),
      "feel": Schema.choice(DrummerPerformance.Feel.allCases.map(\.rawValue), "Drummer: where the backbeat falls."),
      "timekeeper": Schema.choice(DrummerPerformance.Timekeeper.allCases.map(\.rawValue), "Drummer: what keeps time."),
      "register": Schema.integer("Player: octaves up (1) or down (-1)."),
    ]) { current, _ in current }
  ) { arguments, session in
    let project = session.project
    let regions = try sessionRegions(arguments, in: project)
    let drummerIDs = Set(regions.filter { $0.drummer != nil }.map(\.id))
    let playerIDs = Set(regions.filter { $0.player != nil }.map(\.id))
    guard !drummerIDs.isEmpty || !playerIDs.isEmpty else {
      throw AgentError.notFound("None of those regions is a drummer or session player region.")
    }
    let complexity = try arguments.optionalAmount("complexity"), loudness = try arguments.optionalAmount("loudness")
    let swing = try arguments.optionalAmount("swing"), fills = try arguments.optionalAmount("fills")
    let feel = try arguments.optionalChoice("feel", DrummerPerformance.Feel.self)
    let timekeeper = try arguments.optionalChoice("timekeeper", DrummerPerformance.Timekeeper.self)
    let register = try arguments.optionalInt("register")
    let newTake = try arguments.optionalBool("newTake") == true
    let style = try arguments.optionalString("style").map(AgentNames.simplified)
    let drummerStyle = style.flatMap { style in DrummerPerformance.Style.allCases.first { AgentNames.simplified($0.rawValue) == style } }
    let playerStyle = style.flatMap { style in PlayerPerformance.Style.allCases.first { AgentNames.simplified($0.rawValue) == style } }
    if let style {
      guard drummerStyle != nil || playerStyle != nil else {
        throw AgentError.invalidArgument("style", "“\(style)” isn't a style; list_session_players lists them.")
      }
      if let playerStyle, regions.contains(where: { $0.player.map { $0.instrument != playerStyle.instrument } ?? false }) {
        throw AgentError.invalidArgument("style", "\(playerStyle.rawValue) is a \(playerStyle.instrument.rawValue) style, but a region is another player's.")
      }
    }
    var commands: [any EditCommand] = []
    if !drummerIDs.isEmpty {
      commands.append(SetDrummerPerformance(for: drummerIDs) { part in
        if let drummerStyle { part.style = drummerStyle; part.swing = drummerStyle.defaultSwing }
        if let complexity { part.complexity = complexity }
        if let loudness { part.loudness = loudness }
        if let swing { part.swing = swing }
        if let fills { part.fills = fills }
        if let feel { part.feel = feel }
        if let timekeeper { part.timekeeper = timekeeper }
        if newTake { part.seed = UInt64.random(in: 1...UInt64.max) }
      })
    }
    if !playerIDs.isEmpty {
      commands.append(SetPlayerPerformance(for: playerIDs) { part in
        if let playerStyle { part.style = playerStyle; part.swing = playerStyle.defaultSwing }
        if let complexity { part.complexity = complexity }
        if let loudness { part.loudness = loudness }
        if let swing { part.swing = swing }
        if let register { part.register = min(max(register, -1), 1) }
        if newTake { part.seed = UInt64.random(in: 1...UInt64.max) }
      })
    }
    try session.performEdit(CompositeCommand("Edit Session Part", commands: commands), named: "Edit Session Part")
    let updated = session.project
    return ["regions": .array(drummerIDs.union(playerIDs).compactMap(updated.region(withID:)).sorted { $0.start < $1.start }.map {
      AgentDescriptions.region($0, in: updated)
    })]
  }

  static let convertToNotes = AgentTool(
    name: "convert_to_notes", title: "Convert to Notes",
    description: """
      Turns drummer, session player or pattern regions into ordinary MIDI regions with the \
      notes they play, so the notes can be edited with add_notes and transform_notes. They \
      stop following the sections and chords.
      """,
    properties: ["regions": Schema.array(Schema.string("A region's id."), "The regions to convert.")],
    required: ["regions"]
  ) { arguments, session in
    let regions = try arguments.regions("regions", in: session.project)
    try session.performEdit(ConvertPatternToNotes(Set(regions.map(\.id))), named: "Convert to Notes")
    let updated = session.project
    return ["regions": .array(regions.compactMap { updated.region(withID: $0.id) }.map { AgentDescriptions.region($0, in: updated) })]
  }

  // MARK: - Helpers

  /// Where a part plays: the sections asked for, a from–to stretch, every section, or (with
  /// no sections) the whole song so far, at least eight bars.
  static func spans(_ arguments: AgentArguments, in project: Project) throws -> [(name: String, start: Tick, end: Tick)] {
    let tempoMap = project.tempoMap
    let sorted = project.arrangement.sorted { $0.start < $1.start }
    if let names = try arguments.optionalArray("sections") {
      let sections = try sectionsNamed(names, in: project)
      return sections.map { ($0.name, $0.start, $0.end) }
    }
    if let from = try arguments.optionalPosition("from", in: project) {
      guard let to = try arguments.optionalPosition("to", in: project), to > from else {
        throw AgentError.invalidArgument("to", "give where the part ends, after \"from\".")
      }
      let name = sorted.first { $0.range.contains(from) }?.name ?? "Part"
      return [(name, from, to)]
    }
    if !sorted.isEmpty { return sorted.map { ($0.name, $0.start, $0.end) } }
    let lastEnd = project.tracks.flatMap(\.regions).filter { $0.drummer == nil && $0.player == nil }.map(\.end).max() ?? .zero
    let lastBar = max(8, tempoMap.bar(containing: max(.zero, lastEnd - Tick(1))).index + 1)
    return [("Part", .zero, tempoMap.tickPosition(ofBarIndex: lastBar))]
  }

  /// Sections by id, or every section with a name.
  private static func sectionsNamed(_ names: [AgentValue], in project: Project) throws -> [ArrangementSection] {
    var found: [ArrangementSection] = []
    for value in names {
      guard let text = value.stringValue else { throw AgentError.invalidArgument("sections", "list section names or ids.") }
      let ids = AgentNames.match(text, among: project.arrangement.map(\.id))
      let matches = ids.count == 1
        ? project.arrangement.filter { $0.id == ids[0] }
        : project.arrangement.filter { $0.name.compare(text, options: .caseInsensitive) == .orderedSame }
      guard !matches.isEmpty else { _ = try section(text, in: project); continue }
      found += matches.filter { section in !found.contains { $0.id == section.id } }
    }
    return found.sorted { $0.start < $1.start }
  }

  /// The regions edit_session_part changes.
  private static func sessionRegions(_ arguments: AgentArguments, in project: Project) throws -> [Region] {
    if arguments.has("regions") { return try arguments.regions("regions", in: project) }
    guard let track = try arguments.optionalTrack("track", in: project) else { throw AgentError.missingArgument("regions") }
    var regions = track.regions.filter { $0.drummer != nil || $0.player != nil }
    if let names = try arguments.optionalArray("sections") {
      let sections = try sectionsNamed(names, in: project)
      regions = regions.filter { region in sections.contains { $0.range.contains(region.start) } }
    }
    return regions
  }

  /// Adds the regions to a track, removing what's there in the same bars.
  private static func replacingCommands(_ regions: [Region], on track: Track) -> [any EditCommand] {
    let replaced = track.regions.filter { existing in regions.contains { $0.start < existing.end && existing.start < $0.end } }
    return (replaced.isEmpty ? [] : [DeleteRegions(Set(replaced.map(\.id)))]) + regions.map { AddRegion($0, to: track.id) }
  }

  private static func partResult(track: Track, regions: [Region], in project: Project) -> AgentValue {
    [
      "track": AgentDescriptions.track(project.track(withID: track.id) ?? track, in: project),
      "regions": .array(regions.map { AgentDescriptions.region($0, in: project) }),
    ]
  }

  static func uniqueTrackName(_ base: String, in project: Project) -> String {
    let existing = Set(project.tracks.map(\.name))
    var name = base
    var number = 2
    while existing.contains(name) {
      name = "\(base) \(number)"
      number += 1
    }
    return name
  }
}
