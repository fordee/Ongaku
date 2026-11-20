//
//  SamplerZoneLayout.swift
//  OngakuCore
//

import Foundation

/// Where one of the Sampler's zones plays, as Logic's Sampler maps them: a range of keys and
/// of velocities, the key that plays its sample at its own pitch, and its tuning, level and
/// pan. Zones that overlap play together (layers).
public struct SamplerZoneSettings: Codable, Equatable, Hashable, Sendable {
  public var lowKey: Int
  public var highKey: Int
  /// Velocities 1–127 (0 is a note off).
  public var lowVelocity: Int
  public var highVelocity: Int
  /// The key that plays the sample at its own pitch; nil follows the Sampler's Root Note
  /// knob (as a single sample loaded the usual way does).
  public var root: Int?
  /// Cents, −100 to +100.
  public var tune: Double
  /// Decibels, −24 to +12.
  public var gain: Double
  /// −100 (left) to +100 (right).
  public var pan: Double

  public init(
    lowKey: Int = 0, highKey: Int = 127, lowVelocity: Int = 1, highVelocity: Int = 127, root: Int? = nil, tune: Double = 0,
    gain: Double = 0, pan: Double = 0
  ) {
    self.lowKey = lowKey
    self.highKey = highKey
    self.lowVelocity = lowVelocity
    self.highVelocity = highVelocity
    self.root = root
    self.tune = tune
    self.gain = gain
    self.pan = pan
  }

  public static let keys = 0...127
  public static let velocities = 1...127

  /// The whole keyboard at every velocity, following the Root Note knob: a single sample.
  public var isWholeKeyboard: Bool { self == SamplerZoneSettings() }

  public func plays(note: Int, velocity: Int) -> Bool {
    (lowKey...highKey).contains(note) && (lowVelocity...highVelocity).contains(velocity)
  }

  /// The same settings with every value in range and each range the right way round.
  public func clamped() -> SamplerZoneSettings {
    var settings = self
    func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int { min(range.upperBound, max(range.lowerBound, value)) }
    settings.lowKey = clamp(lowKey, Self.keys)
    settings.highKey = clamp(highKey, Self.keys)
    if settings.highKey < settings.lowKey { swap(&settings.lowKey, &settings.highKey) }
    settings.lowVelocity = clamp(lowVelocity, Self.velocities)
    settings.highVelocity = clamp(highVelocity, Self.velocities)
    if settings.highVelocity < settings.lowVelocity { swap(&settings.lowVelocity, &settings.highVelocity) }
    settings.root = root.map { clamp($0, Self.keys) }
    settings.tune = min(100, max(-100, tune))
    settings.gain = min(12, max(-24, gain))
    settings.pan = min(100, max(-100, pan))
    return settings
  }
}

/// Lays samples out across the keyboard, as Logic's Sampler does when you drop several on it.
public enum SamplerZoneLayout {
  /// What the layout needs to know about a sample.
  public struct Sample: Sendable {
    /// The note it plays, or nil when it hasn't a clear pitch (a drum, a noise).
    public var root: Int?
    /// How loud it is (its peak), to order velocity layers: the quietest plays softest.
    public var level: Float

    public init(root: Int?, level: Float = 1) {
      self.root = root
      self.level = level
    }
  }

  /// The zones for `samples`, in the same order:
  /// - Pitched samples each play from their root note to halfway to the next one up and
  ///   down, the lowest down to the bottom of the keyboard and the highest to the top.
  /// - Samples with the same root share its keys as velocity layers, the quietest softest.
  /// - Samples without a pitch each get a key of their own, from `firstUnpitchedKey` up (C1,
  ///   where drums start), playing at their own pitch there.
  public static func map(_ samples: [Sample], firstUnpitchedKey: Int = 36) -> [SamplerZoneSettings] {
    var zones = [SamplerZoneSettings](repeating: SamplerZoneSettings(), count: samples.count)
    let pitched = samples.indices.filter { samples[$0].root != nil }
    let roots = Array(Set(pitched.compactMap { samples[$0].root.map { min(127, max(0, $0)) } })).sorted()
    for (position, root) in roots.enumerated() {
      let low = position == 0 ? 0 : (roots[position - 1] + root) / 2 + 1
      let high = position == roots.count - 1 ? 127 : (root + roots[position + 1]) / 2
      let layers = pitched.filter { samples[$0].root.map { min(127, max(0, $0)) } == root }
        .sorted { samples[$0].level < samples[$1].level }
      for (layer, index) in layers.enumerated() {
        zones[index] = SamplerZoneSettings(
          lowKey: low, highKey: high, lowVelocity: 1 + 127 * layer / layers.count, highVelocity: 127 * (layer + 1) / layers.count,
          root: root)
      }
    }
    var key = firstUnpitchedKey
    for index in samples.indices where samples[index].root == nil {
      let note = min(127, key)
      zones[index] = SamplerZoneSettings(lowKey: note, highKey: note, root: note)
      key += 1
    }
    return zones
  }

  /// New zones fitted around the ones already there: each keeps only the keys around its
  /// root that no existing zone plays (or just its root, if that's taken), so adding
  /// samples doesn't layer them over what's there.
  public static func fit(_ new: [SamplerZoneSettings], around existing: [SamplerZoneSettings]) -> [SamplerZoneSettings] {
    var taken = Set<Int>()
    for zone in existing { taken.formUnion(zone.lowKey...zone.highKey) }
    return new.map { zone in
      var zone = zone
      let root = zone.root ?? zone.lowKey
      guard !taken.contains(root) else {
        zone.lowKey = root
        zone.highKey = root
        return zone
      }
      var low = root, high = root
      while low > zone.lowKey, !taken.contains(low - 1) { low -= 1 }
      while high < zone.highKey, !taken.contains(high + 1) { high += 1 }
      zone.lowKey = low
      zone.highKey = high
      return zone
    }
  }

  /// The note named in a file name, the way sample libraries name their files ("Piano C3",
  /// "Bass_F#1_mf", "Strings-Eb2"), with middle C as C3 as in the Piano Roll. The last
  /// note name wins, as it usually comes after the instrument's name.
  public static func root(fromName name: String) -> Int? {
    let pattern = /(?:^|[^A-Za-z0-9])([A-Ga-g])([#♯b♭]?)(-?[0-9])(?![0-9])/
    guard let match = name.matches(of: pattern).last else { return nil }
    let classes: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    guard let letter = match.output.1.uppercased().first, let pitchClass = classes[letter], let octave = Int(match.output.3)
    else { return nil }
    let accidental = switch match.output.2 {
    case "#", "♯": 1
    case "b", "♭": -1
    default: 0
    }
    let note = (octave + 2) * 12 + pitchClass + accidental
    return SamplerZoneSettings.keys.contains(note) ? note : nil
  }
}
