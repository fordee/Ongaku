//
//  AutomationTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

struct AutomationTests {
  private let beat = Tick.quarterNotes(1)

  private func point(_ beats: Double, _ value: Double) -> AutomationPoint {
    AutomationPoint(position: .quarterNotes(beats), value: value)
  }

  // MARK: - Lanes

  @Test func valuesAreInterpolatedBetweenPoints() {
    let lane = AutomationLane(parameter: .volume, points: [point(4, -20), point(0, 0)])
    #expect(lane.points.map(\.value) == [0, -20], "Points are sorted")
    #expect(lane.value(at: .zero) == 0)
    #expect(lane.value(at: .quarterNotes(2)) == -10)
    #expect(lane.value(at: .quarterNotes(1)) == -5)
    #expect(lane.value(at: .quarterNotes(10)) == -20, "After the last point the value holds")
    #expect(AutomationLane(parameter: .pan).value(at: .zero) == nil)
  }

  @Test func valuesAreClampedToTheParameterRange() {
    let lane = AutomationLane(parameter: .pan, points: [point(0, 3), point(1, -7)])
    #expect(lane.points.map(\.value) == [1, -1])
  }

  @Test func twoPointsAtOnePositionMakeAStep() {
    let lane = AutomationLane(parameter: .volume, points: [point(0, 0), point(2, 0), point(2, -30), point(4, -30)])
    #expect(lane.value(at: .quarterNotes(1.99)) == 0)
    #expect(lane.value(at: .quarterNotes(2.01)) == -30)
  }

  @Test func trackValuesFollowTheMode() {
    var track = Track(name: "Keys", kind: .softwareInstrument)
    track.channel.volume = -6
    track.automation = [AutomationLane(parameter: .volume, points: [point(0, -12)])]
    #expect(track.automatedValue(of: .volume, at: .zero) == -12)
    #expect(track.isAutomated(.volume))
    #expect(!track.isAutomated(.pan))
    #expect(track.automatedValue(of: .pan, at: .zero) == 0, "No pan automation: the strip's pan")
    track.automationMode = .off
    #expect(track.automatedValue(of: .volume, at: .zero) == -6)
    #expect(!track.isAutomated(.volume))
  }

  // MARK: - Writing

  @Test func writingReplacesTheRangeAndKeepsTheCurveOutsideIt() {
    var lane = AutomationLane(parameter: .volume, points: [point(0, 0), point(8, -16)])
    // Before writing, beat 2 is at -4 and beat 6 at -12.
    lane.write([point(3, -40), point(5, -40)], over: Tick.quarterNotes(2)...Tick.quarterNotes(6))
    #expect(lane.value(at: .quarterNotes(1)) == -2, "Untouched before the range")
    #expect(lane.value(at: .quarterNotes(2)) == -4, "Pinned at the range start")
    #expect(lane.value(at: .quarterNotes(4)) == -40, "The written values")
    #expect(abs((lane.value(at: .quarterNotes(7)) ?? 0) - -14) < 0.01, "Back on the old curve after the range")
  }

  @Test func writingAnEmptyLaneJustAddsThePoints() {
    var lane = AutomationLane(parameter: .pan)
    lane.write([point(1, 0.5), point(2, -0.5)], over: Tick.quarterNotes(1)...Tick.quarterNotes(2))
    #expect(lane.points.map(\.value) == [0.5, -0.5])
  }

  @Test func thinningKeepsTheShape() {
    // A straight ramp sampled every 1/16 note with a corner in the middle.
    var samples: [AutomationPoint] = []
    for step in 0...32 {
      let beats = Double(step) / 4
      let value = step <= 16 ? -Double(step) : -16 + Double(step - 16)
      samples.append(point(beats, value))
    }
    let thinned = AutomationLane.thinned(samples, tolerance: 0.1)
    #expect(thinned.map(\.value) == [0, -16, 0], "Two straight lines need only their ends and the corner")
    #expect(AutomationLane.thinned(Array(samples.prefix(2)), tolerance: 1).count == 2)
  }

  // MARK: - Commands

  private func makeProject() -> (Project, Track.ID) {
    let track = Track(name: "Audio 1", kind: .audio)
    return (Project(tracks: [track]), track.id)
  }

  @Test func pointsCanBeAddedMovedAndDeleted() throws {
    var (project, trackID) = makeProject()
    let first = point(0, 0)
    var second = point(4, -10)
    try AddAutomationPoints([first, second], to: .volume, on: trackID).apply(to: &project)
    #expect(project.tracks[0].automationLane(for: .volume)?.points.count == 2)
    #expect(throws: EditError.duplicateID(first.id)) {
      try AddAutomationPoints([first], to: .volume, on: trackID).apply(to: &project)
    }

    second.position = .quarterNotes(2)
    second.value = -20
    try UpdateAutomationPoints([second], in: .volume, on: trackID).apply(to: &project)
    #expect(project.tracks[0].automationLane(for: .volume)?.value(at: .quarterNotes(2)) == -20)

    try DeleteAutomationPoints([first.id, second.id], from: .volume, on: trackID).apply(to: &project)
    #expect(project.tracks[0].automation.isEmpty, "An emptied lane is removed")
  }

  @Test func automationCanBeClearedAndTheModeSet() throws {
    var (project, trackID) = makeProject()
    try AddAutomationPoints([point(0, 0.5)], to: .pan, on: trackID).apply(to: &project)
    try SetAutomationMode(.latch, for: trackID).apply(to: &project)
    #expect(project.tracks[0].automationMode == .latch)
    try ClearAutomation(.pan, on: trackID).apply(to: &project)
    #expect(project.tracks[0].automation.isEmpty)
  }

  @Test func automationRoundTripsThroughTheProjectFile() throws {
    var (project, trackID) = makeProject()
    try AddAutomationPoints([point(0, -3), point(8, 2)], to: .volume, on: trackID).apply(to: &project)
    try SetAutomationMode(.touch, for: trackID).apply(to: &project)
    #expect(try ProjectArchive.decode(ProjectArchive.encode(project)) == project)
  }

  // MARK: - Playback plan

  /// 120 BPM, so a beat is half a second.
  private func planProject(cycle: CycleRange? = nil) throws -> (Project, Track.ID) {
    var (project, trackID) = makeProject()
    try AddAutomationPoints([point(0, 0), point(4, -20), point(8, -20)], to: .volume, on: trackID).apply(to: &project)
    if let cycle { project.cycle = cycle }
    project.endPosition = .quarterNotes(16)
    return (project, trackID)
  }

  @Test func rampsRunFromPointToPoint() throws {
    let (project, _) = try planProject()
    let ramps = PlaybackPlan(project: project, startPosition: .zero).automationRamps(in: 0..<5)
    #expect(ramps.map(\.startTime) == [0, 2, 4])
    #expect(ramps.map(\.endTime) == [2, 4, 5])
    #expect(ramps.map(\.startValue) == [0, -20, -20])
    #expect(ramps.map(\.endValue) == [-20, -20, -20])
    #expect(ramps[0].value(at: 1) == -10)
  }

  @Test func rampsStartMidWayWhenPlaybackDoes() throws {
    let (project, _) = try planProject()
    let ramps = PlaybackPlan(project: project, startPosition: .quarterNotes(2)).automationRamps(in: 0..<1)
    #expect(ramps.count == 1)
    #expect(ramps[0].startValue == -10, "Two beats in, halfway down the first ramp")
    #expect(ramps[0].endValue == -20)
  }

  @Test func consecutiveWindowsJoinUp() throws {
    let (project, _) = try planProject()
    let plan = PlaybackPlan(project: project, startPosition: .zero)
    let first = plan.automationRamps(in: 0..<1)
    let second = plan.automationRamps(in: 1..<2)
    #expect(first.last?.endTime == 1)
    #expect(second.first?.startTime == 1)
    #expect(first.last?.endValue == second.first?.startValue)
  }

  @Test func cyclesJumpBackToTheCycleStartValue() throws {
    let (project, _) = try planProject(cycle: CycleRange(isEnabled: true, start: .zero, end: .quarterNotes(4)))
    // The cycle lasts 2 s: the ramp from 0 to -20 dB plays, then starts again.
    let ramps = PlaybackPlan(project: project, startPosition: .zero).automationRamps(in: 0..<4)
    #expect(ramps.map(\.startTime) == [0, 2])
    #expect(ramps.map(\.startValue) == [0, 0])
    #expect(ramps.map(\.endValue) == [-20, -20])
  }

  @Test func tracksInOffModeAreLeftOut() throws {
    var (project, trackID) = try planProject()
    try SetAutomationMode(.off, for: trackID).apply(to: &project)
    #expect(PlaybackPlan(project: project, startPosition: .zero).automationRamps(in: 0..<5).isEmpty)
  }
}
