//
//  LoopPreviewEngine.swift
//  OngakuEngine
//

import AVFAudio
import Foundation

/// Plays sounds from the Loop Browser before they're added: a loop repeats at the song's
/// tempo and in its key (real-time, with Apple's time-pitch unit), a one-shot plays once.
/// It has its own small engine, so previewing never touches the song's playback graph.
@MainActor
public final class LoopPreviewEngine {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let timePitch = AVAudioUnitTimePitch()
  private var connectedFormat: AVAudioFormat?
  /// Counts previews, so a finished one-shot's callback doesn't stop a newer preview.
  private var generation = 0
  /// Called on the main actor when a one-shot finishes playing by itself.
  public var onFinish: (() -> Void)?

  /// Longer files are previewed from their first minute only.
  static let maximumSeconds = 60.0

  public init() {
    engine.attach(player)
    engine.attach(timePitch)
  }

  public var isPlaying: Bool { player.isPlaying }

  /// Plays `url` (repeating if `loops`) `rate` times as fast, `semitones` higher, through the
  /// output device with `deviceUID` (or the system's).
  public func play(_ url: URL, loops: Bool, rate: Double = 1, semitones: Int = 0, deviceUID: String?) throws {
    stop()
    let file = try AVAudioFile(forReading: url)
    let format = file.processingFormat
    let frames = AVAudioFrameCount(min(Double(file.length), Self.maximumSeconds * format.sampleRate))
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
    try file.read(into: buffer, frameCount: frames)

    if connectedFormat != format {
      engine.disconnectNodeOutput(player)
      engine.disconnectNodeOutput(timePitch)
      try engine.connectNode(player, to: timePitch, format: format)
      try engine.connectNode(timePitch, to: engine.mainMixerNode, format: format)
      connectedFormat = format
    }
    if let deviceUID, let device = AudioOutputDevice.hardwareDevice(uid: deviceUID),
      engine.outputNode.withAUAudioUnit({ $0.deviceID }) != device.id
    {
      engine.stop()
      engine.outputNode.withAUAudioUnit { try? $0.setDeviceID(device.id) }
    }
    timePitch.rate = Float(min(max(rate, 1.0 / 32), 32))
    timePitch.pitch = Float(semitones * 100)
    if !engine.isRunning {
      engine.prepare()
      try engine.start()
    }

    generation += 1
    let current = generation
    if loops {
      player.scheduleBuffer(buffer, at: nil, options: .loops)
    } else {
      player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.generation == current else { return }
          self.onFinish?()
        }
      }
    }
    try player.playAudio()
  }

  public func stop() {
    generation += 1
    player.stop()
  }

  /// Stops the engine too, releasing the output device.
  public func shutDown() {
    stop()
    engine.stop()
  }
}
