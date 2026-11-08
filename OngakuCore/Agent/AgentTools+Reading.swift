//
//  AgentTools+Reading.swift
//  OngakuCore
//

import Foundation

/// Tools that read the song, list what's available, play it, and undo, redo and save.
extension AgentToolbox {
  static let readingTools: [AgentTool] = [
    getSong, getTrack, getNotes, listInstruments, listSessionPlayers, play, stop, undo, redo, save,
  ]

  static let getSong = AgentTool(
    name: "get_song", title: "Get Song",
    description: """
      The whole song at a glance: tempo, time signature, key, length, cycle, playhead, \
      arrangement sections, markers, the Chord track, and every track (id, name, instrument, \
      region count, volume, pan). Start here, and call it again after big changes.
      """,
    isReadOnly: true
  ) { _, session in
    let project = session.project
    let tempoMap = project.tempoMap
    func at(_ position: Tick) -> AgentValue { AgentNotation.format(position, tempoMap: tempoMap) }
    var song: [String: AgentValue] = [
      "name": .string(session.songName),
      "tempo": .number(tempoMap.tempo(at: .zero)),
      "timeSignature": .string(tempoMap.timeSignature(atBarIndex: 0).description),
      "key": .string(AgentNotation.name(of: project.keySignature)),
      "end": at(project.endPosition),
      "bars": .number(AgentNotation.bars(from: .zero, to: project.endPosition, tempoMap: tempoMap)),
      "cycle": [
        "on": .bool(project.cycle.isEnabled), "start": at(project.cycle.start), "end": at(project.cycle.end),
      ],
      "playhead": at(session.playheadPosition),
      "playing": .bool(session.isPlaying),
      "sections": .array(project.arrangement.map { AgentDescriptions.section($0, in: project) }),
      "chords": AgentDescriptions.chords(in: project),
      "tracks": .array(project.tracks.map { AgentDescriptions.track($0, in: project) }),
    ]
    if tempoMap.tempoChanges.count > 1 {
      song["tempoChanges"] = .array(tempoMap.tempoChanges.dropFirst().map { ["at": at($0.position), "bpm": .number($0.bpm)] })
    }
    if tempoMap.meterChanges.count > 1 {
      song["timeSignatureChanges"] = .array(tempoMap.meterChanges.dropFirst().map {
        ["bar": .int($0.barIndex + 1), "signature": .string($0.signature.description)]
      })
    }
    if !project.keyChanges.isEmpty {
      song["keyChanges"] = .array(project.keyChanges.map { ["at": at($0.position), "key": .string(AgentNotation.name(of: $0.key))] })
    }
    if !project.markers.isEmpty {
      song["markers"] = .array(project.markers.map { ["id": AgentNames.shortID($0.id), "name": .string($0.name), "at": at($0.position)] })
    }
    return .object(song)
  }

  static let getTrack = AgentTool(
    name: "get_track", title: "Get Track",
    description: """
      One track in detail: its instrument, channel strip (volume, pan, mute, solo, MIDI \
      effects, inserts, sends) and its regions with their ids, positions and what they hold \
      (written notes, a drummer or session player part, a pattern, audio).
      """,
    properties: ["track": Schema.track], required: ["track"], isReadOnly: true
  ) { arguments, session in
    let project = session.project
    let track = try arguments.track("track", in: project)
    guard case .object(var info) = AgentDescriptions.track(track, in: project) else { return .null }
    info["color"] = .string(track.color.rawValue)
    info["midiEffects"] = .array(track.channel.midiEffects.map { .string($0.name) })
    info["inserts"] = .array(track.channel.inserts.map { .string($0.isBypassed ? "\($0.name) (bypassed)" : $0.name) })
    info["sends"] = .array(track.channel.sends.map { send in
      ["to": .string(project.track(withID: send.destinationTrackID)?.name ?? "?"), "levelDb": .number(send.level)]
    })
    if let output = track.channel.output.trackID { info["output"] = .string(project.track(withID: output)?.name ?? "?") }
    info["regions"] = .array(track.regions.map { AgentDescriptions.region($0, in: project) })
    return .object(info)
  }

  static let getNotes = AgentTool(
    name: "get_notes", title: "Get Notes",
    description: """
      The notes in a MIDI region. Each note has an id, pitch (number and name, C4 = 60), \
      start and length in beats (quarter notes) from the region's start, and velocity. \
      Drummer and session player regions show the notes they currently play.
      """,
    properties: [
      "region": Schema.region,
      "from": Schema.number("Only notes starting at or after this beat (from the region start)."),
      "to": Schema.number("Only notes starting before this beat."),
    ],
    required: ["region"], isReadOnly: true
  ) { arguments, session in
    let project = session.project
    let region = try arguments.region("region", in: project)
    guard case .midi(let sequence) = region.content else {
      throw AgentError.notPossible("“\(region.name)” is an audio region; it has no notes.")
    }
    let from = try arguments.optionalDouble("from").map(AgentNotation.ticks(beats:)) ?? Tick(Int64.min)
    let to = try arguments.optionalDouble("to").map(AgentNotation.ticks(beats:)) ?? Tick(Int64.max)
    let notes = sequence.notes.filter { $0.start >= from && $0.start < to }
    guard case .object(var info) = AgentDescriptions.region(region, in: project) else { return .null }
    info["track"] = .string(AgentNames.track(containing: region.id, in: project)?.name ?? "?")
    info["lengthBeats"] = AgentNotation.beats(region.length)
    info["notes"] = .array(notes.map(AgentDescriptions.note))
    return .object(info)
  }

  static let listInstruments = AgentTool(
    name: "list_instruments", title: "List Instruments",
    description: """
      The sounds a track can play: the 128 General MIDI instruments (by family), the drum \
      kits, Ongaku's own instruments, the Audio Unit instruments installed on this Mac, and \
      the sampled instruments in the person's sound libraries (Settings › Libraries), which \
      are often the best-sounding. Libraries can hold thousands, so search them: \
      search "piano" or "strings". Use a name, code or library "sound" from here as the \
      "instrument" of create_track or update_track.
      """,
    properties: [
      "family": Schema.string("Only this General MIDI family, such as \"Bass\", \"Synth Lead\" or \"Strings\"."),
      "search": Schema.string("Words to find in the sound libraries' instruments (names and folders), such as \"grand piano\"."),
      "library": Schema.string("Only this sound library's instruments."),
      "limit": Schema.integer("How many library instruments to return, up to 100 (25 if left out)."),
    ],
    isReadOnly: true
  ) { arguments, session in
    if arguments.has("search") || arguments.has("library") {
      let libraries = try AgentLibrary.libraries(try arguments.optionalString("library"), in: session)
      let found = AgentLibrary.instruments(matching: try arguments.optionalString("search"), in: libraries)
      return AgentLibrary.results(found, limit: try AgentLibrary.limit(arguments), key: "libraryInstruments")
    }
    let family = try arguments.optionalString("family").map(AgentNames.simplified)
    let families = GeneralMIDI.families.filter { family == nil || AgentNames.simplified($0.name) == family }
    if let family, families.isEmpty {
      throw AgentError.invalidArgument("family", "“\(family)” isn't a family; they are \(GeneralMIDI.families.map(\.name).joined(separator: ", ")).")
    }
    var list: [String: AgentValue] = [
      "generalMIDI": .object(Dictionary(uniqueKeysWithValues: families.map { family in
        (family.name, .array(family.programs.map { .string("gm:\($0) \(GeneralMIDI.programName($0))") }))
      })),
    ]
    if family == nil {
      list["drumKits"] = .array(GeneralMIDI.drumKits.map { .string("drums:\($0.kit) \($0.name)") })
      list["ongaku"] = [
        "Retro Synth: a warm analogue-style synth for leads, basses and pads",
        "Drum Machine: an electronic kit on General MIDI drum notes",
        "Sampler: plays a sample across the keyboard",
      ]
      list["audioUnits"] = .array(session.installedAudioUnits.map { .string("\($0.manufacturer): \($0.name)") })
      let libraries = session.soundLibraries
      if !libraries.isEmpty {
        list["soundLibraries"] = .array(libraries.map { library in
          let count = AgentLibrary.instruments(matching: nil, in: [library]).count
          return ["name": .string(library.name), "instruments": .int(count)]
        })
        list["libraryNote"] = "Pass search (and optionally library) to list the sound libraries' instruments."
      }
      list["note"] = "General MIDI sounds load instantly and suit sketches; drum kits play General MIDI drum notes (kick 36, snare 38, closed hat 42)."
    }
    return .object(list)
  }

  static let listSessionPlayers = AgentTool(
    name: "list_session_players", title: "List Session Players",
    description: """
      Ongaku's session players and what they can do: the Drummer's styles and settings, the \
      Bass and Keys players' styles, the chord progressions for the song's key, and how to \
      write chord symbols. Session players follow the arrangement sections and the Chord track.
      """,
    isReadOnly: true
  ) { _, session in
    let key = session.project.keySignature
    return [
      "drummer": [
        "styles": .array(DrummerPerformance.Style.allCases.map { .string("\($0.rawValue): \($0.summary)") }),
        "feels": .array(DrummerPerformance.Feel.allCases.map { .string($0.rawValue) }),
        "timekeepers": .array(DrummerPerformance.Timekeeper.allCases.map { .string($0.rawValue) }),
        "settings": "complexity, loudness, fills and swing run from 0 to 1. Each section gets its own part, played to suit its name (quiet intro, loud chorus, fills between).",
      ],
      "players": .object(Dictionary(uniqueKeysWithValues: PlayerPerformance.Instrument.allCases.map { instrument in
        (instrument.rawValue, .array(PlayerPerformance.Style.styles(for: instrument).map { .string("\($0.rawValue): \($0.summary)") }))
      })),
      "playerSettings": "complexity, loudness and swing run from 0 to 1; register is -1, 0 or 1 (octaves). Players follow the Chord track, so set chords first.",
      "progressions": .array(ChordProgression.library(for: key).map { progression in
        .string("\(progression.name): \(progression.romanName) = \(progression.chords(in: key).map(\.description).joined(separator: " "))")
      }),
      "progressionKey": .string(AgentNotation.name(of: key)),
      "chordSymbols": "A root (C, F#, Bb) then a quality: nothing (major), m, 7, maj7, m7, dim, m7b5, aug, sus2, sus4, 6, m6, add9, 9, m9, 5; optionally /bass, as in \"C/E\".",
    ]
  }

  static let play = AgentTool(
    name: "play", title: "Play",
    description: "Starts playback so the person can hear the song, from a position or from the playhead.",
    properties: ["from": Schema.position("Where to start; leave out to play from the playhead.")],
    isReadOnly: true
  ) { arguments, session in
    let from = try arguments.optionalPosition("from", in: session.project)
    session.play(from: from)
    return ["playing": true, "from": AgentNotation.format(from ?? session.playheadPosition, tempoMap: session.project.tempoMap)]
  }

  static let stop = AgentTool(
    name: "stop", title: "Stop", description: "Stops playback.", isReadOnly: true
  ) { _, session in
    session.stop()
    return ["playing": false, "playhead": AgentNotation.format(session.playheadPosition, tempoMap: session.project.tempoMap)]
  }

  static let undo = AgentTool(
    name: "undo", title: "Undo",
    description: "Undoes the last change to the song (yours or the person's), as Edit › Undo does."
  ) { _, session in
    guard let name = session.undo() else { throw AgentError.notPossible("There's nothing to undo.") }
    return ["undid": .string(name)]
  }

  static let redo = AgentTool(
    name: "redo", title: "Redo", description: "Redoes the last change that was undone."
  ) { _, session in
    guard let name = session.redo() else { throw AgentError.notPossible("There's nothing to redo.") }
    return ["redid": .string(name)]
  }

  static let save = AgentTool(
    name: "save", title: "Save",
    description: "Saves the song, as File › Save does. A song that's never been saved can't be: ask the person to choose File › Save first, as only they can pick where it goes."
  ) { _, session in
    try await session.save()
    return ["saved": .string(session.songName)]
  }
}
