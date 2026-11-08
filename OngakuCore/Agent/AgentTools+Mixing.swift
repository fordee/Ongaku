//
//  AgentTools+Mixing.swift
//  OngakuCore
//

import Foundation

/// Tools that mix: plug-in effects on channel strips (and Stereo Out), sends to auxes,
/// automation, the Stereo Out fader, and MIDI effects.
extension AgentToolbox {
  static let mixingTools: [AgentTool] = [
    listEffects, addEffect, getEffect, setEffect, removeEffect, setSend, addAutomation, clearAutomation, setMasterVolume,
    addMIDIEffect, removeMIDIEffect,
  ]

  private static let channelSchema: AgentValue = [
    "type": ["string", "integer"],
    "description": "A track's id, name or number, or \"Stereo Out\" for the whole mix.",
  ]
  private static let effectSchema = Schema.string("An effect on the channel strip: its id, its name, or its slot number (1 is the top).")

  static let listEffects = AgentTool(
    name: "list_effects", title: "List Effects",
    description: """
      The effects a channel strip can use: Ongaku's own (the best choice: Channel EQ, \
      Compressor, Reverb, Delay, Mastering…), Apple's built-in effects, the Audio Unit \
      effects installed on this Mac, and the MIDI effects an instrument track can play \
      through, with their settings.
      """,
    isReadOnly: true
  ) { _, session in
    [
      "ongaku": .array(OngakuEffect.allCases.map { .string("\($0.name) (\($0.category.rawValue))") }),
      "apple": .array(BuiltInEffect.allCases.map { .string("Apple \($0.name) (\($0.audioUnitName))") }),
      "audioUnits": .array(session.installedEffects.map { .string("\($0.manufacturer): \($0.name)") }),
      "midiEffects": .object(Dictionary(uniqueKeysWithValues: MIDIEffect.Settings.all.map { settings in
        (settings.name, AgentMIDIEffects.describe(settings))
      })),
      "note": "Effects go in signal-flow order, at most 8 per channel strip. For shared reverb or delay, make an aux track (create_track kind aux), put the effect there, and set_send to it from each track.",
    ]
  }

  static let addEffect = AgentTool(
    name: "add_effect", title: "Add Effect",
    description: """
      Puts an effect on a channel strip (a track, or Stereo Out), after the ones already \
      there unless a slot is given, and returns its parameters and presets once it has \
      loaded. Optionally chooses a preset and sets parameters straight away (as set_effect does).
      """,
    properties: [
      "track": channelSchema,
      "effect": Schema.string("From list_effects: \"Compressor\", \"Reverb\", \"Apple Delay\", \"Valhalla: VintageVerb\"…"),
      "slot": Schema.integer("Where it goes, 1 being the top; last if left out."),
      "preset": Schema.string("A factory preset's name."),
      "parameters": ["type": "object", "description": "Parameter names and values in their own units, such as {\"Mix\": 25, \"Decay\": 2.5}."],
    ],
    required: ["track", "effect"]
  ) { arguments, session in
    let project = session.project
    let channel = try AgentMixing.channel(try arguments.value("track"), in: project)
    let plugin = try AgentMixing.resolveEffect(try arguments.string("effect"), installed: session.installedEffects)
    let slot = try arguments.optionalInt("slot").map { $0 - 1 }
    try session.performEdit(AddInsert(plugin, to: channel.id, at: slot), named: "Add \(plugin.name)")
    guard await session.waitForPlugin(plugin.id, on: channel.id) else {
      return ["added": .string(plugin.name), "id": AgentNames.shortID(plugin.id), "note": "It's still loading; call get_effect in a moment."]
    }
    if arguments.has("preset") || arguments.has("parameters") {
      try await AgentMixing.apply(arguments, to: plugin, on: channel.id, session: session)
    }
    return AgentMixing.describe(plugin, on: channel, session: session)
  }

  static let getEffect = AgentTool(
    name: "get_effect", title: "Get Effect",
    description: "An effect's parameters (with their values, ranges and units, or their choices) and its factory presets.",
    properties: ["track": channelSchema, "effect": effectSchema],
    required: ["track", "effect"], isReadOnly: true
  ) { arguments, session in
    let channel = try AgentMixing.channel(try arguments.value("track"), in: session.project)
    let plugin = try AgentMixing.insert(try arguments.string("effect"), on: channel)
    _ = await session.waitForPlugin(plugin.id, on: channel.id)
    return AgentMixing.describe(plugin, on: channel, session: session)
  }

  static let setEffect = AgentTool(
    name: "set_effect", title: "Set Effect",
    description: """
      Changes an effect: chooses a factory preset, sets parameters by name in their own units \
      (dB, Hz, ms, % — or a choice's name), and bypasses or enables it. get_effect lists the \
      parameters.
      """,
    properties: [
      "track": channelSchema, "effect": effectSchema,
      "preset": Schema.string("A factory preset's name (applied before the parameters)."),
      "parameters": ["type": "object", "description": "Parameter names and values, such as {\"Threshold\": -18, \"Ratio\": 3}."],
      "bypass": Schema.boolean("Bypasses (true) or enables (false) the effect."),
      "impulse_response": Schema.string("For the Convolution Reverb: a \"sound\" from find_impulse_responses, the room it plays."),
    ],
    required: ["track", "effect"]
  ) { arguments, session in
    let channel = try AgentMixing.channel(try arguments.value("track"), in: session.project)
    let plugin = try AgentMixing.insert(try arguments.string("effect"), on: channel)
    if let text = try arguments.optionalString("impulse_response") {
      guard OngakuEffect(plugin) == .convolutionReverb else {
        throw AgentError.invalidArgument("impulse_response", "only Ongaku's Convolution Reverb takes an impulse response.")
      }
      let libraries = try AgentLibrary.libraries(nil, in: session)
      guard let sound = AgentLibrary.sound(text, kinds: [.impulseResponse], in: libraries) else {
        throw AgentError.notFound("There's no impulse response “\(text)”; use a \"sound\" from find_impulse_responses.")
      }
      try session.setImpulseResponse(sound, forPlugin: plugin.id, on: channel.id)
    }
    if let bypass = try arguments.optionalBool("bypass") {
      try session.performEdit(SetInsertBypassed(plugin.id, in: channel.id, isBypassed: bypass), named: bypass ? "Bypass \(plugin.name)" : "Enable \(plugin.name)")
    }
    if arguments.has("preset") || arguments.has("parameters") {
      guard await session.waitForPlugin(plugin.id, on: channel.id) else {
        throw AgentError.notPossible("\(plugin.name) hasn't loaded, so its settings can't be changed yet.")
      }
      try await AgentMixing.apply(arguments, to: plugin, on: channel.id, session: session)
    } else if !arguments.has("bypass"), !arguments.has("impulse_response") {
      throw AgentError.notPossible("Nothing to change: give a preset, parameters, bypass or an impulse_response.")
    }
    return AgentMixing.describe(plugin, on: AgentMixing.refreshed(channel, in: session.project), session: session)
  }

  static let removeEffect = AgentTool(
    name: "remove_effect", title: "Remove Effect",
    description: "Takes an effect off a channel strip.",
    properties: ["track": channelSchema, "effect": effectSchema],
    required: ["track", "effect"], isDestructive: true
  ) { arguments, session in
    let channel = try AgentMixing.channel(try arguments.value("track"), in: session.project)
    let plugin = try AgentMixing.insert(try arguments.string("effect"), on: channel)
    try session.performEdit(RemoveInsert(plugin.id, from: channel.id), named: "Remove \(plugin.name)")
    return ["removed": .string(plugin.name), "from": .string(channel.name)]
  }

  static let setSend = AgentTool(
    name: "set_send", title: "Set Send",
    description: """
      Sends a track to an aux track (for shared reverb or delay), changes the send's level, \
      or removes it. Make the aux with create_track kind aux, and put the effect on it.
      """,
    properties: [
      "track": Schema.track,
      "aux": Schema.string("The aux track's id, name or number."),
      "levelDb": Schema.number("The send level in dB, from -96 to +6; -6 for a new send if left out."),
      "preFader": Schema.boolean("Takes the send before the fader."),
      "remove": Schema.boolean("Removes the send."),
    ],
    required: ["track", "aux"]
  ) { arguments, session in
    let project = session.project
    let track = try arguments.track("track", in: project)
    let aux = try AgentNames.track(try arguments.value("aux"), in: project)
    guard aux.kind == .aux else { throw AgentError.invalidArgument("aux", "“\(aux.name)” isn't an aux track; make one with create_track kind aux.") }
    let existing = track.channel.sends.first { $0.destinationTrackID == aux.id }
    if try arguments.optionalBool("remove") == true {
      guard let existing else { throw AgentError.notFound("“\(track.name)” doesn't send to “\(aux.name)”.") }
      try session.performEdit(RemoveSend(existing.id, from: track.id), named: "Remove Send")
      return ["removed": .string("\(track.name) → \(aux.name)")]
    }
    let level = try arguments.optionalDouble("levelDb")
    if let level, !Send.levelRange.contains(level) { throw AgentError.invalidArgument("levelDb", "sends run from -96 to +6 dB.") }
    var send = existing ?? Send(destinationTrackID: aux.id)
    if let level { send.level = level }
    if let preFader = try arguments.optionalBool("preFader") { send.isPreFader = preFader }
    try session.performEdit(existing == nil ? AddSend(send, from: track.id) : UpdateSend(send, on: track.id), named: "Set Send")
    return ["send": .string("\(track.name) → \(aux.name)"), "levelDb": .number(send.level), "preFader": .bool(send.isPreFader)]
  }

  static let addAutomation = AgentTool(
    name: "add_automation", title: "Add Automation",
    description: """
      Draws automation on a track: points that a parameter moves between as the song plays, \
      such as a fade-out, a filter sweep or a louder chorus. The points replace any automation \
      of that parameter between the first and last of them. Values are in the parameter's \
      own units: dB for volume and sends, -1…1 for pan, and an effect parameter's own units.
      """,
    properties: [
      "track": Schema.track,
      "parameter": Schema.string("\"volume\", \"pan\", \"send:<aux name>\", or \"<effect>:<parameter>\" such as \"Channel EQ:Low Cut Frequency\"."),
      "points": Schema.array(
        Schema.object(["at": Schema.position("Where."), "value": Schema.number("The value there.")], required: ["at", "value"]),
        "The points, in any order; values ramp between them."),
    ],
    required: ["track", "parameter", "points"]
  ) { arguments, session in
    let project = session.project
    let track = try arguments.track("track", in: project)
    let target = try await AgentMixing.automationTarget(try arguments.string("parameter"), on: track, session: session)
    var points: [AutomationPoint] = []
    for (index, item) in try arguments.array("points").enumerated() {
      let point = AgentArguments(item.objectValue ?? [:])
      guard point.has("at"), point.has("value") else { throw AgentError.invalidArgument("points", "point \(index + 1) needs \"at\" and \"value\".") }
      let value = try target.toStored(try point.double("value"))
      points.append(AutomationPoint(position: try point.position("at", in: project), value: value))
    }
    guard let first = points.map(\.position).min(), let last = points.map(\.position).max() else {
      throw AgentError.invalidArgument("points", "give at least one point.")
    }
    try session.performEdit(WriteAutomation(points, over: first...last, to: target.parameter, on: track.id), named: "\(target.name) Automation")
    let lane = session.project.track(withID: track.id)?.automationLane(for: target.parameter)
    return [
      "track": .string(track.name), "parameter": .string(target.name),
      "points": .array((lane?.points ?? []).map {
        .string("\(AgentNotation.format($0.position, tempoMap: project.tempoMap)) \(AgentNotation.formatNumber(target.fromStored($0.value)))")
      }),
      "mode": .string(session.project.track(withID: track.id)?.automationMode.rawValue ?? "read"),
    ]
  }

  static let clearAutomation = AgentTool(
    name: "clear_automation", title: "Clear Automation",
    description: "Removes a parameter's automation from a track, or all of the track's automation.",
    properties: [
      "track": Schema.track,
      "parameter": Schema.string("As add_automation names them; all of the track's automation if left out."),
    ],
    required: ["track"], isDestructive: true
  ) { arguments, session in
    let track = try arguments.track("track", in: session.project)
    let parameters: [AutomationParameter]
    if let name = try arguments.optionalString("parameter") {
      parameters = [try await AgentMixing.automationTarget(name, on: track, session: session).parameter]
    } else {
      parameters = track.automation.map(\.parameter)
    }
    guard !parameters.isEmpty else { throw AgentError.notFound("“\(track.name)” has no automation.") }
    try session.performEdit(CompositeCommand("Clear Automation", commands: parameters.map { ClearAutomation($0, on: track.id) }), named: "Clear Automation")
    return ["cleared": .array(parameters.map { .string($0.name) })]
  }

  static let setMasterVolume = AgentTool(
    name: "set_master_volume", title: "Set Master Volume",
    description: "Sets the Stereo Out fader, the level of the whole mix, in dB (0 is unity).",
    properties: ["volumeDb": Schema.number("From -96 to +6 dB.")],
    required: ["volumeDb"]
  ) { arguments, session in
    let volume = try arguments.double("volumeDb")
    guard ChannelStrip.volumeRange.contains(volume) else { throw AgentError.invalidArgument("volumeDb", "the fader runs from -96 to +6 dB.") }
    try session.performEdit(SetMasterVolume(volume), named: "Master Volume")
    return ["masterVolumeDb": .number(volume)]
  }

  static let addMIDIEffect = AgentTool(
    name: "add_midi_effect", title: "Add MIDI Effect",
    description: """
      Puts a MIDI effect before an instrument track's instrument: an Arpeggiator, Chord \
      Trigger (one key plays a chord), Note Repeater, Randomizer, Scale Quantize, Transposer \
      or Velocity Processor. list_effects shows each one's settings and defaults.
      """,
    properties: [
      "track": Schema.track,
      "effect": Schema.string("Its name, such as \"Arpeggiator\"."),
      "settings": ["type": "object", "description": "Settings to change from the defaults, such as {\"rate\": \"eighth\", \"order\": \"upDown\", \"octaves\": 2}."],
    ],
    required: ["track", "effect"]
  ) { arguments, session in
    let track = try arguments.track("track", in: session.project)
    guard track.kind == .softwareInstrument else { throw AgentError.notPossible("MIDI effects go on instrument tracks.") }
    let settings = try AgentMIDIEffects.settings(try arguments.string("effect"), overrides: arguments.values["settings"]?.objectValue ?? [:])
    let effect = MIDIEffect(settings)
    try session.performEdit(AddMIDIEffect(effect, to: track.id), named: "Add \(effect.name)")
    return ["added": .string(effect.name), "id": AgentNames.shortID(effect.id), "settings": AgentMIDIEffects.describe(settings)]
  }

  static let removeMIDIEffect = AgentTool(
    name: "remove_midi_effect", title: "Remove MIDI Effect",
    description: "Takes a MIDI effect off an instrument track.",
    properties: ["track": Schema.track, "effect": Schema.string("The MIDI effect's id, name or slot number.")],
    required: ["track", "effect"], isDestructive: true
  ) { arguments, session in
    let track = try arguments.track("track", in: session.project)
    let text = try arguments.string("effect")
    let effects = track.channel.midiEffects
    let match = AgentNames.match(text, among: effects.map(\.id)).first.flatMap { id in effects.first { $0.id == id } }
      ?? Int(text).flatMap { effects.indices.contains($0 - 1) ? effects[$0 - 1] : nil }
      ?? effects.first { AgentNames.simplified($0.name) == AgentNames.simplified(text) }
    guard let match else { throw AgentError.notFound("“\(track.name)” has no MIDI effect “\(text)”.") }
    try session.performEdit(RemoveMIDIEffect(match.id, from: track.id), named: "Remove \(match.name)")
    return ["removed": .string(match.name)]
  }
}

/// Finding channel strips, effects and automation targets for the mixing tools.
enum AgentMixing {
  /// A channel strip: a track's or Stereo Out's.
  struct Channel {
    var id: Track.ID
    var name: String
    var inserts: [PluginReference]
  }

  static func channel(_ value: AgentValue, in project: Project) throws -> Channel {
    if let text = value.stringValue, ["stereoout", "master", "mix", "output", "stereoouts"].contains(AgentNames.simplified(text)) {
      return Channel(id: Project.stereoOutID, name: "Stereo Out", inserts: project.stereoOutInserts)
    }
    let track = try AgentNames.track(value, in: project)
    return Channel(id: track.id, name: track.name, inserts: track.channel.inserts)
  }

  static func refreshed(_ channel: Channel, in project: Project) -> Channel {
    var updated = channel
    updated.inserts = (try? project.inserts(of: channel.id)) ?? channel.inserts
    return updated
  }

  /// An effect to add, by name: Ongaku's own first, then Apple's ("Apple Reverb" or
  /// "AUReverb2"), then installed ones ("Manufacturer: Name" or the name).
  static func resolveEffect(_ text: String, installed: [AgentAudioUnit]) throws -> PluginReference {
    let wanted = AgentNames.simplified(text)
    if let effect = OngakuEffect.allCases.first(where: { AgentNames.simplified($0.name) == wanted || AgentNames.simplified("Ongaku \($0.name)") == wanted }) {
      return effect.makeReference()
    }
    if let effect = BuiltInEffect.allCases.first(where: {
      AgentNames.simplified("Apple \($0.name)") == wanted || AgentNames.simplified($0.audioUnitName) == wanted || AgentNames.simplified($0.name) == wanted
    }) {
      return effect.makeReference()
    }
    if let unit = installed.first(where: {
      AgentNames.simplified($0.name) == wanted || AgentNames.simplified("\($0.manufacturer):\($0.name)") == wanted
    }) {
      var reference = unit.reference
      reference.id = UUID()
      return reference
    }
    throw AgentError.invalidArgument("effect", "there's no effect “\(text)”; list_effects lists them.")
  }

  /// An effect already on a channel strip.
  static func insert(_ text: String, on channel: Channel) throws -> PluginReference {
    let ids = AgentNames.match(text, among: channel.inserts.map(\.id))
    if ids.count == 1, let plugin = channel.inserts.first(where: { $0.id == ids[0] }) { return plugin }
    let named = channel.inserts.filter { names(of: $0).contains(AgentNames.simplified(text)) }
    if named.count == 1 { return named[0] }
    if let slot = Int(text), channel.inserts.indices.contains(slot - 1) { return channel.inserts[slot - 1] }
    if named.count > 1 { throw AgentError.notFound("“\(channel.name)” has more than one \(text); use its id or slot.") }
    let list = channel.inserts.isEmpty ? "none" : channel.inserts.map(\.name).joined(separator: ", ")
    throw AgentError.notFound("“\(channel.name)” has no effect “\(text)” (it has \(list)).")
  }

  /// What an effect on a strip answers to: its name, and the names it can be added by
  /// ("Apple Delay" or "AUDelay" for Apple's, "Ongaku Delay" for Ongaku's).
  static func names(of plugin: PluginReference) -> Set<String> {
    var names = [plugin.name]
    if BuiltInEffect.isBuiltIn(plugin), let effect = BuiltInEffect.allCases.first(where: { $0.makeReference().componentSubType == plugin.componentSubType }) {
      names += ["Apple \(effect.name)", effect.audioUnitName]
    }
    if OngakuEffect(plugin) != nil { names.append("Ongaku \(plugin.name)") }
    return Set(names.map(AgentNames.simplified))
  }

  /// An effect's parameters and presets, for the agent.
  @MainActor
  static func describe(_ plugin: PluginReference, on channel: Channel, session: any AgentSession) -> AgentValue {
    var info: [String: AgentValue] = [
      "id": AgentNames.shortID(plugin.id), "name": .string(plugin.name), "track": .string(channel.name),
    ]
    let current = refreshed(channel, in: session.project).inserts.first { $0.id == plugin.id }
    if current?.isBypassed == true { info["bypassed"] = true }
    if let slot = refreshed(channel, in: session.project).inserts.firstIndex(where: { $0.id == plugin.id }) { info["slot"] = .int(slot + 1) }
    guard let parameters = session.parameters(ofPlugin: plugin.id, on: channel.id) else {
      info["note"] = "It's still loading; call get_effect again in a moment."
      return .object(info)
    }
    info["parameters"] = .array(parameters.map { parameter in
      if let choices = parameter.choices, !choices.isEmpty {
        let index = Int(parameter.value - parameter.minimum)
        let current = choices.indices.contains(index) ? choices[index] : AgentNotation.formatNumber(parameter.value)
        return .string("\(parameter.name): \(current) (choices: \(choices.joined(separator: ", ")))")
      }
      let unit = parameter.unit.isEmpty ? "" : " \(parameter.unit)"
      return .string("\(parameter.name): \(AgentNotation.formatNumber(parameter.value))\(unit) (\(AgentNotation.formatNumber(parameter.minimum))…\(AgentNotation.formatNumber(parameter.maximum)))")
    })
    let presets = session.presets(ofPlugin: plugin.id, on: channel.id)
    if !presets.isEmpty { info["presets"] = .array(presets.map { .string($0) }) }
    return .object(info)
  }

  /// set_effect's and add_effect's preset and parameters.
  @MainActor
  static func apply(_ arguments: AgentArguments, to plugin: PluginReference, on channelID: Track.ID, session: any AgentSession) async throws {
    guard let parameters = session.parameters(ofPlugin: plugin.id, on: channelID) else {
      throw AgentError.notPossible("\(plugin.name) hasn't loaded yet; try again in a moment.")
    }
    let preset = try arguments.optionalString("preset")
    if let preset {
      let presets = session.presets(ofPlugin: plugin.id, on: channelID)
      guard presets.contains(where: { AgentNames.simplified($0) == AgentNames.simplified(preset) }) else {
        throw AgentError.invalidArgument("preset", presets.isEmpty ? "\(plugin.name) has no factory presets." : "\(plugin.name)'s presets are \(presets.joined(separator: ", ")).")
      }
    }
    var values: [UInt64: Double] = [:]
    for (name, value) in arguments.values["parameters"]?.objectValue ?? [:] {
      guard let parameter = parameters.first(where: { AgentNames.simplified($0.name) == AgentNames.simplified(name) }) else {
        throw AgentError.invalidArgument("parameters", "\(plugin.name) has no parameter “\(name)”; get_effect lists them.")
      }
      values[parameter.address] = try parameterValue(value, for: parameter)
    }
    try await session.setPlugin(plugin.id, on: channelID, preset: preset, values: values, named: "\(plugin.name) Settings")
  }

  /// A value in a parameter's own units, or a choice's name, checked against its range.
  static func parameterValue(_ value: AgentValue, for parameter: AgentPluginParameter) throws -> Double {
    if let choices = parameter.choices, let text = value.stringValue, Double(text) == nil {
      guard let index = choices.firstIndex(where: { AgentNames.simplified($0) == AgentNames.simplified(text) }) else {
        throw AgentError.invalidArgument("parameters", "\(parameter.name) can be \(choices.joined(separator: ", ")).")
      }
      return parameter.minimum + Double(index)
    }
    if let flag = value.boolValue, value.doubleValue == nil { return flag ? parameter.maximum : parameter.minimum }
    guard let number = value.doubleValue else { throw AgentError.invalidArgument("parameters", "\(parameter.name) needs a number.") }
    guard number >= parameter.minimum - 1e-6, number <= parameter.maximum + 1e-6 else {
      throw AgentError.invalidArgument(
        "parameters", "\(parameter.name) runs from \(AgentNotation.formatNumber(parameter.minimum)) to \(AgentNotation.formatNumber(parameter.maximum))\(parameter.unit.isEmpty ? "" : " \(parameter.unit)").")
    }
    return number
  }

  /// A parameter to automate, and how its values convert to what's stored.
  struct AutomationTarget {
    var parameter: AutomationParameter
    var name: String
    var toStored: (Double) throws -> Double
    var fromStored: (Double) -> Double
  }

  @MainActor
  static func automationTarget(_ text: String, on track: Track, session: any AgentSession) async throws -> AutomationTarget {
    func ranged(_ parameter: AutomationParameter, _ name: String) -> AutomationTarget {
      AutomationTarget(parameter: parameter, name: name, toStored: { value in
        guard parameter.range.contains(value) else {
          throw AgentError.invalidArgument("points", "\(name) runs from \(AgentNotation.formatNumber(parameter.range.lowerBound)) to \(AgentNotation.formatNumber(parameter.range.upperBound)).")
        }
        return value
      }, fromStored: { $0 })
    }
    switch AgentNames.simplified(text) {
    case "volume", "fader", "level": return ranged(.volume, "Volume")
    case "pan": return ranged(.pan, "Pan")
    default: break
    }
    guard let colon = text.firstIndex(of: ":") else {
      throw AgentError.invalidArgument("parameter", "use \"volume\", \"pan\", \"send:<aux>\" or \"<effect>:<parameter>\".")
    }
    let owner = text[..<colon].trimmingCharacters(in: .whitespaces)
    let name = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    if AgentNames.simplified(owner) == "send" {
      let aux = try AgentNames.track(.string(name), in: session.project)
      guard let send = track.channel.sends.first(where: { $0.destinationTrackID == aux.id }) else {
        throw AgentError.notFound("“\(track.name)” doesn't send to “\(aux.name)”; add the send with set_send first.")
      }
      return ranged(.sendLevel(send.id), "Send to \(aux.name)")
    }
    let channel = Channel(id: track.id, name: track.name, inserts: track.channel.inserts)
    let plugin = try insert(owner, on: channel)
    guard await session.waitForPlugin(plugin.id, on: track.id), let parameters = session.parameters(ofPlugin: plugin.id, on: track.id) else {
      throw AgentError.notPossible("\(plugin.name) hasn't loaded yet; try again in a moment.")
    }
    guard let parameter = parameters.first(where: { AgentNames.simplified($0.name) == AgentNames.simplified(name) }) else {
      throw AgentError.invalidArgument("parameter", "\(plugin.name) has no parameter “\(name)”; get_effect lists them.")
    }
    // An existing lane keeps its own identity (the same plug-in and address).
    let pluginParameter = PluginParameter(
      pluginID: plugin.id, address: parameter.address, name: "\(plugin.name) \(parameter.name)", initialValue: parameter.fraction(of: parameter.value))
    return AutomationTarget(
      parameter: .plugin(pluginParameter), name: pluginParameter.name,
      toStored: { value in parameter.fraction(of: try parameterValue(.double(value), for: parameter)) },
      fromStored: { parameter.minimum + $0 * (parameter.maximum - parameter.minimum) })
  }
}

/// MIDI effects' settings, read and written as JSON with their own field names.
enum AgentMIDIEffects {
  static func describe(_ settings: MIDIEffect.Settings) -> AgentValue {
    func encode<T: Encodable>(_ value: T) -> AgentValue {
      guard let data = try? JSONEncoder().encode(value), let decoded = try? JSONDecoder().decode(AgentValue.self, from: data) else { return .null }
      return decoded
    }
    var fields: AgentValue
    switch settings {
    case .arpeggiator(let value): fields = encode(value)
    case .chordTrigger(let value): fields = encode(value)
    case .scaleQuantize(let value): fields = encode(value)
    case .noteRepeater(let value): fields = encode(value)
    case .transposer(let value): fields = encode(value)
    case .velocityProcessor(let value): fields = encode(value)
    case .randomizer(let value): fields = encode(value)
    }
    if case .object(var object) = fields {
      switch settings {
      case .arpeggiator:
        object["rate (choices)"] = .string(NoteDivision.allCases.map(\.rawValue).joined(separator: ", "))
        object["order (choices)"] = .string(Arpeggiator.Order.allCases.map(\.rawValue).joined(separator: ", "))
      case .noteRepeater:
        object["rate (choices)"] = .string(NoteDivision.allCases.map(\.rawValue).joined(separator: ", "))
      case .chordTrigger:
        object["chord (choices)"] = .string(ChordTrigger.Chord.allCases.map(\.rawValue).joined(separator: ", "))
      case .scaleQuantize:
        object["scale (choices)"] = .string(ScaleQuantize.Scale.allCases.map(\.rawValue).joined(separator: ", "))
        object["root (note)"] = "0 is C, 1 C#… 11 B"
      default: break
      }
      fields = .object(object)
    }
    return fields
  }

  /// An effect's defaults with some settings changed.
  static func settings(_ name: String, overrides: [String: AgentValue]) throws -> MIDIEffect.Settings {
    guard let defaults = MIDIEffect.Settings.all.first(where: { AgentNames.simplified($0.name) == AgentNames.simplified(name) }) else {
      throw AgentError.invalidArgument("effect", "the MIDI effects are \(MIDIEffect.Settings.all.map(\.name).joined(separator: ", ")).")
    }
    func merged<T: Codable>(_ value: T) throws -> T {
      guard case .object(var fields) = (try? JSONDecoder().decode(AgentValue.self, from: JSONEncoder().encode(value))) ?? .null else { return value }
      for (key, newValue) in overrides {
        guard let field = fields.keys.first(where: { AgentNames.simplified($0) == AgentNames.simplified(key) }) ?? optionalField(key, of: name) else {
          throw AgentError.invalidArgument("settings", "\(defaults.name) has no setting “\(key)”; it has \(fields.keys.sorted().joined(separator: ", ")).")
        }
        fields[field] = newValue
      }
      do {
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(AgentValue.object(fields)))
      } catch {
        throw AgentError.invalidArgument("settings", "those settings don't fit \(defaults.name); list_effects shows its settings and choices.")
      }
    }
    switch defaults {
    case .arpeggiator(let value): return .arpeggiator(try merged(value))
    case .chordTrigger(let value): return .chordTrigger(try merged(value))
    case .scaleQuantize(let value): return .scaleQuantize(try merged(value))
    case .noteRepeater(let value): return .noteRepeater(try merged(value))
    case .transposer(let value): return .transposer(try merged(value))
    case .velocityProcessor(let value): return .velocityProcessor(try merged(value))
    case .randomizer(let value): return .randomizer(try merged(value))
    }
  }

  /// Settings that are left out of the defaults' JSON because they're unset (nil).
  private static func optionalField(_ key: String, of effect: String) -> String? {
    let optional: [String: [String]] = ["arpeggiator": ["fixedVelocity"], "velocityprocessor": ["fixed"]]
    return optional[AgentNames.simplified(effect)]?.first { AgentNames.simplified($0) == AgentNames.simplified(key) }
  }
}
