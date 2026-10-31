//
//  AgentNotation.swift
//  OngakuCore
//

import Foundation

/// The musical units agents use with Ongaku's tools: positions as bar and beat, note
/// lengths in beats, pitches by name, keys, meters and grids. Ticks never reach an agent.
enum AgentNotation {
  // MARK: - Positions

  /// Reads a position: a bar number, or "bar:beat" where the beat (1-based, in the bar's
  /// time signature) can have a fraction ("5:2.5" is halfway through beat 2 of bar 5).
  static func position(_ value: AgentValue, key: String, tempoMap: TempoMap) throws -> Tick {
    let text: String
    switch value {
    case .int(let bar): text = String(bar)
    case .double(let number) where number.rounded() == number: text = String(Int(number))
    case .string(let string): text = string.trimmingCharacters(in: .whitespaces)
    default: throw AgentError.invalidArgument(key, "give a position as \"bar:beat\", such as \"5:1\".")
    }
    let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    guard (1...2).contains(parts.count), let bar = Int(parts[0]), bar >= 1 else {
      throw AgentError.invalidArgument(key, "“\(text)” isn't a position; use \"bar:beat\" such as \"5:1\" (bars start at 1).")
    }
    let beat = parts.count == 2 ? Double(parts[1]) : 1
    let signature = tempoMap.timeSignature(atBarIndex: bar - 1)
    guard let beat, beat >= 1, beat < Double(signature.beatsPerBar + 1) else {
      throw AgentError.invalidArgument(key, "bar \(bar) is in \(signature), so its beats run from 1 to \(signature.beatsPerBar) (fractions allowed).")
    }
    let offset = Double(signature.ticksPerBeat.rawValue) * (beat - 1)
    return tempoMap.tickPosition(ofBarIndex: bar - 1) + Tick(Int64(offset.rounded()))
  }

  /// "bar:beat", the beat with up to three decimal places.
  static func format(_ position: Tick, tempoMap: TempoMap) -> String {
    let (index, start) = tempoMap.bar(containing: position)
    let signature = tempoMap.timeSignature(atBarIndex: index)
    let beat = 1 + Double((position - start).rawValue) / Double(signature.ticksPerBeat.rawValue)
    return "\(index + 1):\(formatNumber(beat))"
  }

  static func format(_ position: Tick, tempoMap: TempoMap) -> AgentValue {
    .string(format(position, tempoMap: tempoMap))
  }

  /// Up to three decimal places, without trailing zeros.
  static func formatNumber(_ value: Double) -> String {
    let rounded = (value * 1000).rounded() / 1000
    if rounded == rounded.rounded() { return String(Int(rounded)) }
    var text = String(format: "%.3f", rounded)
    while text.hasSuffix("0") { text.removeLast() }
    return text
  }

  /// A length in bars, from `start` (bars can differ in length when the meter changes).
  static func end(from start: Tick, bars: Double, tempoMap: TempoMap) -> Tick {
    let (index, barStart) = tempoMap.bar(containing: start)
    let whole = Int(bars.rounded(.down))
    var end = tempoMap.tickPosition(ofBarIndex: index + whole) + (start - barStart)
    let fraction = bars - Double(whole)
    if fraction > 0 {
      let barLength = tempoMap.timeSignature(atBarIndex: tempoMap.bar(containing: end).index).ticksPerBar
      end = end + Tick(Int64((Double(barLength.rawValue) * fraction).rounded()))
    }
    return end
  }

  /// How many bars from `start` to `end`.
  static func bars(from start: Tick, to end: Tick, tempoMap: TempoMap) -> Double {
    let first = tempoMap.bar(containing: start)
    let last = tempoMap.bar(containing: end)
    func fraction(_ position: Tick, _ bar: (index: Int, start: Tick)) -> Double {
      Double((position - bar.start).rawValue) / Double(tempoMap.timeSignature(atBarIndex: bar.index).ticksPerBar.rawValue)
    }
    return Double(last.index - first.index) + fraction(end, last) - fraction(start, first)
  }

  // MARK: - Beats

  /// Note timing inside a region is in quarter-note beats from the region start.
  static func ticks(beats: Double) -> Tick {
    Tick(Int64((beats * Double(Tick.perQuarterNote)).rounded()))
  }

  static func beats(_ ticks: Tick) -> AgentValue {
    .number(ticks.quarterNotes)
  }

  // MARK: - Pitches

  private static let letterPitchClasses: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
  private static let sharpNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

  /// General MIDI drum names, as agents might write them.
  static let drumNames: [String: Int] = [
    "kick": 36, "bassdrum": 36, "bass drum": 36, "kick2": 35, "sidestick": 37, "rimshot": 37, "rim": 37,
    "snare": 38, "clap": 39, "handclap": 39, "electricsnare": 40, "lowfloortom": 41, "floortom": 41,
    "closedhat": 42, "closedhihat": 42, "hihat": 42, "hat": 42, "highfloortom": 43, "pedalhat": 44, "pedalhihat": 44,
    "lowtom": 45, "openhat": 46, "openhihat": 46, "lowmidtom": 47, "midtom": 47, "himidtom": 48, "highmidtom": 48,
    "crash": 49, "crashcymbal": 49, "hightom": 50, "hitom": 50, "ride": 51, "ridecymbal": 51, "china": 52,
    "ridebell": 53, "bell": 53, "tambourine": 54, "splash": 55, "cowbell": 56, "crash2": 57, "vibraslap": 58,
    "ride2": 59, "hibongo": 60, "highbongo": 60, "lowbongo": 61, "conga": 63, "highconga": 62, "lowconga": 64,
    "hightimbale": 65, "lowtimbale": 66, "agogo": 67, "cabasa": 69, "shaker": 70, "maracas": 70, "whistle": 71,
    "guiro": 73, "claves": 75, "woodblock": 76, "highwoodblock": 76, "lowwoodblock": 77, "triangle": 81,
    "opentriangle": 81, "mutetriangle": 80,
  ]

  /// Reads a pitch: a MIDI note number, a name ("C4" is 60, middle C) or a drum's name.
  static func pitch(_ value: AgentValue, key: String = "pitch") throws -> Int {
    if let number = value.intValue {
      guard MIDINote.pitchRange.contains(number) else { throw AgentError.invalidArgument(key, "MIDI notes run from 0 to 127.") }
      return number
    }
    guard let text = value.stringValue?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
      throw AgentError.invalidArgument(key, "give a MIDI note number or a name such as \"C4\".")
    }
    if let drum = drumNames[AgentNames.simplified(text)] { return drum }
    guard let pitch = pitch(named: text) else {
      throw AgentError.invalidArgument(key, "“\(text)” isn't a note; use a name such as \"C4\", \"F#3\" or \"Bb2\" (C4 = 60), or a MIDI number.")
    }
    guard MIDINote.pitchRange.contains(pitch) else { throw AgentError.invalidArgument(key, "“\(text)” is outside MIDI's range (C-1 to G9).") }
    return pitch
  }

  /// "C4" = 60, "F#3" = 54, "Bb2" = 46, "C-1" = 0.
  static func pitch(named text: String) -> Int? {
    var rest = Substring(text)
    guard let letter = rest.first?.uppercased().first, let pitchClass = letterPitchClasses[letter] else { return nil }
    rest = rest.dropFirst()
    var accidental = 0
    while let next = rest.first, "#♯b♭".contains(next) {
      accidental += next == "#" || next == "♯" ? 1 : -1
      rest = rest.dropFirst()
    }
    guard let octave = Int(rest) else { return nil }
    return (octave + 1) * 12 + pitchClass + accidental
  }

  /// Scientific pitch name: 60 is "C4".
  static func name(ofPitch pitch: Int) -> String {
    "\(sharpNames[((pitch % 12) + 12) % 12])\(Int((Double(pitch) / 12).rounded(.down)) - 1)"
  }

  // MARK: - Keys, meters and grids

  /// Reads a key: "A minor", "Am", "F# major", "Eb", "C maj".
  static func key(_ text: String, key argument: String = "key") throws -> KeySignature {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    var rest = Substring(trimmed)
    guard let letter = rest.first?.uppercased().first, let letterClass = letterPitchClasses[letter] else {
      throw AgentError.invalidArgument(argument, "“\(text)” isn't a key; use a name such as \"A minor\" or \"Eb major\".")
    }
    rest = rest.dropFirst()
    var tonic = letterClass
    if let next = rest.first, "#♯b♭".contains(next) {
      tonic += next == "#" || next == "♯" ? 1 : -1
      rest = rest.dropFirst()
    }
    let mode = AgentNames.simplified(String(rest))
    switch mode {
    case "", "maj", "major": return KeySignature(tonic: tonic, mode: .major)
    case "m", "min", "minor": return KeySignature(tonic: tonic, mode: .minor)
    default:
      throw AgentError.invalidArgument(argument, "“\(text)” isn't a key; Ongaku's keys are major or minor, such as \"A minor\".")
    }
  }

  /// "A minor", "Eb major": the spellings most charts use.
  static func name(of key: KeySignature) -> String {
    let names = key.mode == .major
      ? ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
      : ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B"]
    return "\(names[key.tonic]) \(key.mode.rawValue)"
  }

  /// Reads "3/4", "6/8" and so on.
  static func timeSignature(_ text: String, key: String = "signature") throws -> TimeSignature {
    let parts = text.split(separator: "/").map { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2, let beats = parts[0], let unit = parts[1] else {
      throw AgentError.invalidArgument(key, "use a time signature such as \"4/4\", \"3/4\" or \"6/8\".")
    }
    let signature = TimeSignature(beatsPerBar: beats, beatUnit: unit)
    guard signature.isValid else { throw AgentError.invalidArgument(key, "\(text) isn't a supported time signature.") }
    return signature
  }

  /// Reads a grid: "1/4", "1/8", "1/16", "1/32", with "T" for triplets ("1/8T"), or "bar".
  static func grid(_ text: String, key: String = "grid") throws -> Tick {
    let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
    if trimmed == "bar" || trimmed == "1/1" { return Tick.quarterNotes(4) }
    let isTriplet = trimmed.hasSuffix("t")
    let fraction = isTriplet ? String(trimmed.dropLast()) : trimmed
    let parts = fraction.split(separator: "/")
    guard parts.count == 2, parts[0] == "1", let division = Int(parts[1]), [2, 4, 8, 16, 32, 64].contains(division) else {
      throw AgentError.invalidArgument(key, "use a grid such as \"1/4\", \"1/8\", \"1/16\" or \"1/8T\" (triplets).")
    }
    let length = Tick.perQuarterNote * 4 / Int64(division)
    return Tick(isTriplet ? length * 2 / 3 : length)
  }
}
