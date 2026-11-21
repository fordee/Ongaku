//
//  MusicXML.swift
//  OngakuCore
//

import Foundation

/// MusicXML 4.0 (partwise) from a score, for notation apps (Sibelius, Finale, Dorico,
/// MuseScore) and Logic's own MusicXML import: the notes, rests, ties, triplets, beams,
/// clefs, key and time signatures and chord symbols, exactly as the Score editor shows them.
public enum MusicXML {
  /// Positions are written in ticks: 960 to a quarter note.
  static let divisions = Tick.perQuarterNote

  public static func document(for layout: ScoreLayout, title: String, partName: String) -> String {
    var xml = """
      <?xml version="1.0" encoding="UTF-8" standalone="no"?>
      <!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 4.0 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
      <score-partwise version="4.0">
        <work><work-title>\(escape(title))</work-title></work>
        <identification><encoding><software>Ongaku Studio</software></encoding></identification>
        <part-list>
          <score-part id="P1"><part-name>\(escape(partName))</part-name></score-part>
        </part-list>
        <part id="P1">

      """
    for (number, measure) in layout.measures.enumerated() {
      xml += "    <measure number=\"\(number + 1)\">\n"
      xml += attributes(for: measure, isFirst: number == 0, staves: layout.staves)
      for (staff, events) in measure.events.enumerated() {
        if staff > 0 { xml += "      <backup><duration>\(measure.length.rawValue)</duration></backup>\n" }
        xml += notes(events, staff: staff, staffCount: layout.staves.count, clef: layout.staves[staff].clef, measure: measure)
      }
      if number == layout.measures.count - 1 {
        xml += "      <barline location=\"right\"><bar-style>light-heavy</bar-style></barline>\n"
      }
      xml += "    </measure>\n"
    }
    xml += "  </part>\n</score-partwise>\n"
    return xml
  }

  // MARK: - Attributes

  static func attributes(for measure: ScoreMeasure, isFirst: Bool, staves: [ScoreStaff]) -> String {
    guard isFirst || measure.showsKey || measure.showsSignature else { return "" }
    var xml = "      <attributes>\n"
    if isFirst { xml += "        <divisions>\(divisions)</divisions>\n" }
    if isFirst || measure.showsKey, staves.first?.clef != .percussion {
      let mode = measure.key.mode == .minor ? "minor" : "major"
      xml += "        <key><fifths>\(measure.key.sharpsOrFlats)</fifths><mode>\(mode)</mode></key>\n"
    }
    if isFirst || measure.showsSignature {
      xml += "        <time><beats>\(measure.signature.beatsPerBar)</beats><beat-type>\(measure.signature.beatUnit)</beat-type></time>\n"
    }
    if isFirst {
      if staves.count > 1 { xml += "        <staves>\(staves.count)</staves>\n" }
      for (index, staff) in staves.enumerated() {
        let number = staves.count > 1 ? " number=\"\(index + 1)\"" : ""
        switch staff.clef {
        case .treble: xml += "        <clef\(number)><sign>G</sign><line>2</line></clef>\n"
        case .bass: xml += "        <clef\(number)><sign>F</sign><line>4</line></clef>\n"
        case .percussion: xml += "        <clef\(number)><sign>percussion</sign></clef>\n"
        }
      }
    }
    return xml + "      </attributes>\n"
  }

  // MARK: - Notes

  static func notes(_ events: [ScoreEvent], staff: Int, staffCount: Int, clef: Clef, measure: ScoreMeasure) -> String {
    var xml = ""
    let steps = ["C", "D", "E", "F", "G", "A", "B"]
    let beamPositions = beams(events)
    let tuplets = tupletPositions(events)
    for (index, event) in events.enumerated() {
      // Chord symbols go before the note they're over (top staff only).
      if staff == 0 {
        let next = index + 1 < events.count ? events[index + 1].start : measure.end
        for symbol in measure.chordSymbols where symbol.position >= event.start && symbol.position < next {
          xml += harmony(symbol.chord, offset: symbol.position - event.start)
        }
      }
      let isWholeBarRest = event.isRest && events.count == 1
      let duration = isWholeBarRest ? measure.length.rawValue : event.value.ticks
      let staffElement = staffCount > 1 ? "        <staff>\(staff + 1)</staff>\n" : ""
      let notes = event.isRest ? [nil] : event.notes.sorted { $0.diatonic < $1.diatonic }.map { Optional($0) }
      for (chordIndex, note) in notes.enumerated() {
        xml += "      <note>\n"
        if chordIndex > 0 { xml += "        <chord/>\n" }
        if let note {
          if clef == .percussion {
            xml += "        <unpitched><display-step>\(steps[note.step])</display-step><display-octave>\(note.octave)</display-octave></unpitched>\n"
          } else {
            let alter = note.alter != 0 ? "<alter>\(note.alter)</alter>" : ""
            xml += "        <pitch><step>\(steps[note.step])</step>\(alter)<octave>\(note.octave)</octave></pitch>\n"
          }
        } else {
          xml += isWholeBarRest ? "        <rest measure=\"yes\"/>\n" : "        <rest/>\n"
        }
        xml += "        <duration>\(duration)</duration>\n"
        if let note, note.isTiedFromPrevious { xml += "        <tie type=\"stop\"/>\n" }
        if let note, note.tiesToNext { xml += "        <tie type=\"start\"/>\n" }
        xml += "        <voice>\(staff + 1)</voice>\n"
        if !isWholeBarRest {
          xml += "        <type>\(event.value.base.name)</type>\n"
          xml += String(repeating: "        <dot/>\n", count: event.value.dots)
        }
        if let accidental = note?.accidental { xml += "        <accidental>\(accidental.rawValue)</accidental>\n" }
        if event.value.isTriplet {
          xml += "        <time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>\n"
        }
        if note?.isCross == true { xml += "        <notehead>x</notehead>\n" }
        xml += staffElement
        if chordIndex == 0, let beam = beamPositions[index] { xml += "        <beam number=\"1\">\(beam)</beam>\n" }
        var notations: [String] = []
        if let note, note.isTiedFromPrevious { notations.append("<tied type=\"stop\"/>") }
        if let note, note.tiesToNext { notations.append("<tied type=\"start\"/>") }
        if chordIndex == 0, let tuplet = tuplets[index] { notations.append("<tuplet type=\"\(tuplet)\"/>") }
        if !notations.isEmpty { xml += "        <notations>\(notations.joined())</notations>\n" }
        xml += "      </note>\n"
      }
    }
    return xml
  }

  /// Each beamed event's place in its beam: begin, continue or end.
  static func beams(_ events: [ScoreEvent]) -> [Int: String] {
    var result: [Int: String] = [:]
    let groups = Dictionary(grouping: events.indices.filter { events[$0].beamGroup != nil }, by: { events[$0].beamGroup! })
    for (_, members) in groups where members.count > 1 {
      let sorted = members.sorted()
      for (position, index) in sorted.enumerated() {
        result[index] = position == 0 ? "begin" : position == sorted.count - 1 ? "end" : "continue"
      }
    }
    return result
  }

  /// Where each triplet bracket starts and stops.
  static func tupletPositions(_ events: [ScoreEvent]) -> [Int: String] {
    var result: [Int: String] = [:]
    let groups = Dictionary(grouping: events.indices.filter { events[$0].tupletGroup != nil }, by: { events[$0].tupletGroup! })
    for (_, members) in groups {
      let sorted = members.sorted()
      guard let first = sorted.first, let last = sorted.last else { continue }
      result[first] = "start"
      result[last] = first == last ? "start" : "stop"
    }
    return result
  }

  // MARK: - Chord symbols

  static func harmony(_ chord: Chord, offset: Tick) -> String {
    let (step, alter) = spelling(chord.root, flats: ![1, 6].contains(chord.root))
    let kind: String = switch chord.quality {
    case .major: "major"
    case .minor: "minor"
    case .dominant7: "dominant"
    case .major7: "major-seventh"
    case .minor7: "minor-seventh"
    case .diminished: "diminished"
    case .halfDiminished: "half-diminished"
    case .augmented: "augmented"
    case .sus2: "suspended-second"
    case .sus4: "suspended-fourth"
    case .six: "major-sixth"
    case .minor6: "minor-sixth"
    case .add9: "major"
    case .dominant9: "dominant-ninth"
    case .minor9: "minor-ninth"
    case .power: "power"
    }
    var xml = "      <harmony>\n        <root><root-step>\(step)</root-step>\(alter.map { "<root-alter>\($0)</root-alter>" } ?? "")</root>\n"
    xml += "        <kind text=\"\(escape(chord.quality.suffix))\">\(kind)</kind>\n"
    if chord.quality == .add9 { xml += "        <degree><degree-value>9</degree-value><degree-alter>0</degree-alter><degree-type>add</degree-type></degree>\n" }
    if let bass = chord.bass {
      let (bassStep, bassAlter) = spelling(bass, flats: ![1, 6].contains(chord.root))
      xml += "        <bass><bass-step>\(bassStep)</bass-step>\(bassAlter.map { "<bass-alter>\($0)</bass-alter>" } ?? "")</bass>\n"
    }
    if offset > .zero { xml += "        <offset>\(offset.rawValue)</offset>\n" }
    return xml + "      </harmony>\n"
  }

  /// A pitch class's letter and alteration.
  static func spelling(_ pitchClass: Int, flats: Bool) -> (step: String, alter: Int?) {
    let sharpNames = [("C", nil), ("C", 1), ("D", nil), ("D", 1), ("E", nil), ("F", nil), ("F", 1), ("G", nil), ("G", 1), ("A", nil), ("A", 1), ("B", nil)]
    let flatNames = [("C", nil), ("D", -1), ("D", nil), ("E", -1), ("E", nil), ("F", nil), ("G", -1), ("G", nil), ("A", -1), ("A", nil), ("B", -1), ("B", nil)]
    let names: [(String, Int?)] = flats ? flatNames : sharpNames
    return names[((pitchClass % 12) + 12) % 12]
  }

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
}
