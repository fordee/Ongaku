//
//  TrackMoveTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Where a dragged track header lands: anywhere, but stacks stay whole.
struct TrackMoveTests {
  /// Drums, a stack "Keys" holding Piano and Organ, then Bass.
  private func song() -> Project {
    let drums = Track(name: "Drums", kind: .softwareInstrument)
    let stack = Track(name: "Keys", kind: .aux)
    var piano = Track(name: "Piano", kind: .softwareInstrument)
    piano.stackID = stack.id
    var organ = Track(name: "Organ", kind: .softwareInstrument)
    organ.stackID = stack.id
    let bass = Track(name: "Bass", kind: .softwareInstrument)
    var project = Project(tracks: [drums, stack, piano, organ, bass])
    project.tracks[1].isSummingStack = true
    return project
  }

  private func names(after moving: String, before target: String?, in project: Project) throws -> [String]? {
    var project = project
    let id = try #require(project.tracks.first { $0.name == moving }?.id)
    let targetID = target.flatMap { name in project.tracks.first { $0.name == name }?.id }
    guard let destination = project.trackMoveDestination(of: id, before: targetID) else { return nil }
    try MoveTrack(id, to: destination).apply(to: &project)
    return project.tracks.map(\.name)
  }

  @Test func tracksMoveAboveWhereTheyreDropped() throws {
    #expect(try names(after: "Bass", before: "Drums", in: song()) == ["Bass", "Drums", "Keys", "Piano", "Organ"])
    #expect(try names(after: "Drums", before: nil, in: song()) == ["Keys", "Piano", "Organ", "Bass", "Drums"])
    #expect(try names(after: "Drums", before: "Keys", in: song()) == nil, "Dropped where it is, nothing changes")
  }

  @Test func stacksMoveWithTheirSubtracksAndStayWhole() throws {
    #expect(try names(after: "Keys", before: "Drums", in: song()) == ["Keys", "Piano", "Organ", "Drums", "Bass"])
    #expect(try names(after: "Bass", before: "Organ", in: song()) == nil, "Among the subtracks means after them: where Bass is")
    #expect(try names(after: "Drums", before: "Organ", in: song()) == ["Keys", "Piano", "Organ", "Drums", "Bass"],
      "Dropped among the subtracks, it goes after them")
  }

  @Test func subtracksStayInTheirStack() throws {
    #expect(try names(after: "Organ", before: "Piano", in: song()) == ["Drums", "Keys", "Organ", "Piano", "Bass"])
    #expect(try names(after: "Piano", before: "Drums", in: song()) == nil, "Dragged above its stack, it stays its first subtrack")
    #expect(try names(after: "Piano", before: "Bass", in: song()) == ["Drums", "Keys", "Organ", "Piano", "Bass"],
      "Dragged below its stack, it becomes the last subtrack")
  }
}
