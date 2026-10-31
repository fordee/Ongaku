//
//  FreezeTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Freezing tracks: what's locked while a track is frozen, and how playback hears it.
@MainActor
struct FreezeTests {
  private let freezeFile = AudioFileReference(fileName: "Freeze.caf", sampleRate: 48_000, channelCount: 2, frameCount: 96_000)

  /// An instrument track with a region and a compressor, and an aux.
  private func project() -> (Project, keys: Track.ID, aux: Track.ID) {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    let note = MIDINote(pitch: 60, velocity: 100, start: .zero, length: .quarterNotes(1))
    keys.regions = [Region(name: "Notes", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence(notes: [note])))]
    keys.channel.inserts = [BuiltInEffect.compressor.makeReference()]
    let aux = Track(name: "Aux", kind: .aux)
    return (Project(tracks: [keys, aux]), keys.id, aux.id)
  }

  private func frozenEditor(mode: FreezeMode = .preFader) throws -> (ProjectEditor, keys: Track.ID) {
    var (project, keys, _) = project()
    project.tracks[0].freezeMode = mode
    project.tracks[0].isRecordArmed = true
    let editor = ProjectEditor(project: project)
    try editor.perform(FreezeTrack(keys, file: freezeFile), undoManager: nil)
    return (editor, keys)
  }

  @Test func freezingRecordsTheFileAndDisarms() throws {
    let (editor, keys) = try frozenEditor()
    let track = try #require(editor.project.track(withID: keys))
    #expect(track.isFrozen)
    #expect(track.freezeFile == freezeFile)
    #expect(!track.isRecordArmed)
  }

  @Test func auxTracksCantBeFrozen() {
    var (project, _, aux) = project()
    #expect(throws: EditError.self) { try FreezeTrack(aux, file: freezeFile).apply(to: &project) }
  }

  @Test func frozenRegionsCantBeEdited() throws {
    let (editor, keys) = try frozenEditor()
    let region = try #require(editor.project.track(withID: keys)?.regions.first)
    #expect(throws: EditError.self) { try editor.perform(MoveRegion(region.id, to: .quarterNotes(1)), undoManager: nil) }
    #expect(throws: EditError.self) { try editor.perform(DeleteRegions([region.id]), undoManager: nil) }
    #expect(editor.project.track(withID: keys)?.regions.first == region)
  }

  @Test func frozenPluginsAreLocked() throws {
    let (editor, keys) = try frozenEditor()
    var channel = try #require(editor.project.track(withID: keys)?.channel)
    channel.instrument = .generalMIDI(program: 5)
    #expect(throws: EditError.self) { try editor.perform(SetChannelStrip(keys, to: channel), undoManager: nil) }
    channel = try #require(editor.project.track(withID: keys)?.channel)
    channel.inserts = []
    #expect(throws: EditError.self) { try editor.perform(SetChannelStrip(keys, to: channel), undoManager: nil) }
    #expect(throws: EditError.self) { try editor.perform(SetFreezeMode(keys, to: .sourceOnly), undoManager: nil) }
  }

  @Test func frozenTracksCanStillBeMixed() throws {
    let (editor, keys) = try frozenEditor()
    var channel = try #require(editor.project.track(withID: keys)?.channel)
    channel.volume = -12
    channel.pan = 0.5
    channel.isMuted = true
    try editor.perform(SetChannelStrip(keys, to: channel), undoManager: nil)
    try editor.perform(RenameTrack(keys, to: "Frozen Keys"), undoManager: nil)
    #expect(editor.project.track(withID: keys)?.channel.volume == -12)
  }

  @Test func sourceOnlyFreezesLeaveTheInsertsEditable() throws {
    let (editor, keys) = try frozenEditor(mode: .sourceOnly)
    var channel = try #require(editor.project.track(withID: keys)?.channel)
    channel.inserts = []
    try editor.perform(SetChannelStrip(keys, to: channel), undoManager: nil)
    #expect(editor.project.track(withID: keys)?.channel.inserts.isEmpty == true)
  }

  @Test func unfreezingAllowsEditsAgain() throws {
    let (editor, keys) = try frozenEditor()
    try editor.perform(UnfreezeTrack(keys), undoManager: nil)
    let region = try #require(editor.project.track(withID: keys)?.regions.first)
    try editor.perform(MoveRegion(region.id, to: .quarterNotes(1)), undoManager: nil)
    #expect(editor.project.track(withID: keys)?.regions.first?.start == .quarterNotes(1))
    #expect(editor.project.track(withID: keys)?.isFrozen == false)
  }

  @Test func freezingKeepsTheRenderedPluginSettings() throws {
    var (project, keys, _) = project()
    var rendered = project.tracks[0].channel
    rendered.inserts[0].state = Data([1, 2, 3])
    try FreezeTrack(keys, file: freezeFile, renderedChannel: rendered).apply(to: &project)
    #expect(project.tracks[0].channel.inserts[0].state == Data([1, 2, 3]))
  }

  // MARK: - Playback

  @Test func frozenTracksPlayTheirFreezeFile() throws {
    let (editor, keys) = try frozenEditor()
    let played = editor.project.playingFreezeFiles()
    let track = try #require(played.track(withID: keys))
    #expect(track.kind == .audio)
    #expect(track.channel.instrument == nil)
    #expect(track.channel.inserts.isEmpty, "Pre Fader: the inserts are in the file")
    #expect(track.regions.count == 1)
    #expect(track.regions[0].start == .zero)
    // 96 000 frames at 48 kHz is 2 s: four beats at 120 BPM.
    #expect(track.regions[0].length == .quarterNotes(4))
    #expect(played.audioFile(withID: freezeFile.id) == freezeFile)

    let plan = PlaybackPlan(project: played, startPosition: .zero)
    #expect(plan.midiEvents(in: 0..<10).isEmpty, "The instrument isn't played")
    let segments = plan.audioSegments(startingIn: 0..<10)
    #expect(segments.count == 1)
    #expect(segments.first?.fileID == freezeFile.id)
    #expect(segments.first?.frameCount == 96_000)
  }

  @Test func sourceOnlyFreezesKeepTheInsertsRunning() throws {
    let (editor, keys) = try frozenEditor(mode: .sourceOnly)
    let track = try #require(editor.project.playingFreezeFiles().track(withID: keys))
    #expect(track.channel.inserts.count == 1)
  }

  @Test func missingFreezeFilesLeaveTheTrackPlayingNormally() throws {
    let (editor, keys) = try frozenEditor()
    let track = try #require(editor.project.playingFreezeFiles { _ in false }.track(withID: keys))
    #expect(track.kind == .softwareInstrument)
    #expect(track.channel.instrument != nil)
  }

  @Test func frozenTracksAreSaved() throws {
    let (editor, keys) = try frozenEditor(mode: .sourceOnly)
    let reopened = try ProjectArchive.decode(ProjectArchive.encode(editor.project))
    #expect(reopened.track(withID: keys)?.freezeFile == freezeFile)
    #expect(reopened.track(withID: keys)?.freezeMode == .sourceOnly)
  }
}
