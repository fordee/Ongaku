//
//  FlexPitchWindowTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
@testable import Ongaku
import Testing

/// Flex Pitch in the window: opening the editor, retuning and correcting notes, and the
/// retuned audio being rendered.
@MainActor
@Suite(.serialized)
struct FlexPitchWindowTests {
  private let notes = [
    DetectedNote(start: 0.1, end: 0.6, pitch: 64.2), DetectedNote(start: 0.7, end: 1.1, pitch: 62.9),
  ]

  /// A window with an audio region on a Flex Pitch track, its notes already found.
  private func window() -> (ProjectWindowModel, Region) {
    let file = AudioFileReference(fileName: "Vocal.caf", sampleRate: 48_000, channelCount: 1, frameCount: 96_000)
    let region = Region(name: "Vocal", start: .zero, length: .quarterNotes(4), content: .audio(AudioRegionContent(fileID: file.id)))
    let track = Track(name: "Vocal", kind: .audio, regions: [region], flexMode: .pitch)
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [track], audioFiles: [file])))
    if let key = window.detectedNotesKey(for: region) { window.detectedNotes[key] = notes }
    return (window, region)
  }

  private func edits(_ window: ProjectWindowModel, _ region: Region) -> [PitchEdit] {
    guard case .audio(let audio) = window.project.region(withID: region.id)?.content else { return [] }
    return audio.pitchEdits
  }

  @Test func flexPitchRegionsOpenInTheirEditor() {
    let (window, region) = window()
    window.openEditor(for: region.id)
    #expect(window.editorRegionID == region.id)
    #expect(window.pianoRoll.availableEditors == [.pitch])
    #expect(window.pianoRoll.shownEditor == .pitch)
  }

  @Test func theEKeyOpensAFlexPitchRegionAsDoubleClickingDoes() {
    let (window, region) = window()
    window.select(region.id, extending: false)
    window.toggleEditor()
    #expect(window.isEditorVisible)
    #expect(window.editorRegionID == region.id)
    #expect(window.pianoRoll.shownEditor == .pitch)
  }

  @Test func notesAreRetunedAndReset() {
    let (window, region) = window()
    window.retune(notes[0], in: region.id, by: 2)
    #expect(edits(window, region).map(\.semitones) == [2])
    window.retune(notes[0], in: region.id, by: -1)
    #expect(edits(window, region).map(\.semitones) == [-1], "Moving it again replaces the edit")
    window.retune(notes[0], in: region.id, by: 0)
    #expect(edits(window, region).isEmpty)
  }

  @Test func correctPitchMovesEveryNoteToItsSemitone() {
    let (window, region) = window()
    window.correctPitch(of: region.id)
    let corrections = edits(window, region).map(\.semitones)
    #expect(corrections.count == 2)
    #expect(abs(corrections[0] + 0.2) < 1e-9)
    #expect(abs(corrections[1] - 0.1) < 1e-9)
  }

  @Test func retunedAudioIsRendered() async throws {
    // A real file: one second of A4 with harmonics.
    let folder = FileManager.default.temporaryDirectory.appending(path: "FlexPitchWindowTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: "Vocal.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
    buffer.frameLength = 96_000
    for index in 0..<96_000 {
      let t = Double(index) / 48_000
      buffer.floatChannelData![0][index] = Float(0.4 * sin(2 * .pi * 440 * t) + 0.2 * sin(4 * .pi * 440 * t))
    }
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)

    let document = OngakuDocument(project: Project(tracks: []))
    let window = ProjectWindowModel(document: document)
    let file = try await document.stageAudio(from: url)
    let region = Region(
      name: "Vocal", start: .zero, length: .quarterNotes(4),
      content: .audio(AudioRegionContent(fileID: file.id, pitchEdits: [PitchEdit(start: 0, end: 2, semitones: 2)])))
    window.perform(CompositeCommand("Setup", commands: [
      AddAudioFile(file), AddTrack(Track(name: "Vocal", kind: .audio, regions: [region], flexMode: .pitch)),
    ]))
    window.projectDidChange()
    for task in window.flexRenderTasks.values { await task.value }
    let render = try #require(window.flexRenders.values.first)
    let renderURL = try #require(document.url(for: render))
    let found = try await FlexAudio.notes(in: renderURL, from: 0, frames: 96_000)
    #expect(found.contains { abs($0.pitch - 71) < 0.2 }, "Two semitones up from A4 is B4: \(found.map(\.pitch))")
  }
}
