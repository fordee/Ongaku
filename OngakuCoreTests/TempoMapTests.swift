//
//  TempoMapTests.swift
//  OngakuCoreTests
//

import Testing
@testable import OngakuCore

struct TempoMapTests {
  @Test func quarterNoteAt120BPMIsHalfASecond() {
    let map = TempoMap(bpm: 120)
    #expect(map.seconds(at: Tick(960)) == 0.5)
    #expect(map.tickPosition(atSeconds: 0.5) == Tick(960))
    #expect(map.sampleTime(at: Tick(960), sampleRate: 48_000) == 24_000)
  }

  @Test func tempoChangeAffectsOnlyLaterPositions() throws {
    var map = TempoMap(bpm: 120)
    // From bar 2 (tick 3840) the tempo doubles.
    try map.setTempo(240, at: Tick(3840))

    #expect(map.seconds(at: Tick(3840)) == 2.0)
    #expect(map.seconds(at: Tick(3840 + 960)) == 2.25)
    #expect(map.tempo(at: Tick(3839)) == 120)
    #expect(map.tempo(at: Tick(3840)) == 240)
  }

  @Test(arguments: [0, 1, 959, 3840, 5000, 20_000])
  func secondsAndTicksRoundTrip(rawTick: Int64) throws {
    var map = TempoMap(bpm: 97)
    try map.setTempo(143.5, at: Tick(4000))
    let tick = Tick(rawTick)
    #expect(map.tickPosition(atSeconds: map.seconds(at: tick)) == tick)
  }

  @Test func initialTempoCanBeChangedButNotRemoved() throws {
    var map = TempoMap(bpm: 120)
    try map.setTempo(90)
    map.removeTempoChange(at: .zero)
    #expect(map.tempoChanges.count == 1)
    #expect(map.tempo(at: .zero) == 90)
  }

  @Test func rejectsOutOfRangeTempo() {
    var map = TempoMap()
    #expect(throws: EditError.self) { try map.setTempo(0) }
    #expect(throws: EditError.self) { try map.setTempo(120, at: Tick(-1)) }
  }

  @Test func musicalPositionInFourFour() {
    let map = TempoMap()
    #expect(map.musicalPosition(at: .zero) == MusicalPosition(bar: 1))
    #expect(map.musicalPosition(at: Tick(3840)) == MusicalPosition(bar: 2))
    // Bar 2, beat 3, second sixteenth, tick 10.
    let tick = Tick(3840 + 2 * 960 + 240 + 10)
    #expect(map.musicalPosition(at: tick) == MusicalPosition(bar: 2, beat: 3, division: 2, tick: 10))
    #expect(map.tickPosition(of: MusicalPosition(bar: 2, beat: 3, division: 2, tick: 10)) == tick)
  }

  @Test func meterChangeMovesLaterBarLines() throws {
    var map = TempoMap()
    // Bars 1–2 are 4/4, bar 3 onwards is 3/4.
    try map.setTimeSignature(TimeSignature(beatsPerBar: 3, beatUnit: 4), atBarIndex: 2)

    #expect(map.tickPosition(ofBarIndex: 2) == Tick(7680))
    #expect(map.tickPosition(ofBarIndex: 3) == Tick(7680 + 2880))
    #expect(map.bar(containing: Tick(7680 + 2880 + 1)).index == 3)
    #expect(map.musicalPosition(at: Tick(7680 + 2 * 960)) == MusicalPosition(bar: 3, beat: 3))
  }

  @Test func eighthNoteMeterUsesEighthNoteBeats() throws {
    var map = TempoMap()
    try map.setTimeSignature(TimeSignature(beatsPerBar: 6, beatUnit: 8), atBarIndex: 0)
    #expect(map.tickPosition(ofBarIndex: 1) == Tick(2880))
    #expect(map.musicalPosition(at: Tick(480)) == MusicalPosition(bar: 1, beat: 2))
  }

  @Test func negativePositionsAreBeforeBarOne() {
    let map = TempoMap()
    #expect(map.bar(containing: Tick(-1)).index == -1)
    #expect(map.musicalPosition(at: Tick(-3840)) == MusicalPosition(bar: 0))
  }

  @Test func rejectsUnsupportedTimeSignature() {
    var map = TempoMap()
    #expect(throws: EditError.self) {
      try map.setTimeSignature(TimeSignature(beatsPerBar: 4, beatUnit: 3), atBarIndex: 0)
    }
  }
}
