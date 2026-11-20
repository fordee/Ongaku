//
//  TimelineEditTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// The section edits between the locators and the arrangement-marker edits move time the
/// same way: regions are cut at the edges, and chords, tempo, meter and key go with the music.
struct TimelineEditTests {
  private let bar = Tick(3840)

  /// A four-bar song: one two-bar region from the start, sections Intro (bar 1), Verse
  /// (bar 2) and Chorus (bars 3–4), chords C, F, G, Am at each bar, and tempos 120, 100 (from
  /// bar 2) and 140 (from bar 3).
  private func song() throws -> Project {
    let region = Region(name: "Keys", start: .zero, length: bar * 2, content: .midi(MIDISequence()))
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [region])])
    project.arrangement = [
      ArrangementSection(name: "Intro", start: .zero, length: bar),
      ArrangementSection(name: "Verse", start: bar, length: bar),
      ArrangementSection(name: "Chorus", start: bar * 2, length: bar * 2),
    ]
    project.chords = ["C", "F", "G", "Am"].enumerated().map { ChordChange(position: bar * Int64($0), chord: Chord(name: $1)!) }
    try project.tempoMap.setTempo(100, at: bar)
    try project.tempoMap.setTempo(140, at: bar * 2)
    return project
  }

  private func section(_ name: String, in project: Project) throws -> ArrangementSection {
    try #require(project.arrangement.first { $0.name == name })
  }

  private func chords(_ project: Project) -> [String] {
    project.chords.map { "\($0.chord.description)@\($0.position.rawValue / bar.rawValue)" }
  }

  private func tempos(_ project: Project) -> [String] {
    project.tempoMap.tempoChanges.map { "\(Int($0.bpm))@\($0.position.rawValue / bar.rawValue)" }
  }

  @Test func deletingAnArrangementSectionCutsRegionsAtItsEdges() throws {
    var project = try song()
    try DeleteArrangementSection(section("Verse", in: project).id).apply(to: &project)
    #expect(project.tracks[0].regions.map(\.length) == [bar], "The part of the region in the Verse goes with it")
    #expect(chords(project) == ["C@0", "G@1", "Am@2"])
    #expect(tempos(project) == ["120@0", "140@1"])
  }

  @Test func cuttingASectionMatchesDeletingTheSameArrangementSection() throws {
    var deleted = try song(), cut = try song()
    try DeleteArrangementSection(section("Verse", in: deleted).id).apply(to: &deleted)
    try CutSection(bar..<(bar * 2)).apply(to: &cut)
    #expect(chords(cut) == chords(deleted) && tempos(cut) == tempos(deleted))
    #expect(cut.tracks[0].regions.map(\.length) == deleted.tracks[0].regions.map(\.length))
  }

  @Test func whatPlaysAfterACutKeepsPlaying() throws {
    var project = try song()
    // Cut from halfway through the Verse: the second half still plays F at 100 BPM.
    try CutSection(bar..<(bar + Tick(1920))).apply(to: &project)
    #expect(chords(project).first { $0.hasPrefix("F") } != nil, "F still plays after the cut")
    #expect(project.tempoMap.tempo(at: bar) == 100)
    #expect(project.tempoMap.tempo(at: bar + Tick(1920)) == 140, "The Chorus tempo moved back with it")
  }

  @Test func duplicatingASectionCopiesItsChordsAndTempo() throws {
    var project = try song()
    try DuplicateArrangementSection(section("Verse", in: project).id).apply(to: &project)
    #expect(chords(project) == ["C@0", "F@1", "F@2", "G@3", "Am@4"])
    #expect(tempos(project) == ["120@0", "100@1", "140@3"], "The copy plays at 100; the Chorus keeps 140")
    #expect(project.tracks[0].regions.map(\.start) == [.zero, bar, bar * 2], "The Verse's part of the region is copied")
  }

  @Test func repeatingASectionMatchesDuplicatingIt() throws {
    var duplicated = try song(), repeated = try song()
    try DuplicateArrangementSection(section("Verse", in: duplicated).id).apply(to: &duplicated)
    try RepeatSection(bar..<(bar * 2)).apply(to: &repeated)
    #expect(chords(repeated) == chords(duplicated) && tempos(repeated) == tempos(duplicated))
  }

  @Test func movingASectionTakesItsChordsTempoAndMeter() throws {
    var project = try song()
    try project.tempoMap.setTimeSignature(TimeSignature(beatsPerBar: 3, beatUnit: 4), atBarIndex: 1)
    try project.tempoMap.setTimeSignature(.fourFour, atBarIndex: 2)
    let threeFour = TimeSignature(beatsPerBar: 3, beatUnit: 4).ticksPerBar
    // Bars: Intro 4/4, Verse 3/4, Chorus 4/4 ×2. Move the Verse to the end.
    var sections = project.arrangement
    sections[1].length = threeFour
    sections[2].start = bar + threeFour
    project.arrangement = sections
    project.chords[2].position = bar + threeFour
    project.chords[3].position = bar * 2 + threeFour
    project.tempoMap.removeTempoChange(at: bar * 2)
    try project.tempoMap.setTempo(140, at: bar + threeFour)

    try MoveArrangementSection(section("Verse", in: project).id, toIndex: 2).apply(to: &project)
    #expect(project.arrangement.map(\.name) == ["Intro", "Chorus", "Verse"])
    let verse = try section("Verse", in: project)
    #expect(verse.start == bar * 3)
    #expect(project.tempoMap.timeSignature(atBarIndex: 3).beatsPerBar == 3, "The Verse is still in 3/4")
    #expect(project.tempoMap.timeSignature(atBarIndex: 1).beatsPerBar == 4)
    #expect(project.tempoMap.tempo(at: verse.start) == 100 && project.tempoMap.tempo(at: bar) == 140)
    #expect(project.chords.last { $0.position <= verse.start }?.chord.description == "F")
  }
}
