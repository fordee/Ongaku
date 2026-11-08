//
//  SFZInstrument.swift
//  OngakuCore
//

import Foundation

/// An SFZ instrument: the open text format many free and commercial sample libraries use.
///
/// A file is a list of headers — `<control>`, `<global>`, `<master>`, `<group>`, `<region>` —
/// each followed by `opcode=value` settings. A region plays one sample over a range of keys
/// and velocities, taking every setting from the headers above it that it doesn't set
/// itself. `#define $NAME value` and `#include "file"` work as in the spec.
///
/// Ongaku plays SFZ instruments in Apple's sampler (see `SamplerPreset`), which covers the
/// common core of the format: samples, key and velocity ranges, root keys, tuning, volume,
/// pan, sample start and end, loops in the samples' own loop points, and the amplitude
/// envelope (one for the whole instrument). Things Apple's sampler can't do are left out:
/// release triggers, round robins and random layers play their first choice only, and key
/// switches their default.
public struct SFZInstrument: Sendable {
  public struct Region: Sendable, Equatable {
    /// The sample's path as the file gives it (relative to the instrument's folder, with
    /// `default_path` in front), with "/" between folders.
    public var sample: String
    public var keys: ClosedRange<Int> = 0...127
    public var rootKey = 60
    public var velocities: ClosedRange<Int> = 1...127
    /// Semitones and cents.
    public var transpose = 0
    public var tune = 0.0
    /// Decibels.
    public var volume = 0.0
    /// −100 (left) to 100 (right).
    public var pan = 0.0
    /// Where in the sample to start and end, in frames.
    public var offset = 0
    public var end: Int?
    /// Whether it loops, using the sample's own loop points.
    public var loops = false
    public var envelope = Envelope()

    public init(sample: String) {
      self.sample = sample
    }
  }

  /// The amplitude envelope (`ampeg_…`), in seconds; sustain is a fraction of full level.
  public struct Envelope: Sendable, Equatable, Hashable {
    public var delay = 0.0
    public var attack = 0.0
    public var hold = 0.0
    public var decay = 0.0
    public var sustain = 1.0
    public var release = 0.0

    public init() {}
  }

  public var regions: [Region]

  /// Reads an SFZ file's text. `include` returns the text of a file `#include`d by path.
  public init(text: String, include: (String) -> String? = { _ in nil }) {
    var defines: [String: String] = [:]
    let expanded = Self.expand(text, defines: &defines, include: include, depth: 0)
    regions = Self.regions(in: expanded)
  }

  // MARK: - Text

  /// The text without comments, with `#include`s replaced by their text and `#define`d
  /// names replaced by their values.
  private static func expand(_ text: String, defines: inout [String: String], include: (String) -> String?, depth: Int) -> String {
    var output = ""
    for rawLine in withoutBlockComments(text).components(separatedBy: .newlines) {
      var line = rawLine
      if let comment = line.range(of: "//") { line = String(line[..<comment.lowerBound]) }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("#define") {
        let parts = trimmed.dropFirst("#define".count).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if parts.count == 2 { defines[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces) }
        continue
      }
      if trimmed.hasPrefix("#include") {
        let path = substitute(trimmed.dropFirst("#include".count).trimmingCharacters(in: .whitespaces), defines)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        if depth < 8, let included = include(path.replacingOccurrences(of: "\\", with: "/")) {
          output += expand(included, defines: &defines, include: include, depth: depth + 1) + "\n"
        }
        continue
      }
      output += substitute(line, defines) + "\n"
    }
    return output
  }

  private static func withoutBlockComments(_ text: String) -> String {
    var result = ""
    var rest = Substring(text)
    while let start = rest.range(of: "/*") {
      result += rest[..<start.lowerBound]
      guard let end = rest[start.upperBound...].range(of: "*/") else { return result }
      rest = rest[end.upperBound...]
    }
    return result + rest
  }

  /// Replaces `$NAME`s, longest names first so `$NOTE2` isn't read as `$NOTE`.
  private static func substitute(_ text: String, _ defines: [String: String]) -> String {
    guard text.contains("$") else { return text }
    var result = text
    for (name, value) in defines.sorted(by: { $0.key.count > $1.key.count }) {
      result = result.replacingOccurrences(of: name, with: value)
    }
    return result
  }

  /// The headers and their opcodes, in order.
  static func headers(in text: String) -> [(name: String, opcodes: [(String, String)])] {
    var headers: [(String, [(String, String)])] = []
    var index = text.startIndex
    while let open = text[index...].firstIndex(of: "<"), let close = text[open...].firstIndex(of: ">") {
      let name = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces).lowercased()
      let bodyEnd = text[close...].firstIndex(of: "<") ?? text.endIndex
      headers.append((name, opcodes(in: String(text[text.index(after: close)..<bodyEnd]))))
      index = bodyEnd
    }
    return headers
  }

  /// `opcode=value` settings. A value runs to the next opcode, so sample paths can have
  /// spaces in them ("sample=Piano C4 soft.wav").
  static func opcodes(in text: String) -> [(String, String)] {
    let pattern = /([A-Za-z0-9_]+)=/
    let matches = text.matches(of: pattern)
    return matches.enumerated().map { index, match in
      let valueEnd = index + 1 < matches.count ? matches[index + 1].range.lowerBound : text.endIndex
      let value = text[match.range.upperBound..<valueEnd].trimmingCharacters(in: .whitespacesAndNewlines)
      return (String(match.output.1).lowercased(), value)
    }
  }

  // MARK: - Regions

  private static func regions(in text: String) -> [Region] {
    var control: [String: String] = [:]
    var global: [String: String] = [:]
    var master: [String: String] = [:]
    var group: [String: String] = [:]
    var regions: [(opcodes: [String: String], region: Region)] = []
    for header in headers(in: text) {
      let settings = Dictionary(header.opcodes, uniquingKeysWith: { _, last in last })
      switch header.name {
      case "control": control.merge(settings) { _, new in new }
      case "global": global = settings; master = [:]; group = [:]
      case "master": master = settings; group = [:]
      case "group": group = settings
      case "region":
        var merged = global
        merged.merge(master) { _, new in new }
        merged.merge(group) { _, new in new }
        merged.merge(settings) { _, new in new }
        if let region = region(merged, control: control) { regions.append((merged, region)) }
      default:
        break
      }
    }
    return chooseFirstAlternatives(regions)
  }

  /// A region from its settings, or `nil` if it has no sample, plays on release, or is
  /// switched off (`end=-1`).
  private static func region(_ settings: [String: String], control: [String: String]) -> Region? {
    guard var sample = settings["sample"], !sample.hasPrefix("*") else { return nil }
    if let trigger = settings["trigger"]?.lowercased(), trigger == "release" || trigger == "release_key" { return nil }
    if settings["end"] == "-1" { return nil }
    sample = sample.replacingOccurrences(of: "\\", with: "/")
    if let defaultPath = control["default_path"]?.replacingOccurrences(of: "\\", with: "/"), !defaultPath.isEmpty {
      sample = defaultPath.hasSuffix("/") ? defaultPath + sample : defaultPath + "/" + sample
    }
    let octaveOffset = Int(control["octave_offset"] ?? "") ?? 0
    let noteOffset = Int(control["note_offset"] ?? "") ?? 0
    func note(_ key: String) -> Int? {
      settings[key].flatMap { noteNumber($0, octaveOffset: octaveOffset) }.map { $0 + noteOffset }
    }
    func number(_ keys: String...) -> Double? {
      for key in keys { if let value = settings[key].flatMap(Double.init) { return value } }
      return nil
    }

    var region = Region(sample: sample)
    let key = note("key")
    let low = note("lokey") ?? key ?? 0
    let high = note("hikey") ?? key ?? 127
    region.keys = clampedRange(low, high, in: 0...127)
    region.rootKey = note("pitch_keycenter") ?? key ?? 60
    region.velocities = clampedRange(Int(number("lovel") ?? 1), Int(number("hivel") ?? 127), in: 1...127)
    region.transpose = Int(number("transpose") ?? 0)
    region.tune = number("tune", "pitch") ?? 0
    region.volume = number("volume") ?? 0
    region.pan = min(100, max(-100, number("pan") ?? 0))
    region.offset = max(0, Int(number("offset") ?? 0))
    region.end = number("end").map(Int.init).flatMap { $0 > region.offset ? $0 : nil }
    switch (settings["loop_mode"] ?? settings["loopmode"])?.lowercased() {
    case "loop_continuous", "loop_sustain": region.loops = true
    default: region.loops = false
    }
    var envelope = Envelope()
    envelope.delay = number("ampeg_delay") ?? 0
    envelope.attack = number("ampeg_attack") ?? 0
    envelope.hold = number("ampeg_hold") ?? 0
    envelope.decay = number("ampeg_decay") ?? 0
    envelope.sustain = min(1, max(0, (number("ampeg_sustain") ?? 100) / 100))
    envelope.release = number("ampeg_release") ?? 0
    region.envelope = envelope
    return region
  }

  /// Apple's sampler plays every region whose keys and velocities match, so where the
  /// instrument offers alternatives only the first plays: the first of each round robin
  /// (`seq_position`), the first random layer (`lorand`), and the default key switch.
  private static func chooseFirstAlternatives(_ regions: [(opcodes: [String: String], region: Region)]) -> [Region] {
    let switches = regions.compactMap { $0.opcodes["sw_last"] }
    let defaultSwitch = regions.compactMap { $0.opcodes["sw_default"] }.first ?? switches.first
    return regions.filter { entry in
      if let position = entry.opcodes["seq_position"].flatMap(Int.init), position > 1 { return false }
      if let low = entry.opcodes["lorand"].flatMap(Double.init), low > 0 { return false }
      if let switchKey = entry.opcodes["sw_last"], switchKey != defaultSwitch { return false }
      return true
    }.map(\.region)
  }

  private static func clampedRange(_ low: Int, _ high: Int, in limits: ClosedRange<Int>) -> ClosedRange<Int> {
    let lower = min(max(low, limits.lowerBound), limits.upperBound)
    let upper = min(max(high, limits.lowerBound), limits.upperBound)
    return min(lower, upper)...max(lower, upper)
  }

  /// A MIDI note from a number ("60") or a name ("c4", "F#3", "db-1"); C4 is 60.
  static func noteNumber(_ text: String, octaveOffset: Int = 0) -> Int? {
    let text = text.trimmingCharacters(in: .whitespaces)
    if let number = Int(text) { return number }
    let letters: [Character: Int] = ["c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11]
    let lower = text.lowercased()
    guard let first = lower.first, let base = letters[first] else { return nil }
    var rest = lower.dropFirst()
    var pitch = base
    if rest.first == "#" || rest.first == "♯" { pitch += 1; rest = rest.dropFirst() }
    else if rest.first == "b" || rest.first == "♭" { pitch -= 1; rest = rest.dropFirst() }
    guard let octave = Int(rest) else { return nil }
    return (octave + 1 + octaveOffset) * 12 + pitch
  }
}

/// Writes Apple's sampler presets (`.aupreset`): the property list `AVAudioUnitSampler`
/// loads, with zones (a sample over keys and velocities), the files they play, and an
/// amplitude envelope. It must be saved as XML: the sampler won't load a binary one.
public enum SamplerPreset {
  /// Apple's sampler numbers its waveforms from here.
  static let firstWaveformID = 268_435_457

  /// A preset playing an SFZ instrument's regions. `url` gives each region's sample file;
  /// regions whose files can't be found are left out. Apple's sampler only plays one layer's
  /// envelope reliably, so the preset has one layer, with the envelope most of the regions
  /// use (SFZ instruments usually set it once for all of them).
  public static func make(_ instrument: SFZInstrument, name: String, url: (String) -> URL?) -> [String: Any] {
    var fileReferences: [String: String] = [:]
    var waveformIDs: [String: Int] = [:]
    var zones: [[String: Any]] = []
    var envelopes: [SFZInstrument.Envelope: Int] = [:]
    for region in instrument.regions {
      guard let file = url(region.sample) else { continue }
      let path = file.path(percentEncoded: false)
      let waveform: Int
      if let known = waveformIDs[path] {
        waveform = known
      } else {
        waveform = firstWaveformID + waveformIDs.count
        waveformIDs[path] = waveform
        fileReferences["Sample:\(waveform)"] = path
      }
      var zone: [String: Any] = [
        "ID": zones.count, "enabled": true, "waveform": waveform,
        "root key": region.rootKey, "min key": region.keys.lowerBound, "max key": region.keys.upperBound,
        "min vel": region.velocities.lowerBound, "max vel": region.velocities.upperBound,
        "loop enabled": region.loops,
      ]
      // Whole semitones as coarse tune, the rest (within ±50 cents) as fine tune.
      let cents = Double(region.transpose) * 100 + region.tune
      let semitones = (cents / 100).rounded()
      if semitones != 0 { zone["coarse tune"] = Int(semitones) }
      if cents - semitones * 100 != 0 { zone["fine tune"] = cents - semitones * 100 }
      if region.volume != 0 { zone["gain"] = region.volume }
      if region.pan != 0 { zone["pan"] = region.pan / 100 }
      if region.offset > 0 { zone["sample start"] = region.offset }
      if let end = region.end { zone["sample end"] = end }
      zones.append(zone)
      envelopes[region.envelope, default: 0] += 1
    }
    let envelope = envelopes.max { $0.value < $1.value }?.key ?? SFZInstrument.Envelope()
    let layer: [String: Any] = [
      "ID": 0,
      "Amplifier": ["ID": 0, "enabled": true],
      "Oscillator": ["ID": 0, "enabled": true],
      "Filters": ["ID": 0, "cutoff": 20000.0, "enabled": false, "resonance": -3.0],
      "LFOs": [["ID": 0, "enabled": true]],
      "Connections": defaultConnections,
      "Envelopes": [["ID": 0, "Stages": stages(envelope)]],
      "Zones": zones,
    ]
    return [
      "AU version": 1,
      "name": name,
      "type": 1_635_085_685,  // 'aumu'
      "subtype": 1_935_764_848,  // 'samp'
      "manufacturer": 1_634_758_764,  // 'appl'
      "version": 0,
      "Instrument": ["name": name, "Layers": [layer]],
      "file-references": fileReferences,
    ]
  }

  /// The modulation Apple's sampler sets up in a new instrument (velocity, pitch bend, mod
  /// wheel, volume and pan controllers, and the envelope to the amplifier, which without
  /// these does nothing), as it saves them.
  static let defaultConnections: [[String: Any]] = [
    ["ID": 0, "control": 0, "destination": 816_840_704, "enabled": true, "inverse": false, "scale": 12800.0, "source": 300, "transform": 1],
    ["ID": 1, "control": 0, "destination": 1_343_225_856, "enabled": true, "inverse": true, "scale": -96.0, "source": 301, "transform": 2],
    ["ID": 2, "control": 0, "destination": 1_343_225_856, "enabled": true, "inverse": true, "scale": -96.0, "source": 7, "transform": 2],
    ["ID": 3, "control": 0, "destination": 1_343_225_856, "enabled": true, "inverse": true, "scale": -96.0, "source": 11, "transform": 2],
    ["ID": 4, "control": 0, "destination": 1_344_274_432, "enabled": true, "inverse": false, "max value": 0.508, "min value": -0.508, "source": 10, "transform": 1],
    ["ID": 7, "control": 241, "destination": 816_840_704, "enabled": true, "inverse": false, "max value": 12800.0, "min value": -12800.0, "source": 224, "transform": 1],
    ["ID": 8, "control": 0, "destination": 816_840_704, "enabled": true, "inverse": false, "max value": 100.0, "min value": -100.0, "source": 242, "transform": 1],
    ["ID": 6, "control": 1, "destination": 816_840_704, "enabled": true, "inverse": false, "max value": 50.0, "min value": -50.0, "source": 268_435_456, "transform": 1],
    ["ID": 5, "control": 0, "destination": 1_343_225_856, "enabled": true, "inverse": true, "scale": -96.0, "source": 536_870_912, "transform": 1],
  ]

  /// The sampler's envelope stages: delay, attack, hold, decay, sustain (a level), release,
  /// and a short fade for stolen voices.
  static func stages(_ envelope: SFZInstrument.Envelope) -> [[String: Any]] {
    [
      ["stage": 0, "curve": 20, "time": envelope.delay],
      ["stage": 1, "curve": 22, "time": envelope.attack],
      ["stage": 2, "curve": 20, "time": envelope.hold],
      ["stage": 3, "curve": 20, "time": envelope.decay],
      ["stage": 4, "level": envelope.sustain],
      // A release of exactly 0 silences the note at once; SFZ's 0 means as short as can be.
      ["stage": 5, "curve": 20, "time": max(envelope.release, 0.005)],
      ["stage": 6, "curve": 20, "time": 0.005],
    ]
  }
}
