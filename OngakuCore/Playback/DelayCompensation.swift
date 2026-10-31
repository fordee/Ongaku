//
//  DelayCompensation.swift
//  OngakuCore
//

import Foundation

/// Plug-in delay compensation, as Logic does it: some plug-ins (look-ahead limiters and
/// compressors, linear-phase EQs) delay the sound passing through them and say by how much.
/// To keep the mix in time, every other path is delayed to match.
///
/// Sound reaches each mix point (an aux or summing stack's input, and Stereo Out) along
/// several paths. A channel's sound is late by its instrument's latency plus its inserts';
/// an aux waits for the latest path into it, so each earlier path gets a delay that makes
/// up the difference, and the aux's own inserts add to what it passes on. Stereo Out works
/// the same way; how late it is overall is the total latency, which the playhead, metronome,
/// recording and bounce allow for.
///
/// All values are in samples at the engine's rate. This is pure arithmetic over the
/// routing, so it can be tested without audio.
public struct DelayCompensation: Equatable, Sendable {
  /// A channel's own latency: what its source (an instrument) and its inserts add.
  public struct Latency: Equatable, Sendable {
    public var source: Int
    public var inserts: Int

    public init(source: Int = 0, inserts: Int = 0) {
      self.source = source
      self.inserts = inserts
    }
  }

  /// Where a connection from a channel goes.
  public enum Destination: Hashable, Sendable {
    case stereoOut
    /// An aux track's input, through the channel's output or a send.
    case track(Track.ID)
  }

  private struct Connection: Hashable, Sendable {
    var from: Track.ID
    var to: Destination
  }

  /// How late each channel's sound is at its fader (and so at every send and its output).
  public private(set) var faderLatency: [Track.ID: Int] = [:]
  /// How late the mix arrives at Stereo Out.
  public private(set) var totalLatency = 0
  /// What Stereo Out's own plug-ins add. Everything goes through them, so nothing needs
  /// delaying to match; it only makes the whole mix later.
  public var stereoOutLatency = 0
  /// How late what's heard is: the whole mix, through Stereo Out's plug-ins.
  public var mixLatency: Int { totalLatency + max(0, stereoOutLatency) }
  private var delays: [Connection: Int] = [:]

  /// No compensation: everything on time.
  public init() {}

  public init(project: Project, latencies: [Track.ID: Latency]) {
    var arrival: [Track.ID: Int] = [:]
    var visiting: Set<Track.ID> = []
    // Tracks feeding each aux, through outputs or sends.
    var feeders: [Track.ID: [Track.ID]] = [:]
    for track in project.tracks {
      for destination in track.routedDestinations {
        feeders[destination, default: []].append(track.id)
      }
    }

    /// When sound arrives at a channel's input (and leaves its source).
    func arrivalLatency(of trackID: Track.ID) -> Int {
      if let known = arrival[trackID] { return known }
      guard let track = project.track(withID: trackID), visiting.insert(trackID).inserted else { return 0 }
      defer { visiting.remove(trackID) }
      let value: Int
      if track.kind == .aux {
        value = (feeders[trackID] ?? []).map(outputLatency).max() ?? 0
      } else {
        value = max(0, latencies[trackID]?.source ?? 0)
      }
      arrival[trackID] = value
      return value
    }

    func outputLatency(of trackID: Track.ID) -> Int {
      arrivalLatency(of: trackID) + max(0, latencies[trackID]?.inserts ?? 0)
    }

    for track in project.tracks {
      faderLatency[track.id] = outputLatency(of: track.id)
    }
    totalLatency = project.tracks.filter { $0.channel.output == .stereoOut }.compactMap { faderLatency[$0.id] }.max() ?? 0

    for track in project.tracks {
      let latency = faderLatency[track.id] ?? 0
      let outputArrival = track.channel.output.trackID.map(arrivalLatency) ?? totalLatency
      delays[Connection(from: track.id, to: track.channel.output.trackID.map(Destination.track) ?? .stereoOut)] =
        outputArrival - latency
      for send in track.channel.sends {
        delays[Connection(from: track.id, to: .track(send.destinationTrackID))] = arrivalLatency(of: send.destinationTrackID) - latency
      }
    }
  }

  /// The delay added to a channel's connection (its output or a send) so its sound arrives
  /// with everything else's.
  public func delay(from trackID: Track.ID, to destination: Destination) -> Int {
    max(0, delays[Connection(from: trackID, to: destination)] ?? 0)
  }

  /// Whether any connection needs a delay.
  public var compensates: Bool {
    delays.values.contains { $0 > 0 }
  }
}
