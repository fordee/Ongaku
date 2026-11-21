//
//  ScoreEditorTests.swift
//  OngakuTests
//

import CoreGraphics
import Foundation
import OngakuCore
import OngakuEngine
import PDFKit
@testable import Ongaku
import Testing

/// The Score editor: writing, moving and erasing notes in notation, and placing them on the page.
@MainActor
struct ScoreEditorTests {
  private let window: ProjectWindowModel
  private let undoManager = UndoManager()
  private let quarter = Tick(960)

  /// A bar of C, E, G quarters (and a rest) in F major, transposed up a tone by the region.
  init() {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    let notes = [60, 64, 67].enumerated().map { index, pitch in
      MIDINote(pitch: pitch, velocity: 90, start: Tick(960) * Int64(index), length: Tick(960))
    }
    let region = Region(name: "Tune", start: Tick(3840), length: Tick(3840), content: .midi(MIDISequence(notes: notes)), transpose: 2)
    keys.regions = [region]
    var project = Project(tracks: [keys])
    project.keySignature = KeySignature(tonic: 5, mode: .major)
    window = ProjectWindowModel(document: OngakuDocument(project: project))
    undoManager.groupsByEvent = false
    window.undoManager = undoManager
    window.openEditor(for: region.id)
    window.pianoRoll.editorKind = .score
  }

  private var editor: PianoRollModel { window.pianoRoll }

  /// Makes an edit as one undo step. (The undo manager doesn't group by event in tests, so
  /// every edit needs a group of its own, or registering its undo throws.)
  private func edit(_ change: () -> Void) {
    undoManager.beginUndoGrouping()
    change()
    undoManager.endUndoGrouping()
  }

  @Test func midiRegionsOfferTheScore() {
    #expect(editor.availableEditors.contains(.score))
    #expect(editor.shownEditor == .score)
  }

  @Test func thePencilWritesTheChosenValueAtTheClickedPitch() throws {
    editor.scoreNoteValue = .eighth
    // Beat 4 of the region's bar, an A as played (the stored note is before the transpose).
    edit { editor.writeScoreNote(at: Tick(3840) + quarter * 3, pitch: 69) }
    let added = try #require(editor.notes.first { $0.start == quarter * 3 })
    #expect(added.pitch == 67 && added.length == Tick(480))
    #expect(editor.selectedNoteIDs == [added.id])
    #expect(undoManager.undoActionName == "Add Note")
  }

  @Test func draggingUpAStepFollowsTheKeysScale() throws {
    // In F major one step up from A (as played) is B♭, not B.
    let a = try #require(editor.notes.first { $0.pitch == 67 })
    editor.selectedNoteIDs = [a.id]
    edit { editor.moveScoreSelection(by: 0, diatonicSteps: 1, key: window.project.key(at: Tick(3840))) }
    #expect(editor.notes.first { $0.id == a.id }?.pitch == 68, "B♭ played, A♭ stored under the transpose")
    // And sideways by display-quantize steps.
    edit { editor.moveScoreSelection(by: 2, diatonicSteps: 0, key: window.project.key(at: Tick(3840))) }
    #expect(editor.notes.first { $0.id == a.id }?.start == quarter * 2 + editor.scoreOptions.quantize * 2)
  }

  @Test func theEraserDeletesANote() throws {
    let note = try #require(editor.notes.first)
    edit { editor.eraseScoreNote(note.id) }
    #expect(editor.notes.count == 2)
    undoManager.undo()
    #expect(editor.notes.count == 3)
  }

  @Test func staffPositionsMeanTheKeysNotes() {
    let fMajor = KeySignature(tonic: 5, mode: .major)
    // The B line in F major is B♭ (the middle line of the treble staff, B4 = 70).
    #expect(ScorePitch.pitch(diatonic: ScoreNote.diatonic(step: 6, octave: 4), in: fMajor) == 70)
    #expect(ScorePitch.pitch(diatonic: ScoreNote.diatonic(step: 0, octave: 4), in: fMajor) == 60)
    #expect(ScorePitch.drum(diatonic: ScoreNote.diatonic(step: 0, octave: 5)) == 38, "The snare's space")
  }

  @Test func theEngraverPutsEveryNoteOnThePageInOrder() throws {
    let region = try #require(editor.region)
    let score = EngravedScore(layout: editor.scoreLayout(for: region), width: 900)
    let heads = score.placedHeads
    #expect(heads.count == 3)
    #expect(heads.map(\.center.x) == heads.map(\.center.x).sorted())
    // Higher notes are higher on the staff (smaller y).
    let ys = heads.sorted { $0.note.pitch < $1.note.pitch }.map(\.center.y)
    #expect(ys == ys.sorted(by: >))
    // A click on a head finds it; a position maps back to its bar.
    let first = heads[0]
    let place = try #require(score.locate(first.center))
    #expect(score.systems[place.system].measures[place.measure].measure.start == Tick(3840))
  }

  @Test func theScorePrintsOnPagesAndLongPartsRunOn() throws {
    let region = try #require(editor.region)
    let short = ScorePDF.data(layout: editor.scoreLayout(for: region), title: "Song", subtitle: "Keys", pageSize: CGSize(width: 595, height: 842))
    #expect(PDFDocument(data: short)?.pageCount == 1)

    // Sixty-four bars of eighths need more than one page.
    let notes = (0..<512).map { MIDINote(pitch: 60 + $0 % 12, velocity: 90, start: Tick(480) * Int64($0), length: Tick(480)) }
    let long = Region(name: "Long", start: .zero, length: Tick(3840 * 64), content: .midi(MIDISequence(notes: notes)))
    let data = ScorePDF.data(layout: ScoreLayout(region: long, in: window.project), title: "Song", subtitle: "Keys", pageSize: CGSize(width: 595, height: 842))
    let document = try #require(PDFDocument(data: data))
    #expect(document.pageCount > 1)
    try? short.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "ongaku-score-test.pdf"))
    print("SCOREPDF \(NSTemporaryDirectory())ongaku-score-test.pdf")
  }
}
