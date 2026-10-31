//
//  DelayCompensationTests.swift
//  OngakuCoreTests
//

import Testing
@testable import OngakuCore

/// Plug-in delay compensation planning: which paths get delayed, by how much.
struct DelayCompensationTests {
  private let vocal = Track(name: "Vocal", kind: .audio)
  private let guitar = Track(name: "Guitar", kind: .audio)
  private let synth = Track(name: "Synth", kind: .softwareInstrument)
  private let reverb = Track(name: "Reverb", kind: .aux)

  @Test func nothingToCompensateWithoutLatency() {
    let plan = DelayCompensation(project: Project(tracks: [vocal, guitar]), latencies: [:])
    #expect(plan.totalLatency == 0)
    #expect(!plan.compensates)
  }

  @Test func theOtherTracksWaitForTheLatentOne() {
    // A 256-sample compressor on the vocal: the guitar is delayed to match.
    let plan = DelayCompensation(project: Project(tracks: [vocal, guitar]), latencies: [vocal.id: .init(inserts: 256)])
    #expect(plan.totalLatency == 256)
    #expect(plan.delay(from: vocal.id, to: .stereoOut) == 0)
    #expect(plan.delay(from: guitar.id, to: .stereoOut) == 256)
    #expect(plan.faderLatency[vocal.id] == 256)
    #expect(plan.faderLatency[guitar.id] == 0)
  }

  @Test func instrumentLatencyCounts() {
    let plan = DelayCompensation(project: Project(tracks: [synth, guitar]), latencies: [synth.id: .init(source: 64, inserts: 32)])
    #expect(plan.totalLatency == 96)
    #expect(plan.delay(from: guitar.id, to: .stereoOut) == 96)
  }

  @Test func sendsArriveWithTheAuxsOtherInputs() {
    // The vocal (latency 256) and guitar both send to a reverb that adds 100 of its own.
    var vocal = vocal
    var guitar = guitar
    vocal.channel.sends = [Send(destinationTrackID: reverb.id)]
    guitar.channel.sends = [Send(destinationTrackID: reverb.id)]
    let plan = DelayCompensation(
      project: Project(tracks: [vocal, guitar, reverb]),
      latencies: [vocal.id: .init(inserts: 256), reverb.id: .init(inserts: 100)])
    // The reverb hears both at 256 and outputs at 356, the latest path into Stereo Out.
    #expect(plan.delay(from: guitar.id, to: .track(reverb.id)) == 256)
    #expect(plan.delay(from: vocal.id, to: .track(reverb.id)) == 0)
    #expect(plan.faderLatency[reverb.id] == 356)
    #expect(plan.totalLatency == 356)
    #expect(plan.delay(from: vocal.id, to: .stereoOut) == 100)
    #expect(plan.delay(from: guitar.id, to: .stereoOut) == 356)
    #expect(plan.delay(from: reverb.id, to: .stereoOut) == 0)
  }

  @Test func stacksWaitForTheirLatestSubtrack() throws {
    var project = Project(tracks: [vocal, guitar, synth])
    let stack = Track(name: "Sum", kind: .aux)
    try CreateSummingStack([vocal.id, guitar.id], stack: stack).apply(to: &project)
    let plan = DelayCompensation(project: project, latencies: [vocal.id: .init(inserts: 256), stack.id: .init(inserts: 96)])
    #expect(plan.delay(from: guitar.id, to: .track(stack.id)) == 256)
    #expect(plan.delay(from: vocal.id, to: .track(stack.id)) == 0)
    #expect(plan.totalLatency == 352)
    #expect(plan.delay(from: synth.id, to: .stereoOut) == 352, "Tracks outside the stack wait for it")
    #expect(plan.delay(from: stack.id, to: .stereoOut) == 0)
  }
}
