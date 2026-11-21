//
//  ScoreLayoutTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Writing MIDI regions out as notation: bars of notes and rests, ties, triplets, beams,
/// spelling for the key, clefs and drums.
struct ScoreLayoutTests {
  private let quarter: Int64 = 960
  private var bar: Int64 { quarter * 4 }

  private func note(_ pitch: Int, _ start: Int64, _ length: Int64) -> MIDINote {
    MIDINote(pitch: pitch, velocity: 90, start: Tick(start), length: Tick(length))
  }

  private func layout(
    _ notes: [MIDINote], bars: Int64 = 1, signature: TimeSignature = .fourFour, key: KeySignature? = nil,
    drums: Bool = false, options: ScoreOptions = ScoreOptions()
  ) throws -> ScoreLayout {
    var project = Project()
    try project.tempoMap.setTimeSignature(signature, atBarIndex: 0)
    if let key { project.keySignature = key }
    let length = signature.ticksPerBar.rawValue * bars
    let region = Region(name: "Part", start: .zero, length: Tick(length), content: .midi(MIDISequence(notes: notes)))
    return ScoreLayout(region: region, in: project, isDrumPart: drums, options: options)
  }

  /// A staff's events in a bar, as "value[.dots]" (r for a rest, t for a triplet, ~ when tied on).
  private func rhythm(_ measure: ScoreMeasure, staff: Int = 0) -> [String] {
    measure.events[staff].map { event in
      var text = (event.isRest ? "r" : "") + "\(event.value.base.rawValue)" + String(repeating: ".", count: event.value.dots)
      if event.value.isTriplet { text += "t" }
      if event.notes.contains(where: \.tiesToNext) { text += "~" }
      return text
    }
  }

  @Test func anEmptyBarIsAWholeRest() throws {
    let score = try layout([], bars: 2)
    #expect(score.measures.count == 2)
    #expect(rhythm(score.measures[0]) == ["r1"])
  }

  @Test func restsFillTheBeatsAroundNotes() throws {
    // Beat 2 only.
    let score = try layout([note(72, quarter, quarter)])
    #expect(rhythm(score.measures[0]) == ["r4", "4", "r2"], "A half rest for the second half of the bar")
  }

  @Test func longNotesAreTiedAcrossBarLinesAndTheMiddleOfTheBar() throws {
    // From beat 2 for six beats: tied over the middle of 4/4 and into the next bar.
    let score = try layout([note(67, quarter, quarter * 6)], bars: 2)
    #expect(rhythm(score.measures[0]) == ["r4", "4~", "2~"], "Tied over the middle of the bar, not a dotted half")
    #expect(rhythm(score.measures[1]).first == "2.", "Then the rest of it from the bar line")
    #expect(score.measures[1].events[0].first?.notes.first?.isTiedFromPrevious == true)
    let first = score.measures[0].events[0].first { !$0.isRest }
    #expect(first?.notes.first?.tiesToNext == true)
  }

  @Test func eighthsAreBeamedInBeats() throws {
    let notes = (0..<8).map { note(72, Int64($0) * quarter / 2, quarter / 2) }
    let events = try layout(notes).measures[0].events[0]
    #expect(events.count == 8 && events.allSatisfy { $0.value.base == .eighth })
    let groups = events.compactMap(\.beamGroup)
    #expect(groups.count == 8 && Set(groups).count == 4, "One beam per beat")
  }

  @Test func compoundMetersAreBeamedInThrees() throws {
    let six8 = TimeSignature(beatsPerBar: 6, beatUnit: 8)
    let notes = (0..<6).map { note(72, Int64($0) * quarter / 2, quarter / 2) }
    let events = try layout(notes, signature: six8).measures[0].events[0]
    #expect(Set(events.compactMap(\.beamGroup)).count == 2, "Two groups of three eighths")
    // A dotted quarter fills one pulse.
    let held = try layout([note(72, 0, quarter * 3 / 2)], signature: six8).measures[0].events[0]
    #expect(held.first?.value == NoteValue(base: .quarter, dots: 1))
  }

  @Test func notesInThirdsOfABeatAreTriplets() throws {
    let third = quarter / 3
    let notes = (0..<3).map { note(72, Int64($0) * third, third) }
    let events = try layout(notes).measures[0].events[0]
    let beat = events.filter { $0.start.rawValue < quarter }
    #expect(beat.count == 3 && beat.allSatisfy { $0.value == NoteValue(base: .eighth, isTriplet: true) })
    #expect(Set(beat.compactMap(\.tupletGroup)).count == 1)
    // Turned off, they're forced onto the straight grid.
    let straight = try layout(notes, options: ScoreOptions(allowsTriplets: false)).measures[0].events[0]
    #expect(!straight.contains { $0.value.isTriplet })
  }

  @Test func notesAreSpelledForTheKeyWithAccidentalsOncePerBar() throws {
    // F major (one flat): B♭ needs nothing; B natural needs a natural; a second B natural in the bar doesn't.
    let fMajor = KeySignature(tonic: 5, mode: .major)
    let score = try layout([note(70, 0, quarter), note(71, quarter, quarter), note(71, quarter * 2, quarter)], key: fMajor)
    let notes = score.measures[0].events[0].flatMap(\.notes)
    #expect(notes[0].step == 6 && notes[0].alter == -1 && notes[0].accidental == nil, "B♭ from the key")
    #expect(notes[1].accidental == .natural)
    #expect(notes[2].accidental == nil)
    // In E major, D♯ is spelled as D♯, not E♭.
    let eMajor = KeySignature(tonic: 4, mode: .major)
    let sharp = try layout([note(63, 0, quarter)], key: eMajor).measures[0].events[0].flatMap(\.notes)
    #expect(sharp.first?.step == 1 && sharp.first?.alter == 1 && sharp.first?.accidental == nil)
  }

  @Test func clefsFollowTheRange() throws {
    #expect(try layout([note(72, 0, quarter)]).staves.map(\.clef) == [.treble])
    #expect(try layout([note(40, 0, quarter)]).staves.map(\.clef) == [.bass])
    let piano = try layout([note(76, 0, quarter), note(40, 0, quarter)])
    #expect(piano.staves.map(\.clef) == [.treble, .bass])
    #expect(piano.measures[0].events[0].flatMap(\.notes).map(\.pitch) == [76])
    #expect(piano.measures[0].events[1].flatMap(\.notes).map(\.pitch) == [40])
  }

  @Test func drumsGoOnADrumStaffWithCrossesForCymbals() throws {
    let score = try layout([note(36, 0, quarter), note(42, 0, quarter), note(38, quarter, quarter)], drums: true)
    #expect(score.staves.map(\.clef) == [.percussion])
    let first = score.measures[0].events[0][0].notes
    #expect(first.count == 2)
    #expect(first.first { $0.pitch == 42 }?.isCross == true)
    #expect(first.first { $0.pitch == 36 }?.isCross == false)
  }

  @Test func timeAndKeySignaturesShowAtTheStartAndWhereTheyChange() throws {
    var project = Project()
    try project.tempoMap.setTimeSignature(TimeSignature(beatsPerBar: 3, beatUnit: 4), atBarIndex: 1)
    // A bar of 4/4, then two of 3/4.
    let region = Region(name: "Part", start: .zero, length: Tick(bar + quarter * 6), content: .midi(MIDISequence()))
    let score = ScoreLayout(region: region, in: project)
    #expect(score.measures.map(\.showsSignature) == [true, true, false])
    #expect(score.measures.map(\.showsKey) == [true, false, false])
  }

  @Test func playingQuantizeIsShownAndDisplayQuantizeTidiesTheRest() throws {
    // Slightly early and late notes still read as beats.
    let score = try layout([note(72, 20, quarter - 30), note(74, quarter - 15, quarter)])
    #expect(rhythm(score.measures[0]).prefix(2) == ["4", "4"])
  }
}
