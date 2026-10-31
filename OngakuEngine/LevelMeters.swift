//
//  LevelMeters.swift
//  OngakuEngine
//

import Accelerate
import AVFAudio
import Foundation
import OngakuCore
import Synchronization

/// Peak levels for the mixer's meters.
///
/// Each channel's fader output (and Stereo Out) has a tap that stores the loudest sample of
/// every buffer. The tap block can run on the audio thread, so it only does arithmetic and
/// writes atomics on a meter it captured directly — no locks or dictionary lookups. The
/// interface reads levels about 30 times a second and draws its own fall-off.
public final class LevelMeters: Sendable {
  /// The meter identifier for Stereo Out.
  public static let masterID = Project.stereoOutID

  public struct Level: Sendable, Equatable {
    /// Peak of the most recent buffer, per channel, as linear gain.
    public var left: Float
    public var right: Float

    public static let silent = Level(left: 0, right: 0)

    /// The louder side in decibels, floored at -60 dB.
    public var peakDecibels: Float {
      let peak = max(left, right)
      return peak > 0.001 ? 20 * log10(peak) : -60
    }
  }

  /// One meter's latest peaks, stored as float bit patterns so they can be written without
  /// locking.
  private final class Meter: Sendable {
    let left = Atomic<UInt32>(0)
    let right = Atomic<UInt32>(0)

    var level: Level {
      Level(
        left: Float(bitPattern: left.load(ordering: .relaxed)),
        right: Float(bitPattern: right.load(ordering: .relaxed)))
    }

    func store(left newLeft: Float, right newRight: Float) {
      left.store(newLeft.bitPattern, ordering: .relaxed)
      right.store(newRight.bitPattern, ordering: .relaxed)
    }
  }

  /// Registered meters. Only touched when meters are added, removed or read, never from a tap.
  private let meters = Mutex<[UUID: Meter]>([:])

  public init() {}

  public func level(for id: UUID) -> Level {
    meters.withLock { $0[id] }?.level ?? .silent
  }

  /// Starts metering a node's output.
  func meter(_ node: AVAudioNode, as id: UUID) {
    let meter = Meter()
    meters.withLock { $0[id] = meter }
    do {
      try node.installAudioTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
        func peak(_ channel: Int) -> Float {
          guard case .float(let samples) = buffer.channelData(channel) else { return 0 }
          var peak: Float = 0
          samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress, !pointer.isEmpty else { return }
            vDSP_maxmgv(base, 1, &peak, vDSP_Length(pointer.count))
          }
          return peak
        }
        let left = peak(0)
        let right = buffer.format.channelCount > 1 ? peak(1) : left
        meter.store(left: left, right: right)
      }
    } catch {
      meters.withLock { $0[id] = nil }
    }
  }

  func stopMetering(_ node: AVAudioNode, as id: UUID) {
    node.removeTap(onBus: 0)
    meters.withLock { $0[id] = nil }
  }
}
