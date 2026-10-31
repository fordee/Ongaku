//
//  SampleChunkRing.swift
//  OngakuEngine
//

import Accelerate
import AudioToolbox
import Darwin
import Synchronization

/// Chunks of stereo samples handed from a producer (a background reader, or the main thread
/// for the metronome) to the audio render thread, which plays each at an exact sample in the
/// current run of the transport.
///
/// This replaces `AVAudioPlayerNode` for live playback. Starting or stopping a player node
/// blocks the caller for about one audio buffer, so with dozens of audio tracks pressing Play
/// froze the interface for a third of a second, and players started after their shared start
/// time began late and played out of sync. Here starting and stopping are atomic stores:
///
/// - `begin(session:startHostTime:)` starts a run of the transport. On its first render of
///   that run, the render thread works out its own sample time for the start host time, once;
///   every source does the same, so all of them line up on the same first sample. Chunks are
///   then placed by counting samples from there, so consecutive chunks join exactly.
/// - `end()` stops: the render thread drops the run's chunks at its next render.
/// - Chunks for a run that hasn't begun yet are kept, so a run's first audio can be read
///   before its start time is fixed (see `PlaybackEngine.startPlayback`). Runs are numbered
///   in order, so anything from an earlier or ended run is dropped.
/// - A chunk that arrives late plays from where it should be by now, staying in sync.
///
/// Real-time rules: `render` runs on the audio thread, so it only reads atomics and
/// preallocated memory — no allocation, locks or reference counting. This is the code that
/// would sit naturally in C or C++; it's kept small so it stays easy to audit in Swift.
///
/// Each slot is owned by one side at a time: the producer fills a free slot and then marks
/// it ready; the render thread plays a ready slot and marks it free once it has played (or
/// belongs to a run that has ended). There is one producer per ring.
final class SampleChunkRing: @unchecked Sendable {
  private struct Slot {
    var session: Int
    /// The chunk's first frame, counted from the start of its run.
    var start: Int64
    var frameCount: Int
  }

  /// State only the render thread touches.
  private struct RenderState {
    var anchoredSession = 0
    /// The render thread's sample time at the start of the anchored run.
    var anchorSample: Int64 = 0
  }

  private enum SlotState {
    static let free = 0
    static let ready = 1
  }

  let slotCount: Int
  let slotFrames: Int
  let sampleRate: Double

  /// Left then right samples for every slot: slot `i` channel `c` starts at
  /// `(i * 2 + c) * slotFrames`.
  private let samples: UnsafeMutablePointer<Float>
  private let slots: UnsafeMutablePointer<Slot>
  private let states: UnsafeMutablePointer<Atomic<Int>>
  /// Whether the render thread has started playing each ready slot (render thread only).
  private let started: UnsafeMutablePointer<Bool>
  private let renderState: UnsafeMutablePointer<RenderState>

  /// The run being played, or 0 when stopped. Written by the main thread.
  private let session = Atomic<Int>(0)
  /// The latest run that has ended; its chunks, and earlier runs', are dropped.
  private let endedSession = Atomic<Int>(0)
  private let sessionStartHostTime = Atomic<UInt64>(0)
  /// How far the render thread has played, published for the reader's look-ahead.
  private let renderedSession = Atomic<Int>(0)
  private let renderedUntil = Atomic<Int64>(0)
  /// Frames that were due before they arrived and so weren't heard. Should stay 0.
  private let missed = Atomic<Int>(0)
  private let secondsPerHostTick: Double

  init(slotCount: Int, slotFrames: Int, sampleRate: Double) {
    self.slotCount = slotCount
    self.slotFrames = slotFrames
    self.sampleRate = sampleRate
    samples = .allocate(capacity: slotCount * 2 * slotFrames)
    samples.initialize(repeating: 0, count: slotCount * 2 * slotFrames)
    slots = .allocate(capacity: slotCount)
    slots.initialize(repeating: Slot(session: 0, start: 0, frameCount: 0), count: slotCount)
    states = .allocate(capacity: slotCount)
    for index in 0..<slotCount {
      (states + index).initialize(to: Atomic(SlotState.free))
    }
    started = .allocate(capacity: slotCount)
    started.initialize(repeating: false, count: slotCount)
    renderState = .allocate(capacity: 1)
    renderState.initialize(to: RenderState())
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    secondsPerHostTick = Double(timebase.numer) / Double(timebase.denom) / 1e9
  }

  deinit {
    samples.deallocate()
    slots.deallocate()
    states.deinitialize(count: slotCount)
    states.deallocate()
    started.deallocate()
    renderState.deallocate()
  }

  // MARK: - Transport (main thread)

  /// Starts a run of the transport whose first frame plays at `startHostTime`. `session`
  /// must differ from every earlier run's and not be 0.
  func begin(session id: Int, startHostTime: UInt64) {
    sessionStartHostTime.store(startHostTime, ordering: .relaxed)
    session.store(id, ordering: .releasing)
  }

  /// Stops: whatever is queued is dropped at the next render.
  func end() {
    let current = session.load(ordering: .relaxed)
    if current != 0 {
      endedSession.store(current, ordering: .releasing)
    }
    session.store(0, ordering: .releasing)
  }

  // MARK: - Producer

  /// Fills a free slot with a chunk of a run and hands it to the render thread. `fill` gets
  /// the left and right sample buffers (`slotFrames` long) and returns how many frames it
  /// wrote. Returns `false` if every slot is in use.
  @discardableResult
  func enqueue(session id: Int, start: Int64, fill: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>) -> Int) -> Bool {
    for index in 0..<slotCount where states[index].load(ordering: .acquiring) == SlotState.free {
      let left = samples + index * 2 * slotFrames
      let frameCount = min(max(fill(left, left + slotFrames), 0), slotFrames)
      guard frameCount > 0 else { return true }
      slots[index] = Slot(session: id, start: start, frameCount: frameCount)
      states[index].store(SlotState.ready, ordering: .releasing)
      return true
    }
    return false
  }

  /// How many slots are free for the producer.
  var freeSlotCount: Int {
    (0..<slotCount).count { states[$0].load(ordering: .acquiring) == SlotState.free }
  }

  /// How far into a run the render thread has played, or `nil` if it hasn't rendered it yet.
  func playedUntil(session id: Int) -> Int64? {
    let until = renderedUntil.load(ordering: .acquiring)
    return renderedSession.load(ordering: .acquiring) == id ? until : nil
  }

  /// Adds to the count of frames that couldn't be played on time.
  func recordMissed(_ frames: Int) {
    missed.wrappingAdd(frames, ordering: .relaxed)
  }

  var missedFrames: Int {
    missed.load(ordering: .relaxed)
  }

  // MARK: - Render thread

  /// Mixes the chunks due in this render cycle into a stereo, non-interleaved buffer list.
  /// Returns `false` if nothing was written (the output is then silent).
  func render(timestamp: UnsafePointer<AudioTimeStamp>, frameCount: Int, into bufferList: UnsafeMutablePointer<AudioBufferList>) -> Bool {
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    guard buffers.count > 0, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return false }
    let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
    vDSP_vclr(left, 1, vDSP_Length(frameCount))
    if let right { vDSP_vclr(right, 1, vDSP_Length(frameCount)) }

    let current = session.load(ordering: .acquiring)
    let ended = endedSession.load(ordering: .acquiring)
    guard current != 0 else {
      dropStale(ended: ended)
      return false
    }

    let time = timestamp.pointee
    let sampleTime = Int64(time.mSampleTime)
    var state = renderState.pointee
    if state.anchoredSession != current {
      // Work out where the run starts in this node's timeline, once per run.
      let startHost = sessionStartHostTime.load(ordering: .relaxed)
      if time.mFlags.contains(.hostTimeValid) {
        let ticks = Int64(bitPattern: startHost &- time.mHostTime)
        state.anchorSample = sampleTime + Int64((Double(ticks) * secondsPerHostTick * sampleRate).rounded())
      } else {
        state.anchorSample = sampleTime
      }
      state.anchoredSession = current
      renderState.pointee = state
    }

    let cycleStart = sampleTime - state.anchorSample
    let cycleEnd = cycleStart + Int64(frameCount)
    var wrote = false
    for index in 0..<slotCount where states[index].load(ordering: .acquiring) == SlotState.ready {
      let slot = slots[index]
      guard slot.session == current else {
        // An earlier run's chunk is dropped; a later run's waits for its run to begin.
        if slot.session < current || slot.session <= ended {
          releaseSlot(index)
        }
        continue
      }
      let end = slot.start + Int64(slot.frameCount)
      guard end > cycleStart else {
        // Arrived after it should have finished playing.
        missed.wrappingAdd(slot.frameCount, ordering: .relaxed)
        releaseSlot(index)
        continue
      }
      guard slot.start < cycleEnd else { continue }
      if !started[index] {
        // Arrived after it should have started: play the rest, in time.
        if slot.start < cycleStart {
          missed.wrappingAdd(Int(cycleStart - slot.start), ordering: .relaxed)
        }
        started[index] = true
      }
      let from = max(slot.start, cycleStart)
      let to = min(end, cycleEnd)
      let count = Int(to - from)
      let source = samples + index * 2 * slotFrames + Int(from - slot.start)
      let destination = Int(from - cycleStart)
      add(source, to: left + destination, count: count)
      if let right {
        add(source + slotFrames, to: right + destination, count: count)
      }
      wrote = true
      if end <= cycleEnd {
        releaseSlot(index)
      }
    }
    renderedUntil.store(cycleEnd, ordering: .releasing)
    renderedSession.store(current, ordering: .releasing)
    return wrote
  }

  /// Hands a slot back to the producer (render thread).
  private func releaseSlot(_ index: Int) {
    started[index] = false
    states[index].store(SlotState.free, ordering: .releasing)
  }

  /// While stopped: drops chunks of ended runs, keeping any read ahead for the next run.
  private func dropStale(ended: Int) {
    for index in 0..<slotCount where states[index].load(ordering: .acquiring) == SlotState.ready {
      if slots[index].session <= ended {
        releaseSlot(index)
      }
    }
    renderedSession.store(0, ordering: .releasing)
  }

  /// Accelerate, so mixing stays fast even in unoptimized debug builds.
  private func add(_ source: UnsafePointer<Float>, to destination: UnsafeMutablePointer<Float>, count: Int) {
    vDSP_vadd(source, 1, destination, 1, destination, 1, vDSP_Length(count))
  }
}
