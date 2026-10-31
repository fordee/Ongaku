//
//  ArrangeToolTests.swift
//  OngakuTests
//

import OngakuCore
@testable import Ongaku
import Testing

/// The tracks area's tools: what a click on a region does with each one.
@MainActor
struct ArrangeToolTests {
  private let window: ProjectWindowModel
  private let trackID: Track.ID
  private let first: Region.ID
  private let second: Region.ID

  init() {
    let a = Region(name: "A", start: .zero, length: .quarterNotes(8), content: .midi(MIDISequence()))
    let b = Region(name: "B", start: .quarterNotes(8), length: .quarterNotes(8), content: .midi(MIDISequence()))
    let track = Track(name: "Keys", kind: .softwareInstrument, regions: [a, b])
    trackID = track.id
    first = a.id
    second = b.id
    window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [track])))
  }

  private var regions: [Region] { window.project.track(withID: trackID)?.regions ?? [] }

  @Test func theToolMenuPicksByKey() {
    window.showToolMenu()
    #expect(window.isShowingToolMenu)
    #expect(window.pickTool(forKey: "i"))
    #expect(window.tool == .scissors)
    #expect(!window.isShowingToolMenu)
    window.showToolMenu()
    #expect(!window.pickTool(forKey: "q"), "Other keys just close the menu")
    #expect(window.tool == .scissors)
    window.showToolMenu()
    #expect(window.pickTool(forKey: "t"), "T T goes back to the Pointer, as in Logic")
    #expect(window.tool == .pointer)
  }

  @Test func thePointerLeavesClicksToSelection() {
    #expect(!window.applyTool(to: first, at: .quarterNotes(2)))
    #expect(regions.count == 2)
  }

  @Test func theEraserDeletes() {
    window.tool = .eraser
    #expect(window.applyTool(to: first, at: .quarterNotes(2)))
    #expect(regions.map(\.id) == [second])
  }

  @Test func theEraserDeletesTheSelectionWhenClickedOnIt() {
    window.tool = .eraser
    window.selectedRegionIDs = [first, second]
    _ = window.applyTool(to: second, at: .quarterNotes(10))
    #expect(regions.isEmpty)
    #expect(window.selectedRegionIDs.isEmpty)
  }

  @Test func theScissorsSplitAtTheSnappedClick() {
    window.tool = .scissors
    // Snapping goes to the nearest bar at this zoom (or a finer division).
    _ = window.applyTool(to: first, at: .quarterNotes(4))
    #expect(regions.count == 3)
    #expect(regions.map(\.start) == [.zero, .quarterNotes(4), .quarterNotes(8)])
  }

  @Test func theGlueJoinsTheSelection() {
    window.tool = .glue
    window.selectedRegionIDs = [first, second]
    _ = window.applyTool(to: first, at: .quarterNotes(2))
    #expect(regions.count == 1)
    #expect(regions.first?.length == .quarterNotes(16))
    #expect(window.selectedRegionIDs == [first])
  }

  @Test func theGlueNeedsASelection() {
    window.tool = .glue
    _ = window.applyTool(to: first, at: .quarterNotes(2))
    #expect(regions.count == 2)
    #expect(window.errorMessage != nil)
  }

  @Test func theMuteToolTogglesMute() {
    window.tool = .mute
    _ = window.applyTool(to: first, at: .zero)
    #expect(regions.first?.isMuted == true)
    _ = window.applyTool(to: first, at: .zero)
    #expect(regions.first?.isMuted == false)
  }

  @Test func joinRegionsWorksFromTheMenu() {
    window.selectedRegionIDs = [first, second]
    window.joinSelectedRegions()
    #expect(regions.count == 1)
  }

  @Test func theFadeToolFadesAudio() throws {
    let file = AudioFileReference(fileName: "Take.caf", sampleRate: 48_000, channelCount: 2, frameCount: 480_000)
    let take = Region(
      name: "Take", start: .zero, length: .quarterNotes(8), content: .audio(AudioRegionContent(fileID: file.id, fileStartFrame: 48_000)))
    let audioTrack = Track(name: "Audio", kind: .audio, regions: [take])
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [audioTrack], audioFiles: [file])))
    let tolerance = Tick(10)

    let fadeIn = try #require(window.fadeTarget(for: take.id, at: .quarterNotes(1), borderTolerance: tolerance))
    #expect(fadeIn == .fadeIn(take.id))
    window.finishFade(fadeIn, from: .quarterNotes(1), to: .quarterNotes(2))
    guard case .audio(let audio) = window.project.region(withID: take.id)?.content else { Issue.record("Not audio"); return }
    #expect(audio.fadeIn == 1, "Two beats at 120 BPM")

    let fadeOut = try #require(window.fadeTarget(for: take.id, at: .quarterNotes(7), borderTolerance: tolerance))
    #expect(fadeOut == .fadeOut(take.id))

    window.split([take.id], at: .quarterNotes(4))
    let right = try #require(window.project.tracks[0].regions.last?.id)
    #expect(window.fadeTarget(for: take.id, at: .quarterNotes(4), borderTolerance: tolerance) == .crossfade(take.id, right))
  }

  @Test func dragsOverAnOverlapCrossfade() throws {
    let file = AudioFileReference(fileName: "Take.caf", sampleRate: 48_000, channelCount: 2, frameCount: 480_000)
    let content = RegionContent.audio(AudioRegionContent(fileID: file.id))
    let a = Region(name: "A", start: .zero, length: .quarterNotes(8), content: content)
    // Overlaps the last two beats of A.
    let b = Region(name: "B", start: .quarterNotes(6), length: .quarterNotes(8), content: content)
    let audioTrack = Track(name: "Audio", kind: .audio, regions: [a, b])
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [audioTrack], audioFiles: [file])))
    let tolerance = Tick(10)

    // Anywhere in the overlap, from either region (B is on top there, so it's the one hit).
    let crossfade = try #require(window.fadeTarget(for: b.id, at: .quarterNotes(7), borderTolerance: tolerance))
    #expect(crossfade == .crossfade(a.id, b.id))
    #expect(window.fadeTarget(for: a.id, at: .quarterNotes(6), borderTolerance: tolerance) == .crossfade(a.id, b.id))
    // Away from it, the usual fades.
    #expect(window.fadeTarget(for: a.id, at: .quarterNotes(5), borderTolerance: tolerance) == .fadeOut(a.id))
    #expect(window.fadeTarget(for: b.id, at: .quarterNotes(12), borderTolerance: tolerance) == .fadeOut(b.id))

    window.finishFade(crossfade, from: .quarterNotes(7), to: .quarterNotes(7) + Tick(200))
    let regions = window.project.tracks[0].regions
    guard case .audio(let first) = regions[0].content, case .audio(let second) = regions[1].content else {
      Issue.record("Not audio")
      return
    }
    #expect(first.fadeOut == 1, "Faded across the two-beat overlap")
    #expect(second.fadeIn == 1)
  }
}
