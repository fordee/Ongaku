//
//  MixerAndRecordingTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

struct MixerAndRecordingTests {
  private func makeProject() -> (Project, keys: Track.ID, aux: Track.ID, aux2: Track.ID) {
    let keys = Track(name: "Keys", kind: .softwareInstrument)
    let aux = Track(name: "Reverb", kind: .aux)
    let aux2 = Track(name: "Delay", kind: .aux)
    return (Project(tracks: [keys, aux, aux2]), keys.id, aux.id, aux2.id)
  }

  // MARK: - Aux tracks and sends

  @Test func auxTracksHaveNoInstrumentOrInput() {
    let aux = Track(name: "Aux 1", kind: .aux)
    #expect(aux.channel.instrument == nil)
    #expect(aux.channel.audioInput == nil)
    #expect(aux.color == .purple)
    #expect(Track(name: "Audio 1", kind: .audio).channel.audioInput == .defaultInput)
  }

  @Test func sendsGoToAuxTracks() throws {
    var (project, keys, aux, _) = makeProject()
    try AddSend(Send(destinationTrackID: aux, level: 20), from: keys).apply(to: &project)
    let send = try #require(project.track(withID: keys)?.channel.sends.first)
    #expect(send.destinationTrackID == aux)
    #expect(send.level == 6)  // clamped

    // Not to an instrument track, and not twice to the same aux.
    #expect(throws: EditError.self) {
      try AddSend(Send(destinationTrackID: keys), from: aux).apply(to: &project)
    }
    #expect(throws: EditError.self) {
      try AddSend(Send(destinationTrackID: aux), from: keys).apply(to: &project)
    }
  }

  @Test func sendsCantCreateFeedbackLoops() throws {
    var (project, _, aux, aux2) = makeProject()
    try AddSend(Send(destinationTrackID: aux2), from: aux).apply(to: &project)
    // Delay → Reverb would loop back through Reverb → Delay.
    #expect(throws: EditError.self) {
      try AddSend(Send(destinationTrackID: aux), from: aux2).apply(to: &project)
    }
    // And an aux can't send to itself.
    #expect(throws: EditError.self) {
      try AddSend(Send(destinationTrackID: aux), from: aux).apply(to: &project)
    }
  }

  @Test func updatingAndRemovingSends() throws {
    var (project, keys, aux, _) = makeProject()
    var send = Send(destinationTrackID: aux, level: -12)
    try AddSend(send, from: keys).apply(to: &project)
    send.level = -3
    send.isPreFader = true
    try UpdateSend(send, on: keys).apply(to: &project)
    #expect(project.track(withID: keys)?.channel.sends == [send])

    try RemoveSend(send.id, from: keys).apply(to: &project)
    #expect(project.track(withID: keys)?.channel.sends.isEmpty == true)
  }

  @Test func deletingAnAuxRemovesSendsToIt() throws {
    var (project, keys, aux, _) = makeProject()
    try AddSend(Send(destinationTrackID: aux), from: keys).apply(to: &project)
    try DeleteTracks([aux]).apply(to: &project)
    #expect(project.track(withID: keys)?.channel.sends.isEmpty == true)
  }

  @Test func soloingATrackKeepsTheAuxItFeeds() throws {
    var (project, keys, aux, aux2) = makeProject()
    let drums = Track(name: "Drums", kind: .softwareInstrument)
    project.tracks.append(drums)
    try AddSend(Send(destinationTrackID: aux), from: keys).apply(to: &project)
    project.tracks[0].channel.isSoloed = true

    #expect(project.isTrackAudible(keys))
    #expect(project.isTrackAudible(aux), "The soloed track's reverb stays on")
    #expect(!project.isTrackAudible(aux2), "An aux nothing soloed feeds is silenced")
    #expect(!project.isTrackAudible(drums.id))
  }

  // MARK: - Inserts

  @Test func insertsCanBeAddedMovedBypassedAndRemoved() throws {
    var (project, keys, _, _) = makeProject()
    let eq = BuiltInEffect.channelEQ.makeReference()
    let reverb = BuiltInEffect.reverb.makeReference()
    try AddInsert(eq, to: keys).apply(to: &project)
    try AddInsert(reverb, to: keys).apply(to: &project)
    try MoveInsert(reverb.id, in: keys, to: 0).apply(to: &project)
    #expect(project.track(withID: keys)?.channel.inserts.map(\.id) == [reverb.id, eq.id])

    try SetInsertBypassed(eq.id, in: keys, isBypassed: true).apply(to: &project)
    #expect(project.track(withID: keys)?.channel.inserts.last?.isBypassed == true)

    try SetPluginState(Data([1, 2]), forPlugin: eq.id, on: keys).apply(to: &project)
    #expect(project.track(withID: keys)?.channel.inserts.last?.state == Data([1, 2]))

    try RemoveInsert(reverb.id, from: keys).apply(to: &project)
    #expect(project.track(withID: keys)?.channel.inserts.map(\.id) == [eq.id])
  }

  @Test func stereoOutTakesInsertsAndSavesThem() throws {
    var (project, keys, _, _) = makeProject()
    let maximizer = OngakuEffect.maximizer.makeReference()
    let eq = BuiltInEffect.channelEQ.makeReference()
    try AddInsert(maximizer, to: Project.stereoOutID).apply(to: &project)
    try AddInsert(eq, to: Project.stereoOutID, at: 0).apply(to: &project)
    try SetInsertBypassed(eq.id, in: Project.stereoOutID, isBypassed: true).apply(to: &project)
    try SetPluginState(Data([7]), forPlugin: maximizer.id, on: Project.stereoOutID).apply(to: &project)
    #expect(project.stereoOutInserts.map(\.id) == [eq.id, maximizer.id])
    #expect(project.stereoOutInserts[0].isBypassed)
    #expect(project.stereoOutInserts[1].state == Data([7]))
    #expect(project.track(withID: keys)?.channel.inserts.isEmpty == true, "No track got them")

    let saved = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    #expect(saved.stereoOutInserts == project.stereoOutInserts)

    try RemoveInsert(eq.id, from: Project.stereoOutID).apply(to: &project)
    #expect(project.stereoOutInserts.map(\.id) == [maximizer.id])
  }

  @Test func masteringIsLastInTheAddInsertMenu() {
    // The Add Insert menu lists the categories in order, each with its effects.
    #expect(OngakuEffect.Category.allCases.last == .mastering)
    #expect(OngakuEffect.Category.mastering.rawValue == "Mastering")
    #expect(OngakuEffect.allCases.filter { $0.category == .mastering } == [.mastering])
    #expect(OngakuEffect.mastering.name == "Mastering")
    #expect(OngakuEffect.mastering.subType == 0x6F6D_7374)  // 'omst'
    #expect(OngakuEffect.mastering.windowSize == CGSize(width: 940, height: 430 + OngakuEffect.headerHeight))
    #expect(OngakuEffect(OngakuEffect.mastering.makeReference()) == .mastering)
  }

  @Test func channelStripsHaveAtMostEightInserts() throws {
    var (project, keys, _, _) = makeProject()
    for _ in 0..<ChannelStrip.maximumInserts {
      try AddInsert(BuiltInEffect.delay.makeReference(), to: keys).apply(to: &project)
    }
    #expect(throws: EditError.self) {
      try AddInsert(BuiltInEffect.delay.makeReference(), to: keys).apply(to: &project)
    }
  }

  @Test func builtInEffectsUseAppleAudioUnits() {
    let reverb = BuiltInEffect.reverb.makeReference()
    #expect(reverb.componentType == 0x6175_6678)  // 'aufx'
    #expect(reverb.componentSubType == 0x7276_6232)  // 'rvb2'
    #expect(reverb.componentManufacturer == 0x6170_706C)  // 'appl'
    #expect(BuiltInEffect.isBuiltIn(reverb))
  }

  // MARK: - Recording and inputs

  @Test func onlyRecordableTracksCanBeArmed() throws {
    var (project, keys, aux, _) = makeProject()
    try SetRecordArmed(keys, isArmed: true).apply(to: &project)
    #expect(project.track(withID: keys)?.isRecordArmed == true)
    #expect(throws: EditError.self) { try SetRecordArmed(aux, isArmed: true).apply(to: &project) }
  }

  @Test func audioInputsAreForAudioTracks() throws {
    var (project, keys, _, _) = makeProject()
    let audio = Track(name: "Vocal", kind: .audio)
    project.tracks.append(audio)
    try SetAudioInput(AudioInputSelection(firstChannel: 2, isStereo: true), for: audio.id).apply(to: &project)
    #expect(project.track(withID: audio.id)?.channel.audioInput?.displayName == "Input 3–4")
    #expect(throws: EditError.self) {
      try SetAudioInput(.defaultInput, for: keys).apply(to: &project)
    }
  }

  @Test func masterVolumeIsClamped() throws {
    var project = Project()
    try SetMasterVolume(12).apply(to: &project)
    #expect(project.masterVolume == 6)
  }

  @Test func midiRecorderPairsNotesAndBuildsARegion() throws {
    var recorder = MIDIRecorder()
    let bar = Tick(3840)
    // Recording started at beat 3 of bar 2.
    recorder.add([0x90, 60, 100], at: bar + Tick(1920))
    recorder.add([0x90, 64, 90], at: bar + Tick(2400))
    recorder.add([0x80, 60, 0], at: bar + Tick(2880))
    recorder.add([0x90, 64, 0], at: bar + Tick(3360))  // velocity-0 note-off
    recorder.add([0x90, 67, 80], at: bar * 2 + Tick(100))  // still held when recording stops
    recorder.finish(at: bar * 2 + Tick(960))

    let region = try #require(
      recorder.makeRegion(name: "Keys", recordedFrom: bar + Tick(1920), to: bar * 2 + Tick(960), tempoMap: TempoMap()))
    #expect(region.start == bar)
    #expect(region.length == bar * 2)
    guard case .midi(let sequence) = region.content else {
      Issue.record("Expected MIDI")
      return
    }
    #expect(sequence.notes.map(\.pitch) == [60, 64, 67])
    #expect(sequence.notes.map(\.start) == [Tick(1920), Tick(2400), bar + Tick(100)])
    #expect(sequence.notes.map(\.length) == [Tick(960), Tick(960), Tick(860)])
    #expect(sequence.notes.map(\.velocity) == [100, 90, 80])
  }

  @Test func midiRecorderWithNothingPlayedMakesNoRegion() {
    var recorder = MIDIRecorder()
    recorder.add([0xC0, 5], at: .zero)  // a program change isn't recorded
    recorder.finish(at: Tick(3840))
    #expect(recorder.makeRegion(name: "Keys", recordedFrom: .zero, to: Tick(3840), tempoMap: TempoMap()) == nil)
  }

  /// As in Logic, a take with only the sustain pedal (or another controller) is still a take.
  @Test func midiRecorderWithOnlyControllersMakesARegion() {
    var recorder = MIDIRecorder()
    recorder.add([0xB0, 64, 127], at: .zero)
    recorder.finish(at: Tick(3840))
    #expect(recorder.makeRegion(name: "Keys", recordedFrom: .zero, to: Tick(3840), tempoMap: TempoMap()) != nil)
  }

  @Test func midiRecorderKeepsControllersPitchBendAndAftertouch() throws {
    var recorder = MIDIRecorder()
    recorder.add([0xB0, 64, 127], at: Tick(3840 + 100))  // sustain down
    recorder.add([0x90, 60, 90], at: Tick(3840 + 200))
    recorder.add([0xE0, 0x00, 0x60], at: Tick(3840 + 300))  // bend +4096
    recorder.add([0xD0, 50], at: Tick(3840 + 400))
    recorder.add([0x80, 60, 0], at: Tick(3840 + 960))
    recorder.add([0xB0, 64, 0], at: Tick(3840 + 1000))  // sustain up
    let region = try #require(recorder.makeRegion(name: "Take", recordedFrom: Tick(3840), to: Tick(3840 * 2), tempoMap: TempoMap()))
    guard case .midi(let sequence) = region.content else {
      Issue.record("Expected MIDI")
      return
    }
    #expect(region.start == Tick(3840))
    #expect(sequence.controls.map(\.kind) == [.sustain, .pitchBend, .channelPressure, .sustain])
    #expect(sequence.controls.map(\.position) == [Tick(100), Tick(300), Tick(400), Tick(1000)])
    #expect(sequence.controls.map(\.value) == [127, 4096, 50, 0])
  }

  // MARK: - File format

  @Test func formatVersionOneProjectsStillOpen() throws {
    // A channel strip and project as Phase 1 and 2 saved them: no sends, input or master volume.
    let version1 = Data(#"""
      {"audioFiles":[],"cycle":{"end":15360,"isEnabled":false,"start":0},"endPosition":491520,"formatVersion":1,
       "keySignature":{"mode":"major","tonic":0},"sampleRate":48000,
       "tempoMap":{"meterChanges":[{"barIndex":0,"signature":{"beatUnit":4,"beatsPerBar":4}}],"tempoChanges":[{"bpm":120,"position":0}]},
       "tracks":[{"channel":{"inserts":[],"instrument":{"generalMIDI":{"program":0}},"isMuted":false,"isSoloed":false,"pan":0,"volume":0},
         "color":"green","id":"6F9E2B9C-3B1F-4E4A-9A8D-2B7C5E1D0A11","isRecordArmed":false,"kind":"softwareInstrument","name":"Inst 1","regions":[]}]}
      """#.utf8)
    let project = try ProjectArchive.decode(version1)
    #expect(project.masterVolume == 0)
    #expect(project.tracks.first?.channel.sends.isEmpty == true)
    #expect(project.tracks.first?.channel.audioInput == nil)
    #expect(project.tracks.first?.automation.isEmpty == true)
    #expect(project.tracks.first?.automationMode == .read)
    // Saved again, it's in the current format, so an older build won't drop what's new.
    let saved = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(saved.formatVersion == Project.currentFormatVersion)
  }

  @Test func currentProjectsRoundTrip() throws {
    var (project, keys, aux, _) = makeProject()
    try AddSend(Send(destinationTrackID: aux, isPreFader: true), from: keys).apply(to: &project)
    try AddInsert(BuiltInEffect.reverb.makeReference(), to: aux).apply(to: &project)
    project.masterVolume = -3
    #expect(try ProjectArchive.decode(ProjectArchive.encode(project)) == project)
    #expect(project.formatVersion == Project.currentFormatVersion)
  }
}
