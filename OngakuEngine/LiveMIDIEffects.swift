//
//  LiveMIDIEffects.swift
//  OngakuEngine
//

import AVFAudio
import Foundation
import OngakuCore

/// Plays a MIDI keyboard through a track's MIDI effects, live.
///
/// Keys held and recently let go are notes on a running timeline (the song's, while it
/// plays, so the Arpeggiator stays on its grid; otherwise a clock started by the first key).
/// The effects are applied to them over and over, a few times a hundredth of a second, with
/// held notes lasting until just past the look-ahead; what comes out that wasn't played yet is
/// scheduled at its exact time, and its end once the note it came from is let go.
@MainActor
final class LiveMIDIEffects {
  var effects: [MIDIEffect]
  /// Plays MIDI bytes at a host time (`nil` is now).
  private let play: ([UInt8], UInt64?) -> Void
  /// Where the song is at a host time, while it plays.
  private let songPosition: (UInt64) -> Tick?
  private let tempo: () -> Double

  private struct Key: Hashable {
    var pitch: Int
    var channel: Int
  }

  private struct OutputKey: Hashable {
    var start: Tick
    var pitch: Int
    var channel: Int
  }

  /// Keys down, with when they went down.
  private var held: [Key: EffectNote] = [:]
  /// Keys let go during this phrase (the Arpeggiator counts its pattern from the phrase's
  /// first key).
  private var released: [EffectNote] = []
  /// Notes the effects made that have started and not yet been stopped.
  private var sounding: [OutputKey: EffectNote] = [:]
  /// Notes played and stopped this phrase, so they aren't played again.
  private var finished: Set<OutputKey> = []
  /// The timeline: a tick at a host time.
  private var origin: (tick: Tick, hostTime: UInt64)?
  private var timer: Timer?

  /// How far ahead notes are scheduled.
  private static let lookAhead = 0.06
  /// How long after the last note the phrase ends (and the timeline starts again).
  private static let phraseGap = 1.0

  init(
    effects: [MIDIEffect], play: @escaping ([UInt8], UInt64?) -> Void, songPosition: @escaping (UInt64) -> Tick?,
    tempo: @escaping () -> Double
  ) {
    self.effects = effects
    self.play = play
    self.songPosition = songPosition
    self.tempo = tempo
  }

  deinit {
    timer?.invalidate()
  }

  /// Whether any effect would change what's played (if not, input goes straight through).
  static func isActive(_ effects: [MIDIEffect]) -> Bool {
    effects.contains { !$0.isBypassed }
  }

  // MARK: - Input

  /// A message from a MIDI keyboard. Notes go through the effects; anything else (the
  /// sustain pedal, pitch bend) goes straight on.
  func receive(_ bytes: [UInt8], at hostTime: UInt64) {
    guard bytes.count == 3 else {
      play(bytes, nil)
      return
    }
    let kind = bytes[0] & 0xF0, channel = Int(bytes[0] & 0x0F), pitch = Int(bytes[1]), velocity = Int(bytes[2])
    switch kind {
    case 0x90 where velocity > 0:
      if origin == nil { startTimeline(at: hostTime) }
      let key = Key(pitch: pitch, channel: channel)
      if let earlier = held.removeValue(forKey: key) { release(earlier, at: hostTime) }
      held[key] = EffectNote(start: tick(at: hostTime), end: tick(at: hostTime) + Tick(1), pitch: pitch, velocity: velocity, channel: channel)
      startTimer()
    case 0x80, 0x90:
      guard let note = held.removeValue(forKey: Key(pitch: pitch, channel: channel)) else { return }
      release(note, at: hostTime)
    default:
      play(bytes, nil)
      return
    }
    update()
  }

  private func release(_ note: EffectNote, at hostTime: UInt64) {
    var ended = note
    ended.end = max(note.start + Tick(1), tick(at: hostTime))
    released.append(ended)
  }

  /// Stops everything sounding (the transport stopped, the track changed).
  func stopAll() {
    for note in sounding.values {
      play([0x80 | UInt8(note.channel & 0x0F), UInt8(note.pitch), 0], nil)
    }
    sounding = [:]
    finished = []
    held = [:]
    released = []
    origin = nil
    timer?.invalidate()
    timer = nil
  }

  // MARK: - The timeline

  private func startTimeline(at hostTime: UInt64) {
    // While the song plays, the song's own position, so timed effects stay on its grid.
    origin = (songPosition(hostTime) ?? .zero, hostTime)
  }

  private var ticksPerSecond: Double { max(1, tempo()) / 60 * Double(Tick.perQuarterNote) }

  private func tick(at hostTime: UInt64) -> Tick {
    guard let origin else { return .zero }
    let seconds = hostTime >= origin.hostTime
      ? AVAudioTime.seconds(forHostTime: hostTime - origin.hostTime)
      : -AVAudioTime.seconds(forHostTime: origin.hostTime - hostTime)
    return origin.tick + Tick(Int64((seconds * ticksPerSecond).rounded()))
  }

  private func hostTime(at tick: Tick) -> UInt64 {
    guard let origin else { return mach_absolute_time() }
    let seconds = Double((tick - origin.tick).rawValue) / ticksPerSecond
    return seconds >= 0 ? origin.hostTime + AVAudioTime.hostTime(forSeconds: seconds) : origin.hostTime
  }

  private func startTimer() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.update() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  // MARK: - Scheduling

  /// Works out what the effects play now and over the look-ahead, and schedules what's new.
  func update() {
    guard origin != nil else { return }
    let now = mach_absolute_time()
    let nowTick = tick(at: now)
    let horizon = tick(at: now + AVAudioTime.hostTime(forSeconds: Self.lookAhead))
    // Held notes last until just past the look-ahead, for now.
    let open = horizon + Tick(1)
    let input = released + held.values.map { note in
      var stillHeld = note
      stillHeld.end = open
      return stillHeld
    }
    let output = effects.process(input)
    var current: [OutputKey: EffectNote] = [:]
    for note in output where note.start < horizon {
      current[OutputKey(start: note.start, pitch: note.pitch, channel: note.channel)] = note
    }

    // New notes start (any due already, straight away).
    for (key, note) in current where sounding[key] == nil && !finished.contains(key) && note.end > nowTick {
      play([0x90 | UInt8(note.channel & 0x0F), UInt8(note.pitch), UInt8(note.velocity)], note.start <= nowTick ? nil : hostTime(at: note.start))
      sounding[key] = note
    }
    // Notes whose end is now known (they don't run to the open end any more) stop then;
    // notes the effects no longer make (a key let go early) stop now.
    for (key, note) in sounding {
      guard let latest = current[key] else {
        // Stopped now, or (if it was scheduled and hasn't started) just after it starts.
        play([0x80 | UInt8(note.channel & 0x0F), UInt8(note.pitch), 0], key.start >= nowTick ? hostTime(at: key.start + Tick(1)) : nil)
        sounding[key] = nil
        finished.insert(key)
        continue
      }
      if latest.end < open {
        play([0x80 | UInt8(note.channel & 0x0F), UInt8(note.pitch), 0], latest.end <= nowTick ? nil : hostTime(at: latest.end))
        sounding[key] = nil
        finished.insert(key)
      } else {
        sounding[key] = latest
      }
    }

    // The phrase ends once nothing is held or sounding for a while: the timeline (and an
    // arpeggio's pattern) starts again with the next key.
    let lastEnd = released.map(\.end).max() ?? .zero
    if held.isEmpty, sounding.isEmpty, nowTick > lastEnd + Tick(Int64(ticksPerSecond * Self.phraseGap)) {
      released = []
      finished = []
      origin = nil
      timer?.invalidate()
      timer = nil
    }
  }
}
