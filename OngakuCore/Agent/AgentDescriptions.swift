//
//  AgentDescriptions.swift
//  OngakuCore
//

import Foundation

/// How the song looks to an agent: compact JSON, with short ids, bar:beat positions and
/// names rather than raw model values.
enum AgentDescriptions {
  static func track(_ track: Track, in project: Project) -> AgentValue {
    var info: [String: AgentValue] = [
      "id": AgentNames.shortID(track.id),
      "number": .int((project.trackIndex(for: track.id) ?? 0) + 1),
      "name": .string(track.name),
      "kind": .string(kindName(track.kind)),
      "regions": .int(track.regions.count),
      "volumeDb": .number(track.channel.volume),
      "pan": .number(track.channel.pan),
    ]
    if let instrument = track.channel.instrument { info["instrument"] = .string(AgentInstruments.name(of: instrument)) }
    if track.channel.isMuted { info["muted"] = true }
    if track.channel.isSoloed { info["soloed"] = true }
    if track.isFrozen { info["frozen"] = true }
    if AgentInstruments.playsDrums(track) { info["drums"] = true }
    return .object(info)
  }

  static func kindName(_ kind: TrackKind) -> String {
    switch kind {
    case .softwareInstrument: "instrument"
    case .audio: "audio"
    case .aux: "aux"
    }
  }

  /// What a region holds: written notes, a session drummer or player, a step pattern,
  /// takes, or audio.
  static func regionType(_ region: Region) -> String {
    if region.drummer != nil { return "drummer" }
    if region.player != nil { return "player" }
    if region.pattern != nil { return "pattern" }
    if region.takeFolder != nil { return "takes" }
    if case .audio = region.content { return "audio" }
    return "notes"
  }

  static func region(_ region: Region, in project: Project) -> AgentValue {
    let tempoMap = project.tempoMap
    var info: [String: AgentValue] = [
      "id": AgentNames.shortID(region.id),
      "name": .string(region.name),
      "type": .string(regionType(region)),
      "start": AgentNotation.format(region.start, tempoMap: tempoMap),
      "end": AgentNotation.format(region.end, tempoMap: tempoMap),
      "bars": .number(AgentNotation.bars(from: region.start, to: region.end, tempoMap: tempoMap)),
    ]
    if case .midi(let sequence) = region.content { info["notes"] = .int(sequence.notes.count) }
    if region.isMuted { info["muted"] = true }
    if region.isLooped {
      info["looped"] = true
      if let loopEnd = region.loopEnd { info["loopEnd"] = AgentNotation.format(loopEnd, tempoMap: tempoMap) }
    }
    if region.transpose != 0 { info["transpose"] = .int(region.transpose) }
    if let drummer = region.drummer { info["drummer"] = self.drummer(drummer) }
    if let player = region.player { info["player"] = self.player(player) }
    return .object(info)
  }

  static func drummer(_ part: DrummerPerformance) -> AgentValue {
    [
      "style": .string(part.style.rawValue), "complexity": .number(part.complexity), "loudness": .number(part.loudness),
      "fills": .number(part.fills), "swing": .number(part.swing), "feel": .string(part.feel.rawValue),
      "timekeeper": .string(part.timekeeper.rawValue),
    ]
  }

  static func player(_ part: PlayerPerformance) -> AgentValue {
    [
      "instrument": .string(part.instrument.rawValue), "style": .string(part.style.rawValue),
      "complexity": .number(part.complexity), "loudness": .number(part.loudness), "swing": .number(part.swing),
      "register": .int(part.register),
    ]
  }

  static func section(_ section: ArrangementSection, in project: Project) -> AgentValue {
    let tempoMap = project.tempoMap
    return [
      "id": AgentNames.shortID(section.id),
      "name": .string(section.name),
      "start": AgentNotation.format(section.start, tempoMap: tempoMap),
      "end": AgentNotation.format(section.end, tempoMap: tempoMap),
      "bars": .number(AgentNotation.bars(from: section.start, to: section.end, tempoMap: tempoMap)),
    ]
  }

  /// The Chord track as "bar:beat chord" pairs, the cheapest form for an agent to read.
  static func chords(in project: Project) -> AgentValue {
    .array(project.chords.map { .string("\(AgentNotation.format($0.position, tempoMap: project.tempoMap)) \($0.chord)") })
  }

  static func note(_ note: MIDINote) -> AgentValue {
    var info: [String: AgentValue] = [
      "id": AgentNames.shortID(note.id),
      "pitch": .int(note.pitch),
      "name": .string(AgentNotation.name(ofPitch: note.pitch)),
      "start": AgentNotation.beats(note.start),
      "length": AgentNotation.beats(note.length),
      "velocity": .int(note.velocity),
    ]
    if note.isMuted { info["muted"] = true }
    return .object(info)
  }
}

/// Naming and choosing the instruments a track plays.
enum AgentInstruments {
  /// Ongaku's own instruments that make sense on a track (the Session Drummer is a plug-in
  /// for other apps; Ongaku has Drummer regions instead).
  static let ongakuInstruments: [OngakuInstrument] = [.retroSynth, .drumMachine, .sampler]

  static func name(of source: InstrumentSource) -> String {
    switch source {
    case .generalMIDI(let program): "\(GeneralMIDI.programName(program)) (gm:\(program))"
    case .generalMIDIPercussion(let kit): "\(GeneralMIDI.drumKitName(kit)) (drums:\(kit))"
    case .audioUnit(let plugin): plugin.name
    }
  }

  /// Whether a track plays drums: a General MIDI kit or the Drum Machine.
  static func playsDrums(_ track: Track) -> Bool {
    switch track.channel.instrument {
    case .generalMIDIPercussion: true
    case .audioUnit(let plugin): OngakuInstrument(plugin) == .drumMachine || OngakuInstrument(plugin) == .sessionDrummer
    default: false
    }
  }

  /// Finds an instrument from what an agent calls it: "gm:33", a General MIDI program name
  /// ("Fingered Bass"), "drums" or a kit name ("TR-808 Kit", "drums:25"), one of Ongaku's
  /// instruments ("Retro Synth"), or an installed Audio Unit ("Alchemy", "Apple: DLSMusicDevice").
  static func resolve(_ text: String, audioUnits: [AgentAudioUnit], key: String = "instrument") throws -> InstrumentSource {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let wanted = AgentNames.simplified(trimmed)
    if let program = number(after: ["gm:", "gm", "program"], in: wanted) {
      guard (0...127).contains(program) else { throw AgentError.invalidArgument(key, "General MIDI programs run from 0 to 127.") }
      return .generalMIDI(program: program)
    }
    if let kit = number(after: ["drums:", "drums", "kit:"], in: wanted) {
      guard GeneralMIDI.drumKits.contains(where: { $0.kit == kit }) else {
        throw AgentError.invalidArgument(key, "the drum kits are \(GeneralMIDI.drumKits.map { "drums:\($0.kit) (\($0.name))" }.joined(separator: ", ")).")
      }
      return .generalMIDIPercussion(kit: kit)
    }
    if ["drums", "drumkit", "kit", "gmdrums"].contains(wanted) { return .generalMIDIPercussion(kit: 0) }
    if let kit = GeneralMIDI.drumKits.first(where: { AgentNames.simplified($0.name) == wanted || AgentNames.simplified($0.name) == wanted + "kit" }) {
      return .generalMIDIPercussion(kit: kit.kit)
    }
    if let instrument = ongakuInstruments.first(where: { AgentNames.simplified($0.name) == wanted }) {
      return .audioUnit(instrument.makeReference())
    }
    let programs = (0..<128).map { ($0, AgentNames.simplified(GeneralMIDI.programName($0))) }
    if let exact = programs.first(where: { $0.1 == wanted }) { return .generalMIDI(program: exact.0) }
    if let unit = audioUnits.first(where: {
      AgentNames.simplified($0.name) == wanted || AgentNames.simplified("\($0.manufacturer):\($0.name)") == wanted
    }) {
      return .audioUnit(unit.reference)
    }
    // A unique part of a General MIDI name ("vibraphone", "fretless").
    let partial = programs.filter { $0.1.contains(wanted) }
    if partial.count == 1, !wanted.isEmpty { return .generalMIDI(program: partial[0].0) }
    let suggestion = partial.isEmpty ? "" : " Did you mean \(partial.prefix(5).map { "\(GeneralMIDI.programName($0.0)) (gm:\($0.0))" }.joined(separator: ", "))?"
    throw AgentError.invalidArgument(key, "there's no instrument “\(trimmed)”.\(suggestion) Call list_instruments to see them all.")
  }

  private static func number(after prefixes: [String], in text: String) -> Int? {
    for prefix in prefixes where text.hasPrefix(prefix) {
      if let number = Int(text.dropFirst(prefix.count)) { return number }
    }
    return nil
  }
}
