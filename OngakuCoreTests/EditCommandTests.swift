//
//  EditCommandTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

struct EditCommandTests {
  // MARK: - Fixtures

  /// A project with one instrument track holding a two-bar MIDI region, and one audio track
  /// holding a two-bar region of a 48 kHz file. Tempo is 120 BPM, so one bar is 2 seconds.
  private struct Fixture {
    var project: Project
    let instrumentTrackID: Track.ID
    let audioTrackID: Track.ID
    let midiRegionID: Region.ID
    let audioRegionID: Region.ID
    let earlyNoteID: MIDINote.ID
    let lateNoteID: MIDINote.ID
  }

  private func makeFixture() -> Fixture {
    let file = AudioFileReference(fileName: "Take.wav", sampleRate: 48_000, channelCount: 2, frameCount: 48_000 * 60)
    let earlyNote = MIDINote(pitch: 60, start: .zero, length: Tick(960))
    let lateNote = MIDINote(pitch: 64, start: Tick(3840), length: Tick(960))
    let midiRegion = Region(
      name: "Inst 1", start: Tick(3840), length: Tick(7680),
      content: .midi(MIDISequence(notes: [earlyNote, lateNote])))
    let audioRegion = Region(
      name: "Take", start: Tick(3840), length: Tick(7680),
      content: .audio(AudioRegionContent(fileID: file.id)))
    let instrumentTrack = Track(name: "Inst 1", kind: .softwareInstrument, regions: [midiRegion])
    let audioTrack = Track(name: "Audio 1", kind: .audio, regions: [audioRegion])

    return Fixture(
      project: Project(tracks: [instrumentTrack, audioTrack], audioFiles: [file]),
      instrumentTrackID: instrumentTrack.id,
      audioTrackID: audioTrack.id,
      midiRegionID: midiRegion.id,
      audioRegionID: audioRegion.id,
      earlyNoteID: earlyNote.id,
      lateNoteID: lateNote.id)
  }

  // MARK: - Tracks

  @Test func addMoveRenameAndDeleteTracks() throws {
    var project = Project()
    let first = Track(name: "Inst 1", kind: .softwareInstrument)
    let second = Track(name: "Audio 1", kind: .audio)

    try AddTrack(first).apply(to: &project)
    try AddTrack(second, at: 0).apply(to: &project)
    #expect(project.tracks.map(\.id) == [second.id, first.id])

    try MoveTrack(second.id, to: 1).apply(to: &project)
    #expect(project.tracks.map(\.id) == [first.id, second.id])

    try RenameTrack(first.id, to: "  Piano ").apply(to: &project)
    #expect(project.tracks[0].name == "Piano")
    #expect(throws: EditError.self) { try RenameTrack(first.id, to: "   ").apply(to: &project) }

    try DeleteTracks([first.id]).apply(to: &project)
    #expect(project.tracks.map(\.id) == [second.id])
    #expect(throws: EditError.trackNotFound(first.id)) { try DeleteTracks([first.id]).apply(to: &project) }
  }

  @Test func newTracksGetDefaultsForTheirKind() {
    let instrument = Track(name: "Inst 1", kind: .softwareInstrument)
    let audio = Track(name: "Audio 1", kind: .audio)
    #expect(instrument.channel.instrument == .defaultSampler)
    #expect(audio.channel.instrument == nil)
    #expect(instrument.color == .green)
    #expect(audio.color == .blue)
  }

  @Test func nextTrackNameSkipsNamesInUse() {
    let project = Project(tracks: [
      Track(name: "Audio 1", kind: .audio), Track(name: "Audio 2", kind: .audio),
    ])
    #expect(project.nextTrackName(for: .audio) == "Audio 3")
    #expect(project.nextTrackName(for: .softwareInstrument) == "Inst 1")
  }

  @Test func channelStripValuesAreClamped() throws {
    var fixture = makeFixture()
    var channel = ChannelStrip(volume: 20, pan: -3)
    channel.instrument = .defaultSampler
    try SetChannelStrip(fixture.instrumentTrackID, to: channel).apply(to: &fixture.project)

    let stored = try #require(fixture.project.track(withID: fixture.instrumentTrackID)).channel
    #expect(stored.volume == 6)
    #expect(stored.pan == -1)
  }

  @Test func audioTracksRejectInstruments() {
    var fixture = makeFixture()
    let channel = ChannelStrip(instrument: .defaultSampler)
    #expect(throws: EditError.self) {
      try SetChannelStrip(fixture.audioTrackID, to: channel).apply(to: &fixture.project)
    }
  }

  // MARK: - Regions

  @Test func regionsMustMatchTheirTrackKind() {
    var fixture = makeFixture()
    let region = Region(name: "MIDI", start: .zero, length: Tick(3840), content: .midi(MIDISequence()))
    #expect(throws: EditError.trackKindMismatch(expected: .softwareInstrument, found: .audio)) {
      try AddRegion(region, to: fixture.audioTrackID).apply(to: &fixture.project)
    }
  }

  @Test func regionsStaySortedByStart() throws {
    var fixture = makeFixture()
    let earlier = Region(name: "Intro", start: .zero, length: Tick(960), content: .midi(MIDISequence()))
    try AddRegion(earlier, to: fixture.instrumentTrackID).apply(to: &fixture.project)

    let regions = try #require(fixture.project.track(withID: fixture.instrumentTrackID)).regions
    #expect(regions.map(\.id) == [earlier.id, fixture.midiRegionID])
  }

  @Test func moveRegionToAnotherTrackOfTheSameKind() throws {
    var fixture = makeFixture()
    let otherTrack = Track(name: "Inst 2", kind: .softwareInstrument)
    try AddTrack(otherTrack).apply(to: &fixture.project)

    try MoveRegion(fixture.midiRegionID, to: Tick(960), track: otherTrack.id).apply(to: &fixture.project)

    #expect(fixture.project.track(withID: fixture.instrumentTrackID)?.regions.isEmpty == true)
    let moved = try #require(fixture.project.region(withID: fixture.midiRegionID))
    #expect(moved.start == Tick(960))
    #expect(fixture.project.regionLocation(for: fixture.midiRegionID)?.track == 2)

    #expect(throws: EditError.self) {
      try MoveRegion(fixture.midiRegionID, to: .zero, track: fixture.audioTrackID).apply(to: &fixture.project)
    }
  }

  @Test func splitMIDIRegionKeepsNotesInPlace() throws {
    var fixture = makeFixture()
    let rightID = UUID()
    // Split at bar 3, one bar into the region.
    try SplitRegion(fixture.midiRegionID, at: Tick(7680), newRegionID: rightID).apply(to: &fixture.project)

    let left = try #require(fixture.project.region(withID: fixture.midiRegionID))
    let right = try #require(fixture.project.region(withID: rightID))
    #expect(left.start == Tick(3840))
    #expect(left.length == Tick(3840))
    #expect(right.start == Tick(7680))
    #expect(right.length == Tick(3840))

    guard case .midi(let leftNotes) = left.content, case .midi(let rightNotes) = right.content else {
      Issue.record("Split regions should stay MIDI regions")
      return
    }
    #expect(leftNotes.notes.map(\.id) == [fixture.earlyNoteID])
    #expect(rightNotes.notes.map(\.id) == [fixture.lateNoteID])
    // The late note was one bar into the original region, so it is at the start of the right half.
    #expect(rightNotes.notes.first?.start == .zero)
  }

  @Test func splitAudioRegionOffsetsTheFile() throws {
    var fixture = makeFixture()
    let rightID = UUID()
    try SplitRegion(fixture.audioRegionID, at: Tick(7680), newRegionID: rightID).apply(to: &fixture.project)

    let right = try #require(fixture.project.region(withID: rightID))
    guard case .audio(let audio) = right.content else {
      Issue.record("Split regions should stay audio regions")
      return
    }
    // One bar at 120 BPM is 2 seconds, or 96,000 frames at 48 kHz.
    #expect(audio.fileStartFrame == 96_000)
  }

  @Test func splitOutsideTheRegionFails() {
    var fixture = makeFixture()
    #expect(throws: EditError.self) {
      try SplitRegion(fixture.midiRegionID, at: Tick(3840)).apply(to: &fixture.project)
    }
  }

  @Test func trimmingTheStartKeepsContentOnTheTimeline() throws {
    var fixture = makeFixture()
    // Trim one bar off the front of both regions.
    try TrimRegion(fixture.midiRegionID, start: Tick(7680), length: Tick(3840)).apply(to: &fixture.project)
    try TrimRegion(fixture.audioRegionID, start: Tick(7680), length: Tick(3840)).apply(to: &fixture.project)

    let midi = try #require(fixture.project.region(withID: fixture.midiRegionID))
    guard case .midi(let sequence) = midi.content else {
      Issue.record("Expected MIDI")
      return
    }
    let lateNote = try #require(sequence.notes.first { $0.id == fixture.lateNoteID })
    #expect(midi.start + lateNote.start == Tick(7680))

    let audio = try #require(fixture.project.region(withID: fixture.audioRegionID))
    guard case .audio(let content) = audio.content else {
      Issue.record("Expected audio")
      return
    }
    #expect(content.fileStartFrame == 96_000)

    // Extending the audio region before the start of its file isn't possible.
    #expect(throws: EditError.self) {
      try TrimRegion(fixture.audioRegionID, start: .zero, length: Tick(7680)).apply(to: &fixture.project)
    }
  }

  // MARK: - Notes

  @Test func addUpdateAndDeleteNotes() throws {
    var fixture = makeFixture()
    var note = MIDINote(pitch: 67, start: Tick(480), length: Tick(240))
    try AddNotes([note], to: fixture.midiRegionID).apply(to: &fixture.project)

    note.pitch = 69
    note.velocity = 64
    try UpdateNotes([note], in: fixture.midiRegionID).apply(to: &fixture.project)

    var notes = try midiNotes(in: fixture.midiRegionID, of: fixture.project)
    #expect(notes.map(\.id) == [fixture.earlyNoteID, note.id, fixture.lateNoteID])
    #expect(notes[1].pitch == 69)
    #expect(notes[1].velocity == 64)

    try DeleteNotes([note.id], from: fixture.midiRegionID).apply(to: &fixture.project)
    notes = try midiNotes(in: fixture.midiRegionID, of: fixture.project)
    #expect(notes.map(\.id) == [fixture.earlyNoteID, fixture.lateNoteID])
  }

  @Test func invalidNotesAreRejected() {
    var fixture = makeFixture()
    let badPitch = MIDINote(pitch: 128, start: .zero, length: Tick(240))
    let zeroLength = MIDINote(pitch: 60, start: .zero, length: .zero)
    #expect(throws: EditError.self) { try AddNotes([badPitch], to: fixture.midiRegionID).apply(to: &fixture.project) }
    #expect(throws: EditError.self) { try AddNotes([zeroLength], to: fixture.midiRegionID).apply(to: &fixture.project) }
    #expect(throws: EditError.self) { try AddNotes([badPitch], to: fixture.audioRegionID).apply(to: &fixture.project) }
  }

  private func midiNotes(in regionID: Region.ID, of project: Project) throws -> [MIDINote] {
    let region = try #require(project.region(withID: regionID))
    guard case .midi(let sequence) = region.content else {
      Issue.record("Expected a MIDI region")
      return []
    }
    return sequence.notes
  }

  // MARK: - Project settings

  @Test func cycleMustEndAfterItStarts() {
    var project = Project()
    #expect(throws: EditError.self) {
      try SetCycle(CycleRange(start: Tick(3840), end: Tick(3840))).apply(to: &project)
    }
  }

  @Test func theMetronomeIsSavedWithTheSong() throws {
    var project = Project()
    try SetMetronome(true).apply(to: &project)
    let saved = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    #expect(saved.isMetronomeEnabled)
    // Songs saved before it was stored open with it off.
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    object["isMetronomeEnabled"] = nil
    let older = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(!older.isMetronomeEnabled)
  }

  @Test func compositeCommandAppliesEveryStep() throws {
    var project = Project()
    let track = Track(name: "Inst 1", kind: .softwareInstrument)
    let command = CompositeCommand("Set Up Song", commands: [
      AddTrack(track), RenameTrack(track.id, to: "Bass"), SetTempo(95),
    ])
    try command.apply(to: &project)
    #expect(project.tracks.map(\.name) == ["Bass"])
    #expect(project.tempoMap.tempo(at: .zero) == 95)
  }
}

// MARK: - Piano Roll note functions

extension EditCommandTests {
  /// One instrument region at bar 1 with these notes.
  private func noteProject(_ notes: [MIDINote]) -> (Project, Region.ID) {
    let region = Region(name: "Notes", start: .zero, length: .quarterNotes(8), content: .midi(MIDISequence(notes: notes)))
    var track = Track(name: "Keys", kind: .softwareInstrument)
    track.regions = [region]
    return (Project(tracks: [track]), region.id)
  }

  private func notes(_ project: Project, _ regionID: Region.ID) -> [MIDINote] {
    guard case .midi(let sequence) = project.region(withID: regionID)?.content else { return [] }
    return sequence.notes
  }

  @Test func mutedNotesDontPlayButAreKept() throws {
    let kept = MIDINote(pitch: 60, start: .zero, length: Tick(480))
    let muted = MIDINote(pitch: 62, start: Tick(480), length: Tick(480), isMuted: true)
    let (project, regionID) = noteProject([kept, muted])
    let region = try #require(project.region(withID: regionID))
    #expect(region.playedNotes.map(\.id) == [kept.id])
    // Saved and read back, and older songs (without the flag) still open.
    let data = try ProjectArchive.encode(project)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let tracks = try #require(json["tracks"] as? [[String: Any]])
    let regions = try #require(tracks.first?["regions"] as? [[String: Any]])
    let content = try #require(regions.first?["content"] as? [String: Any])
    let midi = try #require((content["midi"] as? [String: Any])?["_0"] as? [String: Any])
    let saved = try #require(midi["notes"] as? [[String: Any]])
    #expect(saved.map { $0["isMuted"] != nil } == [false, true], "Only the muted note says so")
    let reread = try ProjectArchive.decode(data)
    #expect(notes(reread, regionID).map(\.isMuted) == [false, true])
  }

  @Test func scissorsSplitNotesAndGlueJoinsThem() throws {
    let long = MIDINote(pitch: 60, start: .zero, length: Tick(1920))
    let other = MIDINote(pitch: 64, start: Tick(2000), length: Tick(480))
    var (project, regionID) = noteProject([long, other])
    let split = SplitNotes([long.id, other.id], at: Tick(960), in: regionID)
    try split.apply(to: &project)
    let halves = notes(project, regionID).filter { $0.pitch == 60 }
    #expect(halves.map(\.start) == [.zero, Tick(960)])
    #expect(halves.map(\.length) == [Tick(960), Tick(960)])
    #expect(halves.last?.id == split.newNoteIDs[long.id])
    #expect(notes(project, regionID).count == 3, "The note not under the cut is left alone")

    try GlueNotes(Set(halves.map(\.id)), in: regionID).apply(to: &project)
    let glued = notes(project, regionID).filter { $0.pitch == 60 }
    #expect(glued.count == 1 && glued.first?.length == Tick(1920) && glued.first?.id == long.id)
  }

  @Test func legatoAndRemovingOverlaps() throws {
    let a = MIDINote(pitch: 60, start: .zero, length: Tick(100))
    let b = MIDINote(pitch: 64, start: Tick(480), length: Tick(100))
    let c = MIDINote(pitch: 67, start: Tick(960), length: Tick(100))
    #expect(NoteFunction.legato.apply(to: [a, b, c]).map(\.length) == [Tick(480), Tick(480), Tick(100)])

    let first = MIDINote(pitch: 60, start: .zero, length: Tick(960))
    let second = MIDINote(pitch: 60, start: Tick(480), length: Tick(480))
    let chord = MIDINote(pitch: 64, start: Tick(240), length: Tick(960))
    let fixed = NoteFunction.removeOverlaps.apply(to: [first, second, chord])
    #expect(fixed.map(\.length) == [Tick(480), Tick(480), Tick(960)], "Only same-pitch overlaps are cut")
  }

  @Test func velocityTransposeReverseAndInvert() {
    let low = MIDINote(pitch: 48, velocity: 100, start: .zero, length: Tick(480))
    let high = MIDINote(pitch: 72, velocity: 120, start: Tick(960), length: Tick(960))
    #expect(NoteFunction.scaleVelocity(1.2).apply(to: [low, high]).map(\.velocity) == [120, 127], "Clamped at 127")
    #expect(NoteFunction.addVelocity(-110).apply(to: [low]).first?.velocity == 1)
    #expect(NoteFunction.transpose(12).apply(to: [low, high]).map(\.pitch) == [60, 84])
    #expect(NoteFunction.transpose(60).apply(to: [high]).first?.pitch == 72, "Out of range: left alone")
    let reversed = NoteFunction.reverse.apply(to: [low, high])
    #expect(reversed.map(\.start) == [Tick(1440), .zero], "The last note now starts the phrase")
    #expect(NoteFunction.invert.apply(to: [low, high]).map(\.pitch) == [72, 48])
  }

  @Test func humanizingIsRepeatableAndWithinItsRange() {
    let notes = (0..<16).map { MIDINote(pitch: 60, velocity: 100, start: Tick(240) * Int64($0 + 1), length: Tick(120)) }
    let function = NoteFunction.humanize(timing: Tick(20), velocity: 10, seed: 42)
    let once = function.apply(to: notes), again = function.apply(to: notes)
    #expect(once == again)
    #expect(zip(once, notes).allSatisfy { abs(($0.start - $1.start).rawValue) <= 20 && abs($0.velocity - $1.velocity) <= 10 })
    #expect(zip(once, notes).contains { $0.start != $1.start }, "Something moved")
  }

  @Test func quantizeStrengthAndSwing() throws {
    let late = MIDINote(pitch: 60, start: Tick(100), length: Tick(120))
    let offBeat = MIDINote(pitch: 62, start: Tick(240), length: Tick(120))
    var (project, regionID) = noteProject([late, offBeat])
    try QuantizeNotes(in: regionID, noteIDs: [late.id], grid: Tick(240), strength: 0.5).apply(to: &project)
    #expect(notes(project, regionID).first { $0.id == late.id }?.start == Tick(50), "Half way to the line")
    try QuantizeNotes(in: regionID, noteIDs: [offBeat.id], grid: Tick(240), swing: 1).apply(to: &project)
    #expect(notes(project, regionID).first { $0.id == offBeat.id }?.start == Tick(320), "The off-beat swings a third late")
  }

  @Test func tripletsQuantizeExactlyAndMixedQuantizePicksTheNearerGrid() throws {
    // A loose 1/8-triplet run on beat 2 of 4/4 (exact: 960, 1280, 1600), and a straight
    // 1/16 on the and-a of beat 3 (2160).
    let triplets = [Tick(950), Tick(1300), Tick(1590)].map { MIDINote(pitch: 60, start: $0, length: Tick(200)) }
    let sixteenth = MIDINote(pitch: 64, start: Tick(2170), length: Tick(100))
    var (project, regionID) = noteProject(triplets + [sixteenth])
    try QuantizeNotes(in: regionID, noteIDs: Set(triplets.map(\.id)), grid: Tick(320)).apply(to: &project)
    #expect(notes(project, regionID).filter { $0.pitch == 60 }.map(\.start) == [Tick(960), Tick(1280), Tick(1600)])

    // "1/16 & 1/12": both kinds land where they were meant; 1/16 alone would wreck the triplets.
    (project, regionID) = noteProject(triplets + [sixteenth])
    try QuantizeNotes(in: regionID, grid: Tick(240), alternativeGrid: Tick(320)).apply(to: &project)
    #expect(notes(project, regionID).map(\.start) == [Tick(960), Tick(1280), Tick(1600), Tick(2160)])
    (project, regionID) = noteProject(triplets + [sixteenth])
    try QuantizeNotes(in: regionID, grid: Tick(240)).apply(to: &project)
    #expect(notes(project, regionID).map(\.start) == [Tick(960), Tick(1200), Tick(1680), Tick(2160)])
  }

  @Test func compoundMetersFeelTheirBeatsInThrees() {
    let twelveEight = TimeSignature(beatsPerBar: 12, beatUnit: 8)
    #expect(twelveEight.isCompound && twelveEight.pulse == Tick(1440) && twelveEight.ticksPerBar == Tick(5760))
    #expect(TimeSignature(beatsPerBar: 6, beatUnit: 8).pulse == Tick(1440))
    #expect(!TimeSignature.fourFour.isCompound && TimeSignature.fourFour.pulse == Tick(960))
    #expect(!TimeSignature(beatsPerBar: 3, beatUnit: 8).isCompound, "3/8 is felt in one, not a compound meter")
    #expect(!TimeSignature(beatsPerBar: 6, beatUnit: 4).isCompound)
  }

  @Test func noteFunctionsApplyAsOneUndoableCommand() throws {
    let a = MIDINote(pitch: 60, start: .zero, length: Tick(480))
    let b = MIDINote(pitch: 62, start: Tick(480), length: Tick(480))
    var (project, regionID) = noteProject([a, b])
    try ApplyNoteFunction(.mute(true), to: [b.id], in: regionID).apply(to: &project)
    #expect(notes(project, regionID).map(\.isMuted) == [false, true])
    try ApplyNoteFunction(.setLength(Tick(240)), to: nil, in: regionID).apply(to: &project)
    #expect(notes(project, regionID).allSatisfy { $0.length == Tick(240) })
  }
}

// MARK: - MIDI FX slots

extension EditCommandTests {
  @Test func midiEffectsAreAddedMovedChangedAndRemoved() throws {
    var (project, _) = noteProject([])
    let trackID = project.tracks[0].id
    let arp = MIDIEffect(.arpeggiator(Arpeggiator()))
    let chords = MIDIEffect(.chordTrigger(ChordTrigger()))
    try AddMIDIEffect(arp, to: trackID).apply(to: &project)
    try AddMIDIEffect(chords, to: trackID, at: 0).apply(to: &project)
    #expect(project.tracks[0].channel.midiEffects.map(\.id) == [chords.id, arp.id], "The chord trigger goes first")
    try MoveMIDIEffect(chords.id, in: trackID, to: 1).apply(to: &project)
    #expect(project.tracks[0].channel.midiEffects.map(\.id) == [arp.id, chords.id])
    var changed = arp
    changed.settings = .arpeggiator(Arpeggiator(rate: .eighth, order: .down))
    changed.isBypassed = true
    try UpdateMIDIEffect(changed, in: trackID).apply(to: &project)
    #expect(project.tracks[0].channel.midiEffects[0] == changed)
    try RemoveMIDIEffect(arp.id, from: trackID).apply(to: &project)
    #expect(project.tracks[0].channel.midiEffects.map(\.id) == [chords.id])

    // Only instrument tracks have MIDI effects, and at most eight.
    project.tracks.append(Track(name: "Audio", kind: .audio))
    #expect(throws: EditError.self) { try AddMIDIEffect(MIDIEffect(.transposer(Transposer())), to: project.tracks[1].id).apply(to: &project) }
    for _ in 0..<7 { try AddMIDIEffect(MIDIEffect(.transposer(Transposer())), to: trackID).apply(to: &project) }
    #expect(throws: EditError.self) { try AddMIDIEffect(MIDIEffect(.transposer(Transposer())), to: trackID).apply(to: &project) }
  }
}

// MARK: - Step Sequencer patterns

extension EditCommandTests {
  /// A one-bar pattern region holding `pattern`.
  private func patternProject(_ pattern: StepPattern, bars: Int64 = 1) -> (Project, Region.ID) {
    var region = Region(name: "Pattern", start: .zero, length: Tick(3840) * bars, content: .midi(MIDISequence()), pattern: pattern)
    region.renderPattern()
    var track = Track(name: "Drums", kind: .softwareInstrument)
    track.regions = [region]
    return (Project(tracks: [track]), region.id)
  }

  private func row(_ pitch: Int, on steps: [Int], count: Int = 16, configure: (inout StepPattern.Row) -> Void = { _ in }) -> StepPattern.Row {
    var row = StepPattern.Row(pitch: pitch, name: "\(pitch)", steps: (0..<count).map { StepPattern.Step(isOn: steps.contains($0)) })
    configure(&row)
    return row
  }

  @Test func theDrumPatternPlaysABackbeatAndFillsTheRegion() throws {
    let (project, regionID) = patternProject(.drums(), bars: 2)
    let played = notes(project, regionID)
    #expect(played.filter { $0.pitch == 36 }.map(\.start) == [0, 1920, 3840, 5760].map { Tick($0) }, "Kick on 1 and 3, both bars")
    #expect(played.filter { $0.pitch == 38 }.map(\.start) == [960, 2880, 4800, 6720].map { Tick($0) }, "Snare on 2 and 4")
    #expect(played.filter { $0.pitch == 42 }.count == 16, "Eighth-note hats")
  }

  @Test func rowsHaveTheirOwnLengthRateDirectionAndRepeats() {
    let sixteenth = Tick(240)
    // Three steps long: the hit comes round every three sixteenths, against the bar.
    var pattern = StepPattern(rows: [row(60, on: [0], count: 3) { $0.length = 3 }])
    #expect(pattern.notes(over: Tick(3840)).map(\.start) == (0..<6).map { sixteenth * 3 * Int64($0) })

    pattern.rows = [row(60, on: [0, 1], count: 4) { $0.length = 4; $0.rate = .eighth }]
    #expect(pattern.notes(over: Tick(1920)).map(\.start) == [.zero, Tick(480)], "Eighths, four steps a loop")

    pattern.rows = [row(60, on: [0], count: 4) { $0.length = 4; $0.direction = .backward }]
    #expect(pattern.notes(over: Tick(960)).map(\.start) == [sixteenth * 3], "Backward: step 1 plays last")
    #expect((0..<6).map { pattern.stepIndex(of: StepPattern.Row(pitch: 60, name: "", length: 4, direction: .pingPong), at: $0) } == [0, 1, 2, 3, 2, 1])

    var roll = row(38, on: [0], count: 1) { $0.length = 1 }
    roll.steps[0].repeats = 4
    pattern.rows = [roll]
    #expect(pattern.notes(over: sixteenth).map(\.start) == [0, 60, 120, 180].map { Tick($0) }, "A roll of four in one sixteenth")
  }

  @Test func swingChanceVelocityAndGate() {
    var pattern = StepPattern(rows: [row(42, on: Array(0..<16))], swing: 1)
    let swung = pattern.notes(over: Tick(3840))
    #expect(swung[1].start == Tick(240 + 80), "The off-beat sixteenth is a third of a step late")
    #expect(swung[2].start == Tick(480))

    pattern.swing = 0
    pattern.rows[0].steps = pattern.rows[0].steps.map { var step = $0; step.chance = 50; step.velocity = 64; step.gate = 0.5; return step }
    let once = pattern.notes(over: Tick(3840 * 4)), again = pattern.notes(over: Tick(3840 * 4))
    #expect(once == again.map { var note = $0; note.id = once.first { $0.start == note.start }?.id ?? note.id; return note }, "The same steps play every time")
    #expect(once.count > 16 && once.count < 48, "About half of 64 steps: \(once.count)")
    #expect(once.allSatisfy { $0.velocity == 64 && $0.length == Tick(120) })
  }

  @Test func patternRegionsFollowResizingAndConvertToNotes() throws {
    var (project, regionID) = patternProject(.drums())
    #expect(notes(project, regionID).filter { $0.pitch == 36 }.count == 2)
    try TrimRegion(regionID, start: .zero, length: Tick(7680)).apply(to: &project)
    #expect(notes(project, regionID).filter { $0.pitch == 36 }.count == 4, "Twice as long: the pattern plays twice")

    var pattern = try #require(project.region(withID: regionID)?.pattern)
    pattern.rows[0].isMuted = true
    try SetStepPattern(pattern, for: regionID).apply(to: &project)
    #expect(!notes(project, regionID).contains { $0.pitch == 36 }, "A muted row doesn't play")

    let saved = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(saved.region(withID: regionID)?.pattern == pattern)

    try ConvertPatternToNotes([regionID]).apply(to: &project)
    #expect(project.region(withID: regionID)?.pattern == nil)
    #expect(notes(project, regionID).count == notes(saved, regionID).count, "The notes it played stay")
  }

  @Test func splittingAPatternKeepsWhatItPlays() throws {
    var (project, regionID) = patternProject(.drums(), bars: 2)
    let before = notes(project, regionID).map { $0.start }
    let split = SplitRegion(regionID, at: Tick(3840 + 480))
    try split.apply(to: &project)
    let left = try #require(project.region(withID: regionID)), right = try #require(project.region(withID: split.newRegionID))
    #expect(left.pattern == nil && right.pattern == nil)
    let after = notes(project, regionID).map(\.start) + notes(project, split.newRegionID).map { $0.start + right.start }
    #expect(after.sorted() == before.sorted())
  }
}

// MARK: - Drummer

extension EditCommandTests {
  private func drummerProject(_ drummer: DrummerPerformance, bars: Int = 4, signature: TimeSignature = .fourFour) -> (Project, Region.ID) {
    var project = Project()
    try? project.tempoMap.setTimeSignature(signature, atBarIndex: 0)
    var region = Region(
      name: "Drummer", start: .zero, length: signature.ticksPerBar * Int64(bars), content: .midi(MIDISequence()), drummer: drummer)
    region.renderDrummer(tempoMap: project.tempoMap)
    project.tracks = [Track(name: "Drums", kind: .softwareInstrument, regions: [region])]
    return (project, region.id)
  }

  @Test func theDrummerKeepsTimeWithABackbeatAndFillsAtTheEnd() {
    let part = DrummerPerformance(style: .rock, complexity: 0.3, loudness: 0.5, fills: 0.5, fillsAtEnd: true, seed: 7)
    let (project, regionID) = drummerProject(part)
    let played = notes(project, regionID)
    let firstBar = played.filter { $0.start < Tick(3840) }
    #expect(firstBar.contains { $0.pitch == 36 && $0.start == .zero }, "A kick on the downbeat")
    // Snares on beats 2 and 4, give or take the human touch.
    for beat in [1, 3] {
      #expect(firstBar.contains { $0.pitch == 38 && abs(($0.start - Tick(960) * Int64(beat)).rawValue) <= 5 })
    }
    #expect(firstBar.filter { $0.pitch == 42 }.count == 8, "Eighth-note hi-hats")
    let lastBar = played.filter { $0.start >= Tick(3840 * 3) }
    #expect(lastBar.contains { [45, 47, 50].contains($0.pitch) }, "Toms in the fill into the next section")
    #expect(played.allSatisfy { $0.start >= .zero && $0.start < Tick(3840 * 4) && MIDINote.velocityRange.contains($0.velocity) })
  }

  @Test func theDrummerIsTheSameEachTimeUntilANewTake() {
    let part = DrummerPerformance(style: .funk, complexity: 0.8, seed: 3)
    let played = { (part: DrummerPerformance) -> [String] in
      let (project, regionID) = self.drummerProject(part)
      return self.notes(project, regionID).map { "\($0.pitch) \($0.start.rawValue) \($0.velocity)" }
    }
    #expect(played(part) == played(part))
    var other = part
    other.seed = 4
    #expect(played(part) != played(other))
  }

  @Test func busierAndLouderPartsPlayMoreAndHarder() {
    let quiet = drummerProject(DrummerPerformance(style: .funk, complexity: 0.1, loudness: 0.2, fills: 0, seed: 1))
    let busy = drummerProject(DrummerPerformance(style: .funk, complexity: 0.95, loudness: 0.9, fills: 0, seed: 1))
    let quietNotes = notes(quiet.0, quiet.1), busyNotes = notes(busy.0, busy.1)
    #expect(busyNotes.count > quietNotes.count + 16)
    let average = { (notes: [MIDINote]) in Double(notes.map(\.velocity).reduce(0, +)) / Double(max(1, notes.count)) }
    #expect(average(busyNotes.filter { $0.pitch == 38 && $0.velocity > 60 }) > average(quietNotes.filter { $0.pitch == 38 }) + 20)
  }

  @Test func theDrummerPlaysCompoundAndOddMeters() {
    let twelveEight = drummerProject(DrummerPerformance(style: .rock, fills: 0, seed: 2), bars: 2, signature: TimeSignature(beatsPerBar: 12, beatUnit: 8))
    let played = notes(twelveEight.0, twelveEight.1).filter { $0.start < Tick(5760) }
    // Snares on the second and fourth dotted quarters.
    #expect(played.filter { $0.pitch == 38 && $0.velocity > 50 }.map { ($0.start.rawValue + 20) / 1440 }.sorted() == [1, 3])
    #expect(played.filter { $0.pitch == 42 }.count == 12, "An eighth-note hi-hat through the bar")
    #expect(DrummerPerformance.pulses(of: TimeSignature(beatsPerBar: 7, beatUnit: 8)).map(\.length) == [4, 4, 6])
  }

  @Test func drummerRegionsFollowEditsResizingAndTheMeter() throws {
    var (project, regionID) = drummerProject(DrummerPerformance(style: .rock, fills: 0, seed: 5), bars: 2)
    try SetDrummerPerformance(for: [regionID]) { $0.style = .electronic }.apply(to: &project)
    #expect(project.region(withID: regionID)?.drummer?.style == .electronic)
    #expect(notes(project, regionID).filter { $0.pitch == 36 && $0.velocity > 40 }.count >= 8, "Four on the floor")
    try TrimRegion(regionID, start: .zero, length: Tick(3840 * 4)).apply(to: &project)
    #expect(notes(project, regionID).contains { $0.start >= Tick(3840 * 3) }, "Resizing plays into the new bars")
    try SetTimeSignature(TimeSignature(beatsPerBar: 3, beatUnit: 4), atBarIndex: 0).apply(to: &project)
    #expect(!notes(project, regionID).contains { $0.pitch == 38 && abs(($0.start - Tick(960 * 3)).rawValue) <= 5 && $0.velocity > 50 },
      "In 3/4 the next bar starts where beat 4 was, so no backbeat there")
    try ConvertPatternToNotes([regionID]).apply(to: &project)
    #expect(project.region(withID: regionID)?.drummer == nil && !notes(project, regionID).isEmpty)
    #expect(throws: EditError.self) { try SetDrummerPerformance(for: [regionID]) { $0.loudness = 1 }.apply(to: &project) }
  }

  @Test func sectionsSetHowTheDrummerPlays() throws {
    let chorus = DrummerPerformance.forSection(named: "Chorus", style: .pop, kit: .generalMIDI, isFirst: false, isLast: false, seed: 1)
    let intro = DrummerPerformance.forSection(named: "Intro", style: .pop, kit: .generalMIDI, isFirst: true, isLast: false, seed: 1)
    let outro = DrummerPerformance.forSection(named: "Outro", style: .pop, kit: .generalMIDI, isFirst: false, isLast: true, seed: 1)
    #expect(chorus.loudness > intro.loudness && chorus.complexity > intro.complexity)
    #expect(chorus.crashesAtStart && !intro.crashesAtStart && !outro.fillsAtEnd)
    var region = Region(name: "Chorus", start: .zero, length: Tick(3840), content: .midi(MIDISequence()), drummer: chorus)
    region.renderDrummer(tempoMap: TempoMap())
    let saved = try ProjectArchive.decode(ProjectArchive.encode(Project(tracks: [Track(name: "Drums", kind: .softwareInstrument, regions: [region])])))
    #expect(saved.tracks[0].regions[0] == region)
  }

  @Test func splitDrummerRegionsKeepPlayingAndJoinBackIntoOne() throws {
    let part = DrummerPerformance(style: .rock, fills: 0.6, fillsAtEnd: true, crashesAtStart: true, seed: 5)
    var (project, regionID) = drummerProject(part, bars: 4)
    // What plays: generated notes get new identifiers each time.
    let played = { (notes: [MIDINote]?) in (notes ?? []).map { "\($0.pitch) \($0.start.rawValue) \($0.velocity) \($0.length.rawValue)" } }
    let whole = played(notes(project, regionID))
    let split = SplitRegion(regionID, at: Tick(3840 * 2))
    try split.apply(to: &project)
    let left = try #require(project.region(withID: regionID)), right = try #require(project.region(withID: split.newRegionID))
    #expect(left.drummer?.crashesAtStart == true && left.drummer?.fillsAtEnd == false, "The crash stays at the start")
    #expect(right.drummer?.crashesAtStart == false && right.drummer?.fillsAtEnd == true, "The fill stays at the end")
    for half in [left, right] {
      #expect(played(notes(project, half.id)) == played(half.drummer?.notes(from: half.start, length: half.length, tempoMap: project.tempoMap)),
        "Each half plays for its own length")
    }
    #expect(notes(project, split.newRegionID).contains { $0.start >= Tick(3840) && [45, 47, 50].contains($0.pitch) },
      "The right half fills into what follows")

    let glue = GlueRegions([regionID, split.newRegionID])
    #expect(glue.actionName(in: project) == "Join Regions")
    try glue.apply(to: &project)
    #expect(project.region(withID: regionID)?.drummer == part, "Joined, it's the drummer it was")
    #expect(played(notes(project, regionID)) == whole)

    // Halves set differently can't carry on as one drummer, so they become their notes.
    let again = SplitRegion(regionID, at: Tick(3840 * 2))
    try again.apply(to: &project)
    try SetDrummerPerformance(for: [again.newRegionID]) { $0.loudness = 1 }.apply(to: &project)
    let mismatched = GlueRegions([regionID, again.newRegionID])
    #expect(mismatched.actionName(in: project) == "Join and Convert to MIDI")
    try mismatched.apply(to: &project)
    #expect(project.region(withID: regionID)?.drummer == nil && !notes(project, regionID).isEmpty)
  }

  @Test func splitPlayerRegionsKeepFollowingTheChordsAndJoinBack() throws {
    var (project, regionID) = playerProject(.rootNotes, chords: ["C", "Am", "F", "G"])
    try SetPlayerPerformance(for: [regionID]) { $0.leadsIntoNext = true }.apply(to: &project)
    let part = try #require(project.region(withID: regionID)?.player)
    let split = SplitRegion(regionID, at: Tick(3840 * 2))
    try split.apply(to: &project)
    let left = try #require(project.region(withID: regionID)), right = try #require(project.region(withID: split.newRegionID))
    #expect(left.player?.leadsIntoNext == false && right.player?.leadsIntoNext == true, "The lead-in stays at the end")
    let firstNote = try #require(notes(project, split.newRegionID).min { $0.start < $1.start })
    #expect(firstNote.pitch % 12 == 5, "The right half starts on the F it's over")

    try GlueRegions([regionID, split.newRegionID]).apply(to: &project)
    #expect(project.region(withID: regionID)?.player == part)
    let joined = try #require(project.region(withID: regionID))
    let expected = part.notes(from: joined.start, length: joined.length, tempoMap: project.tempoMap, chords: project.chordTimeline)
    #expect(notes(project, regionID).map { "\($0.pitch) \($0.start.rawValue)" } == expected.map { "\($0.pitch) \($0.start.rawValue)" },
      "Joined, it plays the whole part again")
  }
}

// MARK: - Session Drummer songs

extension EditCommandTests {
  @Test func aDrummerSongPlaysItsSectionsInOrderAndRepeats() {
    var song = DrummerSong.starter(style: .rock, layout: [("Verse", 2), ("Chorus", 2)])
    #expect(song.totalBars() == 4)
    #expect(song.section(atBar: 0)?.index == 0 && song.section(atBar: 2)?.index == 1 && song.section(atBar: 3)?.barInSection == 1)
    #expect(song.section(atBar: 4)?.index == 0, "Repeats from the top")
    song.repeats = false
    #expect(song.section(atBar: 9)?.index == 1, "Without repeating, the last section carries on")

    let notes = song.notes(in: .fourFour)
    #expect(notes.allSatisfy { $0.channel == 9 && $0.start >= .zero && $0.start < Tick(3840 * 4) })
    #expect(notes.contains { $0.pitch == 36 && $0.start == .zero })
    #expect(notes.contains { $0.pitch == 49 && abs(($0.start - Tick(3840 * 2)).rawValue) <= 5 }, "The chorus crashes in")
    #expect(song.lengthInQuarterNotes(in: .fourFour) == 16)
    #expect(song.lengthInQuarterNotes(in: TimeSignature(beatsPerBar: 6, beatUnit: 8)) == 12)
  }

  @Test func aDrummerSongWritesAMIDIFile() throws {
    let song = DrummerSong.starter(style: .pop, layout: [("Verse", 2)])
    let data = song.midiFile(signature: .fourFour, bpm: 96, times: 2)
    let contents = try StandardMIDIFile.read(data)
    let notes = contents.tracks.flatMap(\.regions).flatMap { region -> [MIDINote] in
      if case .midi(let sequence) = region.content { return sequence.notes }
      return []
    }
    #expect(notes.count == song.notes(in: .fourFour).count * 2)
    #expect(contents.tempoMap.tempo(at: .zero) == 96)
    let saved = try JSONDecoder().decode(DrummerSong.self, from: JSONEncoder().encode(song))
    #expect(saved == song)
  }
}

// MARK: - The Purdie shuffle

extension EditCommandTests {
  private func shuffle(_ signature: TimeSignature = .fourFour, feel: DrummerPerformance.Feel = .normal) -> [MIDINote] {
    let part = DrummerPerformance(style: .shuffle, complexity: 0.5, loudness: 0.5, fills: 0, feel: feel, seed: 11)
    let tempoMap = TempoMap(bpm: 100, timeSignature: signature)
    return part.notes(from: .zero, length: signature.ticksPerBar, tempoMap: tempoMap)
  }

  private func near(_ notes: [MIDINote], _ pitch: Int, _ tick: Int64) -> MIDINote? {
    notes.first { $0.pitch == pitch && abs($0.start.rawValue - tick) <= 6 }
  }

  @Test func thePurdieShufflePlaysOnTriplets() {
    let bar = shuffle()
    // The hi-hat on each beat's first and last triplet, never the middle one.
    for beat in Int64(0)..<4 {
      #expect(near(bar, 42, beat * 960) != nil && near(bar, 42, beat * 960 + 640) != nil, "Hi-hat on beat \(beat + 1)")
      #expect(near(bar, 42, beat * 960 + 320) == nil, "No hi-hat on the middle triplet of beat \(beat + 1)")
    }
    #expect(bar.filter { $0.pitch == 42 }.count == 8)
    // Ghost notes in the middle of the beats; the backbeat once, on 3.
    let ghosts = (Int64(0)..<4).compactMap { near(bar, 38, $0 * 960 + 320) }
    #expect(ghosts.count >= 3 && ghosts.allSatisfy { $0.velocity < 50 }, "Ghost notes between the hi-hats")
    let accents = bar.filter { $0.pitch == 38 && $0.velocity > 60 }
    #expect(accents.count == 1 && accents.first.map { abs($0.start.rawValue - 1920) <= 6 } == true, "Half-time backbeat on 3")
    // The kick on 1, and pushing the last triplet of 2.
    #expect(near(bar, 36, 0) != nil && near(bar, 36, 960 + 640) != nil)
    // Nothing on a straight sixteenth that isn't a triplet.
    #expect(!bar.contains { [240, 720].contains($0.start.rawValue % 960) }, "Triplets, not sixteenths")
  }

  @Test func thePurdieShuffleInDoubleTimeAndTwelveEight() {
    let doubled = shuffle(feel: .doubleTime)
    let accents = doubled.filter { $0.pitch == 38 && $0.velocity > 60 }.map { ($0.start.rawValue + 6) / 960 }.sorted()
    #expect(accents == [1, 3], "Double time puts the backbeat on 2 and 4")

    let twelveEight = shuffle(TimeSignature(beatsPerBar: 12, beatUnit: 8))
    for pulse in Int64(0)..<4 {
      #expect(near(twelveEight, 42, pulse * 1440) != nil && near(twelveEight, 42, pulse * 1440 + 960) != nil,
        "12/8: the hi-hat on the first and third eighth of each beat")
    }
  }
}

extension EditCommandTests {
  @Test func inTheShuffleSwingSetsHowHardTheGhostNotesAre() {
    func ghosts(_ swing: Double) -> (ghosts: Double, backbeat: Int) {
      let part = DrummerPerformance(style: .shuffle, complexity: 0.5, loudness: 0.5, fills: 0, swing: swing, seed: 3)
      let notes = part.notes(from: .zero, length: Tick(3840 * 4), tempoMap: TempoMap())
      // The middle triplet of each beat.
      let ghosts = notes.filter { $0.pitch == 38 && abs($0.start.rawValue % 960 - 320) <= 6 }
      let backbeat = notes.filter { $0.pitch == 38 && $0.velocity > 70 }.map(\.velocity).max() ?? 0
      return (Double(ghosts.map(\.velocity).reduce(0, +)) / Double(max(1, ghosts.count)), backbeat)
    }
    let whisper = ghosts(0), hard = ghosts(1)
    #expect(whisper.ghosts < 25 && hard.ghosts > 50, "Whispered \(whisper.ghosts), hard \(hard.ghosts)")
    #expect(abs(whisper.backbeat - hard.backbeat) <= 6, "The backbeat stays as it was")
    #expect(DrummerPerformance(style: .shuffle).swing == 0.4, "A new shuffle starts with soft ghosts")
  }
}

// MARK: - Chords and session players

extension EditCommandTests {
  @Test func chordNamesAreReadAndWritten() throws {
    let names = ["C", "Am", "G7", "Fmaj7", "Dm7", "Bdim", "Bm7♭5", "Caug", "Dsus4", "Esus2", "A6", "Cm6", "Cadd9", "G9",
      "Am9", "E5", "C/E", "F♯m", "B♭", "E♭maj7"]
    for name in names {
      let chord = try #require(Chord(name: name), "\(name) reads")
      #expect(chord.description == name, "\(name) writes back as \(chord.description)")
    }
    #expect(Chord(name: "Bb")?.description == "B♭" && Chord(name: "F#m7")?.description == "F♯m7")
    #expect(Chord(name: "CΔ7")?.quality == .major7 && Chord(name: "C-7")?.quality == .minor7 && Chord(name: "Cø")?.quality == .halfDiminished)
    #expect(Chord(name: "H7") == nil && Chord(name: "Cblah") == nil && Chord(name: "") == nil)
    #expect(Chord(name: "C/E")?.pitchClasses == [0, 4, 7] && Chord(name: "C/E")?.bassNote == 4)
    #expect(Chord(name: "C/C")?.bass == nil, "A slash of its own root is just the chord")
  }

  @Test func chordsAreFoundInPlayedNotes() {
    // Am for a bar (A C E), then F/C (C F A, C lowest), then G7 (G B D F).
    func notes(_ pitches: [Int], at bar: Int64) -> [MIDINote] {
      pitches.map { MIDINote(pitch: $0, velocity: 90, start: Tick(3840 * bar), length: Tick(3840)) }
    }
    let region = Region(
      name: "Keys", start: .zero, length: Tick(3840 * 3),
      content: .midi(MIDISequence(notes: notes([57, 60, 64], at: 0) + notes([48, 65, 69, 72], at: 1) + notes([55, 59, 62, 65], at: 2))))
    let project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [region])])
    let found = project.detectChords(in: region)
    #expect(found.map(\.chord.description) == ["Am", "F/C", "G7"], "\(found.map(\.chord.description))")
    #expect(found.map(\.position) == [.zero, Tick(3840), Tick(3840 * 2)], "One change per chord, not per half bar")
  }

  /// A song with a bass player region and a chord per bar.
  private func playerProject(_ style: PlayerPerformance.Style, chords: [String], complexity: Double = 0.5)
    -> (Project, Region.ID)
  {
    var project = Project()
    project.chords = chords.enumerated().map { index, name in
      ChordChange(position: Tick(3840 * Int64(index)), chord: Chord(name: name)!)
    }
    var region = Region(
      name: "Verse", start: .zero, length: Tick(3840 * Int64(chords.count)), content: .midi(MIDISequence()),
      player: PlayerPerformance(style: style, complexity: complexity, leadsIntoNext: false, seed: 4))
    region.renderPlayer(in: project)
    project.tracks = [Track(name: "Bass", kind: .softwareInstrument, regions: [region])]
    return (project, region.id)
  }

  @Test func theBassPlayerFollowsTheChords() throws {
    let (project, regionID) = playerProject(.rootNotes, chords: ["C", "Am", "F", "G"])
    let played = notes(project, regionID)
    for (bar, root) in [0, 9, 5, 7].enumerated() {
      let downbeat = try #require(played.first { abs($0.start.rawValue - Int64(3840 * bar)) <= 8 }, "A note on bar \(bar + 1)")
      #expect(downbeat.pitch % 12 == root, "Bar \(bar + 1) starts on its chord's root")
      #expect((28...55).contains(downbeat.pitch), "In the bass's range: \(downbeat.pitch)")
    }
    // A slash chord's bass note is what the bass plays.
    let slash = playerProject(.rootNotes, chords: ["C/E"])
    #expect(notes(slash.0, slash.1).first?.pitch.isMultiple(of: 12) == false && notes(slash.0, slash.1).first.map { $0.pitch % 12 } == 4)
  }

  @Test func walkingBassStepsIntoTheNextChord() throws {
    let (project, regionID) = playerProject(.walking, chords: ["C", "F"])
    let played = notes(project, regionID).sorted { $0.start < $1.start }
    #expect(played.count == 5, "A note a beat, ending on a held root")
    let approach = try #require(played.last { $0.start < Tick(3840) })
    #expect([4, 6].contains(approach.pitch % 12), "Beat 4 of the C bar leads to F by a half step: \(approach.pitch % 12)")
    #expect(played.first { $0.start >= Tick(3840 - 8) }?.pitch.isMultiple(of: 12) == false)
  }

  @Test func bassFiguresAreWellWritten() {
    for style in PlayerPerformance.Style.styles(for: .bass) where style != .walking {
      let vocabulary = BassVocabulary.of(style)
      for figures in [vocabulary.grooves, vocabulary.variations, vocabulary.fills] {
        #expect(figures.count == 3, "\(style.title) has figures for each level")
        for figure in figures.joined() {
          #expect(figure.count == 16, "\(style.title) figure \(figure) is a bar of sixteenths")
          #expect(figure.allSatisfy { "R35678b24LNAWx-.".contains($0) }, "\(figure) uses known symbols")
          #expect(figure.first.map { "R8".contains($0) } == true, "\(figure) starts the bar on a note")
          #expect(!figure.contains(".-"), "\(figure) doesn't hold a rest")
        }
      }
    }
  }

  @Test func theBassPlaysInPhrases() throws {
    let (project, regionID) = playerProject(.funkBass, chords: Array(repeating: "C", count: 8))
    let played = notes(project, regionID)
    func rhythm(_ bar: Int) -> [Int64] {
      played.filter { $0.start.rawValue + 20 >= Int64(3840 * bar) && $0.start.rawValue + 20 < Int64(3840 * (bar + 1)) }
        .map { ($0.start.rawValue + 20 - Int64(3840 * bar)) / 240 }
    }
    #expect(rhythm(0) == rhythm(2) && rhythm(0) == rhythm(4), "The groove holds through the section")
    #expect(rhythm(3) != rhythm(0), "The fourth bar is a fill")
    #expect(played.contains { $0.velocity < 50 }, "Funk has dead notes")
    #expect(played.contains { $0.pitch % 12 == 10 }, "and the flat seventh")
  }

  @Test func walkingBassPassesThroughTheKey() throws {
    var (project, regionID) = playerProject(.walking, chords: ["Am", "Dm", "E7", "Am"])
    project.keySignature = KeySignature(tonic: 9, mode: .minor)
    try SetPlayerPerformance(for: [regionID]) { $0.complexity = 0.5 }.apply(to: &project)
    let played = notes(project, regionID).sorted { $0.start < $1.start }
    #expect(played.count == 13, "A note a beat, ending on a held root")
    let aMinor: Set<Int> = [9, 11, 0, 2, 4, 5, 7]
    for note in played where (note.start.rawValue + 20) % 3840 < 2880 {
      let chord = project.chord(at: note.start + Tick(20))
      #expect(aMinor.contains(note.pitch % 12) || chord.pitchClasses.contains(note.pitch % 12),
        "Beats 1–3 come from the key or the chord: \(note.pitch % 12) over \(chord)")
    }
    // The line moves: no note repeats on the next beat.
    for pair in zip(played, played.dropFirst()) { #expect(pair.0.pitch != pair.1.pitch) }
  }

  @Test func theKeysPlayerVoicesChordsSmoothly() throws {
    let (project, regionID) = playerProject(.blockChords, chords: ["C", "Am", "F", "G"])
    let played = notes(project, regionID)
    /// The right hand sounding just after a bar's downbeat (a chord pushed early holds over it).
    func rightHand(_ bar: Int) -> [Int] {
      let time = Int64(3840 * bar + 40)
      return played.filter { $0.start.rawValue <= time && $0.start.rawValue + $0.length.rawValue > time && $0.pitch >= 52 }
        .map(\.pitch).sorted()
    }
    for (bar, name) in ["C", "Am", "F", "G"].enumerated() {
      let chord = Chord(name: name)!
      let upper = rightHand(bar)
      #expect(upper.count >= 3 && upper.allSatisfy { chord.pitchClasses.contains($0 % 12) }, "Bar \(bar + 1) plays \(name): \(upper)")
      #expect(upper.contains { $0 % 12 == chord.root } && upper.contains { $0 % 12 == (chord.root + (chord.quality.isMinor ? 3 : 4)) % 12 })
    }
    // Moving between chords, the voicing moves little (the nearest inversion).
    for bar in 0..<3 {
      let (from, to) = (rightHand(bar), rightHand(bar + 1))
      let move = abs(Double(from.reduce(0, +)) / Double(from.count) - Double(to.reduce(0, +)) / Double(to.count))
      #expect(move <= 5, "Smooth voice leading: moved \(move) semitones on average")
    }
    // The left hand plays the roots, low.
    #expect(played.contains { $0.start.rawValue < 40 && $0.pitch < 52 && $0.pitch % 12 == 0 })
  }

  @Test func keysPlayersHaveTheirStylesColourAndPhrases() throws {
    // A pad adds the key's ninth to a plain chord, and re-voices it so its top line moves.
    let pad = playerProject(.pad, chords: Array(repeating: "C", count: 8), complexity: 0.5)
    let padNotes = notes(pad.0, pad.1)
    #expect(padNotes.contains { $0.pitch % 12 == 2 && $0.pitch >= 52 }, "Cadd9")
    // A ballad's left hand rolls through the chord under the pedal.
    let ballad = playerProject(.balladArpeggio, chords: ["C", "G"], complexity: 0.5)
    let left = notes(ballad.0, ballad.1).filter { $0.pitch < 52 && $0.start < Tick(3840) }
    #expect(left.count >= 6 && Set(left.map(\.pitch)).count >= 3, "Rolling through the chord: \(left.map(\.pitch))")
    // Funk stabs are short ninths and minor sevenths, on the off-beats too.
    let funk = playerProject(.funkStabs, chords: ["Am", "D", "Am", "D"], complexity: 0.5)
    let stabs = notes(funk.0, funk.1)
    #expect(stabs.allSatisfy { $0.length <= Tick(240) || $0.start >= Tick(3840 * 3) }, "Stabs are short")
    #expect(stabs.contains { $0.start < Tick(3840) && $0.pitch % 12 == 7 }, "Am7 has its G")
    #expect(stabs.contains { ($0.start.rawValue + 20) % 960 > 100 }, "Syncopated")
    // The groove holds, and the fourth bar turns around.
    let pop = playerProject(.popPulse, chords: Array(repeating: "C", count: 8), complexity: 0.5)
    let popNotes = notes(pop.0, pop.1)
    func bar(_ index: Int) -> Set<String> {
      Set(popNotes.filter { ($0.start.rawValue + 20) / 3840 == Int64(index) && $0.pitch >= 52 }
        .map { "\(($0.start.rawValue + 20) % 3840 / 240):\($0.pitch)" })
    }
    #expect(bar(0) == bar(2), "The groove holds")
    #expect(bar(3) != bar(0), "The fourth bar turns around")
  }

  @Test func progressionsPlayInAnyKey() throws {
    let pop = try #require(ChordProgression.named("Pop", mode: .major))
    #expect(pop.chords(in: KeySignature(tonic: 7, mode: .major)).map(\.description) == ["G", "D", "Em", "C"])
    #expect(ChordProgression.chord(numeral: "♭VII", in: .cMajor)?.description == "B♭")
    #expect(ChordProgression.chord(numeral: "iiø7", in: KeySignature(tonic: 9, mode: .minor))?.description == "Bm7♭5")
    #expect(ChordProgression.chord(numeral: "V7", in: KeySignature(tonic: 9, mode: .minor))?.description == "E7")
    for progression in ChordProgression.major + ChordProgression.minor {
      #expect(progression.chords(in: .cMajor).count == progression.numerals.count, "\(progression.name) reads")
    }
    // One chord a bar, repeating to fill the stretch; the song can come home at the end.
    let changes = pop.changes(in: .cMajor, from: .zero, to: Tick(3840 * 8), tempoMap: TempoMap(), endsHome: true)
    #expect(changes.map(\.chord.description) == ["C", "G", "Am", "F", "C", "G", "Am", "C"])
    #expect(changes.map(\.position) == (0..<8).map { Tick(3840 * Int64($0)) })
    // A song's verses and choruses differ, and every verse is the same.
    for song in 0..<4 {
      let verse = ChordProgression.forSection(named: "Verse", key: .cMajor, song: song)
      #expect(verse != ChordProgression.forSection(named: "Chorus", key: .cMajor, song: song))
      #expect(verse == ChordProgression.forSection(named: "verse", key: .cMajor, song: song))
    }
  }

  @Test func settingChordsReplacesAStretchAndPlayersFollow() throws {
    var (project, regionID) = playerProject(.rootNotes, chords: ["C", "C", "C", "C"])
    let blues = try #require(ChordProgression.named("Classic", mode: .major))
    let changes = blues.changes(in: .cMajor, from: Tick(3840), to: Tick(3840 * 3), tempoMap: project.tempoMap)
    try SetChords(changes, from: Tick(3840), to: Tick(3840 * 3)).apply(to: &project)
    #expect(project.chords.map(\.chord.description) == ["C", "C", "F", "C"], "Bars 2 and 3 replaced: \(project.chords.map(\.chord.description))")
    #expect(notes(project, regionID).contains { abs($0.start.rawValue - 3840 * 2) <= 20 && $0.pitch % 12 == 5 }, "The bass plays F in bar 3")
  }

  @Test func playersFollowChordTrackEditsAndAreSaved() throws {
    var (project, regionID) = playerProject(.drivingEighths, chords: ["C", "C"])
    try SetChord(Chord(name: "D")!, at: Tick(3840)).apply(to: &project)
    #expect(notes(project, regionID).first { $0.start >= Tick(3840 - 8) && $0.start < Tick(3840 + 30) }.map { $0.pitch % 12 } == 2,
      "The second bar plays D now")
    let chordID = try #require(project.chords.last?.id)
    try MoveChord(chordID, to: Tick(1920)).apply(to: &project)
    #expect(notes(project, regionID).contains { $0.start >= Tick(1910) && $0.start < Tick(2000) && $0.pitch % 12 == 2 })
    try DeleteChords([chordID]).apply(to: &project)
    #expect(notes(project, regionID).allSatisfy { $0.pitch % 12 == 0 })

    try SetPlayerPerformance(for: [regionID]) { $0.style = .walking }.apply(to: &project)
    #expect(project.region(withID: regionID)?.player?.style == .walking)
    let saved = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(saved.chords == project.chords && saved.tracks[0].regions[0] == project.tracks[0].regions[0])

    // Detecting chords from a MIDI part puts them on the Chord track.
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    let part = Region(name: "Part", start: Tick(3840 * 4), length: Tick(3840), content: .midi(MIDISequence(notes: [57, 60, 64].map {
      MIDINote(pitch: $0, velocity: 90, start: .zero, length: Tick(3840))
    })))
    keys.regions = [part]
    project.tracks.append(keys)
    try DetectChords(from: part.id).apply(to: &project)
    #expect(project.chord(at: Tick(3840 * 4 + 100)).description == "Am")
  }
}
