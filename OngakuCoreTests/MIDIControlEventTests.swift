//
//  MIDIControlEventTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Controllers, pitch bend and aftertouch in MIDI regions.
struct MIDIControlEventTests {
  @Test(arguments: [
    MIDIControlEvent(kind: .volume, channel: 2, position: .zero, value: 90),
    MIDIControlEvent(kind: .pitchBend, channel: 0, position: .zero, value: -8192),
    MIDIControlEvent(kind: .pitchBend, channel: 0, position: .zero, value: 8191),
    MIDIControlEvent(kind: .pitchBend, channel: 15, position: .zero, value: 0),
    MIDIControlEvent(kind: .channelPressure, channel: 9, position: .zero, value: 64),
    MIDIControlEvent(kind: .polyPressure(pitch: 60), channel: 1, position: .zero, value: 127),
  ])
  func messagesRoundTrip(event: MIDIControlEvent) throws {
    let parsed = try #require(MIDIControlEvent.parse(event.bytes, at: .zero))
    #expect(parsed.kind == event.kind)
    #expect(parsed.channel == event.channel)
    #expect(parsed.value == event.value)
  }

  @Test func pitchBendIsCentredAt8192() {
    #expect(MIDIControlEvent(kind: .pitchBend, position: .zero, value: 0).bytes == [0xE0, 0x00, 0x40])
    #expect(MIDIControlEvent(kind: .pitchBend, position: .zero, value: 8191).bytes == [0xE0, 0x7F, 0x7F])
  }

  @Test func notesAndChannelModeMessagesAreNotControls() {
    #expect(MIDIControlEvent.parse([0x90, 60, 100], at: .zero) == nil)
    #expect(MIDIControlEvent.parse([0xB0, 123, 0], at: .zero) == nil, "All Notes Off is a channel mode message")
    #expect(MIDIControlEvent.parse([0xC0, 5], at: .zero) == nil, "Program changes are kept elsewhere")
  }

  @Test func validity() {
    #expect(MIDIControlEvent(kind: .controller(120), position: .zero, value: 0).isValid == false)
    #expect(MIDIControlEvent(kind: .volume, position: .zero, value: 128).isValid == false)
    #expect(MIDIControlEvent(kind: .pitchBend, position: .zero, value: -8192).isValid)
    #expect(MIDIControlEvent(kind: .volume, channel: 16, position: .zero, value: 1).isValid == false)
  }

  @Test func sequencesWithoutControlsStillDecode() throws {
    let json = Data(#"{"notes":[{"channel":0,"id":"6F9E2B9C-3B1F-4E4A-9A8D-2B7C5E1D0A11","length":960,"pitch":60,"start":0,"velocity":100}]}"#.utf8)
    let sequence = try JSONDecoder().decode(MIDISequence.self, from: json)
    #expect(sequence.notes.count == 1)
    #expect(sequence.controls.isEmpty)
  }

  @Test func controlsAreSavedWithTheProject() throws {
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument)])
    let controls = [
      MIDIControlEvent(kind: .modulation, position: Tick(480), value: 40),
      MIDIControlEvent(kind: .pitchBend, channel: 3, position: Tick(960), value: -1000),
      MIDIControlEvent(kind: .polyPressure(pitch: 64), position: Tick(120), value: 77),
    ]
    let region = Region(name: "R", start: .zero, length: Tick(3840), content: .midi(MIDISequence(controls: controls)))
    project.tracks[0].regions = [region]
    #expect(try ProjectArchive.decode(ProjectArchive.encode(project)) == project)
  }

  // MARK: - Editing

  private func makeProject() -> (Project, Region.ID) {
    let controls = [
      MIDIControlEvent(kind: .volume, position: Tick(0), value: 100),
      MIDIControlEvent(kind: .volume, position: Tick(1920), value: 60),
      MIDIControlEvent(kind: .volume, position: Tick(3000), value: 20),
      MIDIControlEvent(kind: .pan, position: Tick(2000), value: 10),
    ]
    let region = Region(name: "R", start: Tick(3840), length: Tick(3840), content: .midi(MIDISequence(controls: controls)))
    return (Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [region])]), region.id)
  }

  private func controls(_ project: Project, _ index: Int = 0) -> [MIDIControlEvent] {
    guard case .midi(let sequence) = project.tracks[0].regions[index].content else { return [] }
    return sequence.controls
  }

  @Test func splittingSharesOutTheControls() throws {
    var (project, regionID) = makeProject()
    try SplitRegion(regionID, at: Tick(3840 + 1920)).apply(to: &project)
    #expect(controls(project, 0).map(\.position) == [Tick(0)])
    #expect(controls(project, 1).map(\.position) == [Tick(0), Tick(80), Tick(1080)])
  }

  @Test func trimmingTheStartKeepsControlsOnTheTimeline() throws {
    var (project, regionID) = makeProject()
    try TrimRegion(regionID, start: Tick(3840 + 960), length: Tick(2880)).apply(to: &project)
    #expect(controls(project).map(\.position) == [Tick(-960), Tick(960), Tick(1040), Tick(2040)])
  }

  @Test func addMoveAndDeleteControls() throws {
    var (project, regionID) = makeProject()
    let added = MIDIControlEvent(kind: .volume, position: Tick(500), value: 80)
    try AddControlEvents([added], to: regionID).apply(to: &project)
    #expect(controls(project).map(\.position) == [Tick(0), Tick(500), Tick(1920), Tick(2000), Tick(3000)])

    var moved = added
    moved.position = Tick(2500)
    moved.value = 10
    try UpdateControlEvents([moved], in: regionID).apply(to: &project)
    #expect(controls(project).first { $0.id == added.id }?.value == 10)
    #expect(controls(project).map(\.position) == [Tick(0), Tick(1920), Tick(2000), Tick(2500), Tick(3000)])

    try DeleteControlEvents([added.id], from: regionID).apply(to: &project)
    #expect(controls(project).count == 4)

    var invalid = moved
    invalid.value = 200
    #expect(throws: EditError.self) { try UpdateControlEvents([invalid], in: regionID).apply(to: &project) }
  }

  @Test func drawingReplacesOnlyThatControllerInTheRange() throws {
    var (project, regionID) = makeProject()
    let drawn = [
      MIDIControlEvent(kind: .volume, position: Tick(1800), value: 1),
      MIDIControlEvent(kind: .volume, position: Tick(2200), value: 2),
    ]
    try ReplaceControlEvents(.volume, channel: 0, over: Tick(1800)...Tick(2200), with: drawn, in: regionID).apply(to: &project)
    let volume = controls(project).filter { $0.kind == .volume }
    #expect(volume.map(\.value) == [100, 1, 2, 20], "The point at 1920 was drawn over")
    #expect(controls(project).contains { $0.kind == .pan }, "Pan is left alone")
  }
}
