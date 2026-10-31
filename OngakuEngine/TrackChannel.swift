//
//  TrackChannel.swift
//  OngakuEngine
//

import AVFAudio
import OngakuCore

/// The player nodes of an audio track in a bounce, feeding the track's channel input.
/// (Live playback uses `AudioTrackSource` instead: starting and stopping player nodes blocks
/// for about an audio buffer each, which held up the transport.)
///
///     player (48 kHz stereo) ─┐
///     player (44.1 kHz mono) ─┼─▶ channel input (see `ChannelNodes`)
///
/// A player node plays files most efficiently when its output format matches the file, so a
/// track keeps one player per file format and lets the channel's input mixer convert.
@MainActor
final class TrackChannel {
  private struct FormatKey: Hashable {
    var sampleRate: Double
    var channelCount: AVAudioChannelCount
  }

  private var players: [FormatKey: AVAudioPlayerNode] = [:]
  private unowned let engine: AVAudioEngine
  private unowned let destination: AVAudioMixerNode

  init(engine: AVAudioEngine, destination: AVAudioMixerNode) {
    self.engine = engine
    self.destination = destination
  }

  var allPlayers: some Collection<AVAudioPlayerNode> { players.values }

  /// The player for a file format, created and connected on first use.
  func player(for format: AVAudioFormat) throws -> AVAudioPlayerNode {
    let key = FormatKey(sampleRate: format.sampleRate, channelCount: format.channelCount)
    if let player = players[key] {
      return player
    }
    let player = AVAudioPlayerNode()
    engine.attach(player)
    do {
      try engine.connectNode(player, to: destination, fromBus: 0, toBus: engine.freeInputBus(on: destination, for: player), format: format)
    } catch {
      engine.detach(player)
      throw error
    }
    players[key] = player
    return player
  }

  func stopPlayers() {
    for player in players.values {
      player.stop()
    }
  }

  func detach() {
    stopPlayers()
    for player in players.values {
      engine.detach(player)
    }
    players.removeAll()
  }
}
