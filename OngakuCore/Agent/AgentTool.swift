//
//  AgentTool.swift
//  OngakuCore
//

import Foundation

/// What an agent's tools work on: one open song, with its undo, transport and saving.
///
/// The app's project window provides it; tests use a plain `ProjectEditor`. Everything the
/// tools change goes through `performEdit`, as one undoable step per tool call, so the person
/// sees each change in the window and can undo it.
@MainActor
public protocol AgentSession: AnyObject {
  var project: Project { get }
  /// The song's name, as its window shows it.
  var songName: String { get }
  /// Applies a change as one undo step called `actionName`.
  func performEdit(_ command: any EditCommand, named actionName: String) throws
  var isPlaying: Bool { get }
  var playheadPosition: Tick { get }
  func play(from position: Tick?)
  func stop()
  /// Undoes the last change, returning its name, or `nil` when there's nothing to undo.
  func undo() -> String?
  func redo() -> String?
  /// Saves the song (one that's never been saved can't be: the person chooses where).
  func save() async throws
  /// The Audio Unit instruments installed on this Mac.
  var installedAudioUnits: [AgentAudioUnit] { get }
  /// Third-party Audio Unit effects installed on this Mac (Ongaku's and Apple's are always
  /// there).
  var installedEffects: [AgentAudioUnit] { get }

  // MARK: Plug-ins

  /// Waits for a channel strip's plug-in to load (they load in the background), returning
  /// whether it did.
  func waitForPlugin(_ pluginID: PluginReference.ID, on channelID: Track.ID) async -> Bool
  /// A loaded plug-in's parameters, or `nil` while it isn't loaded.
  func parameters(ofPlugin pluginID: PluginReference.ID, on channelID: Track.ID) -> [AgentPluginParameter]?
  /// A loaded plug-in's factory presets.
  func presets(ofPlugin pluginID: PluginReference.ID, on channelID: Track.ID) -> [String]
  /// Chooses a preset and then sets parameters (by address, in their own units), as one
  /// undo step called `actionName`.
  func setPlugin(
    _ pluginID: PluginReference.ID, on channelID: Track.ID, preset: String?, values: [UInt64: Double], named actionName: String
  ) async throws

  // MARK: Rendering

  /// Renders the mix of `range` as it plays (plug-ins and automation included), for analysis.
  func renderMix(_ range: Range<Tick>) async throws -> AgentAudio
  /// Bounces the mix of `range` to a file in the person's Music folder.
  func bounce(_ range: Range<Tick>, settings: BounceSettings) async throws -> AgentBounce
  /// Analyze Whole Song with Ongaku Mastering on Stereo Out (added if it isn't there), as one
  /// undo step; `nil` if there was too little music to go on.
  func masterSong() async throws -> MasteringAnalysis.Result?

  // MARK: Sound libraries

  /// The sound libraries the person added in Settings (none by default).
  var soundLibraries: [AgentSoundLibrary] { get }
  /// Adds a loop or sample from a library at `position`, as dragging it from the Loop
  /// Browser does, on `trackID` or a new track.
  func addLibrarySound(_ sound: AgentLibrarySound, at position: Tick, onTrack trackID: Track.ID?) async throws -> AgentLibraryPlacement
  /// Gives a Convolution Reverb a library impulse response, as one undo step.
  func setImpulseResponse(_ sound: AgentLibrarySound, forPlugin pluginID: PluginReference.ID, on channelID: Track.ID) throws
}

/// One of a plug-in's parameters, in its own units.
public struct AgentPluginParameter: Sendable, Equatable {
  public var address: UInt64
  public var name: String
  public var value: Double
  public var minimum: Double
  public var maximum: Double
  /// "dB", "Hz", "%", "ms"… or empty.
  public var unit: String
  /// The choices of a parameter that picks one of several, from the minimum up.
  public var choices: [String]?

  public init(address: UInt64, name: String, value: Double, minimum: Double, maximum: Double, unit: String, choices: [String]? = nil) {
    self.address = address
    self.name = name
    self.value = value
    self.minimum = minimum
    self.maximum = maximum
    self.unit = unit
    self.choices = choices
  }

  /// Where a value sits in the range, 0–1, as automation stores it.
  public func fraction(of value: Double) -> Double {
    maximum > minimum ? min(max((value - minimum) / (maximum - minimum), 0), 1) : 0
  }
}

/// A rendered stereo mix.
public struct AgentAudio: Sendable {
  public var left: [Float]
  public var right: [Float]
  public var sampleRate: Double

  public init(left: [Float], right: [Float], sampleRate: Double) {
    self.left = left
    self.right = right
    self.sampleRate = sampleRate
  }
}

/// A bounced file.
public struct AgentBounce: Sendable {
  public var path: String
  public var seconds: Double
  public var peakDecibels: Double
  public var isClipped: Bool

  public init(path: String, seconds: Double, peakDecibels: Double, isClipped: Bool) {
    self.path = path
    self.seconds = seconds
    self.peakDecibels = peakDecibels
    self.isClipped = isClipped
  }
}

/// An installed Audio Unit instrument, as the tools list and choose it.
public struct AgentAudioUnit: Sendable, Equatable {
  public var name: String
  public var manufacturer: String
  public var reference: PluginReference

  public init(name: String, manufacturer: String, reference: PluginReference) {
    self.name = name
    self.manufacturer = manufacturer
    self.reference = reference
  }
}

/// Something an agent can do in Ongaku: a name, a description and a JSON Schema for its
/// arguments (which MCP clients show to their model), and what it does.
public struct AgentTool: Sendable {
  public var name: String
  public var title: String
  public var description: String
  public var inputSchema: AgentValue
  /// Only reads the song (or plays it); changes nothing.
  public var isReadOnly: Bool
  /// Removes things (they can still be undone).
  public var isDestructive: Bool
  let run: @MainActor @Sendable (AgentArguments, any AgentSession) async throws -> AgentValue

  init(
    name: String, title: String, description: String, properties: [String: AgentValue] = [:], required: [String] = [],
    isReadOnly: Bool = false, isDestructive: Bool = false,
    run: @escaping @MainActor @Sendable (AgentArguments, any AgentSession) async throws -> AgentValue
  ) {
    self.name = name
    self.title = title
    self.description = description
    self.inputSchema = Schema.object(properties, required: required)
    self.isReadOnly = isReadOnly
    self.isDestructive = isDestructive
    self.run = run
  }

  /// Runs the tool. Errors are `AgentError`s or `EditError`s, with messages written for the
  /// agent to act on.
  @MainActor
  public func call(_ arguments: [String: AgentValue], in session: any AgentSession) async throws -> AgentValue {
    try await run(AgentArguments(arguments), session)
  }
}

public enum AgentError: Error, Equatable, LocalizedError {
  case unknownTool(String)
  case missingArgument(String)
  case invalidArgument(String, String)
  case notFound(String)
  case notPossible(String)

  public var errorDescription: String? {
    switch self {
    case .unknownTool(let name): "There's no tool called \(name)."
    case .missingArgument(let name): "“\(name)” is required."
    case .invalidArgument(let name, let message): "“\(name)”: \(message)"
    case .notFound(let message), .notPossible(let message): message
    }
  }
}

/// JSON Schema for tool arguments.
enum Schema {
  static func object(_ properties: [String: AgentValue], required: [String] = []) -> AgentValue {
    var schema: [String: AgentValue] = ["type": "object", "properties": .object(properties)]
    if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
    return .object(schema)
  }

  static func string(_ description: String) -> AgentValue {
    ["type": "string", "description": .string(description)]
  }

  static func integer(_ description: String) -> AgentValue {
    ["type": "integer", "description": .string(description)]
  }

  static func number(_ description: String) -> AgentValue {
    ["type": "number", "description": .string(description)]
  }

  static func boolean(_ description: String) -> AgentValue {
    ["type": "boolean", "description": .string(description)]
  }

  static func choice(_ values: [String], _ description: String) -> AgentValue {
    ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)]
  }

  static func array(_ items: AgentValue, _ description: String) -> AgentValue {
    ["type": "array", "items": items, "description": .string(description)]
  }

  /// A bar position: "5" or "5:3" (bar 5, beat 3), or a bar number.
  static func position(_ description: String) -> AgentValue {
    ["type": ["string", "integer"], "description": .string(description + " As \"bar:beat\" (\"5:3\" is bar 5, beat 3; \"5\" is the start of bar 5).")]
  }

  /// A track: its id, its name or its number.
  static let track: AgentValue = ["type": ["string", "integer"], "description": "The track's id, name, or number (1 is the top track)."]

  static let region: AgentValue = string("The region's id.")

  /// A pitch: a MIDI note number or a name.
  static let pitch: AgentValue = [
    "type": ["string", "integer"],
    "description": "MIDI note number (60 is middle C) or a name such as \"C4\", \"F#3\" or \"Bb2\" (C4 = 60). On drum tracks, General MIDI drum names work too: \"kick\", \"snare\", \"closed hat\", \"open hat\", \"crash\", \"ride\", \"low tom\", \"clap\"…",
  ]
}

/// The arguments of one tool call, with readers that explain what's wrong to the agent.
public struct AgentArguments {
  public var values: [String: AgentValue]

  public init(_ values: [String: AgentValue]) {
    self.values = values
  }

  func has(_ key: String) -> Bool {
    if let value = values[key], value != .null { return true }
    return false
  }

  func value(_ key: String) throws -> AgentValue {
    guard let value = values[key], value != .null else { throw AgentError.missingArgument(key) }
    return value
  }

  func string(_ key: String) throws -> String {
    let value = try value(key)
    if let string = value.stringValue { return string }
    if let number = value.intValue { return String(number) }
    throw AgentError.invalidArgument(key, "expected text.")
  }

  func optionalString(_ key: String) throws -> String? {
    has(key) ? try string(key) : nil
  }

  func int(_ key: String) throws -> Int {
    guard let number = try value(key).intValue else { throw AgentError.invalidArgument(key, "expected a whole number.") }
    return number
  }

  func optionalInt(_ key: String) throws -> Int? {
    has(key) ? try int(key) : nil
  }

  func double(_ key: String) throws -> Double {
    guard let number = try value(key).doubleValue, number.isFinite else {
      throw AgentError.invalidArgument(key, "expected a number.")
    }
    return number
  }

  func optionalDouble(_ key: String) throws -> Double? {
    has(key) ? try double(key) : nil
  }

  /// A number from 0 to 1, such as a session player's complexity.
  func optionalAmount(_ key: String) throws -> Double? {
    guard let amount = try optionalDouble(key) else { return nil }
    guard (0...1).contains(amount) else { throw AgentError.invalidArgument(key, "expected a number from 0 to 1.") }
    return amount
  }

  func bool(_ key: String) throws -> Bool {
    guard let flag = try value(key).boolValue else { throw AgentError.invalidArgument(key, "expected true or false.") }
    return flag
  }

  func optionalBool(_ key: String) throws -> Bool? {
    has(key) ? try bool(key) : nil
  }

  func array(_ key: String) throws -> [AgentValue] {
    let value = try value(key)
    if let array = value.arrayValue { return array }
    // Some clients send a JSON array as a string.
    if let text = value.stringValue, let data = text.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([AgentValue].self, from: data)
    {
      return decoded
    }
    throw AgentError.invalidArgument(key, "expected a list.")
  }

  func optionalArray(_ key: String) throws -> [AgentValue]? {
    has(key) ? try array(key) : nil
  }

  func choice<T: RawRepresentable>(_ key: String, _ type: T.Type) throws -> T where T.RawValue == String, T: CaseIterable {
    let text = try string(key)
    let wanted = AgentNames.simplified(text)
    guard let match = T.allCases.first(where: { AgentNames.simplified($0.rawValue) == wanted }) else {
      throw AgentError.invalidArgument(key, "use one of \(T.allCases.map(\.rawValue).joined(separator: ", ")).")
    }
    return match
  }

  func optionalChoice<T: RawRepresentable>(_ key: String, _ type: T.Type) throws -> T? where T.RawValue == String, T: CaseIterable {
    has(key) ? try choice(key, type) : nil
  }

  // MARK: - Song things

  func position(_ key: String, in project: Project) throws -> Tick {
    try AgentNotation.position(try value(key), key: key, tempoMap: project.tempoMap)
  }

  func optionalPosition(_ key: String, in project: Project) throws -> Tick? {
    has(key) ? try position(key, in: project) : nil
  }

  func track(_ key: String, in project: Project) throws -> Track {
    try AgentNames.track(try value(key), in: project)
  }

  func optionalTrack(_ key: String, in project: Project) throws -> Track? {
    has(key) ? try track(key, in: project) : nil
  }

  func region(_ key: String, in project: Project) throws -> Region {
    try AgentNames.region(try string(key), in: project)
  }

  /// Several regions, from a list of ids (or one id).
  func regions(_ key: String, in project: Project) throws -> [Region] {
    let value = try value(key)
    let ids = try value.arrayValue?.compactMap(\.stringValue) ?? [string(key)]
    guard !ids.isEmpty else { throw AgentError.invalidArgument(key, "list at least one region.") }
    return try ids.map { try AgentNames.region($0, in: project) }
  }
}

/// How the tools name things for agents: short ids, and finding tracks and regions from
/// what an agent calls them.
enum AgentNames {
  /// The first eight characters of an identifier, enough to tell a song's things apart and
  /// far cheaper for an agent to read and repeat than a whole UUID.
  static func shortID(_ id: UUID) -> String {
    String(id.uuidString.lowercased().prefix(8))
  }

  static func shortID(_ id: UUID) -> AgentValue {
    .string(shortID(id))
  }

  /// Lowercased without spaces, hyphens or underscores, so "hip-hop", "Hip Hop" and
  /// "hipHop" all match.
  static func simplified(_ text: String) -> String {
    text.lowercased().filter { !" -_".contains($0) }
  }

  /// The one identifier among `ids` that `text` names (in full or by its start).
  static func match(_ text: String, among ids: [UUID]) -> [UUID] {
    let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
    guard wanted.count >= 4 else { return [] }
    return ids.filter { $0.uuidString.lowercased().hasPrefix(wanted) }
  }

  static func track(_ value: AgentValue, in project: Project) throws -> Track {
    if case .int(let number) = value {
      return try track(number: number, in: project)
    }
    guard let text = value.stringValue ?? value.intValue.map(String.init) else {
      throw AgentError.invalidArgument("track", "give the track's id, name or number.")
    }
    let ids = match(text, among: project.tracks.map(\.id))
    if ids.count == 1, let track = project.track(withID: ids[0]) { return track }
    let named = project.tracks.filter { $0.name.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    if named.count == 1 { return named[0] }
    if named.count > 1 {
      throw AgentError.notFound("More than one track is called “\(text)”; use its id.")
    }
    if let number = Int(text) { return try track(number: number, in: project) }
    throw AgentError.notFound("There's no track “\(text)”. Call get_song to see the tracks.")
  }

  private static func track(number: Int, in project: Project) throws -> Track {
    guard project.tracks.indices.contains(number - 1) else {
      throw AgentError.notFound("There's no track \(number); the song has \(project.tracks.count).")
    }
    return project.tracks[number - 1]
  }

  static func region(_ text: String, in project: Project) throws -> Region {
    let regions = project.tracks.flatMap(\.regions)
    let ids = match(text, among: regions.map(\.id))
    guard ids.count == 1, let region = project.region(withID: ids[0]) else {
      throw AgentError.notFound(
        ids.isEmpty
          ? "There's no region “\(text)”. Call get_track to see a track's regions."
          : "“\(text)” matches more than one region; use more of its id.")
    }
    return region
  }

  static func track(containing regionID: Region.ID, in project: Project) -> Track? {
    project.regionLocation(for: regionID).map { project.tracks[$0.track] }
  }
}
