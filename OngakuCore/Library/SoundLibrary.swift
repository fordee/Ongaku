//
//  SoundLibrary.swift
//  OngakuCore
//

import Foundation

/// A sound in a library folder the user added: a loop, a one-shot sample, or a sampler
/// instrument. Libraries are any folders of sounds in standard formats (Logic's and
/// GarageBand's libraries, sample packs, SoundFont collections), indexed so they can be
/// searched without reading the files again.
public struct SoundLibraryItem: Codable, Sendable, Hashable, Identifiable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    /// Audio with a tempo, which follows the song's tempo (and key, if it has one).
    case loop
    /// Audio without a tempo: a hit, a note, an effect.
    case oneShot
    /// A sampler instrument (EXS, SoundFont, DLS, SFZ or an Audio Unit preset).
    case instrument
    /// A room or space recorded for a convolution reverb (Space Designer's `.SDIR` files,
    /// or audio in an impulse responses folder).
    case impulseResponse
  }

  /// The path from the library's folder, with "/" between folders.
  public var path: String
  public var kind: Kind
  /// The file's modification date and size when it was indexed, to tell when it changed.
  public var modified: Double
  public var size: Int64
  public var duration: Double?
  public var beats: Int?
  public var tempo: Double?
  public var keyTonic: Int?
  public var keyMode: KeySignature.Mode?
  public var timeSignature: TimeSignature?
  public var category: SoundCategory?
  public var genre: String?
  /// Subcategory and descriptors, as tagged.
  public var tags: [String]
  /// Whether the loop also carries MIDI (Apple's green MIDI loops), so it can go on an
  /// instrument track as notes.
  public var hasMIDI: Bool
  /// The instruments in a SoundFont or DLS bank.
  public var presets: [SoundBankPreset]

  public var id: String { path }

  public init(
    path: String, kind: Kind, modified: Double = 0, size: Int64 = 0, duration: Double? = nil, beats: Int? = nil,
    tempo: Double? = nil, keyTonic: Int? = nil, keyMode: KeySignature.Mode? = nil, timeSignature: TimeSignature? = nil,
    category: SoundCategory? = nil, genre: String? = nil, tags: [String] = [], hasMIDI: Bool = false,
    presets: [SoundBankPreset] = []
  ) {
    self.path = path
    self.kind = kind
    self.modified = modified
    self.size = size
    self.duration = duration
    self.beats = beats
    self.tempo = tempo
    self.keyTonic = keyTonic
    self.keyMode = keyMode
    self.timeSignature = timeSignature
    self.category = category
    self.genre = genre
    self.tags = tags
    self.hasMIDI = hasMIDI
    self.presets = presets
  }

  /// Short keys: an index can hold a hundred thousand items.
  private enum CodingKeys: String, CodingKey {
    case path = "p", kind = "k", modified = "m", size = "s", duration = "d", beats = "b", tempo = "t"
    case keyTonic = "kt", keyMode = "km", timeSignature = "ts", category = "c", genre = "g", tags = "tg", hasMIDI = "midi"
    case presets = "pr"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(String.self, forKey: .path)
    kind = try container.decode(Kind.self, forKey: .kind)
    modified = try container.decode(Double.self, forKey: .modified)
    size = try container.decode(Int64.self, forKey: .size)
    duration = try container.decodeIfPresent(Double.self, forKey: .duration)
    beats = try container.decodeIfPresent(Int.self, forKey: .beats)
    tempo = try container.decodeIfPresent(Double.self, forKey: .tempo)
    keyTonic = try container.decodeIfPresent(Int.self, forKey: .keyTonic)
    keyMode = try container.decodeIfPresent(KeySignature.Mode.self, forKey: .keyMode)
    timeSignature = try container.decodeIfPresent(TimeSignature.self, forKey: .timeSignature)
    category = try container.decodeIfPresent(SoundCategory.self, forKey: .category)
    genre = try container.decodeIfPresent(String.self, forKey: .genre)
    tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    hasMIDI = try container.decodeIfPresent(Bool.self, forKey: .hasMIDI) ?? false
    presets = try container.decodeIfPresent([SoundBankPreset].self, forKey: .presets) ?? []
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(path, forKey: .path)
    try container.encode(kind, forKey: .kind)
    try container.encode(modified, forKey: .modified)
    try container.encode(size, forKey: .size)
    try container.encodeIfPresent(duration, forKey: .duration)
    try container.encodeIfPresent(beats, forKey: .beats)
    try container.encodeIfPresent(tempo, forKey: .tempo)
    try container.encodeIfPresent(keyTonic, forKey: .keyTonic)
    try container.encodeIfPresent(keyMode, forKey: .keyMode)
    try container.encodeIfPresent(timeSignature, forKey: .timeSignature)
    try container.encodeIfPresent(category, forKey: .category)
    try container.encodeIfPresent(genre, forKey: .genre)
    if !tags.isEmpty { try container.encode(tags, forKey: .tags) }
    if hasMIDI { try container.encode(true, forKey: .hasMIDI) }
    if !presets.isEmpty { try container.encode(presets, forKey: .presets) }
  }

  /// The file name without its extension.
  public var name: String {
    let fileName = path.split(separator: "/").last.map(String.init) ?? path
    return (fileName as NSString).deletingPathExtension
  }

  /// The folders it's in, from the library's folder down.
  public var folders: [String] {
    path.split(separator: "/").dropLast().map(String.init)
  }

  public var fileExtension: String {
    (path as NSString).pathExtension.lowercased()
  }

  /// Whether the loop has a key to follow (drum loops don't).
  public var isTonal: Bool { keyTonic != nil }

  /// "E♭ min", "C maj", "A" (no mode stated), or `nil`.
  public var keyName: String? {
    guard let keyTonic else { return nil }
    let note = KeySignature.noteNames[keyTonic]
    switch keyMode {
    case .major: return "\(note) maj"
    case .minor: return "\(note) min"
    case nil: return note
    }
  }

  /// How many semitones to transpose the loop so its key matches `key`: the nearest way,
  /// from 6 down to 5 up, as Logic moves Apple Loops to the project key. 0 if untuned.
  public func semitones(toMatch key: KeySignature) -> Int {
    keyTonic.map { key.semitones(fromTonic: $0, mode: keyMode) } ?? 0
  }

  /// Text to search: name, folders, category, genre and tags, folded for case and accents.
  public var searchText: String {
    ([name, category?.displayName ?? "", genre ?? ""] + tags + folders)
      .joined(separator: " ")
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}

extension KeySignature {
  /// Pitch class names, as the key menus show them.
  public static let noteNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

  /// How many semitones to move something in `tonic` (and `mode`, if known) into this key:
  /// the nearest way, from 6 down to 5 up. A minor loop goes to a major key's relative minor,
  /// and a major loop to a minor key's relative major.
  public func semitones(fromTonic tonic: Int, mode loopMode: Mode?) -> Int {
    var target = self.tonic
    if loopMode == .minor, mode == .major { target += 9 }
    if loopMode == .major, mode == .minor { target += 3 }
    let up = ((target - tonic) % 12 + 12) % 12
    return up > 5 ? up - 12 : up
  }
}

/// The instrument families the Loop Browser's buttons filter by, as Logic's do.
public enum SoundCategory: String, Codable, Sendable, CaseIterable {
  case drums, percussion, bass, guitar, piano, keys, synth, strings, brass, woodwind, mallets, vocals, fx, other

  public var displayName: String {
    switch self {
    case .drums: "Drums"
    case .percussion: "Percussion"
    case .bass: "Bass"
    case .guitar: "Guitar"
    case .piano: "Piano"
    case .keys: "Keys"
    case .synth: "Synth"
    case .strings: "Strings"
    case .brass: "Brass"
    case .woodwind: "Woodwind"
    case .mallets: "Mallets"
    case .vocals: "Vocals"
    case .fx: "FX"
    case .other: "Other"
    }
  }

  /// Words (or the start of words) that name the family. Checked in case order, so the
  /// more particular families come first ("bassoon" is a woodwind, not a bass).
  static let keywords: [(SoundCategory, [String])] = [
    (.woodwind, ["woodwind", "flute", "sax", "clarinet", "oboe", "bassoon", "piccolo", "recorder", "pan flute"]),
    (.percussion, ["percussion", "perc", "conga", "bongo", "shaker", "tambourine", "cowbell", "clave", "cajon", "timbale",
      "djembe", "tabla", "taiko", "triangle", "guiro", "agogo"]),
    (.mallets, ["mallet", "marimba", "vibraphone", "vibes", "xylophone", "glockenspiel", "celesta", "kalimba", "music box",
      "steel drum", "bell"]),
    (.vocals, ["vocal", "vox", "voice", "choir", "chant", "acapella", "singer", "singing", "adlib"]),
    (.fx, ["fx", "sfx", "effect", "riser", "sweep", "impact", "texture", "ambien", "noise", "transition", "whoosh",
      "foley", "drone", "jingle", "soundscape", "atmos"]),
    (.piano, ["piano", "grand", "upright"]),
    (.keys, ["keys", "keyboard", "organ", "rhodes", "wurli", "electric piano", "clav", "epiano", "harpsichord", "mellotron",
      "accordion"]),
    (.guitar, ["guitar", "gtr", "strum", "banjo", "ukulele", "mandolin", "sitar", "koto", "harp", "pipa", "guzheng"]),
    (.strings, ["string", "violin", "viola", "cello", "orchestra", "ensemble", "pizzicato", "erhu"]),
    (.brass, ["brass", "horn", "trumpet", "trombone", "tuba", "flugel"]),
    (.synth, ["synth", "lead", "pad", "arp", "pluck", "saw", "square", "chiptune", "8-bit"]),
    (.bass, ["bass", "sub", "808"]),
    (.drums, ["drum", "kick", "snare", "hat", "hihat", "hi-hat", "cymbal", "crash", "ride", "tom", "beat", "break",
      "kit", "clap", "rim", "top loop"]),
  ]

  /// The family a sound belongs to, from the texts that describe it, most telling first
  /// (its tagged category, subcategory, name, then folders from the innermost out). In a
  /// text, the last word that names a family wins, as the last word of "Synth Bass" or
  /// "Bass Drum" says what it is.
  public static func classify(_ texts: [String]) -> SoundCategory? {
    for text in texts {
      let lower = text.lowercased()
      let words = lower.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
      // Two-word names ("electric piano", "music box") first, anywhere in the text.
      for (category, names) in keywords {
        if names.contains(where: { $0.contains(" ") && lower.contains($0) }) { return category }
      }
      for word in words.reversed() {
        for (category, names) in keywords where names.contains(where: { matches(word, $0) }) {
          return category
        }
      }
    }
    return nil
  }

  /// Whether a word is a keyword, or starts with one ("drums", "strings", "pads"). Short
  /// keywords must match whole words, so "sub" isn't "subtle" and "rim" isn't "rimshot"'s
  /// only reading.
  private static func matches(_ word: String, _ keyword: String) -> Bool {
    if keyword.count <= 3 { return word == keyword || word == keyword + "s" }
    return word.hasPrefix(keyword)
  }
}

/// What the Loop Browser shows: the items matching every filter that's set.
public struct SoundLibraryFilter: Equatable, Sendable {
  public var text = ""
  public var kinds: Set<SoundLibraryItem.Kind> = [.loop, .oneShot]
  public var categories: Set<SoundCategory> = []
  public var genre: String?
  /// Only loops in this key (any mode) — or, with `matchesKey` in the browser, near it.
  public var keyTonic: Int?
  public var tempoRange: ClosedRange<Double>?
  /// Only MIDI loops (for instrument tracks).
  public var midiOnly = false

  public init() {}

  public var isEmpty: Bool { self == SoundLibraryFilter() }

  /// The folded search words.
  public var searchWords: [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .split(whereSeparator: \.isWhitespace).map(String.init)
  }

  /// Whether an item passes, given its `searchText` (folded once, as items are loaded).
  public func matches(_ item: SoundLibraryItem, searchText: String, words: [String]) -> Bool {
    guard kinds.contains(item.kind) else { return false }
    if !categories.isEmpty, !categories.contains(item.category ?? .other) { return false }
    if let genre, item.genre != genre { return false }
    if let keyTonic, item.keyTonic != keyTonic { return false }
    if let tempoRange, !(item.tempo.map(tempoRange.contains) ?? false) { return false }
    if midiOnly, !item.hasMIDI { return false }
    return words.allSatisfy { searchText.contains($0) }
  }
}
