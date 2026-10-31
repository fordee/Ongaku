//
//  Metronome.swift
//  OngakuEngine
//

import AVFAudio
import OngakuCore

/// The metronome's sound (the app's Metronome settings).
public struct MetronomeSettings: Equatable, Sendable {
  public enum Sound: String, CaseIterable, Sendable {
    /// A short, bright sine blip.
    case click
    /// A hollow, knocking tone.
    case woodblock
    /// A burst of filtered noise, like a closed hi-hat.
    case hiHat
    /// A longer, softer electronic beep.
    case beep
  }

  public var sound: Sound
  /// 0 (silent) to 1 (full).
  public var level: Double
  /// Whether the first beat of each bar is higher and louder.
  public var accentsDownbeats: Bool

  public init(sound: Sound = .click, level: Double = 1, accentsDownbeats: Bool = true) {
    self.sound = sound
    self.level = level
    self.accentsDownbeats = accentsDownbeats
  }
}

/// Plays synthesized clicks at times supplied by a `PlaybackPlan`. Clicks go through a
/// `SampleChunkRing`, like audio regions, so the metronome starts with the rest of a run.
@MainActor
final class Metronome {
  let node: AVAudioSourceNode
  let format: AVAudioFormat
  private let ring: SampleChunkRing
  private var accentClick: [Float] = []
  private var beatClick: [Float] = []
  private var session = 0
  /// How long the metronome runs before playback time 0: the count-in.
  private var lead: Double = 0
  /// The longest click any sound makes, which sizes the ring's slots.
  private static let maximumClickSeconds = 0.08

  private(set) var settings = MetronomeSettings()

  /// `format` must be stereo.
  init?(format: AVAudioFormat) {
    guard format.channelCount == 2 else { return nil }
    self.format = format
    ring = SampleChunkRing(
      slotCount: 32, slotFrames: Int(format.sampleRate * Self.maximumClickSeconds), sampleRate: format.sampleRate)
    node = SampleChunkRing.makeSourceNode(rendering: ring, format: format)
    makeClicks()
  }

  var volume: Float {
    get { node.volume }
    set { node.volume = newValue }
  }

  /// Changes the sound; clicks already queued keep the old one.
  func configure(_ newSettings: MetronomeSettings) {
    guard newSettings != settings else { return }
    let soundChanged = newSettings.sound != settings.sound || newSettings.accentsDownbeats != settings.accentsDownbeats
    settings = newSettings
    if soundChanged {
      makeClicks()
    }
  }

  /// Starts a run at `startHostTime`. With a count-in, that is `lead` seconds before
  /// playback time 0, and clicks with negative playback times (the count-in) play first.
  func begin(session id: Int, startHostTime: UInt64, lead: Double = 0) {
    session = id
    self.lead = lead
    ring.begin(session: id, startHostTime: startHostTime)
  }

  func end() {
    session = 0
    ring.end()
  }

  func schedule(_ clicks: [PlaybackPlan.Click]) {
    guard session != 0 else { return }
    for click in clicks {
      let samples = click.isDownbeat ? accentClick : beatClick
      let start = Int64(((click.playbackTime + lead) * format.sampleRate).rounded())
      ring.enqueue(session: session, start: start) { left, right in
        samples.withUnsafeBufferPointer { click in
          guard let base = click.baseAddress else { return 0 }
          left.update(from: base, count: click.count)
          right.update(from: base, count: click.count)
          return click.count
        }
      }
    }
  }

  private func makeClicks() {
    let rate = format.sampleRate
    beatClick = Self.makeClick(settings.sound, accented: false, sampleRate: rate)
    accentClick = Self.makeClick(settings.sound, accented: settings.accentsDownbeats, sampleRate: rate)
  }

  /// One click of a sound. Accented clicks are pitched up and a little louder.
  static func makeClick(_ sound: MetronomeSettings.Sound, accented: Bool, sampleRate: Double) -> [Float] {
    let pitch = accented ? 4.0 / 3 : 1  // a fourth higher
    let amplitude = accented ? 0.5 : 0.35
    func samples(seconds: Double, _ value: (Double) -> Double) -> [Float] {
      (0..<Int(sampleRate * min(seconds, maximumClickSeconds))).map { Float(value(Double($0) / sampleRate)) }
    }
    switch sound {
    case .click:
      // A short sine burst with a fast exponential decay.
      return samples(seconds: 0.03) { t in sin(2 * .pi * 1_320 * pitch * t) * exp(-t * 150) * amplitude }
    case .woodblock:
      // Two inharmonic partials with a very fast decay sound hollow and wooden.
      return samples(seconds: 0.05) { t in
        (sin(2 * .pi * 880 * pitch * t) + 0.5 * sin(2 * .pi * 2_430 * pitch * t)) * exp(-t * 90) * amplitude * 0.8
      }
    case .hiHat:
      // Noise through a simple high-pass (the difference of successive samples), decaying fast.
      var generator = SplitMix(seed: accented ? 2 : 1)
      var previous = 0.0
      return samples(seconds: 0.04) { t in
        let noise = generator.nextUnit() * 2 - 1
        defer { previous = noise }
        return (noise - previous) * 0.5 * exp(-t * (accented ? 70 : 110)) * amplitude
      }
    case .beep:
      // A longer square-ish tone with a soft attack and release.
      return samples(seconds: 0.08) { t in
        let envelope = min(t / 0.004, 1) * max(0, 1 - t / 0.08)
        let phase = 2 * .pi * 990 * pitch * t
        return (sin(phase) + sin(3 * phase) / 3) * envelope * amplitude * 0.7
      }
    }
  }
}

/// A small, fast pseudo-random generator, so the hi-hat sounds the same every time.
private struct SplitMix {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  /// A value from 0 up to (but not including) 1.
  mutating func nextUnit() -> Double {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= z >> 31
    return Double(z >> 11) / Double(1 << 53)
  }
}
