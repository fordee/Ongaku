//
//  AutomationQueue.swift
//  OngakuEngine
//

import AVFAudio
import AudioToolbox
import Synchronization

/// Automation ramps for one parameter of one mixer node, passed from the main thread (which
/// schedules ahead) to the render thread (which applies them buffer by buffer).
///
/// AVAudioEngine's mixers only carry a parameter ramp to the end of the render buffer it
/// starts in, so a ramp lasting seconds can't be handed over in one go. Instead, a pre-render
/// observer asks this queue for the part of the curve inside each buffer and schedules that
/// as a short ramp. Measured offline, this follows a linear fade to within 0.0001.
///
/// Like `MIDIEventQueue`, the render side only touches atomics and preallocated storage, and
/// `flush()` drops everything still queued when the transport stops.
final class AutomationQueue: @unchecked Sendable {
  struct Ramp {
    /// In the node's sample timeline.
    var start: Int64
    var end: Int64
    var from: Float
    var to: Float

    func value(at sampleTime: Int64) -> Float {
      guard end > start else { return to }
      let fraction = Float(sampleTime - start) / Float(end - start)
      return from + (to - from) * min(max(fraction, 0), 1)
    }
  }

  static let capacity = 4096

  let address: AUParameterAddress
  private let storage: UnsafeMutablePointer<Ramp>
  private let writeIndex = Atomic<Int>(0)
  private let readIndex = Atomic<Int>(0)
  private let flushIndex = Atomic<Int>(0)
  /// While a control is being moved by hand, the queue stops applying automation so the
  /// hand wins (Touch and Latch). Queued ramps still get consumed in step with time.
  private let suspended = Atomic<Bool>(false)

  init(address: AUParameterAddress) {
    self.address = address
    storage = .allocate(capacity: AutomationQueue.capacity)
  }

  deinit {
    storage.deallocate()
  }

  // MARK: - Producer (main thread)

  /// Adds a ramp. Ramps must be pushed in time order and must not overlap. Returns `false`
  /// if the queue is full.
  @discardableResult
  func push(_ ramp: Ramp) -> Bool {
    let write = writeIndex.load(ordering: .relaxed)
    let read = readIndex.load(ordering: .acquiring)
    guard write - read < AutomationQueue.capacity else { return false }
    storage[write % AutomationQueue.capacity] = ramp
    writeIndex.store(write + 1, ordering: .releasing)
    return true
  }

  func flush() {
    flushIndex.store(writeIndex.load(ordering: .relaxed), ordering: .releasing)
  }

  var isSuspended: Bool {
    get { suspended.load(ordering: .relaxed) }
    set { suspended.store(newValue, ordering: .relaxed) }
  }

  // MARK: - Consumer (render thread)

  /// Schedules the part of the queued curve inside the buffer starting at `bufferStart`.
  func deliver(bufferStart: Int64, frameCount: Int64, to schedule: AUScheduleParameterBlock) {
    var read = max(readIndex.load(ordering: .relaxed), flushIndex.load(ordering: .acquiring))
    let write = writeIndex.load(ordering: .acquiring)
    let bufferEnd = bufferStart + frameCount
    let isSuspended = suspended.load(ordering: .relaxed)
    while read < write {
      let ramp = storage[read % AutomationQueue.capacity]
      if ramp.end <= bufferStart {
        read += 1  // Already over (scheduled late, or while suspended).
        continue
      }
      if ramp.start >= bufferEnd { break }
      if !isSuspended {
        let from = max(ramp.start, bufferStart)
        let to = min(ramp.end, bufferEnd)
        schedule(AUEventSampleTime(from), 0, address, ramp.value(at: from))
        schedule(AUEventSampleTime(from), AUAudioFrameCount(to - from), address, ramp.value(at: to))
      }
      // A ramp running past this buffer is kept for the next one.
      guard ramp.end <= bufferEnd else { break }
      read += 1
    }
    readIndex.store(read, ordering: .releasing)
  }
}

/// The sample and host time of a node's most recent render, recorded by its render
/// observer. Mixer nodes don't report a valid `lastRenderTime`, so their timeline has to be
/// read this way. A sequence counter (odd while writing) lets the main thread read both
/// values consistently without the render thread ever waiting.
final class RenderClock: @unchecked Sendable {
  private let sequence = Atomic<Int>(0)
  private let sampleTime = Atomic<Int64>(0)
  private let hostTime = Atomic<UInt64>(0)
  private let hasHostTime = Atomic<Bool>(false)
  private let hasRendered = Atomic<Bool>(false)

  /// Render thread.
  func record(_ timestamp: AudioTimeStamp) {
    sequence.wrappingAdd(1, ordering: .acquiringAndReleasing)
    sampleTime.store(Int64(timestamp.mSampleTime), ordering: .relaxed)
    let hostValid = timestamp.mFlags.contains(.hostTimeValid)
    hasHostTime.store(hostValid, ordering: .relaxed)
    if hostValid { hostTime.store(timestamp.mHostTime, ordering: .relaxed) }
    hasRendered.store(true, ordering: .relaxed)
    sequence.wrappingAdd(1, ordering: .releasing)
  }

  /// The most recent render's sample time and, if known, host time.
  func lastRender() -> (sampleTime: Int64, hostTime: UInt64?)? {
    while true {
      let before = sequence.load(ordering: .acquiring)
      guard before % 2 == 0 else { continue }
      let rendered = hasRendered.load(ordering: .relaxed)
      let sample = sampleTime.load(ordering: .relaxed)
      let host = hasHostTime.load(ordering: .relaxed) ? hostTime.load(ordering: .relaxed) : nil
      guard sequence.load(ordering: .acquiring) == before else { continue }
      return rendered ? (sample, host) : nil
    }
  }

  /// The node's sample time at a host time, at `sampleRate`.
  func sampleTime(atHostTime target: UInt64, sampleRate: Double) -> Int64? {
    guard let last = lastRender(), let host = last.hostTime else { return nil }
    let seconds = target >= host
      ? AVAudioTime.seconds(forHostTime: target - host)
      : -AVAudioTime.seconds(forHostTime: host - target)
    return last.sampleTime + Int64((seconds * sampleRate).rounded())
  }
}

extension AVAudioNode {
  /// The node's sample time at a host time, from its most recent render. Each node counts
  /// samples in its own timeline, so times for scheduled events have to be worked out per node.
  func sampleTime(atHostTime hostTime: UInt64) -> Int64? {
    guard let last = lastRenderTime, last.isSampleTimeValid, last.isHostTimeValid else { return nil }
    let seconds = hostTime >= last.hostTime
      ? AVAudioTime.seconds(forHostTime: hostTime - last.hostTime)
      : -AVAudioTime.seconds(forHostTime: last.hostTime - hostTime)
    return last.sampleTime + Int64((seconds * last.sampleRate).rounded())
  }
}
