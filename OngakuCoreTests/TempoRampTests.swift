//
//  TempoRampTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Logic's tempo ramps: a tempo change that glides to the next one instead of stepping.
struct TempoRampTests {
  /// 100 BPM ramping to 140 over a bar, then holding.
  private func rampingMap() throws -> TempoMap {
    var map = TempoMap(bpm: 100)
    try map.setTempo(140, at: Tick(3840))
    map.setRamp(true, at: .zero)
    return map
  }

  /// The bar's length in seconds: ∫ 60 / tempo over the ramp.
  private let rampSeconds = 60.0 / 960 * log(1.4) / (40.0 / 3840)

  @Test func theTempoGlidesThroughTheRamp() throws {
    let map = try rampingMap()
    #expect(map.tempo(at: Tick(1920)) == 120)
    #expect(map.tempo(at: Tick(3840)) == 140)
    #expect(map.tempo(at: Tick(9000)) == 140)
  }

  @Test func timeThroughARampIsTheIntegralOfItsTempo() throws {
    let map = try rampingMap()
    #expect(abs(map.seconds(at: Tick(3840)) - rampSeconds) < 1e-9)
    // After the ramp, beats are at 140 BPM.
    #expect(abs(map.seconds(at: Tick(3840 + 960)) - rampSeconds - 60.0 / 140) < 1e-9)
  }

  @Test(arguments: [0, 1, 500, 1920, 3839, 3840, 6000])
  func secondsAndTicksRoundTripThroughARamp(rawTick: Int64) throws {
    let map = try rampingMap()
    #expect(map.tickPosition(atSeconds: map.seconds(at: Tick(rawTick))) == Tick(rawTick))
  }

  @Test func rampsAreSavedButStepsAreAsBefore() throws {
    let map = try rampingMap()
    let decoded = try JSONDecoder().decode(TempoMap.self, from: JSONEncoder().encode(map))
    #expect(decoded == map)
    let steps = try String(decoding: JSONEncoder().encode(TempoMap(bpm: 120)), as: UTF8.self)
    #expect(!steps.contains("rampsToNext"), "Files without ramps are unchanged")
  }

  @Test func theLastChangeHasNothingToRampTo() throws {
    var project = Project(tempoMap: try rampingMap())
    #expect(throws: EditError.self) { try SetTempoRamp(at: Tick(3840), ramps: true).apply(to: &project) }
    // Deleting the change it ramps to makes the first one step again.
    try DeleteTempoChange(at: Tick(3840)).apply(to: &project)
    #expect(project.tempoMap.tempoChanges.map(\.rampsToNext) == [false])
  }

  @Test func movingAChangeKeepsTheRamps() throws {
    var project = Project(tempoMap: try rampingMap())
    try project.tempoMap.setTempo(90, at: Tick(7680))
    project.tempoMap.setRamp(true, at: Tick(3840))
    try UpdateTempoChange(at: Tick(3840), to: Tick(4800), bpm: 150).apply(to: &project)
    #expect(project.tempoMap.tempoChanges.map(\.rampsToNext) == [true, true, false])
    #expect(project.tempoMap.tempoChanges.map(\.position) == [.zero, Tick(4800), Tick(7680)])
  }

  @Test func midiFilesStepThroughARampABeatAtATime() throws {
    let data = StandardMIDIFile.write(Project(tempoMap: try rampingMap()))
    let read = try StandardMIDIFile.read(data).tempoMap
    #expect(read.tempoChanges.count == 5, "A tempo for each of the ramp's four beats, then 140")
    // Every beat lands where it plays (to the file's microsecond resolution).
    for beat in 0...4 {
      let tick = Tick(Int64(beat) * 960)
      #expect(abs(read.seconds(at: tick) - (try rampingMap()).seconds(at: tick)) < 1e-5)
    }
  }
}
