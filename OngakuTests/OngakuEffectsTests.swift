//
//  OngakuEffectsTests.swift
//  OngakuTests
//

import Accelerate
import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
import Testing

/// Ongaku's own effects, loaded from the extension inside the app the way the mixer loads
/// them (out of process), and measured.
@MainActor
@Suite(.serialized)
struct OngakuEffectsTests {
  private let rate = 48_000.0

  private func description(_ effect: OngakuEffect) -> AudioComponentDescription {
    let reference = effect.makeReference()
    return AudioComponentDescription(
      componentType: reference.componentType, componentSubType: reference.componentSubType,
      componentManufacturer: reference.componentManufacturer, componentFlags: 0, componentFlagsMask: 0)
  }

  private func load(_ effect: OngakuEffect) async throws -> AVAudioUnit {
    try await AVAudioUnit.instantiate(with: description(effect), options: [.loadOutOfProcess])
  }

  private func set(_ unit: AVAudioUnit, _ values: [AUParameterAddress: AUValue]) throws {
    let tree = try #require(unit.au.parameterTree)
    for (address, value) in values {
      try #require(tree.parameter(withAddress: address)).value = value
    }
  }

  private func address(band: Int, _ field: Int) -> AUParameterAddress {
    AUParameterAddress(10 + 10 * band + field)
  }

  /// The gain in decibels the unit gives a sine at `frequency` (once settings have glided
  /// into place).
  private func gain(of unit: AVAudioUnit, at frequency: Double, amplitude: Double = 0.25) throws -> Double {
    let settled = try render(unit, frequency: frequency, amplitude: amplitude, blocks: 12).left[(6 * 4_096)...]
    let rms = (settled.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(settled.count, 1))).squareRoot()
    return 20 * log10(max(rms, 1e-9) / (amplitude / 2.0.squareRoot()))
  }

  /// Renders a sine through the unit, from its first sample, for `blocks` blocks of 4,096
  /// samples.
  private func render(_ unit: AVAudioUnit, frequency: Double, amplitude: Double, blocks: Int) throws
    -> (left: [Float], right: [Float])
  {
    let step = 2 * .pi * frequency / rate
    return try render(unit, blocks: blocks) { Float(amplitude * sin(step * Double($0))) }
  }

  /// Renders a signal (a sample for each frame number, the same in both channels) through
  /// the unit, from its first sample.
  private func render(_ unit: AVAudioUnit, blocks: Int, signal: @escaping @Sendable (Int) -> Float) throws
    -> (left: [Float], right: [Float])
  {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
    let generator = SignalSource(signal)
    let source = AVAudioSourceNode(format: format) { _, _, frameCount, data in
      generator.render(frameCount: Int(frameCount), into: data)
      return noErr
    }
    engine.attach(source)
    engine.attach(unit)
    try engine.connectNode(source, to: unit, format: format)
    try engine.connectNode(unit, to: engine.mainMixerNode, format: format)
    try engine.start()
    defer {
      engine.stop()
      engine.detach(unit)
    }

    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
    var left: [Float] = [], right: [Float] = []
    for _ in 0..<blocks {
      _ = try engine.renderOffline(4_096, to: buffer)
      left += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
      right += UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength))
    }
    return (left, right)
  }

  @Test func theChannelEQIsInstalledWithTheApp() throws {
    let components = AVAudioUnitComponentManager.shared().components(matching: description(.channelEQ))
    #expect(components.first?.name == "Channel EQ")
    #expect(components.first?.manufacturerName == "Ongaku")
    #expect(!InstrumentLibrary.audioUnitEffects().contains { $0.componentManufacturer == OngakuEffect.manufacturer },
      "Ongaku's effects are listed as built-ins, not with other Audio Units")
  }

  @Test func theChannelEQIsFlatByDefault() async throws {
    let unit = try await load(.channelEQ)
    for frequency in [60.0, 1_000, 12_000] {
      let gain = try gain(of: unit, at: frequency)
      #expect(abs(gain) < 0.1, "\(gain) dB at \(frequency) Hz")
    }
  }

  @Test func aBellBoostsItsFrequency() async throws {
    let unit = try await load(.channelEQ)
    // The Mid band (the fourth) up 12 dB at 1 kHz.
    try set(unit, [address(band: 3, 1): 1_000, address(band: 3, 2): 12, address(band: 3, 3): 1])
    #expect(abs(try gain(of: unit, at: 1_000) - 12) < 0.3)
    #expect(abs(try gain(of: unit, at: 100)) < 0.5, "Far below the bell is untouched")
    #expect(abs(try gain(of: unit, at: 10_000)) < 0.5, "Far above it too")
  }

  @Test func theLowCutFallsAtItsSlope() async throws {
    let unit = try await load(.channelEQ)
    // Low cut on at 1 kHz, 24 dB per octave.
    try set(unit, [address(band: 0, 0): 1, address(band: 0, 1): 1_000, address(band: 0, 4): 3])
    #expect(abs(try gain(of: unit, at: 1_000) + 3) < 0.5, "Butterworth: 3 dB down at the corner")
    let twoOctavesDown = try gain(of: unit, at: 250)
    #expect(abs(twoOctavesDown + 48) < 1.5, "\(twoOctavesDown) dB two octaves down")
    #expect(abs(try gain(of: unit, at: 8_000)) < 0.3)
  }

  @Test func outputGainAndBypass() async throws {
    let unit = try await load(.channelEQ)
    try set(unit, [0: -6])
    #expect(abs(try gain(of: unit, at: 1_000) + 6) < 0.1)
    unit.au.shouldBypassEffect = true
    #expect(abs(try gain(of: unit, at: 1_000)) < 0.1)
  }

  @Test func settingsAreSavedAndRestored() async throws {
    let unit = try await load(.channelEQ)
    try set(unit, [address(band: 5, 1): 3_200, address(band: 5, 2): -7.5])
    let state = try #require(unit.au.fullState)

    let restored = try await load(.channelEQ)
    restored.au.fullState = state
    let tree = try #require(restored.au.parameterTree)
    #expect(tree.parameter(withAddress: address(band: 5, 1))?.value == 3_200)
    #expect(tree.parameter(withAddress: address(band: 5, 2))?.value == -7.5)
    #expect(abs(try gain(of: restored, at: 3_200) + 7.5) < 0.3, "The restored unit sounds the same")
  }

  // MARK: - Compressor

  private let threshold = AUParameterAddress(100), ratio = AUParameterAddress(101), attack = AUParameterAddress(102)
  private let knee = AUParameterAddress(104), makeUp = AUParameterAddress(105), autoGain = AUParameterAddress(106)
  private let mix = AUParameterAddress(107), detection = AUParameterAddress(108)

  @Test func quietSignalsPassUntouched() async throws {
    let unit = try await load(.compressor)
    // −26 dB peaks, under the −20 dB threshold (and its knee).
    #expect(abs(try gain(of: unit, at: 1_000, amplitude: 0.05)) < 0.1)
  }

  @Test(arguments: [(0.0, 4.0), (1.0, 4.0), (1.0, 2.0)])
  func loudSignalsAreCompressedByTheRatio(detectionMode: Double, ratioValue: Double) async throws {
    let unit = try await load(.compressor)
    try set(unit, [threshold: -20, ratio: AUValue(ratioValue), knee: 0, detection: AUValue(detectionMode)])
    // −6 dB peaks are 14 dB over, so come out at −20 + 14 / ratio.
    let expected = -20 + 14 / ratioValue - -6.02
    let gain = try gain(of: unit, at: 1_000, amplitude: 0.5)
    #expect(abs(gain - expected) < 0.3, "\(gain) dB, expected \(expected)")
  }

  @Test func makeUpMixAndAutoGain() async throws {
    let unit = try await load(.compressor)
    try set(unit, [threshold: -20, ratio: 4, knee: 0, detection: 1, makeUp: 6])
    #expect(abs(try gain(of: unit, at: 1_000, amplitude: 0.5) - (-10.5 + 6)) < 0.3)
    // Automatic make-up adds half of what 0 dB loses (15 dB at 4:1).
    try set(unit, [makeUp: 0, autoGain: 1])
    #expect(abs(try gain(of: unit, at: 1_000, amplitude: 0.5) - (-10.5 + 7.5)) < 0.3)
    try set(unit, [autoGain: 0, mix: 0])
    #expect(abs(try gain(of: unit, at: 1_000, amplitude: 0.5)) < 0.1, "All dry")
  }

  @Test func attackLetsTheStartThrough() async throws {
    let unit = try await load(.compressor)
    try set(unit, [threshold: -30, ratio: 10, knee: 0, attack: 30])
    let first = try render(unit, frequency: 1_000, amplitude: 0.5, blocks: 2).left
    let start = first[0..<240].map(abs).max() ?? 0
    let later = first[7_000..<8_000].map(abs).max() ?? 0
    #expect(start > 0.4, "The first 5 ms is hardly touched (\(start))")
    #expect(later < 0.2, "By 150 ms it's well compressed (\(later))")
  }

  // MARK: - Reverb

  private let predelay = AUParameterAddress(200), decay = AUParameterAddress(201), width = AUParameterAddress(207)
  private let reverbMix = AUParameterAddress(208)

  /// The level in dB of a stretch of samples (RMS).
  private func level(_ samples: ArraySlice<Float>) -> Double {
    let power = samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(samples.count, 1))
    return 10 * log10(max(power, 1e-24))
  }

  @Test func theReverbDecaysAtItsDecayTime() async throws {
    let unit = try await load(.reverb)
    try set(unit, [decay: 2, predelay: 0, reverbMix: 100])
    // A short burst, then 1.5 s of the tail.
    let (left, _) = try render(unit, blocks: 18) { $0 < 480 ? Float.random(in: -0.5...0.5) : 0 }
    let early = level(left[Int(0.2 * rate)..<Int(0.3 * rate)])
    let late = level(left[Int(1.2 * rate)..<Int(1.3 * rate)])
    // −60 dB in 2 s is −30 dB in a second (the highs fall faster, so allow a little more).
    let fall = early - late
    #expect((25.0...40.0).contains(fall), "Fell \(fall) dB in a second")
    let isFinite = left.allSatisfy { $0.isFinite }
    #expect(isFinite)
    #expect(abs(unit.au.tailTime - 3) < 0.01, "Decay and predelay make the tail")
  }

  @Test func thePredelayHoldsBackTheReverb() async throws {
    let unit = try await load(.reverb)
    try set(unit, [predelay: 50, reverbMix: 100])
    let (left, _) = try render(unit, blocks: 2) { $0 == 0 ? 1 : 0 }
    let arrival = try #require(left.firstIndex { abs($0) > 1e-4 })
    #expect(abs(Double(arrival) / rate - 0.05) < 0.002, "First heard at \(Double(arrival) / rate) s")
  }

  @Test func widthSpreadsTheTail() async throws {
    let unit = try await load(.reverb)
    try set(unit, [reverbMix: 100, width: 100])
    let burst: @Sendable (Int) -> Float = { $0 < 2_400 ? sin(Float($0) * 0.37) * 0.5 : 0 }
    let (left, right) = try render(unit, blocks: 6, signal: burst)
    let wide = zip(left, right).map { abs($0 - $1) }.max() ?? 0
    #expect(wide > 0.01, "The sides differ at full width")

    let narrow = try await load(.reverb)
    try set(narrow, [reverbMix: 100, width: 0])
    let (monoLeft, monoRight) = try render(narrow, blocks: 6, signal: burst)
    let isMono = zip(monoLeft, monoRight).allSatisfy { abs($0 - $1) < 1e-6 }
    #expect(isMono, "At zero width it's mono")
  }

  @Test func theLowCutThinsTheReverb() async throws {
    let lowCut = AUParameterAddress(205)
    let unit = try await load(.reverb)
    try set(unit, [reverbMix: 100, lowCut: 20])
    let full = try gain(of: unit, at: 100)
    try set(unit, [lowCut: 500])
    let thinned = try gain(of: unit, at: 100)
    // Two and a bit octaves under a 24 dB/octave cut.
    #expect(full - thinned > 40, "100 Hz fell \(full - thinned) dB")
  }

  @Test func dryAtZeroMixAndRoomsSetTheRoom() async throws {
    let unit = try await load(.reverb)
    #expect(unit.au.currentPreset?.name == "Hall", "A new reverb starts as a hall")
    try set(unit, [reverbMix: 0])
    #expect(abs(try gain(of: unit, at: 440)) < 0.01)

    let presets = try #require(unit.au.factoryPresets)
    #expect(presets.map(\.name) == ["Room", "Chamber", "Hall", "Plate", "Cathedral"])
    unit.au.currentPreset = presets[4]
    let tree = try #require(unit.au.parameterTree)
    #expect(tree.parameter(withAddress: decay)?.value == 7)
    #expect(tree.parameter(withAddress: reverbMix)?.value == 0, "Rooms leave the mix alone")
  }

  // MARK: - Delay

  private let dlySync = AUParameterAddress(300), dlyTime = AUParameterAddress(301), dlyNote = AUParameterAddress(302)
  private let dlyFeedback = AUParameterAddress(303), dlyPingPong = AUParameterAddress(304)
  private let dlyLowCut = AUParameterAddress(305), dlyHighCut = AUParameterAddress(306)
  private let dlyFlutter = AUParameterAddress(307), dlyDrive = AUParameterAddress(308), dlyMix = AUParameterAddress(309)

  /// A clean delay (no filtering, wobble or saturation), all wet.
  private func cleanDelay() async throws -> AVAudioUnit {
    let unit = try await load(.delay)
    try set(unit, [dlyLowCut: 20, dlyHighCut: 20_000, dlyFlutter: 0, dlyDrive: 0, dlyMix: 100])
    return unit
  }

  /// Where each burst of sound starts (in seconds), and its peak, looking for gaps of
  /// silence between them.
  private func bursts(in samples: [Float]) -> [(time: Double, peak: Float)] {
    var found: [(time: Double, peak: Float)] = []
    var index = 0
    while index < samples.count {
      guard abs(samples[index]) > 0.01 else { index += 1; continue }
      let end = min(samples.count, index + Int(0.02 * rate))
      found.append((Double(index) / rate, samples[index..<end].map(abs).max() ?? 0))
      index = end
      while index < samples.count, abs(samples[index]) > 0.01 { index += 1 }
    }
    return found
  }

  @Test func echoesComeAtTheTimeAndFallByTheFeedback() async throws {
    let unit = try await cleanDelay()
    try set(unit, [dlySync: 0, dlyTime: 100, dlyFeedback: 50])
    // A 2 ms click.
    let (left, _) = try render(unit, blocks: 4) { $0 < 96 ? 0.8 * sin(Float($0) * 0.5) : 0 }
    let echoes = bursts(in: left)
    try #require(echoes.count >= 3)
    #expect(abs(echoes[0].time - 0.1) < 0.002, "First echo at \(echoes[0].time) s")
    #expect(abs(echoes[1].time - 0.2) < 0.002)
    let fall = 20 * log10(Double(echoes[1].peak / echoes[0].peak))
    #expect(abs(fall + 6) < 0.5, "Each echo is 6 dB down (\(fall))")
  }

  @Test func syncedEchoesFollowTheHostsTempo() async throws {
    let unit = try await cleanDelay()
    // A quarter note at 100 BPM is 0.6 s.
    try set(unit, [dlySync: 1, dlyNote: 8, dlyFeedback: 0])
    let context = HostMusicalContext()
    context.update(at: .zero, in: TempoMap(bpm: 100))
    unit.au.musicalContextBlock = context.block
    let (left, _) = try render(unit, blocks: 10) { $0 < 96 ? 0.8 * sin(Float($0) * 0.5) : 0 }
    let echo = try #require(bursts(in: left).first)
    #expect(abs(echo.time - 0.6) < 0.002, "Echo at \(echo.time) s")
    #expect(abs(unit.au.tailTime - 1.2) < 0.01, "One echo, then nothing")
  }

  @Test func pingPongBouncesSideToSide() async throws {
    let unit = try await cleanDelay()
    try set(unit, [dlySync: 0, dlyTime: 100, dlyFeedback: 70, dlyPingPong: 1])
    let (left, right) = try render(unit, blocks: 4) { $0 < 96 ? 0.8 * sin(Float($0) * 0.5) : 0 }
    let leftEchoes = bursts(in: left).map(\.time)
    let rightEchoes = bursts(in: right).map(\.time)
    #expect(abs((leftEchoes.first ?? 0) - 0.1) < 0.002, "The first echo is on the left")
    #expect(abs((rightEchoes.first ?? 0) - 0.2) < 0.002, "The next is on the right")
    #expect(abs((leftEchoes.dropFirst().first ?? 0) - 0.3) < 0.002, "Then the left again")
  }

  @Test func driveAndFlutterKeepTheEchoesSane() async throws {
    let unit = try await load(.delay)
    try set(unit, [dlySync: 0, dlyTime: 50, dlyFeedback: 100, dlyDrive: 100, dlyFlutter: 100, dlyMix: 100])
    // Full feedback on loud noise: saturation keeps it from running away.
    let (left, _) = try render(unit, blocks: 24) { _ in Float.random(in: -0.9...0.9) }
    let isFinite = left.allSatisfy { $0.isFinite }
    #expect(isFinite)
    #expect((left.map(abs).max() ?? 0) < 2.5)
  }
}

/// A signal, one sample per frame number, rendered on the audio thread.
private final class SignalSource: @unchecked Sendable {
  private let signal: @Sendable (Int) -> Float
  private var frame = 0

  init(_ signal: @escaping @Sendable (Int) -> Float) {
    self.signal = signal
  }

  func render(frameCount: Int, into data: UnsafeMutablePointer<AudioBufferList>) {
    for buffer in UnsafeMutableAudioBufferListPointer(data) {
      guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
      for index in 0..<frameCount {
        samples[index] = signal(frame + index)
      }
    }
    frame += frameCount
  }
}

// MARK: - Instruments

/// Ongaku's own instruments, loaded the way tracks load them (out of process), played with
/// MIDI and listened to.
extension OngakuEffectsTests {
  private func loadInstrument(_ instrument: OngakuInstrument) async throws -> AVAudioUnit {
    let reference = instrument.makeReference()
    return try await AVAudioUnit.instantiate(
      with: AudioComponentDescription(
        componentType: reference.componentType, componentSubType: reference.componentSubType,
        componentManufacturer: reference.componentManufacturer, componentFlags: 0, componentFlagsMask: 0),
      options: [.loadOutOfProcess])
  }

  private func setSynth(_ unit: AVAudioUnit, _ values: [OngakuSynthParameter: AUValue]) throws {
    let tree = try #require(unit.au.parameterTree)
    for (parameter, value) in values {
      try #require(tree.parameter(withAddress: parameter.rawValue)).value = value
    }
  }

  /// Plays MIDI events (each at a frame) through the instrument for `seconds`, and returns
  /// the left channel.
  private func playMIDI(_ unit: AVAudioUnit, seconds: Double, events: [(frame: Int, bytes: [UInt8])]) throws -> [Float] {
    try playStereo(unit, seconds: seconds, events: events).left
  }

  /// Plays MIDI events through the instrument, and returns both channels.
  private func playStereo(_ unit: AVAudioUnit, seconds: Double, events: [(frame: Int, bytes: [UInt8])]) throws
    -> (left: [Float], right: [Float])
  {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    engine.attach(unit)
    try engine.connectNode(unit, to: engine.mainMixerNode, format: format)
    try engine.start()
    defer {
      engine.stop()
      engine.detach(unit)
    }
    let schedule = try #require(unit.au.scheduleMIDIEventBlock)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
    var samples: [Float] = [], right: [Float] = []
    let total = Int(seconds * rate)
    while samples.count < total {
      // Events in this block, at their offsets into it.
      for event in events where event.frame >= samples.count && event.frame < samples.count + 512 {
        var bytes = event.bytes
        schedule(AUEventSampleTimeImmediate + AUEventSampleTime(event.frame - samples.count), 0, bytes.count, &bytes)
      }
      _ = try engine.renderOffline(512, to: buffer)
      samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
      right += UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength))
    }
    return (Array(samples.prefix(total)), Array(right.prefix(total)))
  }

  private func noteOn(_ note: UInt8, at frame: Int = 0, velocity: UInt8 = 100) -> (frame: Int, bytes: [UInt8]) {
    (frame, [0x90, note, velocity])
  }

  private func noteOff(_ note: UInt8, at frame: Int) -> (frame: Int, bytes: [UInt8]) {
    (frame, [0x80, note, 0])
  }

    // MARK: - Retro Synth

  @Test func theRetroSynthIsInstalledAsAnInstrument() throws {
    let entry = try #require(InstrumentLibrary.ongakuInstruments().first)
    #expect(entry.name == "Retro Synth")
    let components = AVAudioUnitComponentManager.shared().components(
      matching: AudioComponentDescription(
        componentType: entry.componentType, componentSubType: entry.componentSubType,
        componentManufacturer: entry.componentManufacturer, componentFlags: 0, componentFlagsMask: 0))
    #expect(components.first?.name == "Retro Synth")
    #expect(components.first?.hasMIDIInput == true)
    #expect(!InstrumentLibrary.audioUnitInstruments().contains { $0.componentManufacturer == OngakuEffect.manufacturer },
      "Listed as Ongaku's own, not with other Audio Units")
  }

  @Test(arguments: [(69, 3), (57, 0), (45, 1)])
  func notesPlayInTune(note: Int, wave: Int) async throws {
    let unit = try await loadInstrument(.retroSynth)
    // One oscillator's wave, the filter open.
    try setSynth(unit, [.synOsc1Wave: AUValue(wave), .synOscMix: 0, .synCutoff: 20_000, .synResonance: 0, .synFilterEnv: 0])
    let samples = try playMIDI(unit, seconds: 0.6, events: [noteOn(UInt8(note))])
    let found = PitchDetector.notes(samples, sampleRate: rate)
    let pitch = try #require(found.first?.pitch)
    #expect(abs(pitch - Double(note)) < 0.1, "Played \(note), heard \(pitch)")
  }

  @Test func notesStopAfterTheirRelease() async throws {
    let unit = try await loadInstrument(.retroSynth)
    try setSynth(unit, [.synAmpRelease: 100])
    let samples = try playMIDI(unit, seconds: 1, events: [noteOn(60), noteOff(60, at: Int(0.3 * rate))])
    #expect(level(samples[Int(0.1 * rate)..<Int(0.3 * rate)]) > -40, "Sounding while held")
    #expect(level(samples[Int(0.7 * rate)...]) < -90, "Silent once released")
  }

  @Test func theSustainPedalHoldsNotes() async throws {
    let unit = try await loadInstrument(.retroSynth)
    try setSynth(unit, [.synAmpRelease: 50])
    let samples = try playMIDI(unit, seconds: 1, events: [
      (0, [0xB0, 64, 127]), noteOn(60), noteOff(60, at: Int(0.2 * rate)), (Int(0.6 * rate), [0xB0, 64, 0]),
    ])
    #expect(level(samples[Int(0.4 * rate)..<Int(0.55 * rate)]) > -40, "Held by the pedal")
    #expect(level(samples[Int(0.8 * rate)...]) < -90, "Released with it")
  }

  @Test func chordsPlayEveryNote() async throws {
    let unit = try await loadInstrument(.retroSynth)
    let one = try playMIDI(unit, seconds: 0.5, events: [noteOn(60)])
    let three = try playMIDI(unit, seconds: 0.5, events: [noteOn(60), noteOn(64), noteOn(67)])
    let difference = level(three[Int(0.2 * rate)...]) - level(one[Int(0.2 * rate)...])
    #expect(difference > 3, "Three voices are louder than one (\(difference) dB)")
  }

  @Test func theFilterDarkensTheSound() async throws {
    /// How much of the sound is in the highs: its level after differencing it three times
    /// (which tilts it up 18 dB an octave) against its level.
    func brightness(_ samples: [Float]) -> Double {
      var tilted = samples
      for _ in 0..<3 { tilted = zip(tilted.dropFirst(), tilted).map { $0 - $1 } }
      return level(tilted[...]) - level(samples[...])
    }
    let unit = try await loadInstrument(.retroSynth)
    try setSynth(unit, [.synFilterEnv: 0, .synResonance: 0, .synCutoff: 8_000])
    let bright = try playMIDI(unit, seconds: 0.4, events: [noteOn(45)])
    try setSynth(unit, [.synCutoff: 200])
    let dark = try playMIDI(unit, seconds: 0.4, events: [noteOn(45)])
    let difference = brightness(Array(bright[Int(0.1 * rate)...])) - brightness(Array(dark[Int(0.1 * rate)...]))
    #expect(difference > 20, "A low cutoff takes the highs away (\(difference) dB)")
  }

  @Test func patchesSetEverything() async throws {
    let unit = try await loadInstrument(.retroSynth)
    let presets = try #require(unit.au.factoryPresets)
    #expect(presets.map(\.name) == [
      "Analog Saws", "Fat Bass", "Soft Pad", "Square Lead", "Brass", "Pluck", "PWM Strings", "Supersaw", "Sync Lead",
      "Ring Bells", "FM Keys", "Sub Bass",
    ])
    #expect(unit.au.currentPreset?.name == "Analog Saws")
    let tree = try #require(unit.au.parameterTree)
    unit.au.currentPreset = presets[1]
    #expect(tree.parameter(withAddress: OngakuSynthParameter.synMode.rawValue)?.value == 1)
    #expect(tree.parameter(withAddress: OngakuSynthParameter.synCutoff.rawValue)?.value == 300)
    // Back to the first patch: what Fat Bass changed goes back too.
    unit.au.currentPreset = presets[0]
    #expect(tree.parameter(withAddress: OngakuSynthParameter.synMode.rawValue)?.value == 0)
    #expect(tree.parameter(withAddress: OngakuSynthParameter.synCutoff.rawValue)?.value == 2_500)
  }

  // MARK: - Drum Machine

  /// Pads in General MIDI order: kick 36, snare 38, clap 39, rim 37, closed hat 42, open hat
  /// 46, low tom 45, mid tom 47, high tom 50, cowbell 56, crash 49, shaker 70.
  private var drumNotes: [UInt8] { [36, 38, 39, 37, 42, 46, 45, 47, 50, 56, 49, 70] }

  private func setDrum(_ unit: AVAudioUnit, pad: Int, field: Int, _ value: AUValue) throws {
    let tree = try #require(unit.au.parameterTree)
    try #require(tree.parameter(withAddress: AUParameterAddress(510 + 5 * pad + field))).value = value
  }

  @Test func everyPadSoundsOnItsNote() async throws {
    #expect(InstrumentLibrary.ongakuInstruments().map(\.name) == ["Retro Synth", "Drum Machine", "Sampler", "Session Drummer"])
    let unit = try await loadInstrument(.drumMachine)
    for note in drumNotes {
      let samples = try playMIDI(unit, seconds: 0.2, events: [noteOn(note)])
      #expect(level(samples[..<Int(0.15 * rate)]) > -40, "Note \(note) plays a drum")
    }
    let other = try playMIDI(unit, seconds: 0.2, events: [noteOn(60)])
    #expect(level(other[...]) < -100, "Notes without a pad are silent")
  }

  @Test func tuneShiftsTheDrum() async throws {
    let unit = try await loadInstrument(.drumMachine)
    // The mid tom (pad 7), once its pitch has settled.
    func pitch() throws -> Double? {
      let samples = try playMIDI(unit, seconds: 0.5, events: [noteOn(47)])
      return PitchDetector.notes(Array(samples[Int(0.12 * rate)..<Int(0.4 * rate)]), sampleRate: rate).first?.pitch
    }
    let low = try #require(try pitch())
    try setDrum(unit, pad: 7, field: 0, 12)
    let high = try #require(try pitch())
    #expect(abs(high - low - 12) < 1, "An octave up: \(low) to \(high)")
  }

  @Test func decayLengthensTheDrum() async throws {
    let unit = try await loadInstrument(.drumMachine)
    try setDrum(unit, pad: 1, field: 1, 50)
    let short = try playMIDI(unit, seconds: 0.6, events: [noteOn(38)])
    try setDrum(unit, pad: 1, field: 1, 300)
    let long = try playMIDI(unit, seconds: 0.6, events: [noteOn(38)])
    let tail = Int(0.3 * rate)..<Int(0.5 * rate)
    #expect(level(long[tail]) - level(short[tail]) > 10, "A longer decay rings on")
  }

  @Test func theClosedHatChokesTheOpenHat() async throws {
    let unit = try await loadInstrument(.drumMachine)
    let alone = try playMIDI(unit, seconds: 0.5, events: [noteOn(46)])
    let choked = try playMIDI(unit, seconds: 0.5, events: [noteOn(46), noteOn(42, at: Int(0.1 * rate))])
    let after = Int(0.25 * rate)..<Int(0.45 * rate)
    #expect(level(alone[after]) - level(choked[after]) > 15, "The closed hat cuts the open hat off")
  }

  @Test func velocitySetsTheLevel() async throws {
    let unit = try await loadInstrument(.drumMachine)
    let hard = try playMIDI(unit, seconds: 0.3, events: [noteOn(36, velocity: 127)])
    let soft = try playMIDI(unit, seconds: 0.3, events: [noteOn(36, velocity: 20)])
    #expect(level(hard[...]) - level(soft[...]) > 6)
  }

  @Test func kitsSetEveryDrum() async throws {
    let unit = try await loadInstrument(.drumMachine)
    let presets = try #require(unit.au.factoryPresets)
    #expect(presets.map(\.name) == ["Analog 808", "Punchy 909", "Lo-Fi", "Electro"])
    #expect(unit.au.currentPreset?.name == "Analog 808")
    let tree = try #require(unit.au.parameterTree)
    unit.au.currentPreset = presets[1]
    #expect(tree.parameter(withAddress: 511)?.value == 55, "909 kick decay")
    unit.au.currentPreset = presets[0]
    #expect(tree.parameter(withAddress: 511)?.value == 100)
  }

  // MARK: Oscillator features

  /// Sines with the filter open, so pitch and timbre come straight from the oscillators.
  private func pureSynth() async throws -> AVAudioUnit {
    let unit = try await loadInstrument(.retroSynth)
    try setSynth(unit, [.synOsc1Wave: 3, .synOsc2Wave: 3, .synOsc2Detune: 0, .synCutoff: 20_000, .synResonance: 0,
                        .synFilterEnv: 0, .synKeyTrack: 0])
    return unit
  }

  private func pitch(_ samples: [Float]) -> Double? {
    PitchDetector.notes(Array(samples[Int(0.1 * rate)...]), sampleRate: rate).first?.pitch
  }

  /// The level of the highs against the whole (see `theFilterDarkensTheSound`).
  private func brightness(_ samples: [Float]) -> Double {
    var tilted = Array(samples[Int(0.1 * rate)...])
    let whole = level(tilted[...])
    for _ in 0..<3 { tilted = zip(tilted.dropFirst(), tilted).map { $0 - $1 } }
    return level(tilted[...]) - whole
  }

  @Test func unisonSpreadsAcrossTheStereoField() async throws {
    let unit = try await loadInstrument(.retroSynth)
    let single = try playStereo(unit, seconds: 0.4, events: [noteOn(57)])
    let isMono = zip(single.left, single.right).allSatisfy { abs($0 - $1) < 1e-6 }
    #expect(isMono, "One voice sits in the middle")
    try setSynth(unit, [.synUnison: 5, .synUnisonSpread: 100])
    let wide = try playStereo(unit, seconds: 0.4, events: [noteOn(57)])
    let difference = zip(wide.left, wide.right).map { abs($0 - $1) }.max() ?? 0
    #expect(difference > 0.01, "Five spread voices differ left and right")
  }

  @Test func unisonStaysInTune() async throws {
    let unit = try await pureSynth()
    try setSynth(unit, [.synOscMix: 0, .synUnison: 7, .synUnisonDetune: 20])
    let found = try #require(pitch(try playMIDI(unit, seconds: 0.6, events: [noteOn(60)])))
    #expect(abs(found - 60) < 0.2, "Detuned evenly around the note: \(found)")
  }

  @Test func theSubPlaysAnOctaveDown() async throws {
    let unit = try await pureSynth()
    try setSynth(unit, [.synOscMix: 0, .synSubLevel: 100])
    let found = try #require(pitch(try playMIDI(unit, seconds: 0.6, events: [noteOn(60)])))
    #expect(abs(found - 48) < 0.2, "The sub sets the pitch an octave down: \(found)")
  }

  @Test func syncTiesOscillator2ToOscillator1() async throws {
    let unit = try await pureSynth()
    // Only oscillator 2 heard, a fifth up.
    try setSynth(unit, [.synOscMix: 100, .synOsc2Semitones: 7])
    let free = try #require(pitch(try playMIDI(unit, seconds: 0.6, events: [noteOn(57)])))
    #expect(abs(free - 64) < 0.2, "On its own, a fifth up: \(free)")
    try setSynth(unit, [.synOsc2Mode: 1])
    let synced = try #require(pitch(try playMIDI(unit, seconds: 0.6, events: [noteOn(57)])))
    #expect(abs(synced - 57) < 0.2, "Synced, it repeats with oscillator 1: \(synced)")
  }

  @Test func ringModulationMakesNewFrequencies() async throws {
    let unit = try await pureSynth()
    // Oscillator 2 an octave up: alone it's heard there; ringed with oscillator 1 the
    // product (the difference and sum, f and 3f) repeats at oscillator 1's pitch.
    try setSynth(unit, [.synOscMix: 100, .synOsc2Semitones: 12, .synOsc2Mode: 2])
    let ringed = try #require(pitch(try playMIDI(unit, seconds: 0.6, events: [noteOn(57)])))
    #expect(abs(ringed - 57) < 0.2, "Ringed: \(ringed)")
  }

  @Test func shapeAndFMChangeTheTone() async throws {
    let unit = try await pureSynth()
    /// The duty cycle: how much of the time the wave spends above its middle.
    func dutyCycle(_ samples: [Float]) -> Double {
      let settled = samples[Int(0.1 * rate)...]
      let middle = settled.reduce(0, +) / Float(settled.count)
      return Double(settled.filter { $0 > middle }.count) / Double(settled.count)
    }
    try setSynth(unit, [.synOscMix: 0, .synOsc1Wave: 1, .synPulseWidth: 50])
    let square = dutyCycle(try playMIDI(unit, seconds: 0.5, events: [noteOn(48)]))
    #expect(abs(square - 0.5) < 0.05, "Shape 50 % is a square (\(square))")
    try setSynth(unit, [.synPulseWidth: 10])
    let narrow = dutyCycle(try playMIDI(unit, seconds: 0.5, events: [noteOn(48)]))
    #expect(abs(narrow - 0.5) > 0.3, "Shape 10 % is a narrow pulse (\(narrow))")

    try setSynth(unit, [.synOsc1Wave: 3, .synPulseWidth: 50, .synFM: 0])
    let sine = brightness(try playMIDI(unit, seconds: 0.5, events: [noteOn(48)]))
    try setSynth(unit, [.synFM: 70, .synOsc2Semitones: 12])
    let fm = brightness(try playMIDI(unit, seconds: 0.5, events: [noteOn(48)]))
    #expect(fm - sine > 10, "FM adds harmonics (\(fm - sine) dB)")
  }

  @Test func monoGlidesBetweenLegatoNotes() async throws {
    let unit = try await loadInstrument(.retroSynth)
    try setSynth(unit, [.synMode: 1, .synGlide: 200, .synOsc1Wave: 3, .synOscMix: 0, .synCutoff: 20_000, .synFilterEnv: 0])
    // C, then E played over it: the pitch slides up.
    let samples = try playMIDI(unit, seconds: 1, events: [noteOn(60), noteOn(64, at: Int(0.4 * rate))])
    let notes = PitchDetector.notes(samples, sampleRate: rate)
    #expect(notes.first.map { abs($0.pitch - 60) < 0.2 } == true)
    #expect(notes.last.map { abs($0.pitch - 64) < 0.2 } == true, "Ends on E: \(notes.map(\.pitch))")
  }
}

/// The synth's parameter addresses (from the extension's header), for setting them in tests.
enum OngakuSynthParameter: AUParameterAddress {
  case synOsc1Wave = 400, synOsc2Wave, synOsc2Semitones, synOsc2Detune, synOscMix, synPulseWidth, synNoise, synCutoff,
    synResonance, synFilterEnv, synKeyTrack, synFilterAttack, synFilterDecay, synFilterSustain, synFilterRelease,
    synAmpAttack, synAmpDecay, synAmpSustain, synAmpRelease, synLfoRate, synLfoWave, synLfoPitch, synLfoFilter,
    synLfoPulse, synGlide, synVelocity, synMode, synBendRange, synGain, synOsc2Shape, synOsc2Mode, synFM, synSubLevel,
    synUnison, synUnisonDetune, synUnisonSpread
}

// MARK: - Sampler

/// The Sampler's parameter addresses (from the extension's header), for setting them in tests.
enum OngakuSamplerParameter: AUParameterAddress {
  case start = 600, end, loopStart, loopEnd, playMode, loop, crossfade, reverse, root, transpose, tune, followKeys, glide,
    voices, bendRange, filterOn, cutoff, resonance, filterEnv, keyTrack, filterAttack, filterDecay, filterSustain,
    filterRelease, ampAttack, ampDecay, ampSustain, ampRelease, velocity, lfoRate, lfoWave, lfoPitch, lfoFilter, lfoAmp,
    gain
}

extension OngakuEffectsTests {
  /// A Sampler playing a sample (given as mono audio at 48 kHz), set the way a saved song
  /// sets it: in its state.
  private func sampler(playing audio: [Float], name: String = "Test", _ values: [OngakuSamplerParameter: AUValue] = [:])
    async throws -> AVAudioUnit
  {
    let unit = try await loadInstrument(.sampler)
    var state = try #require(unit.au.fullState)
    let data = audio.withUnsafeBufferPointer { Data(buffer: $0) }
    state["ongakuSample"] = ["name": name, "sampleRate": rate, "channels": 1, "audio": data]
    unit.au.fullState = state
    try setSampler(unit, values)
    return unit
  }

  private func setSampler(_ unit: AVAudioUnit, _ values: [OngakuSamplerParameter: AUValue]) throws {
    let tree = try #require(unit.au.parameterTree)
    for (parameter, value) in values {
      try #require(tree.parameter(withAddress: parameter.rawValue)).value = value
    }
  }

  /// A sine at a frequency, at half scale.
  private func sine(_ frequency: Double, seconds: Double) -> [Float] {
    (0..<Int(seconds * rate)).map { Float(0.5 * sin(2 * .pi * frequency * Double($0) / rate)) }
  }

  @Test func theSamplerIsInstalledAsAnInstrument() throws {
    let entry = try #require(InstrumentLibrary.ongakuInstruments().first { $0.name == "Sampler" })
    let components = AVAudioUnitComponentManager.shared().components(
      matching: AudioComponentDescription(
        componentType: entry.componentType, componentSubType: entry.componentSubType,
        componentManufacturer: entry.componentManufacturer, componentFlags: 0, componentFlagsMask: 0))
    #expect(components.first?.name == "Sampler")
    #expect(components.first?.hasMIDIInput == true)
  }

  @Test func notesAreNamedAsInThePianoRollAndNamesMatchThePanel() async throws {
    let unit = try await loadInstrument(.sampler)
    let tree = try #require(unit.au.parameterTree)
    let root = try #require(tree.parameter(withAddress: OngakuSamplerParameter.root.rawValue))
    var middleC: AUValue = 60
    #expect(root.string(fromValue: &middleC) == "C3", "Middle C is C3, as in Logic")
    #expect(tree.parameter(withAddress: OngakuSamplerParameter.crossfade.rawValue)?.displayName == "Loop X-Fade")
    #expect(tree.parameter(withAddress: OngakuSamplerParameter.lfoFilter.rawValue)?.displayName == "LFO Wah (to Filter)")
    #expect(tree.parameter(withAddress: OngakuSamplerParameter.gain.rawValue)?.displayName == "Volume")
  }

  @Test func anEmptySamplerIsSilent() async throws {
    let unit = try await loadInstrument(.sampler)
    let samples = try playMIDI(unit, seconds: 0.3, events: [noteOn(60)])
    #expect(samples.allSatisfy { $0 == 0 })
  }

  /// An A at 440 Hz, its root note A4: other keys play it at their pitches.
  @Test(arguments: [69, 81, 57, 64])
  func keysPlayTheSampleAtTheirPitch(note: Int) async throws {
    let unit = try await sampler(playing: sine(440, seconds: 2), [.root: 69])
    let samples = try playMIDI(unit, seconds: 0.6, events: [noteOn(UInt8(note))])
    let heard = try #require(pitch(samples))
    #expect(abs(heard - Double(note)) < 0.1, "Played \(note), heard \(heard)")
  }

  @Test func fixedPitchPlaysEveryKeyTheSame() async throws {
    let unit = try await sampler(playing: sine(440, seconds: 2), [.root: 69, .followKeys: 0])
    let samples = try playMIDI(unit, seconds: 0.6, events: [noteOn(50)])
    let heard = try #require(pitch(samples))
    #expect(abs(heard - 69) < 0.1, "Heard \(heard)")
  }

  @Test func theSampleIsSavedInTheState() async throws {
    let first = try await sampler(playing: sine(440, seconds: 1), name: "Sine", [.root: 69, .transpose: 12])
    let state = try #require(first.au.fullState)
    let saved = try #require(state["ongakuSample"] as? [String: Any])
    #expect(saved["name"] as? String == "Sine")
    // Through a property list, as the song stores it.
    let data = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    let restored = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let second = try await loadInstrument(.sampler)
    second.au.fullState = restored
    let samples = try playMIDI(second, seconds: 0.6, events: [noteOn(69)])
    let heard = try #require(pitch(samples))
    #expect(abs(heard - 81) < 0.1, "Plays the restored sample, transposed an octave: \(heard)")
  }

  @Test func classicStopsWithTheKeyAndOneShotPlaysOn() async throws {
    let audio = sine(440, seconds: 1)
    let classic = try await sampler(playing: audio, [.ampRelease: 20])
    let held = try playMIDI(classic, seconds: 0.8, events: [noteOn(60), noteOff(60, at: Int(0.2 * rate))])
    #expect(level(held[Int(0.4 * rate)...]) < -90, "Classic stops after the release")

    let oneShot = try await sampler(playing: audio, [.ampRelease: 20, .playMode: 1])
    let tapped = try playMIDI(oneShot, seconds: 1.2, events: [noteOn(60), noteOff(60, at: Int(0.05 * rate))])
    #expect(level(tapped[Int(0.5 * rate)..<Int(0.9 * rate)]) > -20, "One Shot plays on after the key is let go")
    #expect(level(tapped[Int(1.05 * rate)...]) < -90, "and stops at the sample's end")
  }

  @Test func loopsSustainPastTheSampleEnd() async throws {
    let audio = sine(440, seconds: 0.3)
    let unlooped = try await sampler(playing: audio, [.root: 69])
    let short = try playMIDI(unlooped, seconds: 1, events: [noteOn(69)])
    #expect(level(short[Int(0.4 * rate)...]) < -90, "Without a loop it stops at the end")

    for mode: AUValue in [1, 2] {
      let looped = try await sampler(playing: audio, [.root: 69, .loop: mode, .loopStart: 20, .loopEnd: 80, .crossfade: 10])
      let sustained = try playMIDI(looped, seconds: 1, events: [noteOn(69)])
      #expect(level(sustained[Int(0.6 * rate)...]) > -15, "Loop mode \(mode) keeps the note going")
      let heard = try #require(pitch(sustained))
      #expect(abs(heard - 69) < 0.2, "and in tune: \(heard)")
    }
  }

  @Test func reverseAndTheStartMarker() async throws {
    // Silence, then a tone: half a second of each.
    let audio = [Float](repeating: 0, count: Int(0.5 * rate)) + sine(440, seconds: 0.5)
    let forward = try playMIDI(try await sampler(playing: audio, [.root: 69]), seconds: 0.4, events: [noteOn(69)])
    #expect(level(forward[...]) < -90, "Starts with the silence")

    let trimmed = try playMIDI(try await sampler(playing: audio, [.root: 69, .start: 50]), seconds: 0.4, events: [noteOn(69)])
    #expect(level(trimmed[Int(0.05 * rate)...]) > -15, "Starting half way in skips the silence")

    let reversed = try playMIDI(try await sampler(playing: audio, [.root: 69, .reverse: 1]), seconds: 0.4, events: [noteOn(69)])
    #expect(level(reversed[Int(0.05 * rate)...]) > -15, "Backwards, the tone comes first")
  }

  @Test func presetsLeaveTheSampleSettingsAlone() async throws {
    let unit = try await sampler(playing: sine(440, seconds: 1), [.start: 30, .end: 70, .root: 69, .ampAttack: 500])
    let tree = try #require(unit.au.parameterTree)
    unit.au.currentPreset = try #require(unit.au.factoryPresets?.first { $0.name == "One Shot" })
    #expect(tree.parameter(withAddress: OngakuSamplerParameter.start.rawValue)?.value == 30)
    #expect(tree.parameter(withAddress: OngakuSamplerParameter.end.rawValue)?.value == 70)
    #expect(tree.parameter(withAddress: OngakuSamplerParameter.root.rawValue)?.value == 69)
    #expect(tree.parameter(withAddress: OngakuSamplerParameter.playMode.rawValue)?.value == 1)
    #expect(tree.parameter(withAddress: OngakuSamplerParameter.ampAttack.rawValue)?.value == 1, "Its own settings are set")
  }
}

// MARK: - Dynamics, colour and the vocal strip

extension OngakuEffectsTests {
  /// The level in dB (RMS) of part of a render.
  private func rms(_ samples: ArraySlice<Float>) -> Double {
    level(samples)
  }

  /// A sine's level at one frequency (Goertzel), in dB relative to full scale.
  private func toneLevel(_ samples: ArraySlice<Float>, frequency: Double) -> Double {
    let omega = 2 * .pi * frequency / rate
    var s1 = 0.0, s2 = 0.0
    for sample in samples {
      let s = Double(sample) + 2 * cos(omega) * s1 - s2
      s2 = s1
      s1 = s
    }
    let power = s1 * s1 + s2 * s2 - 2 * cos(omega) * s1 * s2
    return 10 * log10(max(power, 1e-24)) - 20 * log10(Double(samples.count) / 2)
  }

  @Test func theNewEffectsAreInstalled() throws {
    for effect in [
      OngakuEffect.noiseGate, .transientShaper, .maximizer, .deEsser, .saturation, .doubler, .convolutionReverb, .vocalStrip,
      .mastering,
    ] {
      let components = AVAudioUnitComponentManager.shared().components(matching: description(effect))
      #expect(components.first?.name == effect.name, "\(effect.name) is installed")
    }
  }

  @Test func theGateSilencesWhatsBelowItsThreshold() async throws {
    let unit = try await load(.noiseGate)
    try set(unit, [700: -30])
    let quiet = try render(unit, frequency: 440, amplitude: 0.003, blocks: 12).left
    #expect(rms(quiet[(6 * 4_096)...]) < -100, "Noise at −50 dB is gated")
    let loud = try render(unit, frequency: 440, amplitude: 0.3, blocks: 12).left
    #expect(abs(rms(loud[(6 * 4_096)...]) - rms(ArraySlice((0..<8_192).map { Float(0.3 * sin(2 * .pi * 440 * Double($0) / rate)) }))) < 0.5,
      "A note at −10 dB passes untouched")
  }

  @Test func theTransientShaperShapesAttackAndSustain() async throws {
    // A hit every quarter second: an instant rise, then a 150 ms decay.
    let hits: @Sendable (Int) -> Float = { frame in
      let t = Double(frame % 12_000) / 48_000
      return Float(0.5 * sin(2 * .pi * 180 * t) * exp(-t / 0.15))
    }
    func shape(_ attack: AUValue, _ sustain: AUValue) async throws -> (onset: Double, tail: Double) {
      let unit = try await load(.transientShaper)
      try set(unit, [800: attack, 801: sustain])
      let out = try render(unit, blocks: 12, signal: hits).left
      // The fourth hit, settled: its first 5 ms, and 100–200 ms in.
      let start = 3 * 12_000
      return (rms(out[start..<(start + 240)]), rms(out[(start + 4_800)..<(start + 9_600)]))
    }
    let neutral = try await shape(0, 0)
    let punchy = try await shape(100, 0)
    let tight = try await shape(0, -100)
    #expect(punchy.onset > neutral.onset + 2, "More attack: \(punchy.onset) against \(neutral.onset)")
    #expect(tight.tail < neutral.tail - 4, "Less sustain: \(tight.tail) against \(neutral.tail)")
  }

  @Test func theMaximizerHoldsItsCeilingAndReportsItsLookAhead() async throws {
    let unit = try await load(.maximizer)
    try set(unit, [900: 12, 901: -1])
    #expect(abs(unit.au.latency - 0.002) < 0.0001, "2 ms of look-ahead")
    let out = try render(unit, frequency: 220, amplitude: 0.9, blocks: 8).left
    let peak = out.map { abs($0) }.max() ?? 0
    #expect(peak <= pow(10, -1 / 20) + 0.001, "Nothing over −1 dBFS (peak \(20 * log10(peak)) dB)")
    #expect(rms(out[(4 * 4_096)...]) > -6, "And it's loud")
  }

  @Test func theDeEsserTurnsDownOnlyTheSibilance() async throws {
    let unit = try await load(.deEsser)
    try set(unit, [1000: 6_000, 1001: -30, 1002: 12])
    let ess = try gain(of: unit, at: 8_000, amplitude: 0.3)
    #expect(ess < -4, "An 8 kHz tone is turned down (\(ess) dB)")
    let voice = try gain(of: unit, at: 300, amplitude: 0.3)
    #expect(abs(voice) < 0.5, "A 300 Hz tone isn't (\(voice) dB)")
  }

  @Test func saturationAddsHarmonicsAsItsDriven() async throws {
    func thirdHarmonic(drive: AUValue, type: AUValue) async throws -> (harmonic: Double, level: Double) {
      let unit = try await load(.saturation)
      try set(unit, [1100: drive, 1101: type, 1102: 0])
      let out = try render(unit, frequency: 200, amplitude: 0.25, blocks: 8).left[(4 * 4_096)...]
      return (toneLevel(out, frequency: 600) - toneLevel(out, frequency: 200), rms(out))
    }
    let clean = try await thirdHarmonic(drive: 0, type: 2)
    let driven = try await thirdHarmonic(drive: 24, type: 2)
    #expect(driven.harmonic > clean.harmonic + 15, "Driving it adds harmonics (\(driven.harmonic) against \(clean.harmonic) dB)")
    #expect(abs(driven.level - clean.level) < 6, "At about the same level")
    for type: AUValue in [0, 1] {
      let colour = try await thirdHarmonic(drive: 20, type: type)
      #expect(colour.harmonic > -50, "Type \(type) adds harmonics too")
    }
  }

  @Test func theDoublerSpreadsOnePartIntoTwo() async throws {
    let unit = try await load(.doubler)
    let out = try render(unit, frequency: 330, amplitude: 0.3, blocks: 10)
    let left = out.left[(5 * 4_096)...], right = out.right[(5 * 4_096)...]
    let difference = zip(left, right).map { $0 - $1 }
    #expect(rms(difference[...]) > -30, "The two sides differ: the copies are spread")
    #expect(rms(left) > -20 && rms(left) < -2, "At a sensible level (\(rms(left)) dB)")
  }

  @Test func theConvolutionReverbRingsAndReportsItsBlock() async throws {
    let unit = try await load(.convolutionReverb)
    // Dry only: the input, a block late.
    try set(unit, [1307: 0, 1300: 0])
    let click: @Sendable (Int) -> Float = { $0 == 1_000 ? 1 : 0 }
    let dry = try render(unit, blocks: 2, signal: click).left
    #expect(dry.firstIndex { abs($0) > 0.5 } == 1_256)
    #expect(abs(unit.au.latency - 256 / rate) < 0.0001, "It reports the block as latency")

    // All reverb, a one-second decay: loud early on, about 50 dB down a second later.
    let reverb = try await load(.convolutionReverb)
    try set(reverb, [1307: 100, 1300: 0, 1301: 1, 1305: 20, 1306: 20_000])
    let wet = try render(reverb, blocks: 16, signal: click).left
    let early = rms(wet[(1_256 + 2_400)..<(1_256 + 12_000)])
    let late = rms(wet[(1_256 + 48_000)..<(1_256 + 57_600)])
    #expect(early > -60, "The reverb is heard (\(early) dB)")
    #expect(early - late > 35, "And dies away over its decay (\(early) then \(late) dB)")
  }

  @Test func theVocalStripCutsLowsAndAddsPresence() async throws {
    let unit = try await load(.vocalStrip)
    try set(unit, [1400: 150, 1401: 0, 1402: 0, 1403: 0, 1404: 0, 1405: 0])
    #expect(try gain(of: unit, at: 40) < -10, "Rumble at 40 Hz is cut")
    try set(unit, [1400: 20, 1404: 100])
    #expect(try gain(of: unit, at: 4_500) > 6, "Presence lifts 4.5 kHz")
    #expect(abs(try gain(of: unit, at: 300)) < 1, "And leaves the body alone")
  }
}

// MARK: - Presets and state

extension OngakuEffectsTests {
  /// Every effect and instrument, as a host loads it.
  private var everyPlugin: [AudioComponentDescription] {
    OngakuEffect.allCases.map(description) + OngakuInstrument.allCases.map { instrument in
      let reference = instrument.makeReference()
      return AudioComponentDescription(
        componentType: reference.componentType, componentSubType: reference.componentSubType,
        componentManufacturer: reference.componentManufacturer, componentFlags: 0, componentFlagsMask: 0)
    }
  }

  /// Moves every parameter part of the way along its range, so nothing is left at its default.
  private func moveEveryParameter(of unit: AUAudioUnit) throws -> [AUParameterAddress: AUValue] {
    let tree = try #require(unit.parameterTree)
    var values: [AUParameterAddress: AUValue] = [:]
    for (index, parameter) in tree.allParameters.enumerated() {
      let fraction = AUValue(0.2 + 0.6 * Double(index % 5) / 4)
      var value = parameter.minValue + (parameter.maxValue - parameter.minValue) * fraction
      if parameter.unit == .indexed || parameter.unit == .boolean { value = value.rounded() }
      parameter.value = value
      values[parameter.address] = parameter.value
    }
    return values
  }

  @Test func everyPluginRestoresItsSettings() async throws {
    for description in everyPlugin {
      let first = try await AVAudioUnit.instantiate(with: description, options: [.loadOutOfProcess])
      let values = try moveEveryParameter(of: first.au)
      let state = try #require(first.au.fullState)
      let second = try await AVAudioUnit.instantiate(with: description, options: [.loadOutOfProcess])
      second.au.fullState = state
      let tree = try #require(second.au.parameterTree)
      for (address, value) in values {
        let restored = try #require(tree.parameter(withAddress: address)).value
        #expect(abs(restored - value) <= max(abs(value), 1) * 1e-4,
          "\(first.au.audioUnitName ?? "?") parameter \(address): \(restored) instead of \(value)")
      }
    }
  }

  @Test func userPresetsAreSavedChosenAndDeleted() async throws {
    let unit = try await load(.compressor).au
    #expect(unit.supportsUserPresets)
    for old in unit.userPresets where old.name.hasPrefix("Test Preset") { try unit.deleteUserPreset(old) }
    let values = try moveEveryParameter(of: unit)
    let preset = AUAudioUnitPreset()
    preset.name = "Test Preset \(UUID().uuidString.prefix(6))"
    preset.number = -1 - Int.random(in: 0..<10_000)
    try unit.saveUserPreset(preset)
    // Out of process, the list catches up a moment later.
    #expect(await waitFor { unit.userPresets.contains { $0.name == preset.name } })

    // Change everything, then choose the preset: its settings come back.
    let tree = try #require(unit.parameterTree)
    for parameter in tree.allParameters { parameter.value = parameter.minValue }
    let saved = try #require(unit.userPresets.first { $0.name == preset.name })
    unit.currentPreset = saved
    for (address, value) in values {
      let restored = try #require(tree.parameter(withAddress: address)).value
      #expect(abs(restored - value) <= max(abs(value), 1) * 1e-4, "Parameter \(address)")
    }

    try unit.deleteUserPreset(try #require(unit.userPresets.first { $0.name == preset.name }))
    #expect(await waitFor { !unit.userPresets.contains { $0.name == preset.name } })
  }

  /// Waits up to three seconds for something to become true.
  private func waitFor(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<60 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
  }
}

// MARK: - Session Drummer

/// A host's song position for the Session Drummer: 120 BPM in 4/4, moving on as blocks
/// are rendered (or standing still).
private final class FakeHostClock: @unchecked Sendable {
  var beat = 0.0
  var isPlaying = true
  let tempo = 120.0
  /// Like a host that updates its position from a screen timer: the beat it reports only
  /// moves every few blocks, and a little off.
  var updatesEvery = 1
  /// Whether the host reports its transport (the coarse-host test turns it off).
  var keepsTransport = true
  private(set) var reportedBeat = 0.0
  private var blocks = 0

  func advance(by beats: Double) {
    beat += beats
    blocks += 1
    if blocks % updatesEvery == 0 { reportedBeat = beat + (blocks % 2 == 0 ? 0.004 : -0.004) * Double(updatesEvery - 1) }
  }

  var musicalContext: AUHostMusicalContextBlock {
    { [self] tempo, numerator, denominator, beat, offset, downbeat in
      tempo?.pointee = self.tempo
      numerator?.pointee = 4
      denominator?.pointee = 4
      beat?.pointee = self.updatesEvery == 1 ? self.beat : self.reportedBeat
      offset?.pointee = 0
      downbeat?.pointee = (self.beat / 4).rounded(.down) * 4
      return true
    }
  }

  var transport: AUHostTransportStateBlock {
    { [self] flags, _, _, _ in
      flags?.pointee = self.isPlaying ? [.changed, .moving] : []
      return true
    }
  }
}

/// MIDI the plug-in sends out: (sample time, bytes).
private final class MIDICollector: @unchecked Sendable {
  private let lock = NSLock()
  private var collected: [(time: AUEventSampleTime, bytes: [UInt8])] = []

  var block: AUMIDIOutputEventBlock {
    { [self] time, _, length, bytes in
      lock.lock()
      collected.append((time, Array(UnsafeBufferPointer(start: bytes, count: length))))
      lock.unlock()
      return noErr
    }
  }

  var noteOns: [(time: AUEventSampleTime, note: UInt8, velocity: UInt8)] {
    lock.lock()
    defer { lock.unlock() }
    return collected.filter { $0.bytes.count == 3 && $0.bytes[0] & 0xF0 == 0x90 && $0.bytes[2] > 0 }
      .map { ($0.time, $0.bytes[1], $0.bytes[2]) }
  }
}

extension OngakuEffectsTests {
  /// Renders the drummer for `seconds`, moving the host's clock on block by block.
  /// (The engine takes the unit's MIDI output and host blocks away when it lets go of it, so
  /// they're given again each time.)
  private func renderDrummer(_ unit: AVAudioUnit, clock: FakeHostClock, midi: MIDICollector, seconds: Double) throws
    -> [Float]
  {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    engine.attach(unit)
    unit.au.midiOutputEventBlock = midi.block
    unit.au.musicalContextBlock = clock.musicalContext
    if unit.au.transportStateBlock != nil || clock.keepsTransport {
      unit.au.transportStateBlock = clock.transport
    }
    try engine.connectNode(unit, to: engine.mainMixerNode, format: format)
    try engine.start()
    defer {
      engine.stop()
      engine.detach(unit)
    }
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
    var samples: [Float] = []
    let total = Int(seconds * rate)
    while samples.count < total {
      _ = try engine.renderOffline(512, to: buffer)
      samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
      if clock.isPlaying { clock.advance(by: 512 / rate * clock.tempo / 60) }
    }
    return Array(samples.prefix(total))
  }

  private func drummer(song: DrummerSong, clock: FakeHostClock, midi: MIDICollector) async throws -> AVAudioUnit {
    let unit = try await loadInstrument(.sessionDrummer)
    var state = unit.au.fullState ?? [:]
    state["ongakuDrummerSong"] = try JSONEncoder().encode(song)
    unit.au.fullState = state
    unit.au.musicalContextBlock = clock.musicalContext
    unit.au.transportStateBlock = clock.transport
    unit.au.midiOutputEventBlock = midi.block
    // The part is laid out off the render thread.
    try await Task.sleep(for: .milliseconds(200))
    return unit
  }

  @Test func theSessionDrummerPlaysItsPartInTimeWithTheHost() async throws {
    var song = DrummerSong.starter(style: .rock, layout: [("Verse", 2)])
    song.sections[0].performance.fills = 0
    let clock = FakeHostClock(), midi = MIDICollector()
    let unit = try await drummer(song: song, clock: clock, midi: midi)
    #expect(unit.au.midiOutputNames == ["Drums"])
    let samples = try renderDrummer(unit, clock: clock, midi: midi, seconds: 2)

    // Every hit of the first bar (2 s at 120 BPM), sent as MIDI at its own sample.
    let expected = song.notes(in: .fourFour).filter { $0.start < Tick(3840) }
    // Blocks of 512 run a little past the bar; only its hits count.
    let sent = midi.noteOns.filter { $0.time < AUEventSampleTime(2 * rate) }
    #expect(sent.count == expected.count, "\(sent.count) hits sent, \(expected.count) in the part")
    for note in expected {
      let frame = note.start.quarterNotes * rate / 2
      #expect(sent.contains { Int($0.note) == note.pitch && abs(Double($0.time) - frame) <= 2 },
        "Note \(note.pitch) at beat \(note.start.quarterNotes)")
    }
    #expect(sent.first?.time == 0 && sent.contains { $0.note == 36 && $0.time == 0 }, "The kick on the downbeat")
    // And its own kit plays them.
    #expect(samples[0..<2_400].map(abs).max() ?? 0 > 0.05, "The kick sounds at once")
  }

  @Test func theSessionDrummerKeepsTimeWithACoarseHost() async throws {
    var song = DrummerSong.starter(style: .rock, layout: [("Verse", 2)])
    song.sections[0].performance.fills = 0
    let clock = FakeHostClock(), midi = MIDICollector()
    clock.updatesEvery = 3
    let unit = try await drummer(song: song, clock: clock, midi: midi)
    // No transport block: it tells the song is playing from the beat moving on.
    clock.keepsTransport = false
    unit.au.transportStateBlock = nil
    _ = try renderDrummer(unit, clock: clock, midi: midi, seconds: 4)
    let expected = song.notes(in: .fourFour)
    // Up to just before the repeat's downbeat (it may land a sample early).
    let sent = midi.noteOns.filter { $0.time < AUEventSampleTime(4 * rate) - 200 }
    #expect(sent.count == expected.count,
      "Every hit once: \(sent.count) sent, \(expected.count) in the part: \(sent.map { "\($0.note)@\($0.time)" })")
    for note in expected {
      let frame = note.start.quarterNotes * rate / 2
      #expect(sent.contains { Int($0.note) == note.pitch && abs(Double($0.time) - frame) <= 1_536 },
        "Note \(note.pitch) at beat \(note.start.quarterNotes), within a few blocks")
    }
  }

  @Test func theSessionDrummerRepeatsItsSongAndPreviewsWhenTheHostIsStopped() async throws {
    let song = DrummerSong.starter(style: .electronic, layout: [("Verse", 1)])
    let clock = FakeHostClock(), midi = MIDICollector()
    // Start in the song's third bar: it repeats, so that's its first bar again.
    clock.beat = 8
    let unit = try await drummer(song: song, clock: clock, midi: midi)
    _ = try renderDrummer(unit, clock: clock, midi: midi, seconds: 0.25)
    #expect(midi.noteOns.contains { $0.note == 36 && $0.time == 0 }, "Bar 3 is bar 1 again")

    // Stopped: silent, until Preview is on.
    clock.isPlaying = false
    let stoppedMIDI = MIDICollector()
    let silent = try renderDrummer(unit, clock: clock, midi: stoppedMIDI, seconds: 0.5)
    #expect(stoppedMIDI.noteOns.isEmpty && (silent.map(abs).max() ?? 0) < 0.3)
    try set(unit, [AUParameterAddress(1503): 1])
    _ = try renderDrummer(unit, clock: clock, midi: stoppedMIDI, seconds: 1)
    #expect(stoppedMIDI.noteOns.filter { $0.note == 36 }.count >= 2,
      "Preview plays four on the floor: \(stoppedMIDI.noteOns.map { "\($0.note)@\($0.time)" })")
  }

  @Test func theSessionDrummerPlaysApplesKitsToo() async throws {
    var song = DrummerSong.starter(style: .rock, layout: [("Verse", 1)])
    song.sections[0].performance.fills = 0
    let clock = FakeHostClock(), midi = MIDICollector()
    let unit = try await drummer(song: song, clock: clock, midi: midi)
    let ownKit = try renderDrummer(unit, clock: clock, midi: midi, seconds: 0.25)
    // Apple's Standard Kit (loaded before the engine renders).
    try set(unit, [AUParameterAddress(1504): 1])
    clock.beat = 0
    let appleKit = try renderDrummer(unit, clock: clock, midi: midi, seconds: 0.25)
    #expect((appleKit.map(abs).max() ?? 0) > 0.02, "Apple's kit sounds")
    let difference = zip(ownKit, appleKit).map { abs($0 - $1) }.max() ?? 0
    #expect(difference > 0.02, "And it isn't the Drum Machine")
  }

  @Test func theSessionDrummerSavesItsSong() async throws {
    let song = DrummerSong.starter(style: .funk, layout: [("Intro", 4), ("Chorus", 8)])
    let clock = FakeHostClock(), midi = MIDICollector()
    let unit = try await drummer(song: song, clock: clock, midi: midi)
    let state = try #require(unit.au.fullState)
    let saved = try #require(state["ongakuDrummerSong"] as? Data)
    #expect(try JSONDecoder().decode(DrummerSong.self, from: saved) == song)
  }
}

// MARK: - Mastering

/// A stereo signal, a pair of samples per frame number, rendered on the audio thread.
private final class StereoSignalSource: @unchecked Sendable {
  private let signal: @Sendable (Int) -> (Float, Float)
  private var frame = 0

  init(_ signal: @escaping @Sendable (Int) -> (Float, Float)) {
    self.signal = signal
  }

  func render(frameCount: Int, into data: UnsafeMutablePointer<AudioBufferList>) {
    let buffers = UnsafeMutableAudioBufferListPointer(data)
    for index in 0..<frameCount {
      let (left, right) = signal(frame + index)
      buffers[0].mData?.assumingMemoryBound(to: Float.self)[index] = left
      if buffers.count > 1 { buffers[1].mData?.assumingMemoryBound(to: Float.self)[index] = right }
    }
    frame += frameCount
  }
}

/// A song-like test signal: pink noise (partly different in each side) and a bass line,
/// pulsing on the beat at 120 BPM, scaled to a known integrated loudness.
private struct TestSong: Sendable {
  let left: [Float], right: [Float]
  let loudness: Double

  init(seconds: Double, loudness target: Double, rate: Double) {
    let count = Int(seconds * rate)
    var seed: UInt32 = 0x1234_5678
    func white() -> Float {
      seed = seed &* 1_664_525 &+ 1_013_904_223
      return Float(seed >> 8) / Float(1 << 24) * 2 - 1
    }
    // Paul Kellet's pink filter, one per noise.
    var shared = [Float](repeating: 0, count: 7), spread = [Float](repeating: 0, count: 7)
    func pink(_ b: inout [Float], _ white: Float) -> Float {
      b[0] = 0.99886 * b[0] + white * 0.0555179
      b[1] = 0.99332 * b[1] + white * 0.0750759
      b[2] = 0.96900 * b[2] + white * 0.1538520
      b[3] = 0.86650 * b[3] + white * 0.3104856
      b[4] = 0.55000 * b[4] + white * 0.5329522
      b[5] = -0.7616 * b[5] - white * 0.0168980
      let sum = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362
      b[6] = white * 0.115926
      return sum * 0.11
    }
    var left = [Float](repeating: 0, count: count), right = [Float](repeating: 0, count: count)
    for frame in 0..<count {
      let t = Double(frame) / rate
      let beat = t.truncatingRemainder(dividingBy: 0.5)
      let pulse = Float(0.55 + 0.45 * exp(-beat / 0.09))
      let bass = Float(0.35 * sin(2 * .pi * 55 * t) * exp(-beat / 0.3))
      let middle = pink(&shared, white()), side = pink(&spread, white())
      left[frame] = (middle + 0.4 * side) * pulse + bass
      right[frame] = (middle - 0.4 * side) * pulse + bass
    }
    let scale = Float(pow(10, (target - MasteringMeasure.integratedLoudness(left[...], right[...], rate: rate)) / 20))
    self.left = left.map { $0 * scale }
    self.right = right.map { $0 * scale }
    loudness = MasteringMeasure.integratedLoudness(self.left[...], self.right[...], rate: rate)
  }

  func signal() -> @Sendable (Int) -> (Float, Float) {
    let (left, right) = (left, right)
    return { frame in frame < left.count ? (left[frame], right[frame]) : (0, 0) }
  }
}

/// Reference measurements, independent of the plug-in's own: loudness by ITU-R BS.1770-4
/// and the true peak at four times the rate.
private enum MasteringMeasure {
  /// The gated integrated loudness of a stereo signal at 48 kHz (LUFS).
  static func integratedLoudness(_ left: ArraySlice<Float>, _ right: ArraySlice<Float>, rate: Double) -> Double {
    precondition(rate == 48_000, "The K-weighting coefficients here are for 48 kHz")
    func weighted(_ samples: ArraySlice<Float>) -> [Double] {
      // The head's shelf, then the high-pass, as BS.1770 gives them at 48 kHz.
      let stages: [([Double], [Double])] = [
        ([1.53512485958697, -2.69169618940638, 1.19839281085285], [-1.69065929318241, 0.73248077421585]),
        ([1, -2, 1], [-1.99004745483398, 0.99007225036621]),
      ]
      var signal = samples.map(Double.init)
      for (b, a) in stages {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for index in signal.indices {
          let x = signal[index]
          let y = b[0] * x + b[1] * x1 + b[2] * x2 - a[0] * y1 - a[1] * y2
          (x2, x1, y2, y1) = (x1, x, y1, y)
          signal[index] = y
        }
      }
      return signal
    }
    let l = weighted(left), r = weighted(right)
    let block = Int(0.4 * rate), step = Int(0.1 * rate)
    var powers: [Double] = []
    var start = 0
    while start + block <= l.count {
      var sum = 0.0
      for index in start..<(start + block) { sum += l[index] * l[index] + r[index] * r[index] }
      powers.append(sum / Double(block))
      start += step
    }
    func lufs(_ power: Double) -> Double { -0.691 + 10 * log10(max(power, 1e-20)) }
    let absolute = powers.filter { lufs($0) > -70 }
    guard !absolute.isEmpty else { return -120 }
    let relative = lufs(absolute.reduce(0, +) / Double(absolute.count)) - 10
    let gated = absolute.filter { lufs($0) > relative }
    return lufs(gated.reduce(0, +) / Double(gated.count))
  }

  /// The highest peak of the waveform between the samples too: each point between found by
  /// a 64-tap Kaiser-windowed sinc (much longer than the plug-in's detector), in dBTP.
  static func truePeak(_ samples: [Float]) -> Double {
    let half = 32
    var highest = samples.map(abs).max() ?? 0
    func bessel(_ x: Double) -> Double {
      var sum = 1.0, term = 1.0
      for k in 1..<40 {
        term *= (x / Double(2 * k)) * (x / Double(2 * k))
        sum += term
      }
      return sum
    }
    for phase in 1..<4 {
      let fraction = Double(phase) / 4
      // result[i] = Σ samples[i + k] · taps[k]: the point `fraction` after sample i + half − 1.
      let taps = (0..<(2 * half)).map { k -> Float in
        let offset = fraction + Double(half - 1 - k)
        let sinc = sin(.pi * offset) / (.pi * offset)
        let position = offset / Double(half)
        return Float(sinc * bessel(9 * (1 - min(1, position * position)).squareRoot()) / bessel(9))
      }
      let count = samples.count - taps.count + 1
      guard count > 0 else { continue }
      var result = [Float](repeating: 0, count: count)
      vDSP_conv(samples, 1, taps, 1, &result, 1, vDSP_Length(count), vDSP_Length(taps.count))
      highest = max(highest, result.map(abs).max() ?? 0)
    }
    return 20 * log10(max(Double(highest), 1e-12))
  }
}

extension OngakuEffectsTests {
  /// Mastering's parameter addresses (the extension's `OngakuEffectsParameterAddresses.h`).
  private enum Address: AUParameterAddress {
    case mstCharacter = 1600, mstLoudness, mstCompare, mstEQAmount, mstDynamics, mstWidth, mstLowEndMono, mstCeiling
    case mstLowShelf = 1610, mstLowMid, mstPresence, mstAir, mstHighShelf
    case mstThreshold = 1620, mstRatio
    case mstMeasuredLoudness = 1640
    case mstListen = 1650
  }

  /// Mastering, with the given settings by address.
  private func mastering(_ values: [Address: AUValue] = [:]) async throws -> AVAudioUnit {
    let unit = try await load(.mastering)
    try set(unit, Dictionary(uniqueKeysWithValues: values.map { ($0.rawValue, $1) }))
    return unit
  }

  /// Renders a stereo signal through the unit for `blocks` blocks of 4,096 samples, calling
  /// `beforeBlock` with each block's number first (to change settings as it plays).
  private func renderStereo(
    _ unit: AVAudioUnit, blocks: Int, signal: @escaping @Sendable (Int) -> (Float, Float),
    beforeBlock: (Int) throws -> Void = { _ in }
  ) throws -> (left: [Float], right: [Float]) {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
    let generator = StereoSignalSource(signal)
    let source = AVAudioSourceNode(format: format) { _, _, frameCount, data in
      generator.render(frameCount: Int(frameCount), into: data)
      return noErr
    }
    engine.attach(source)
    engine.attach(unit)
    try engine.connectNode(source, to: unit, format: format)
    try engine.connectNode(unit, to: engine.mainMixerNode, format: format)
    try engine.start()
    defer {
      engine.stop()
      engine.detach(unit)
    }
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
    var left: [Float] = [], right: [Float] = []
    for block in 0..<blocks {
      try beforeBlock(block)
      _ = try engine.renderOffline(4_096, to: buffer)
      left += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
      right += UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength))
    }
    return (left, right)
  }

  private func blocks(seconds: Double) -> Int { Int((seconds * rate / 4_096).rounded(.up)) }

  /// The plug-in's latency in samples, as it reports it.
  private func latencySamples(_ unit: AVAudioUnit) -> Int { Int((unit.au.latency * rate).rounded()) }

  @Test func masteringReachesTheLoudnessItsAskedFor() async throws {
    let song = TestSong(seconds: 20, loudness: -20, rate: rate)
    #expect(abs(song.loudness + 20) < 0.05)
    let unit = try await mastering([.mstMeasuredLoudness: AUValue(song.loudness), .mstLoudness: -14])
    let out = try renderStereo(unit, blocks: blocks(seconds: 20), signal: song.signal())
    // Once it's learned what the chain does (two seconds) and the make-up has settled.
    let settled = 6 * Int(rate)..<(20 * Int(rate))
    let loudness = MasteringMeasure.integratedLoudness(out.left[settled], out.right[settled], rate: rate)
    print("Mastering: −20 LUFS in, \(loudness) LUFS out (asked for −14)")
    #expect(abs(loudness + 14) <= 0.7, "Output \(loudness) LUFS for −14")

    // Not measured yet: nothing is turned up.
    let unmeasured = try await mastering()
    let quiet = try renderStereo(unmeasured, blocks: blocks(seconds: 8), signal: song.signal())
    let range = 3 * Int(rate)..<(8 * Int(rate))
    let level = MasteringMeasure.integratedLoudness(quiet.left[range], quiet.right[range], rate: rate)
    #expect(level < -19, "Unmeasured, it stays about as loud as it came in (\(level) LUFS)")
  }

  /// Presets are destinations: they set the loudness and ceiling, and leave the character
  /// (chosen in the window) and the listen's settings for the song alone.
  @Test func masteringPresetsSetOnlyHowLoud() async throws {
    let unit = try await mastering([.mstCharacter: 2, .mstLowShelf: -1.5, .mstMeasuredLoudness: -19])
    let presets = try #require(unit.au.factoryPresets)
    #expect(presets.map(\.name) == ["Streaming", "Gentle", "Loud", "Club / CD"])
    unit.au.currentPreset = presets[3]
    let tree = try #require(unit.au.parameterTree)
    func value(_ address: Address) -> AUValue? { tree.parameter(withAddress: address.rawValue)?.value }
    #expect(value(.mstLoudness) == -8)
    #expect(abs((value(.mstCeiling) ?? 0) + 0.3) < 0.001)
    #expect(value(.mstCharacter) == 2)
    #expect(value(.mstLowShelf) == -1.5)
    #expect(value(.mstMeasuredLoudness) == -19)
  }

  @Test(arguments: [AUValue(-1), -0.3])
  func masteringHoldsTheTruePeakUnderTheCeiling(ceiling: AUValue) async throws {
    let song = TestSong(seconds: 10, loudness: -20, rate: rate)
    // Pushed hard: 12 dB of make-up into the limiter.
    let unit = try await mastering([.mstMeasuredLoudness: AUValue(song.loudness), .mstLoudness: -8, .mstCeiling: ceiling])
    let out = try renderStereo(unit, blocks: blocks(seconds: 10), signal: song.signal())
    let peak = max(MasteringMeasure.truePeak(out.left), MasteringMeasure.truePeak(out.right))
    print("Mastering: true peak \(peak) dBTP under a \(ceiling) dBTP ceiling (margin \(Double(ceiling) - peak) dB)")
    #expect(peak <= Double(ceiling), "True peak \(peak) dBTP over the \(ceiling) dBTP ceiling")
    let loudness = MasteringMeasure.integratedLoudness(out.left[(4 * Int(rate))...], out.right[(4 * Int(rate))...], rate: rate)
    #expect(loudness > -10.5, "And it's loud (\(loudness) LUFS)")
  }

  @Test func masteringReportsItsTrueLatencyWhateverTheCharacter() async throws {
    for character in 0..<4 {
      let unit = try await mastering([.mstCharacter: AUValue(character)])
      let click: @Sendable (Int) -> (Float, Float) = { $0 == 10_000 ? (0.5, 0.5) : (0, 0) }
      let out = try renderStereo(unit, blocks: 4, signal: click).left
      // Read once it's running at the test's rate: before, it reports its default rate's.
      let latency = latencySamples(unit)
      #expect(latency == 48 + 24 + 96, "Oversampling, the detector's filter and 2 ms of look-ahead")
      let loudest = out.indices.max { abs(out[$0]) < abs(out[$1]) }
      #expect(loudest == 10_000 + latency, "Character \(character): the click comes out \(latency) samples late")
    }
  }

  @Test func compareIsTheInputInTimeAndAtTheSameLoudness() async throws {
    let song = TestSong(seconds: 14, loudness: -20, rate: rate)
    let settings: [Address: AUValue] = [.mstMeasuredLoudness: AUValue(song.loudness), .mstLoudness: -14, .mstPresence: 4]
    let processed = try renderStereo(try await mastering(settings), blocks: blocks(seconds: 14), signal: song.signal())
    var comparing = settings
    comparing[.mstCompare] = 1
    let unit = try await mastering(comparing)
    let compared = try renderStereo(unit, blocks: blocks(seconds: 14), signal: song.signal())
    let latency = latencySamples(unit)

    // The input, delayed by exactly the latency and turned up: the best gain leaves almost nothing.
    let window = (12 * Int(rate))..<(13 * Int(rate))
    let input = window.map { song.left[$0 - latency] }, output = window.map { compared.left[$0] }
    let gain = zip(input, output).map { Double($0) * Double($1) }.reduce(0, +) / input.map { Double($0) * Double($0) }.reduce(0, +)
    let residual = zip(input, output).map { Double($1) - gain * Double($0) }
    #expect(level(ArraySlice(residual.map(Float.init))) - level(ArraySlice(output)) < -40, "Compare plays the input, \(latency) samples late")
    #expect(gain > 1.5, "Turned up to the master's loudness (×\(gain))")

    let settled = (6 * Int(rate))..<(14 * Int(rate))
    let master = MasteringMeasure.integratedLoudness(processed.left[settled], processed.right[settled], rate: rate)
    let original = MasteringMeasure.integratedLoudness(compared.left[settled], compared.right[settled], rate: rate)
    print("Mastering: processed \(master) LUFS, Compare \(original) LUFS")
    #expect(abs(master - original) <= 1, "Compare (\(original) LUFS) is as loud as the master (\(master) LUFS)")
  }

  @Test func theMasteringEQFollowsEQAmountAndCharacter() async throws {
    // Quiet, with no compression and no make-up, so only the EQ acts.
    func presence(_ values: [Address: AUValue]) async throws -> Double {
      var settings: [Address: AUValue] = [.mstDynamics: 0, .mstPresence: 6]
      settings.merge(values) { _, new in new }
      return try gain(of: try await mastering(settings), at: 3_000, amplitude: 0.05)
    }
    let full = try await presence([:])
    let half = try await presence([.mstEQAmount: 50])
    let transparent = try await presence([.mstCharacter: 3])
    let flat = try await presence([.mstEQAmount: 0])
    #expect(abs(full - 6) < 0.3, "+6 dB at 3 kHz (\(full) dB)")
    #expect(abs(half - 3) < 0.3, "Half of it at 50 % (\(half) dB)")
    #expect(abs(transparent - 3) < 0.3, "Transparent halves it (\(transparent) dB)")
    #expect(abs(flat) < 0.2, "None at 0 % (\(flat) dB)")
  }

  @Test func lowEndMonoAndWidthWorkOnTheSide() async throws {
    /// The side's level at a frequency out, against a side-only tone in (dB).
    func side(_ frequency: Double, _ values: [Address: AUValue]) async throws -> Double {
      var settings: [Address: AUValue] = [.mstDynamics: 0]
      settings.merge(values) { _, new in new }
      let step = 2 * .pi * frequency / rate
      let out = try renderStereo(try await mastering(settings), blocks: 12) { frame in
        let sample = Float(0.1 * sin(step * Double(frame)))
        return (sample, -sample)
      }
      let difference = (6 * 4_096..<12 * 4_096).map { (out.left[$0] - out.right[$0]) / 2 }
      return toneLevel(ArraySlice(difference), frequency: frequency) - 20 * log10(0.1)
    }
    let lows = try await side(60, [.mstLowEndMono: 120])
    let highs = try await side(2_000, [.mstLowEndMono: 120])
    let lowsKept = try await side(60, [.mstLowEndMono: 50])
    let wide = try await side(2_000, [.mstWidth: 100])
    let transparentWidth = try await side(2_000, [.mstWidth: 100, .mstCharacter: 3])
    #expect(lows < -20, "A side-only 60 Hz tone is removed below 120 Hz (\(lows) dB)")
    #expect(abs(highs) < 0.5, "A side-only 2 kHz tone passes (\(highs) dB)")
    #expect(abs(lowsKept) < 0.5, "Low-End Mono off keeps the side's lows (\(lowsKept) dB)")
    #expect(abs(wide - 20 * log10(1.5)) < 0.3, "Width 100 % turns the side up by half (\(wide) dB)")
    #expect(abs(transparentWidth) < 0.3, "Transparent doesn't widen (\(transparentWidth) dB)")

    // A mono signal has no side: Width can't change it.
    let song = TestSong(seconds: 3, loudness: -24, rate: rate)
    let mono: @Sendable (Int) -> (Float, Float) = { frame in
      let sample = frame < song.left.count ? song.left[frame] : 0
      return (sample, sample)
    }
    let narrow = try renderStereo(try await mastering([.mstWidth: 0]), blocks: 30, signal: mono)
    let widened = try renderStereo(try await mastering([.mstWidth: 100]), blocks: 30, signal: mono)
    let difference = zip(narrow.left, widened.left).map { abs($0 - $1) }.max() ?? 1
    #expect(difference < 1e-5, "Mono stays the same with Width (largest difference \(difference))")
  }

  /// Listens to `signal` for 20 seconds, as a host would (Listen on, play, Listen off), and
  /// waits for the plug-in to set the song's settings.
  private func listen(_ unit: AVAudioUnit, to signal: @escaping @Sendable (Int) -> (Float, Float)) async throws {
    try set(unit, [Address.mstListen.rawValue: 1])
    _ = try renderStereo(unit, blocks: blocks(seconds: 20), signal: signal)
    try set(unit, [Address.mstListen.rawValue: 0])
    // The plug-in analyses on its own main thread, in its own process.
    let measured = try #require(unit.au.parameterTree?.parameter(withAddress: Address.mstMeasuredLoudness.rawValue))
    for _ in 0..<50 where measured.value <= -69.9 {
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  @Test func listeningSetsTheSongsLoudnessAndSettings() async throws {
    let song = TestSong(seconds: 20, loudness: -20, rate: rate)
    let unit = try await mastering()
    try await listen(unit, to: song.signal())
    let tree = try #require(unit.au.parameterTree)
    let value = { (address: Address) in tree.parameter(withAddress: address.rawValue)?.value ?? .nan }
    print("Mastering listened: \(value(.mstMeasuredLoudness)) LUFS, EQ \(value(.mstLowShelf)) \(value(.mstLowMid)) \(value(.mstPresence)) \(value(.mstAir)) \(value(.mstHighShelf)), ratio \(value(.mstRatio)), threshold \(value(.mstThreshold)), width \(value(.mstWidth))")
    #expect(abs(value(.mstMeasuredLoudness) + 20) < 0.5, "Measured \(value(.mstMeasuredLoudness)) LUFS for a −20 LUFS song")
    #expect(value(.mstListen) == 0, "Listen reads as off again")
    for band in [Address.mstLowShelf, .mstLowMid, .mstPresence, .mstAir, .mstHighShelf] {
      #expect(abs(value(band)) <= 3, "EQ corrections stay gentle")
    }

    // And now it's measured, the master reaches the loudness asked for.
    let out = try renderStereo(unit, blocks: blocks(seconds: 20), signal: song.signal())
    let settled = 6 * Int(rate)..<(20 * Int(rate))
    let loudness = MasteringMeasure.integratedLoudness(out.left[settled], out.right[settled], rate: rate)
    #expect(abs(loudness + 14) <= 0.7, "Output \(loudness) LUFS for −14")
  }

  @Test func aDullSongGetsMoreTopThanABrightOne() async throws {
    // The test song is noise, brighter than a finished master: its top is turned down. The
    // same song through a gentle low-pass (about 4 kHz) is dull, and gets more top.
    let song = TestSong(seconds: 20, loudness: -20, rate: rate)
    let coefficient = Float(1 - exp(-2 * Double.pi * 4_000 / rate))
    var dullLeft = song.left, dullRight = song.right
    for frame in 1..<dullLeft.count {
      dullLeft[frame] = dullLeft[frame - 1] + coefficient * (song.left[frame] - dullLeft[frame - 1])
      dullRight[frame] = dullRight[frame - 1] + coefficient * (song.right[frame] - dullRight[frame - 1])
    }
    let (left, right) = (dullLeft, dullRight)
    let dull: @Sendable (Int) -> (Float, Float) = { $0 < left.count ? (left[$0], right[$0]) : (0, 0) }
    let bright = try await mastering(), darker = try await mastering()
    try await listen(bright, to: song.signal())
    try await listen(darker, to: dull)
    let value = { (unit: AVAudioUnit, address: Address) in unit.au.parameterTree?.parameter(withAddress: address.rawValue)?.value ?? .nan }
    print("Mastering: Air \(value(bright, .mstAir)) / High \(value(bright, .mstHighShelf)) dB bright, Air \(value(darker, .mstAir)) / High \(value(darker, .mstHighShelf)) dB dull")
    #expect(value(bright, .mstHighShelf) < 0, "The bright song's top is turned down")
    #expect(value(darker, .mstHighShelf) > value(bright, .mstHighShelf) + 1, "The dull one gets more top")
    #expect(value(darker, .mstAir) > value(bright, .mstAir) + 1)
  }

  @Test func tooLittleMusicChangesNothing() async throws {
    let unit = try await mastering()
    try set(unit, [Address.mstListen.rawValue: 1])
    _ = try renderStereo(unit, blocks: blocks(seconds: 3), signal: TestSong(seconds: 3, loudness: -20, rate: rate).signal())
    try set(unit, [Address.mstListen.rawValue: 0])
    try await Task.sleep(for: .milliseconds(500))
    let measured = unit.au.parameterTree?.parameter(withAddress: Address.mstMeasuredLoudness.rawValue)?.value
    #expect(measured == -70, "Three seconds isn't enough to go on")
  }

  @Test func compareAndCharacterChangesDontClick() async throws {
    let step = 2 * .pi * 220 / rate
    let tone: @Sendable (Int) -> (Float, Float) = { frame in
      let sample = Float(0.3 * sin(step * Double(frame)))
      return (sample, sample)
    }
    let unit = try await mastering()
    let tree = try #require(unit.au.parameterTree)
    let compare = try #require(tree.parameter(withAddress: Address.mstCompare.rawValue))
    let character = try #require(tree.parameter(withAddress: Address.mstCharacter.rawValue))
    let out = try renderStereo(unit, blocks: 64, signal: tone) { block in
      switch block {
      case 25: compare.value = 1
      case 35: compare.value = 0
      case 40: character.value = 1
      case 45: character.value = 2
      case 50: character.value = 3
      case 53: character.value = 0
      case 55: compare.value = 1
      default: break
      }
    }.left
    // A click is a jump the smooth tone can't make: its second difference stays tiny.
    let steady = 0.3 * step * step
    let jumps = (4_096..<out.count).map { abs(Double(out[$0] - 2 * out[$0 - 1] + out[$0 - 2])) }
    let worst = jumps.max() ?? 0
    print("Mastering: worst second difference \(worst) (a steady tone's is \(steady))")
    #expect(worst < 0.004, "No clicks (worst second difference \(worst))")

    // And Compare took effect: the end is the input, delayed.
    let latency = latencySamples(unit)
    let end = (out.count - 4_096)..<out.count
    let input = end.map { tone($0 - latency).0 }, output = end.map { out[$0] }
    let gain = zip(input, output).map { Double($0) * Double($1) }.reduce(0, +) / input.map { Double($0) * Double($0) }.reduce(0, +)
    let residual = zip(input, output).map { Float(Double($1) - gain * Double($0)) }
    #expect(level(ArraySlice(residual)) - level(ArraySlice(output)) < -40, "Comparing at the end")
  }
}
