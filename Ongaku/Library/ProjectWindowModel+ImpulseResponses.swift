//
//  ProjectWindowModel+ImpulseResponses.swift
//  Ongaku
//

import AVFAudio
import OngakuCore
import OngakuEngine
import SwiftUI

extension ProjectWindowModel {
  /// The settings key the Convolution Reverb keeps a loaded impulse response under, and how
  /// long a response it uses.
  static let impulseStateKey = "ongakuImpulse"
  static let maximumImpulseSeconds = 8.0

  /// Gives a Convolution Reverb insert the impulse response in `url`, as one undo step.
  func useImpulseResponse(at url: URL, forInsert pluginID: PluginReference.ID, on channelID: Track.ID) throws {
    let current = engine.insertState(pluginID, onTrack: channelID) ?? plugin(pluginID, on: channelID)?.state
    var state = current.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
    state[Self.impulseStateKey] = try Self.impulseState(contentsOf: url)
    let data = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    // Undo goes back to the settings the reverb has now, which reach the song only when its
    // window closes: store them first, as saving does.
    if let current {
      var settled = project
      try? SetPluginState(current, forPlugin: pluginID, on: channelID).apply(to: &settled)
      document.editor.load(settled)
    }
    perform(SetPluginState(data, forPlugin: pluginID, on: channelID))
  }

  private func plugin(_ pluginID: PluginReference.ID, on channelID: Track.ID) -> PluginReference? {
    let inserts = channelID == Project.stereoOutID ? project.stereoOutInserts : project.track(withID: channelID)?.channel.inserts
    return inserts?.first { $0.id == pluginID }
  }

  /// An impulse response as the reverb keeps it: its name, sample rate, and up to two
  /// channels of 32-bit floats one after the other, at most 8 seconds.
  nonisolated static func impulseState(contentsOf url: URL) throws -> [String: Any] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let format = file.processingFormat
    let frames = AVAudioFrameCount(min(Double(file.length), maximumImpulseSeconds * format.sampleRate))
    guard frames > 1, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    try file.read(into: buffer, frameCount: frames)
    guard let channels = buffer.floatChannelData, buffer.frameLength > 1 else { throw CocoaError(.fileReadCorruptFile) }
    let channelCount = min(2, Int(format.channelCount))
    var audio = Data(capacity: Int(buffer.frameLength) * channelCount * MemoryLayout<Float>.size)
    for channel in 0..<channelCount {
      audio.append(UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)))
    }
    return [
      "name": url.deletingPathExtension().lastPathComponent, "sampleRate": format.sampleRate,
      "channels": channelCount, "audio": audio,
    ]
  }
}
