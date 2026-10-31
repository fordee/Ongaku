//
//  Project.swift
//  OngakuCore
//

import Foundation

/// The complete, serializable state of an Ongaku song.
///
/// `Project` and everything it contains are value types. The UI edits a project only through
/// `EditCommand`s, and the audio engine reads immutable copies, so no locks are needed between
/// the two.
public struct Project: Codable, Sendable, Equatable {
  /// Bump whenever the on-disk format changes in a way older builds can't read.
  /// Version 2 added aux tracks, sends, audio inputs and the master volume; version 3 added
  /// automation (an older build would silently drop it when saving); version 4 added
  /// controller, pitch bend and aftertouch events to MIDI regions; version 5 added track
  /// outputs and summing stacks; version 6 added frozen tracks; version 7 added region
  /// playback parameters (loop, transpose, velocity, quantize) and fades; version 8 added
  /// markers and the arrangement track; version 9 added mixer groups; version 10 added take
  /// folders; version 11 added Flex Time; version 12 added Flex Pitch; version 13 added
  /// region time-stretch (Smart Tempo); version 14 added region loop ends; version 15 keeps
  /// large plug-in settings in files beside Project.json (an older build would lose them);
  /// version 16 added muted notes; version 17 added MIDI effects; version 18 added Step
  /// Sequencer patterns; version 19 added mixed (straight and triplet) playback quantize;
  /// version 20 added Drummer regions; version 21 added the Chord track and session player
  /// regions; version 22 added plug-ins on Stereo Out (an older build would drop them) and
  /// input monitoring; version 23 saves whether the metronome is on; version 24 added key
  /// changes.
  public static let currentFormatVersion = 24

  public var formatVersion: Int
  public var sampleRate: Double
  public var tempoMap: TempoMap
  /// The key at the start of the song.
  public var keySignature: KeySignature
  /// Changes of key after the start, sorted by position, none at the start and none to the
  /// key already in effect (see `key(at:)`).
  public var keyChanges: [KeyChange]
  public var cycle: CycleRange
  /// Whether the metronome clicks, saved with the song as in Logic.
  public var isMetronomeEnabled: Bool
  /// Where the project ends (the end marker in Logic's ruler).
  public var endPosition: Tick
  public var tracks: [Track]
  /// Audio files stored in the project package and used by audio regions.
  public var audioFiles: [AudioFileReference]
  /// The Stereo Out fader, in decibels.
  public var masterVolume: Double
  /// The plug-ins on Stereo Out, before its fader: what the whole mix goes through.
  public var stereoOutInserts: [PluginReference]
  /// The Marker track, sorted by position.
  public var markers: [Marker]
  /// The Arrangement track's sections, sorted by start and never overlapping.
  public var arrangement: [ArrangementSection]
  /// Mixer groups, by number.
  public var groups: [MixerGroup]
  /// The Chord track, sorted by position: the chords the session players follow.
  public var chords: [ChordChange]

  public init(
    sampleRate: Double = 48_000,
    tempoMap: TempoMap = TempoMap(),
    keySignature: KeySignature = .cMajor,
    cycle: CycleRange? = nil,
    endPosition: Tick? = nil,
    tracks: [Track] = [],
    audioFiles: [AudioFileReference] = []
  ) {
    self.formatVersion = Project.currentFormatVersion
    self.sampleRate = sampleRate
    self.tempoMap = tempoMap
    self.keySignature = keySignature
    self.keyChanges = []
    self.cycle = cycle ?? CycleRange(start: .zero, end: tempoMap.tickPosition(ofBarIndex: 4))
    self.isMetronomeEnabled = false
    self.endPosition = endPosition ?? tempoMap.tickPosition(ofBarIndex: 128)
    self.tracks = tracks
    self.audioFiles = audioFiles
    self.masterVolume = 0
    self.stereoOutInserts = []
    self.markers = []
    self.arrangement = []
    self.groups = []
    self.chords = []
  }

  private enum CodingKeys: String, CodingKey {
    case formatVersion, sampleRate, tempoMap, keySignature, cycle, endPosition, tracks, audioFiles, masterVolume, markers,
      arrangement, groups, chords, stereoOutInserts, isMetronomeEnabled, keyChanges
  }

  /// Reads every format version up to the current one; fields added later get defaults.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    formatVersion = try container.decode(Int.self, forKey: .formatVersion)
    sampleRate = try container.decode(Double.self, forKey: .sampleRate)
    tempoMap = try container.decode(TempoMap.self, forKey: .tempoMap)
    keySignature = try container.decode(KeySignature.self, forKey: .keySignature)
    cycle = try container.decode(CycleRange.self, forKey: .cycle)
    endPosition = try container.decode(Tick.self, forKey: .endPosition)
    tracks = try container.decode([Track].self, forKey: .tracks)
    audioFiles = try container.decode([AudioFileReference].self, forKey: .audioFiles)
    masterVolume = try container.decodeIfPresent(Double.self, forKey: .masterVolume) ?? 0
    markers = try container.decodeIfPresent([Marker].self, forKey: .markers) ?? []
    arrangement = try container.decodeIfPresent([ArrangementSection].self, forKey: .arrangement) ?? []
    groups = try container.decodeIfPresent([MixerGroup].self, forKey: .groups) ?? []
    // The Chord track was added in format version 21.
    chords = try container.decodeIfPresent([ChordChange].self, forKey: .chords) ?? []
    // Plug-ins on Stereo Out were added in format version 22.
    stereoOutInserts = try container.decodeIfPresent([PluginReference].self, forKey: .stereoOutInserts) ?? []
    // The metronome's state was saved from format version 23.
    isMetronomeEnabled = try container.decodeIfPresent(Bool.self, forKey: .isMetronomeEnabled) ?? false
    // Key changes were added in format version 24.
    keyChanges = try container.decodeIfPresent([KeyChange].self, forKey: .keyChanges) ?? []
  }

  /// The channel ID that stands for Stereo Out in commands that edit a channel strip's
  /// inserts. No track has it.
  public static let stereoOutID = UUID(uuidString: "00000000-0000-0000-0000-00000000005E")!

  /// A channel strip's inserts: a track's, or Stereo Out's for `stereoOutID`.
  public func inserts(of channelID: Track.ID) throws -> [PluginReference] {
    channelID == Self.stereoOutID ? stereoOutInserts : tracks[try requireTrackIndex(channelID)].channel.inserts
  }

  /// Changes a channel strip's inserts: a track's, or Stereo Out's for `stereoOutID`.
  public mutating func modifyInserts<Result>(
    of channelID: Track.ID, _ body: (inout [PluginReference]) throws -> Result
  ) throws -> Result {
    if channelID == Self.stereoOutID {
      return try body(&stereoOutInserts)
    }
    let index = try requireTrackIndex(channelID)
    return try body(&tracks[index].channel.inserts)
  }

  /// Linear gain for the master fader.
  public var masterLinearGain: Double {
    masterVolume <= ChannelStrip.volumeRange.lowerBound ? 0 : pow(10, masterVolume / 20)
  }

  /// Whether sending from `source` to `destination` would feed `source`'s own output back
  /// into it (directly, or through a chain of aux sends).
  public func sendWouldCreateFeedback(from source: Track.ID, to destination: Track.ID) -> Bool {
    if source == destination { return true }
    // Walk the routing graph (sends and outputs) from the destination; reaching the source
    // means a loop.
    var visited: Set<Track.ID> = []
    var queue = [destination]
    while let next = queue.popLast() {
      guard visited.insert(next).inserted, let track = track(withID: next) else { continue }
      for destination in track.routedDestinations {
        if destination == source { return true }
        queue.append(destination)
      }
    }
    return false
  }

  /// Whether routing `source`'s output to `destination` would feed sound back into it.
  public func outputWouldCreateFeedback(from source: Track.ID, to destination: Track.ID) -> Bool {
    sendWouldCreateFeedback(from: source, to: destination)
  }

  /// A summing stack's subtracks, in track order.
  public func stackMembers(of stackID: Track.ID) -> [Track] {
    tracks.filter { $0.stackID == stackID }
  }

  /// The project a new document starts with: 120 BPM, 4/4, C major and one instrument track.
  public static func newDefault() -> Project {
    Project(tracks: [Track(name: "Inst 1", kind: .softwareInstrument)])
  }

  // MARK: - Lookup

  public func trackIndex(for trackID: Track.ID) -> Int? {
    tracks.firstIndex { $0.id == trackID }
  }

  public func track(withID trackID: Track.ID) -> Track? {
    trackIndex(for: trackID).map { tracks[$0] }
  }

  /// The track and region indexes of a region, if it exists.
  public func regionLocation(for regionID: Region.ID) -> (track: Int, region: Int)? {
    for (trackIndex, track) in tracks.enumerated() {
      if let regionIndex = track.regions.firstIndex(where: { $0.id == regionID }) {
        return (trackIndex, regionIndex)
      }
    }
    return nil
  }

  public func region(withID regionID: Region.ID) -> Region? {
    regionLocation(for: regionID).map { tracks[$0.track].regions[$0.region] }
  }

  public func audioFile(withID fileID: AudioFileReference.ID) -> AudioFileReference? {
    audioFiles.first { $0.id == fileID }
  }

  /// A name such as "Audio 3" that isn't used by another track yet.
  public func nextTrackName(for kind: TrackKind) -> String {
    let prefix = kind.defaultNamePrefix
    let existing = Set(tracks.map(\.name))
    var number = 1
    while existing.contains("\(prefix) \(number)") {
      number += 1
    }
    return "\(prefix) \(number)"
  }
}

/// The cycle (loop) range shown in the ruler.
public struct CycleRange: Codable, Sendable, Equatable {
  public var isEnabled: Bool
  public var start: Tick
  public var end: Tick

  public init(isEnabled: Bool = false, start: Tick, end: Tick) {
    self.isEnabled = isEnabled
    self.start = start
    self.end = end
  }

  public var length: Tick { end - start }
}

public struct KeySignature: Codable, Sendable, Hashable, CustomStringConvertible {
  public enum Mode: String, Codable, Sendable, CaseIterable {
    case major, minor
  }

  private static let pitchClassNames = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

  public static let cMajor = KeySignature(tonic: 0, mode: .major)

  /// Pitch class of the tonic, 0 (C) through 11 (B).
  public var tonic: Int
  public var mode: Mode

  public init(tonic: Int, mode: Mode) {
    self.tonic = ((tonic % 12) + 12) % 12
    self.mode = mode
  }

  public var description: String {
    "\(KeySignature.pitchClassNames[tonic]) \(mode == .major ? "maj" : "min")"
  }
}

/// An audio file stored in the project package's "Audio Files" folder.
public struct AudioFileReference: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  /// File name inside the package's audio folder.
  public var fileName: String
  public var sampleRate: Double
  public var channelCount: Int
  public var frameCount: Int64

  public init(id: UUID = UUID(), fileName: String, sampleRate: Double, channelCount: Int, frameCount: Int64) {
    self.id = id
    self.fileName = fileName
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.frameCount = frameCount
  }

  public var duration: Double { Double(frameCount) / sampleRate }
}

extension Project {
  /// How many bars the song runs past the last thing in it, so there's always room to add more.
  public static let barsPastContent = 8

  /// Where the last region, loop, marker or arrangement section ends. A region that loops
  /// to the end of the song counts only its own length.
  public var contentEnd: Tick {
    let regionEnds = tracks.flatMap(\.regions).map { $0.loopEnd ?? $0.end }
    return (regionEnds + markers.map(\.position) + arrangement.map(\.end)).max() ?? .zero
  }

  /// Moves the end of the song to `barsPastContent` bars past the bar its content ends in,
  /// if the content has come within that of the end. The song never gets shorter by itself.
  /// `ProjectEditor` does this after every command.
  public mutating func extendEndPastContent() {
    let contentEnd = contentEnd
    guard contentEnd > .zero else { return }
    // The bar holding the content's last tick, so content ending on a bar line doesn't count
    // the bar after it.
    let lastBar = tempoMap.bar(containing: contentEnd - Tick(1)).index
    let neededEnd = tempoMap.tickPosition(ofBarIndex: lastBar + 1 + Self.barsPastContent)
    if neededEnd > endPosition {
      endPosition = neededEnd
    }
  }
}
