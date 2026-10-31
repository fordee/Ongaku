//
//  BounceRenderTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
import Testing

/// Bounces small projects and inspects the files: where sound starts, how long the file is,
/// how loud it is and what format it's in. Bouncing renders offline, so nothing is heard.
@MainActor
@Suite(.serialized)
struct BounceRenderTests {
  private let folder = FileManager.default.temporaryDirectory.appending(path: "BounceRenderTests-\(UUID().uuidString)")

  init() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  /// A quarter-second 1 kHz tone at the given level, starting at full amplitude on frame 0
  /// so its onset is exact.
  private func makeTone(amplitude: Float = 0.5) throws -> (URL, AudioFileReference) {
    let url = folder.appending(path: "Tone \(UUID().uuidString).caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000))
    buffer.frameLength = 12_000
    for channel in 0..<2 {
      for frame in 0..<12_000 {
        buffer.floatChannelData![channel][frame] = amplitude * cos(2 * .pi * 1_000 * Float(frame) / 48_000)
      }
    }
    try file.write(from: buffer)
    return (url, AudioFileReference(fileName: url.lastPathComponent, sampleRate: 48_000, channelCount: 2, frameCount: 12_000))
  }

  /// A project with the tone on an audio track, starting on beat 2 (0.5 s at 120 BPM).
  private func toneProject(amplitude: Float = 0.5, channel: (inout ChannelStrip) -> Void = { _ in }) throws -> (Project, URL) {
    let (url, file) = try makeTone(amplitude: amplitude)
    var track = Track(name: "Tone", kind: .audio, regions: [Region.audio(for: file, at: .quarterNotes(1), tempoMap: TempoMap())])
    channel(&track.channel)
    return (Project(tracks: [track], audioFiles: [file]), url)
  }

  private func bounce(_ project: Project, locate url: URL? = nil, settings: BounceSettings, named name: String = "Bounce") async throws
    -> (BounceResult, URL)
  {
    let output = folder.appending(path: "\(name).\(settings.format.fileExtension)")
    let bouncer = ProjectBouncer(project: project) { _ in url }
    let range = try #require(project.bounceRange)
    return (try await bouncer.bounce(range, settings: settings, to: output), output)
  }

  /// The file's left channel as floats.
  private func samples(of url: URL) throws -> (samples: [Float], format: AVAudioFormat, fileFormat: AVAudioFormat) {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    return (left, file.processingFormat, file.fileFormat)
  }

  private func firstFrame(above threshold: Float, in samples: [Float]) -> Int? {
    samples.firstIndex { abs($0) > threshold }
  }

  // MARK: - Timing and length

  @Test func audioLandsOnTheExactSample() async throws {
    let (project, url) = try toneProject()
    let (result, output) = try await bounce(project, locate: url, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, format, _) = try samples(of: output)
    #expect(format.sampleRate == 48_000)
    #expect(firstFrame(above: 0.01, in: samples) == 24_000, "The region starts 0.5 s in")
    // The project ends where the region does: 0.5 s plus the quarter-second tone.
    #expect(samples.count == 36_000)
    #expect(abs(result.duration - 0.75) < 0.0001)
    #expect(abs(result.peakDecibels - 20 * log10(0.5)) < 0.1, "Unity gain through the channel strip")
    #expect(!result.isClipped)
  }

  // MARK: - Plug-in delay compensation

  /// Two audio tracks playing the tone: A on beat 2 (sample 24 000) through `insertOnA`,
  /// B dry on beat 3 (sample 48 000).
  private func twoTones(insertOnA: BuiltInEffect = .limiter) throws -> (Project, URL, a: Track.ID, b: Track.ID) {
    let (url, file) = try makeTone()
    var a = Track(name: "A", kind: .audio, regions: [Region.audio(for: file, at: .quarterNotes(1), tempoMap: TempoMap())])
    a.channel.inserts = [insertOnA.makeReference()]
    let b = Track(name: "B", kind: .audio, regions: [Region.audio(for: file, at: .quarterNotes(2), tempoMap: TempoMap())])
    return (Project(tracks: [a, b], audioFiles: [file]), url, a.id, b.id)
  }

  /// Where the tone starts after `after`: the first frame loud enough to be it.
  private func onset(in samples: [Float], after start: Int) -> Int? {
    samples.indices.dropFirst(start).first { abs(samples[$0]) > 0.05 }
  }

  /// The limiter looks 2 ms ahead (96 samples): without compensation its track would be
  /// late and the dry track early against it.
  @Test func latentPluginsStayInTimeWithTheRest() async throws {
    let (project, url, _, _) = try twoTones()
    let (_, output) = try await bounce(project, locate: url, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, _, _) = try samples(of: output)
    #expect(onset(in: samples, after: 0) == 24_000, "The limited track starts on beat 2")
    #expect(onset(in: samples, after: 40_000) == 48_000, "The dry track starts on beat 3")
    #expect(samples.count == 60_000, "The file isn't longer for the compensation")
  }

  /// Plug-ins on Stereo Out process the whole mix, and their latency comes off the file's
  /// start like the tracks' does.
  @Test func stereoOutPluginsProcessTheMixInTime() async throws {
    var (project, url, _, _) = try twoTones(insertOnA: .compressor)
    project.tracks[0].channel.inserts = []
    project.stereoOutInserts = [BuiltInEffect.limiter.makeReference()]
    project.masterVolume = -6
    let (_, output) = try await bounce(project, locate: url, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, _, _) = try samples(of: output)
    #expect(onset(in: samples, after: 0) == 24_000, "Beat 2, through the limiter's look-ahead")
    #expect(onset(in: samples, after: 40_000) == 48_000)
    #expect(samples.count == 60_000)
    let peak = samples.map(abs).max() ?? 0
    #expect(abs(peak - 0.5 * 0.501) < 0.01, "The Stereo Out fader comes after its plug-ins (peak \(peak))")
  }

  /// Mastering on Stereo Out reports its oversampling and look-ahead (126 samples), and
  /// the bounce takes them off.
  @Test func masteringOnStereoOutStaysInTime() async throws {
    var (project, url, _, _) = try twoTones()
    project.tracks[0].channel.inserts = []
    project.stereoOutInserts = [OngakuEffect.mastering.makeReference()]
    let (_, output) = try await bounce(project, locate: url, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, _, _) = try samples(of: output)
    #expect(onset(in: samples, after: 0) == 24_000, "Beat 2, through Mastering")
    #expect(onset(in: samples, after: 40_000) == 48_000)
    #expect(samples.count == 60_000)
  }

  /// Analyze Whole Song: Mastering on Stereo Out hears the whole song offline and sets
  /// itself up for it; its settings come back for the song's Mastering.
  @Test func masteringListensToTheWholeSongOffline() async throws {
    let seconds = 20
    let url = folder.appending(path: "Noise \(UUID().uuidString).caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let frames = seconds * 48_000
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    var generator = SystemRandomNumberGenerator()
    for frame in 0..<frames {
      buffer.floatChannelData![0][frame] = Float.random(in: -0.1...0.1, using: &generator)
      buffer.floatChannelData![1][frame] = Float.random(in: -0.1...0.1, using: &generator)
    }
    try file.write(from: buffer)
    file.close()
    let reference = AudioFileReference(fileName: url.lastPathComponent, sampleRate: 48_000, channelCount: 2, frameCount: Int64(frames))
    let track = Track(name: "Noise", kind: .audio, regions: [Region.audio(for: reference, at: .zero, tempoMap: TempoMap())])
    let mastering = OngakuEffect.mastering.makeReference()
    var project = Project(tracks: [track], audioFiles: [reference])
    project.stereoOutInserts = [mastering]
    let range = try #require(project.bounceRange)

    let state = try await ProjectBouncer(project: project) { _ in url }
      .listenForMastering(mastering.id, range: range, sampleRate: 48_000)
    let settings = try #require(state, "It heard enough music")
    let fullState = try #require(try PropertyListSerialization.propertyList(from: settings, format: nil) as? [String: Any])
    #expect(fullState["ongakuMasteringAnalysis"] != nil, "What it found is kept, for its window")

    // A fresh Mastering given those settings is set up for the song.
    let unit = try await AVAudioUnit.instantiate(
      with: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: OngakuEffect.mastering.subType,
        componentManufacturer: OngakuEffect.manufacturer, componentFlags: 0, componentFlagsMask: 0),
      options: [.loadOutOfProcess])
    unit.au.fullState = fullState
    let measured = unit.au.parameterTree?.parameter(withAddress: OngakuEffect.MasteringParameter.measuredLoudness)?.value
    // White noise of ±0.1 is about −20 dBFS RMS; K-weighting brightens it a little.
    #expect(measured.map { (-24)...(-14) ~= $0 } == true, "Measured \(String(describing: measured)) LUFS")
    #expect(unit.au.parameterTree?.parameter(withAddress: OngakuEffect.MasteringParameter.listen)?.value == 0)
  }

  /// A song of a second and a half is too little to go on: nothing comes back.
  @Test func masteringNeedsEnoughMusicToAnalyze() async throws {
    var (project, url, _, _) = try twoTones()
    let mastering = OngakuEffect.mastering.makeReference()
    project.stereoOutInserts = [mastering]
    let range = try #require(project.bounceRange)
    let state = try await ProjectBouncer(project: project) { _ in url }
      .listenForMastering(mastering.id, range: range, sampleRate: 48_000)
    #expect(state == nil)
  }

  @Test func compressorLatencyIsCompensatedToo() async throws {
    let (project, url, _, _) = try twoTones(insertOnA: .compressor)  // 256 samples
    let (_, output) = try await bounce(project, locate: url, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, _, _) = try samples(of: output)
    #expect(onset(in: samples, after: 0) == 24_000)
    #expect(onset(in: samples, after: 40_000) == 48_000)
  }

  @Test func bypassedPluginsAddNoDelay() async throws {
    var (project, url, a, _) = try twoTones()
    let index = try #require(project.trackIndex(for: a))
    project.tracks[index].channel.inserts[0].isBypassed = true
    let (_, output) = try await bounce(project, locate: url, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, _, _) = try samples(of: output)
    #expect(onset(in: samples, after: 0) == 24_000)
    #expect(onset(in: samples, after: 40_000) == 48_000)
  }

  @Test func sendsAreCompensated() async throws {
    // B is only heard through an aux (fader down, pre-fader send).
    var (project, url, _, b) = try twoTones()
    let aux = Track(name: "Aux", kind: .aux)
    project.tracks.append(aux)
    let index = try #require(project.trackIndex(for: b))
    project.tracks[index].channel.volume = ChannelStrip.volumeRange.lowerBound
    project.tracks[index].channel.sends = [Send(destinationTrackID: aux.id, level: 0, isPreFader: true)]
    let (_, output) = try await bounce(project, locate: url, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, _, _) = try samples(of: output)
    #expect(onset(in: samples, after: 0) == 24_000)
    #expect(onset(in: samples, after: 40_000) == 48_000, "The aux's path is delayed to match")
  }

  @Test func stacksAreCompensated() async throws {
    // The limiter is on a stack holding A; B is outside it.
    var (project, url, a, _) = try twoTones()
    let index = try #require(project.trackIndex(for: a))
    project.tracks[index].channel.inserts = []
    var stack = Track(name: "Sum", kind: .aux)
    stack.channel.inserts = [BuiltInEffect.limiter.makeReference()]
    try CreateSummingStack([a], stack: stack).apply(to: &project)
    let (_, output) = try await bounce(project, locate: url, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, _, _) = try samples(of: output)
    #expect(onset(in: samples, after: 0) == 24_000)
    #expect(onset(in: samples, after: 40_000) == 48_000)
  }

  @Test func midiNotesLandOnTime() async throws {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 80)  // square lead: fast attack
    let note = MIDINote(pitch: 72, velocity: 127, start: .quarterNotes(2), length: .quarterNotes(1))
    keys.regions = [Region(name: "Notes", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence(notes: [note])))]
    let (_, output) = try await bounce(Project(tracks: [keys]), settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))

    let (samples, _, _) = try samples(of: output)
    let onset = try #require(firstFrame(above: 0.001, in: samples), "The note should be audible")
    // Beat 3 is 1 s in; the sampler's attack takes a moment to rise above the threshold.
    let milliseconds = Double(onset - 48_000) / 48
    #expect(milliseconds >= 0 && milliseconds < 5, "The note started \(milliseconds) ms after beat 3")
    #expect(samples.count == 96_000, "Four beats at 120 BPM")
  }

  @Test func ongakuInstrumentsPlayTheirNotes() async throws {
    var keys = Track(name: "Synth", kind: .softwareInstrument)
    keys.channel.instrument = .audioUnit(OngakuInstrument.retroSynth.makeReference())
    let note = MIDINote(pitch: 57, velocity: 127, start: .quarterNotes(2), length: .quarterNotes(1))
    keys.regions = [Region(name: "Notes", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence(notes: [note])))]
    let (_, output) = try await bounce(Project(tracks: [keys]), settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: true))

    let (samples, _, _) = try samples(of: output)
    let onset = try #require(firstFrame(above: 0.001, in: samples), "The synth should be heard")
    let milliseconds = Double(onset - 48_000) / 48
    #expect(milliseconds >= 0 && milliseconds < 10, "The note started \(milliseconds) ms after beat 3")
    let heard = PitchDetector.notes(Array(samples[48_000..<72_000]), sampleRate: 48_000)
    #expect(heard.first.map { abs($0.pitch - 57) < 0.2 } == true, "Played A3, heard \(heard.map(\.pitch))")
  }

  @Test func theDrumMachinePlaysDrumParts() async throws {
    var drums = Track(name: "Drums", kind: .softwareInstrument)
    drums.channel.instrument = .audioUnit(OngakuInstrument.drumMachine.makeReference())
    // A kick on beat 1 and a snare on beat 3.
    let notes = [
      MIDINote(pitch: 36, velocity: 120, start: .zero, length: .quarterNotes(0.5)),
      MIDINote(pitch: 38, velocity: 120, start: .quarterNotes(2), length: .quarterNotes(0.5)),
    ]
    drums.regions = [Region(name: "Beat", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence(notes: notes)))]
    let (_, output) = try await bounce(Project(tracks: [drums]), settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, _, _) = try samples(of: output)
    #expect(firstFrame(above: 0.01, in: samples).map { $0 < 480 } == true, "The kick is on the downbeat")
    let snare = samples[48_000..<52_800].map(abs).max() ?? 0
    #expect(snare > 0.05, "The snare is on beat 3")
  }

  /// A Sampler track plays the sample saved in its settings, at the notes' pitches.
  @Test func theSamplerPlaysItsSavedSample() async throws {
    var reference = OngakuInstrument.sampler.makeReference()
    let unit = try await AVAudioUnit.instantiate(
      with: AudioComponentDescription(
        componentType: reference.componentType, componentSubType: reference.componentSubType,
        componentManufacturer: reference.componentManufacturer, componentFlags: 0, componentFlagsMask: 0),
      options: [.loadOutOfProcess])
    // An A (440 Hz), with its root note A4.
    let audio = (0..<48_000).map { Float(0.5 * sin(2 * .pi * 440 * Double($0) / 48_000)) }
    var state = try #require(unit.au.fullState)
    state["ongakuSample"] = ["name": "A", "sampleRate": 48_000.0, "channels": 1, "audio": audio.withUnsafeBufferPointer { Data(buffer: $0) }]
    unit.au.fullState = state
    try #require(unit.au.parameterTree?.parameter(withAddress: 608)).value = 69
    reference.state = try PropertyListSerialization.data(
      fromPropertyList: try #require(unit.au.fullState), format: .binary, options: 0)

    var keys = Track(name: "Sampler", kind: .softwareInstrument)
    keys.channel.instrument = .audioUnit(reference)
    let note = MIDINote(pitch: 64, velocity: 127, start: .quarterNotes(2), length: .quarterNotes(1))
    keys.regions = [Region(name: "Notes", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence(notes: [note])))]
    let (_, output) = try await bounce(Project(tracks: [keys]), settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))

    let (samples, _, _) = try samples(of: output)
    let onset = try #require(firstFrame(above: 0.01, in: samples), "The sample should be heard")
    #expect(Double(onset - 48_000) / 48 < 10, "On beat 3")
    let heard = PitchDetector.notes(Array(samples[50_000..<70_000]), sampleRate: 48_000)
    #expect(heard.first.map { abs($0.pitch - 64) < 0.2 } == true, "Played E4, heard \(heard.map(\.pitch))")
  }

  /// A bounce plays the track through its MIDI effects: an A held for a beat, up an octave
  /// and arpeggiated in eighths, is heard as two A5s.
  @Test func bouncesPlayThroughMIDIEffects() async throws {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 80)
    keys.channel.midiEffects = [
      MIDIEffect(.transposer(Transposer(semitones: 12))), MIDIEffect(.arpeggiator(Arpeggiator(rate: .eighth, gate: 0.5))),
    ]
    let note = MIDINote(pitch: 69, velocity: 110, start: .zero, length: .quarterNotes(1))
    keys.regions = [Region(name: "Notes", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence(notes: [note])))]
    let (_, output) = try await bounce(Project(tracks: [keys]), settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, _, _) = try samples(of: output)
    let heard = PitchDetector.notes(Array(samples[0..<24_000]), sampleRate: 48_000)
    #expect(heard.count == 2, "Two eighth notes: \(heard.map(\.pitch))")
    #expect(heard.allSatisfy { abs($0.pitch - 81) < 0.3 }, "An octave up")
  }

  /// Controllers reach the instrument: volume (CC 7) down to 0 half way through a held note
  /// silences the rest of it.
  @Test func controllersShapeTheSound() async throws {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 80)  // square lead: sustained
    let note = MIDINote(pitch: 72, velocity: 127, start: .zero, length: .quarterNotes(4))
    let silence = MIDIControlEvent(kind: .volume, position: .quarterNotes(2), value: 0)
    keys.regions = [Region(
      name: "Notes", start: .zero, length: .quarterNotes(4),
      content: .midi(MIDISequence(notes: [note], controls: [silence])))]
    let (_, output) = try await bounce(Project(tracks: [keys]), settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))

    let (samples, _, _) = try samples(of: output)
    // 120 BPM at 48 kHz: the volume drops 1 s in. Allow the sampler a moment to fade.
    let before = samples[24_000..<46_000].map(abs).max() ?? 0
    let after = samples[52_000..<96_000].map(abs).max() ?? 0
    #expect(before > 0.05, "The note sounds before the volume drops")
    #expect(after < 0.001, "Volume 0 silences the rest of the note (peak \(after))")
  }

  @Test func tailsRingOutAfterTheEnd() async throws {
    let (project, url) = try toneProject { $0.inserts = [BuiltInEffect.reverb.makeReference()] }
    let (dry, _) = try await bounce(project, locate: url, settings: BounceSettings(includeTail: false), named: "Dry")
    let (withTail, output) = try await bounce(project, locate: url, settings: BounceSettings(includeTail: true), named: "Tail")
    #expect(dry.duration == 0.75)
    #expect(withTail.duration > 1.25, "The reverb rings on (and the tail ends with half a second of silence)")
    #expect(withTail.duration < 20.75, "The tail stops once the reverb has died away")
    let (samples, _, _) = try samples(of: output)
    #expect(samples[36_000..<38_400].contains { abs($0) > 0.0001 }, "Reverb is audible just after the end")
  }

  @Test func ongakuEffectsPlayWithTheirSavedSettings() async throws {
    // Ongaku's Channel EQ, saved with its output 6 dB down.
    var insert = OngakuEffect.channelEQ.makeReference()
    let unit = try await AVAudioUnit.instantiate(
      with: AudioComponentDescription(
        componentType: insert.componentType, componentSubType: insert.componentSubType,
        componentManufacturer: insert.componentManufacturer, componentFlags: 0, componentFlagsMask: 0),
      options: [.loadOutOfProcess])
    try #require(unit.au.parameterTree?.parameter(withAddress: 0)).value = -6
    insert.state = try PropertyListSerialization.data(
      fromPropertyList: try #require(unit.au.fullState), format: .binary, options: 0)

    let (project, url) = try toneProject { $0.inserts = [insert] }
    let (_, output) = try await bounce(project, locate: url, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, _, _) = try samples(of: output)
    let peak = samples.map(abs).max() ?? 0
    #expect(abs(peak - 0.5 * 0.501) < 0.005, "-6 dB of a 0.5 tone (peak \(peak))")
  }

  @Test func syncedDelaysFollowTheSongsTempo() async throws {
    // A synced quarter-note delay, all wet, on a song at 90 BPM.
    var insert = OngakuEffect.delay.makeReference()
    let unit = try await AVAudioUnit.instantiate(
      with: AudioComponentDescription(
        componentType: insert.componentType, componentSubType: insert.componentSubType,
        componentManufacturer: insert.componentManufacturer, componentFlags: 0, componentFlagsMask: 0),
      options: [.loadOutOfProcess])
    let tree = try #require(unit.au.parameterTree)
    for (address, value): (AUParameterAddress, AUValue) in [(300, 1), (302, 8), (303, 0), (307, 0), (309, 100)] {
      try #require(tree.parameter(withAddress: address)).value = value
    }
    insert.state = try PropertyListSerialization.data(
      fromPropertyList: try #require(unit.au.fullState), format: .binary, options: 0)

    var (project, url) = try toneProject { $0.inserts = [insert] }
    project.tempoMap = TempoMap(bpm: 90)
    let (_, output) = try await bounce(project, locate: url, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: true))
    let (samples, _, _) = try samples(of: output)
    // The tone starts on beat 2 (two-thirds of a second in at 90 BPM); its echo a beat later.
    let echo = try #require(firstFrame(above: 0.05, in: samples))
    #expect(abs(Double(echo) / 48_000 - 4.0 / 3) < 0.003, "Echo at \(Double(echo) / 48_000) s")
  }

  // MARK: - Region settings

  @Test func regionGainChangesTheLevel() async throws {
    var (project, url) = try toneProject()
    try SetRegionParameter(.gain(-6), for: [project.tracks[0].regions[0].id]).apply(to: &project)
    let (_, output) = try await bounce(project, locate: url, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, _, _) = try samples(of: output)
    let peak = samples.map(abs).max() ?? 0
    #expect(abs(peak - 0.5 * 0.501) < 0.002, "-6 dB of a 0.5 tone (peak \(peak))")
  }

  @Test func loopedAudioRepeats() async throws {
    var (project, url) = try toneProject()
    try SetRegionParameter(.looped(true), for: [project.tracks[0].regions[0].id]).apply(to: &project)
    project.endPosition = .quarterNotes(3)
    let (_, output) = try await bounce(project, locate: url, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, _, _) = try samples(of: output)
    // The quarter-second tone starts on beat 2 (24 000) and repeats every 12 000 frames to
    // beat 4 (72 000), where the project ends.
    #expect(samples.count == 72_000)
    #expect(samples[36_000] > 0.45, "The first repeat starts at full level, like the tone")
    #expect(samples[60_000] > 0.45)
    #expect(samples[66_000..<72_000].contains { abs($0) > 0.1 }, "Still playing at the end")
  }

  @Test func fadesShapeTheAudio() async throws {
    var (project, url) = try toneProject()
    let id = project.tracks[0].regions[0].id
    try SetRegionParameter(.fadeIn(0.1), for: [id]).apply(to: &project)
    let (_, output) = try await bounce(project, locate: url, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false))
    let (samples, _, _) = try samples(of: output)
    // The tone (0.5) starts at 24 000; the fade takes 4 800 frames.
    #expect(abs(samples[24_000]) < 0.001, "Silent at the start of the fade")
    let middle = samples[26_380..<26_420].map(abs).max() ?? 0
    #expect(abs(middle - 0.25) < 0.01, "Half way up half way through (\(middle))")
    #expect((samples[29_000..<29_100].map(abs).max() ?? 0) > 0.49, "Full level after the fade")
  }

  // MARK: - Mix

  @Test func mutedTracksAreLeftOut() async throws {
    let (project, url) = try toneProject { $0.isMuted = true }
    let (result, _) = try await bounce(project, locate: url, settings: BounceSettings(includeTail: false))
    #expect(result.peakDecibels == -.infinity)
  }

  /// A summing stack's fader controls its subtracks in a bounce too.
  @Test func stacksSumTheirSubtracks() async throws {
    var (project, url) = try toneProject()
    try CreateSummingStack([project.tracks[0].id], stack: Track(name: "Sum", kind: .aux)).apply(to: &project)
    let (open, _) = try await bounce(project, locate: url, settings: BounceSettings(includeTail: false), named: "Open")
    #expect(open.peakDecibels > -12, "The tone plays through the stack")

    project.tracks[0].channel.volume = ChannelStrip.volumeRange.lowerBound  // the stack's fader
    let (closed, _) = try await bounce(project, locate: url, settings: BounceSettings(includeTail: false), named: "Closed")
    #expect(closed.peakDecibels == -.infinity, "With the stack's fader down nothing is heard")
  }

  @Test func sendsReachTheAux() async throws {
    var (project, url) = try toneProject()
    let aux = Track(name: "Aux 1", kind: .aux)
    project.tracks.append(aux)
    // Fader down, pre-fader send at 0 dB: the tone is only heard through the aux.
    project.tracks[0].channel.volume = ChannelStrip.volumeRange.lowerBound
    project.tracks[0].channel.sends = [Send(destinationTrackID: aux.id, level: 0, isPreFader: true)]
    let (result, _) = try await bounce(project, locate: url, settings: BounceSettings(includeTail: false))
    #expect(abs(result.peakDecibels - 20 * log10(0.5)) < 0.1)
  }

  @Test func overloadedMixesReportClipping() async throws {
    let (project, url) = try toneProject { $0.volume = 12 }
    let (result, _) = try await bounce(project, locate: url, settings: BounceSettings(includeTail: false))
    #expect(result.isClipped)
  }

  @Test func normalizingSetsThePeak() async throws {
    let (project, url) = try toneProject(amplitude: 0.1)
    let settings = BounceSettings(bitDepth: .thirtyTwoFloat, normalize: true, includeTail: false)
    let (result, output) = try await bounce(project, locate: url, settings: settings)
    let (samples, _, _) = try samples(of: output)
    let peak = samples.map(abs).max() ?? 0
    #expect(abs(20 * log10(Double(peak)) - settings.normalizationTarget) < 0.01)
    #expect(abs(result.peakDecibels + 20) < 0.1, "The reported peak is the mix's, before normalizing")
  }

  // MARK: - File formats

  @Test(arguments: [
    BounceSettings(format: .wav, bitDepth: .sixteen, sampleRate: 44_100),
    BounceSettings(format: .wav, bitDepth: .twentyFour),
    BounceSettings(format: .aiff, bitDepth: .twentyFour, sampleRate: 96_000),
    BounceSettings(format: .m4a, sampleRate: 48_000),
  ])
  func filesHaveTheRequestedFormat(settings: BounceSettings) async throws {
    var settings = settings
    settings.includeTail = false
    let (project, url) = try toneProject()
    let (_, output) = try await bounce(project, locate: url, settings: settings)
    let (samples, _, fileFormat) = try samples(of: output)
    let description = fileFormat.streamDescription.pointee
    #expect(fileFormat.sampleRate == settings.effectiveSampleRate)
    #expect(fileFormat.channelCount == 2)
    if let bitDepth = settings.effectiveBitDepth {
      #expect(description.mFormatID == kAudioFormatLinearPCM)
      #expect(Int(description.mBitsPerChannel) == bitDepth.rawValue)
      #expect(samples.count == Int((0.75 * settings.effectiveSampleRate).rounded()))
    } else {
      #expect(description.mFormatID == kAudioFormatMPEG4AAC)
      #expect(abs(samples.count - 36_000) < 4_096, "AAC adds a little padding")
    }
    #expect(samples.contains { abs($0) > 0.4 }, "The tone survives the conversion")
  }

  @Test func cancellingStopsTheBounce() async throws {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 0)
    keys.regions = [Region(name: "Long", start: .zero, length: .quarterNotes(2_000), content: .midi(MIDISequence()))]
    let project = Project(tracks: [keys])
    let output = folder.appending(path: "Cancelled.wav")
    let task = Task {
      try await ProjectBouncer(project: project) { _ in nil }
        .bounce(project.bounceRange!, settings: BounceSettings(), to: output)
    }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func ditherStaysWithinOneBit() {
    var dither = TriangularDither(bitDepth: 16)
    var samples = [Float](repeating: 0, count: 10_000)
    samples.withUnsafeMutableBufferPointer { dither.apply(to: $0.baseAddress!, count: $0.count) }
    let lsb: Float = 1 / 32_768
    #expect(samples.allSatisfy { abs($0) <= lsb })
    #expect(abs(samples.reduce(0, +) / Float(samples.count)) < lsb / 20, "No DC offset")
    #expect(Set(samples).count > 9_000, "Noise, not a constant")
  }
}
