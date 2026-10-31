//
//  MixerGraphTests.swift
//  OngakuTests
//

import AVFAudio
import AudioToolbox
import Foundation
import OngakuCore
@testable import OngakuEngine
import Testing

/// Exercises the live mixer graph, using the level meters to hear where sound goes.
@MainActor
@Suite(.serialized)
struct MixerGraphTests {
  /// An instrument track ("Keys") sending to an aux ("Reverb").
  private func makeProject(send: Send?, keysChannel: (inout ChannelStrip) -> Void = { _ in }) -> (Project, Track.ID, Track.ID) {
    let aux = Track(name: "Reverb", kind: .aux)
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 80)  // square lead: loud and sustained
    if var send {
      send.destinationTrackID = aux.id
      keys.channel.sends = [send]
    }
    keysChannel(&keys.channel)
    return (Project(tracks: [keys, aux]), keys.id, aux.id)
  }

  /// Holds a note on the keys track and returns the loudest level each meter showed.
  private func peaks(
    playing engine: PlaybackEngine, on keysID: Track.ID, meters ids: [UUID]
  ) async throws -> [UUID: Float] {
    try await Task.sleep(for: .milliseconds(300))  // let the engine render once
    engine.playLive([0x90, 72, 127], onTrack: keysID)
    var peaks: [UUID: Float] = [:]
    for _ in 0..<15 {
      try await Task.sleep(for: .milliseconds(40))
      for id in ids {
        peaks[id] = max(peaks[id] ?? -60, engine.meters.level(for: id).peakDecibels)
      }
    }
    engine.playLive([0x80, 72, 0], onTrack: keysID)
    return peaks
  }

  @Test func preFaderSendsIgnoreTheFader() async throws {
    let (project, keys, aux) = makeProject(send: Send(destinationTrackID: UUID(), level: 0, isPreFader: true)) {
      $0.volume = ChannelStrip.volumeRange.lowerBound  // fader all the way down
    }
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }

    let levels = try await peaks(playing: engine, on: keys, meters: [keys, aux])
    #expect(levels[keys]! <= -59, "The keys fader is down, so its meter stays silent")
    #expect(levels[aux]! > -40, "The pre-fader send still feeds the aux")
  }

  @Test func postFaderSendsFollowMute() async throws {
    let (project, keys, aux) = makeProject(send: Send(destinationTrackID: UUID(), level: 0, isPreFader: false)) {
      $0.isMuted = true
    }
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }

    let levels = try await peaks(playing: engine, on: keys, meters: [aux])
    #expect(levels[aux]! <= -59, "Muting the track silences its post-fader send")
  }

  @Test func soundReachesStereoOutThroughTheTrack() async throws {
    let (project, keys, _) = makeProject(send: nil)
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }

    let levels = try await peaks(playing: engine, on: keys, meters: [keys, LevelMeters.masterID])
    #expect(levels[keys]! > -40)
    #expect(levels[LevelMeters.masterID]! > -40)
  }

  /// Writes a one-second, 48 kHz stereo sine file.
  private func makeToneFile() throws -> (URL, AudioFileReference) {
    let url = FileManager.default.temporaryDirectory.appending(path: "MixerGraphTests-\(UUID().uuidString).caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
    buffer.frameLength = 48_000
    for channel in 0..<2 {
      for frame in 0..<48_000 {
        buffer.floatChannelData![channel][frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / 48_000)
      }
    }
    try file.write(from: buffer)
    return (url, AudioFileReference(fileName: url.lastPathComponent, sampleRate: 48_000, channelCount: 2, frameCount: 48_000))
  }

  @Test func audioRegionsPlayThroughTheChannel() async throws {
    let (url, file) = try makeToneFile()
    defer { try? FileManager.default.removeItem(at: url) }
    let region = Region.audio(for: file, at: .zero, tempoMap: TempoMap())
    let track = Track(name: "Tone", kind: .audio, regions: [region])
    let engine = PlaybackEngine(project: Project(tracks: [track], audioFiles: [file])) { _ in url }
    defer { engine.shutDown() }

    try await Task.sleep(for: .milliseconds(200))
    engine.play()
    #expect(engine.isPlaying, "Playback should start: \(engine.lastError ?? "")")
    var peak: Float = -60
    for _ in 0..<15 {
      try await Task.sleep(for: .milliseconds(40))
      peak = max(peak, engine.meters.level(for: track.id).peakDecibels)
    }
    engine.stop()
    #expect(peak > -20, "The tone should reach the track's meter")
    #expect(engine.lastError == nil)
  }

  /// Importing adds an audio track to an engine that is already running, as in the app.
  @Test func audioTracksAddedWhileRunningPlay() async throws {
    let (url, file) = try makeToneFile()
    defer { try? FileManager.default.removeItem(at: url) }
    var project = Project.newDefault()
    let engine = PlaybackEngine(project: project) { _ in url }
    defer { engine.shutDown() }
    try await Task.sleep(for: .milliseconds(200))

    let track = Track(name: "Tone", kind: .audio, regions: [Region.audio(for: file, at: .zero, tempoMap: TempoMap())])
    project.tracks.append(track)
    project.audioFiles.append(file)
    engine.update(project: project)
    #expect(engine.lastError == nil, "Adding the track: \(engine.lastError ?? "")")

    engine.play()
    #expect(engine.isPlaying, "Playback should start: \(engine.lastError ?? "")")
    var peak: Float = -60
    for _ in 0..<15 {
      try await Task.sleep(for: .milliseconds(40))
      peak = max(peak, engine.meters.level(for: track.id).peakDecibels)
    }
    engine.stop()
    #expect(peak > -20)
    #expect(engine.lastError == nil, "\(engine.lastError ?? "")")
  }

  /// Adding an instrument track to a running engine, as the New Track menu does.
  @Test func instrumentTracksAddedWhileRunningPlay() async throws {
    var project = Project(tracks: [Track(name: "Audio 1", kind: .audio)])
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    try await Task.sleep(for: .milliseconds(200))

    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 80)
    project.tracks.append(keys)
    engine.update(project: project)

    let levels = try await peaks(playing: engine, on: keys.id, meters: [keys.id])
    #expect(levels[keys.id]! > -40, "A track added while the engine runs should still sound")
    #expect(engine.lastError == nil)
  }

  /// A summing stack's subtracks play through the stack: its fader controls them, and
  /// they no longer reach Stereo Out directly.
  @Test func subtracksPlayThroughTheirStack() async throws {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 80)
    var project = Project(tracks: [keys])
    try CreateSummingStack([keys.id], stack: Track(name: "Sum", kind: .aux)).apply(to: &project)
    let stackID = try #require(project.tracks.first { $0.isSummingStack }?.id)
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }

    let through = try await peaks(playing: engine, on: keys.id, meters: [keys.id, stackID, LevelMeters.masterID])
    #expect(through[stackID]! > -40, "The stack hears its subtrack")
    #expect(through[LevelMeters.masterID]! > -40, "…and passes it to Stereo Out")

    #expect(engine.lastError == nil)

    // The stack's fader down: nothing reaches Stereo Out, though the subtrack still plays.
    // (A fresh engine, as the meters take a moment to fall back after the first note.)
    let index = try #require(project.trackIndex(for: stackID))
    project.tracks[index].channel.volume = ChannelStrip.volumeRange.lowerBound
    let quiet = PlaybackEngine(project: project) { _ in nil }
    defer { quiet.shutDown() }
    let down = try await peaks(playing: quiet, on: keys.id, meters: [keys.id, LevelMeters.masterID])
    #expect(down[keys.id]! > -40)
    #expect(down[LevelMeters.masterID]! <= -59, "Only the stack feeds Stereo Out")
  }

  /// Live playback compensates plug-in latency: a compressor on one track delays the others,
  /// and they're still heard through their delayed connections.
  @Test func liveMixCompensatesPluginLatency() async throws {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 80)
    var vocal = Track(name: "Vocal", kind: .audio)
    vocal.channel.inserts = [BuiltInEffect.compressor.makeReference()]
    let engine = PlaybackEngine(project: Project(tracks: [keys, vocal])) { _ in nil }
    defer { engine.shutDown() }

    let latency = engine.compensation.totalLatency
    #expect(latency > 200 && latency < 300, "About 5.3 ms of compressor latency (\(latency) samples)")
    #expect(engine.compensation.delay(from: keys.id, to: .stereoOut) == latency)
    #expect(engine.compensation.delay(from: vocal.id, to: .stereoOut) == 0)
    #expect(engine.compensationSeconds > 0.005 && engine.compensationSeconds < 0.006)

    let levels = try await peaks(playing: engine, on: keys.id, meters: [keys.id, LevelMeters.masterID])
    #expect(levels[LevelMeters.masterID]! > -40, "The delayed keys still reach Stereo Out")
    #expect(engine.lastError == nil)
  }

  /// Importing a MIDI file adds several tracks to a running engine at once. They used to
  /// share one Stereo Out input, each replacing the last, so only the last track sounded.
  @Test func severalTracksAddedWhileRunningAllPlay() async throws {
    var project = Project.newDefault()
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    try await Task.sleep(for: .milliseconds(200))

    let added = (0..<3).map { index in
      var track = Track(name: "Keys \(index + 1)", kind: .softwareInstrument)
      track.channel.instrument = .generalMIDI(program: 80)
      return track
    }
    try ImportTracks(added).apply(to: &project)
    engine.update(project: project)

    for track in project.tracks {
      let levels = try await peaks(playing: engine, on: track.id, meters: [track.id])
      #expect(levels[track.id]! > -40, "“\(track.name)” should sound")
    }
    #expect(engine.lastError == nil)
  }

  /// Live playback places automation in the fader's own timeline, read from its renders.
  @Test func volumeAutomationPlaysLive() async throws {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 80)
    let note = MIDINote(pitch: 72, velocity: 127, start: .zero, length: .quarterNotes(8))
    keys.regions = [Region(name: "Held", start: .zero, length: .quarterNotes(8), content: .midi(MIDISequence(notes: [note])))]
    // Full level for the first beat (half a second), then silence.
    keys.automation = [AutomationLane(parameter: .volume, points: [
      AutomationPoint(position: .zero, value: 0), AutomationPoint(position: .quarterNotes(1), value: 0),
      AutomationPoint(position: .quarterNotes(1.01), value: ChannelStrip.volumeRange.lowerBound),
    ])]
    let engine = PlaybackEngine(project: Project(tracks: [keys])) { _ in nil }
    defer { engine.shutDown() }
    try await Task.sleep(for: .milliseconds(300))

    engine.play()
    var early: Float = -60
    var late: Float = -60
    for step in 0..<30 {
      try await Task.sleep(for: .milliseconds(40))
      let level = engine.meters.level(for: keys.id).peakDecibels
      if (5...9).contains(step) { early = max(early, level) }  // about 0.2-0.4 s
      if step >= 22 { late = max(late, level) }  // after about 0.9 s
    }
    engine.stop()
    #expect(early > -40, "Audible before the automation drops")
    #expect(late <= -59, "Silent once the automation has dropped: \(late) dB")
  }

  /// Send automation plays live: the aux, fed only by an automated pre-fader send, falls
  /// silent when the send's automation drops.
  @Test func sendAutomationPlaysLive() async throws {
    let aux = Track(name: "Aux", kind: .aux)
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 80)
    keys.channel.volume = ChannelStrip.volumeRange.lowerBound
    let send = Send(destinationTrackID: aux.id, level: 0, isPreFader: true)
    keys.channel.sends = [send]
    let note = MIDINote(pitch: 72, velocity: 127, start: .zero, length: .quarterNotes(8))
    keys.regions = [Region(name: "Held", start: .zero, length: .quarterNotes(8), content: .midi(MIDISequence(notes: [note])))]
    keys.automation = [AutomationLane(parameter: .sendLevel(send.id), points: [
      AutomationPoint(position: .zero, value: 0), AutomationPoint(position: .quarterNotes(1), value: 0),
      AutomationPoint(position: .quarterNotes(1.01), value: Send.levelRange.lowerBound),
    ])]
    let engine = PlaybackEngine(project: Project(tracks: [keys, aux])) { _ in nil }
    defer { engine.shutDown() }
    try await Task.sleep(for: .milliseconds(300))

    engine.play()
    var early: Float = -60
    var late: Float = -60
    for step in 0..<30 {
      try await Task.sleep(for: .milliseconds(40))
      let level = engine.meters.level(for: aux.id).peakDecibels
      if (5...9).contains(step) { early = max(early, level) }
      if step >= 22 { late = max(late, level) }
    }
    engine.stop()
    #expect(early > -40, "The aux hears the send before its automation drops")
    #expect(late <= -59, "Silent once the send's automation has dropped: \(late) dB")
  }

  /// Letting go of a control in Touch stores new automation mid-song; that must not restart
  /// playback (which would be heard as a hiccup).
  @Test func automationEditsDontRestartPlayback() async throws {
    var (project, _, _) = makeProject(send: nil)
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    try await Task.sleep(for: .milliseconds(200))
    engine.play()
    let started = try #require(engine.session?.startHostTime)

    project.tracks[0].automation = [AutomationLane(parameter: .volume, points: [AutomationPoint(position: .zero, value: -12)])]
    engine.update(project: project)
    project.tracks[0].automationMode = .latch
    engine.update(project: project)
    #expect(engine.session?.startHostTime == started, "Still the same run of the transport")
    #expect(engine.session?.plan.project.tracks[0].automation == project.tracks[0].automation, "Playing the new automation")
    engine.stop()
  }

  @Test func automationSetsTheLevelWhileStopped() async throws {
    var (project, keys, _) = makeProject(send: nil)
    project.tracks[0].automation = [AutomationLane(parameter: .volume, points: [
      AutomationPoint(position: .zero, value: ChannelStrip.volumeRange.lowerBound),
    ])]
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    let levels = try await peaks(playing: engine, on: keys, meters: [keys])
    #expect(levels[keys]! <= -59, "The automation at the playhead keeps the fader down")
  }

  /// Mixers left to pick their own format run at 44.1 kHz, which would resample every track
  /// twice on a 48 kHz device.
  @Test func channelsMixAtTheOutputSampleRate() throws {
    let (project, _, _) = makeProject(send: Send(destinationTrackID: UUID(), level: 0)) {
      $0.inserts = [BuiltInEffect.channelEQ.makeReference()]
    }
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }

    let outputRate = engine.engine.outputNode.outputFormat(forBus: 0).sampleRate
    let rates = engine.engine.attachedNodes.filter { $0 !== engine.engine.outputNode }.map { $0.outputFormat(forBus: 0).sampleRate }
    #expect(!rates.isEmpty)
    #expect(rates.allSatisfy { $0 == outputRate }, "Node rates \(Set(rates)) vs output \(outputRate)")
  }

  @Test func builtInEffectsLoadAsInserts() throws {
    let reverb = BuiltInEffect.reverb.makeReference()
    let (project, keys, _) = makeProject(send: nil) { $0.inserts = [reverb] }
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }

    #expect(!engine.isLoadingInsert(reverb.id, onTrack: keys))
    let subType = engine.withInsertAudioUnit(reverb.id, onTrack: keys) { $0.componentDescription.componentSubType }
    #expect(subType == kAudioUnitSubType_Reverb2)
    #expect(engine.insertState(reverb.id, onTrack: keys) != nil)
    #expect(engine.lastError == nil)
  }

  @Test func bypassingAnInsertKeepsItLoaded() throws {
    var reverb = BuiltInEffect.reverb.makeReference()
    var (project, keys, _) = makeProject(send: nil) { $0.inserts = [reverb] }
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }

    reverb.isBypassed = true
    project.tracks[0].channel.inserts = [reverb]
    engine.update(project: project)
    let bypassed = engine.withInsertAudioUnit(reverb.id, onTrack: keys) { $0.shouldBypassEffect }
    #expect(bypassed == true)
  }

  /// A plug-in's settings changed in the project (an undo, or Analyze Whole Song) reach the
  /// loaded plug-in.
  @Test func changedPluginSettingsReachTheLoadedPlugin() throws {
    var reverb = BuiltInEffect.reverb.makeReference()
    var (project, keys, _) = makeProject(send: nil) { $0.inserts = [reverb] }
    let engine = PlaybackEngine(project: project) { _ in nil }
    defer { engine.shutDown() }
    func dryWet() -> AUValue? {
      engine.withInsertAudioUnit(reverb.id, onTrack: keys) {
        $0.parameterTree?.parameter(withAddress: AUParameterAddress(kReverb2Param_DryWetMix))?.value
      } ?? nil
    }
    func setDryWet(_ value: AUValue) {
      engine.withInsertAudioUnit(reverb.id, onTrack: keys) {
        $0.parameterTree?.parameter(withAddress: AUParameterAddress(kReverb2Param_DryWetMix))?.value = value
      }
    }

    setDryWet(20)
    let settings = try #require(engine.insertState(reverb.id, onTrack: keys))
    setDryWet(80)
    reverb.state = settings
    project.tracks[0].channel.inserts = [reverb]
    engine.update(project: project)
    #expect(dryWet() == 20, "The project's settings were applied")
  }
}
