//
//  AudioDevices.swift
//  OngakuEngine
//

import CoreAudio
import Foundation

/// An audio output device, for choosing where Ongaku plays.
public struct AudioOutputDevice: Identifiable, Hashable, Sendable {
  /// Core Audio's unique ID for the device, which stays the same across launches.
  public var uid: String
  public var name: String
  public var sampleRate: Double
  /// The I/O buffer sizes the device accepts, in frames.
  public var bufferSizeRange: ClosedRange<Int>
  public var id: String { uid }

  /// The devices that can play audio, by name. Devices that are currently unusable (no
  /// sample rate, such as an aggregate whose parts are missing) are left out.
  public static func all() -> [AudioOutputDevice] {
    let devices = (try? AudioHardwareSystem.shared.devices) ?? []
    return devices.compactMap { device -> AudioOutputDevice? in
      guard let streams = try? device.streams, streams.contains(where: { (try? $0.direction) == .output }),
        let uid = try? device.uid, let name = try? device.name,
        let rate = try? device.nominalSampleRate, rate > 0
      else { return nil }
      let range = (try? device.bufferFrameSizeRange).map { Int($0.mMinimum)...Int($0.mMaximum) } ?? 14...4096
      return AudioOutputDevice(uid: uid, name: name, sampleRate: rate, bufferSizeRange: range)
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// The device macOS plays through by default (System Settings › Sound).
  public static func systemDefault() -> AudioOutputDevice? {
    guard let uid = try? AudioHardwareSystem.shared.defaultOutputDevice?.uid else { return nil }
    return all().first { $0.uid == uid }
  }

  /// The Core Audio object for a device, if it's connected.
  static func hardwareDevice(uid: String) -> AudioHardwareDevice? {
    try? AudioHardwareSystem.shared.device(forUID: uid)
  }
}
