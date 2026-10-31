//
//  RegionLoopTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Loops that end where they're dragged to (Logic's loop handle), and turning them into
/// regions of their own.
struct RegionLoopTests {
  private let bar = Tick.quarterNotes(4)

  /// A one-bar riff at bar 1 with a note on beat 1, and a fill at bar 9.
  private func project() -> Project {
    let note = MIDINote(pitch: 60, start: .zero, length: .quarterNotes(1))
    let riff = Region(name: "Riff", start: .zero, length: bar, content: .midi(MIDISequence(notes: [note])))
    let fill = Region(name: "Fill", start: bar * 8, length: bar, content: .midi(MIDISequence()))
    return Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [riff, fill])])
  }

  private func played(_ project: Project) -> [(start: Tick, length: Tick)] {
    project.tracks[0].playedRegions(until: project.endPosition).filter { $0.name == "Riff" }.map { ($0.start, $0.length) }
  }

  @Test func loopsStopWhereTheyreDraggedTo() throws {
    var project = project()
    let riff = project.tracks[0].regions[0].id
    // Dragged out to half way through bar 4: three and a half bars of riff.
    try SetRegionLoop(riff, to: bar * 3 + .quarterNotes(2)).apply(to: &project)
    let pieces = played(project)
    #expect(pieces.map(\.start) == [.zero, bar, bar * 2, bar * 3])
    #expect(pieces.last?.length == .quarterNotes(2), "The last repeat stops part way")
    #expect(project.tracks[0].regions[0].loopEnd == bar * 3 + .quarterNotes(2))

    // Dragged back inside the region: no loops.
    try SetRegionLoop(riff, to: bar).apply(to: &project)
    #expect(played(project).count == 1)
    #expect(!project.tracks[0].regions[0].isLooped)
  }

  @Test func theNextRegionStillStopsTheLoops() throws {
    var project = project()
    try SetRegionLoop(project.tracks[0].regions[0].id, to: bar * 12).apply(to: &project)
    #expect(played(project).count == 8, "Repeats stop at the fill in bar 9")
  }

  @Test func theLoopSwitchLoopsToTheNextRegion() throws {
    var project = project()
    let riff = project.tracks[0].regions[0].id
    try SetRegionLoop(riff, to: bar * 2).apply(to: &project)
    try SetRegionParameter(.looped(true), for: [riff]).apply(to: &project)
    #expect(project.tracks[0].regions[0].loopedLength == nil)
    #expect(played(project).count == 8)
  }

  @Test func movingAndResizingKeepTheLoopsInPlace() throws {
    var project = project()
    let riff = project.tracks[0].regions[0].id
    try SetRegionLoop(riff, to: bar * 4).apply(to: &project)
    // Moving takes the loops along: they still reach four bars on.
    try MoveRegion(riff, to: bar).apply(to: &project)
    #expect(project.tracks[0].regions[0].loopEnd == bar * 5)
    // Shortening from the start keeps the loop end where it was.
    try TrimRegion(riff, start: bar + .quarterNotes(2), length: .quarterNotes(2)).apply(to: &project)
    #expect(project.tracks[0].regions.first { $0.id == riff }?.loopEnd == bar * 5)
  }

  @Test func splittingKeepsTheLoopsOnTheRightHalf() throws {
    var project = project()
    let riff = project.tracks[0].regions[0].id
    try SetRegionLoop(riff, to: bar * 3).apply(to: &project)
    let split = SplitRegion(riff, at: .quarterNotes(2))
    try split.apply(to: &project)
    #expect(project.region(withID: riff)?.isLooped == false)
    #expect(project.region(withID: split.newRegionID)?.loopEnd == bar * 3)
  }

  @Test func convertingLoopsMakesRealRegions() throws {
    var project = project()
    let riff = project.tracks[0].regions[0].id
    try SetRegionLoop(riff, to: bar * 2 + .quarterNotes(2)).apply(to: &project)
    try ConvertLoopsToRegions([riff]).apply(to: &project)
    let riffs = project.tracks[0].regions.filter { $0.name == "Riff" }
    #expect(riffs.map(\.start) == [.zero, bar, bar * 2])
    #expect(riffs.map(\.length) == [bar, bar, .quarterNotes(2)])
    #expect(riffs.allSatisfy { !$0.isLooped })
    #expect(Set(riffs.map(\.id)).count == 3, "Each is a region of its own")
    guard case .midi(let sequence) = riffs[1].content else { Issue.record("Not MIDI"); return }
    #expect(sequence.notes.count == 1, "With the notes copied")
    #expect(played(project).count == 3, "It plays just the same")
  }

  @Test func loopEndsAreSaved() throws {
    var project = project()
    try SetRegionLoop(project.tracks[0].regions[0].id, to: bar * 3).apply(to: &project)
    let reopened = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(reopened.tracks[0].regions[0].loopEnd == bar * 3)
  }
}
