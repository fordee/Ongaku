//
//  ArrangementTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Markers and the Arrangement track: moving, duplicating and deleting sections takes
/// everything in them along.
struct ArrangementTests {
  private let bar = Tick.quarterNotes(4)

  /// Intro (bars 1–4), Verse (5–8) and Chorus (9–12), with a region, an automation point
  /// and a marker at the start of each.
  private func song() throws -> (Project, intro: ArrangementSection, verse: ArrangementSection, chorus: ArrangementSection) {
    let intro = ArrangementSection(name: "Intro", start: .zero, length: bar * 4)
    let verse = ArrangementSection(name: "Verse", start: bar * 4, length: bar * 4)
    let chorus = ArrangementSection(name: "Chorus", start: bar * 8, length: bar * 4)
    var track = Track(name: "Keys", kind: .softwareInstrument)
    var lane = AutomationLane(parameter: .volume)
    for section in [intro, verse, chorus] {
      track.regions.append(Region(name: section.name, start: section.start, length: bar * 4, content: .midi(MIDISequence())))
      lane.setPoints(lane.points + [AutomationPoint(position: section.start, value: -6)])
    }
    track.automation = [lane]
    var project = Project(tracks: [track])
    for section in [intro, verse, chorus] {
      try AddArrangementSection(section).apply(to: &project)
      try AddMarker(Marker(name: section.name, position: section.start)).apply(to: &project)
    }
    return (project, intro, verse, chorus)
  }

  private func regionNames(_ project: Project) -> [String] {
    project.tracks[0].regions.map(\.name)
  }

  @Test func sectionsCantOverlap() throws {
    var (project, _, _, _) = try song()
    #expect(throws: EditError.self) {
      try AddArrangementSection(ArrangementSection(name: "Bridge", start: bar * 10, length: bar * 4)).apply(to: &project)
    }
  }

  @Test func movingASectionMovesItsContents() throws {
    var (project, _, _, chorus) = try song()
    // Chorus first: Chorus, Intro, Verse.
    try MoveArrangementSection(chorus.id, toIndex: 0).apply(to: &project)
    #expect(project.arrangement.map(\.name) == ["Chorus", "Intro", "Verse"])
    #expect(project.arrangement.map(\.start) == [.zero, bar * 4, bar * 8])
    #expect(regionNames(project) == ["Chorus", "Intro", "Verse"])
    #expect(project.tracks[0].regions.map(\.start) == [.zero, bar * 4, bar * 8])
    #expect(project.markers.map(\.name) == ["Chorus", "Intro", "Verse"])
    #expect(project.tracks[0].automation[0].points.map(\.position) == [.zero, bar * 4, bar * 8])
  }

  @Test func deletingASectionClosesTheGap() throws {
    var (project, _, verse, _) = try song()
    try DeleteArrangementSection(verse.id).apply(to: &project)
    #expect(project.arrangement.map(\.name) == ["Intro", "Chorus"])
    #expect(project.arrangement.last?.start == bar * 4)
    #expect(regionNames(project) == ["Intro", "Chorus"])
    #expect(project.tracks[0].regions.last?.start == bar * 4)
    #expect(project.markers.map(\.name) == ["Intro", "Chorus"])
    #expect(project.tracks[0].automation[0].points.count == 2)
  }

  @Test func duplicatingASectionInsertsACopyAfterIt() throws {
    var (project, _, verse, _) = try song()
    let duplicate = DuplicateArrangementSection(verse.id)
    try duplicate.apply(to: &project)
    #expect(project.arrangement.map(\.name) == ["Intro", "Verse", "Verse", "Chorus"])
    #expect(project.arrangement.first { $0.id == duplicate.copyID }?.start == bar * 8)
    #expect(regionNames(project) == ["Intro", "Verse", "Verse", "Chorus"])
    #expect(project.tracks[0].regions.map(\.start) == [.zero, bar * 4, bar * 8, bar * 12])
    #expect(Set(project.tracks[0].regions.map(\.id)).count == 4, "The copies are new regions")
    #expect(project.markers.map(\.position) == [.zero, bar * 4, bar * 8, bar * 12])
    #expect(project.tracks[0].automation[0].points.count == 4)
  }

  @Test func markersCanBeMovedRenamedAndDeleted() throws {
    var (project, _, _, _) = try song()
    var marker = project.markers[0]
    marker.name = "  Start  "
    marker.position = bar * 20
    try UpdateMarker(marker).apply(to: &project)
    #expect(project.markers.last?.name == "Start", "Sorted by position, name trimmed")
    marker.name = ""
    #expect(throws: EditError.self) { try UpdateMarker(marker).apply(to: &project) }
    try DeleteMarkers([marker.id]).apply(to: &project)
    #expect(project.markers.count == 2)
  }

  @Test func markersAndSectionsAreSaved() throws {
    let (project, _, _, _) = try song()
    let reopened = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(reopened.markers == project.markers)
    #expect(reopened.arrangement == project.arrangement)
  }

  @Test func sectionsAreColouredByName() {
    #expect(ArrangementSection(name: "Chorus", start: .zero, length: bar).color == .orange)
    #expect(ArrangementSection(name: "Something", start: .zero, length: bar).color == .gray)
  }
}
