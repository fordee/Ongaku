//
//  StepEditorTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
import OngakuEngine
@testable import Ongaku
import Testing

/// The Step Editor: lanes of notes and controllers, painted on a step grid.
@MainActor
struct StepEditorTests {
  private let window: ProjectWindowModel
  private let sixteenth = Tick(240)

  /// A one-bar drum region with a kick on step 1.
  init() {
    var drums = Track(name: "Drums", kind: .softwareInstrument)
    drums.channel.instrument = .generalMIDIPercussion(kit: 0)
    let region = Region(name: "Beat", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence(notes: [
      MIDINote(pitch: 36, velocity: 100, start: .zero, length: Tick(240))
    ])))
    drums.regions = [region]
    window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [drums])))
    window.openEditor(for: region.id)
    window.pianoRoll.editorKind = .stepEditor
  }

  private var editor: PianoRollModel { window.pianoRoll }

  @Test func drumKitsListTheirDrumsAndControllers() {
    let lanes = editor.stepLanes
    #expect(lanes.first == .note(pitch: 49))
    #expect(lanes.contains(.note(pitch: 36)))
    #expect(editor.name(of: .note(pitch: 36)) == "Kick")
    #expect(lanes.suffix(2) == [.control(.modulation), .control(.sustain)])
  }

  @Test func deleteLeavesNotesTheStepEditorCannotShowAsSelected() {
    // Notes selected in the Piano Roll, then the Step Editor shown and clicked.
    editor.selectedNoteIDs = Set(editor.notes.map(\.id))
    window.beginEditing(in: .pianoRoll)
    window.deleteSelectionInActiveArea()
    #expect(editor.notes.count == 1)
    #expect(window.project.tracks[0].regions.count == 1, "Nor does it fall through to the region")
  }

  @Test func theDrumMachineListsItsPads() {
    window.perform(SetChannelStrip(
      window.project.tracks[0].id, to: ChannelStrip(instrument: .audioUnit(OngakuInstrument.drumMachine.makeReference()))))
    let lanes = editor.stepLanes
    #expect(lanes.first == .note(pitch: 49))
    #expect(lanes.contains(.note(pitch: 70)) && !lanes.contains(.note(pitch: 51)), "Its shaker, and no ride")
    #expect(editor.name(of: .note(pitch: 37)) == "Rim")
    #expect(editor.name(of: .note(pitch: 42)) == "Closed Hat")
    #expect(editor.name(of: .note(pitch: 36)) == "Kick")
  }

  @Test func otherInstrumentsListThePitchesInUse() {
    window.perform(SetChannelStrip(window.project.tracks[0].id, to: ChannelStrip(instrument: .generalMIDI(program: 0))))
    #expect(editor.stepLanes.first == .note(pitch: 36))
    #expect(editor.name(of: .note(pitch: 36)) == PianoRollModel.noteName(36))
  }

  @Test func stepsFollowTheGrid() {
    #expect(editor.stepLength == sixteenth, "Sixteenths when the grid is automatic")
    #expect(editor.stepCount == 16)
    #expect(editor.stepValue(.note(pitch: 36), at: 0) == 100)
    #expect(editor.stepValue(.note(pitch: 36), at: 1) == nil)
    editor.gridSetting = .eighth
    #expect(editor.stepCount == 8)
  }

  @Test func paintingAddsAndChangesStepsInOneUndo() {
    editor.setStepValues([0: 127, 4: 90, 8: 60], in: .note(pitch: 36))
    #expect(editor.stepValue(.note(pitch: 36), at: 0) == 127, "The existing kick got louder")
    #expect(editor.stepValue(.note(pitch: 36), at: 4) == 90)
    #expect(editor.notes.filter { $0.pitch == 36 }.count == 3)
    #expect(editor.notes.first { $0.start == sixteenth * 4 }?.length == sixteenth)
  }

  @Test func controllersArePaintedToo() {
    editor.setStepValues([2: 200, 3: 64], in: .control(.modulation))
    #expect(editor.stepValue(.control(.modulation), at: 2) == 127, "Kept within the controller's range")
    #expect(editor.controls.map(\.position) == [sixteenth * 2, sixteenth * 3])
  }

  @Test func doubleClickingClearsAStep() {
    editor.clearStep(.note(pitch: 36), at: 0)
    #expect(editor.notes.isEmpty)
  }

  @Test func stepsPastTheRegionAreIgnored() {
    editor.setStepValues([40: 100], in: .note(pitch: 38))
    #expect(editor.notes.count == 1)
  }
}

// MARK: - Step Sequencer

extension StepEditorTests {
  /// A new pattern region on the drum track, open in the Step Sequencer.
  private func newPattern() throws -> Region {
    window.createPatternRegion(on: window.project.tracks[0].id, at: Tick(3840 + 100))
    return try #require(editor.region)
  }

  @Test func newPatternRegionsStartWithABeatOnDrumTracks() throws {
    let region = try newPattern()
    #expect(region.start == Tick(3840), "At the bar clicked")
    #expect(editor.shownEditor == .stepSequencer)
    #expect(editor.availableEditors == [.stepSequencer], "Edited only in the Step Sequencer")
    let pattern = try #require(region.pattern)
    #expect(pattern.rows.first?.name == "Kick")
    #expect(editor.notes.filter { $0.pitch == 36 }.count == 2, "The pattern's kicks are the region's notes")
  }

  @Test func theTrackMenuMakesAPatternRegionAtThePlayhead() throws {
    window.selectedTrackID = window.project.tracks[0].id
    #expect(window.canCreatePatternRegionAtPlayhead)
    window.engine.locate(to: Tick(3840 * 2 + 500))
    window.createPatternRegionAtPlayhead()
    let region = try #require(editor.region)
    #expect(region.pattern != nil && region.start == Tick(3840 * 2), "At the start of the playhead's bar")
    #expect(window.project.tracks[0].regions.contains { $0.id == region.id })
    #expect(editor.shownEditor == .stepSequencer)

    window.perform(AddTrack(Track(name: "Audio", kind: .audio)))
    window.selectedTrackID = window.project.tracks[1].id
    #expect(!window.canCreatePatternRegionAtPlayhead, "Only on instrument tracks")
  }

  @Test func paintingStepsInEachMode() throws {
    _ = try newPattern()
    let snare = try #require(editor.pattern?.rows.first { $0.pitch == 38 })
    // Step On/Off: two more snares, in one undo.
    editor.setSteps([2: 1, 3: 1], inRow: snare.id)
    #expect(editor.notes.filter { $0.pitch == 38 }.map(\.start) == [480, 720, 960, 2880].map { Tick($0) })
    editor.setSteps([2: 0], inRow: snare.id)
    #expect(editor.notes.filter { $0.pitch == 38 }.count == 3)

    editor.stepEditMode = .velocity
    editor.setSteps([4: 0.5], inRow: snare.id)
    #expect(editor.notes.first { $0.pitch == 38 && $0.start == Tick(960) }?.velocity == 64)
    editor.stepEditMode = .repeats
    editor.setSteps([4: 1], inRow: snare.id)
    #expect(editor.notes.filter { $0.pitch == 38 && $0.start >= Tick(960) && $0.start < Tick(1200) }.count == 4, "A roll")
  }

  @Test func rowAndPatternSettings() throws {
    _ = try newPattern()
    let kick = try #require(editor.pattern?.rows.first)
    editor.setRowLength(3, of: kick.id)
    #expect(editor.pattern?.rows.first?.steps.count == 3)
    editor.setRowRate(.eighth, of: kick.id)
    editor.setPatternLength(32)
    #expect(editor.pattern?.length == 32)
    #expect(editor.pattern?.rows.first { $0.pitch == 38 }?.steps.count == 32, "Rows following the pattern grow")
    #expect(editor.pattern?.rows.first?.steps.count == 3, "A row with its own length keeps it")
    editor.toggleRowMute(kick.id)
    #expect(!editor.notes.contains { $0.pitch == 36 })
    editor.addRow(pitch: 56, name: "Cowbell")
    #expect(editor.pattern?.rows.first?.name == "Cowbell")
    editor.removeRow(kick.id)
    #expect(!(editor.pattern?.rows.contains { $0.id == kick.id } ?? true))
  }

  @Test func convertingMakesAnOrdinaryMIDIRegion() throws {
    let region = try newPattern()
    let count = editor.notes.count
    editor.convertPatternToNotes()
    #expect(window.project.region(withID: region.id)?.pattern == nil)
    #expect(editor.notes.count == count)
    #expect(editor.shownEditor == .pianoRoll)
  }
}

// MARK: - Drummer

extension StepEditorTests {
  @Test func aDrummerTrackPlaysEachSectionOfTheSong() throws {
    window.perform(AddArrangementSection(ArrangementSection(name: "Intro", start: .zero, length: Tick(3840 * 4))))
    window.perform(AddArrangementSection(ArrangementSection(name: "Chorus", start: Tick(3840 * 4), length: Tick(3840 * 8))))
    // Tests have no run loop to close undo groups, so the new track gets its own.
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    window.undoManager = undoManager
    undoManager.beginUndoGrouping()
    window.addDrummerTrack(style: .pop)
    undoManager.endUndoGrouping()
    let track = try #require(window.project.tracks.first { $0.name == "Drummer" })
    #expect(track.channel.instrument == .generalMIDIPercussion(kit: 0))
    #expect(track.regions.map(\.name) == ["Intro", "Chorus"])
    #expect(track.regions.map(\.length) == [Tick(3840 * 4), Tick(3840 * 8)])
    let intro = try #require(track.regions[0].drummer), chorus = try #require(track.regions[1].drummer)
    #expect(chorus.loudness > intro.loudness && intro.fillsAtEnd && !chorus.fillsAtEnd && chorus.crashesAtStart)
    #expect(editor.shownEditor == .drummer && editor.availableEditors == [.drummer])
    #expect(!editor.notes.isEmpty, "The intro's notes are the region's notes")
    undoManager.undo()
    #expect(!window.project.tracks.contains { $0.name == "Drummer" }, "One undo removes the track and its regions")
  }

  @Test func editingTheDrummerChangesTheSelectedRegions() throws {
    window.addDrummerTrack()
    let track = try #require(window.project.tracks.first { $0.name == "Drummer" })
    #expect(track.regions.count == 1, "Eight bars when the song has no sections")
    let before = editor.notes.count
    editor.editDrummer("Drummer Pad") {
      $0.complexity = 1
      $0.loudness = 1
    }
    #expect(editor.drummer?.complexity == 1 && editor.notes.count > before)
    let notes = editor.notes.map(\.start)
    editor.newDrummerTake()
    #expect(editor.notes.map(\.start) != notes, "A new take plays differently")
    editor.convertDrummerToNotes()
    #expect(editor.region?.drummer == nil && editor.shownEditor == .pianoRoll)
  }

  @Test func matchingSongSectionsKeepsEachSectionsSettings() throws {
    for (name, bar, bars) in [("Intro", 0, 4), ("Verse", 4, 4), ("Chorus", 8, 4)] {
      window.perform(AddArrangementSection(ArrangementSection(name: name, start: Tick(3840 * Int64(bar)), length: Tick(3840 * Int64(bars)))))
    }
    window.addDrummerTrack()
    let trackID = try #require(window.project.tracks.first { $0.name == "Drummer" }?.id)
    func regions() -> [Region] { window.project.track(withID: trackID)?.regions ?? [] }
    let verse = try #require(regions().first { $0.name == "Verse" })
    let chorus = try #require(regions().first { $0.name == "Chorus" })
    window.select(verse.id, extending: false)
    window.openEditor(for: verse.id)
    editor.editDrummer("Drummer Pad") { $0.loudness = 0.95 }
    window.createDrummerRegion(on: trackID, at: Tick(3840 * 20))
    #expect(regions().count == 4)

    // The chorus grows, and an outro is added; the region at bar 21 has no section now.
    var longer = try #require(window.project.arrangement.first { $0.name == "Chorus" })
    longer.length = Tick(3840 * 8)
    window.perform(UpdateArrangementSection(longer))
    window.perform(AddArrangementSection(ArrangementSection(name: "Outro", start: Tick(3840 * 16), length: Tick(3840 * 4))))
    #expect(!window.drummerMatchesSections(on: trackID))
    #expect(window.drummerSectionMatch(on: trackID)?.removed.map(\.start) == [Tick(3840 * 20)], "Asked about first")

    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    window.undoManager = undoManager
    undoManager.beginUndoGrouping()
    window.matchDrummerToSections(on: trackID)
    undoManager.endUndoGrouping()
    #expect(regions().map(\.name) == ["Intro", "Verse", "Chorus", "Outro"])
    #expect(window.drummerMatchesSections(on: trackID))
    let matchedVerse = try #require(regions().first { $0.name == "Verse" })
    #expect(matchedVerse.id == verse.id && matchedVerse.drummer?.loudness == 0.95, "The verse keeps its settings")
    let matchedChorus = try #require(regions().first { $0.name == "Chorus" })
    #expect(matchedChorus.id == chorus.id && matchedChorus.drummer == chorus.drummer && matchedChorus.length == Tick(3840 * 8),
      "The chorus keeps its settings, and fills its new length")
    guard case .midi(let sequence) = matchedChorus.content else { Issue.record("Not MIDI"); return }
    #expect(sequence.notes.contains { $0.start >= Tick(3840 * 4) }, "It plays into the new bars")
    undoManager.undo()
    #expect(regions().count == 4 && regions().contains { $0.start == Tick(3840 * 20) }, "One undo puts it all back")
  }
}

// MARK: - Session players and the Chord track

extension StepEditorTests {
  @Test func aBassPlayerTrackFollowsTheChordTrack() throws {
    window.perform(AddArrangementSection(ArrangementSection(name: "Verse", start: .zero, length: Tick(3840 * 2))))
    window.perform(AddArrangementSection(ArrangementSection(name: "Chorus", start: Tick(3840 * 2), length: Tick(3840 * 2))))
    window.addPlayerTrack(.bass)
    let track = try #require(window.project.tracks.first { $0.name == "Bass Player" })
    #expect(track.channel.instrument == .generalMIDI(program: 33))
    #expect(track.regions.map(\.name) == ["Verse", "Chorus"] && track.regions.allSatisfy { $0.player?.instrument == .bass })
    #expect(editor.shownEditor == .player && editor.availableEditors == [.player])

    // With an empty Chord track, the song gets chords: a progression a section, a chord a
    // bar, coming home to the key's chord at the end.
    let written = window.project.chords
    #expect(written.first?.position == .zero && written.contains { $0.position == Tick(3840 * 2) }, "\(written.map(\.chord.description))")
    #expect(written.last?.chord.description == "C")
    #expect(window.isGlobalTracksVisible)
    // A second player follows those chords rather than writing more.
    window.addPlayerTrack(.keys)
    #expect(window.project.chords == written)

    // A progression over a section, from the Chord track's menu.
    let classic = try #require(window.progressions(at: .zero).first { $0.name == "Classic" })
    #expect(window.chordNames(classic, at: .zero) == "C F G C")
    window.fillChords(with: classic, from: Tick(3840 * 2), to: Tick(3840 * 4))
    #expect(window.project.chords.filter { $0.position >= Tick(3840 * 2) }.map(\.chord.description) == ["C", "F"])

    // Chords typed on the Chord track: on the Snap grid, and the bass follows.
    #expect(window.setChord(named: "Am", at: Tick(10)))
    #expect(window.setChord(named: "F", at: Tick(3840 + 30)))
    #expect(window.project.chords.prefix(2).map(\.position) == [.zero, Tick(3840)], "Snapped")
    let verse = try #require(window.project.tracks.first { $0.name == "Bass Player" }?.regions.first)
    guard case .midi(let sequence) = verse.content else { Issue.record("Not MIDI"); return }
    #expect(sequence.notes.first { $0.start < Tick(30) }.map { $0.pitch % 12 } == 9, "The verse starts on A")
    #expect(!window.setChord(named: "Hm", at: .zero) && window.errorMessage != nil, "Not a chord name")
    #expect(window.diatonicChords(at: .zero).map(\.description) == ["C", "Dm", "Em", "F", "G", "Am", "Bdim"])

    // After a key change, the suggestions are the new key's.
    window.setKey(KeySignature(tonic: 7, mode: .major), at: Tick(3840 * 8))
    #expect(window.diatonicChords(at: Tick(3840 * 9)).map(\.description) == ["G", "Am", "Bm", "C", "D", "Em", "F♯dim"])
    #expect(window.diatonicChords(at: Tick(3840 * 7)).first?.description == "C", "Before it, still C major")
  }

  @Test func editingAPlayerChangesItsPart() throws {
    window.addPlayerTrack(.keys)
    let before = editor.notes.count
    editor.editPlayer("Player Style") { $0.style = .balladArpeggio }
    #expect(editor.player?.style == .balladArpeggio && editor.notes.count != before)
    editor.editPlayer("Player Register") { $0.register = 5 }
    #expect(editor.player?.register == 1, "Kept within its range")
    editor.convertPlayerToNotes()
    #expect(editor.region?.player == nil && editor.shownEditor == .pianoRoll)
  }

  @Test func chordsSnapToTheSnapSettingButNotBetweenSixteenths() {
    let saved = UserDefaults.standard.string(forKey: AppSettings.snapModeKey)
    defer { UserDefaults.standard.set(saved, forKey: AppSettings.snapModeKey) }
    UserDefaults.standard.set(AppSettings.SnapMode.bar.rawValue, forKey: AppSettings.snapModeKey)
    #expect(window.snapChord(Tick(3840 + 1000)) == Tick(3840))
    UserDefaults.standard.set(AppSettings.SnapMode.beat.rawValue, forKey: AppSettings.snapModeKey)
    #expect(window.snapChord(Tick(3840 + 1000)) == Tick(3840 + 960))
    UserDefaults.standard.set(AppSettings.SnapMode.off.rawValue, forKey: AppSettings.snapModeKey)
    #expect(window.snapChord(Tick(3840 + 250)) == Tick(3840 + 240), "The nearest sixteenth with Snap off")
    UserDefaults.standard.set(AppSettings.SnapMode.eighthTriplet.rawValue, forKey: AppSettings.snapModeKey)
    #expect(window.snapChord(Tick(320)) == Tick(240), "Triplets are between the sixteenths the players read")
  }

  @Test func aClickedChordIsWhatDeleteRemoves() throws {
    #expect(window.setChord(named: "C", at: .zero))
    #expect(window.setChord(named: "F", at: Tick(3840)))
    let regionID = window.project.tracks[0].regions[0].id
    window.select(regionID, extending: false)
    window.selectChord(try #require(window.project.chords.last).id)
    window.deleteSelectionInActiveArea()
    #expect(window.project.chords.map(\.chord.description) == ["C"], "The clicked chord goes")
    #expect(window.project.tracks[0].regions.count == 1, "The selected region stays")
    #expect(window.selectedChordID == nil)

    // Clicking a region afterwards: Delete removes regions again.
    window.selectChord(window.project.chords[0].id)
    window.select(regionID, extending: false)
    #expect(window.selectedChordID == nil)
    window.deleteSelectionInActiveArea()
    #expect(window.project.chords.count == 1 && window.project.tracks[0].regions.isEmpty)
  }

  @Test func detectChordsReadsTheSelectedMIDIRegions() throws {
    window.addTrack(.softwareInstrument)
    let keys = try #require(window.project.tracks.last)
    let chord = [60, 64, 67].map { MIDINote(pitch: $0, start: .zero, length: Tick(3840)) }
      + [65, 69, 72].map { MIDINote(pitch: $0, start: Tick(3840), length: Tick(3840)) }
    let region = Region(name: "Keys", start: .zero, length: Tick(3840 * 2), content: .midi(MIDISequence(notes: chord)))
    window.perform(AddRegion(region, to: keys.id))
    window.selectedRegionIDs = [region.id, window.project.tracks[0].regions[0].id]
    #expect(window.chordDetectionRegionIDs == [region.id], "Not the drums")
    window.detectChordsInSelection()
    #expect(window.project.chords.map(\.chord.description) == ["C", "F"])
  }
}
