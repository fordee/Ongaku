//
//  HostMusicalContext.swift
//  OngakuEngine
//

import AudioToolbox
import Darwin
import OngakuCore
import Synchronization

/// The song's tempo, time signature, position and transport, for plug-ins that follow them
/// (a delay synced to the beat, an arpeggiator, a drummer). The engine updates it as the
/// playhead moves; plug-ins read it from the render thread through `block` and
/// `transportStateBlock`.
///
/// During playback the engine only updates it every few tens of milliseconds, so the
/// position is anchored to a host time and carried forward at the tempo when a plug-in
/// asks: a beat that stood still between updates would make arpeggiators late and jumpy.
public final class HostMusicalContext: Sendable {
  struct State {
    var tempo = 120.0
    /// The position in quarter notes, at `hostTime`.
    var beat = 0.0
    /// When `beat` is heard, or 0 when the position doesn't move on by itself (stopped, or
    /// rendering offline).
    var hostTime: UInt64 = 0
    var numerator = 4
    var denominator = 4
    /// Where the bar containing `beat` starts, and how long bars are, in quarter notes.
    var barStart = 0.0
    var barLength = 4.0
    /// The position in seconds from the start of the song, at `hostTime`.
    var seconds = 0.0
    var sampleRate = 48_000.0
    var isPlaying = false
    var isRecording = false
    /// The cycle in quarter notes (and how long it lasts) while playback loops it.
    var cycle: (start: Double, end: Double, barStart: Double, seconds: Double)?
    /// Counts transport changes (start, stop, a jump), so plug-ins can be told of them.
    var generation = 0
  }

  private let state = Mutex(State())

  public init() {}

  // MARK: - Updates

  /// Takes the tempo, signature and position at `position` in the song. With a `hostTime`
  /// (when that position is heard), the position moves on at the tempo until the next update.
  public func update(at position: Tick, hostTime: UInt64 = 0, in tempoMap: TempoMap) {
    let bar = tempoMap.bar(containing: position)
    let signature = tempoMap.timeSignature(atBarIndex: bar.index)
    let tempo = tempoMap.tempo(at: position)
    let beat = Self.quarterNotes(position)
    let seconds = tempoMap.seconds(at: position)
    state.withLock { state in
      // A position that isn't where the last one was heading is a jump.
      if state.isPlaying, state.hostTime != 0, hostTime != 0 {
        let expected = Self.carriedForward(state, to: hostTime).beat
        if abs(expected - beat) > 0.25 { state.generation += 1 }
      }
      state.tempo = tempo
      state.beat = beat
      state.hostTime = hostTime
      state.numerator = signature.beatsPerBar
      state.denominator = signature.beatUnit
      state.barStart = Self.quarterNotes(bar.start)
      state.barLength = Double(signature.beatsPerBar) * 4 / Double(max(1, signature.beatUnit))
      state.seconds = seconds
    }
  }

  /// Takes whether the song is playing or recording, and the cycle it loops (if any).
  public func setTransport(isPlaying: Bool, isRecording: Bool = false, cycle: Range<Tick>? = nil, in tempoMap: TempoMap) {
    let cycleState = cycle.map { range in
      (
        start: Self.quarterNotes(range.lowerBound), end: Self.quarterNotes(range.upperBound),
        barStart: Self.quarterNotes(tempoMap.bar(containing: range.lowerBound).start),
        seconds: tempoMap.seconds(at: range.upperBound) - tempoMap.seconds(at: range.lowerBound)
      )
    }
    state.withLock { state in
      let cycleChanged = state.cycle?.start != cycleState?.start || state.cycle?.end != cycleState?.end
      if state.isPlaying != isPlaying || state.isRecording != isRecording || cycleChanged {
        state.generation += 1
      }
      state.isPlaying = isPlaying
      state.isRecording = isRecording
      state.cycle = cycleState
      if !isPlaying { state.hostTime = 0 }
    }
  }

  /// The sample rate plug-ins render at, for sample positions and offsets.
  public func setSampleRate(_ sampleRate: Double) {
    state.withLock { $0.sampleRate = sampleRate }
  }

  public var currentTempo: Double { state.withLock { $0.tempo } }

  // MARK: - Plug-ins

  /// Gives a plug-in the musical context and transport state blocks.
  public func attach(to audioUnit: AUAudioUnit) {
    audioUnit.musicalContextBlock = block
    audioUnit.transportStateBlock = transportStateBlock
  }

  /// The block Audio Units call for the musical context.
  public var block: AUHostMusicalContextBlock {
    let reader = Reader(context: self)
    return { tempoOut, numeratorOut, denominatorOut, beatOut, sampleOffsetOut, downbeatOut in
      guard let now = reader.read() else { return false }
      tempoOut?.pointee = now.tempo
      numeratorOut?.pointee = Double(now.numerator)
      denominatorOut?.pointee = now.denominator
      beatOut?.pointee = now.beat
      downbeatOut?.pointee = now.barStart
      if let sampleOffsetOut {
        // Samples until the next whole beat, while the song moves.
        let beatsToGo = now.beat.rounded(.up) - now.beat
        let offset = now.isPlaying && now.tempo > 0 ? beatsToGo * 60 / now.tempo * now.sampleRate : 0
        sampleOffsetOut.pointee = Int(offset.rounded())
      }
      return true
    }
  }

  /// The block Audio Units call for the transport state. `changed` is reported once to each
  /// plug-in after the song starts, stops, jumps or changes its cycle.
  public var transportStateBlock: AUHostTransportStateBlock {
    let reader = Reader(context: self)
    return { flagsOut, samplePositionOut, cycleStartOut, cycleEndOut in
      guard let now = reader.read() else { return false }
      if let flagsOut {
        var flags: AUHostTransportStateFlags = []
        if reader.takeChange(now.generation) { flags.insert(.changed) }
        if now.isPlaying { flags.insert(.moving) }
        if now.isRecording { flags.insert(.recording) }
        if now.cycle != nil { flags.insert(.cycling) }
        flagsOut.pointee = flags
      }
      samplePositionOut?.pointee = (now.seconds * now.sampleRate).rounded()
      cycleStartOut?.pointee = now.cycle?.start ?? 0
      cycleEndOut?.pointee = now.cycle?.end ?? 0
      return true
    }
  }

  /// The state for a plug-in rendering now: carried forward to the host time being rendered.
  /// The lock is only tried, never waited on, as the render thread mustn't block; if the
  /// engine happens to be holding it, the reader's last state is used again.
  fileprivate func current() -> State? {
    guard let state = state.withLockIfAvailable({ $0 }) else { return nil }
    return Self.carriedForward(state, to: mach_absolute_time())
  }

  /// `state` moved on at its tempo from its host time to `hostTime`: not by more than a
  /// fraction of a second (if updates stop, so does the song), and back round the cycle.
  static func carriedForward(_ state: State, to hostTime: UInt64) -> State {
    guard state.isPlaying, state.hostTime != 0, hostTime > state.hostTime, state.tempo > 0 else { return state }
    var state = state
    let elapsed = min(seconds(fromHostTime: hostTime - state.hostTime), 0.25)
    state.beat += elapsed * state.tempo / 60
    state.seconds += elapsed
    state.hostTime = hostTime
    if let cycle = state.cycle, cycle.end > cycle.start, state.beat >= cycle.end {
      state.beat -= cycle.end - cycle.start
      state.seconds -= cycle.seconds
      state.barStart = cycle.barStart
    }
    if state.barLength > 0, state.beat >= state.barStart + state.barLength {
      state.barStart += ((state.beat - state.barStart) / state.barLength).rounded(.down) * state.barLength
    }
    return state
  }

  private static func quarterNotes(_ position: Tick) -> Double {
    Double(position.rawValue) / Double(Tick.perQuarterNote)
  }

  private static let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
  }()

  private static func seconds(fromHostTime ticks: UInt64) -> Double {
    Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
  }
}

/// One plug-in's view of the context: its last state (for when the lock is busy), and the
/// last transport change it was told of. Each block is called by one render thread at a time.
private final class Reader: @unchecked Sendable {
  private let context: HostMusicalContext
  private var last: HostMusicalContext.State?
  private var seenGeneration = 0

  init(context: HostMusicalContext) {
    self.context = context
  }

  func read() -> HostMusicalContext.State? {
    if let now = context.current() {
      last = now
      return now
    }
    return last.map { HostMusicalContext.carriedForward($0, to: mach_absolute_time()) }
  }

  /// Whether the transport changed since this plug-in last asked.
  func takeChange(_ generation: Int) -> Bool {
    defer { seenGeneration = generation }
    return generation != seenGeneration
  }
}
