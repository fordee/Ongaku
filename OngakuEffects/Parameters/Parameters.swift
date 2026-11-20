//
//  Parameters.swift
//  OngakuEffects
//

import AudioToolbox
import Foundation

/// The effects and instruments in the extension, one per Audio Unit subtype (listed in
/// Info.plist).
enum OngakuEffect: CaseIterable {
  case channelEQ, compressor, reverb, delay, retroSynth, drumMachine, sampler
  case noiseGate, transientShaper, maximizer, deEsser, saturation, doubler, convolutionReverb, vocalStrip
  case sessionDrummer, mastering
  case chorus, flanger, phaser, tremolo
  case gain, tuner, multibandCompressor
  case electricPiano, organ

  init?(subType: FourCharCode) {
    guard let effect = Self.allCases.first(where: { $0.subType == subType }) else { return nil }
    self = effect
  }

  var subType: FourCharCode {
    switch self {
    case .channelEQ: FourCharCode("oeq1")
    case .compressor: FourCharCode("ocmp")
    case .reverb: FourCharCode("orvb")
    case .delay: FourCharCode("odly")
    case .retroSynth: FourCharCode("osyn")
    case .drumMachine: FourCharCode("odrm")
    case .sampler: FourCharCode("ospl")
    case .noiseGate: FourCharCode("ogat")
    case .transientShaper: FourCharCode("otrn")
    case .maximizer: FourCharCode("omax")
    case .deEsser: FourCharCode("odes")
    case .saturation: FourCharCode("osat")
    case .doubler: FourCharCode("odbl")
    case .convolutionReverb: FourCharCode("ocnv")
    case .vocalStrip: FourCharCode("ovox")
    case .sessionDrummer: FourCharCode("odrr")
    case .mastering: FourCharCode("omst")
    case .chorus: FourCharCode("ocho")
    case .flanger: FourCharCode("oflg")
    case .phaser: FourCharCode("ophs")
    case .tremolo: FourCharCode("otrm")
    case .gain: FourCharCode("ogin")
    case .tuner: FourCharCode("otun")
    case .multibandCompressor: FourCharCode("ombc")
    case .electricPiano: FourCharCode("oepn")
    case .organ: FourCharCode("oorg")
    }
  }

  /// Instruments play MIDI and have no audio input.
  var isInstrument: Bool {
    self == .retroSynth || self == .drumMachine || self == .sampler || self == .sessionDrummer || self == .electricPiano
      || self == .organ
  }

  var kind: OngakuEffectKind {
    switch self {
    case .channelEQ: .channelEQ
    case .compressor: .compressor
    case .reverb: .reverb
    case .delay: .delay
    case .retroSynth: .retroSynth
    case .drumMachine: .drumMachine
    case .sampler: .sampler
    case .noiseGate: .noiseGate
    case .transientShaper: .transientShaper
    case .maximizer: .maximizer
    case .deEsser: .deEsser
    case .saturation: .saturation
    case .doubler: .doubler
    case .convolutionReverb: .convolutionReverb
    case .vocalStrip: .vocalStrip
    case .sessionDrummer: .sessionDrummer
    case .mastering: .mastering
    case .chorus: .chorus
    case .flanger: .flanger
    case .phaser: .phaser
    case .tremolo: .tremolo
    case .gain: .gain
    case .tuner: .tuner
    case .multibandCompressor: .multibandCompressor
    case .electricPiano: .electricPiano
    case .organ: .organ
    }
  }

  /// The size the interface would like (Ongaku's `OngakuEffect.windowSize` matches).
  /// The window: the shared header (presets, A/B, undo) above the effect's own interface.
  var windowSize: CGSize {
    CGSize(width: preferredSize.width, height: preferredSize.height + PluginHeader.height)
  }

  /// The effect's own interface, below the header.
  var preferredSize: CGSize {
    switch self {
    case .channelEQ: CGSize(width: 720, height: 420)
    case .compressor: CGSize(width: 720, height: 380)
    case .reverb: CGSize(width: 900, height: 360)
    case .delay: CGSize(width: 900, height: 340)
    case .retroSynth: CGSize(width: 1180, height: 610)
    case .drumMachine: CGSize(width: 980, height: 560)
    case .sampler: CGSize(width: 1180, height: 700)
    case .noiseGate: CGSize(width: 720, height: 340)
    case .transientShaper: CGSize(width: 660, height: 340)
    case .maximizer: CGSize(width: 820, height: 380)
    case .deEsser: CGSize(width: 700, height: 340)
    case .saturation: CGSize(width: 720, height: 360)
    case .doubler: CGSize(width: 700, height: 340)
    case .convolutionReverb: CGSize(width: 900, height: 380)
    case .vocalStrip: CGSize(width: 860, height: 360)
    case .sessionDrummer: CGSize(width: 1180, height: 560)
    case .mastering: CGSize(width: 960, height: 470)
    case .chorus, .flanger, .phaser, .tremolo: CGSize(width: 720, height: 340)
    case .gain: CGSize(width: 640, height: 320)
    case .tuner: CGSize(width: 640, height: 360)
    case .multibandCompressor: CGSize(width: 860, height: 480)
    case .electricPiano: CGSize(width: 980, height: 440)
    case .organ: CGSize(width: 1080, height: 500)
    }
  }

  var parameters: ParameterTreeSpec {
    switch self {
    case .channelEQ: ChannelEQParameters.tree
    case .compressor: CompressorParameters.tree
    case .reverb: ReverbParameters.tree
    case .delay: DelayParameters.tree
    case .retroSynth: RetroSynthParameters.tree
    case .drumMachine: DrumMachineParameters.tree
    case .sampler: SamplerParameters.tree
    case .noiseGate: NoiseGateParameters.tree
    case .transientShaper: TransientShaperParameters.tree
    case .maximizer: MaximizerParameters.tree
    case .deEsser: DeEsserParameters.tree
    case .saturation: SaturationParameters.tree
    case .doubler: DoublerParameters.tree
    case .convolutionReverb: ConvolutionReverbParameters.tree
    case .vocalStrip: VocalStripParameters.tree
    case .sessionDrummer: SessionDrummerParameters.tree
    case .mastering: MasteringParameters.tree
    case .chorus: ModulationParameters.chorus
    case .flanger: ModulationParameters.flanger
    case .phaser: ModulationParameters.phaser
    case .tremolo: ModulationParameters.tremolo
    case .gain: UtilityParameters.gain
    case .tuner: UtilityParameters.tuner
    case .multibandCompressor: MultibandParameters.tree
    case .electricPiano: KeysParameters.electricPiano
    case .organ: KeysParameters.organ
    }
  }

  /// Factory presets: the Reverb's rooms, the Retro Synth's patches.
  var presets: [EffectPreset] {
    switch self {
    case .reverb: ReverbParameters.rooms.map { EffectPreset(name: $0.name, values: $0.values, resetsOthers: false) }
    case .retroSynth: RetroSynthParameters.patches
    case .drumMachine: DrumMachineParameters.kits
    case .sampler: SamplerParameters.presets
    case .noiseGate: NoiseGateParameters.presets
    case .transientShaper: TransientShaperParameters.presets
    case .maximizer: MaximizerParameters.presets
    case .deEsser: DeEsserParameters.presets
    case .saturation: SaturationParameters.presets
    case .doubler: DoublerParameters.presets
    case .convolutionReverb: ConvolutionReverbParameters.presets
    case .vocalStrip: VocalStripParameters.presets
    // The drummer's kit is the Drum Machine's, so its kits are the presets.
    case .sessionDrummer: DrumMachineParameters.kits
    case .mastering: MasteringParameters.presets
    case .chorus: ModulationParameters.chorusPresets
    case .flanger: ModulationParameters.flangerPresets
    case .phaser: ModulationParameters.phaserPresets
    case .tremolo: ModulationParameters.tremoloPresets
    case .gain: UtilityParameters.gainPresets
    case .multibandCompressor: MultibandParameters.presets
    case .electricPiano: KeysParameters.electricPianoPresets
    case .organ: KeysParameters.organPresets
    default: []
    }
  }

  /// The preset a new instance starts as (its parameters' defaults match it).
  var defaultPreset: Int? {
    switch self {
    case .reverb: ReverbParameters.defaultRoom
    case .retroSynth: 0
    case .drumMachine, .sessionDrummer: 0
    case .sampler: 0
    case .noiseGate, .transientShaper, .maximizer, .deEsser, .saturation, .doubler, .convolutionReverb, .vocalStrip: 0
    case .mastering: 0
    case .chorus, .flanger, .phaser, .tremolo, .gain, .multibandCompressor, .electricPiano, .organ: 0
    default: nil
    }
  }
}

/// A factory preset: values for some parameters.
struct EffectPreset {
  var name: String
  var values: [AUParameterAddress: AUValue]
  /// Whether parameters it doesn't set go back to their defaults (a synth patch), or stay as
  /// they are (a reverb room leaves the mix alone).
  var resetsOthers: Bool
}

extension FourCharCode {
  init(_ code: StaticString) {
    self = code.withUTF8Buffer { $0.reduce(0) { $0 << 8 | FourCharCode($1) } }
  }
}

/// The Channel EQ's parameters: an output gain, then eight bands from the low cut up.
enum ChannelEQParameters {
  struct Band {
    var identifier: String
    var name: String
    var isOn: Bool
    var frequency: AUValue
    var q: AUValue
    var isCut: Bool { identifier == "lowCut" || identifier == "highCut" }
  }

  static let bands = [
    Band(identifier: "lowCut", name: "Low Cut", isOn: false, frequency: 30, q: 0.71),
    Band(identifier: "lowShelf", name: "Low Shelf", isOn: true, frequency: 80, q: 0.71),
    Band(identifier: "lowMid", name: "Low Mid", isOn: true, frequency: 200, q: 1.1),
    Band(identifier: "mid", name: "Mid", isOn: true, frequency: 500, q: 1.1),
    Band(identifier: "highMid", name: "High Mid", isOn: true, frequency: 1_500, q: 1.1),
    Band(identifier: "presence", name: "Presence", isOn: true, frequency: 4_000, q: 1.1),
    Band(identifier: "highShelf", name: "High Shelf", isOn: true, frequency: 10_000, q: 0.71),
    Band(identifier: "highCut", name: "High Cut", isOn: false, frequency: 17_000, q: 0.71),
  ]

  static let slopes = ["6 dB/Oct", "12 dB/Oct", "18 dB/Oct", "24 dB/Oct", "36 dB/Oct", "48 dB/Oct"]

  static func address(band: Int, _ field: OngakuEQBandField) -> AUParameterAddress {
    OngakuEffectsParameterAddress.eqFirstBand.rawValue
      + AUParameterAddress(Int(OngakuEQBandStride) * band + Int(field.rawValue))
  }

  static let tree = ParameterTreeSpec {
    ParameterSpec(
      address: OngakuEffectsParameterAddress.eqOutputGain.rawValue, identifier: "outputGain", name: "Gain",
      units: .decibels, valueRange: -24...24, defaultValue: 0)
    for (index, band) in bands.enumerated() {
      ParameterGroupSpec(identifier: band.identifier, name: band.name) {
        ParameterSpec(
          address: address(band: index, .on), identifier: "on", name: "\(band.name) On",
          units: .boolean, valueRange: 0...1, defaultValue: band.isOn ? 1 : 0)
        ParameterSpec(
          address: address(band: index, .frequency), identifier: "frequency", name: "\(band.name) Frequency",
          units: .hertz, valueRange: 20...20_000, defaultValue: band.frequency,
          flags: [.flag_IsWritable, .flag_IsReadable, .flag_DisplayLogarithmic])
        ParameterSpec(
          address: address(band: index, .Q), identifier: "q", name: "\(band.name) Q",
          units: .generic, valueRange: 0.1...12, defaultValue: band.q,
          flags: [.flag_IsWritable, .flag_IsReadable, .flag_DisplayLogarithmic])
        if band.isCut {
          ParameterSpec(
            address: address(band: index, .slope), identifier: "slope", name: "\(band.name) Slope",
            units: .indexed, valueRange: 0...5, defaultValue: 1, valueStrings: slopes)
        } else {
          ParameterSpec(
            address: address(band: index, .gain), identifier: "gain", name: "\(band.name) Gain",
            units: .decibels, valueRange: -24...24, defaultValue: 0)
        }
      }
    }
  }
}

/// The Compressor's parameters.
enum CompressorParameters {
  private static let logarithmic: AudioUnitParameterOptions = [.flag_IsWritable, .flag_IsReadable, .flag_DisplayLogarithmic]

  static let tree = ParameterTreeSpec {
    ParameterSpec(
      address: OngakuEffectsParameterAddress.compThreshold.rawValue, identifier: "threshold", name: "Threshold",
      units: .decibels, valueRange: -60...0, defaultValue: -20)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.compRatio.rawValue, identifier: "ratio", name: "Ratio",
      units: .ratio, valueRange: 1...30, defaultValue: 4, flags: logarithmic)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.compAttack.rawValue, identifier: "attack", name: "Attack",
      units: .milliseconds, valueRange: 0.1...200, defaultValue: 10, flags: logarithmic)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.compRelease.rawValue, identifier: "release", name: "Release",
      units: .milliseconds, valueRange: 5...2_000, defaultValue: 150, flags: logarithmic)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.compKnee.rawValue, identifier: "knee", name: "Knee",
      units: .decibels, valueRange: 0...24, defaultValue: 6)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.compMakeUp.rawValue, identifier: "makeUp", name: "Make Up",
      units: .decibels, valueRange: -20...40, defaultValue: 0)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.compAutoGain.rawValue, identifier: "autoGain", name: "Auto Gain",
      units: .boolean, valueRange: 0...1, defaultValue: 0)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.compMix.rawValue, identifier: "mix", name: "Mix",
      units: .percent, valueRange: 0...100, defaultValue: 100)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.compDetection.rawValue, identifier: "detection", name: "Detection",
      units: .indexed, valueRange: 0...1, defaultValue: 0, valueStrings: ["Peak", "RMS"])
  }
}

/// The Reverb's parameters, and its rooms (offered as factory presets).
enum ReverbParameters {
  private static let logarithmic: AudioUnitParameterOptions = [.flag_IsWritable, .flag_IsReadable, .flag_DisplayLogarithmic]

  static let tree = ParameterTreeSpec {
    ParameterSpec(
      address: OngakuEffectsParameterAddress.verbPredelay.rawValue, identifier: "predelay", name: "Predelay",
      units: .milliseconds, valueRange: 0...250, defaultValue: 25)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.verbDecay.rawValue, identifier: "decay", name: "Decay",
      units: .seconds, valueRange: 0.2...20, defaultValue: 2.8, flags: logarithmic)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.verbSize.rawValue, identifier: "size", name: "Size",
      units: .percent, valueRange: 0...100, defaultValue: 75)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.verbDiffusion.rawValue, identifier: "diffusion", name: "Diffusion",
      units: .percent, valueRange: 0...100, defaultValue: 75)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.verbHighCut.rawValue, identifier: "highCut", name: "High Cut",
      units: .hertz, valueRange: 1_000...20_000, defaultValue: 7_000, flags: logarithmic)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.verbLowCut.rawValue, identifier: "lowCut", name: "Low Cut",
      units: .hertz, valueRange: 20...1_000, defaultValue: 60, flags: logarithmic)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.verbModulation.rawValue, identifier: "modulation", name: "Modulation",
      units: .percent, valueRange: 0...100, defaultValue: 30)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.verbWidth.rawValue, identifier: "width", name: "Width",
      units: .percent, valueRange: 0...100, defaultValue: 100)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.verbMix.rawValue, identifier: "mix", name: "Mix",
      units: .percent, valueRange: 0...100, defaultValue: 30)
  }

  /// A room: settings for every parameter but the mix, which stays as the user set it.
  struct Room {
    var name: String
    var predelay, decay, size, diffusion, highCut, lowCut, modulation, width: AUValue

    var values: [AUParameterAddress: AUValue] {
      let pairs: [(OngakuEffectsParameterAddress, AUValue)] = [
        (.verbPredelay, predelay), (.verbDecay, decay), (.verbSize, size), (.verbDiffusion, diffusion),
        (.verbHighCut, highCut), (.verbLowCut, lowCut), (.verbModulation, modulation), (.verbWidth, width)]
      return Dictionary(uniqueKeysWithValues: pairs.map { ($0.rawValue, $1) })
    }
  }

  /// The room a new Reverb starts as (the parameters' defaults match it).
  static let defaultRoom = 2

  static let rooms = [
    Room(name: "Room", predelay: 4, decay: 0.8, size: 25, diffusion: 70, highCut: 7_000, lowCut: 100, modulation: 15, width: 80),
    Room(name: "Chamber", predelay: 10, decay: 1.4, size: 45, diffusion: 80, highCut: 8_000, lowCut: 80, modulation: 20, width: 100),
    Room(name: "Hall", predelay: 25, decay: 2.8, size: 75, diffusion: 75, highCut: 7_000, lowCut: 60, modulation: 30, width: 100),
    Room(name: "Plate", predelay: 0, decay: 1.8, size: 40, diffusion: 95, highCut: 12_000, lowCut: 120, modulation: 40, width: 100),
    Room(name: "Cathedral", predelay: 40, decay: 7, size: 100, diffusion: 85, highCut: 5_000, lowCut: 50, modulation: 35, width: 100),
  ]
}

/// The Delay's parameters.
enum DelayParameters {
  private static let logarithmic: AudioUnitParameterOptions = [.flag_IsWritable, .flag_IsReadable, .flag_DisplayLogarithmic]

  static let notes = ["1/32", "1/16T", "1/16", "1/16.", "1/8T", "1/8", "1/8.", "1/4T", "1/4", "1/4.", "1/2"]
  /// Each note value in quarter notes (the kernel's `Delay::noteBeats` matches).
  static let noteBeats: [Double] = [0.125, 1.0 / 6, 0.25, 0.375, 1.0 / 3, 0.5, 0.75, 2.0 / 3, 1, 1.5, 2]

  static let tree = ParameterTreeSpec {
    ParameterSpec(
      address: OngakuEffectsParameterAddress.dlySync.rawValue, identifier: "sync", name: "Sync",
      units: .boolean, valueRange: 0...1, defaultValue: 1)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.dlyTime.rawValue, identifier: "time", name: "Time",
      units: .milliseconds, valueRange: 1...2_000, defaultValue: 375, flags: logarithmic)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.dlyNote.rawValue, identifier: "note", name: "Note",
      units: .indexed, valueRange: 0...10, defaultValue: 6, valueStrings: notes)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.dlyFeedback.rawValue, identifier: "feedback", name: "Feedback",
      units: .percent, valueRange: 0...100, defaultValue: 35)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.dlyPingPong.rawValue, identifier: "pingPong", name: "Ping-Pong",
      units: .boolean, valueRange: 0...1, defaultValue: 0)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.dlyLowCut.rawValue, identifier: "lowCut", name: "Low Cut",
      units: .hertz, valueRange: 20...2_000, defaultValue: 120, flags: logarithmic)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.dlyHighCut.rawValue, identifier: "highCut", name: "High Cut",
      units: .hertz, valueRange: 500...20_000, defaultValue: 5_000, flags: logarithmic)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.dlyFlutter.rawValue, identifier: "flutter", name: "Wow & Flutter",
      units: .percent, valueRange: 0...100, defaultValue: 20)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.dlyDrive.rawValue, identifier: "drive", name: "Drive",
      units: .percent, valueRange: 0...100, defaultValue: 15)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.dlyMix.rawValue, identifier: "mix", name: "Mix",
      units: .percent, valueRange: 0...100, defaultValue: 30)
  }
}

/// The Retro Synth's parameters and patches.
enum RetroSynthParameters {
  private static let logarithmic: AudioUnitParameterOptions = [.flag_IsWritable, .flag_IsReadable, .flag_DisplayLogarithmic]

  static let waves = ["Saw", "Pulse", "Triangle", "Sine"]
  static let lfoWaves = ["Triangle", "Square", "Random"]

  private static func spec(
    _ address: OngakuEffectsParameterAddress, _ identifier: String, _ name: String, _ units: AudioUnitParameterUnit,
    _ range: ClosedRange<AUValue>, _ value: AUValue, logarithmic isLogarithmic: Bool = false, strings: [String]? = nil
  ) -> ParameterSpec {
    ParameterSpec(
      address: address.rawValue, identifier: identifier, name: name, units: units, valueRange: range, defaultValue: value,
      flags: isLogarithmic ? logarithmic : [.flag_IsWritable, .flag_IsReadable], valueStrings: strings)
  }

  /// The defaults are the first patch, Analog Saws. Names are what hosts and automation
  /// menus show, so each matches (or contains) the knob's label on the panel.
  static let tree = ParameterTreeSpec {
    spec(.synOsc1Wave, "osc1Wave", "Osc 1 Wave", .indexed, 0...3, 0, strings: waves)
    spec(.synOsc2Wave, "osc2Wave", "Osc 2 Wave", .indexed, 0...3, 0, strings: waves)
    spec(.synOsc2Semitones, "osc2Semitones", "Osc 2 Pitch", .relativeSemiTones, -24...24, 0)
    spec(.synOsc2Detune, "osc2Detune", "Osc 2 Fine Tune", .cents, -50...50, 7)
    spec(.synOscMix, "oscMix", "Osc Mix", .percent, 0...100, 50)
    spec(.synPulseWidth, "pulseWidth", "Osc 1 Shape", .percent, 5...95, 50)
    spec(.synNoise, "noise", "Noise", .percent, 0...100, 0)
    spec(.synCutoff, "cutoff", "Cutoff", .hertz, 20...20_000, 2_500, logarithmic: true)
    spec(.synResonance, "resonance", "Resonance", .percent, 0...100, 20)
    spec(.synFilterEnv, "filterEnv", "Filter Env Amount", .percent, -100...100, 40)
    spec(.synKeyTrack, "keyTrack", "Key Track", .percent, 0...100, 50)
    spec(.synFilterAttack, "filterAttack", "Filter Attack", .milliseconds, 1...10_000, 5, logarithmic: true)
    spec(.synFilterDecay, "filterDecay", "Filter Decay", .milliseconds, 1...10_000, 400, logarithmic: true)
    spec(.synFilterSustain, "filterSustain", "Filter Sustain", .percent, 0...100, 30)
    spec(.synFilterRelease, "filterRelease", "Filter Release", .milliseconds, 1...10_000, 300, logarithmic: true)
    spec(.synAmpAttack, "ampAttack", "Attack", .milliseconds, 1...10_000, 5, logarithmic: true)
    spec(.synAmpDecay, "ampDecay", "Decay", .milliseconds, 1...10_000, 300, logarithmic: true)
    spec(.synAmpSustain, "ampSustain", "Sustain", .percent, 0...100, 80)
    spec(.synAmpRelease, "ampRelease", "Release", .milliseconds, 1...10_000, 300, logarithmic: true)
    spec(.synLfoRate, "lfoRate", "LFO Rate", .hertz, 0.05...20, 5, logarithmic: true)
    spec(.synLfoWave, "lfoWave", "LFO Wave", .indexed, 0...2, 0, strings: lfoWaves)
    spec(.synLfoPitch, "lfoPitch", "Vibrato", .cents, 0...100, 0)
    spec(.synLfoFilter, "lfoFilter", "LFO Wah (to Filter)", .percent, 0...100, 0)
    spec(.synLfoPulse, "lfoPulse", "LFO PWM (to Shape)", .percent, 0...100, 0)
    spec(.synGlide, "glide", "Glide", .milliseconds, 0...2_000, 0)
    spec(.synVelocity, "velocity", "Velocity", .percent, 0...100, 60)
    spec(.synMode, "mode", "Voices", .indexed, 0...1, 0, strings: ["Poly", "Mono"])
    spec(.synBendRange, "bendRange", "Bend Range", .relativeSemiTones, 1...12, 2)
    spec(.synGain, "gain", "Volume", .decibels, -24...12, 0)
    spec(.synOsc2Shape, "osc2Shape", "Osc 2 Shape", .percent, 5...95, 50)
    spec(.synOsc2Mode, "osc2Mode", "Osc 2 Mode", .indexed, 0...2, 0, strings: ["Normal", "Sync", "Ring"])
    spec(.synFM, "fm", "FM", .percent, 0...100, 0)
    spec(.synSubLevel, "sub", "Sub Osc", .percent, 0...100, 0)
    // Plain numbers: an indexed parameter's names must match its range exactly (auval
    // fails it otherwise), and the number is its own name.
    spec(.synUnison, "unison", "Unison Voices", .indexed, 1...7, 1)
    spec(.synUnisonDetune, "unisonDetune", "Unison Detune", .cents, 0...100, 20)
    spec(.synUnisonSpread, "unisonSpread", "Stereo Spread", .percent, 0...100, 60)
  }

  private static func patch(_ name: String, _ values: [(OngakuEffectsParameterAddress, AUValue)]) -> EffectPreset {
    EffectPreset(name: name, values: Dictionary(uniqueKeysWithValues: values.map { ($0.rawValue, $1) }), resetsOthers: true)
  }

  /// Patches change what they need from the defaults (Analog Saws).
  static let patches: [EffectPreset] = [
    patch("Analog Saws", []),
    patch("Fat Bass", [
      (.synOsc2Wave, 1), (.synOsc2Semitones, -12), (.synOsc2Detune, 5), (.synOscMix, 40), (.synSubLevel, 50), (.synCutoff, 300),
      (.synResonance, 35), (.synFilterEnv, 55), (.synFilterDecay, 250), (.synFilterSustain, 10), (.synAmpAttack, 2),
      (.synAmpDecay, 200), (.synAmpSustain, 90), (.synAmpRelease, 120), (.synMode, 1), (.synGlide, 40),
    ]),
    patch("Soft Pad", [
      (.synOsc2Wave, 2), (.synOsc2Semitones, 12), (.synOsc2Detune, 9), (.synCutoff, 1_200), (.synResonance, 10),
      (.synFilterEnv, 25), (.synFilterAttack, 800), (.synFilterDecay, 1_500), (.synFilterSustain, 60),
      (.synFilterRelease, 1_500), (.synAmpAttack, 900), (.synAmpDecay, 1_000), (.synAmpSustain, 85),
      (.synAmpRelease, 1_800), (.synLfoRate, 0.4), (.synLfoFilter, 15),
    ]),
    patch("Square Lead", [
      (.synOsc1Wave, 1), (.synOsc2Wave, 1), (.synOsc2Detune, 12), (.synPulseWidth, 40), (.synOsc2Shape, 40), (.synCutoff, 3_500),
      (.synResonance, 25), (.synFilterEnv, 30), (.synAmpAttack, 3), (.synAmpDecay, 200), (.synAmpSustain, 90),
      (.synAmpRelease, 200), (.synMode, 1), (.synGlide, 80), (.synLfoRate, 5.5),
    ]),
    patch("Brass", [
      (.synOsc2Detune, 10), (.synCutoff, 700), (.synResonance, 15), (.synFilterEnv, 70), (.synFilterAttack, 80),
      (.synFilterDecay, 500), (.synFilterSustain, 50), (.synFilterRelease, 200), (.synAmpAttack, 40),
      (.synAmpDecay, 300), (.synAmpSustain, 85), (.synAmpRelease, 250),
    ]),
    patch("Pluck", [
      (.synOsc2Wave, 1), (.synOsc2Semitones, 12), (.synCutoff, 600), (.synResonance, 30), (.synFilterEnv, 75),
      (.synFilterAttack, 1), (.synFilterDecay, 220), (.synFilterSustain, 0), (.synFilterRelease, 200),
      (.synAmpAttack, 1), (.synAmpDecay, 450), (.synAmpSustain, 0), (.synAmpRelease, 350),
    ]),
    patch("PWM Strings", [
      (.synOsc1Wave, 1), (.synOsc2Wave, 1), (.synOsc2Detune, 8), (.synLfoRate, 0.7), (.synLfoPulse, 60),
      (.synAmpAttack, 300), (.synAmpDecay, 800), (.synAmpSustain, 85), (.synAmpRelease, 900),
    ]),
    patch("Supersaw", [
      (.synOsc2Detune, 0), (.synUnison, 7), (.synUnisonDetune, 30), (.synUnisonSpread, 90), (.synCutoff, 6_000),
      (.synResonance, 10), (.synFilterEnv, 15), (.synAmpAttack, 10), (.synAmpRelease, 500),
    ]),
    patch("Sync Lead", [
      (.synOsc2Mode, 1), (.synOsc2Semitones, 7), (.synOscMix, 80), (.synCutoff, 5_000), (.synResonance, 15),
      (.synFilterEnv, 20), (.synAmpSustain, 90), (.synMode, 1), (.synGlide, 60), (.synUnison, 2), (.synUnisonDetune, 10),
    ]),
    patch("Ring Bells", [
      (.synOsc1Wave, 3), (.synOsc2Wave, 3), (.synOsc2Mode, 2), (.synOsc2Semitones, 19), (.synOscMix, 70),
      (.synCutoff, 9_000), (.synResonance, 0), (.synFilterEnv, 0), (.synAmpAttack, 1), (.synAmpDecay, 1_800),
      (.synAmpSustain, 0), (.synAmpRelease, 1_500),
    ]),
    patch("FM Keys", [
      (.synOsc1Wave, 3), (.synOsc2Wave, 3), (.synOsc2Semitones, 12), (.synOsc2Detune, 0), (.synOscMix, 0), (.synFM, 45),
      (.synCutoff, 8_000), (.synResonance, 0), (.synFilterEnv, 0), (.synAmpAttack, 2), (.synAmpDecay, 1_200),
      (.synAmpSustain, 30), (.synAmpRelease, 600), (.synVelocity, 80),
    ]),
    patch("Sub Bass", [
      (.synOsc1Wave, 2), (.synOscMix, 0), (.synSubLevel, 90), (.synCutoff, 900), (.synResonance, 5), (.synFilterEnv, 10),
      (.synAmpAttack, 2), (.synAmpRelease, 120), (.synMode, 1),
    ]),
  ]
}

/// The Drum Machine's parameters and kits.
enum DrumMachineParameters {
  struct Pad {
    var identifier: String
    var name: String
    var note: Int
    /// What its Tone knob changes.
    var toneName: String
    var toneHelp: String
    var pan: AUValue
  }

  static let pads = [
    Pad(identifier: "kick", name: "Kick", note: 36, toneName: "Click", toneHelp: "How much click the kick starts with: more cuts through a busy mix.", pan: 0),
    Pad(identifier: "snare", name: "Snare", note: 38, toneName: "Snappy", toneHelp: "How much the snares rattle against the drum's body.", pan: 0),
    Pad(identifier: "clap", name: "Clap", note: 39, toneName: "Brightness", toneHelp: "How bright the clap is.", pan: 0),
    Pad(identifier: "rim", name: "Rim", note: 37, toneName: "Tone", toneHelp: "The rimshot doesn't use Tone: use Tune instead.", pan: -10),
    Pad(identifier: "closedHat", name: "Closed Hat", note: 42, toneName: "Brightness", toneHelp: "How bright and sizzly the hi-hat is.", pan: 15),
    Pad(identifier: "openHat", name: "Open Hat", note: 46, toneName: "Brightness", toneHelp: "How bright and sizzly the hi-hat is. The closed hat cuts it off.", pan: 15),
    Pad(identifier: "lowTom", name: "Low Tom", note: 45, toneName: "Attack", toneHelp: "How much stick attack the tom has.", pan: -30),
    Pad(identifier: "midTom", name: "Mid Tom", note: 47, toneName: "Attack", toneHelp: "How much stick attack the tom has.", pan: 0),
    Pad(identifier: "highTom", name: "High Tom", note: 50, toneName: "Attack", toneHelp: "How much stick attack the tom has.", pan: 30),
    Pad(identifier: "cowbell", name: "Cowbell", note: 56, toneName: "Tone", toneHelp: "The cowbell doesn't use Tone: use Tune instead.", pan: -20),
    Pad(identifier: "crash", name: "Crash", note: 49, toneName: "Brightness", toneHelp: "How bright the cymbal is.", pan: -15),
    Pad(identifier: "shaker", name: "Shaker", note: 70, toneName: "Tone", toneHelp: "The shaker doesn't use Tone: use Tune instead.", pan: 25),
  ]

  static func address(pad: Int, _ field: OngakuDrumField) -> AUParameterAddress {
    OngakuEffectsParameterAddress.drmFirstPad.rawValue + AUParameterAddress(Int(OngakuDrumPadStride) * pad + Int(field.rawValue))
  }

  static let tree = ParameterTreeSpec {
    ParameterSpec(
      address: OngakuEffectsParameterAddress.drmVolume.rawValue, identifier: "volume", name: "Volume",
      units: .decibels, valueRange: -24...12, defaultValue: 0)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.drmDrive.rawValue, identifier: "drive", name: "Drive",
      units: .percent, valueRange: 0...100, defaultValue: 0)
    for (index, pad) in pads.enumerated() {
      ParameterGroupSpec(identifier: pad.identifier, name: pad.name) {
        ParameterSpec(
          address: address(pad: index, .tune), identifier: "tune", name: "\(pad.name) Tune",
          units: .relativeSemiTones, valueRange: -12...12, defaultValue: 0)
        ParameterSpec(
          address: address(pad: index, .decay), identifier: "decay", name: "\(pad.name) Decay",
          units: .percent, valueRange: 10...300, defaultValue: 100)
        ParameterSpec(
          address: address(pad: index, .tone), identifier: "tone", name: "\(pad.name) \(pad.toneName)",
          units: .percent, valueRange: 0...100, defaultValue: index == 0 || pad.toneName == "Attack" ? 30 : 50)
        ParameterSpec(
          address: address(pad: index, .level), identifier: "level", name: "\(pad.name) Level",
          units: .decibels, valueRange: -36...6, defaultValue: 0)
        ParameterSpec(
          address: address(pad: index, .pan), identifier: "pan", name: "\(pad.name) Pan",
          units: .pan, valueRange: -100...100, defaultValue: pad.pan)
      }
    }
  }

  private static func kit(_ name: String, _ values: [(String, OngakuDrumField, AUValue)], volume: AUValue = 0, drive: AUValue = 0)
    -> EffectPreset
  {
    var dictionary: [AUParameterAddress: AUValue] = [
      OngakuEffectsParameterAddress.drmVolume.rawValue: volume, OngakuEffectsParameterAddress.drmDrive.rawValue: drive,
    ]
    for (identifier, field, value) in values {
      guard let index = pads.firstIndex(where: { $0.identifier == identifier }) else { continue }
      dictionary[address(pad: index, field)] = value
    }
    return EffectPreset(name: name, values: dictionary, resetsOthers: true)
  }

  /// Kits change what they need from the defaults (Analog 808).
  static let kits: [EffectPreset] = [
    kit("Analog 808", []),
    kit("Punchy 909", [
      ("kick", .tune, 3), ("kick", .decay, 55), ("kick", .tone, 75), ("snare", .tune, 2), ("snare", .tone, 75),
      ("snare", .decay, 80), ("clap", .tone, 70), ("closedHat", .tone, 75), ("openHat", .tone, 75), ("crash", .tone, 70),
    ], drive: 20),
    kit("Lo-Fi", [
      ("kick", .decay, 80), ("kick", .tone, 10), ("snare", .tone, 30), ("closedHat", .tone, 15), ("openHat", .tone, 15),
      ("crash", .tone, 20), ("clap", .tone, 25),
    ], volume: -3, drive: 70),
    kit("Electro", [
      ("kick", .tune, -2), ("kick", .decay, 150), ("lowTom", .decay, 140), ("midTom", .decay, 140),
      ("highTom", .decay, 140), ("lowTom", .tune, 2), ("midTom", .tune, 2), ("highTom", .tune, 2), ("cowbell", .level, 2),
      ("snare", .tone, 85), ("snare", .decay, 60), ("clap", .level, 2),
    ]),
  ]
}

/// The Sampler's parameters and presets.
enum SamplerParameters {
  private static let logarithmic: AudioUnitParameterOptions = [.flag_IsWritable, .flag_IsReadable, .flag_DisplayLogarithmic]

  private static func spec(
    _ address: OngakuEffectsParameterAddress, _ identifier: String, _ name: String, _ units: AudioUnitParameterUnit,
    _ range: ClosedRange<AUValue>, _ value: AUValue, logarithmic isLogarithmic: Bool = false, strings: [String]? = nil
  ) -> ParameterSpec {
    ParameterSpec(
      address: address.rawValue, identifier: identifier, name: name, units: units, valueRange: range, defaultValue: value,
      flags: isLogarithmic ? logarithmic : [.flag_IsWritable, .flag_IsReadable], valueStrings: strings)
  }

  static let playModes = ["Classic", "One Shot"]
  static let loopModes = ["Off", "Forward", "Alternate"]

  /// The defaults are the first preset, Classic.
  static let tree = ParameterTreeSpec {
    spec(.splStart, "start", "Sample Start", .percent, 0...100, 0)
    spec(.splEnd, "end", "Sample End", .percent, 0...100, 100)
    spec(.splLoopStart, "loopStart", "Loop Start", .percent, 0...100, 25)
    spec(.splLoopEnd, "loopEnd", "Loop End", .percent, 0...100, 90)
    spec(.splPlayMode, "playMode", "Mode", .indexed, 0...1, 0, strings: playModes)
    spec(.splLoop, "loop", "Loop", .indexed, 0...2, 0, strings: loopModes)
    spec(.splCrossfade, "crossfade", "Loop X-Fade", .milliseconds, 0...500, 20)
    spec(.splReverse, "reverse", "Reverse", .boolean, 0...1, 0)
    spec(.splRoot, "root", "Root Note", .midiNoteNumber, 0...127, 60)
    spec(.splTranspose, "transpose", "Transpose", .relativeSemiTones, -24...24, 0)
    spec(.splTune, "tune", "Fine Tune", .cents, -100...100, 0)
    spec(.splFollowKeys, "followKeys", "Follow Keys", .boolean, 0...1, 1)
    spec(.splGlide, "glide", "Glide", .milliseconds, 0...2_000, 0)
    spec(.splVoices, "voices", "Voices", .indexed, 0...1, 0, strings: ["Poly", "Mono"])
    spec(.splBendRange, "bendRange", "Bend Range", .relativeSemiTones, 1...12, 2)
    spec(.splFilterOn, "filterOn", "Filter", .boolean, 0...1, 0)
    spec(.splCutoff, "cutoff", "Cutoff", .hertz, 20...20_000, 4_000, logarithmic: true)
    spec(.splResonance, "resonance", "Resonance", .percent, 0...100, 15)
    spec(.splFilterEnv, "filterEnv", "Filter Env Amount", .percent, -100...100, 0)
    spec(.splKeyTrack, "keyTrack", "Key Track", .percent, 0...100, 50)
    spec(.splFilterAttack, "filterAttack", "Filter Attack", .milliseconds, 1...10_000, 5, logarithmic: true)
    spec(.splFilterDecay, "filterDecay", "Filter Decay", .milliseconds, 1...10_000, 400, logarithmic: true)
    spec(.splFilterSustain, "filterSustain", "Filter Sustain", .percent, 0...100, 50)
    spec(.splFilterRelease, "filterRelease", "Filter Release", .milliseconds, 1...10_000, 300, logarithmic: true)
    spec(.splAmpAttack, "ampAttack", "Attack", .milliseconds, 1...10_000, 1, logarithmic: true)
    spec(.splAmpDecay, "ampDecay", "Decay", .milliseconds, 1...10_000, 300, logarithmic: true)
    spec(.splAmpSustain, "ampSustain", "Sustain", .percent, 0...100, 100)
    spec(.splAmpRelease, "ampRelease", "Release", .milliseconds, 1...10_000, 150, logarithmic: true)
    spec(.splVelocity, "velocity", "Velocity", .percent, 0...100, 60)
    spec(.splLfoRate, "lfoRate", "LFO Rate", .hertz, 0.05...20, 5, logarithmic: true)
    spec(.splLfoWave, "lfoWave", "LFO Wave", .indexed, 0...2, 0, strings: RetroSynthParameters.lfoWaves)
    spec(.splLfoPitch, "lfoPitch", "Vibrato", .cents, 0...100, 0)
    spec(.splLfoFilter, "lfoFilter", "LFO Wah (to Filter)", .percent, 0...100, 0)
    spec(.splLfoAmp, "lfoAmp", "Tremolo", .percent, 0...100, 0)
    spec(.splGain, "gain", "Volume", .decibels, -24...12, 0)
  }

  /// What a preset leaves alone: the settings that belong to the sample (where it starts,
  /// ends and loops, and its root note), not to how it's played.
  static let sampleSettings: Set<AUParameterAddress> = Set(
    [OngakuEffectsParameterAddress.splStart, .splEnd, .splLoopStart, .splLoopEnd, .splRoot].map(\.rawValue))

  /// A preset: the playing settings it changes from the defaults, with the rest of them
  /// back at their defaults (but not the sample's own settings).
  private static func preset(_ name: String, _ values: [(OngakuEffectsParameterAddress, AUValue)]) -> EffectPreset {
    var dictionary: [AUParameterAddress: AUValue] = [:]
    func collect(_ nodes: [NodeSpec]) {
      for node in nodes {
        if let parameter = node as? ParameterSpec, !sampleSettings.contains(parameter.address) {
          dictionary[parameter.address] = parameter.defaultValue
        }
        if let group = node as? ParameterGroupSpec { collect(group.children) }
      }
    }
    collect(tree.children)
    for (address, value) in values {
      dictionary[address.rawValue] = value
    }
    return EffectPreset(name: name, values: dictionary, resetsOthers: false)
  }

  static let presets: [EffectPreset] = [
    preset("Classic", []),
    preset("One Shot", [(.splPlayMode, 1), (.splAmpRelease, 30), (.splVelocity, 70)]),
    preset("Sustained Loop", [(.splLoop, 1), (.splCrossfade, 120), (.splAmpAttack, 15), (.splAmpRelease, 600)]),
    preset("Soft Pad", [
      (.splLoop, 2), (.splCrossfade, 80), (.splAmpAttack, 900), (.splAmpDecay, 1_000), (.splAmpSustain, 85),
      (.splAmpRelease, 1_800), (.splFilterOn, 1), (.splCutoff, 1_800), (.splResonance, 10), (.splFilterEnv, 20),
      (.splFilterAttack, 800), (.splFilterSustain, 60), (.splLfoRate, 0.4), (.splLfoFilter, 15),
    ]),
    preset("Pluck", [
      (.splFilterOn, 1), (.splCutoff, 700), (.splResonance, 25), (.splFilterEnv, 70), (.splFilterAttack, 1),
      (.splFilterDecay, 250), (.splFilterSustain, 0), (.splAmpDecay, 500), (.splAmpSustain, 0), (.splAmpRelease, 300),
    ]),
    preset("Reverse Swell", [(.splReverse, 1), (.splPlayMode, 1), (.splAmpAttack, 40)]),
    preset("Lo-Fi", [
      (.splFilterOn, 1), (.splCutoff, 2_200), (.splResonance, 30), (.splLfoRate, 0.6), (.splLfoPitch, 8), (.splGain, 2),
    ]),
    preset("Mono Lead", [(.splVoices, 1), (.splGlide, 80), (.splLoop, 1), (.splCrossfade, 60), (.splLfoRate, 5.5)]),
    preset("Fixed Pitch", [(.splFollowKeys, 0), (.splPlayMode, 1)]),
  ]
}

// MARK: - Phase 9 effects

/// Builds the parameters of the simpler effects: specs, and presets that set every
/// parameter (anything a preset doesn't name goes back to its default).
private enum EffectSpecs {
  static let logarithmic: AudioUnitParameterOptions = [.flag_IsWritable, .flag_IsReadable, .flag_DisplayLogarithmic]

  static func spec(
    _ address: OngakuEffectsParameterAddress, _ identifier: String, _ name: String, _ units: AudioUnitParameterUnit,
    _ range: ClosedRange<AUValue>, _ value: AUValue, logarithmic isLogarithmic: Bool = false, strings: [String]? = nil,
    unitName: String? = nil
  ) -> ParameterSpec {
    ParameterSpec(
      address: address.rawValue, identifier: identifier, name: name, units: units, valueRange: range, defaultValue: value,
      unitName: unitName, flags: isLogarithmic ? logarithmic : [.flag_IsWritable, .flag_IsReadable], valueStrings: strings)
  }

  static func preset(_ name: String, _ values: [(OngakuEffectsParameterAddress, AUValue)]) -> EffectPreset {
    EffectPreset(name: name, values: Dictionary(uniqueKeysWithValues: values.map { ($0.rawValue, $1) }), resetsOthers: true)
  }
}

enum NoiseGateParameters {
  static let tree = ParameterTreeSpec {
    EffectSpecs.spec(.gateThreshold, "threshold", "Threshold", .decibels, -80...0, -45)
    EffectSpecs.spec(.gateReduction, "reduction", "Reduction", .decibels, -100...0, -100)
    EffectSpecs.spec(.gateAttack, "attack", "Attack", .milliseconds, 0.1...200, 1, logarithmic: true)
    EffectSpecs.spec(.gateHold, "hold", "Hold", .milliseconds, 0...500, 40)
    EffectSpecs.spec(.gateRelease, "release", "Release", .milliseconds, 1...2_000, 120, logarithmic: true)
    EffectSpecs.spec(.gateHysteresis, "hysteresis", "Hysteresis", .decibels, 0...20, 4)
    EffectSpecs.spec(.gateKeyLowCut, "keyLowCut", "Key Low Cut", .hertz, 20...2_000, 20, logarithmic: true)
  }

  static let presets = [
    EffectSpecs.preset("Clean Gate", []),
    EffectSpecs.preset("Tight Drums", [(.gateThreshold, -30), (.gateHold, 15), (.gateRelease, 60), (.gateKeyLowCut, 60)]),
    EffectSpecs.preset("Vocal Breaths", [(.gateThreshold, -48), (.gateReduction, -15), (.gateRelease, 250), (.gateHold, 80)]),
    EffectSpecs.preset("Guitar Hum", [(.gateThreshold, -52), (.gateKeyLowCut, 150), (.gateRelease, 180), (.gateHold, 60)]),
    EffectSpecs.preset("Gated Snare", [(.gateThreshold, -24), (.gateHold, 120), (.gateRelease, 15), (.gateAttack, 0.2)]),
  ]
}

enum TransientShaperParameters {
  static let tree = ParameterTreeSpec {
    EffectSpecs.spec(.trnAttack, "attack", "Attack", .percent, -100...100, 0)
    EffectSpecs.spec(.trnSustain, "sustain", "Sustain", .percent, -100...100, 0)
    EffectSpecs.spec(.trnOutput, "output", "Output", .decibels, -24...12, 0)
    EffectSpecs.spec(.trnMix, "mix", "Mix", .percent, 0...100, 100)
  }

  static let presets = [
    EffectSpecs.preset("Neutral", []),
    EffectSpecs.preset("Punchy Drums", [(.trnAttack, 60), (.trnSustain, -15)]),
    EffectSpecs.preset("Tighten", [(.trnSustain, -60)]),
    EffectSpecs.preset("More Room", [(.trnSustain, 60), (.trnOutput, -2)]),
    EffectSpecs.preset("Soften Attack", [(.trnAttack, -60)]),
  ]
}

enum MaximizerParameters {
  static let tree = ParameterTreeSpec {
    EffectSpecs.spec(.maxGain, "gain", "Gain", .decibels, 0...24, 0)
    EffectSpecs.spec(.maxCeiling, "ceiling", "Ceiling", .decibels, -6...0, -1)
    EffectSpecs.spec(.maxRelease, "release", "Release", .milliseconds, 1...1_000, 60, logarithmic: true)
    EffectSpecs.spec(.maxTruePeak, "truePeak", "True Peak", .boolean, 0...1, 1)
  }

  static let presets = [
    EffectSpecs.preset("Safety Limiter", []),
    EffectSpecs.preset("Gentle Lift", [(.maxGain, 3), (.maxRelease, 120)]),
    EffectSpecs.preset("Loud Master", [(.maxGain, 8), (.maxRelease, 40)]),
    EffectSpecs.preset("Very Loud", [(.maxGain, 12), (.maxRelease, 25)]),
    EffectSpecs.preset("Broadcast Safe", [(.maxGain, 4), (.maxCeiling, -2)]),
  ]
}

enum DeEsserParameters {
  static let tree = ParameterTreeSpec {
    EffectSpecs.spec(.desFrequency, "frequency", "Frequency", .hertz, 2_000...12_000, 6_500, logarithmic: true)
    EffectSpecs.spec(.desThreshold, "threshold", "Threshold", .decibels, -60...0, -30)
    EffectSpecs.spec(.desRange, "range", "Range", .decibels, 0...24, 8)
    EffectSpecs.spec(.desListen, "listen", "Listen", .boolean, 0...1, 0)
  }

  static let presets = [
    EffectSpecs.preset("Vocal", []),
    EffectSpecs.preset("Female Vocal", [(.desFrequency, 7_500)]),
    EffectSpecs.preset("Male Vocal", [(.desFrequency, 5_500)]),
    EffectSpecs.preset("Gentle", [(.desRange, 4), (.desThreshold, -26)]),
    EffectSpecs.preset("Strong", [(.desRange, 14), (.desThreshold, -38)]),
  ]
}

enum SaturationParameters {
  static let types = ["Tape", "Tube", "Transistor"]

  static let tree = ParameterTreeSpec {
    EffectSpecs.spec(.satDrive, "drive", "Drive", .decibels, 0...36, 6)
    EffectSpecs.spec(.satType, "type", "Type", .indexed, 0...2, 0, strings: types)
    EffectSpecs.spec(.satTone, "tone", "Tone", .percent, -100...100, 0)
    EffectSpecs.spec(.satOutput, "output", "Output", .decibels, -24...12, 0)
    EffectSpecs.spec(.satMix, "mix", "Mix", .percent, 0...100, 100)
  }

  static let presets = [
    EffectSpecs.preset("Warm Tape", []),
    EffectSpecs.preset("Tube Glow", [(.satType, 1), (.satDrive, 10)]),
    EffectSpecs.preset("Subtle Glue", [(.satDrive, 3), (.satMix, 60)]),
    EffectSpecs.preset("Crunch", [(.satType, 2), (.satDrive, 22), (.satTone, -20)]),
    EffectSpecs.preset("Lo-Fi Drive", [(.satDrive, 28), (.satTone, -60), (.satOutput, -3)]),
  ]
}

enum DoublerParameters {
  static let tree = ParameterTreeSpec {
    EffectSpecs.spec(.dblDelay, "delay", "Delay", .milliseconds, 5...60, 18)
    EffectSpecs.spec(.dblDetune, "detune", "Detune", .cents, 0...50, 9)
    EffectSpecs.spec(.dblDrift, "drift", "Drift", .percent, 0...100, 40)
    EffectSpecs.spec(.dblWidth, "width", "Width", .percent, 0...100, 80)
    EffectSpecs.spec(.dblMix, "mix", "Mix", .percent, 0...100, 60)
  }

  static let presets = [
    EffectSpecs.preset("Natural Double", []),
    EffectSpecs.preset("Wide Guitars", [(.dblDelay, 24), (.dblDetune, 12), (.dblWidth, 100), (.dblMix, 75)]),
    EffectSpecs.preset("Tight ADT", [(.dblDelay, 9), (.dblDetune, 6), (.dblDrift, 20)]),
    EffectSpecs.preset("Chorused", [(.dblDetune, 22), (.dblDrift, 75), (.dblMix, 70)]),
    EffectSpecs.preset("Subtle", [(.dblMix, 30), (.dblWidth, 60)]),
  ]
}

/// The Chorus, Flanger, Phaser and Tremolo (Modulation.hpp).
enum ModulationParameters {
  static let chorus = ParameterTreeSpec {
    EffectSpecs.spec(.chrRate, "rate", "Rate", .hertz, 0.05...5, 0.6, logarithmic: true)
    EffectSpecs.spec(.chrDepth, "depth", "Depth", .percent, 0...100, 50)
    EffectSpecs.spec(.chrDelay, "delay", "Delay", .milliseconds, 5...30, 14)
    EffectSpecs.spec(.chrWidth, "width", "Width", .percent, 0...100, 80)
    EffectSpecs.spec(.chrMix, "mix", "Mix", .percent, 0...100, 50)
  }

  static let chorusPresets = [
    EffectSpecs.preset("Classic Chorus", []),
    EffectSpecs.preset("Shimmer", [(.chrRate, 1.4), (.chrDepth, 35), (.chrDelay, 9), (.chrWidth, 100)]),
    EffectSpecs.preset("Slow and Wide", [(.chrRate, 0.2), (.chrDepth, 70), (.chrWidth, 100), (.chrMix, 45)]),
    EffectSpecs.preset("Thickener", [(.chrRate, 0.35), (.chrDepth, 25), (.chrDelay, 20), (.chrMix, 35)]),
    EffectSpecs.preset("Vibrato", [(.chrRate, 5), (.chrDepth, 45), (.chrDelay, 6), (.chrWidth, 0), (.chrMix, 100)]),
  ]

  static let flanger = ParameterTreeSpec {
    EffectSpecs.spec(.flgRate, "rate", "Rate", .hertz, 0.02...5, 0.25, logarithmic: true)
    EffectSpecs.spec(.flgDepth, "depth", "Depth", .percent, 0...100, 70)
    EffectSpecs.spec(.flgDelay, "delay", "Delay", .milliseconds, 0.3...10, 1.5, logarithmic: true)
    EffectSpecs.spec(.flgFeedback, "feedback", "Feedback", .percent, -95...95, 55)
    EffectSpecs.spec(.flgWidth, "width", "Width", .percent, 0...100, 50)
    EffectSpecs.spec(.flgMix, "mix", "Mix", .percent, 0...100, 100)
  }

  static let flangerPresets = [
    EffectSpecs.preset("Jet", []),
    EffectSpecs.preset("Gentle Sweep", [(.flgRate, 0.12), (.flgDepth, 50), (.flgFeedback, 25)]),
    EffectSpecs.preset("Metallic", [(.flgRate, 0.5), (.flgDelay, 0.6), (.flgFeedback, 85)]),
    EffectSpecs.preset("Hollow", [(.flgFeedback, -70), (.flgDepth, 60)]),
    EffectSpecs.preset("Through Zero", [(.flgRate, 0.08), (.flgDelay, 0.3), (.flgDepth, 100), (.flgFeedback, 0)]),
  ]

  static let stages = ["2", "4", "6", "8", "12"]

  static let phaser = ParameterTreeSpec {
    EffectSpecs.spec(.phsRate, "rate", "Rate", .hertz, 0.02...8, 0.4, logarithmic: true)
    EffectSpecs.spec(.phsDepth, "depth", "Depth", .percent, 0...100, 70)
    EffectSpecs.spec(.phsStages, "stages", "Stages", .indexed, 0...4, 1, strings: stages)
    EffectSpecs.spec(.phsCenter, "center", "Centre", .hertz, 100...6_000, 800, logarithmic: true)
    EffectSpecs.spec(.phsFeedback, "feedback", "Feedback", .percent, -95...95, 40)
    EffectSpecs.spec(.phsWidth, "width", "Width", .percent, 0...100, 50)
    EffectSpecs.spec(.phsMix, "mix", "Mix", .percent, 0...100, 100)
  }

  static let phaserPresets = [
    EffectSpecs.preset("Classic Phase", []),
    EffectSpecs.preset("Slow Swirl", [(.phsRate, 0.1), (.phsDepth, 90), (.phsStages, 3), (.phsWidth, 100)]),
    EffectSpecs.preset("Funky Four", [(.phsRate, 1.2), (.phsStages, 1), (.phsFeedback, 60), (.phsCenter, 1_200)]),
    EffectSpecs.preset("Deep Twelve", [(.phsRate, 0.25), (.phsStages, 4), (.phsFeedback, 70)]),
    EffectSpecs.preset("Subtle", [(.phsDepth, 40), (.phsFeedback, 10), (.phsMix, 60)]),
  ]

  static let shapes = ["Sine", "Triangle", "Square"]

  static let tremolo = ParameterTreeSpec {
    EffectSpecs.spec(.trmSync, "sync", "Sync", .boolean, 0...1, 0)
    EffectSpecs.spec(.trmRate, "rate", "Rate", .hertz, 0.1...20, 5, logarithmic: true)
    EffectSpecs.spec(.trmNote, "note", "Note", .indexed, 0...10, 5, strings: DelayParameters.notes)
    EffectSpecs.spec(.trmDepth, "depth", "Depth", .percent, 0...100, 50)
    EffectSpecs.spec(.trmShape, "shape", "Shape", .indexed, 0...2, 0, strings: shapes)
    EffectSpecs.spec(.trmStereo, "stereo", "Stereo Phase", .degrees, 0...180, 0, unitName: "°")
  }

  static let tremoloPresets = [
    EffectSpecs.preset("Amp Tremolo", []),
    EffectSpecs.preset("Auto-Pan", [(.trmRate, 0.5), (.trmDepth, 100), (.trmStereo, 180)]),
    EffectSpecs.preset("Eighth-Note Chop", [(.trmSync, 1), (.trmNote, 5), (.trmDepth, 100), (.trmShape, 2)]),
    EffectSpecs.preset("Slow Throb", [(.trmRate, 2), (.trmDepth, 70), (.trmShape, 1)]),
    EffectSpecs.preset("Wide Shimmer", [(.trmRate, 7), (.trmDepth, 35), (.trmStereo, 90)]),
  ]
}

/// The Electric Piano and the Organ (Keys.hpp).
enum KeysParameters {
  static let electricPiano = ParameterTreeSpec {
    EffectSpecs.spec(.epTone, "tone", "Tone", .percent, 0...100, 50)
    EffectSpecs.spec(.epBell, "bell", "Bell", .percent, 0...100, 35)
    EffectSpecs.spec(.epDecay, "decay", "Decay", .percent, 25...400, 100, logarithmic: true)
    EffectSpecs.spec(.epVelocity, "velocity", "Velocity", .percent, 0...100, 70)
    EffectSpecs.spec(.epTremoloRate, "tremoloRate", "Tremolo Rate", .hertz, 0.5...12, 4.5, logarithmic: true)
    EffectSpecs.spec(.epTremoloDepth, "tremoloDepth", "Tremolo Depth", .percent, 0...100, 0)
    EffectSpecs.spec(.epDrive, "drive", "Drive", .percent, 0...100, 10)
    EffectSpecs.spec(.epVolume, "volume", "Volume", .decibels, -24...12, 0)
  }

  static let electricPianoPresets = [
    EffectSpecs.preset("Classic Tines", []),
    EffectSpecs.preset("Bright Bark", [(.epTone, 80), (.epBell, 60), (.epVelocity, 90), (.epDrive, 25)]),
    EffectSpecs.preset("Mellow Ballad", [(.epTone, 25), (.epBell, 15), (.epDecay, 160), (.epDrive, 0)]),
    EffectSpecs.preset("Suitcase Tremolo", [(.epTremoloDepth, 60), (.epTremoloRate, 4.5), (.epTone, 45)]),
    EffectSpecs.preset("Driven", [(.epDrive, 55), (.epTone, 65), (.epBell, 45)]),
  ]

  /// The drawbars' footages, left to right.
  static let footages = ["16′", "5⅓′", "8′", "4′", "2⅔′", "2′", "1⅗′", "1⅓′", "1′"]
  static let vibratos = ["Off", "V1", "V2", "V3", "C1", "C2", "C3"]
  static let rotarySpeeds = ["Off", "Slow", "Fast"]

  static let organ = ParameterTreeSpec {
    for (bar, footage) in footages.enumerated() {
      ParameterSpec(
        address: OngakuEffectsParameterAddress.orgFirstDrawbar.rawValue + AUParameterAddress(bar), identifier: "drawbar\(bar)",
        name: "Drawbar \(footage)", units: .generic, valueRange: 0...8, defaultValue: bar < 3 ? 8 : 0)
    }
    EffectSpecs.spec(.orgPercussion, "percussion", "Percussion", .boolean, 0...1, 1)
    EffectSpecs.spec(.orgPercussionHarmonic, "percussionHarmonic", "Percussion Harmonic", .indexed, 0...1, 1, strings: ["Second", "Third"])
    EffectSpecs.spec(.orgPercussionDecay, "percussionDecay", "Percussion Decay", .indexed, 0...1, 0, strings: ["Fast", "Slow"])
    EffectSpecs.spec(.orgClick, "click", "Key Click", .percent, 0...100, 40)
    EffectSpecs.spec(.orgVibrato, "vibrato", "Vibrato", .indexed, 0...6, 6, strings: vibratos)
    EffectSpecs.spec(.orgRotary, "rotary", "Rotary", .indexed, 0...2, 1, strings: rotarySpeeds)
    EffectSpecs.spec(.orgDrive, "drive", "Drive", .percent, 0...100, 15)
    EffectSpecs.spec(.orgVolume, "volume", "Volume", .decibels, -24...12, 0)
  }

  /// A registration: the drawbars as a Hammond player writes them ("888000000").
  private static func registration(_ name: String, _ drawbars: String, _ extra: [(OngakuEffectsParameterAddress, AUValue)]) -> EffectPreset {
    var values = Dictionary(uniqueKeysWithValues: extra.map { ($0.rawValue, $1) })
    for (bar, digit) in drawbars.enumerated() {
      values[OngakuEffectsParameterAddress.orgFirstDrawbar.rawValue + AUParameterAddress(bar)] = AUValue(String(digit)) ?? 0
    }
    return EffectPreset(name: name, values: values, resetsOthers: true)
  }

  static let organPresets = [
    registration("Jazz Trio", "888000000", [(.orgPercussion, 1), (.orgPercussionHarmonic, 1), (.orgVibrato, 6), (.orgRotary, 1)]),
    registration("Full Gospel", "888888888", [(.orgPercussion, 0), (.orgRotary, 2), (.orgDrive, 30), (.orgVibrato, 6)]),
    registration("Rock Drive", "888600000", [(.orgPercussion, 0), (.orgRotary, 2), (.orgDrive, 65), (.orgClick, 60)]),
    registration("Soft Ballad", "008600000", [(.orgPercussion, 0), (.orgRotary, 1), (.orgVibrato, 6), (.orgClick, 10), (.orgDrive, 0)]),
    registration("Church Hymn", "688600000", [(.orgPercussion, 0), (.orgRotary, 0), (.orgVibrato, 6), (.orgClick, 20), (.orgDrive, 0)]),
  ]
}

/// The Multiband Compressor (MultibandCompressor.hpp).
enum MultibandParameters {
  static let bandNames = ["Low", "Mid", "High"]

  static func address(_ band: Int, _ field: OngakuBandField) -> AUParameterAddress {
    OngakuEffectsParameterAddress.mbcFirstBand.rawValue + AUParameterAddress(10 * band + Int(field.rawValue))
  }

  static let tree = ParameterTreeSpec {
    EffectSpecs.spec(.mbcLowCrossover, "lowCrossover", "Low Crossover", .hertz, 40...2_000, 200, logarithmic: true)
    EffectSpecs.spec(.mbcHighCrossover, "highCrossover", "High Crossover", .hertz, 500...16_000, 3_000, logarithmic: true)
    EffectSpecs.spec(.mbcAttack, "attack", "Attack", .milliseconds, 0.5...200, 10, logarithmic: true)
    EffectSpecs.spec(.mbcRelease, "release", "Release", .milliseconds, 10...2_000, 150, logarithmic: true)
    EffectSpecs.spec(.mbcOutput, "output", "Output", .decibels, -24...24, 0)
    for (band, name) in bandNames.enumerated() {
      ParameterSpec(
        address: address(band, .threshold), identifier: "threshold\(band)", name: "\(name) Threshold",
        units: .decibels, valueRange: -60...0, defaultValue: -20)
      ParameterSpec(
        address: address(band, .ratio), identifier: "ratio\(band)", name: "\(name) Ratio",
        units: .ratio, valueRange: 1...20, defaultValue: 2.5, flags: EffectSpecs.logarithmic)
      ParameterSpec(
        address: address(band, .makeUp), identifier: "makeUp\(band)", name: "\(name) Make-Up",
        units: .decibels, valueRange: -24...24, defaultValue: 0)
    }
  }

  private static func preset(_ name: String, low: (AUValue, AUValue, AUValue), mid: (AUValue, AUValue, AUValue),
    high: (AUValue, AUValue, AUValue), extra: [(OngakuEffectsParameterAddress, AUValue)] = []) -> EffectPreset
  {
    var values = Dictionary(uniqueKeysWithValues: extra.map { ($0.rawValue, $1) })
    for (band, settings) in [low, mid, high].enumerated() {
      values[address(band, .threshold)] = settings.0
      values[address(band, .ratio)] = settings.1
      values[address(band, .makeUp)] = settings.2
    }
    return EffectPreset(name: name, values: values, resetsOthers: true)
  }

  static let presets = [
    preset("Gentle Glue", low: (-20, 2.5, 0), mid: (-20, 2.5, 0), high: (-20, 2.5, 0)),
    preset("Tame the Lows", low: (-28, 4, 2), mid: (-18, 1.5, 0), high: (-18, 1.5, 0)),
    preset("Smooth Vocal", low: (-22, 2, 0), mid: (-24, 3, 2), high: (-30, 4, 1), extra: [(.mbcLowCrossover, 180), (.mbcHighCrossover, 5_000)]),
    preset("Drum Bus Punch", low: (-18, 3, 2), mid: (-22, 4, 3), high: (-20, 2, 1), extra: [(.mbcAttack, 25), (.mbcRelease, 90)]),
    preset("Mastering Polish", low: (-16, 1.8, 0.5), mid: (-16, 1.6, 0.5), high: (-18, 1.8, 0.5),
      extra: [(.mbcAttack, 30), (.mbcRelease, 250), (.mbcLowCrossover, 120), (.mbcHighCrossover, 6_000)]),
  ]
}

/// Gain and the Tuner (Utility.hpp).
enum UtilityParameters {
  static let gain = ParameterTreeSpec {
    EffectSpecs.spec(.ginGain, "gain", "Gain", .decibels, -48...24, 0)
    EffectSpecs.spec(.ginInvertLeft, "invertLeft", "Invert Left", .boolean, 0...1, 0)
    EffectSpecs.spec(.ginInvertRight, "invertRight", "Invert Right", .boolean, 0...1, 0)
    EffectSpecs.spec(.ginSwap, "swap", "Swap Left and Right", .boolean, 0...1, 0)
    EffectSpecs.spec(.ginMono, "mono", "Mono", .boolean, 0...1, 0)
    EffectSpecs.spec(.ginWidth, "width", "Width", .percent, 0...200, 100)
    EffectSpecs.spec(.ginBalance, "balance", "Balance", .pan, -100...100, 0)
  }

  static let gainPresets = [
    EffectSpecs.preset("Unity", []),
    EffectSpecs.preset("Mono Check", [(.ginMono, 1)]),
    EffectSpecs.preset("Swap Sides", [(.ginSwap, 1)]),
    EffectSpecs.preset("Flip Polarity", [(.ginInvertLeft, 1), (.ginInvertRight, 1)]),
    EffectSpecs.preset("Extra Wide", [(.ginWidth, 150)]),
  ]

  static let tuner = ParameterTreeSpec {
    EffectSpecs.spec(.tunReference, "reference", "Reference", .hertz, 430...450, 440)
    ParameterSpec(
      address: OngakuEffectsParameterAddress.tunFrequency.rawValue, identifier: "frequency", name: "Frequency",
      units: .hertz, valueRange: 0...2_000, defaultValue: 0, flags: [.flag_IsReadable])
    EffectSpecs.spec(.tunMute, "mute", "Mute While Tuning", .boolean, 0...1, 0)
  }
}

enum ConvolutionReverbParameters {
  /// The parameters the impulse response is built from (changing them builds it again).
  static let shapingAddresses: Set<AUParameterAddress> = Set(
    [OngakuEffectsParameterAddress.cnvDecay, .cnvSize, .cnvDamping].map(\.rawValue))

  static let tree = ParameterTreeSpec {
    EffectSpecs.spec(.cnvPredelay, "predelay", "Predelay", .milliseconds, 0...250, 12)
    EffectSpecs.spec(.cnvDecay, "decay", "Decay", .seconds, 0.2...7, 2.2, logarithmic: true)
    EffectSpecs.spec(.cnvSize, "size", "Size", .percent, 0...100, 55)
    EffectSpecs.spec(.cnvDamping, "damping", "Damping", .percent, 0...100, 40)
    EffectSpecs.spec(.cnvWidth, "width", "Width", .percent, 0...100, 100)
    EffectSpecs.spec(.cnvLowCut, "lowCut", "Low Cut", .hertz, 20...1_000, 120, logarithmic: true)
    EffectSpecs.spec(.cnvHighCut, "highCut", "High Cut", .hertz, 1_000...20_000, 12_000, logarithmic: true)
    EffectSpecs.spec(.cnvMix, "mix", "Mix", .percent, 0...100, 30)
  }

  static let presets = [
    EffectSpecs.preset("Medium Hall", []),
    EffectSpecs.preset("Small Room", [(.cnvDecay, 0.6), (.cnvSize, 20), (.cnvDamping, 55), (.cnvPredelay, 4)]),
    EffectSpecs.preset("Studio Room", [(.cnvDecay, 1.0), (.cnvSize, 35), (.cnvDamping, 50), (.cnvPredelay, 8)]),
    EffectSpecs.preset("Concert Hall", [(.cnvDecay, 2.8), (.cnvSize, 75), (.cnvDamping, 35), (.cnvPredelay, 25)]),
    EffectSpecs.preset("Cathedral", [(.cnvDecay, 6), (.cnvSize, 100), (.cnvDamping, 25), (.cnvPredelay, 40), (.cnvMix, 35)]),
    EffectSpecs.preset("Bright Plate", [(.cnvDecay, 1.8), (.cnvSize, 5), (.cnvDamping, 12), (.cnvPredelay, 0), (.cnvHighCut, 16_000)]),
    EffectSpecs.preset("Dark Chamber", [(.cnvDecay, 1.4), (.cnvSize, 40), (.cnvDamping, 85), (.cnvHighCut, 6_000)]),
  ]
}

enum VocalStripParameters {
  static let tree = ParameterTreeSpec {
    EffectSpecs.spec(.voxLowCut, "lowCut", "Low Cut", .hertz, 20...400, 90, logarithmic: true)
    EffectSpecs.spec(.voxDeEss, "deEss", "De-Ess", .percent, 0...100, 40)
    EffectSpecs.spec(.voxCompress, "compress", "Compress", .percent, 0...100, 40)
    EffectSpecs.spec(.voxBody, "body", "Body", .percent, -100...100, 0)
    EffectSpecs.spec(.voxPresence, "presence", "Presence", .percent, -100...100, 20)
    EffectSpecs.spec(.voxAir, "air", "Air", .percent, -100...100, 20)
    EffectSpecs.spec(.voxOutput, "output", "Output", .decibels, -24...12, 0)
  }

  static let presets = [
    EffectSpecs.preset("Lead Vocal", []),
    EffectSpecs.preset("Natural", [(.voxDeEss, 20), (.voxCompress, 20), (.voxPresence, 0), (.voxAir, 0)]),
    EffectSpecs.preset("Backing Vocals", [(.voxCompress, 60), (.voxBody, -30), (.voxAir, 40)]),
    EffectSpecs.preset("Podcast Voice", [(.voxLowCut, 100), (.voxCompress, 65), (.voxPresence, 30), (.voxBody, 20)]),
    EffectSpecs.preset("Rap Vocal", [(.voxCompress, 70), (.voxPresence, 40), (.voxDeEss, 50)]),
  ]
}

// MARK: - Session Drummer

/// The Session Drummer's own settings, and its kit (the Drum Machine's, in a group).
enum SessionDrummerParameters {
  /// What plays the part: Ongaku's Drum Machine, or one of Apple's General MIDI kits.
  static let kitNames = [
    "Ongaku Drum Machine", "Apple Standard Kit", "Apple Power Kit", "Apple Electronic Kit", "Apple TR-808 Kit",
    "Apple Brush Kit", "Apple Orchestra Kit",
  ]

  static let tree = ParameterTreeSpec {
    EffectSpecs.spec(.sdrVolume, "volume", "Kit Volume", .decibels, -40...6, 0)
    EffectSpecs.spec(.sdrPlaysKit, "playsKit", "Play Own Kit", .boolean, 0...1, 1)
    EffectSpecs.spec(.sdrSendsMIDI, "sendsMIDI", "Send MIDI", .boolean, 0...1, 1)
    EffectSpecs.spec(.sdrPreview, "preview", "Preview", .boolean, 0...1, 0)
    // ("kit" is the Drum Machine settings' group.)
    EffectSpecs.spec(.sdrKit, "kitSource", "Kit", .indexed, 0...6, 0, strings: kitNames)
    ParameterGroupSpec(identifier: "kit", name: "Kit") {
      DrumMachineParameters.tree.children
    }
  }
}

// MARK: - Mastering

/// Mastering's parameters: the controls, then the settings the listening pass writes for
/// the song (the EQ bands, the compressor and the measured loudness).
enum MasteringParameters {
  static let characters = ["Clean", "Valve", "Punch", "Transparent"]

  /// Low-End Mono below this is off (the kernel's `Mastering::lowEndMonoOff`).
  static let lowEndMonoOff: AUValue = 60
  /// The measured loudness that means the song hasn't been listened to yet.
  static let notMeasured: AUValue = -70

  /// The defaults are the first preset, Clean.
  static let tree = ParameterTreeSpec {
    EffectSpecs.spec(.mstCharacter, "character", "Character", .indexed, 0...3, 0, strings: characters)
    EffectSpecs.spec(.mstLoudness, "loudness", "Loudness", .customUnit, -16...(-8), -14, unitName: "LUFS")
    EffectSpecs.spec(.mstCompare, "compare", "Compare", .boolean, 0...1, 0)
    EffectSpecs.spec(.mstEQAmount, "eqAmount", "EQ Amount", .percent, 0...100, 100)
    EffectSpecs.spec(.mstDynamics, "dynamics", "Dynamics", .percent, 0...100, 50)
    EffectSpecs.spec(.mstWidth, "width", "Width", .percent, 0...100, 0)
    EffectSpecs.spec(.mstLowEndMono, "lowEndMono", "Low-End Mono", .hertz, 50...200, 120, logarithmic: true)
    EffectSpecs.spec(.mstCeiling, "ceiling", "Ceiling", .customUnit, -3...0, -1, unitName: "dBTP")
    EffectSpecs.spec(.mstLowShelf, "eqLowShelf", "EQ Low Shelf", .decibels, -6...6, 0)
    EffectSpecs.spec(.mstLowMid, "eqLowMid", "EQ Low-Mid", .decibels, -6...6, 0)
    EffectSpecs.spec(.mstPresence, "eqPresence", "EQ Presence", .decibels, -6...6, 0)
    EffectSpecs.spec(.mstAir, "eqAir", "EQ Air", .decibels, -6...6, 0)
    EffectSpecs.spec(.mstHighShelf, "eqHighShelf", "EQ High Shelf", .decibels, -6...6, 0)
    EffectSpecs.spec(.mstThreshold, "compThreshold", "Comp Threshold", .decibels, -40...0, -18)
    EffectSpecs.spec(.mstRatio, "compRatio", "Comp Ratio", .ratio, 1...4, 1.5)
    EffectSpecs.spec(.mstAttack, "compAttack", "Comp Attack", .milliseconds, 1...100, 20, logarithmic: true)
    EffectSpecs.spec(.mstRelease, "compRelease", "Comp Release", .milliseconds, 20...1_000, 200, logarithmic: true)
    EffectSpecs.spec(.mstMeasuredLoudness, "measuredLoudness", "Measured Loudness", .customUnit, -70...0, -70, unitName: "LUFS")
    EffectSpecs.spec(.mstListen, "listen", "Listen", .boolean, 0...1, 0)
  }

  /// Where the song is going: how loud it ends up and how close its peaks may come to full
  /// scale. The character (chosen in the window) and the listening pass's settings (the EQ
  /// bands, the compressor, the measured loudness) are left alone.
  private static func preset(_ name: String, loudness: AUValue, ceiling: AUValue) -> EffectPreset {
    let controls: [(OngakuEffectsParameterAddress, AUValue)] = [
      (.mstLoudness, loudness), (.mstCeiling, ceiling), (.mstCompare, 0),
    ]
    return EffectPreset(name: name, values: Dictionary(uniqueKeysWithValues: controls.map { ($0.rawValue, $1) }), resetsOthers: false)
  }

  /// Streaming first: it's the defaults.
  static let presets = [
    preset("Streaming", loudness: -14, ceiling: -1),
    preset("Gentle", loudness: -16, ceiling: -1),
    preset("Loud", loudness: -10, ceiling: -1),
    preset("Club / CD", loudness: -8, ceiling: -0.3),
  ]
}
