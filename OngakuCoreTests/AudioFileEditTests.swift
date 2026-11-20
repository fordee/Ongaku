//
//  AudioFileEditTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// The Audio File Editor's functions, and swapping an edited file in.
struct AudioFileEditTests {
  private func apply(_ edit: AudioFileEdit, to samples: [Float], frames: Range<Int>) -> [Float] {
    var channels = [samples]
    edit.apply(to: &channels, frames: frames)
    return channels[0]
  }

  @Test func eachFunctionChangesOnlyTheSelection() {
    let ramp: [Float] = [0.1, 0.2, -0.4, 0.25, 0.5]
    #expect(apply(.reverse, to: ramp, frames: 1..<4) == [0.1, 0.25, -0.4, 0.2, 0.5])
    #expect(apply(.invert, to: ramp, frames: 0..<2) == [-0.1, -0.2, -0.4, 0.25, 0.5])
    #expect(apply(.silence, to: ramp, frames: 3..<9) == [0.1, 0.2, -0.4, 0, 0], "A selection past the end stops there")
    #expect(apply(.fadeIn, to: [1, 1, 1, 1], frames: 0..<4) == [0, 0.25, 0.5, 0.75])
    #expect(apply(.fadeOut, to: [1, 1, 1, 1], frames: 0..<4) == [1, 0.75, 0.5, 0.25])
    let louder = apply(.gain(6.0206), to: ramp, frames: 0..<5)
    #expect(abs(louder[4] - 1) < 0.0001)
  }

  @Test func normalizeBringsTheLoudestChannelToThePeak() {
    var channels: [[Float]] = [[0.1, -0.25], [0.05, 0.2]]
    AudioFileEdit.normalize(peak: 0).apply(to: &channels, frames: 0..<2)
    #expect(channels == [[0.4, -1], [0.2, 0.8]], "Both channels by the same gain")
    var silent: [[Float]] = [[0, 0]]
    AudioFileEdit.normalize(peak: 0).apply(to: &silent, frames: 0..<2)
    #expect(silent == [[0, 0]])
  }

  @Test func removingDCOffsetCentresEachChannel() {
    var channels: [[Float]] = [[0.5, 0.7, 0.3], [-0.2, -0.2, -0.2]]
    AudioFileEdit.removeDCOffset.apply(to: &channels, frames: 0..<3)
    #expect(channels[0].map { ($0 * 1000).rounded() / 1000 } == [0, 0.2, -0.2])
    #expect(channels[1] == [0, 0, 0])
  }

  @MainActor @Test func theEditedFileReplacesTheOriginalEverywhere() throws {
    let file = AudioFileReference(fileName: "Vox.caf", sampleRate: 48_000, channelCount: 1, frameCount: 96_000)
    let other = AudioFileReference(fileName: "Gtr.caf", sampleRate: 48_000, channelCount: 1, frameCount: 96_000)
    let audio = RegionContent.audio(AudioRegionContent(fileID: file.id, fileStartFrame: 100, gain: -3))
    var folder = Region(name: "Takes", start: .quarterNotes(8), length: .quarterNotes(4), content: audio)
    let takes = [Take(name: "Take 1", content: audio), Take(name: "Take 2", content: .audio(AudioRegionContent(fileID: other.id)))]
    folder.takeFolder = TakeFolder(takes: takes, comp: [CompSection(start: .zero, end: .quarterNotes(4), takeID: takes[0].id)])
    let plain = Region(name: "Vox", start: .zero, length: .quarterNotes(4), content: audio)
    let editor = ProjectEditor(project: Project(
      tracks: [Track(name: "Vox", kind: .audio, regions: [plain, folder])], audioFiles: [file, other]))
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false

    let edited = AudioFileReference(fileName: "Vox Edit.caf", sampleRate: 48_000, channelCount: 1, frameCount: 96_000)
    undoManager.beginUndoGrouping()
    try editor.perform(ReplaceAudioFile(file.id, with: edited, actionName: "Reverse"), undoManager: undoManager)
    undoManager.endUndoGrouping()
    let regions = editor.project.tracks[0].regions
    #expect(regions[0].content == .audio(AudioRegionContent(fileID: edited.id, fileStartFrame: 100, gain: -3)), "Only the file changes")
    #expect(regions[1].takeFolder?.takes.map(\.content) == [regions[0].content, takes[1].content])
    #expect(editor.project.audioFiles.map(\.id) == [other.id, edited.id])
    #expect(undoManager.undoActionName == "Reverse")

    undoManager.undo()
    #expect(editor.project.tracks[0].regions == [plain, folder])

    let shorter = AudioFileReference(fileName: "Short.caf", sampleRate: 48_000, channelCount: 1, frameCount: 10)
    #expect(throws: EditError.self) { try editor.perform(ReplaceAudioFile(file.id, with: shorter, actionName: "Trim"), undoManager: nil) }
  }
}
