//
//  BounceDialogTests.swift
//  OngakuTests
//

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
