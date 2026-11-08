//
//  AgentTools+Library.swift
//  OngakuCore
//

import Foundation

/// A sound library the person added in Settings, as agents see it: its name and index, never
/// its files.
public struct AgentSoundLibrary: Sendable {
  public var id: UUID
  public var name: String
  public var items: [SoundLibraryItem]
  /// Each item's `searchText`, folded once.
  public var searchTexts: [String]

  public init(id: UUID, name: String, items: [SoundLibraryItem], searchTexts: [String]? = nil) {
    self.id = id
    self.name = name
    self.items = items
    self.searchTexts = searchTexts ?? items.map(\.searchText)
  }
}

/// A sound in a library, found from what an agent calls it.
public struct AgentLibrarySound: Sendable {
  public var libraryID: UUID
  public var libraryName: String
  public var item: SoundLibraryItem
  /// A SoundFont or DLS bank's preset, for instruments.
  public var preset: SoundBankPreset?

  /// "Library/Folder/File.ext", with "#Preset" for one of a bank's presets: what agents
  /// pass back to choose it.
  public var reference: String {
    let base = "\(libraryName)/\(item.path)"
    return preset.map { "\(base)#\($0.name)" } ?? base
  }

  public var name: String { preset?.name ?? item.name }

  /// As a track's instrument.
  public var instrument: InstrumentSource {
    .sampler(SamplerInstrument(libraryID: libraryID, libraryName: libraryName, path: item.path, preset: preset))
  }
}

/// What adding a library sound to the song made.
public struct AgentLibraryPlacement: Sendable {
  public var regionIDs: [Region.ID]

  public init(regionIDs: [Region.ID]) {
    self.regionIDs = regionIDs
  }
}

/// The library things only the app can do; sessions without libraries (tests) have none.
extension AgentSession {
  public var soundLibraries: [AgentSoundLibrary] { [] }

  public func addLibrarySound(_ sound: AgentLibrarySound, at position: Tick, onTrack trackID: Track.ID?) async throws -> AgentLibraryPlacement {
    throw AgentError.notPossible("Sound libraries aren't available here.")
  }

  public func setImpulseResponse(_ sound: AgentLibrarySound, forPlugin pluginID: PluginReference.ID, on channelID: Track.ID) throws {
    throw AgentError.notPossible("Sound libraries aren't available here.")
  }
}

/// Finding and describing library sounds for the tools.
enum AgentLibrary {
  /// The most results a search returns.
  static let maximumResults = 100

  /// The library sound `text` names: a reference from a search ("Library/Folder/File.exs",
  /// "…/Bank.sf2#Preset"), or the name of the only sound of that kind with it.
  static func sound(_ text: String, kinds: Set<SoundLibraryItem.Kind>, in libraries: [AgentSoundLibrary]) -> AgentLibrarySound? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    for library in libraries where trimmed.hasPrefix(library.name + "/") {
      var path = String(trimmed.dropFirst(library.name.count + 1))
      var presetName: String?
      if !library.items.contains(where: { $0.path == path }), let hash = path.lastIndex(of: "#") {
        presetName = String(path[path.index(after: hash)...])
        path = String(path[..<hash])
      }
      guard let item = library.items.first(where: { $0.path == path && kinds.contains($0.kind) }) else { continue }
      let preset = presetName.flatMap { name in item.presets.first { $0.name == name } } ?? item.presets.first
      return AgentLibrarySound(libraryID: library.id, libraryName: library.name, item: item, preset: item.presets.count > 0 ? preset : nil)
    }
    // A plain name, if only one sound has it.
    let wanted = AgentNames.simplified(trimmed)
    guard !wanted.isEmpty else { return nil }
    var matches: [AgentLibrarySound] = []
    for library in libraries {
      for item in library.items where kinds.contains(item.kind) {
        if AgentNames.simplified(item.name) == wanted {
          matches.append(AgentLibrarySound(libraryID: library.id, libraryName: library.name, item: item, preset: item.presets.first))
        }
        for preset in item.presets where item.presets.count > 1 && AgentNames.simplified(preset.name) == wanted {
          matches.append(AgentLibrarySound(libraryID: library.id, libraryName: library.name, item: item, preset: preset))
        }
        if matches.count > 1 { return nil }
      }
    }
    return matches.first
  }

  /// The libraries to search: all of them, or the one named.
  @MainActor
  static func libraries(_ name: String?, in session: any AgentSession) throws -> [AgentSoundLibrary] {
    let libraries = session.soundLibraries
    guard !libraries.isEmpty else {
      throw AgentError.notFound("No sound libraries have been added. The person can add folders of sounds in Settings › Libraries.")
    }
    guard let name else { return libraries }
    let wanted = AgentNames.simplified(name)
    let found = libraries.filter { AgentNames.simplified($0.name) == wanted }
    guard !found.isEmpty else {
      throw AgentError.invalidArgument("library", "the libraries are \(libraries.map(\.name).joined(separator: ", ")).")
    }
    return found
  }

  static func words(_ search: String?) -> [String] {
    (search ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .split(whereSeparator: \.isWhitespace).map(String.init)
  }

  /// The library's instruments matching every search word, each preset of a bank on its own.
  static func instruments(matching search: String?, in libraries: [AgentSoundLibrary]) -> [AgentLibrarySound] {
    let words = words(search)
    var found: [AgentLibrarySound] = []
    for library in libraries {
      for (item, text) in zip(library.items, library.searchTexts)
      where item.kind == .instrument && SamplerInstrument.isPlayable(item.path) {
        if item.presets.count > 1 {
          for preset in item.presets {
            let presetText = text + " " + preset.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            if words.allSatisfy(presetText.contains) {
              found.append(AgentLibrarySound(libraryID: library.id, libraryName: library.name, item: item, preset: preset))
            }
          }
        } else if words.allSatisfy(text.contains) {
          found.append(AgentLibrarySound(libraryID: library.id, libraryName: library.name, item: item, preset: item.presets.first))
        }
      }
    }
    return found
  }

  /// A sound as the tools list it.
  static func describe(_ sound: AgentLibrarySound) -> AgentValue {
    let item = sound.item
    var info: [String: AgentValue] = [
      "sound": .string(sound.reference),
      "name": .string(sound.name),
      "folder": .string(([sound.libraryName] + item.folders).joined(separator: "/")),
    ]
    switch item.kind {
    case .loop: info["kind"] = item.hasMIDI ? "midi loop" : "audio loop"
    case .oneShot: info["kind"] = "one-shot"
    case .instrument: info["kind"] = "instrument"
    case .impulseResponse: info["kind"] = "impulse response"
    }
    if let beats = item.beats { info["beats"] = .int(beats) }
    if let tempo = item.tempo { info["bpm"] = .number(tempo) }
    if let key = item.keyName { info["key"] = .string(key) }
    if let category = item.category { info["family"] = .string(category.rawValue) }
    if let genre = item.genre { info["genre"] = .string(genre) }
    if item.kind != .loop, item.kind != .instrument, let duration = item.duration { info["seconds"] = .number(duration) }
    if !item.tags.isEmpty { info["tags"] = .array(item.tags.map { .string($0) }) }
    return .object(info)
  }

  static func limit(_ arguments: AgentArguments) throws -> Int {
    let limit = try arguments.optionalInt("limit") ?? 25
    guard (1...maximumResults).contains(limit) else { throw AgentError.invalidArgument("limit", "from 1 to \(maximumResults).") }
    return limit
  }

  /// Results, at most `limit` of them, with how many there were.
  static func results(_ sounds: [AgentLibrarySound], limit: Int, key: String) -> AgentValue {
    var result: [String: AgentValue] = [
      "count": .int(sounds.count),
      key: .array(sounds.prefix(limit).map(describe)),
    ]
    if sounds.count > limit { result["note"] = .string("Showing \(limit) of \(sounds.count); search with more words to narrow it down.") }
    return .object(result)
  }
}

extension AgentToolbox {
  static let libraryTools: [AgentTool] = [findLoops, addLoop, findImpulseResponses]

  static let findLoops = AgentTool(
    name: "find_loops", title: "Find Loops",
    description: """
      Searches the person's sound libraries (Settings › Libraries) for loops and samples, as \
      the Loop Browser does: by words, instrument family, key, tempo and genre. Audio loops \
      follow the song's tempo and key when added; MIDI loops come in as notes. Pass a result's \
      "sound" to add_loop.
      """,
    properties: [
      "search": Schema.string("Words to find in names, folders, genres and tags, such as \"funky bass\"."),
      "family": Schema.choice(SoundCategory.allCases.map(\.rawValue), "An instrument family."),
      "kind": Schema.choice(["loop", "one-shot", "any"], "Loops (default), one-shot samples, or both."),
      "key": Schema.string("Only loops in this key's root, such as \"E\" or \"F#\"."),
      "bpmMin": Schema.number("The slowest tempo, in BPM."),
      "bpmMax": Schema.number("The fastest tempo, in BPM."),
      "nearSongTempo": Schema.boolean("Only loops within 10% of the song's tempo (they stretch less)."),
      "genre": Schema.string("A genre, as the loops are tagged."),
      "midiOnly": Schema.boolean("Only MIDI loops, which become notes on an instrument track."),
      "library": Schema.string("Only this library."),
      "limit": Schema.integer("How many to return, up to 100 (25 if left out)."),
    ],
    isReadOnly: true
  ) { arguments, session in
    let libraries = try AgentLibrary.libraries(try arguments.optionalString("library"), in: session)
    var filter = SoundLibraryFilter()
    filter.text = try arguments.optionalString("search") ?? ""
    switch try arguments.optionalString("kind").map(AgentNames.simplified) {
    case nil, "loop", "loops": filter.kinds = [.loop]
    case "oneshot", "oneshots": filter.kinds = [.oneShot]
    case "any", "all": filter.kinds = [.loop, .oneShot]
    default: throw AgentError.invalidArgument("kind", "use loop, one-shot or any.")
    }
    if let family = try arguments.optionalChoice("family", SoundCategory.self) { filter.categories = [family] }
    if let key = try arguments.optionalString("key") {
      guard let tonic = AudioFileMetadata.pitchClass(named: key.trimmingCharacters(in: .whitespaces)) else {
        throw AgentError.invalidArgument("key", "a note name such as C, F# or Bb.")
      }
      filter.keyTonic = tonic
    }
    let songTempo = session.project.tempoMap.tempo(at: session.playheadPosition)
    if try arguments.optionalBool("nearSongTempo") == true {
      filter.tempoRange = (songTempo * 0.9)...(songTempo * 1.1)
    } else if arguments.has("bpmMin") || arguments.has("bpmMax") {
      filter.tempoRange = (try arguments.optionalDouble("bpmMin") ?? 0)...(try arguments.optionalDouble("bpmMax") ?? 999)
    }
    filter.genre = try arguments.optionalString("genre")
    filter.midiOnly = try arguments.optionalBool("midiOnly") ?? false
    let words = filter.searchWords
    var found: [AgentLibrarySound] = []
    for library in libraries {
      for (item, text) in zip(library.items, library.searchTexts) {
        // Genres are matched loosely ("hip hop" finds "Hip Hop").
        var itemFilter = filter
        if let genre = filter.genre { itemFilter.genre = AgentNames.simplified(item.genre ?? "") == AgentNames.simplified(genre) ? item.genre : genre }
        if itemFilter.matches(item, searchText: text, words: words) {
          found.append(AgentLibrarySound(libraryID: library.id, libraryName: library.name, item: item))
        }
      }
    }
    guard case .object(var result) = AgentLibrary.results(found, limit: try AgentLibrary.limit(arguments), key: "sounds") else { return .null }
    result["songTempo"] = .number(songTempo)
    result["songKey"] = .string(AgentNotation.name(of: session.project.key(at: session.playheadPosition)))
    return .object(result)
  }

  static let addLoop = AgentTool(
    name: "add_loop", title: "Add Loop",
    description: """
      Adds a loop or sample from find_loops to the song at a position, as dragging it from the \
      Loop Browser does: onto an audio track, or a new track if none is given. Tagged audio \
      loops are stretched to the song's tempo and moved to its key; MIDI loops become notes, \
      on the instrument track given or a new one. Use copy_region with repeats to loop it.
      """,
    properties: [
      "sound": Schema.string("A \"sound\" from find_loops."),
      "at": Schema.position("Where it starts (bar 1 if left out)."),
      "track": Schema.string("The track to put it on (an audio track, or an instrument track for MIDI loops); a new track if left out."),
    ],
    required: ["sound"]
  ) { arguments, session in
    let libraries = try AgentLibrary.libraries(nil, in: session)
    let text = try arguments.string("sound")
    guard let sound = AgentLibrary.sound(text, kinds: [.loop, .oneShot], in: libraries) else {
      throw AgentError.notFound("There's no loop or sample “\(text)”; use a \"sound\" from find_loops.")
    }
    let project = session.project
    let position = try arguments.optionalPosition("at", in: project) ?? .zero
    let track = try arguments.optionalTrack("track", in: project)
    if let track, track.kind == .aux { throw AgentError.invalidArgument("track", "loops can't go on aux tracks.") }
    let placement = try await session.addLibrarySound(sound, at: position, onTrack: track?.id)
    let now = session.project
    let regions: [AgentValue] = placement.regionIDs.compactMap { id in
      guard let region = now.region(withID: id), case .object(var info) = AgentDescriptions.region(region, in: now) else { return nil }
      info["track"] = .string(AgentNames.track(containing: id, in: now)?.name ?? "?")
      if region.transpose != 0 { info["transposed"] = .int(region.transpose) }
      return .object(info)
    }
    return ["added": .string(sound.name), "regions": .array(regions)]
  }

  static let findImpulseResponses = AgentTool(
    name: "find_impulse_responses", title: "Find Impulse Responses",
    description: """
      Searches the sound libraries for impulse responses (recorded rooms and spaces, such as \
      Logic's Space Designer files) for Ongaku's Convolution Reverb. Pass a result's "sound" \
      to set_effect as impulse_response.
      """,
    properties: [
      "search": Schema.string("Words to find, such as \"hall\", \"plate\" or \"small room\"."),
      "library": Schema.string("Only this library."),
      "limit": Schema.integer("How many to return, up to 100 (25 if left out)."),
    ],
    isReadOnly: true
  ) { arguments, session in
    let libraries = try AgentLibrary.libraries(try arguments.optionalString("library"), in: session)
    let words = AgentLibrary.words(try arguments.optionalString("search"))
    var found: [AgentLibrarySound] = []
    for library in libraries {
      for (item, text) in zip(library.items, library.searchTexts) where item.kind == .impulseResponse && words.allSatisfy(text.contains) {
        found.append(AgentLibrarySound(libraryID: library.id, libraryName: library.name, item: item))
      }
    }
    return AgentLibrary.results(found, limit: try AgentLibrary.limit(arguments), key: "impulseResponses")
  }
}
