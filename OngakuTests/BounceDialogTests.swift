//
//  BounceDialogTests.swift
//  OngakuTests
//

import AVFAudio
import AudioToolbox
import Foundation
import OngakuCore
import OngakuEngine
@testable import Ongaku
import Testing

/// The Bounce dialog's model, driven the way the dialog's buttons drive it.
@MainActor
@Suite(.serialized)
struct BounceDialogTests {
  private func makeWindow(regions: Bool = true) -> ProjectWindowModel {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 0)
    if regions {
      let note = MIDINote(pitch: 60, start: .zero, length: .quarterNotes(1))
      keys.regions = [Region(name: "Notes", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence(notes: [note])))]
    }
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [keys])))
    return window
  }

  private func waitUntilFinished(_ bounce: BounceModel) async throws -> BounceResult {
    for _ in 0..<200 {
      if case .finished(let result) = bounce.phase { return result }
      try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("The bounce didn't finish")
    throw CancellationError()
  }

  @Test func bouncingRendersAFileAndDiscardingRemovesIt() async throws {
    let window = makeWindow()
    defer { window.engine.shutDown() }
    window.showBounce()
    let bounce = try #require(window.bounce)
    #expect(bounce.range == .zero..<Tick.quarterNotes(4))
    #expect(window.describeBounceRange(bounce.range) == "bar 1 to bar 2")

    bounce.settings = BounceSettings(format: .aiff, bitDepth: .sixteen, includeTail: false)
    window.startBounce()
    let result = try await waitUntilFinished(bounce)
    #expect(FileManager.default.fileExists(atPath: result.url.path))
    #expect(result.url.pathExtension == "aiff")
    #expect(abs(result.duration - 2) < 0.001)
    #expect(result.peakDecibels > -40, "The piano note is in the bounce")

    window.closeBounce()
    #expect(window.bounce == nil)
    #expect(!FileManager.default.fileExists(atPath: result.url.path), "The temporary file is cleaned up")
  }

  @Test func settingsAreRememberedForTheNextBounce() throws {
    let window = makeWindow()
    defer { window.engine.shutDown() }
    window.showBounce()
    try #require(window.bounce).settings = BounceSettings(format: .m4a, normalize: true)
    window.closeBounce()

    window.showBounce()
    #expect(window.bounce?.settings.format == .m4a)
    #expect(window.bounce?.settings.normalize == true)
    window.bounce?.settings = BounceSettings()
    window.closeBounce()
  }

  @Test func emptyProjectsExplainWhyTheresNothingToBounce() {
    let window = makeWindow(regions: false)
    defer { window.engine.shutDown() }
    window.showBounce()
    #expect(window.bounce == nil)
    #expect(window.errorMessage?.contains("nothing to bounce") == true)
  }

  @Test func bouncingStopsPlayback() {
    let window = makeWindow()
    defer { window.engine.shutDown() }
    window.engine.play()
    window.showBounce()
    #expect(!window.engine.isPlaying)
    window.closeBounce()
  }

  /// Analyze Whole Song from the window: the song's Mastering takes what the offline listen
  /// found, as one step that Undo takes back.
  @Test func analyzeWholeSongSetsUpMasteringAndUndoes() async throws {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 0)
    // A chord on every beat for 24 seconds (12 bars at 120 BPM): plenty to go on.
    let notes = (0..<48).flatMap { (beat: Int) in
      [60, 64, 67].map { MIDINote(pitch: $0, velocity: 100, start: .quarterNotes(Double(beat)), length: .quarterNotes(1)) }
    }
    keys.regions = [Region(name: "Chords", start: .zero, length: .quarterNotes(48), content: .midi(MIDISequence(notes: notes)))]
    var project = Project(tracks: [keys])
    let mastering = OngakuEffect.mastering.makeReference()
    project.stereoOutInserts = [mastering]
    let window = ProjectWindowModel(document: OngakuDocument(project: project))
    defer { window.engine.shutDown() }
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    window.undoManager = undoManager
    func measured() -> Float? {
      window.engine.withInsertAudioUnit(mastering.id, onTrack: Project.stereoOutID) {
        $0.parameterTree?.parameter(withAddress: OngakuEffect.MasteringParameter.measuredLoudness)?.value
      } ?? nil
    }
    for _ in 0..<200 where measured() == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(measured() == OngakuEffect.MasteringParameter.notMeasured)

    undoManager.beginUndoGrouping()
    window.analyzeSongForMastering()
    #expect(window.songAnalysis != nil, "The progress sheet shows")
    for _ in 0..<1200 where window.songAnalysis != nil {
      try await Task.sleep(for: .milliseconds(50))
    }
    undoManager.endUndoGrouping()
    #expect(window.songAnalysis == nil)
    #expect(window.errorMessage == nil)
    #expect(undoManager.undoActionName == "Analyze Whole Song")
    // The window's view does this after every change.
    window.projectDidChange()
    let analysed = try #require(measured())
    #expect(analysed > -40 && analysed < 0, "The live Mastering knows the song's loudness (\(analysed) LUFS)")

    undoManager.undo()
    window.projectDidChange()
    #expect(measured() == OngakuEffect.MasteringParameter.notMeasured, "Undo puts the settings back")
  }
}

/// Bounce in Place and Export All Tracks, driven as their dialogs drive them.
@MainActor
@Suite(.serialized)
struct TrackBounceTests {
  private func makeWindow() -> ProjectWindowModel {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 0)
    let note = MIDINote(pitch: 60, start: .zero, length: .quarterNotes(1))
    keys.regions = [Region(name: "Notes", start: .quarterNotes(4), length: .quarterNotes(4), content: .midi(MIDISequence(notes: [note])))]
    var bass = Track(name: "Bass/Low", kind: .softwareInstrument)
    bass.channel.instrument = .generalMIDI(program: 33)
    bass.regions = [Region(name: "Line", start: .zero, length: .quarterNotes(8), content: .midi(MIDISequence(notes: [note])))]
    return ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [keys, bass, Track(name: "Verb", kind: .aux)])))
  }

  @Test func bounceInPlacePutsTheRenderOnANewTrackAndUndoes() async throws {
    let window = makeWindow()
    defer { window.engine.shutDown() }
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    window.undoManager = undoManager
    let keys = window.project.tracks[0]
    window.selectedRegionIDs = [keys.regions[0].id]
    window.showBounceInPlace()
    let dialog = try #require(window.bounceInPlace)
    dialog.source = .mute
    undoManager.beginUndoGrouping()
    let task = window.startBounceInPlace()
    #expect(window.startBounceInPlace() == nil, "Pressing Bounce again while it renders does nothing")
    await task?.value
    undoManager.endUndoGrouping()
    #expect(window.errorMessage == nil)
    #expect(window.bounceInPlace == nil, "The dialog closes")
    #expect(window.project.tracks.map(\.name) == ["Keys", "Keys Bounce", "Bass/Low", "Verb"])
    let bounced = try #require(window.project.tracks[1].regions.first)
    #expect(bounced.start == .quarterNotes(4))
    guard case .audio(let audio) = bounced.content, let file = window.project.audioFile(withID: audio.fileID) else {
      Issue.record("The bounce is an audio region")
      return
    }
    #expect(file.fileName == "Keys Bounce.caf" && file.duration > 2, "The bar, and the piano's tail")
    #expect(window.project.tracks[0].regions[0].isMuted)
    #expect(window.selectedTrackID == window.project.tracks[1].id)

    undoManager.undo()
    #expect(window.project.tracks.count == 3 && window.project.audioFiles.isEmpty)
    #expect(!window.project.tracks[0].regions[0].isMuted)
    dialog.source = .mute
  }

  @Test func exportAllTracksMakesAFileForEachTrack() async throws {
    let window = makeWindow()
    defer { window.engine.shutDown() }
    window.showExportAllTracks()
    let bounce = try #require(window.bounce)
    #expect(bounce.target == .allTracks)
    bounce.settings = BounceSettings(format: .wav, bitDepth: .sixteen, includeTail: false)
    window.startBounce()
    var files: [URL] = []
    for _ in 0..<400 {
      if case .finishedTracks(_, let made) = bounce.phase { files = made; break }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(files.map(\.lastPathComponent) == ["01 Keys.wav", "02 Bass-Low.wav"], "Aux tracks have nothing of their own to export")
    for file in files {
      let length = try AVAudioFile(forReading: file).length
      #expect(abs(Double(length) / 48_000 - 4) < 0.05 || abs(Double(length) / 44_100 - 4) < 0.05, "Every file runs the whole song, so they line up")
    }
    window.closeBounce()
    #expect(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
  }
}
