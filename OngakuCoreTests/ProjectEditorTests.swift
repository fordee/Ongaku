//
//  ProjectEditorTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

@MainActor
struct ProjectEditorTests {
  /// An undo manager that groups explicitly, since tests have no run loop to close groups.
  private func makeUndoManager() -> UndoManager {
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    return undoManager
  }

  private func perform(_ command: some EditCommand, on editor: ProjectEditor, undoManager: UndoManager) throws {
    undoManager.beginUndoGrouping()
    defer { undoManager.endUndoGrouping() }
    try editor.perform(command, undoManager: undoManager)
  }

  @Test func undoAndRedoRestoreProjectSnapshots() throws {
    let editor = ProjectEditor(project: Project())
    let undoManager = makeUndoManager()
    let track = Track(name: "Inst 1", kind: .softwareInstrument)

    try perform(AddTrack(track), on: editor, undoManager: undoManager)
    try perform(RenameTrack(track.id, to: "Piano"), on: editor, undoManager: undoManager)
    #expect(undoManager.undoActionName == "Rename Track")

    undoManager.undo()
    #expect(editor.project.tracks.map(\.name) == ["Inst 1"])

    undoManager.undo()
    #expect(editor.project.tracks.isEmpty)

    undoManager.redo()
    undoManager.redo()
    #expect(editor.project.tracks.map(\.name) == ["Piano"])
    #expect(undoManager.canRedo == false)
  }

  @Test func failedCommandsChangeNothing() throws {
    let editor = ProjectEditor(project: Project())
    let undoManager = makeUndoManager()
    let track = Track(name: "Inst 1", kind: .softwareInstrument)
    let before = editor.project

    // The first step succeeds and the second fails; neither may stick. No undo group is
    // opened here because even an empty group counts as undoable.
    let command = CompositeCommand("Broken", commands: [AddTrack(track), RenameTrack(UUID(), to: "Nope")])
    #expect(throws: EditError.self) {
      try editor.perform(command, undoManager: undoManager)
    }
    #expect(editor.project == before)
    #expect(undoManager.canUndo == false)
  }

  @Test func loadingDoesNotCreateAnUndoStep() {
    let editor = ProjectEditor(project: Project())
    let undoManager = makeUndoManager()
    editor.load(.newDefault())
    #expect(editor.project.tracks.count == 1)
    #expect(undoManager.canUndo == false)
  }

  @Test func theSongGrowsPastItsLastRegion() throws {
    let track = Track(name: "Keys", kind: .softwareInstrument)
    let editor = ProjectEditor(project: Project(tracks: [track]))
    let undoManager = makeUndoManager()
    let bar = Tick.quarterNotes(4)
    let defaultEnd = editor.project.endPosition
    #expect(defaultEnd == bar * 128)

    // A region well inside the song leaves the end alone.
    let early = Region(name: "Early", start: bar * 10, length: bar, content: .midi(MIDISequence()))
    try perform(AddRegion(early, to: track.id), on: editor, undoManager: undoManager)
    #expect(editor.project.endPosition == defaultEnd)

    // One moved to bar 130 (index 129) takes the end to 8 bars past its bar.
    try perform(MoveRegion(early.id, to: bar * 129), on: editor, undoManager: undoManager)
    #expect(editor.project.endPosition == bar * (130 + 8))

    // A loop counts to where its repeats stop.
    try perform(SetRegionLoop(early.id, to: bar * 200), on: editor, undoManager: undoManager)
    #expect(editor.project.endPosition == bar * (200 + 8))

    // Undo takes the end back with the edit.
    undoManager.undo()
    #expect(editor.project.endPosition == bar * 138)
  }
}
