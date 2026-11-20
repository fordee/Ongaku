//
//  RecordingModeTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Logic's Autopunch and Replace: what a recording keeps, and what it replaces.
struct RecordingModeTests {
  private let bar = Tick(3840)

  @Test func autopunchKeepsOnlyThePunchRange() {
    var project = Project()
    #expect(project.punchedRange(of: .zero..<(bar * 4)) == .zero..<(bar * 4), "Off: the whole take")
    project.punch = CycleRange(isEnabled: true, start: bar, end: bar * 3)
    #expect(project.punchedRange(of: .zero..<(bar * 4)) == bar..<(bar * 3))
    #expect(project.punchedRange(of: (bar * 2)..<(bar * 5)) == (bar * 2)..<(bar * 3))
    #expect(project.punchedRange(of: (bar * 3)..<(bar * 5)) == nil, "Missed the punch entirely")
  }

  @Test func replaceClearsTheRecordedStretch() throws {
    let note = { (beat: Double) in MIDINote(pitch: 60, start: .quarterNotes(beat), length: .quarterNotes(1)) }
    let long = Region(name: "Keys", start: .zero, length: bar * 4, content: .midi(MIDISequence(notes: [note(0), note(6), note(13)])))
    let inside = Region(name: "Fill", start: bar * 5, length: bar, content: .midi(MIDISequence()))
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [long, inside])])
    let trackID = project.tracks[0].id

    try ClearRangeForRecording(bar..<(bar * 6), on: trackID).apply(to: &project)
    let regions = project.tracks[0].regions
    #expect(regions.map(\.start) == [.zero], "Cut at the edge; what was inside is gone")
    #expect(regions.first?.end == bar)

    try SetReplaceRecording(true).apply(to: &project)
    try SetPunch(CycleRange(isEnabled: true, start: bar, end: bar * 2)).apply(to: &project)
    let saved = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(saved.isReplaceRecording && saved.punch.isEnabled && saved.punch.end == bar * 2)
    #expect(throws: EditError.self) { try SetPunch(CycleRange(start: bar, end: bar)).apply(to: &project) }
  }
}
