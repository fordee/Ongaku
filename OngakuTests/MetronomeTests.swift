//
//  MetronomeTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
@testable import OngakuEngine
import Testing

/// The Metronome settings: sounds, accent and level.
@MainActor
struct MetronomeTests {
  @Test(arguments: MetronomeSettings.Sound.allCases)
  func everySoundIsAShortClickThatDoesntClip(sound: MetronomeSettings.Sound) {
    for accented in [false, true] {
      let click = Metronome.makeClick(sound, accented: accented, sampleRate: 48_000)
      #expect(!click.isEmpty)
      #expect(click.count <= 48_000 / 10, "At most 100 ms")
      let peak = click.map(abs).max() ?? 0
      #expect(peak > 0.05, "Loud enough to hear")
      #expect(peak <= 1, "Doesn't clip")
      #expect(abs(click.last ?? 0) < 0.02, "Fades out instead of stopping with a click")
    }
  }

  @Test func accentedClicksDiffer() {
    let beat = Metronome.makeClick(.woodblock, accented: false, sampleRate: 48_000)
    let accent = Metronome.makeClick(.woodblock, accented: true, sampleRate: 48_000)
    #expect(beat != accent)
  }

  @Test func theLevelSetsTheVolume() {
    let engine = PlaybackEngine(project: Project()) { _ in nil }
    defer { engine.shutDown() }
    engine.metronomeSettings.level = 0.5
    #expect(engine.metronome?.volume == 0, "Off until switched on")
    engine.isMetronomeEnabled = true
    #expect(engine.metronome?.volume == 0.5)
    engine.metronomeSettings.sound = .hiHat
    #expect(engine.metronome?.settings.sound == .hiHat)
  }
}
