//
//  Track.swift
//  OngakuCore
//

import Foundation

/// The kinds of track Ongaku supports. New kinds (bus, folder, drummer, video…) are added here
/// and given an editor and an engine node in their own modules.
public enum TrackKind: String, Codable, Sendable, CaseIterable {
  /// Plays MIDI regions through an instrument.
  case softwareInstrument
  /// Plays audio regions from audio files.
  case audio
  /// An aux channel: mixes what other tracks send to it (for shared reverb or submixes).
  /// Aux tracks have no regions.
  case aux

  public var displayName: String {
    switch self {
    case .softwareInstrument: "Software Instrument"
    case .audio: "Audio"
    case .aux: "Aux"
    }
  }

  /// Whether the track holds regions (aux tracks only mix).
  public var hasRegions: Bool { self != .aux }

  /// Whether the track can record (audio from an input, or MIDI into an instrument).
  public var canRecord: Bool { self != .aux }

  var defaultNamePrefix: String {
    switch self {
    case .softwareInstrument: "Inst"
    case .audio: "Audio"
    case .aux: "Aux"
    }
  }

  /// The colour new tracks of this kind get, unless the app's settings choose another.
  public var defaultColor: TrackColor {
    switch self {
    case .softwareInstrument: .green
    case .audio: .blue
    case .aux: .purple
    }
  }
}

/// What freezing a track renders, as in Logic.
public enum FreezeMode: String, Codable, Sendable, CaseIterable {
  /// The instrument or regions through the inserts: the whole channel strip before the
  /// fader. Saves the most processing; the inserts can't be changed while frozen.
  case preFader
  /// Only the instrument or regions; the inserts keep running and can still be changed.
  case sourceOnly

  public var displayName: String {
    switch self {
    case .preFader: "Pre Fader"
    case .sourceOnly: "Source Only"
    }
  }
}

public enum TrackColor: String, Codable, Sendable, CaseIterable {
  case red, orange, yellow, green, teal, blue, purple, pink, gray
}

public struct Track: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  public var name: String
  public var kind: TrackKind
  public var color: TrackColor
  public var channel: ChannelStrip
  public var isRecordArmed: Bool
  /// Whether an audio track plays its input live through its channel strip (Logic's Input
  /// Monitoring), so you hear yourself and its plug-ins while you play or record.
  public var isInputMonitored: Bool
  /// Sorted by start position.
  public var regions: [Region]
  /// At most one lane per parameter.
  public var automation: [AutomationLane]
  public var automationMode: AutomationMode
  /// An aux track that is a summing stack's main track, like Logic's: its subtracks output
  /// to it and are shown indented below it.
  public var isSummingStack: Bool
  /// The summing stack this track is a subtrack of.
  public var stackID: Track.ID?
  /// What freezing the track renders, like the Freeze Mode in Logic's track inspector.
  public var freezeMode: FreezeMode
  /// While the track is frozen, the render of its regions it plays instead (see
  /// `Project.playingFreezeFiles`). Its regions, and what was rendered, can't be edited.
  public var freezeFile: AudioFileReference?
  /// The mixer group the track belongs to (see `MixerGroup`).
  public var groupID: Int?
  /// Flex Time for an audio track: how its regions' flex markers are played, or `nil` when
  /// Flex is off (the markers are kept but the audio plays as recorded).
  public var flexMode: FlexMode?

  public init(
    id: UUID = UUID(),
    name: String,
    kind: TrackKind,
    color: TrackColor? = nil,
    channel: ChannelStrip? = nil,
    isRecordArmed: Bool = false,
    regions: [Region] = [],
    automation: [AutomationLane] = [],
    automationMode: AutomationMode = .read,
    isSummingStack: Bool = false,
    stackID: Track.ID? = nil,
    freezeMode: FreezeMode = .preFader,
    freezeFile: AudioFileReference? = nil,
    groupID: Int? = nil,
    flexMode: FlexMode? = nil,
    isInputMonitored: Bool = false
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.color = color ?? kind.defaultColor
    self.channel = channel ?? ChannelStrip(
      instrument: kind == .softwareInstrument ? .defaultSampler : nil,
      audioInput: kind == .audio ? .defaultInput : nil)
    self.isRecordArmed = isRecordArmed
    self.isInputMonitored = isInputMonitored
    self.regions = regions
    self.automation = automation
    self.automationMode = automationMode
    self.isSummingStack = isSummingStack
    self.stackID = stackID
    self.freezeMode = freezeMode
    self.freezeFile = freezeFile
    self.groupID = groupID
    self.flexMode = flexMode
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, kind, color, channel, isRecordArmed, regions, automation, automationMode, isSummingStack, stackID,
      freezeMode, freezeFile, groupID, flexMode, isInputMonitored
  }

  /// Automation was added in format version 3, summing stacks in 5, freezing in 6 and mixer
  /// groups in 9; older projects get none, in Read mode.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    kind = try container.decode(TrackKind.self, forKey: .kind)
    color = try container.decode(TrackColor.self, forKey: .color)
    channel = try container.decode(ChannelStrip.self, forKey: .channel)
    isRecordArmed = try container.decodeIfPresent(Bool.self, forKey: .isRecordArmed) ?? false
    regions = try container.decode([Region].self, forKey: .regions)
    automation = try container.decodeIfPresent([AutomationLane].self, forKey: .automation) ?? []
    automationMode = try container.decodeIfPresent(AutomationMode.self, forKey: .automationMode) ?? .read
    isSummingStack = try container.decodeIfPresent(Bool.self, forKey: .isSummingStack) ?? false
    stackID = try container.decodeIfPresent(Track.ID.self, forKey: .stackID)
    freezeMode = try container.decodeIfPresent(FreezeMode.self, forKey: .freezeMode) ?? .preFader
    freezeFile = try container.decodeIfPresent(AudioFileReference.self, forKey: .freezeFile)
    groupID = try container.decodeIfPresent(Int.self, forKey: .groupID)
    flexMode = try container.decodeIfPresent(FlexMode.self, forKey: .flexMode)
    // Input monitoring was added in format version 22.
    isInputMonitored = try container.decodeIfPresent(Bool.self, forKey: .isInputMonitored) ?? false
  }

  public var isFrozen: Bool { freezeFile != nil }

  /// Whether the track can be frozen: it plays regions (aux tracks only mix).
  public var canFreeze: Bool { kind.hasRegions }

  /// Whether freezing renders the inserts too (Pre Fader), so they're not running while frozen.
  public var freezesInserts: Bool { freezeMode == .preFader }

  mutating func sortRegions() {
    regions.sort { $0.start < $1.start }
  }

  /// The regions as they play, sorted by start: a looped region repeats until the next
  /// region on the track starts, or until `end` (the project end).
  public func playedRegions(until end: Tick) -> [Region] {
    let sorted = regions.sorted { $0.start < $1.start }
    var played: [Region] = []
    for (index, region) in sorted.enumerated() {
      played.append(region)
      guard region.isLooped, region.length > .zero else { continue }
      // Repeats stop at the next region, the project end or the region's loop end.
      var limit = sorted[(index + 1)...].first { $0.start >= region.end }?.start ?? max(end, region.end)
      if let loopEnd = region.loopEnd {
        limit = min(limit, loopEnd)
      }
      var repeatStart = region.end
      // Far more repeats than any song needs, in case of a tiny region and a far end.
      var count = 0
      while repeatStart < limit, count < 10_000 {
        var copy = region
        copy.start = repeatStart
        copy.length = min(region.length, limit - repeatStart)
        copy.isLooped = false
        played.append(copy)
        repeatStart = repeatStart + region.length
        count += 1
      }
    }
    return played
  }

  /// The tracks this one feeds: its sends' auxes and, if it isn't Stereo Out, its output.
  public var routedDestinations: [Track.ID] {
    channel.sends.map(\.destinationTrackID) + (channel.output.trackID.map { [$0] } ?? [])
  }
}

/// Mixer settings for a track.
public struct ChannelStrip: Codable, Sendable, Equatable {
  /// Fader range in decibels (Logic's faders top out at +6 dB).
  public static let volumeRange: ClosedRange<Double> = -96...6
  public static let panRange: ClosedRange<Double> = -1...1

  /// Fader level in decibels. 0 dB is unity gain.
  public var volume: Double
  /// -1 is hard left, 0 is center and 1 is hard right.
  public var pan: Double
  public var isMuted: Bool
  public var isSoloed: Bool
  /// The sound source for software instrument tracks. Always `nil` on audio tracks.
  public var instrument: InstrumentSource?
  /// MIDI effects before the instrument, in order (instrument tracks only).
  public var midiEffects: [MIDIEffect]
  /// Insert effects, in signal-flow order.
  public var inserts: [PluginReference]
  /// Sends to aux tracks.
  public var sends: [Send]
  /// The hardware input an audio track records from.
  public var audioInput: AudioInputSelection?
  /// Where the fader's output goes: Stereo Out, or an aux track (such as a summing stack).
  public var output: ChannelOutput

  /// The most insert slots a channel strip has.
  public static let maximumInserts = 8

  public init(
    volume: Double = 0,
    pan: Double = 0,
    isMuted: Bool = false,
    isSoloed: Bool = false,
    instrument: InstrumentSource? = nil,
    midiEffects: [MIDIEffect] = [],
    inserts: [PluginReference] = [],
    sends: [Send] = [],
    audioInput: AudioInputSelection? = nil,
    output: ChannelOutput = .stereoOut
  ) {
    self.volume = volume
    self.pan = pan
    self.isMuted = isMuted
    self.isSoloed = isSoloed
    self.instrument = instrument
    self.midiEffects = midiEffects
    self.inserts = inserts
    self.sends = sends
    self.audioInput = audioInput
    self.output = output
  }

  private enum CodingKeys: String, CodingKey {
    case volume, pan, isMuted, isSoloed, instrument, midiEffects, inserts, sends, audioInput, output
  }

  /// Sends and inputs were added in format version 2, outputs in 5 and MIDI effects in 17;
  /// older projects get the defaults.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    volume = try container.decode(Double.self, forKey: .volume)
    pan = try container.decode(Double.self, forKey: .pan)
    isMuted = try container.decode(Bool.self, forKey: .isMuted)
    isSoloed = try container.decode(Bool.self, forKey: .isSoloed)
    instrument = try container.decodeIfPresent(InstrumentSource.self, forKey: .instrument)
    midiEffects = try container.decodeIfPresent([MIDIEffect].self, forKey: .midiEffects) ?? []
    inserts = try container.decodeIfPresent([PluginReference].self, forKey: .inserts) ?? []
    sends = try container.decodeIfPresent([Send].self, forKey: .sends) ?? []
    audioInput = try container.decodeIfPresent(AudioInputSelection.self, forKey: .audioInput)
    output = try container.decodeIfPresent(ChannelOutput.self, forKey: .output) ?? .stereoOut
  }

  /// Linear gain for the fader level (0 at the bottom of the fader).
  public var linearGain: Double {
    volume <= ChannelStrip.volumeRange.lowerBound ? 0 : pow(10, volume / 20)
  }

  /// A copy with volume and pan clamped to their valid ranges.
  public func clamped() -> ChannelStrip {
    var copy = self
    copy.volume = min(max(volume, ChannelStrip.volumeRange.lowerBound), ChannelStrip.volumeRange.upperBound)
    copy.pan = min(max(pan, ChannelStrip.panRange.lowerBound), ChannelStrip.panRange.upperBound)
    return copy
  }
}

/// Where a channel strip's output goes.
public enum ChannelOutput: Codable, Sendable, Hashable {
  case stereoOut
  /// An aux track's input (a summing stack's subtracks output to the stack).
  case track(Track.ID)

  public var trackID: Track.ID? {
    if case .track(let id) = self { id } else { nil }
  }
}

/// A send from a channel strip to an aux track.
public struct Send: Identifiable, Codable, Sendable, Equatable {
  /// The bottom is off (−∞), as on the fader.
  public static let levelRange: ClosedRange<Double> = -96...6
  /// Where a new send starts, and where resetting its knob puts it back: 6 dB below unity,
  /// so adding a send to a reverb doesn't bring it in at full level.
  public static let defaultLevel = -6.0

  public var id: UUID
  /// The aux track this send feeds.
  public var destinationTrackID: Track.ID
  /// Send level in decibels.
  public var level: Double
  /// Pre-fader sends are taken before the channel's fader and mute, so they don't follow
  /// the fader.
  public var isPreFader: Bool

  public init(id: UUID = UUID(), destinationTrackID: Track.ID, level: Double = Send.defaultLevel, isPreFader: Bool = false) {
    self.id = id
    self.destinationTrackID = destinationTrackID
    self.level = level
    self.isPreFader = isPreFader
  }

  public var linearGain: Double {
    level <= Send.levelRange.lowerBound ? 0 : pow(10, level / 20)
  }
}

/// Which hardware input channels an audio track records.
public struct AudioInputSelection: Codable, Sendable, Equatable, Hashable {
  /// 0-based index of the first input channel ("Input 1" is 0).
  public var firstChannel: Int
  public var isStereo: Bool

  public static let defaultInput = AudioInputSelection(firstChannel: 0, isStereo: false)

  public init(firstChannel: Int, isStereo: Bool) {
    self.firstChannel = max(0, firstChannel)
    self.isStereo = isStereo
  }

  public var channelCount: Int { isStereo ? 2 : 1 }

  /// "Input 1" or "Input 1–2", matching Logic.
  public var displayName: String {
    isStereo ? "Input \(firstChannel + 1)–\(firstChannel + 2)" : "Input \(firstChannel + 1)"
  }
}

/// Where a software instrument track gets its sound.
public enum InstrumentSource: Codable, Sendable, Equatable {
  /// The built-in sampler playing a General MIDI program (0–127) from the system sound bank.
  case generalMIDI(program: Int)
  /// The built-in sampler playing a General MIDI drum kit (0 is the standard kit).
  case generalMIDIPercussion(kit: Int)
  /// A third-party or Apple Audio Unit instrument.
  case audioUnit(PluginReference)

  public static let defaultSampler = InstrumentSource.generalMIDI(program: 0)

  /// A short name for track headers and menus.
  public var displayName: String {
    switch self {
    case .generalMIDI(let program): GeneralMIDI.programName(program)
    case .generalMIDIPercussion(let kit): GeneralMIDI.drumKitName(kit)
    case .audioUnit(let plugin): plugin.name
    }
  }
}

/// Identifies an Audio Unit and stores its saved state.
///
/// The component fields mirror `AudioComponentDescription` so Core stays independent of
/// AudioToolbox; the engine module turns this into a real component.
public struct PluginReference: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  public var componentType: UInt32
  public var componentSubType: UInt32
  public var componentManufacturer: UInt32
  public var name: String
  public var isBypassed: Bool
  /// The plug-in's `fullState`, encoded as a property list.
  public var state: Data?
  /// Only in a saved package's Project.json: a large state (a sampler's audio, say) is kept
  /// in this file in the package's "Plug-in Settings" folder instead (see `ProjectArchive`).
  public var stateFileName: String?

  public init(
    id: UUID = UUID(),
    componentType: UInt32,
    componentSubType: UInt32,
    componentManufacturer: UInt32,
    name: String,
    isBypassed: Bool = false,
    state: Data? = nil
  ) {
    self.id = id
    self.componentType = componentType
    self.componentSubType = componentSubType
    self.componentManufacturer = componentManufacturer
    self.name = name
    self.isBypassed = isBypassed
    self.state = state
  }
}

/// Apple's effects that ship with macOS, offered as Ongaku's built-in effects. They are
/// sandbox-safe Audio Units, so they load in process without a plug-in host.
public enum BuiltInEffect: String, CaseIterable, Sendable {
  case channelEQ, compressor, multibandCompressor, limiter, reverb, delay, distortion, highPass, lowPass

  private static let effectType: UInt32 = 0x6175_6678  // 'aufx'
  private static let apple: UInt32 = 0x6170_706C  // 'appl'

  public var name: String {
    switch self {
    case .channelEQ: "Channel EQ"
    case .compressor: "Compressor"
    case .multibandCompressor: "Multiband Compressor"
    case .limiter: "Limiter"
    case .reverb: "Reverb"
    case .delay: "Delay"
    case .distortion: "Distortion"
    case .highPass: "High Pass Filter"
    case .lowPass: "Low Pass Filter"
    }
  }

  /// Apple's name for the Audio Unit, to tell it from Ongaku's own effect of the same kind.
  public var audioUnitName: String {
    switch self {
    case .channelEQ: "AUNBandEQ"
    case .compressor: "AUDynamicsProcessor"
    case .multibandCompressor: "AUMultibandCompressor"
    case .limiter: "AUPeakLimiter"
    case .reverb: "AUReverb2"
    case .delay: "AUDelay"
    case .distortion: "AUDistortion"
    case .highPass: "AUHipass"
    case .lowPass: "AULowpass"
    }
  }

  /// The Apple Audio Unit subtype ('nbeq', 'dcmp' and so on).
  private var subType: UInt32 {
    let code: String
    switch self {
    case .channelEQ: code = "nbeq"
    case .compressor: code = "dcmp"
    case .multibandCompressor: code = "mcmp"
    case .limiter: code = "lmtr"
    case .reverb: code = "rvb2"
    case .delay: code = "dely"
    case .distortion: code = "dist"
    case .highPass: code = "hpas"
    case .lowPass: code = "lpas"
    }
    return code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
  }

  /// A new insert for this effect.
  public func makeReference() -> PluginReference {
    PluginReference(
      componentType: Self.effectType, componentSubType: subType, componentManufacturer: Self.apple, name: name)
  }

  /// Whether a plug-in is one of the built-in effects (these load in process).
  public static func isBuiltIn(_ plugin: PluginReference) -> Bool {
    plugin.componentManufacturer == apple && plugin.componentType == effectType
  }
}

/// Ongaku's own instruments, from the same Audio Unit extension as its effects.
public enum OngakuInstrument: String, CaseIterable, Sendable {
  case retroSynth, drumMachine, sampler, sessionDrummer

  private static let instrumentType: UInt32 = 0x6175_6D75  // 'aumu'

  public var name: String {
    switch self {
    case .retroSynth: "Retro Synth"
    case .drumMachine: "Drum Machine"
    case .sampler: "Sampler"
    case .sessionDrummer: "Session Drummer"
    }
  }

  /// The subtype in the extension's Info.plist.
  public var subType: UInt32 {
    let code: String
    switch self {
    case .retroSynth: code = "osyn"
    case .drumMachine: code = "odrm"
    case .sampler: code = "ospl"
    case .sessionDrummer: code = "odrr"
    }
    return code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
  }

  public var componentType: UInt32 { Self.instrumentType }

  /// The size its interface is designed for (see `OngakuEffect.windowSize`), with the
  /// plug-ins' shared header.
  public var windowSize: CGSize {
    let size: CGSize = switch self {
    case .retroSynth: CGSize(width: 1180, height: 610)
    case .drumMachine: CGSize(width: 980, height: 560)
    case .sampler: CGSize(width: 1180, height: 700)
    case .sessionDrummer: CGSize(width: 1180, height: 560)
    }
    return CGSize(width: size.width, height: size.height + OngakuEffect.headerHeight)
  }

  public func makeReference() -> PluginReference {
    PluginReference(
      componentType: Self.instrumentType, componentSubType: subType, componentManufacturer: OngakuEffect.manufacturer,
      name: name)
  }

  public init?(_ plugin: PluginReference) {
    guard plugin.componentManufacturer == OngakuEffect.manufacturer, plugin.componentType == Self.instrumentType,
      let instrument = Self.allCases.first(where: { $0.subType == plugin.componentSubType })
    else { return nil }
    self = instrument
  }
}

/// Ongaku's own effects, from the OngakuEffects Audio Unit extension inside the app. They
/// load out of process like other Audio Units, and work in other hosts too.
public enum OngakuEffect: String, CaseIterable, Sendable {
  case channelEQ, compressor, reverb, delay
  case noiseGate, transientShaper, maximizer, deEsser, saturation, doubler, convolutionReverb, vocalStrip
  case mastering

  private static let effectType: UInt32 = 0x6175_6678  // 'aufx'
  public static let manufacturer: UInt32 = 0x4F6E_676B  // 'Ongk'

  public var name: String {
    switch self {
    case .channelEQ: "Channel EQ"
    case .compressor: "Compressor"
    case .reverb: "Reverb"
    case .delay: "Delay"
    case .noiseGate: "Noise Gate"
    case .transientShaper: "Transient Shaper"
    case .maximizer: "Maximizer"
    case .deEsser: "De-Esser"
    case .saturation: "Saturation"
    case .doubler: "Doubler"
    case .convolutionReverb: "Convolution Reverb"
    case .vocalStrip: "Vocal Strip"
    case .mastering: "Mastering"
    }
  }

  /// Where it's listed in the Add Insert menu, as Logic groups its plug-ins.
  public enum Category: String, CaseIterable, Sendable {
    case eq = "EQ", dynamics = "Dynamics", reverbAndDelay = "Reverb & Delay", distortion = "Distortion",
      imaging = "Imaging", vocal = "Vocal", mastering = "Mastering"
  }

  public var category: Category {
    switch self {
    case .channelEQ: .eq
    case .compressor, .noiseGate, .transientShaper, .maximizer, .deEsser: .dynamics
    case .reverb, .delay, .convolutionReverb: .reverbAndDelay
    case .saturation: .distortion
    case .doubler: .imaging
    case .vocalStrip: .vocal
    case .mastering: .mastering
    }
  }

  /// The subtype in the extension's Info.plist.
  public var subType: UInt32 {
    let code: String
    switch self {
    case .channelEQ: code = "oeq1"
    case .compressor: code = "ocmp"
    case .reverb: code = "orvb"
    case .delay: code = "odly"
    case .noiseGate: code = "ogat"
    case .transientShaper: code = "otrn"
    case .maximizer: code = "omax"
    case .deEsser: code = "odes"
    case .saturation: code = "osat"
    case .doubler: code = "odbl"
    case .convolutionReverb: code = "ocnv"
    case .vocalStrip: code = "ovox"
    case .mastering: code = "omst"
    }
    return code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
  }

  /// The height of the header every Ongaku plug-in has above its own interface (presets,
  /// A/B, undo; the extension's `PluginHeader.height`).
  public static let headerHeight: CGFloat = 36

  /// The size its interface is designed for, header included (the extension's
  /// `OngakuEffect.windowSize` says the same; hosts can't always get it from an extension in
  /// time).
  public var windowSize: CGSize {
    let size: CGSize = switch self {
    case .channelEQ: CGSize(width: 720, height: 420)
    case .compressor: CGSize(width: 720, height: 380)
    case .reverb: CGSize(width: 900, height: 360)
    case .delay: CGSize(width: 900, height: 340)
    case .noiseGate: CGSize(width: 720, height: 340)
    case .transientShaper: CGSize(width: 660, height: 340)
    case .maximizer: CGSize(width: 820, height: 380)
    case .deEsser: CGSize(width: 700, height: 340)
    case .saturation: CGSize(width: 720, height: 360)
    case .doubler: CGSize(width: 700, height: 340)
    case .convolutionReverb: CGSize(width: 900, height: 380)
    case .vocalStrip: CGSize(width: 860, height: 360)
    case .mastering: CGSize(width: 960, height: 470)
    }
    return CGSize(width: size.width, height: size.height + Self.headerHeight)
  }

  public func makeReference() -> PluginReference {
    PluginReference(
      componentType: Self.effectType, componentSubType: subType, componentManufacturer: Self.manufacturer, name: name)
  }

  public init?(_ plugin: PluginReference) {
    guard plugin.componentManufacturer == Self.manufacturer,
      let effect = Self.allCases.first(where: { $0.subType == plugin.componentSubType })
    else { return nil }
    self = effect
  }
}

extension OngakuEffect {
  /// The Mastering parameters Ongaku drives itself, for Analyze Whole Song (the same
  /// addresses as the extension's OngakuEffectsParameterAddresses.h, which never change).
  public enum MasteringParameter {
    /// The song's loudness as Listen measured it (LUFS); `notMeasured` until then.
    public static let measuredLoudness: UInt64 = 1640
    /// On while it listens; turning it off analyses what it heard.
    public static let listen: UInt64 = 1650
    public static let notMeasured: Float = -70
  }
}
