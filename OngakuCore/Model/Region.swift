//
//  Region.swift
//  OngakuCore
//

import Foundation

/// A block of content on a track: MIDI notes on an instrument track or a slice of an audio
/// file on an audio track.
///
/// The playback parameters (Logic's Region Inspector: loop, transpose, velocity and
/// quantize) change how the region plays without changing its notes; see `playedNotes`.
public struct Region: Identifiable, Codable, Sendable, Equatable {
  public static let transposeRange: ClosedRange<Int> = -96...96
  public static let velocityOffsetRange: ClosedRange<Int> = -99...99

  public var id: UUID
  public var name: String
  /// Position on the timeline.
  public var start: Tick
  public var length: Tick
  public var isMuted: Bool
  public var content: RegionContent
  /// Logic's Loop: the region repeats until the next region on its track, or the end of
  /// the project (or `loopedLength`, if that's sooner).
  public var isLooped: Bool
  /// How far a looped region and its repeats reach, from its start (what dragging Logic's
  /// loop handle sets; the last repeat can stop part way). `nil` loops to the next region.
  public var loopedLength: Tick?
  /// MIDI: semitones added to every note as it plays.
  public var transpose: Int
  /// MIDI: added to every note's velocity as it plays (kept within 1…127).
  public var velocityOffset: Int
  /// MIDI: the grid notes play quantized to, or `nil` to play them as recorded.
  public var playbackQuantize: Tick?
  /// MIDI: with `playbackQuantize`, a second grid (a triplet one, say) for a mixed quantize:
  /// each note plays on whichever grid's line is nearer.
  public var playbackQuantizeAlternative: Tick?
  /// Where the region's content comes from, when it isn't plain notes or audio: a take
  /// folder, or a pattern, drummer or player that generates its notes. A region has at most
  /// one (see `RegionSource`).
  public var source: RegionSource?

  public init(
    id: UUID = UUID(),
    name: String,
    start: Tick,
    length: Tick,
    isMuted: Bool = false,
    content: RegionContent,
    isLooped: Bool = false,
    loopedLength: Tick? = nil,
    transpose: Int = 0,
    velocityOffset: Int = 0,
    playbackQuantize: Tick? = nil,
    playbackQuantizeAlternative: Tick? = nil,
    takeFolder: TakeFolder? = nil,
    pattern: StepPattern? = nil,
    drummer: DrummerPerformance? = nil,
    player: PlayerPerformance? = nil
  ) {
    self.id = id
    self.name = name
    self.start = start
    self.length = length
    self.isMuted = isMuted
    self.content = content
    self.isLooped = isLooped
    self.loopedLength = loopedLength
    self.transpose = transpose
    self.velocityOffset = velocityOffset
    self.playbackQuantize = playbackQuantize
    self.playbackQuantizeAlternative = playbackQuantizeAlternative
    self.source = RegionSource(takeFolder: takeFolder, pattern: pattern, drummer: drummer, player: player)
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, start, length, isMuted, content, isLooped, loopedLength, transpose, velocityOffset, playbackQuantize,
      playbackQuantizeAlternative, takeFolder, pattern, drummer, player
  }

  /// The playback parameters were added in format version 7; older regions play as recorded.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    start = try container.decode(Tick.self, forKey: .start)
    length = try container.decode(Tick.self, forKey: .length)
    isMuted = try container.decode(Bool.self, forKey: .isMuted)
    content = try container.decode(RegionContent.self, forKey: .content)
    isLooped = try container.decodeIfPresent(Bool.self, forKey: .isLooped) ?? false
    // Loop ends were added in format version 14; older loops reach the next region.
    loopedLength = try container.decodeIfPresent(Tick.self, forKey: .loopedLength)
    transpose = try container.decodeIfPresent(Int.self, forKey: .transpose) ?? 0
    velocityOffset = try container.decodeIfPresent(Int.self, forKey: .velocityOffset) ?? 0
    playbackQuantize = try container.decodeIfPresent(Tick.self, forKey: .playbackQuantize)
    // Mixed playback quantize was added in format version 19.
    playbackQuantizeAlternative = try container.decodeIfPresent(Tick.self, forKey: .playbackQuantizeAlternative)
    // Patterns were added in format version 18, drummer regions in 20 and session player
    // regions in 21. Each is still saved under its own key, so files are unchanged.
    source = RegionSource(
      takeFolder: try container.decodeIfPresent(TakeFolder.self, forKey: .takeFolder),
      pattern: try container.decodeIfPresent(StepPattern.self, forKey: .pattern),
      drummer: try container.decodeIfPresent(DrummerPerformance.self, forKey: .drummer),
      player: try container.decodeIfPresent(PlayerPerformance.self, forKey: .player))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(start, forKey: .start)
    try container.encode(length, forKey: .length)
    try container.encode(isMuted, forKey: .isMuted)
    try container.encode(content, forKey: .content)
    try container.encode(isLooped, forKey: .isLooped)
    try container.encodeIfPresent(loopedLength, forKey: .loopedLength)
    try container.encode(transpose, forKey: .transpose)
    try container.encode(velocityOffset, forKey: .velocityOffset)
    try container.encodeIfPresent(playbackQuantize, forKey: .playbackQuantize)
    try container.encodeIfPresent(playbackQuantizeAlternative, forKey: .playbackQuantizeAlternative)
    try container.encodeIfPresent(takeFolder, forKey: .takeFolder)
    try container.encodeIfPresent(pattern, forKey: .pattern)
    try container.encodeIfPresent(drummer, forKey: .drummer)
    try container.encodeIfPresent(player, forKey: .player)
  }

  /// The notes as they play: transposed, with the velocity offset, and quantized to
  /// `playbackQuantize` (to the nearest grid line from the region start, or the nearer of the
  /// two grids' lines with `playbackQuantizeAlternative`). Muted notes, and
  /// notes pushed out of the MIDI range by transposing, don't play.
  public var playedNotes: [MIDINote] {
    notesWithPlaybackParameters(keepingMuted: false)
  }

  /// Whether transpose, velocity or playback quantize change how the notes play.
  public var hasPlaybackParameters: Bool {
    transpose != 0 || velocityOffset != 0 || playbackQuantize != nil
  }

  /// The notes with transpose, velocity and playback quantize written into them, as
  /// `playedNotes` plays them; muted notes are kept (still muted) or left out. Notes pushed
  /// out of the MIDI range by transposing are left out.
  public func notesWithPlaybackParameters(keepingMuted: Bool) -> [MIDINote] {
    guard case .midi(let sequence) = content else { return [] }
    guard hasPlaybackParameters || (!keepingMuted && sequence.notes.contains(where: \.isMuted))
    else { return sequence.notes }
    return sequence.notes.compactMap { note in
      guard keepingMuted || !note.isMuted else { return nil }
      var played = note
      played.pitch += transpose
      guard MIDINote.pitchRange.contains(played.pitch) else { return nil }
      played.velocity = min(max(note.velocity + velocityOffset, MIDINote.velocityRange.lowerBound), MIDINote.velocityRange.upperBound)
      if let grid = playbackQuantize, grid > .zero {
        let steps = (Double(note.start.rawValue) / Double(grid.rawValue)).rounded()
        played.start = grid * Int64(steps)
        if let other = playbackQuantizeAlternative, other > .zero {
          let otherStart = other * Int64((Double(note.start.rawValue) / Double(other.rawValue)).rounded())
          if abs((otherStart - note.start).rawValue) < abs((played.start - note.start).rawValue) { played.start = otherStart }
        }
      }
      return played
    }
  }

  public var end: Tick { start + length }

  /// Where a looped region's repeats stop, if it has a loop end.
  public var loopEnd: Tick? {
    isLooped ? loopedLength.map { start + $0 } : nil
  }
}

public enum RegionContent: Codable, Sendable, Equatable {
  case midi(MIDISequence)
  case audio(AudioRegionContent)

  /// The kind of track this content can live on.
  public var trackKind: TrackKind {
    switch self {
    case .midi: .softwareInstrument
    case .audio: .audio
    }
  }
}

public struct MIDISequence: Codable, Sendable, Equatable {
  /// Sorted by start position. Notes may lie outside the region bounds after a trim; they are
  /// kept so extending the region again brings them back, but they don't play.
  public var notes: [MIDINote]
  /// Controllers, pitch bend and aftertouch, sorted by position. Like notes, they're kept
  /// when a trim leaves them outside the region, but don't play there.
  public var controls: [MIDIControlEvent]

  public init(notes: [MIDINote] = [], controls: [MIDIControlEvent] = []) {
    self.notes = notes.sorted { $0.start < $1.start }
    self.controls = controls.sorted { $0.position < $1.position }
  }

  private enum CodingKeys: String, CodingKey {
    case notes, controls
  }

  /// Projects from before format 4 have no `controls`.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    notes = try container.decode([MIDINote].self, forKey: .notes)
    controls = try container.decodeIfPresent([MIDIControlEvent].self, forKey: .controls) ?? []
  }

  mutating func sortNotes() {
    notes.sort { $0.start < $1.start }
    controls.sort { $0.position < $1.position }
  }

  /// The events of one kind on one channel, in order.
  public func controls(_ kind: MIDIControlEvent.Kind, channel: Int? = nil) -> [MIDIControlEvent] {
    controls.filter { $0.kind == kind && (channel == nil || $0.channel == channel) }
  }
}

/// A MIDI message other than a note, at a point in a region: a controller (volume, pan,
/// modulation, sustain…), pitch bend, or aftertouch for the whole channel or one note.
public struct MIDIControlEvent: Identifiable, Codable, Sendable, Equatable {
  public enum Kind: Hashable, Codable, Sendable {
    /// A control change; the number is 0–119 (120–127 are channel mode messages).
    case controller(Int)
    /// Bends every note on the channel; −8192…8191, 0 is no bend.
    case pitchBend
    /// Channel aftertouch: how hard keys are held down, for the whole channel; 0–127.
    case channelPressure
    /// Polyphonic aftertouch: pressure on one held key; 0–127.
    case polyPressure(pitch: Int)

    public static let volume = Kind.controller(7)
    public static let pan = Kind.controller(10)
    public static let modulation = Kind.controller(1)
    public static let expression = Kind.controller(11)
    public static let sustain = Kind.controller(64)

    public static let controllerNumbers: ClosedRange<Int> = 0...119

    /// The values this kind of event takes.
    public var valueRange: ClosedRange<Int> {
      self == .pitchBend ? -8192...8191 : 0...127
    }

    /// The value with no effect, which playback returns to: centred for pan and pitch bend,
    /// full for volume and expression, otherwise 0.
    public var neutralValue: Int {
      switch self {
      case .pitchBend: 0
      case .pan: 64
      case .volume: 100
      case .expression: 127
      default: 0
      }
    }

    public var isValid: Bool {
      switch self {
      case .controller(let number): Self.controllerNumbers.contains(number)
      case .pitchBend, .channelPressure: true
      case .polyPressure(let pitch): MIDINote.pitchRange.contains(pitch)
      }
    }

    /// A name for menus and labels, such as "Volume (CC 7)" or "Pitch Bend".
    public var name: String {
      switch self {
      case .controller(let number):
        if let name = Self.controllerNames[number] { "\(name) (CC \(number))" } else { "Controller \(number)" }
      case .pitchBend: "Pitch Bend"
      case .channelPressure: "Channel Aftertouch"
      case .polyPressure: "Poly Aftertouch"
      }
    }

    /// The General MIDI names of the common controllers.
    public static let controllerNames: [Int: String] = [
      0: "Bank Select", 1: "Modulation", 2: "Breath", 4: "Foot Control", 5: "Portamento Time", 7: "Volume",
      8: "Balance", 10: "Pan", 11: "Expression", 64: "Sustain", 65: "Portamento", 66: "Sostenuto", 67: "Soft Pedal",
      71: "Resonance", 72: "Release Time", 73: "Attack Time", 74: "Brightness", 91: "Reverb", 93: "Chorus",
    ]
  }

  public var id: UUID
  public var kind: Kind
  public var channel: Int
  /// Relative to the region start.
  public var position: Tick
  public var value: Int

  public init(id: UUID = UUID(), kind: Kind, channel: Int = 0, position: Tick, value: Int) {
    self.id = id
    self.kind = kind
    self.channel = channel
    self.position = position
    self.value = value
  }

  public var isValid: Bool {
    kind.isValid && kind.valueRange.contains(value) && MIDINote.channelRange.contains(channel)
  }

  /// The MIDI 1.0 message.
  public var bytes: [UInt8] {
    let channelNibble = UInt8(clamping: channel & 0x0F)
    let clamped = min(max(value, kind.valueRange.lowerBound), kind.valueRange.upperBound)
    switch kind {
    case .controller(let number):
      return [0xB0 | channelNibble, UInt8(clamping: number), UInt8(clamping: clamped)]
    case .pitchBend:
      let raw = clamped + 8192
      return [0xE0 | channelNibble, UInt8(raw & 0x7F), UInt8((raw >> 7) & 0x7F)]
    case .channelPressure:
      return [0xD0 | channelNibble, UInt8(clamping: clamped)]
    case .polyPressure(let pitch):
      return [0xA0 | channelNibble, UInt8(clamping: pitch), UInt8(clamping: clamped)]
    }
  }

  /// Reads a controller, pitch bend or aftertouch message; `nil` for anything else
  /// (including notes and channel mode messages).
  public static func parse(_ bytes: [UInt8], at position: Tick) -> MIDIControlEvent? {
    guard let status = bytes.first else { return nil }
    let channel = Int(status & 0x0F)
    func data(_ index: Int) -> Int? { index < bytes.count ? Int(bytes[index] & 0x7F) : nil }
    switch status & 0xF0 {
    case 0xB0:
      guard let number = data(1), let value = data(2), Kind.controllerNumbers.contains(number) else { return nil }
      return MIDIControlEvent(kind: .controller(number), channel: channel, position: position, value: value)
    case 0xE0:
      guard let low = data(1), let high = data(2) else { return nil }
      return MIDIControlEvent(kind: .pitchBend, channel: channel, position: position, value: (high << 7 | low) - 8192)
    case 0xD0:
      guard let value = data(1) else { return nil }
      return MIDIControlEvent(kind: .channelPressure, channel: channel, position: position, value: value)
    case 0xA0:
      guard let pitch = data(1), let value = data(2) else { return nil }
      return MIDIControlEvent(kind: .polyPressure(pitch: pitch), channel: channel, position: position, value: value)
    default:
      return nil
    }
  }
}

public struct MIDINote: Identifiable, Codable, Sendable, Equatable {
  public static let pitchRange: ClosedRange<Int> = 0...127
  public static let velocityRange: ClosedRange<Int> = 1...127
  public static let channelRange: ClosedRange<Int> = 0...15

  public var id: UUID
  /// MIDI note number; 60 is middle C (C3 in Logic's naming).
  public var pitch: Int
  public var velocity: Int
  public var channel: Int
  /// Start relative to the region start.
  public var start: Tick
  public var length: Tick
  /// Muted notes stay in the region (drawn grey) but don't play, as in Logic.
  public var isMuted: Bool

  public init(
    id: UUID = UUID(), pitch: Int, velocity: Int = 100, channel: Int = 0, start: Tick, length: Tick, isMuted: Bool = false
  ) {
    self.id = id
    self.pitch = pitch
    self.velocity = velocity
    self.channel = channel
    self.start = start
    self.length = length
    self.isMuted = isMuted
  }

  private enum CodingKeys: String, CodingKey {
    case id, pitch, velocity, channel, start, length, isMuted
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    pitch = try container.decode(Int.self, forKey: .pitch)
    velocity = try container.decode(Int.self, forKey: .velocity)
    channel = try container.decode(Int.self, forKey: .channel)
    start = try container.decode(Tick.self, forKey: .start)
    length = try container.decode(Tick.self, forKey: .length)
    isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
  }

  /// Only muted notes say so, keeping songs (with thousands of notes) small.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(pitch, forKey: .pitch)
    try container.encode(velocity, forKey: .velocity)
    try container.encode(channel, forKey: .channel)
    try container.encode(start, forKey: .start)
    try container.encode(length, forKey: .length)
    if isMuted { try container.encode(true, forKey: .isMuted) }
  }

  public var end: Tick { start + length }

  public var isValid: Bool {
    MIDINote.pitchRange.contains(pitch)
      && MIDINote.velocityRange.contains(velocity)
      && MIDINote.channelRange.contains(channel)
      && length > .zero
  }
}

public struct AudioRegionContent: Codable, Sendable, Equatable {
  public var fileID: AudioFileReference.ID
  /// The frame in the audio file that plays at the region start.
  public var fileStartFrame: Int64
  /// Region gain in decibels.
  public var gain: Double
  /// How long the region fades in from silence at its start, in seconds.
  public var fadeIn: Double
  /// How long the region fades out to silence at its end, in seconds.
  public var fadeOut: Double
  /// The shape of the fade in, from −1 (slow, then fast) through 0 (straight) to 1 (fast,
  /// then slow), as Logic's fade curve (see `AudioEnvelope.fadeShape`).
  public var fadeInCurve: Double
  /// The shape of the fade out (see `fadeInCurve`).
  public var fadeOutCurve: Double
  /// Flex Time markers (played when the track's Flex mode is on), sorted by source time.
  public var flexMarkers: [FlexMarker]
  /// Flex Pitch: retuned notes (played when the track's Flex mode is Flex Pitch).
  public var pitchEdits: [PitchEdit]
  /// Seconds of the recording played per second of the region: 1 plays it as recorded;
  /// Smart Tempo's Match Project Tempo time-stretches whole regions to the song's tempo.
  public var stretch: Double

  public init(
    fileID: AudioFileReference.ID, fileStartFrame: Int64 = 0, gain: Double = 0, fadeIn: Double = 0, fadeOut: Double = 0,
    fadeInCurve: Double = 0, fadeOutCurve: Double = 0,
    flexMarkers: [FlexMarker] = [],
    pitchEdits: [PitchEdit] = [],
    stretch: Double = 1
  ) {
    self.fileID = fileID
    self.fileStartFrame = fileStartFrame
    self.gain = gain
    self.fadeIn = fadeIn
    self.fadeOut = fadeOut
    self.fadeInCurve = fadeInCurve
    self.fadeOutCurve = fadeOutCurve
    self.flexMarkers = flexMarkers
    self.pitchEdits = pitchEdits
    self.stretch = stretch
  }

  private enum CodingKeys: String, CodingKey {
    case fileID, fileStartFrame, gain, fadeIn, fadeOut, fadeInCurve, fadeOutCurve, flexMarkers, pitchEdits, stretch
  }

  /// Fades were added in format version 7, flex markers in 11, pitch edits in 12 and
  /// stretch in 13.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fileID = try container.decode(AudioFileReference.ID.self, forKey: .fileID)
    fileStartFrame = try container.decode(Int64.self, forKey: .fileStartFrame)
    gain = try container.decode(Double.self, forKey: .gain)
    fadeIn = try container.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0
    fadeOut = try container.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
    // Fade curves were added in format version 27; older fades are straight.
    fadeInCurve = try container.decodeIfPresent(Double.self, forKey: .fadeInCurve) ?? 0
    fadeOutCurve = try container.decodeIfPresent(Double.self, forKey: .fadeOutCurve) ?? 0
    flexMarkers = try container.decodeIfPresent([FlexMarker].self, forKey: .flexMarkers) ?? []
    pitchEdits = try container.decodeIfPresent([PitchEdit].self, forKey: .pitchEdits) ?? []
    stretch = try container.decodeIfPresent(Double.self, forKey: .stretch) ?? 1
  }
}

/// What a region's content comes from, beyond plain notes or audio. Each kind is edited in
/// its own editor; the generated ones (`isGenerated`) replace the region's notes whenever
/// they're rendered (see `Project.renderGeneratedRegions(changedSince:)`).
public enum RegionSource: Sendable, Equatable {
  /// The takes of a take folder (see `TakeFolder`).
  case takeFolder(TakeFolder)
  /// A Step Sequencer pattern: notes rendered by `Region.renderPattern()`.
  case pattern(StepPattern)
  /// A session drummer's part: notes rendered by `Region.renderDrummer(tempoMap:)`.
  case drummer(DrummerPerformance)
  /// A session player's part (bass or keys), following the Chord track: notes rendered by
  /// `Region.renderPlayer(in:)`.
  case player(PlayerPerformance)

  /// The one source among the stored keys (a file can't hold more than one, but if it
  /// did, the take folder wins, then the pattern, drummer and player).
  init?(takeFolder: TakeFolder?, pattern: StepPattern?, drummer: DrummerPerformance?, player: PlayerPerformance?) {
    if let takeFolder { self = .takeFolder(takeFolder) }
    else if let pattern { self = .pattern(pattern) }
    else if let drummer { self = .drummer(drummer) }
    else if let player { self = .player(player) }
    else { return nil }
  }

  /// Whether the region's notes are generated from this source.
  public var isGenerated: Bool {
    switch self {
    case .takeFolder: false
    case .pattern, .drummer, .player: true
    }
  }
}

extension Region {
  /// The take folder, if the region is one. Setting one replaces any other source; setting
  /// `nil` only clears a take folder.
  public var takeFolder: TakeFolder? {
    get { if case .takeFolder(let folder) = source { folder } else { nil } }
    set {
      if let newValue { source = .takeFolder(newValue) } else if case .takeFolder = source { source = nil }
    }
  }

  /// The Step Sequencer pattern, if the region is a pattern region (see `takeFolder` for
  /// how setting works).
  public var pattern: StepPattern? {
    get { if case .pattern(let pattern) = source { pattern } else { nil } }
    set {
      if let newValue { source = .pattern(newValue) } else if case .pattern = source { source = nil }
    }
  }

  /// The drummer's part, if the region is a drummer region (see `takeFolder` for how
  /// setting works).
  public var drummer: DrummerPerformance? {
    get { if case .drummer(let drummer) = source { drummer } else { nil } }
    set {
      if let newValue { source = .drummer(newValue) } else if case .drummer = source { source = nil }
    }
  }

  /// The session player's part, if the region is a player region (see `takeFolder` for how
  /// setting works).
  public var player: PlayerPerformance? {
    get { if case .player(let player) = source { player } else { nil } }
    set {
      if let newValue { source = .player(newValue) } else if case .player = source { source = nil }
    }
  }

  /// Whether the region's notes are generated (by a pattern, drummer or player), so editing
  /// them directly would be undone by the next render.
  public var isGenerated: Bool { source?.isGenerated ?? false }
}
