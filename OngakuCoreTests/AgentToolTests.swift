//
//  AgentToolTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// The tools agents make music with: their units, and what they do to a song.
@MainActor
struct AgentToolTests {
  /// A song open in a `ProjectEditor`, standing in for a project window.
  final class Session: AgentSession {
    let editor: ProjectEditor
    let undoManager = UndoManager()
    var isPlaying = false
    var playheadPosition = Tick.zero
    var saveCount = 0

    init(_ project: Project = Project()) {
      editor = ProjectEditor(project: project)
      undoManager.groupsByEvent = false
    }

    var project: Project { editor.project }
    var songName: String { "Test Song" }
    var installedAudioUnits: [AgentAudioUnit] { [] }

    func performEdit(_ command: any EditCommand, named actionName: String) throws {
      undoManager.beginUndoGrouping()
      defer { undoManager.endUndoGrouping() }
      try editor.perform(CompositeCommand(actionName, commands: [command]), undoManager: undoManager)
    }

    func play(from position: Tick?) {
      if let position { playheadPosition = position }
      isPlaying = true
    }

    func stop() { isPlaying = false }

    func undo() -> String? {
      guard undoManager.canUndo else { return nil }
      let name = undoManager.undoActionName
      undoManager.undo()
      return name
    }

    func redo() -> String? {
      guard undoManager.canRedo else { return nil }
      let name = undoManager.redoActionName
      undoManager.redo()
      return name
    }

    func save() throws { saveCount += 1 }

    // Every plug-in "loads" at once with two parameters, and a render is a test tone.
    var installedEffects: [AgentAudioUnit] { [] }
    var pluginValues: [PluginReference.ID: [UInt64: Double]] = [:]
    var renderedAudio = AgentAudio(left: [], right: [], sampleRate: 48_000)
    var bouncedRange: Range<Tick>?

    func waitForPlugin(_ pluginID: PluginReference.ID, on channelID: Track.ID) async -> Bool {
      (try? project.inserts(of: channelID))?.contains { $0.id == pluginID } == true
    }

    func parameters(ofPlugin pluginID: PluginReference.ID, on channelID: Track.ID) -> [AgentPluginParameter]? {
      let values = pluginValues[pluginID] ?? [:]
      return [
        AgentPluginParameter(address: 1, name: "Mix", value: values[1] ?? 50, minimum: 0, maximum: 100, unit: "%"),
        AgentPluginParameter(address: 2, name: "Type", value: values[2] ?? 0, minimum: 0, maximum: 2, unit: "", choices: ["Room", "Hall", "Plate"]),
      ]
    }

    func presets(ofPlugin pluginID: PluginReference.ID, on channelID: Track.ID) -> [String] { ["Big Hall"] }

    func setPlugin(
      _ pluginID: PluginReference.ID, on channelID: Track.ID, preset: String?, values: [UInt64: Double], named actionName: String
    ) async throws {
      if preset != nil { pluginValues[pluginID, default: [:]][2] = 1 }
      pluginValues[pluginID, default: [:]].merge(values) { _, new in new }
      try performEdit(SetPluginState(Data("set".utf8), forPlugin: pluginID, on: channelID), named: actionName)
    }

    func renderMix(_ range: Range<Tick>) async throws -> AgentAudio { renderedAudio }

    func bounce(_ range: Range<Tick>, settings: BounceSettings) async throws -> AgentBounce {
      bouncedRange = range
      return AgentBounce(path: "/tmp/Song.\(settings.format.fileExtension)", seconds: 8, peakDecibels: 0.4, isClipped: true)
    }

    func masterSong() async throws -> MasteringAnalysis.Result? { nil }
  }

  private let bar = Tick.quarterNotes(4)

  @discardableResult
  private func call(_ name: String, _ arguments: [String: AgentValue] = [:], in session: Session) async throws -> AgentValue {
    try await AgentToolbox.call(name, arguments: arguments, in: session)
  }

  // MARK: - The toolbox

  @Test func everyToolHasAUniqueNameAndAnObjectSchema() async {
    let names = AgentToolbox.tools.map(\.name)
    #expect(Set(names).count == names.count)
    for tool in AgentToolbox.tools {
      #expect(tool.inputSchema["type"] == "object", "\(tool.name)")
      #expect(!tool.description.isEmpty, "\(tool.name)")
      // Every required argument is described.
      let properties = tool.inputSchema["properties"]?.objectValue ?? [:]
      for required in tool.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
        #expect(properties[required] != nil, "\(tool.name) requires \(required)")
      }
    }
  }

  @Test func unknownToolsAndMissingArgumentsExplainThemselves() async {
    let session = Session()
    await #expect(throws: AgentError.unknownTool("make_hit")) { try await call("make_hit", in: session) }
    await #expect(throws: AgentError.missingArgument("bpm")) { try await call("set_tempo", in: session) }
  }

  // MARK: - Units

  @Test func positionsAreBarsAndBeats() async throws {
    var tempoMap = TempoMap()
    try tempoMap.setTimeSignature(TimeSignature(beatsPerBar: 6, beatUnit: 8), atBarIndex: 4)
    #expect(try AgentNotation.position("1", key: "at", tempoMap: tempoMap) == .zero)
    #expect(try AgentNotation.position(.int(2), key: "at", tempoMap: tempoMap) == bar)
    #expect(try AgentNotation.position("2:3", key: "at", tempoMap: tempoMap) == bar + Tick(1920))
    #expect(try AgentNotation.position("1:2.5", key: "at", tempoMap: tempoMap) == Tick(1440))
    // Bar 5 is in 6/8, so its beats are eighth notes.
    #expect(try AgentNotation.position("5:4", key: "at", tempoMap: tempoMap) == bar * 4 + Tick(1440))
    #expect(AgentNotation.format(bar * 4 + Tick(1440), tempoMap: tempoMap) == "5:4")
    #expect(AgentNotation.format(Tick(1440), tempoMap: tempoMap) == "1:2.5")
    #expect(throws: AgentError.self) { try AgentNotation.position("0:1", key: "at", tempoMap: tempoMap) }
    #expect(throws: AgentError.self) { try AgentNotation.position("2:5", key: "at", tempoMap: tempoMap) }
  }

  @Test func pitchesAreNamedWithMiddleCAsC4() async throws {
    #expect(try AgentNotation.pitch("C4") == 60)
    #expect(try AgentNotation.pitch("F#3") == 54)
    #expect(try AgentNotation.pitch("Bb2") == 46)
    #expect(try AgentNotation.pitch("C-1") == 0)
    #expect(try AgentNotation.pitch(.int(64)) == 64)
    #expect(try AgentNotation.pitch("closed hat") == 42)
    #expect(try AgentNotation.pitch("Kick") == 36)
    #expect(AgentNotation.name(ofPitch: 61) == "C#4")
    #expect(AgentNotation.name(ofPitch: 0) == "C-1")
    #expect(throws: AgentError.self) { try AgentNotation.pitch("H2") }
  }

  @Test func keysMetersAndGrids() async throws {
    #expect(try AgentNotation.key("A minor") == KeySignature(tonic: 9, mode: .minor))
    #expect(try AgentNotation.key("F#m") == KeySignature(tonic: 6, mode: .minor))
    #expect(try AgentNotation.key("Eb") == KeySignature(tonic: 3, mode: .major))
    #expect(AgentNotation.name(of: KeySignature(tonic: 10, mode: .major)) == "Bb major")
    #expect(AgentNotation.name(of: KeySignature(tonic: 1, mode: .minor)) == "C# minor")
    #expect(try AgentNotation.timeSignature("6/8") == TimeSignature(beatsPerBar: 6, beatUnit: 8))
    #expect(try AgentNotation.grid("1/16") == Tick(240))
    #expect(try AgentNotation.grid("1/8T") == Tick(320))
  }

  @Test func instrumentsAreFoundByNameOrCode() async throws {
    #expect(try AgentInstruments.resolve("gm:33", audioUnits: []) == .generalMIDI(program: 33))
    #expect(try AgentInstruments.resolve("Electric Piano 1", audioUnits: []) == .generalMIDI(program: 4))
    #expect(try AgentInstruments.resolve("drums", audioUnits: []) == .generalMIDIPercussion(kit: 0))
    #expect(try AgentInstruments.resolve("TR-808 Kit", audioUnits: []) == .generalMIDIPercussion(kit: 25))
    #expect(try AgentInstruments.resolve("vibraphone", audioUnits: []) == .generalMIDI(program: 11))
    guard case .audioUnit(let plugin) = try AgentInstruments.resolve("Retro Synth", audioUnits: []) else {
      Issue.record("Retro Synth should be an Audio Unit")
      return
    }
    #expect(OngakuInstrument(plugin) == .retroSynth)
    #expect(throws: AgentError.self) { try AgentInstruments.resolve("kazoo orchestra", audioUnits: []) }
  }

  // MARK: - Writing a song

  @Test func aTrackGetsARegionOfNotes() async throws {
    let session = Session()
    let created = try await call("create_track", ["name": "Lead", "instrument": "square lead"], in: session)
    let trackID = try #require(created["id"]?.stringValue)
    #expect(session.project.tracks.last?.channel.instrument == .generalMIDI(program: 80))

    let region = try await call("create_region", [
      "track": .string(trackID), "start": "3", "bars": 2,
      "notes": [["pitch": "E4", "start": 0, "length": 1, "velocity": 90], "G4 1 0.5", "C5 1.5 2.5 110"],
    ], in: session)
    #expect(region["start"] == "3:1")
    #expect(region["end"] == "5:1")
    #expect(region["notesAdded"] == 3)

    let notes = try await call("get_notes", ["region": try #require(region["id"])], in: session)
    let pitches = notes["notes"]?.arrayValue?.compactMap { $0["name"]?.stringValue }
    #expect(pitches == ["E4", "G4", "C5"])
    #expect(notes["notes"]?.arrayValue?[1]["length"] == .double(0.5))
    #expect(notes["notes"]?.arrayValue?[2]["velocity"] == 110)

    // Tracks can be named or numbered, regions found by the start of their id.
    let track = try await call("get_track", ["track": "lead"], in: session)
    #expect(track["number"] == .int(session.project.tracks.count))
    #expect(track["regions"]?.arrayValue?.count == 1)
  }

  @Test func notesCanBeReplacedTransformedAndDeleted() async throws {
    let session = Session()
    let trackID = try #require(try await call("create_track", [:], in: session)["id"])
    let regionID = try #require(try await call("create_region", ["track": trackID, "start": 1, "bars": 1, "notes": ["C4 0 1", "E4 1 1", "G4 2 1"]], in: session)["id"])

    try await call("transform_notes", ["region": regionID, "transpose": 2, "velocity": 80], in: session)
    var notes = try await call("get_notes", ["region": regionID], in: session)["notes"]?.arrayValue ?? []
    #expect(notes.compactMap { $0["name"]?.stringValue } == ["D4", "F#4", "A4"])
    #expect(notes.allSatisfy { $0["velocity"] == 80 })

    try await call("delete_notes", ["region": regionID, "pitch": "F#4"], in: session)
    notes = try await call("get_notes", ["region": regionID], in: session)["notes"]?.arrayValue ?? []
    #expect(notes.count == 2)

    let added = try await call("add_notes", ["region": regionID, "notes": ["C3 0 4"], "replace": true], in: session)
    #expect(added["notesInRegion"] == 1)

    // A note after the region's end is written, with a warning.
    let late = try await call("add_notes", ["region": regionID, "notes": ["C3 6 1"]], in: session)
    #expect(late["warning"] != nil)
  }

  @Test func eachCallIsOneUndoStep() async throws {
    let session = Session()
    try await call("set_tempo", ["bpm": 92], in: session)
    try await call("create_track", ["name": "Keys"], in: session)
    #expect(session.project.tempoMap.tempo(at: .zero) == 92)
    #expect(try await call("undo", in: session)["undid"] == "Create Track")
    #expect(session.project.tracks.contains { $0.name == "Keys" } == false)
    #expect(try await call("undo", in: session)["undid"] == "Set Tempo")
    #expect(session.project.tempoMap.tempo(at: .zero) == 120)
    try await call("redo", in: session)
    #expect(session.project.tempoMap.tempo(at: .zero) == 92)
  }

  @Test func theArrangementIsLaidOutWithoutMovingAnything() async throws {
    let session = Session()
    let trackID = try #require(try await call("create_track", [:], in: session)["id"])
    try await call("create_region", ["track": trackID, "start": 1, "bars": 4], in: session)
    let result = try await call("set_arrangement", ["sections": [["name": "Intro", "bars": 4], ["name": "Verse", "bars": 8], ["name": "Chorus", "bars": 8]]], in: session)
    #expect(result["sections"]?.arrayValue?.compactMap { $0["start"]?.stringValue } == ["1:1", "5:1", "13:1"])
    // Laying it out again replaces the sections, and the region stays.
    try await call("set_arrangement", ["sections": [["name": "Verse", "bars": 8]]], in: session)
    #expect(session.project.arrangement.map(\.name) == ["Verse"])
    #expect(session.project.tracks.flatMap(\.regions).count == 1)
  }

  @Test func chordsFillSectionsBarByBar() async throws {
    let session = Session()
    try await call("set_arrangement", ["sections": [["name": "Verse", "bars": 4], ["name": "Chorus", "bars": 4]]], in: session)
    let result = try await call("set_chords", ["section": "chorus", "bars": ["C", "Am F"]], in: session)
    #expect(result["chords"] == ["5:1 C", "6:1 Am", "6:3 F", "7:1 C", "8:1 Am", "8:3 F"])
    #expect(session.project.chords.allSatisfy { $0.position >= bar * 4 })

    try await call("set_key", ["key": "A minor"], in: session)
    let progression = try await call("set_chords", ["progression": AgentValue.string(ChordProgression.minor[0].name), "from": 1, "to": 5], in: session)
    #expect(progression["chords"]?.arrayValue?.isEmpty == false)
    await #expect(throws: AgentError.self) { try await call("set_chords", ["bars": ["C H7"]], in: session) }
  }

  @Test func theDrummerPlaysEverySection() async throws {
    let session = Session()
    try await call("set_arrangement", ["sections": [["name": "Intro", "bars": 4], ["name": "Chorus", "bars": 8]]], in: session)
    let result = try await call("add_drummer", ["style": "funk"], in: session)
    let drummer = try #require(session.project.tracks.first { $0.name == "Drummer" })
    #expect(drummer.channel.instrument == .generalMIDIPercussion(kit: 0))
    #expect(drummer.regions.map(\.name) == ["Intro", "Chorus"])
    #expect(drummer.regions.allSatisfy { $0.drummer?.style == .funk })
    #expect(result["regions"]?.arrayValue?.allSatisfy { ($0["notes"]?.intValue ?? 0) > 0 } == true)

    // Playing the chorus again replaces its region rather than stacking another.
    try await call("add_drummer", ["track": "Drummer", "sections": ["Chorus"], "style": "rock", "loudness": 0.9], in: session)
    let updated = try #require(session.project.track(withID: drummer.id))
    #expect(updated.regions.count == 2)
    #expect(updated.regions.last?.drummer?.style == .rock)
    #expect(updated.regions.last?.drummer?.loudness == 0.9)

    // Generated notes can't be written over until the part is converted to notes.
    let chorusID = AgentValue.string(AgentNames.shortID(try #require(updated.regions.last?.id)))
    await #expect(throws: AgentError.self) { try await call("add_notes", ["region": chorusID, "notes": ["kick 0 0.25"]], in: session) }
    try await call("convert_to_notes", ["regions": [chorusID]], in: session)
    try await call("add_notes", ["region": chorusID, "notes": [["pitch": "crash", "start": 0]]], in: session)
  }

  @Test func sessionPlayersFollowTheChords() async throws {
    let session = Session()
    try await call("set_arrangement", ["sections": [["name": "Verse", "bars": 4]]], in: session)
    await #expect(throws: AgentError.self) { try await call("add_session_player", ["instrument": "bass"], in: session) }
    try await call("set_chords", ["section": "Verse", "bars": ["C", "G", "Am", "F"]], in: session)
    await #expect(throws: AgentError.self) { try await call("add_session_player", ["instrument": "bass", "style": "pad"], in: session) }

    try await call("add_session_player", ["instrument": "bass", "style": "walking"], in: session)
    let bass = try #require(session.project.tracks.first { $0.name == "Bass Player" })
    #expect(bass.channel.instrument == .generalMIDI(program: 33))
    let region = try #require(bass.regions.first)
    #expect(region.player?.style == .walking)
    guard case .midi(let sequence) = region.content else { return }
    #expect(!sequence.notes.isEmpty)

    // A new take plays the same part differently.
    let seed = region.player?.seed
    try await call("edit_session_part", ["track": "Bass Player", "newTake": true, "complexity": 0.8], in: session)
    let edited = try #require(session.project.region(withID: region.id)?.player)
    #expect(edited.seed != seed)
    #expect(edited.complexity == 0.8)
  }

  @Test func theSongSummaryDescribesEverything() async throws {
    let session = Session()
    try await call("set_tempo", ["bpm": 98.5], in: session)
    try await call("set_key", ["key": "D minor"], in: session)
    try await call("set_arrangement", ["sections": [["name": "Verse", "bars": 8]]], in: session)
    try await call("set_chords", ["bars": ["Dm", "Bb"]], in: session)
    try await call("create_track", ["name": "Piano", "instrument": "gm:0", "volumeDb": -3], in: session)
    let song = try await call("get_song", in: session)
    #expect(song["tempo"] == .double(98.5))
    #expect(song["key"] == "D minor")
    #expect(song["chords"] == ["1:1 Dm", "2:1 B♭"])
    let piano = song["tracks"]?.arrayValue?.last
    #expect(piano?["instrument"] == "Acoustic Grand Piano (gm:0)")
    #expect(piano?["volumeDb"] == -3)
  }
  // MARK: - Mixing

  @Test func effectsAreAddedSetAndUndone() async throws {
    let session = Session()
    let trackID = try #require(try await call("create_track", ["name": "Keys"], in: session)["id"])
    let added = try await call("add_effect", ["track": trackID, "effect": "Reverb", "parameters": ["Mix": 30]], in: session)
    #expect(added["name"] == "Reverb")
    #expect(added["parameters"]?.arrayValue?.first == "Mix: 30 % (0…100)")
    let insert = try #require(session.project.tracks.last?.channel.inserts.first)
    #expect(OngakuEffect(insert) == .reverb)
    #expect(insert.state == Data("set".utf8))

    // Choices by name, presets, and values outside the range.
    let set = try await call("set_effect", ["track": "Keys", "effect": "reverb", "parameters": ["Type": "Plate"]], in: session)
    #expect(set["parameters"]?.arrayValue?.last?.stringValue?.hasPrefix("Type: Plate") == true)
    try await call("set_effect", ["track": "Keys", "effect": "1", "preset": "big hall"], in: session)
    await #expect(throws: AgentError.self) { try await call("set_effect", ["track": "Keys", "effect": "Reverb", "parameters": ["Mix": 140]], in: session) }
    await #expect(throws: AgentError.self) { try await call("set_effect", ["track": "Keys", "effect": "Reverb", "preset": "Cathedral"], in: session) }
    await #expect(throws: AgentError.self) { try await call("add_effect", ["track": "Keys", "effect": "Flanger 9000"], in: session) }

    #expect(try await call("undo", in: session)["undid"] == "Reverb Settings")
    try await call("set_effect", ["track": "Keys", "effect": "Reverb", "bypass": true], in: session)
    #expect(session.project.tracks.last?.channel.inserts.first?.isBypassed == true)
    try await call("remove_effect", ["track": "Keys", "effect": "Reverb"], in: session)
    #expect(session.project.tracks.last?.channel.inserts.isEmpty == true)

    // Stereo Out has effects too.
    try await call("add_effect", ["track": "Stereo Out", "effect": "Apple Limiter"], in: session)
    #expect(session.project.stereoOutInserts.map(\.name) == ["Limiter"])
  }

  @Test func sendsGoToAuxTracks() async throws {
    let session = Session()
    try await call("create_track", ["name": "Vocal"], in: session)
    try await call("create_track", ["name": "Verb", "kind": "aux"], in: session)
    await #expect(throws: AgentError.self) { try await call("set_send", ["track": "Verb", "aux": "Vocal"], in: session) }
    let send = try await call("set_send", ["track": "Vocal", "aux": "Verb"], in: session)
    #expect(send["levelDb"] == -6)
    try await call("set_send", ["track": "Vocal", "aux": "Verb", "levelDb": -12], in: session)
    let vocal = try #require(session.project.tracks.first { $0.name == "Vocal" })
    #expect(vocal.channel.sends.map(\.level) == [-12])
    try await call("set_send", ["track": "Vocal", "aux": "Verb", "remove": true], in: session)
    #expect(session.project.tracks.first { $0.name == "Vocal" }?.channel.sends.isEmpty == true)
  }

  @Test func automationIsDrawnInItsOwnUnits() async throws {
    let session = Session()
    try await call("create_track", ["name": "Pad"], in: session)
    let fade = try await call("add_automation", ["track": "Pad", "parameter": "volume", "points": [["at": "9", "value": 0], ["at": "13", "value": -40]]], in: session)
    #expect(fade["points"] == ["9:1 0", "13:1 -40"])
    await #expect(throws: AgentError.self) {
      try await call("add_automation", ["track": "Pad", "parameter": "pan", "points": [["at": 1, "value": 3]]], in: session)
    }

    // An effect's parameter is stored as a fraction of its range, but read and written in its units.
    try await call("add_effect", ["track": "Pad", "effect": "Delay"], in: session)
    let sweep = try await call("add_automation", ["track": "Pad", "parameter": "Delay:Mix", "points": [["at": 1, "value": 0], ["at": 5, "value": 75]]], in: session)
    #expect(sweep["points"] == ["1:1 0", "5:1 75"])
    let pad = try #require(session.project.tracks.last)
    #expect(pad.automation.count == 2)
    let lane = try #require(pad.automation.first { if case .plugin = $0.parameter { true } else { false } })
    #expect(lane.points.map(\.value) == [0, 0.75])

    try await call("clear_automation", ["track": "Pad"], in: session)
    #expect(session.project.tracks.last?.automation.isEmpty == true)
  }

  @Test func midiEffectsTakeTheirOwnSettings() async throws {
    let session = Session()
    try await call("create_track", ["name": "Arp"], in: session)
    try await call("add_midi_effect", ["track": "Arp", "effect": "Arpeggiator", "settings": ["rate": "eighth", "order": "upDown", "octaves": 2]], in: session)
    guard case .arpeggiator(let arpeggiator)? = session.project.tracks.last?.channel.midiEffects.first?.settings else {
      Issue.record("Expected an arpeggiator")
      return
    }
    #expect(arpeggiator.rate == .eighth)
    #expect(arpeggiator.order == .upDown)
    #expect(arpeggiator.octaves == 2)
    await #expect(throws: AgentError.self) {
      try await call("add_midi_effect", ["track": "Arp", "effect": "Arpeggiator", "settings": ["rate": "warp speed"]], in: session)
    }
    await #expect(throws: AgentError.self) {
      try await call("add_midi_effect", ["track": "Arp", "effect": "Arpeggiator", "settings": ["flavour": 2]], in: session)
    }
    try await call("remove_midi_effect", ["track": "Arp", "effect": "arpeggiator"], in: session)
    #expect(session.project.tracks.last?.channel.midiEffects.isEmpty == true)
  }

  // MARK: - Listening

  /// A 1 kHz tone, the same in both channels.
  private func tone(amplitude: Float, seconds: Double, sampleRate: Double = 48_000) -> AgentAudio {
    let samples = (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * Double.pi * 1000 * Double($0) / sampleRate)) }
    return AgentAudio(left: samples, right: samples, sampleRate: sampleRate)
  }

  @Test func loudnessIsMeasuredAsBS1770Does() {
    // A 1 kHz sine at −20 dBFS in both channels reads −20 LUFS.
    let audio = tone(amplitude: 0.1, seconds: 12)
    let summary = MixMeasurement.summary(of: MixMeasurement.blocks(left: audio.left, right: audio.right, sampleRate: audio.sampleRate))
    #expect(abs((summary.loudness ?? 0) + 20) < 0.3, "\(String(describing: summary.loudness))")
    #expect(abs(summary.peak + 20) < 0.1)
    // All its energy is in the 1 kHz band, and none is in the sides.
    let balance = summary.balance.compactMap { $0 }
    #expect(summary.balance[5] == balance.max())
    #expect((summary.sideToMid ?? 0) < -60)
  }

  @Test func analyzeMixDescribesTheSongAndEachSection() async throws {
    let session = Session()
    try await call("set_tempo", ["bpm": 120], in: session)
    try await call("set_arrangement", ["sections": [["name": "Verse", "bars": 4], ["name": "Chorus", "bars": 4]]], in: session)
    let trackID = try #require(try await call("create_track", [:], in: session)["id"])
    try await call("create_region", ["track": trackID, "start": 1, "bars": 8], in: session)
    // 16 s at 120 bpm: a quiet verse, then a chorus 10 dB louder.
    let quiet = tone(amplitude: 0.03, seconds: 8), loud = tone(amplitude: 0.1, seconds: 8)
    session.renderedAudio = AgentAudio(left: quiet.left + loud.left, right: quiet.right + loud.right, sampleRate: 48_000)

    let analysis = try await call("analyze_mix", in: session)
    let sections = try #require(analysis["sections"]?.arrayValue)
    #expect(sections.compactMap { $0["name"]?.stringValue } == ["Verse", "Chorus"])
    let verse = try #require(sections[0]["loudnessLufs"]?.doubleValue), chorus = try #require(sections[1]["loudnessLufs"]?.doubleValue)
    #expect(abs(chorus - verse - 10.5) < 1)
    #expect(analysis["notes"]?.arrayValue?.contains { $0.stringValue?.contains("mono") == true } == true)
  }

  @Test func bouncesFollowTheCycle() async throws {
    let session = Session()
    let trackID = try #require(try await call("create_track", [:], in: session)["id"])
    try await call("create_region", ["track": trackID, "start": 1, "bars": 8], in: session)
    try await call("set_cycle", ["start": 3, "end": 5], in: session)
    let result = try await call("bounce", ["format": "m4a"], in: session)
    #expect(result["path"] == "/tmp/Song.m4a")
    #expect(result["warning"] != nil)
    #expect(session.bouncedRange == bar * 2..<bar * 4)
    // An explicit range wins over the cycle.
    try await call("bounce", ["from": 1, "to": 2], in: session)
    #expect(session.bouncedRange == .zero..<bar)
  }
}
