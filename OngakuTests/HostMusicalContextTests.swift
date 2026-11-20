//
//  HostMusicalContextTests.swift
//  OngakuTests
//

import AudioToolbox
import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
import Testing

/// What plug-ins are told about the song: tempo, position and transport.
struct HostMusicalContextTests {
  private static func quarterNotes(_ count: Int64) -> Tick {
    Tick(rawValue: count * Tick.perQuarterNote)
  }

  private struct Context {
    var tempo = 0.0, numerator = 0.0, denominator = 0, beat = 0.0, sampleOffset = 0, downbeat = 0.0
  }

  private func read(_ block: AUHostMusicalContextBlock) -> Context {
    var context = Context()
    #expect(block(&context.tempo, &context.numerator, &context.denominator, &context.beat, &context.sampleOffset, &context.downbeat))
    return context
  }

  private struct Transport {
    var flags: AUHostTransportStateFlags = [], samplePosition = 0.0, cycleStart = 0.0, cycleEnd = 0.0
  }

  private func read(_ block: AUHostTransportStateBlock) -> Transport {
    var transport = Transport()
    #expect(block(&transport.flags, &transport.samplePosition, &transport.cycleStart, &transport.cycleEnd))
    return transport
  }

  @Test func reportsTheBarsDownbeatAndMeter() {
    let context = HostMusicalContext()
    // In 3/4, the third bar starts on quarter note 6.
    context.update(at: Self.quarterNotes(7), in: TempoMap(bpm: 90, timeSignature: TimeSignature(beatsPerBar: 3, beatUnit: 4)))
    let now = read(context.block)
    #expect(now.tempo == 90)
    #expect(now.numerator == 3)
    #expect(now.denominator == 4)
    #expect(now.beat == 7)
    #expect(now.downbeat == 6)
    #expect(now.sampleOffset == 0, "Stopped, so no beat is coming")
  }

  @Test func thePositionMovesOnAtTheTempoBetweenUpdates() {
    var state = HostMusicalContext.State()
    state.tempo = 120
    state.isPlaying = true
    state.hostTime = 1_000_000
    let later = HostMusicalContext.carriedForward(state, to: state.hostTime + AVAudioTime.hostTime(forSeconds: 0.1))
    #expect(abs(later.beat - 0.2) < 0.0001, "Two beats a second")
    #expect(abs(later.seconds - 0.1) < 0.0001)

    let stalled = HostMusicalContext.carriedForward(state, to: state.hostTime + AVAudioTime.hostTime(forSeconds: 5))
    #expect(abs(stalled.beat - 0.5) < 0.0001, "Without updates it goes no further than a quarter of a second")

    state.isPlaying = false
    #expect(HostMusicalContext.carriedForward(state, to: state.hostTime + AVAudioTime.hostTime(forSeconds: 0.1)).beat == 0)
  }

  @Test func thePositionGoesBackRoundTheCycleAndFollowsTheBars() {
    var state = HostMusicalContext.State()
    state.tempo = 120
    state.isPlaying = true
    state.hostTime = 1_000_000
    state.beat = 15.9
    state.barStart = 12
    state.cycle = (start: 8, end: 16, barStart: 8, seconds: 4)
    let later = HostMusicalContext.carriedForward(state, to: state.hostTime + AVAudioTime.hostTime(forSeconds: 0.1))
    #expect(abs(later.beat - 8.1) < 0.0001)
    #expect(later.barStart == 8)

    state.cycle = nil
    let past = HostMusicalContext.carriedForward(state, to: state.hostTime + AVAudioTime.hostTime(forSeconds: 0.1))
    #expect(past.barStart == 16, "Into the next bar")
  }

  @Test func eachPlugInIsToldOnceThatTheTransportChanged() {
    let context = HostMusicalContext()
    let tempoMap = TempoMap(bpm: 120)
    context.setSampleRate(48_000)
    let first = context.transportStateBlock
    let second = context.transportStateBlock
    #expect(read(first).flags.isEmpty)

    context.setTransport(isPlaying: true, isRecording: true, cycle: Self.quarterNotes(4)..<Self.quarterNotes(8), in: tempoMap)
    context.update(at: Self.quarterNotes(4), in: tempoMap)
    let playing = read(first)
    #expect(playing.flags == [.changed, .moving, .recording, .cycling])
    #expect(playing.cycleStart == 4)
    #expect(playing.cycleEnd == 8)
    #expect(playing.samplePosition == 96_000, "Two seconds in at 120 BPM")
    #expect(read(first).flags == [.moving, .recording, .cycling], "Only once")
    #expect(read(second).flags.contains(.changed), "Every plug-in hears of it")

    context.setTransport(isPlaying: false, in: tempoMap)
    #expect(read(first).flags == [.changed])
  }

  @Test func aJumpDuringPlaybackIsAChange() {
    let context = HostMusicalContext()
    let tempoMap = TempoMap(bpm: 120)
    let transport = context.transportStateBlock
    context.setTransport(isPlaying: true, in: tempoMap)
    let now = mach_absolute_time()
    context.update(at: .zero, hostTime: now, in: tempoMap)
    _ = read(transport)
    // A tenth of a second later, a fifth of a beat on: just playing along.
    let later = now + AVAudioTime.hostTime(forSeconds: 0.1)
    context.update(at: Tick(rawValue: Tick.perQuarterNote / 5), hostTime: later, in: tempoMap)
    #expect(!read(transport).flags.contains(.changed))
    context.update(at: Self.quarterNotes(16), hostTime: later, in: tempoMap)
    #expect(read(transport).flags.contains(.changed))
  }

  @Test func sampleOffsetCountsToTheNextBeatWhilePlaying() {
    let context = HostMusicalContext()
    let tempoMap = TempoMap(bpm: 120)
    context.setSampleRate(48_000)
    context.setTransport(isPlaying: true, in: tempoMap)
    // Half a beat in, without a host time so it stays put: a quarter of a second to go.
    context.update(at: Tick(rawValue: Tick.perQuarterNote / 2), in: tempoMap)
    #expect(read(context.block).sampleOffset == 12_000)
  }
}
