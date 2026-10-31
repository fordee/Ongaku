//
//  SampleChunkRingTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
@testable import OngakuEngine
import Testing

/// Drives `SampleChunkRing.render` with made-up render timestamps, as the audio thread
/// would, and checks every chunk lands on its exact sample.
struct SampleChunkRingTests {
  private static let rate = 48_000.0
  private static let cycle = 512

  /// A render-thread stand-in: the node's timeline and the host clock advance together.
  private struct Renderer {
    let ring: SampleChunkRing
    var sampleTime: Int64 = 100_000
    let hostAtZero: UInt64 = 1_000_000_000
    let buffer = AVAudioPCMBuffer(
      pcmFormat: AVAudioFormat(standardFormatWithSampleRate: SampleChunkRingTests.rate, channels: 2)!,
      frameCapacity: AVAudioFrameCount(SampleChunkRingTests.cycle))!

    func hostTime(atSample sample: Int64) -> UInt64 {
      hostAtZero + AVAudioTime.hostTime(forSeconds: Double(sample) / SampleChunkRingTests.rate)
    }

    /// Renders cycles until `frames` frames have played and returns the left channel.
    mutating func render(frames: Int) -> [Float] {
      var output: [Float] = []
      while output.count < frames {
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = Double(sampleTime)
        timestamp.mHostTime = hostTime(atSample: sampleTime)
        timestamp.mFlags = [.sampleTimeValid, .hostTimeValid]
        buffer.frameLength = AVAudioFrameCount(SampleChunkRingTests.cycle)
        _ = ring.render(timestamp: &timestamp, frameCount: SampleChunkRingTests.cycle, into: buffer.mutableAudioBufferList)
        output += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: SampleChunkRingTests.cycle)
        sampleTime += Int64(SampleChunkRingTests.cycle)
      }
      return output
    }
  }

  private func makeRing() -> SampleChunkRing {
    SampleChunkRing(slotCount: 8, slotFrames: 1000, sampleRate: Self.rate)
  }

  /// Enqueues a chunk whose samples are 1, 2, 3, … so where each lands can be checked.
  @discardableResult
  private func enqueueCounting(_ ring: SampleChunkRing, session: Int, start: Int64, frames: Int, from first: Float = 1) -> Bool {
    ring.enqueue(session: session, start: start) { left, right in
      for frame in 0..<frames {
        left[frame] = first + Float(frame)
        right[frame] = first + Float(frame)
      }
      return frames
    }
  }

  @Test func theFirstSampleLandsAtTheStartHostTime() {
    let ring = makeRing()
    var renderer = Renderer(ring: ring)
    // The run starts 3,000 samples after the renderer's current time.
    let startSample = renderer.sampleTime + 3_000
    ring.begin(session: 1, startHostTime: renderer.hostTime(atSample: startSample))
    enqueueCounting(ring, session: 1, start: 0, frames: 10)

    let output = renderer.render(frames: 4_096)
    let first = output.firstIndex { $0 != 0 }
    #expect(first == 3_000)
    #expect(Array(output[3_000..<3_010]) == (1...10).map(Float.init))
    #expect(ring.missedFrames == 0)
  }

  @Test func consecutiveChunksJoinWithoutAGap() {
    let ring = makeRing()
    var renderer = Renderer(ring: ring)
    ring.begin(session: 1, startHostTime: renderer.hostTime(atSample: renderer.sampleTime))
    // Three chunks of 1,000 frames that together count 1…3000.
    for chunk in 0..<3 {
      enqueueCounting(ring, session: 1, start: Int64(chunk * 1_000), frames: 1_000, from: Float(chunk * 1_000 + 1))
    }
    let output = renderer.render(frames: 3_584)
    #expect(Array(output[0..<3_000]) == (1...3_000).map(Float.init))
    #expect(output[3_000...].allSatisfy { $0 == 0 })
    #expect(ring.freeSlotCount == 8, "Played chunks are handed back")
  }

  @Test func aLateChunkPlaysTheRestInTime() {
    let ring = makeRing()
    var renderer = Renderer(ring: ring)
    ring.begin(session: 1, startHostTime: renderer.hostTime(atSample: renderer.sampleTime))
    _ = renderer.render(frames: 1_024)  // 1,024 frames played before the chunk arrives
    enqueueCounting(ring, session: 1, start: 1_000, frames: 1_000)

    let output = renderer.render(frames: 1_024)
    // Frames 1,000–1,023 of the run were missed; frame 1,024 is the chunk's 25th sample.
    #expect(output[0] == 25)
    #expect(output[975] == 1_000)
    #expect(output[976] == 0)
    #expect(ring.missedFrames == 24)
  }

  @Test func stoppingDropsWhatIsQueued() {
    let ring = makeRing()
    var renderer = Renderer(ring: ring)
    ring.begin(session: 1, startHostTime: renderer.hostTime(atSample: renderer.sampleTime))
    enqueueCounting(ring, session: 1, start: 0, frames: 1_000)
    enqueueCounting(ring, session: 1, start: 1_000, frames: 1_000)
    _ = renderer.render(frames: 512)

    ring.end()
    let output = renderer.render(frames: 2_048)
    #expect(output.allSatisfy { $0 == 0 }, "Silent from the next render")
    #expect(ring.freeSlotCount == 8)
  }

  @Test func aNewRunIgnoresTheOldRunsChunks() {
    let ring = makeRing()
    var renderer = Renderer(ring: ring)
    ring.begin(session: 1, startHostTime: renderer.hostTime(atSample: renderer.sampleTime))
    enqueueCounting(ring, session: 1, start: 0, frames: 1_000, from: 500)

    // Locating starts a new run before the old one rendered anything.
    let newStart = renderer.sampleTime + 1_536
    ring.begin(session: 2, startHostTime: renderer.hostTime(atSample: newStart))
    enqueueCounting(ring, session: 2, start: 0, frames: 4)

    let output = renderer.render(frames: 2_048)
    #expect(output.firstIndex { $0 != 0 } == 1_536)
    #expect(Array(output[1_536..<1_540]) == [1, 2, 3, 4])
    #expect(output.filter { $0 != 0 }.count == 4, "Nothing from the old run is heard")
  }

  @Test func overlappingChunksMix() {
    let ring = makeRing()
    var renderer = Renderer(ring: ring)
    ring.begin(session: 1, startHostTime: renderer.hostTime(atSample: renderer.sampleTime))
    ring.enqueue(session: 1, start: 0) { left, right in
      left.update(repeating: 0.25, count: 100)
      right.update(repeating: 0.25, count: 100)
      return 100
    }
    ring.enqueue(session: 1, start: 50) { left, right in
      left.update(repeating: 0.5, count: 100)
      right.update(repeating: 0.5, count: 100)
      return 100
    }
    let output = renderer.render(frames: 512)
    #expect(output[10] == 0.25)
    #expect(output[60] == 0.75)
    #expect(output[120] == 0.5)
    #expect(output[160] == 0)
  }
}

extension SampleChunkRingTests {
  /// What one source costs the audio thread per render, stopped and playing. A song with
  /// 32 audio tracks renders 32 of these about 94 times a second.
  @Test func renderCost() {
    let ring = SampleChunkRing(slotCount: AudioTrackSource.chunkCount, slotFrames: 8192, sampleRate: Self.rate)
    var renderer = Renderer(ring: ring)
    let clock = ContinuousClock()
    let cycles = 20_000
    let stopped = clock.measure { _ = renderer.render(frames: cycles * Self.cycle) }

    ring.begin(session: 1, startHostTime: renderer.hostTime(atSample: renderer.sampleTime))
    var next: Int64 = 0
    let playing = clock.measure {
      for _ in 0..<cycles {
        while ring.freeSlotCount > 12 {
          ring.enqueue(session: 1, start: next) { left, right in
            left.update(repeating: 0.1, count: 8192)
            right.update(repeating: 0.1, count: 8192)
            return 8192
          }
          next += 8192
        }
        _ = renderer.render(frames: Self.cycle)
      }
    }
    print("PERF ring render stopped: \(stopped / cycles) per render; playing (incl. filling): \(playing / cycles) per render")
  }
}

extension SampleChunkRingTests {
  /// Play reads each track's first chunk before fixing the start time; those chunks must
  /// survive renders while stopped, and an ended run's chunks must not.
  @Test func chunksReadBeforeARunBeginsAreKept() {
    let ring = makeRing()
    var renderer = Renderer(ring: ring)
    ring.begin(session: 1, startHostTime: renderer.hostTime(atSample: renderer.sampleTime))
    enqueueCounting(ring, session: 1, start: 4_000, frames: 10, from: 100)
    ring.end()

    // Run 2's first chunk is read while stopped, then a few renders go by.
    enqueueCounting(ring, session: 2, start: 0, frames: 10)
    #expect(renderer.render(frames: 1_536).allSatisfy { $0 == 0 })
    #expect(ring.freeSlotCount == 7, "Run 1's chunk is dropped; run 2's is kept")

    ring.begin(session: 2, startHostTime: renderer.hostTime(atSample: renderer.sampleTime + 512))
    let output = renderer.render(frames: 1_024)
    #expect(Array(output[512..<522]) == (1...10).map(Float.init))
    #expect(ring.missedFrames == 0)
  }
}
