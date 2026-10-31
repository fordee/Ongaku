//
//  MIDIEventQueue.swift
//  OngakuEngine
//

import AudioToolbox
import Synchronization

/// A lock-free queue of timestamped MIDI events between the main thread (which schedules
/// ahead) and the audio render thread (which hands each event to the instrument in the
/// render cycle where it is due).
///
/// Why not give the instrument the events directly? An Audio Unit holds on to events
/// scheduled for the future and there is no way to take them back, so after Stop already
/// queued notes would still play. Keeping them here until they are due means Stop can drop
/// them with `flush()`.
///
/// Real-time rules: `deliver(before:to:)` runs on the render thread, so it only reads
/// atomics and preallocated memory — no allocation, locks or reference counting. This is the
/// kind of code that would sit naturally in C++; it is kept small so it stays easy to audit
/// in Swift.
final class MIDIEventQueue: @unchecked Sendable {
  struct Event {
    var sampleTime: Int64
    var bytes: (UInt8, UInt8, UInt8)
    var length: Int
  }

  static let capacity = 8192

  private let storage: UnsafeMutablePointer<Event>
  /// Advanced only by the producer (main thread).
  private let writeIndex = Atomic<Int>(0)
  /// Advanced only by the consumer (render thread).
  private let readIndex = Atomic<Int>(0)
  /// Set by the producer: the consumer skips everything before this index.
  private let flushIndex = Atomic<Int>(0)

  init() {
    storage = .allocate(capacity: MIDIEventQueue.capacity)
  }

  deinit {
    storage.deallocate()
  }

  // MARK: - Producer (main thread)

  /// Adds an event. Events must be pushed in time order. Returns `false` if the queue is
  /// full, in which case the event is dropped.
  @discardableResult
  func push(sampleTime: Int64, bytes: [UInt8]) -> Bool {
    guard (1...3).contains(bytes.count) else { return false }
    let write = writeIndex.load(ordering: .relaxed)
    let read = readIndex.load(ordering: .acquiring)
    guard write - read < MIDIEventQueue.capacity else { return false }
    storage[write % MIDIEventQueue.capacity] = Event(
      sampleTime: sampleTime,
      bytes: (bytes[0], bytes.count > 1 ? bytes[1] : 0, bytes.count > 2 ? bytes[2] : 0),
      length: bytes.count)
    writeIndex.store(write + 1, ordering: .releasing)
    return true
  }

  /// Drops every event that hasn't been delivered yet. Events pushed afterwards are kept.
  func flush() {
    flushIndex.store(writeIndex.load(ordering: .relaxed), ordering: .releasing)
  }

  // MARK: - Consumer (render thread)

  /// Delivers the events due before `endSampleTime` to the instrument.
  func deliver(before endSampleTime: Int64, to schedule: AUScheduleMIDIEventBlock) {
    var read = max(readIndex.load(ordering: .relaxed), flushIndex.load(ordering: .acquiring))
    let write = writeIndex.load(ordering: .acquiring)
    while read < write {
      var event = storage[read % MIDIEventQueue.capacity]
      guard event.sampleTime < endSampleTime else { break }
      withUnsafePointer(to: &event.bytes) { tuple in
        tuple.withMemoryRebound(to: UInt8.self, capacity: 3) { bytes in
          schedule(AUEventSampleTime(event.sampleTime), 0, event.length, bytes)
        }
      }
      read += 1
    }
    readIndex.store(read, ordering: .releasing)
  }

  /// A render observer that delivers this queue's events just before the instrument renders.
  static func makeRenderObserver(queue: MIDIEventQueue, schedule: @escaping AUScheduleMIDIEventBlock) -> AURenderObserver {
    { flags, timestamp, frameCount, _ in
      guard flags.contains(.unitRenderAction_PreRender) else { return }
      let end = Int64(timestamp.pointee.mSampleTime) + Int64(frameCount)
      queue.deliver(before: end, to: schedule)
    }
  }
}
