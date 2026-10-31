//
//  DrummerSong.swift
//  OngakuCore
//

import Foundation

/// The Session Drummer plug-in's song: the parts of the song in order (Intro, Verse,
/// Chorus…), each some bars long and played its own way. Other DAWs don't tell a plug-in
/// about their song sections, so the plug-in keeps its own list, laid out from bar 1 of the
/// host's timeline (and repeating, if `repeats`).
public struct DrummerSong: Codable, Sendable, Equatable {
  public struct Section: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var bars: Int
    public var performance: DrummerPerformance

    public init(id: UUID = UUID(), name: String, bars: Int, performance: DrummerPerformance) {
      self.id = id
      self.name = name
      self.bars = bars
      self.performance = performance
    }
  }

  public static let barsRange = 1...64

  public var sections: [Section]
  /// After the last section, start again from the first (otherwise the last one carries on).
  public var repeats: Bool

  public init(sections: [Section], repeats: Bool = true) {
    self.sections = sections
    self.repeats = repeats
  }

  /// A song to start from: sections with the usual names, each played to suit it, in one
  /// style.
  public static func starter(
    style: DrummerPerformance.Style = .rock, kit: DrummerPerformance.Kit = .generalMIDI,
    layout: [(name: String, bars: Int)] = [("Verse", 8), ("Chorus", 8)], seed: UInt64 = 1
  ) -> DrummerSong {
    var song = DrummerSong(sections: layout.enumerated().map { index, part in
      Section(
        name: part.name, bars: part.bars,
        performance: .forSection(
          named: part.name, style: style, kit: kit, isFirst: index == 0, isLast: false,
          seed: seed &+ UInt64(index) &* 0x9E37_79B9))
    })
    song.updateTransitions()
    return song
  }

  /// Crashes into each section after the first and fills into the next; with `repeats`, the
  /// last fills back into the first and the first crashes in again when it comes round.
  public mutating func updateTransitions() {
    for index in sections.indices {
      sections[index].performance.fillsAtEnd = repeats || index < sections.count - 1
      sections[index].performance.crashesAtStart = index > 0 || (repeats && sections.count > 1)
    }
  }

  public func totalBars() -> Int { sections.reduce(0) { $0 + max(1, $1.bars) } }

  /// The section playing at a bar (counting from 0), and that bar's index within it; nil past
  /// the end of a song that doesn't repeat (the last section carries on).
  public func section(atBar bar: Int) -> (index: Int, barInSection: Int)? {
    let total = totalBars()
    guard total > 0, !sections.isEmpty else { return nil }
    var position = repeats ? ((bar % total) + total) % total : min(max(bar, 0), total - 1)
    for (index, section) in sections.enumerated() {
      let bars = max(1, section.bars)
      if position < bars { return (index, position) }
      position -= bars
    }
    return (sections.count - 1, 0)
  }

  /// The whole part, once through, in one meter, from the song's start. Notes are on the
  /// General MIDI drum channel (10), as drum parts conventionally are.
  public func notes(in signature: TimeSignature) -> [MIDINote] {
    let tempoMap = TempoMap(bpm: 120, timeSignature: signature)
    var notes: [MIDINote] = []
    var start = Tick.zero
    for section in sections {
      let length = signature.ticksPerBar * Int64(max(1, section.bars))
      for var note in section.performance.notes(from: start, length: length, tempoMap: tempoMap) {
        note.start += start
        note.channel = 9
        notes.append(note)
      }
      start += length
    }
    return notes
  }

  /// The song's length in quarter notes.
  public func lengthInQuarterNotes(in signature: TimeSignature) -> Double {
    (signature.ticksPerBar * Int64(totalBars())).quarterNotes
  }

  /// The part as a Standard MIDI File (one drum track), to drag into a DAW. `times` repeats
  /// the song (useful when it repeats in the host).
  public func midiFile(signature: TimeSignature, bpm: Double, times: Int = 1) -> Data {
    let once = notes(in: signature)
    let songLength = signature.ticksPerBar * Int64(totalBars())
    var all: [MIDINote] = []
    for pass in 0..<max(1, times) {
      all += once.map { note in
        var copy = note
        copy.id = UUID()
        copy.start += songLength * Int64(pass)
        return copy
      }
    }
    var track = Track(name: "Session Drummer", kind: .softwareInstrument)
    track.channel.instrument = .generalMIDIPercussion(kit: 0)
    track.regions = [Region(
      name: "Drums", start: .zero, length: songLength * Int64(max(1, times)), content: .midi(MIDISequence(notes: all)))]
    let project = Project(
      tempoMap: TempoMap(bpm: bpm, timeSignature: signature), endPosition: songLength * Int64(max(1, times)), tracks: [track])
    return StandardMIDIFile.write(project)
  }
}
