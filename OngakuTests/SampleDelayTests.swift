//
//  SampleDelayTests.swift
//  OngakuTests
//

import AVFAudio
@testable import OngakuEngine
import Testing

/// The sample delays plug-in delay compensation puts on early connections.
@MainActor
struct SampleDelayTests {
  /// Renders a single-sample impulse through a chain of delays set to `frames`, and returns
  /// where it comes out.
  private func impulseArrival(delayedBy frames: Int) throws -> Int? {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
    let impulse = ImpulseSource()
    let source = AVAudioSourceNode(format: format) { _, _, frameCount, data in
      impulse.render(frameCount: Int(frameCount), into: data)
      return noErr
    }
    let units = (0..<SampleDelay.unitCount(for: frames)).map { _ in SampleDelay.makeUnit() }
    let chain: [AVAudioNode] = [source] + units + [engine.mainMixerNode]
    for node in chain.dropLast() { engine.attach(node) }
    for index in chain.indices.dropLast() {
      try engine.connectNode(chain[index], to: chain[index + 1], format: format)
    }
    SampleDelay.set(units, to: frames)
    try engine.start()
    defer { engine.stop() }

    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
    var rendered = 0
    for _ in 0..<4 {
      _ = try engine.renderOffline(4_096, to: buffer)
      if let index = (0..<Int(buffer.frameLength)).first(where: { abs(buffer.floatChannelData![0][$0]) > 0.1 }) {
        return rendered + index
      }
      rendered += Int(buffer.frameLength)
    }
    return nil
  }

  @Test(arguments: [0, 1, 96, 256, 4_410, 4_411, 9_000])
  func delaysAreExactToTheSample(frames: Int) throws {
    #expect(try impulseArrival(delayedBy: frames) == frames)
  }

  @Test func longDelaysChainUnits() {
    #expect(SampleDelay.unitCount(for: 0) == 0)
    #expect(SampleDelay.unitCount(for: 4_410) == 1)
    #expect(SampleDelay.unitCount(for: 4_411) == 2)
  }
}

/// A single sample at the start, then silence; called from the render thread.
private final class ImpulseSource: @unchecked Sendable {
  private var sent = false

  func render(frameCount: Int, into data: UnsafeMutablePointer<AudioBufferList>) {
    for buffer in UnsafeMutableAudioBufferListPointer(data) {
      guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
      samples.update(repeating: 0, count: frameCount)
      if !sent { samples[0] = 0.5 }
    }
    sent = true
  }
}
