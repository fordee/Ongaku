//
//  TrackEditingWindowTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
import OngakuEngine
@testable import Ongaku
import Testing

/// Editing regions and tracks from the window: the Edit menu's cut, copy and paste, repeat,
/// option-drag copies, the rubber band, duplicating tracks and section edits.
@MainActor
@Suite(.serialized)
struct TrackEditingWindowTests {
  private let window: ProjectWindowModel
  private let undoManager = UndoManager()
  private let bar = Tick.quarterNotes(4)

  /// Keys with a region at bar 1, Bass with one at bar 2.
  init() {
    let keys = Track(name: "Keys", kind: .softwareInstrument, regions: [
      Region(name: "Chords", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence()))
    ])
    let bass = Track(name: "Bass", kind: .softwareInstrument, regions: [
      Region(name: "Line", start: .quarterNotes(4), length: .quarterNotes(4), content: .midi(MIDISequence()))
    ])
    window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [keys, bass])))
    window.undoManager = undoManager
    RegionPasteboard.contents = nil
  }

  private var keys: Track { window.project.tracks[0] }
  private var bass: Track { window.project.tracks[1] }

  @Test func midiKeyboardsPlayEveryArmedInstrumentTrack() {
    window.selectedTrackID = bass.id
    #expect(window.liveMIDITrackIDs == [bass.id], "The selected track when none are armed")
    window.setRecordArmed(keys.id, true)
    window.setRecordArmed(bass.id, true)
    #expect(window.liveMIDITrackIDs == [keys.id, bass.id], "Layered, as they all record")
    window.setRecordArmed(bass.id, false)
    #expect(window.liveMIDITrackIDs == [keys.id], "Armed tracks rather than the selected one")
    window.setRecordArmed(keys.id, false)
    window.perform(AddTrack(Track(name: "Audio", kind: .audio)))
    window.selectedTrackID = window.project.tracks[2].id
    #expect(window.liveMIDITrackIDs.isEmpty, "Nothing when an audio track is selected")
  }

  @Test func copyAndPasteAtThePlayhead() {
    window.selectedRegionIDs = [keys.regions[0].id]
    window.copySelection()
    window.engine.locate(to: bar * 4)
    window.selectedTrackID = bass.id
    window.paste()
    #expect(bass.regions.map(\.start) == [bar, bar * 4], "Pasted onto the selected track at the playhead")
    #expect(window.selectedRegionIDs == [bass.regions[1].id], "The paste is selected")
    #expect(keys.regions.count == 1, "Copying left the original")
  }

  @Test func cutRemovesAndUndoBringsBack() {
    window.selectedRegionIDs = [keys.regions[0].id]
    window.cutSelection()
    #expect(keys.regions.isEmpty)
    #expect(undoManager.undoActionName == "Cut Region")
    undoManager.undo()
    #expect(keys.regions.count == 1)
    // And it can still be pasted.
    window.engine.locate(to: bar * 2)
    window.selectedTrackID = keys.id
    window.paste()
    #expect(keys.regions.map(\.start) == [.zero, bar * 2])
  }

  @Test func optionArrowsNudgeTheSelectedRegions() {
    // Tests have no run loop to close undo groups, so each nudge gets its own.
    undoManager.groupsByEvent = false
    func nudge(_ steps: Int, mode: AppSettings.SnapMode = .beat) {
      undoManager.beginUndoGrouping()
      window.nudgeSelectedRegions(by: steps, mode: mode)
      undoManager.endUndoGrouping()
    }
    window.selectedRegionIDs = [keys.regions[0].id, bass.regions[0].id]
    nudge(1)
    #expect(keys.regions[0].start == .quarterNotes(1))
    #expect(bass.regions[0].start == .quarterNotes(5))
    #expect(undoManager.undoActionName == "Nudge Regions")
    // Back past the start: no further than the project start, keeping the spacing.
    nudge(-1)
    // Already at the start: nothing moves and there's nothing to undo.
    window.nudgeSelectedRegions(by: -1, mode: .beat)
    #expect(keys.regions[0].start == .zero)
    #expect(bass.regions[0].start == bar)
    undoManager.undo()
    #expect(keys.regions[0].start == .quarterNotes(1), "Each nudge is one undo step")
    nudge(1, mode: .bar)
    #expect(keys.regions[0].start == .quarterNotes(5), "A bar with Snap set to Bar")
  }

  @Test func theMetronomeIsUndoneLikeTheCycle() {
    window.toggleMetronome()
    #expect(window.project.isMetronomeEnabled)
    #expect(undoManager.undoActionName == "Metronome Change")
    // As the window does after every change.
    window.projectDidChange()
    #expect(window.engine.isMetronomeEnabled)
    undoManager.undo()
    window.projectDidChange()
    #expect(!window.project.isMetronomeEnabled)
    #expect(!window.engine.isMetronomeEnabled)
  }

  @Test func repeatingSelectsTheCopies() {
    window.selectedRegionIDs = [keys.regions[0].id]
    window.repeatSelection(times: 3)
    #expect(keys.regions.map(\.start) == [.zero, bar, bar * 2, bar * 3])
    #expect(window.selectedRegionIDs.count == 3)
    #expect(!window.selectedRegionIDs.contains(keys.regions[0].id))
  }

  @Test func optionDraggingCopiesToAnotherTrack() {
    window.selectedRegionIDs = [keys.regions[0].id]
    // Dragged two bars right and down a track.
    window.copySelection(by: bar * 2, trackOffset: 1)
    #expect(keys.regions.count == 1, "The original stays")
    #expect(bass.regions.map(\.start) == [bar, bar * 2])
    #expect(undoManager.undoActionName == "Copy Region")
  }

  @Test func theRubberBandSelectsWhatItTouches() {
    // Both rows, from half way through bar 1 to the start of bar 2: touches both regions.
    window.selectRegions(inRows: 0...1, over: Tick.quarterNotes(2)..<(bar + Tick(1)), extending: false)
    #expect(window.selectedRegionIDs == [keys.regions[0].id, bass.regions[0].id])
    // Only the first row, in bar 3: nothing.
    window.selectRegions(inRows: 0...0, over: (bar * 2)..<(bar * 3), extending: false)
    #expect(window.selectedRegionIDs.isEmpty)
  }

  @Test func selectAllFollowingAndOnTrack() {
    window.selectedRegionIDs = [keys.regions[0].id]
    window.repeatSelection(times: 2)
    window.selectAllFollowing(keys.regions[1].id)
    #expect(window.selectedRegionIDs == Set(keys.regions.dropFirst().map(\.id)))
    window.selectAllRegions(onTrack: bass.id)
    #expect(window.selectedRegionIDs == [bass.regions[0].id])
    window.selectAllRegions()
    #expect(window.selectedRegionIDs.count == 4)
  }

  @Test func duplicatingTheSelectedTrack() {
    window.selectedTrackID = bass.id
    window.duplicateSelectedTrack()
    #expect(window.project.tracks.map(\.name) == ["Keys", "Bass", "Bass 2"])
    #expect(window.selectedTrackID == window.project.tracks[2].id)
    #expect(window.project.tracks[2].regions.map(\.start) == [bar])
  }

  @Test func sectionEditsUseTheLocators() {
    // Locators around bar 1; cutting it moves the bass line to the start.
    window.perform(SetCycle(CycleRange(start: .zero, end: bar)))
    window.cutSection()
    #expect(keys.regions.isEmpty)
    #expect(bass.regions.map(\.start) == [.zero])
    window.insertSilence()
    #expect(bass.regions.map(\.start) == [bar])
    window.repeatSection()
    #expect(bass.regions.map(\.start) == [bar * 2], "Nothing in bar 1 to repeat, but bar 1's length is inserted")
  }

  @Test func deleteWithNothingSelectedKeepsTheTrack() {
    window.selectedTrackID = keys.id
    window.selectedRegionIDs = []
    window.deleteSelectionInActiveArea()
    #expect(window.project.tracks.map(\.name) == ["Keys", "Bass"], "Delete only ever removes regions")

    window.selectedRegionIDs = [keys.regions[0].id]
    window.deleteSelectionInActiveArea()
    #expect(keys.regions.isEmpty)
    #expect(window.project.tracks.count == 2)
  }

  @Test func deleteTrackRemovesEverySelectedTrack() {
    window.selectedTrackID = bass.id
    window.deleteSelectedTracks()
    #expect(window.project.tracks.map(\.name) == ["Keys"])
    #expect(window.selectedTrackID == keys.id, "The track nearest the deleted one is selected")
    undoManager.undo()

    window.selectedTrackIDs = [keys.id, bass.id]
    window.deleteSelectedTracks()
    #expect(window.project.tracks.isEmpty)
    #expect(undoManager.undoActionName == "Delete Tracks")
    undoManager.undo()
    #expect(window.project.tracks.map(\.name) == ["Keys", "Bass"], "One undo brings both back")
  }
}

/// Logic's loop handle, from the window: dragging sets where the loops end, snapped.
@MainActor
struct RegionLoopWindowTests {
  private let window: ProjectWindowModel
  private let bar = Tick.quarterNotes(4)

  init() {
    let keys = Track(name: "Keys", kind: .softwareInstrument, regions: [
      Region(name: "Riff", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence()))
    ])
    window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [keys])))
  }

  private var riff: Region { window.project.tracks[0].regions[0] }

  @Test func draggingTheLoopHandleSetsTheLoopEnd() throws {
    // Dragged to just past bar 3: snapped to it.
    let end = try #require(window.loopEnd(for: riff.id, draggedTo: bar * 3 + Tick(10)))
    window.finishLoopDrag(LoopPreview(regionID: riff.id, end: end))
    #expect(riff.loopEnd == window.snap(bar * 3 + Tick(10)))
    #expect(riff.isLooped)
    // Dragged back into the region: the loops go.
    let back = try #require(window.loopEnd(for: riff.id, draggedTo: .quarterNotes(1)))
    #expect(back == riff.end, "No earlier than the region's end")
    window.finishLoopDrag(LoopPreview(regionID: riff.id, end: back))
    #expect(!riff.isLooped)
  }

  @Test func convertingSelectsTheNewRegions() {
    window.perform(SetRegionLoop(riff.id, to: bar * 3))
    window.selectedRegionIDs = [riff.id]
    #expect(window.selectionHasLoops)
    window.convertLoopsToRegions()
    #expect(window.project.tracks[0].regions.count == 3)
    #expect(window.selectedRegionIDs.count == 3)
    #expect(!window.selectionHasLoops)
  }
}
