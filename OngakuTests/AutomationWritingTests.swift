//
//  AutomationWritingTests.swift
//  OngakuTests
//

import AppKit
import AudioToolbox
import Foundation
import OngakuCore
import OngakuEngine
@testable import Ongaku
import Testing

/// Recording automation by moving controls during playback, driven the way the mixer's
/// fader and pan controls drive it.
@MainActor
@Suite(.serialized)
struct AutomationWritingTests {
  private func makeWindow(mode: AutomationMode, volume: Double = 0) -> (ProjectWindowModel, Track.ID) {
    var track = Track(name: "Audio 1", kind: .audio, automationMode: mode)
    track.channel.volume = volume
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [track])))
    return (window, track.id)
  }

  private func lane(_ window: ProjectWindowModel, _ trackID: Track.ID) -> AutomationLane? {
    window.project.track(withID: trackID)?.automationLane(for: .volume)
  }

  @Test func touchWritesWhileHeldAndStopsWhenLetGo() async throws {
    let (window, trackID) = makeWindow(mode: .touch, volume: -3)
    defer { window.engine.shutDown() }
    try await Task.sleep(for: .milliseconds(200))
    window.engine.play()
    try await Task.sleep(for: .milliseconds(150))

    window.controlChanged(.volume, to: -10, on: trackID)
    try await Task.sleep(for: .milliseconds(150))
    window.controlChanged(.volume, to: -20, on: trackID)
    #expect(window.displayedValue(of: .volume, on: window.project.tracks[0]) == -20, "The fader shows what's being written")
    try await Task.sleep(for: .milliseconds(150))
    #expect(window.controlReleased(.volume, on: trackID), "The move became automation")
    window.engine.stop()

    let points = try #require(lane(window, trackID)?.points)
    #expect(points.first?.value == -10)
    #expect(points.last?.value == -20)
    #expect(points.first!.position > .zero, "Written where the playhead was")
    #expect(window.project.tracks[0].channel.volume == -3, "The strip's own setting is untouched")
    #expect(window.automationWrite == nil)
  }

  @Test func latchKeepsTheLastValueUntilPlaybackStops() async throws {
    let (window, trackID) = makeWindow(mode: .latch)
    defer { window.engine.shutDown() }
    try await Task.sleep(for: .milliseconds(200))
    window.engine.play()
    try await Task.sleep(for: .milliseconds(100))

    window.controlChanged(.volume, to: -12, on: trackID)
    try await Task.sleep(for: .milliseconds(100))
    window.controlReleased(.volume, on: trackID)
    let releasedAt = window.engine.playheadPosition
    #expect(window.automationWrite?.isReleased == true, "Still writing after letting go")
    try await Task.sleep(for: .milliseconds(300))
    window.engine.stop()
    window.transportDidStop(at: window.engine.playheadPosition)

    let points = try #require(lane(window, trackID)?.points)
    #expect(points.last?.value == -12)
    #expect(points.last!.position > releasedAt, "The value was held until the stop")
    #expect(window.automationWrite == nil)
  }

  @Test func readModeDoesNotWrite() async throws {
    let (window, trackID) = makeWindow(mode: .read)
    defer { window.engine.shutDown() }
    try await Task.sleep(for: .milliseconds(200))
    window.engine.play()
    window.controlChanged(.volume, to: -12, on: trackID)
    #expect(!window.controlReleased(.volume, on: trackID))
    window.engine.stop()
    #expect(lane(window, trackID) == nil)
  }

  @Test func nothingIsWrittenWhileStopped() {
    let (window, trackID) = makeWindow(mode: .touch)
    defer { window.engine.shutDown() }
    window.controlChanged(.volume, to: -12, on: trackID)
    #expect(!window.controlReleased(.volume, on: trackID), "A move while stopped changes the strip as usual")
  }

  @Test func showingAutomationGivesEachTrackAStripBelowItsLane() {
    let (window, _) = makeWindow(mode: .read)
    defer { window.engine.shutDown() }
    typealias Layout = ProjectWindowModel.Layout
    #expect(window.rowHeight == Layout.trackHeight)
    let viewport = CGSize(width: 1_000, height: 600)
    // Scrolled down by 40 rows of regions.
    let offset = CGPoint(x: 0, y: Layout.rulerHeight + 40 * Layout.trackHeight)
    window.scroll.update(offset: offset, viewportSize: viewport)
    let rowsWithoutAutomation = window.scroll.visibleRows

    window.isAutomationVisible = true
    #expect(window.rowHeight == Layout.trackHeight + Layout.automationHeight)
    #expect(window.contentWidth > 0)
    // The same scroll offset is fewer rows down once each row holds a strip too.
    #expect(window.scroll.visibleRows.lowerBound < rowsWithoutAutomation.lowerBound)
  }

  @Test func controlsShowTheAutomationAtThePlayhead() throws {
    let (window, trackID) = makeWindow(mode: .read)
    defer { window.engine.shutDown() }
    window.addAutomationPoint(at: .zero, value: 0, to: .volume, on: trackID)
    window.addAutomationPoint(at: .quarterNotes(4), value: -20, to: .volume, on: trackID)
    window.engine.locate(to: .quarterNotes(2))
    #expect(window.displayedValue(of: .volume, on: window.project.tracks[0]) == -10)
    #expect(window.displayedValue(of: .pan, on: window.project.tracks[0]) == 0, "Pan isn't automated")

    window.setAutomationMode(.off, for: trackID)
    #expect(window.displayedValue(of: .volume, on: window.project.tracks[0]) == 0, "Off: the strip's setting")
  }

  @Test func sendKnobsWriteTouchAutomation() async throws {
    let aux = Track(name: "Reverb", kind: .aux)
    var track = Track(name: "Audio 1", kind: .audio, automationMode: .touch)
    let send = Send(destinationTrackID: aux.id)
    track.channel.sends = [send]
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [track, aux])))
    defer { window.engine.shutDown() }
    #expect(send.level == Send.defaultLevel, "New sends start where resetting puts them")
    try await Task.sleep(for: .milliseconds(200))
    window.engine.play()
    try await Task.sleep(for: .milliseconds(100))

    window.controlChanged(.sendLevel(send.id), to: -12, on: track.id)
    try await Task.sleep(for: .milliseconds(100))
    window.controlChanged(.sendLevel(send.id), to: Send.levelRange.lowerBound, on: track.id)
    #expect(window.displayedValue(of: .sendLevel(send.id), on: window.project.tracks[0]) == Send.levelRange.lowerBound,
      "The knob shows what's being written, down to off")
    #expect(window.controlReleased(.sendLevel(send.id), on: track.id))
    window.engine.stop()

    let points = try #require(window.project.tracks[0].automationLane(for: .sendLevel(send.id))?.points)
    #expect(points.first?.value == -12)
    #expect(points.last?.value == Send.levelRange.lowerBound)
    #expect(window.project.tracks[0].channel.sends[0].level == Send.defaultLevel, "The send's own level is untouched")
  }

  @Test func groupedTracksInTouchWriteAlongWithTheFader() async throws {
    let drums = Track(name: "Drums", kind: .audio, automationMode: .touch)
    let bass = Track(name: "Bass", kind: .audio, channel: ChannelStrip(volume: -4), automationMode: .touch)
    let keys = Track(name: "Keys", kind: .audio, automationMode: .read)
    var project = Project(tracks: [drums, bass, keys])
    try CreateMixerGroup(MixerGroup(id: 1), with: [drums.id, bass.id, keys.id]).apply(to: &project)
    let window = ProjectWindowModel(document: OngakuDocument(project: project))
    defer { window.engine.shutDown() }
    try await Task.sleep(for: .milliseconds(200))
    window.engine.play()
    try await Task.sleep(for: .milliseconds(100))

    window.controlChanged(.volume, to: -6, on: drums.id)
    try await Task.sleep(for: .milliseconds(100))
    window.controlChanged(.volume, to: -10, on: drums.id)
    #expect(window.displayedValue(of: .volume, on: window.project.tracks[1]) == -14, "Bass follows, 4 dB below")
    window.controlReleased(.volume, on: drums.id)
    window.engine.stop()

    let bassPoints = try #require(window.project.tracks[1].automationLane(for: .volume)?.points)
    #expect(bassPoints.first?.value == -10)
    #expect(bassPoints.last?.value == -14)
    #expect(window.project.tracks[0].automationLane(for: .volume)?.points.last?.value == -10)
    #expect(window.project.tracks[2].automationLane(for: .volume) == nil, "Keys is in Read, so it doesn't write")
    #expect(window.project.tracks[1].channel.volume == -4, "Bass's own setting is untouched")
  }

  @Test func groupsCanBeRenamedAndUndone() throws {
    let drums = Track(name: "Drums", kind: .audio)
    var project = Project(tracks: [drums])
    try CreateMixerGroup(MixerGroup(id: 1), with: [drums.id]).apply(to: &project)
    let window = ProjectWindowModel(document: OngakuDocument(project: project))
    defer { window.engine.shutDown() }
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    window.undoManager = undoManager
    undoManager.beginUndoGrouping()
    window.renameGroup(1, to: "  Drums  ")
    undoManager.endUndoGrouping()
    #expect(window.project.mixerGroup(withID: 1)?.name == "Drums")
    #expect(undoManager.undoActionName == "Rename Group")
    window.renameGroup(1, to: " ")
    #expect(window.project.mixerGroup(withID: 1)?.name == "Drums", "An empty name keeps the old one")
    undoManager.undo()
    #expect(window.project.mixerGroup(withID: 1)?.name == "Group 1")
  }

  @Test func shiftAndCommandClickingStripsSelectSeveralTracks() {
    let tracks = (1...3).map { Track(name: "Audio \($0)", kind: .audio) }
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: tracks)))
    defer { window.engine.shutDown() }
    window.selectTrack(tracks[0].id)
    window.selectTrack(tracks[2].id, modifiers: .shift)
    #expect(window.selectedTrackIDs == Set(tracks.map(\.id)))
    window.selectTrack(tracks[1].id, modifiers: .command)
    #expect(window.selectedTrackIDs == [tracks[0].id, tracks[2].id])
    window.createGroup(with: tracks[2].id)
    #expect(window.project.tracks.map(\.groupID) == [1, nil, 1], "New Group with Selected Tracks groups the selection")
  }

  @Test func pluginAutomationShowsTheParametersOwnUnit() {
    let decibels = PluginValueFormat(minimum: -24, maximum: 24, unit: .decibels)
    #expect(AutomationScale.label(0.75, for: .plugin(PluginParameter(pluginID: UUID(), address: 0, name: "Gain")), format: decibels)
      == "+12.0 dB")
    #expect(AutomationScale.label(0.75, for: .plugin(PluginParameter(pluginID: UUID(), address: 0, name: "Gain"))) == "75%",
      "Percent when the plug-in isn't loaded")
    #expect(PluginValueFormat(minimum: 20, maximum: 20_000, unit: .hertz).label(forFraction: 0.5) == "10.01 kHz")
    #expect(PluginValueFormat(minimum: 0, maximum: 3, unit: .indexed, valueStrings: ["Saw", "Pulse", "Triangle", "Sine"])
      .label(forFraction: 1 / 3) == "Pulse")
    #expect(PluginValueFormat(minimum: 0, maximum: 127, unit: .midiNoteNumber).label(forFraction: 60.0 / 127) == "C3",
      "Middle C is C3, as in the Piano Roll")
  }

  @Test func pointsCanBeEditedAndUndone() throws {
    let (window, trackID) = makeWindow(mode: .read)
    defer { window.engine.shutDown() }
    // Tests have no run loop to close undo groups, so each edit gets its own.
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    window.undoManager = undoManager
    func step(_ edit: () -> Void) {
      undoManager.beginUndoGrouping()
      edit()
      undoManager.endUndoGrouping()
    }
    step { window.addAutomationPoint(at: .quarterNotes(1), value: -6, to: .pan, on: trackID) }
    var point = try #require(window.project.tracks[0].automationLane(for: .pan)?.points.first)
    #expect(point.value == -1, "Pan is clamped to its range")

    point.value = 0.5
    step { window.moveAutomationPoint(point, in: .pan, on: trackID) }
    #expect(window.project.tracks[0].automationLane(for: .pan)?.points.first?.value == 0.5)
    step { window.deleteAutomationPoint(point.id, from: .pan, on: trackID) }
    #expect(window.project.tracks[0].automation.isEmpty)

    undoManager.undo()
    #expect(window.project.tracks[0].automationLane(for: .pan)?.points.first?.value == 0.5)
  }
}
