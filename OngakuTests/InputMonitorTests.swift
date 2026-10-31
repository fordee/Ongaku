//
//  InputMonitorTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
import Testing

/// Input monitoring's ring: what the input writes, each monitoring track reads back from its
/// own channels, a buffer or two later.
struct InputMonitorTests {
  private static let cycle = 256
  private let input = AVAudioPCMBuffer(
    // More than two channels need a layout: four discrete ones, like an interface's inputs.
    pcmFormat: AVAudioFormat(
      standardFormatWithSampleRate: 48_000,
      channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4)!),
    frameCapacity: AVAudioFrameCount(cycle))!
  private let output = AVAudioPCMBuffer(
    pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: AVAudioFrameCount(cycle))!

  /// Writes one cycle of a four-channel input whose channel n, frame f holds n * 1 000 000 + f.
  private func writeCycle(_ ring: InputRing, startingAt frame: Int) {
    input.frameLength = AVAudioFrameCount(Self.cycle)
    for channel in 0..<4 {
      for offset in 0..<Self.cycle {
        input.floatChannelData![channel][offset] = Float(channel * 1_000_000 + frame + offset)
      }
    }
    ring.write(input.audioBufferList, frameCount: Self.cycle)
  }

  private func readCycle(_ ring: InputRing, _ reader: InputRing.Reader) -> (played: Bool, left: [Float], right: [Float]) {
    output.frameLength = AVAudioFrameCount(Self.cycle)
    let played = ring.read(into: output.mutableAudioBufferList, frameCount: Self.cycle, with: reader)
    return (
      played,
      Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Self.cycle)),
      Array(UnsafeBufferPointer(start: output.floatChannelData![1], count: Self.cycle)))
  }

  @Test func eachTrackHearsItsOwnChannelsTwoCyclesLate() {
    let ring = InputRing(channelCount: 4)
    let mono = InputRing.Reader(left: 2, right: 2)  // Input 3, mono
    let stereo = InputRing.Reader(left: 0, right: 1)  // Inputs 1–2

    writeCycle(ring, startingAt: 0)
    #expect(!readCycle(ring, mono).played, "Silence until two cycles have arrived")
    writeCycle(ring, startingAt: Self.cycle)
    for cycle in 2..<6 {
      writeCycle(ring, startingAt: cycle * Self.cycle)
      let heard = readCycle(ring, mono)
      #expect(heard.played)
      let expectedStart = Float(2_000_000 + (cycle - 1) * Self.cycle)
      #expect(heard.left.first == expectedStart, "Cycle \(cycle)")
      #expect(heard.left == heard.right, "A mono input goes to both sides")
      #expect(heard.left.last == expectedStart + Float(Self.cycle - 1), "Frames run on without a gap")
    }
    let both = readCycle(ring, stereo)
    #expect(both.left.first.map { $0 < 1_000_000 } == true)
    #expect(both.right.first.map { $0 >= 1_000_000 && $0 < 2_000_000 } == true)
  }

  @Test func aReaderThatFallsBehindCatchesUp() {
    let ring = InputRing(channelCount: 4)
    let reader = InputRing.Reader(left: 0, right: 0)
    for cycle in 0..<3 { writeCycle(ring, startingAt: cycle * Self.cycle) }
    _ = readCycle(ring, reader)
    // The output stalls for ten cycles while the input carries on.
    for cycle in 3..<13 { writeCycle(ring, startingAt: cycle * Self.cycle) }
    let heard = readCycle(ring, reader)
    #expect(heard.left.first == Float(11 * Self.cycle), "Back to two cycles behind the newest input")
  }

  @Test func inputMonitoringIsForAudioTracks() throws {
    let audio = Track(name: "Vocal", kind: .audio)
    let keys = Track(name: "Keys", kind: .softwareInstrument)
    var project = Project(tracks: [audio, keys])
    try SetInputMonitoring(audio.id, isMonitored: true).apply(to: &project)
    #expect(project.tracks[0].isInputMonitored)
    #expect(throws: EditError.self) { try SetInputMonitoring(keys.id, isMonitored: true).apply(to: &project) }
    let saved = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    #expect(saved.tracks[0].isInputMonitored, "It's saved with the song")
  }
}
