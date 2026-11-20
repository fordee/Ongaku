//
//  SamplerZones.swift
//  OngakuEffects
//

import Foundation
import OngakuCore

/// One of the Sampler's zones: a sample and where on the keyboard it plays.
struct SamplerZone: Identifiable, @unchecked Sendable {
  let id: UUID
  let buffer: SamplerSampleBuffer
  var settings: SamplerZoneSettings

  init(id: UUID = UUID(), buffer: SamplerSampleBuffer, settings: SamplerZoneSettings = SamplerZoneSettings()) {
    self.id = id
    self.buffer = buffer
    self.settings = settings.clamped()
  }

  var name: String { buffer.name }

  /// The key it plays at its own pitch, given the Root Note knob's.
  func root(knob: Int) -> Int { settings.root ?? knob }

  // MARK: - Saved state

  private enum Key {
    static let sample = "sample", settings = "settings"
  }

  /// The zone as a property list: its sample (as `SamplerSampleBuffer.state`) and settings.
  var state: [String: Any] {
    [Key.sample: buffer.state, Key.settings: (try? JSONEncoder().encode(settings)) ?? Data()]
  }

  init?(state: [String: Any]) {
    guard let sample = state[Key.sample] as? [String: Any], let buffer = SamplerSampleBuffer(state: sample) else { return nil }
    let settings = (state[Key.settings] as? Data).flatMap { try? JSONDecoder().decode(SamplerZoneSettings.self, from: $0) }
    self.init(buffer: buffer, settings: settings ?? SamplerZoneSettings())
  }
}

/// The zones as the kernel reads them (`SamplerKeymap`), at fixed addresses, holding on to
/// their samples for as long as the kernel may read them.
final class SamplerKeymapBuffer: @unchecked Sendable {
  let keymap: UnsafeMutablePointer<SamplerKeymap>
  private let entries: UnsafeMutablePointer<SamplerKeyZone>
  private let buffers: [SamplerSampleBuffer]

  init(zones: [SamplerZone]) {
    buffers = zones.map(\.buffer)
    entries = .allocate(capacity: max(1, zones.count))
    for (index, zone) in zones.enumerated() {
      let settings = zone.settings
      entries.advanced(by: index).initialize(to: SamplerKeyZone(
        sample: zone.buffer.kernelSample.pointee, lowKey: Int32(settings.lowKey), highKey: Int32(settings.highKey),
        lowVelocity: Int32(settings.lowVelocity), highVelocity: Int32(settings.highVelocity), root: Int32(settings.root ?? -1),
        tune: Float(settings.tune), gain: Float(pow(10, settings.gain / 20)), pan: Float(settings.pan / 100)))
    }
    keymap = .allocate(capacity: 1)
    keymap.initialize(to: SamplerKeymap(zones: entries, count: Int32(zones.count)))
  }

  deinit {
    entries.deallocate()
    keymap.deallocate()
  }
}

/// What the Sampler's window shows about one zone.
struct SamplerZoneInfo: Identifiable, Equatable {
  let id: UUID
  let name: String
  let settings: SamplerZoneSettings
  let duration: Double
  let channelCount: Int
  let overview: [Float]
  let notice: String?
}
