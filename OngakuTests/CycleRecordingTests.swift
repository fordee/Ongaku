//
//  CycleRecordingTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
import Testing

/// Recording with the cycle on: each pass becomes a take in a take folder.
@MainActor
struct CycleRecordingTests {
  private let bar = Tick.quarterNotes(4)

  /// Cycle over bars 1–2 (4 s at 120 BPM).
  private func cyclingProject(armed track: Track) -> Project {
    var project = Project(tracks: [track])
    project.cycle = CycleRange(isEnabled: true, start: .zero, end: bar * 2)
    return project
  }

  @Test func thePlanKnowsEachPass() {
    var project = cyclingProject(armed: Track(name: "Keys", kind: .softwareInstrument))
    project.cycle.start = bar
    // Starting at bar 1: the first pass runs to the cycle end at 4 s, reaching the cycle
    // start (bar 2) after 2 s; then every 2 s.
    let plan = PlaybackPlan(project: project, startPosition: .zero)
    #expect(plan.cycleRange == bar..<(bar * 2))
    #expect(plan.passIndex(atPlaybackTime: 3.9) == 0)
    #expect(plan.passIndex(atPlaybackTime: 4.1) == 1)
    #expect(plan.passIndex(atPlaybackTime: 6.1) == 2)
    #expect(plan.cycleStartTime(ofPass: 0) == 2)
    #expect(plan.cycleStartTime(ofPass: 2) == 6)
  }

  @Test func audioPassesBecomeTakes() throws {
    let project = cyclingProject(armed: Track(name: "Vocal", kind: .audio))
    let plan = PlaybackPlan(project: project, startPosition: .zero)
    // Recorded from the start for 9 s: two full passes and one second of a third.
    let passes = try #require(PlaybackEngine.cyclePasses(in: plan, recordedFrom: 0, frames: 432_000, sampleRate: 48_000))
    #expect(passes.cycle == .zero..<(bar * 2))
    #expect(passes.startFrames == [0, 192_000, 384_000])
  }

  @Test func shortPassesAreLeftOut() throws {
    let project = cyclingProject(armed: Track(name: "Vocal", kind: .audio))
    let plan = PlaybackPlan(project: project, startPosition: .zero)
    // Half a second into the second pass: not a take.
    #expect(PlaybackEngine.cyclePasses(in: plan, recordedFrom: 0, frames: 216_000, sampleRate: 48_000) == nil)
  }

  @Test func midiPassesBecomeATakeFolder() throws {
    var track = Track(name: "Keys", kind: .softwareInstrument)
    track.isRecordArmed = true
    let project = cyclingProject(armed: track)
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    let start: UInt64 = 1_000_000_000
    func host(_ seconds: Double) -> UInt64 { start + AVAudioTime.hostTime(forSeconds: seconds) }
    let recording = RecordingSession(
      audio: [], midiTrackIDs: [track.id], midiCapture: nil, startPosition: .zero, startHostTime: start,
      outputLatency: 0, inputLatency: 0)
    let plan = PlaybackPlan(project: project, startPosition: .zero)

    // C on beat 1 of the first pass, E on beat 2 of the second.
    let takes = engine.midiTakes(
      from: [
        (host(0), [0x90, 60, 100]), (host(0.4), [0x80, 60, 0]),
        (host(4.5), [0x90, 64, 100]), (host(4.9), [0x80, 64, 0]),
      ],
      recording: recording, plan: plan, stopPosition: bar * 2)
    let region = try #require(takes.first?.region)
    let folder = try #require(region.takeFolder)
    #expect(region.start == .zero)
    #expect(region.length == bar * 2)
    #expect(folder.takes.map(\.name) == ["Take 1", "Take 2"])
    #expect(region.leadTakeID == folder.takes[1].id, "The last take plays")
    guard case .midi(let second) = region.content else { Issue.record("Not MIDI"); return }
    #expect(second.notes.map(\.pitch) == [64])
    #expect(abs(second.notes[0].start.rawValue - 960) <= 1, "Beat 2 of its pass")
  }
}
