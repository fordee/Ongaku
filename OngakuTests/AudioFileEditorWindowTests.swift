//
//  AudioFileEditorWindowTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
@testable import Ongaku
import Testing

/// The Audio File Editor in the window: a function writes an edited copy of the file and
/// every region plays it, with undo.
@MainActor
@Suite(.serialized)
struct AudioFileEditorWindowTests {
  @Test func functionsEditTheFileForEveryRegionAndUndo() async throws {
    // A real file: a rising ramp, so reversing it is easy to see.
    let folder = FileManager.default.temporaryDirectory.appending(path: "AudioFileEditorWindowTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: "Vox.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
    buffer.frameLength = 48_000
    for index in 0..<48_000 { buffer.floatChannelData![0][index] = Float(index) / 48_000 }
    let source = try AVAudioFile(forWriting: url, settings: format.settings)
    try source.write(from: buffer)
    source.close()

    let document = OngakuDocument(project: Project(tracks: []))
    let window = ProjectWindowModel(document: document)
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    window.undoManager = undoManager
    let file = try await document.stageAudio(from: url)
    let first = Region.audio(for: file, at: .zero, tempoMap: window.project.tempoMap)
    let second = Region.audio(for: file, at: .quarterNotes(8), tempoMap: window.project.tempoMap)
    undoManager.beginUndoGrouping()
    window.perform(CompositeCommand("Setup", commands: [AddAudioFile(file), AddTrack(Track(name: "Vox", kind: .audio, regions: [first, second]))]))
    undoManager.endUndoGrouping()

    window.openEditor(for: first.id)
    #expect(window.pianoRoll.shownEditor == .audioFile)

    // Reverse the second half.
    undoManager.beginUndoGrouping()
    await window.editAudioFile(of: first.id, .reverse, frames: 24_000..<48_000)?.value
    undoManager.endUndoGrouping()
    #expect(window.errorMessage == nil)
    let edited = try #require(window.project.audioFiles.first)
    #expect(edited.id != file.id && edited.fileName == "Vox Edit.caf" && edited.frameCount == 48_000)
    for region in [first, second] {
      guard case .audio(let audio) = window.project.region(withID: region.id)?.content else { Issue.record(); continue }
      #expect(audio.fileID == edited.id)
    }
    let (channels, _) = try FlexAudio.read(try #require(document.url(for: edited)), from: 0, frames: 48_000)
    #expect(abs(channels[0][1_000] - Float(1_000) / 48_000) < 1e-6, "The first half is as it was")
    #expect(abs(channels[0][24_000] - Float(47_999) / 48_000) < 1e-6, "The second half runs backwards")
    #expect(undoManager.undoActionName == "Reverse")

    // A second edit is named after the first.
    undoManager.beginUndoGrouping()
    await window.editAudioFile(of: first.id, .invert, frames: nil)?.value
    undoManager.endUndoGrouping()
    #expect(window.project.audioFiles.map(\.fileName) == ["Vox Edit 2.caf"])

    undoManager.undo()
    undoManager.undo()
    #expect(window.project.audioFiles.map(\.id) == [file.id])
    guard case .audio(let restored) = window.project.region(withID: second.id)?.content else { Issue.record(); return }
    #expect(restored.fileID == file.id)
  }
}
