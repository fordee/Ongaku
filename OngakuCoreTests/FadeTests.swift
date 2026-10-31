//
//  FadeTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Fades and crossfades on audio regions.
struct FadeTests {
  /// A 10-second file and a 2-second region (four beats at 120 BPM) playing from 1 s into it.
  private func project() -> (Project, Region.ID) {
    let file = AudioFileReference(fileName: "Take.caf", sampleRate: 48_000, channelCount: 2, frameCount: 480_000)
    let region = Region(
      name: "Take", start: .zero, length: .quarterNotes(4), content: .audio(AudioRegionContent(fileID: file.id, fileStartFrame: 48_000)))
    return (Project(tracks: [Track(name: "Audio", kind: .audio, regions: [region])], audioFiles: [file]), region.id)
  }

  private func audio(_ project: Project, _ id: Region.ID) -> AudioRegionContent? {
    if case .audio(let audio) = project.region(withID: id)?.content { audio } else { nil }
  }

  @Test func envelopesRampThroughTheFades() {
    let envelope = AudioEnvelope(gain: 1, offset: 0, regionDuration: 2, fadeIn: 0.5, fadeOut: 1)
    #expect(envelope.level(atSecondsIntoSegment: 0) == 0)
    #expect(envelope.level(atSecondsIntoSegment: 0.25) == 0.5)
    #expect(envelope.level(atSecondsIntoSegment: 0.75) == 1)
    #expect(envelope.level(atSecondsIntoSegment: 1.5) == 0.5)
    #expect(envelope.level(atSecondsIntoSegment: 2) == 0)
    // Starting part-way into the region.
    let later = AudioEnvelope(gain: 0.5, offset: 0.25, regionDuration: 2, fadeIn: 0.5)
    #expect(later.level(atSecondsIntoSegment: 0) == 0.25)
  }

  @Test func fadesStayInsideTheRegion() throws {
    var (project, id) = project()
    try SetRegionParameter(.fadeIn(1.5), for: [id]).apply(to: &project)
    try SetRegionParameter(.fadeOut(5), for: [id]).apply(to: &project)
    #expect(audio(project, id)?.fadeIn == 1.5)
    #expect(audio(project, id)?.fadeOut == 0.5, "The fade out can only reach the fade in")
    try SetRegionParameter(.fadeIn(-1), for: [id]).apply(to: &project)
    #expect(audio(project, id)?.fadeIn == 0)
  }

  @Test func fadesPlay() throws {
    var (project, id) = project()
    try SetRegionParameter(.fadeIn(0.5), for: [id]).apply(to: &project)
    let segment = try #require(PlaybackPlan(project: project, startPosition: .zero).audioSegments(startingIn: 0..<1).first)
    #expect(segment.envelope.fadeIn == 0.5)
  }

  @Test func splittingKeepsEachFadeOnItsEnd() throws {
    var (project, id) = project()
    try SetRegionParameter(.fadeIn(0.5), for: [id]).apply(to: &project)
    try SetRegionParameter(.fadeOut(0.5), for: [id]).apply(to: &project)
    let split = SplitRegion(id, at: .quarterNotes(2))
    try split.apply(to: &project)
    #expect(audio(project, id)?.fadeIn == 0.5)
    #expect(audio(project, id)?.fadeOut == 0)
    #expect(audio(project, split.newRegionID)?.fadeIn == 0)
    #expect(audio(project, split.newRegionID)?.fadeOut == 0.5)
    try GlueRegions([id, split.newRegionID]).apply(to: &project)
    #expect(audio(project, id)?.fadeIn == 0.5)
    #expect(audio(project, id)?.fadeOut == 0.5, "Joining back keeps the outer fades")
  }

  @Test func crossfadesOverlapNeighbours() throws {
    var (project, id) = project()
    let split = SplitRegion(id, at: .quarterNotes(2))
    try split.apply(to: &project)
    try CrossfadeRegions(id, split.newRegionID, duration: 0.2).apply(to: &project)

    let first = try #require(project.region(withID: id))
    let second = try #require(project.region(withID: split.newRegionID))
    // Each extends 0.1 s (192 ticks at 120 BPM) past the old border at beat 2.
    #expect(first.end == .quarterNotes(2) + Tick(192))
    #expect(second.start == .quarterNotes(2) - Tick(192))
    #expect(abs((audio(project, id)?.fadeOut ?? 0) - 0.2) < 0.001)
    #expect(abs((audio(project, split.newRegionID)?.fadeIn ?? 0) - 0.2) < 0.001)
    // The second region still plays the file in the same place: 1 s + 0.9 s at its new start.
    let expectedStart: Int64 = 48_000 + 43_200
    #expect(audio(project, split.newRegionID)?.fileStartFrame == expectedStart)
  }

  @Test func crossfadesNeedAudioPastTheEdges() throws {
    let file = AudioFileReference(fileName: "Take.caf", sampleRate: 48_000, channelCount: 2, frameCount: 96_000)
    let a = Region(name: "A", start: .zero, length: .quarterNotes(4), content: .audio(AudioRegionContent(fileID: file.id)))
    let b = Region(name: "B", start: .quarterNotes(4), length: .quarterNotes(4), content: .audio(AudioRegionContent(fileID: file.id)))
    var project = Project(tracks: [Track(name: "Audio", kind: .audio, regions: [a, b])], audioFiles: [file])
    // A plays the whole file and B starts at the file's start: neither can extend.
    #expect(throws: EditError.self) { try CrossfadeRegions(a.id, b.id, duration: 0.2).apply(to: &project) }
  }

  @Test func fadesAreSaved() throws {
    var (project, id) = project()
    try SetRegionParameter(.fadeOut(0.3), for: [id]).apply(to: &project)
    let reopened = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(audio(reopened, id)?.fadeOut == 0.3)
  }
}
