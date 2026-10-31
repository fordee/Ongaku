//
//  MIDIDrawTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
import OngakuEngine
@testable import Ongaku
import Testing

/// Editing velocity, controllers, pitch bend and aftertouch in the piano roll's MIDI Draw
/// lane, through the model the lane's gestures drive.
@MainActor
struct MIDIDrawTests {
  private let window: ProjectWindowModel
  private let regionID: Region.ID

  init() {
    let notes = [
      MIDINote(pitch: 60, velocity: 100, channel: 3, start: .zero, length: Tick(960)),
      MIDINote(pitch: 64, velocity: 80, channel: 3, start: Tick(960), length: Tick(960)),
      MIDINote(pitch: 67, velocity: 60, channel: 3, start: Tick(1920), length: Tick(960)),
    ]
    let controls = [MIDIControlEvent(kind: .volume, channel: 3, position: Tick(480), value: 90)]
    let region = Region(name: "Riff", start: .zero, length: Tick(3840), content: .midi(MIDISequence(notes: notes, controls: controls)))
    regionID = region.id
    window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [
      Track(name: "Keys", kind: .softwareInstrument, regions: [region]),
    ])))
    window.openEditor(for: region.id)
  }

  private var pianoRoll: PianoRollModel { window.pianoRoll }

  @Test func draggingVelocityStalksChangesThemInOneStep() {
    pianoRoll.velocityPreview = [pianoRoll.notes[0].id: 40, pianoRoll.notes[1].id: 127]
    pianoRoll.commitVelocityPreview()
    #expect(pianoRoll.notes.map(\.velocity) == [40, 127, 60])
    #expect(pianoRoll.velocityPreview == nil)
    #expect(pianoRoll.newNoteVelocity == 127, "New notes follow the last velocity set, like Logic")
  }

  @Test func newPointsGoOnTheNotesChannel() {
    pianoRoll.midiDrawParameter = .control(.pitchBend)
    #expect(pianoRoll.drawnChannel == 3)
    pianoRoll.addControlPoint(at: Tick(1000), value: 9000)
    let bend = pianoRoll.controls.filter { $0.kind == .pitchBend }
    #expect(bend.map(\.channel) == [3])
    #expect(bend.map(\.value) == [8191], "Clamped to the pitch bend range")
    #expect(pianoRoll.selectedControlIDs == Set(bend.map(\.id)))
  }

  @Test func movingPointsKeepsThemInRange() {
    pianoRoll.midiDrawParameter = .control(.volume)
    let id = pianoRoll.controls[0].id
    let moved = pianoRoll.movedControls([id], by: Tick(-1000), valueOffset: 100)
    #expect(moved.map(\.position) == [.zero])
    #expect(moved.map(\.value) == [127])

    pianoRoll.controlPreview = .init(events: moved)
    #expect(pianoRoll.drawnControls.map(\.value) == [127], "The lane shows the drag before it's committed")
    pianoRoll.commitControlPreview()
    #expect(pianoRoll.controls.map(\.value) == [127])
  }

  @Test func strokesKeepOnlyChangesAndEndOnTheLastValue() {
    pianoRoll.midiDrawParameter = .control(.modulation)
    let samples: [(position: Tick, value: Int)] = [(Tick(0), 10), (Tick(10), 11), (Tick(40), 11), (Tick(80), 30), (Tick(90), 50)]
    let events = pianoRoll.strokeEvents(samples)
    // 10 ticks after the first sample is too soon for a new point; 90 is too, but it's
    // where the stroke ended, so its value is kept.
    #expect(events.map(\.position) == [Tick(0), Tick(40), Tick(80), Tick(90)])
    #expect(events.map(\.value) == [10, 11, 30, 50])
    #expect(events.allSatisfy { $0.kind == .modulation && $0.channel == 3 })
  }

  @Test func drawingReplacesWhatTheStrokeCovers() {
    pianoRoll.midiDrawParameter = .control(.volume)
    let stroke = pianoRoll.strokeEvents([(Tick(0), 20), (Tick(500), 40), (Tick(1000), 60)])
    pianoRoll.controlPreview = .init(events: stroke)
    pianoRoll.commitControlPreview(drawnOver: Tick(0)...Tick(1000))
    #expect(pianoRoll.controls.filter { $0.kind == .volume }.map(\.value) == [20, 40, 60], "The old point at 480 is gone")
  }

  @Test func deleteRemovesSelectedPointsBeforeNotes() {
    pianoRoll.midiDrawParameter = .control(.volume)
    pianoRoll.selectedNoteIDs = [pianoRoll.notes[0].id]
    pianoRoll.selectControl(pianoRoll.controls[0].id, extending: false)
    pianoRoll.deleteSelection()
    #expect(pianoRoll.controls.isEmpty)
    #expect(pianoRoll.notes.count == 3, "The notes stay")
  }

  @Test func polyAftertouchBelongsToTheSelectedNote() {
    pianoRoll.midiDrawParameter = .polyPressure
    #expect(pianoRoll.drawnKind == nil, "Nothing to edit without a note")
    pianoRoll.selectedNoteIDs = [pianoRoll.notes[1].id]
    #expect(pianoRoll.drawnKind == .polyPressure(pitch: 64))
    pianoRoll.addControlPoint(at: Tick(1200), value: 70)
    #expect(pianoRoll.drawnControls.map(\.value) == [70])
    pianoRoll.selectedNoteIDs = [pianoRoll.notes[2].id]
    #expect(pianoRoll.drawnControls.isEmpty, "Another note has its own aftertouch")
  }

  @Test func theMenuMarksParametersWithData() {
    #expect(pianoRoll.parametersInUse.contains(.control(.volume)))
    #expect(!pianoRoll.parametersInUse.contains(.control(.pan)))
  }
}

/// The Piano Roll's Logic-style editing: its tools, selecting, the clipboard, resizing and
/// its note functions, through the model its gestures and menus drive. (In this suite
/// because Xcode doesn't find new suites until it re-indexes.)
@MainActor
private final class EditingFixture {
  let window: ProjectWindowModel
  let regionID: Region.ID

  /// A two-bar region at bar 1: C, E and G a beat apart, then a long C.
  init() {
    let notes = [
      MIDINote(pitch: 60, velocity: 100, start: .zero, length: Tick(480)),
      MIDINote(pitch: 64, velocity: 90, start: Tick(960), length: Tick(480)),
      MIDINote(pitch: 67, velocity: 80, start: Tick(1920), length: Tick(480)),
      MIDINote(pitch: 60, velocity: 70, start: Tick(3840), length: Tick(1920)),
    ]
    let region = Region(name: "Riff", start: .zero, length: Tick(7680), content: .midi(MIDISequence(notes: notes)))
    regionID = region.id
    window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [
      Track(name: "Keys", kind: .softwareInstrument, regions: [region]),
    ])))
    window.openEditor(for: region.id)
    window.activeEditingArea = .pianoRoll
    window.pianoRoll.gridSetting = .sixteenth
  }

  var pianoRoll: PianoRollModel { window.pianoRoll }

  func note(pitch: Int, at start: Tick) -> MIDINote? {
    pianoRoll.notes.first { $0.pitch == pitch && $0.start == start }
  }
}

extension MIDIDrawTests {
  @Test func selectingByKeyRubberBandAndInverting() throws {
    let fixture = EditingFixture()
    fixture.pianoRoll.selectAll(pitch: 60, extending: false)
    #expect(fixture.pianoRoll.selectedNoteIDs.count == 2, "Clicking C3 selects both Cs")
    fixture.pianoRoll.selectNotes(over: Tick(900)..<Tick(2000), pitches: 62...70, extending: false)
    #expect(Set(fixture.pianoRoll.notes.filter { fixture.pianoRoll.selectedNoteIDs.contains($0.id) }.map(\.pitch)) == [64, 67])
    fixture.pianoRoll.invertSelection()
    #expect(fixture.pianoRoll.selectedNoteIDs.count == 2)
    fixture.pianoRoll.selectedNoteIDs = [try #require(fixture.note(pitch: 60, at: .zero)).id]
    fixture.pianoRoll.selectSamePitches()
    #expect(fixture.pianoRoll.selectedNoteIDs.count == 2)
  }

  @Test func eraserScissorsGlueMuteAndQuantizeTools() throws {
    let fixture = EditingFixture()
    let long = try #require(fixture.note(pitch: 60, at: Tick(3840)))
    fixture.pianoRoll.tool = .scissors
    #expect(fixture.pianoRoll.applyTool(to: long.id, at: Tick(4810)))
    #expect(fixture.note(pitch: 60, at: Tick(4800))?.length == Tick(960), "Split on the nearest sixteenth")
    #expect(fixture.pianoRoll.selectedNoteIDs.count == 2, "Both halves are selected")

    fixture.pianoRoll.tool = .glue
    #expect(fixture.pianoRoll.applyTool(to: long.id, at: Tick(3840)))
    #expect(fixture.note(pitch: 60, at: Tick(3840))?.length == Tick(1920), "Glued back together")

    fixture.pianoRoll.tool = .mute
    fixture.pianoRoll.selectedNoteIDs = []
    #expect(fixture.pianoRoll.applyTool(to: long.id, at: Tick(3840)))
    #expect(fixture.note(pitch: 60, at: Tick(3840))?.isMuted == true)
    #expect(fixture.pianoRoll.applyTool(to: long.id, at: Tick(3840)))
    #expect(fixture.note(pitch: 60, at: Tick(3840))?.isMuted == false, "Clicking a muted note unmutes it")

    fixture.pianoRoll.tool = .eraser
    #expect(fixture.pianoRoll.applyTool(to: long.id, at: Tick(3840)))
    #expect(fixture.pianoRoll.notes.count == 3)

    fixture.pianoRoll.tool = .pointer
    #expect(!fixture.pianoRoll.applyTool(to: fixture.pianoRoll.notes[0].id, at: .zero), "The Pointer leaves clicks to selecting")
  }

  @Test func snappingCanBeTurnedOff() {
    pianoRoll.gridSetting = .sixteenth
    #expect(pianoRoll.snap(Tick(250)) == Tick(240))
    #expect(pianoRoll.snapDown(Tick(470)) == Tick(240))
    pianoRoll.isSnapEnabled = false
    #expect(pianoRoll.snap(Tick(250)) == Tick(250), "Notes go exactly where they're put")
    #expect(pianoRoll.snapDown(Tick(470)) == Tick(470))
  }

  @Test func pencilAndBrushDrawNotes() throws {
    let fixture = EditingFixture()
    fixture.pianoRoll.tool = .pencil
    fixture.pianoRoll.drawNote(from: Tick(5760), to: Tick(6720), pitch: 72)
    #expect(fixture.note(pitch: 72, at: Tick(5760))?.length == Tick(960), "Dragged out to a quarter")
    fixture.pianoRoll.drawNote(from: Tick(6800), to: Tick(6800), pitch: 74)
    #expect(fixture.note(pitch: 74, at: Tick(6720))?.length == Tick(960), "A click uses the last length drawn")

    fixture.pianoRoll.tool = .brush
    let cells = (0..<4).map { (start: Tick(240) * Int64($0) + Tick(10), pitch: 48) } + [(start: Tick(10), pitch: 48)]
    fixture.pianoRoll.paint(cells)
    #expect(fixture.pianoRoll.notes.filter { $0.pitch == 48 }.map(\.start) == [.zero, Tick(240), Tick(480), Tick(720)])
    #expect(fixture.pianoRoll.notes.filter { $0.pitch == 48 }.allSatisfy { $0.length == Tick(240) })
  }

  @Test func copyPasteRepeatAndCopyDrag() throws {
    let fixture = EditingFixture()
    fixture.pianoRoll.selectNotes(over: .zero..<Tick(2400), pitches: 0...127, extending: false)
    fixture.window.editCopy()
    fixture.window.engine.locate(to: Tick(3840))
    fixture.window.editPaste()
    #expect(fixture.pianoRoll.notes.count == 7)
    #expect(fixture.note(pitch: 64, at: Tick(3840 + 960)) != nil, "Pasted at the playhead, spacing kept")
    #expect(fixture.pianoRoll.selectedNoteIDs.count == 3, "The pasted notes are selected")

    fixture.pianoRoll.selectedNoteIDs = [try #require(fixture.note(pitch: 67, at: Tick(1920))).id]
    fixture.window.editRepeat()
    #expect(fixture.note(pitch: 67, at: Tick(1920 + 3840)) != nil, "Repeated a bar later")

    fixture.pianoRoll.selectedNoteIDs = [try #require(fixture.note(pitch: 60, at: .zero)).id]
    fixture.pianoRoll.copySelection(by: Tick(240), pitchOffset: 2)
    #expect(fixture.note(pitch: 62, at: Tick(240)) != nil && fixture.note(pitch: 60, at: .zero) != nil, "Option-drag copies")

    fixture.window.editSelectAll()
    #expect(fixture.pianoRoll.selectedNoteIDs.count == fixture.pianoRoll.notes.count)
    fixture.window.editCut()
    #expect(fixture.pianoRoll.notes.isEmpty)
  }

  @Test func resizingEitherEdgeResizesTheSelection() throws {
    let fixture = EditingFixture()
    let first = try #require(fixture.note(pitch: 60, at: .zero)), second = try #require(fixture.note(pitch: 64, at: Tick(960)))
    fixture.pianoRoll.selectedNoteIDs = [first.id, second.id]
    fixture.pianoRoll.resizeSelection(first.id, fromStart: false, by: Tick(240))
    #expect(fixture.note(pitch: 60, at: .zero)?.length == Tick(720))
    #expect(fixture.note(pitch: 64, at: Tick(960))?.length == Tick(720), "Both got longer")
    fixture.pianoRoll.resizeSelection(second.id, fromStart: true, by: Tick(240))
    #expect(fixture.note(pitch: 64, at: Tick(1200))?.length == Tick(480), "The start moved, the end stayed")
  }

  @Test func keysTransposeNudgeQuantizeAndVelocity() throws {
    let fixture = EditingFixture()
    let e = try #require(fixture.note(pitch: 64, at: Tick(960)))
    fixture.pianoRoll.selectedNoteIDs = [e.id]
    fixture.pianoRoll.transposeSelection(by: 12)
    fixture.pianoRoll.nudgeSelection(by: 1)
    #expect(fixture.note(pitch: 76, at: Tick(1200)) != nil, "Up an octave, a sixteenth later")

    fixture.pianoRoll.quantizeStrength = 0.5
    fixture.pianoRoll.gridSetting = .quarter
    fixture.pianoRoll.quantizeSelection()
    #expect(fixture.note(pitch: 76, at: Tick(1080)) != nil, "Half way back to the beat")

    let changed = fixture.pianoRoll.velocityChange(for: e.id, dragged: -40)
    fixture.pianoRoll.finishVelocityChange(changed)
    #expect(fixture.pianoRoll.notes.first { $0.id == e.id }?.velocity == 110, "Dragging up 40 points adds 20")

    fixture.window.perform(ApplyNoteFunction(.mute(true), to: [e.id], in: fixture.regionID))
    #expect(fixture.window.project.region(withID: fixture.regionID)?.playedNotes.count == 3, "Muted notes don't play")
  }

  @Test func muteUnmuteActsOnEveryNoteWithoutASelection() throws {
    let fixture = EditingFixture()
    fixture.pianoRoll.selectedNoteIDs = []
    fixture.pianoRoll.toggleMuteSelection()
    #expect(fixture.pianoRoll.notes.allSatisfy { $0.isMuted }, "Like the other functions, every note")
    fixture.pianoRoll.toggleMuteSelection()
    #expect(!fixture.pianoRoll.notes.contains { $0.isMuted }, "And unmuted again")
    // With a selection, just the selection.
    let e = try #require(fixture.note(pitch: 64, at: Tick(960)))
    fixture.pianoRoll.selectedNoteIDs = [e.id]
    fixture.pianoRoll.toggleMuteSelection()
    #expect(fixture.pianoRoll.notes.filter { $0.isMuted }.map(\.id) == [e.id])
  }

  @Test func tOpensTheToolsOfTheAreaUnderThePointer() {
    let fixture = EditingFixture()
    // The region was opened from the tracks, so they were clicked last.
    fixture.window.activeEditingArea = .tracks
    fixture.pianoRoll.isPointerOver = true
    fixture.window.showToolMenu()
    #expect(fixture.pianoRoll.isToolMenuForPianoRoll)
    #expect(fixture.window.pickTool(forKey: "b"))
    #expect(fixture.pianoRoll.tool == .brush && fixture.window.tool == .pointer, "The Piano Roll's tool changed, not the tracks'")

    fixture.pianoRoll.isPointerOver = false
    fixture.window.isPointerOverTracks = true
    fixture.window.showToolMenu()
    #expect(!fixture.pianoRoll.isToolMenuForPianoRoll)
    #expect(fixture.window.pickTool(forKey: "e"))
    #expect(fixture.window.tool == .eraser && fixture.pianoRoll.tool == .brush)
  }
}
