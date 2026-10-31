//
//  TakesEditorTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
@testable import Ongaku
import Testing

/// Take folders in the window: opening them and choosing editors.
@MainActor
struct TakesEditorTests {
  private let bar = Tick.quarterNotes(4)

  private func window(audio: Bool) -> (ProjectWindowModel, Region) {
    let file = AudioFileReference(fileName: "Takes.caf", sampleRate: 48_000, channelCount: 2, frameCount: 480_000)
    let contents: [RegionContent] = audio
      ? [.audio(AudioRegionContent(fileID: file.id)), .audio(AudioRegionContent(fileID: file.id, fileStartFrame: 192_000))]
      : [.midi(MIDISequence()), .midi(MIDISequence())]
    let takes = contents.enumerated().map { Take(name: "Take \($0.offset + 1)", content: $0.element) }
    let region = Region(
      name: "Part", start: .zero, length: bar * 2, content: takes[1].content,
      takeFolder: TakeFolder(takes: takes, playing: takes[1].id, length: bar * 2))
    let track = Track(name: "Part", kind: audio ? .audio : .softwareInstrument, regions: [region])
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [track], audioFiles: [file])))
    return (window, region)
  }

  @Test func audioTakeFoldersOpenInTheTakesEditor() {
    let (window, region) = window(audio: true)
    window.openEditor(for: region.id)
    #expect(window.editorRegionID == region.id)
    #expect(window.pianoRoll.availableEditors == [.takes])
    #expect(window.pianoRoll.shownEditor == .takes)
  }

  @Test func midiTakeFoldersOpenInTakesFirst() {
    let (window, region) = window(audio: false)
    window.pianoRoll.editorKind = .pianoRoll
    window.openEditor(for: region.id)
    #expect(window.pianoRoll.availableEditors == [.takes, .pianoRoll, .stepEditor])
    #expect(window.pianoRoll.shownEditor == .takes)
    window.pianoRoll.editorKind = .pianoRoll
    #expect(window.pianoRoll.shownEditor == .pianoRoll)
    #expect(window.pianoRoll.editedTake?.name == "Take 2", "The Piano Roll edits the take starting the comp")
  }

  @Test func takesCanBeRenamedAndDeletedWithUndo() throws {
    let (window, region) = window(audio: false)
    let undoManager = UndoManager()
    // Tests have no run loop to close undo groups, so each edit gets its own.
    undoManager.groupsByEvent = false
    window.undoManager = undoManager
    let takes = try #require(region.takeFolder?.takes)
    func edit(_ command: any EditCommand) {
      undoManager.beginUndoGrouping()
      window.perform(command)
      undoManager.endUndoGrouping()
    }

    edit(RenameTake(takes[0].id, in: region.id, to: "  Best verse "))
    #expect(window.project.region(withID: region.id)?.takeFolder?.takes.first?.name == "Best verse")
    #expect(undoManager.undoActionName == "Rename Take")
    undoManager.undo()
    #expect(window.project.region(withID: region.id)?.takeFolder?.takes.first?.name == "Take 1")

    // Deleting one of two takes leaves a plain region playing the other.
    edit(DeleteTake(takes[1].id, from: region.id))
    let plain = try #require(window.project.region(withID: region.id))
    #expect(plain.takeFolder == nil && plain.content == takes[0].content)
    undoManager.undo()
    #expect(window.project.region(withID: region.id)?.takeFolder?.takes.count == 2)
  }

  @Test func plainAudioRegionsDontOpenTheEditor() {
    let file = AudioFileReference(fileName: "One.caf", sampleRate: 48_000, channelCount: 2, frameCount: 48_000)
    let region = Region(name: "One", start: .zero, length: bar, content: .audio(AudioRegionContent(fileID: file.id)))
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(
      tracks: [Track(name: "Audio", kind: .audio, regions: [region])], audioFiles: [file])))
    window.openEditor(for: region.id)
    #expect(window.editorRegionID == nil)
  }

  @Test func swipingCompsAndFlattening() throws {
    let (window, region) = window(audio: true)
    let takes = try #require(region.takeFolder?.takes)
    window.perform(CompTake(takes[0].id, over: bar..<(bar * 2), in: region.id))
    #expect(window.project.region(withID: region.id)?.takeFolder?.comp.map(\.takeID) == [takes[1].id, takes[0].id])
    window.perform(FlattenTakeFolder(region.id))
    #expect(window.project.tracks[0].regions.allSatisfy { $0.takeFolder == nil })
  }
}
