//
//  TakeFolderTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Take folders: several takes, and a comp choosing which plays where.
struct TakeFolderTests {
  private let bar = Tick.quarterNotes(4)
  /// A 10 s recording at 48 kHz: three two-bar passes of a cycle, one after another.
  private let file = AudioFileReference(fileName: "Takes.caf", sampleRate: 48_000, channelCount: 2, frameCount: 480_000)

  /// An audio take folder over bars 1–2 with three takes, each a pass of the same file
  /// (two bars at 120 BPM is 4 s, 192 000 frames).
  private func audioFolder() -> (Project, Region, [Take]) {
    let takes = (0..<3).map { index in
      Take(name: "Take \(index + 1)", content: .audio(AudioRegionContent(fileID: file.id, fileStartFrame: Int64(index) * 192_000)))
    }
    let folder = TakeFolder(takes: takes, playing: takes[2].id, length: bar * 2)
    let region = Region(name: "Vocal", start: .zero, length: bar * 2, content: takes[2].content, takeFolder: folder)
    let project = Project(tracks: [Track(name: "Vocal", kind: .audio, regions: [region])], audioFiles: [file])
    return (project, region, takes)
  }

  @Test func swipingReplacesPartOfTheComp() {
    let a = UUID(), b = UUID()
    var folder = TakeFolder(takes: [], comp: [CompSection(start: .zero, end: bar * 4, takeID: a)])
    folder.use(b, over: bar..<(bar * 2))
    #expect(folder.comp.map(\.takeID) == [a, b, a])
    #expect(folder.comp.map(\.start) == [.zero, bar, bar * 2])
    // Swiping the rest with take B joins it up.
    folder.use(b, over: (bar * 2)..<(bar * 4))
    #expect(folder.comp.map(\.takeID) == [a, b])
    #expect(folder.comp.last?.range == bar..<(bar * 4))
    #expect(folder.takeID(at: bar * 3) == b)
  }

  @Test func theCompPlaysEachSectionsTake() throws {
    var (project, region, takes) = audioFolder()
    try CompTake(takes[0].id, over: bar..<(bar * 2), in: region.id).apply(to: &project)
    let plan = PlaybackPlan(project: project, startPosition: .zero)
    let segments = plan.audioSegments(startingIn: 0..<10)
    #expect(segments.count == 2)
    // Bar 1 from take 3 (its pass starts at frame 384 000); bar 2 from take 1, two seconds in.
    #expect(segments.map(\.fileStartFrame) == [384_000, 96_000])
    #expect(segments.map(\.playbackTime) == [0, 2])
    #expect(segments[0].envelope.fadeOut == Project.compCrossfade, "A short fade where the takes meet")
    #expect(segments[1].envelope.fadeIn == Project.compCrossfade)
  }

  @Test func selectingATakePlaysItThroughout() throws {
    var (project, region, takes) = audioFolder()
    try SelectTake(takes[1].id, in: region.id).apply(to: &project)
    let folder = try #require(project.region(withID: region.id))
    #expect(folder.leadTakeID == takes[1].id)
    #expect(folder.content == takes[1].content, "The region shows the take that plays")
  }

  @Test func editsToTheLeadTakeAreKept() throws {
    // A MIDI folder: editing the region's notes edits the take that plays.
    let first = Take(name: "Take 1", content: .midi(MIDISequence(notes: [MIDINote(pitch: 60, start: .zero, length: bar)])))
    let second = Take(name: "Take 2", content: .midi(MIDISequence(notes: [MIDINote(pitch: 64, start: .zero, length: bar)])))
    let region = Region(
      name: "Keys", start: .zero, length: bar, content: first.content,
      takeFolder: TakeFolder(takes: [first, second], playing: first.id, length: bar))
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [region])])
    try AddNotes([MIDINote(pitch: 67, start: .quarterNotes(2), length: .quarterNotes(1))], to: region.id).apply(to: &project)
    try SelectTake(second.id, in: region.id).apply(to: &project)
    try SelectTake(first.id, in: region.id).apply(to: &project)
    guard case .midi(let sequence) = project.region(withID: region.id)?.content else { Issue.record("Not MIDI"); return }
    #expect(sequence.notes.map(\.pitch) == [60, 67])
  }

  @Test func deletingTakesLeavesAPlainRegionAtTheEnd() throws {
    var (project, region, takes) = audioFolder()
    try DeleteTake(takes[2].id, from: region.id).apply(to: &project)
    #expect(project.region(withID: region.id)?.takeFolder?.takes.count == 2)
    #expect(project.region(withID: region.id)?.leadTakeID == takes[0].id, "The comp falls back to the first take")
    try DeleteTake(takes[0].id, from: region.id).apply(to: &project)
    let plain = try #require(project.region(withID: region.id))
    #expect(plain.takeFolder == nil)
    #expect(plain.content == takes[1].content)
  }

  @Test func aFoldersOnlyTakeIsNeverDeleted() throws {
    let take = Take(name: "Take 1", content: .midi(MIDISequence()))
    let region = Region(
      name: "Keys", start: .zero, length: bar, content: take.content,
      takeFolder: TakeFolder(takes: [take], playing: take.id, length: bar))
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [region])])
    #expect(throws: EditError.self) { try DeleteTake(take.id, from: region.id).apply(to: &project) }
    #expect(throws: EditError.self) { try DeleteTake(UUID(), from: region.id).apply(to: &project) }
  }

  @Test func renamingATakeKeepsItsEdits() throws {
    // Renaming the lead take of a MIDI folder keeps the notes edited in the region.
    let first = Take(name: "Take 1", content: .midi(MIDISequence()))
    let second = Take(name: "Take 2", content: .midi(MIDISequence()))
    let region = Region(
      name: "Keys", start: .zero, length: bar, content: first.content,
      takeFolder: TakeFolder(takes: [first, second], playing: first.id, length: bar))
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [region])])
    try AddNotes([MIDINote(pitch: 67, start: .zero, length: .quarterNotes(1))], to: region.id).apply(to: &project)
    try RenameTake(first.id, in: region.id, to: "Keeper").apply(to: &project)
    let folder = try #require(project.region(withID: region.id))
    #expect(folder.takeFolder?.takes.map(\.name) == ["Keeper", "Take 2"])
    guard case .midi(let sequence) = folder.content else { Issue.record("Not MIDI"); return }
    #expect(sequence.notes.map(\.pitch) == [67])
    #expect(throws: EditError.self) { try RenameTake(first.id, in: region.id, to: "  ").apply(to: &project) }
  }

  @Test func flatteningAudioMakesARegionPerSection() throws {
    var (project, region, takes) = audioFolder()
    try CompTake(takes[0].id, over: bar..<(bar * 2), in: region.id).apply(to: &project)
    try FlattenTakeFolder(region.id).apply(to: &project)
    let regions = project.tracks[0].regions
    #expect(regions.count == 2)
    #expect(regions.allSatisfy { $0.takeFolder == nil })
    #expect(regions.first?.id == region.id)
    #expect(regions.map(\.start) == [.zero, bar])
  }

  @Test func flatteningMIDIMakesOneRegion() throws {
    let first = Take(name: "Take 1", content: .midi(MIDISequence(notes: [MIDINote(pitch: 60, start: .zero, length: .quarterNotes(1))])))
    let second = Take(name: "Take 2", content: .midi(MIDISequence(notes: [
      MIDINote(pitch: 64, start: .quarterNotes(2), length: .quarterNotes(1))
    ])))
    let region = Region(
      name: "Keys", start: .zero, length: bar, content: first.content,
      takeFolder: TakeFolder(takes: [first, second], playing: first.id, length: bar))
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [region])])
    try CompTake(second.id, over: .quarterNotes(2)..<bar, in: region.id).apply(to: &project)
    try FlattenTakeFolder(region.id).apply(to: &project)
    let flat = try #require(project.tracks[0].regions.first)
    guard case .midi(let sequence) = flat.content else { Issue.record("Not MIDI"); return }
    #expect(project.tracks[0].regions.count == 1)
    #expect(sequence.notes.map(\.pitch) == [60, 64])
    #expect(sequence.notes.map(\.start) == [.zero, .quarterNotes(2)])
  }

  @Test func takeFoldersAreFlattenedBeforeResizing() {
    var (project, region, _) = audioFolder()
    #expect(throws: EditError.self) { try TrimRegion(region.id, start: .zero, length: bar).apply(to: &project) }
    #expect(throws: EditError.self) { try SplitRegion(region.id, at: bar).apply(to: &project) }
    // Moving is fine.
    #expect(throws: Never.self) { try MoveRegion(region.id, to: bar).apply(to: &project) }
  }

  @Test func takeFoldersAreSaved() throws {
    let (project, region, _) = audioFolder()
    let reopened = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(reopened.region(withID: region.id) == region)
  }

  // MARK: - Packing

  @Test func packingKeepsWhatPlayed() throws {
    // Two audio regions one after the other: bar 1 from the start of the file, bar 2 from
    // 6 s in.
    let a = Region(name: "A", start: .zero, length: bar, content: .audio(AudioRegionContent(fileID: file.id)))
    let b = Region(name: "B", start: bar, length: bar, content: .audio(AudioRegionContent(fileID: file.id, fileStartFrame: 288_000)))
    var project = Project(tracks: [Track(name: "Vocal", kind: .audio, regions: [a, b])], audioFiles: [file])
    let before = PlaybackPlan(project: project, startPosition: .zero).audioSegments(startingIn: 0..<10).map(\.fileStartFrame)

    try PackTakeFolder([a.id, b.id]).apply(to: &project)
    let folder = try #require(project.tracks[0].regions.first)
    #expect(project.tracks[0].regions.count == 1)
    #expect(folder.id == a.id)
    #expect(folder.length == bar * 2)
    #expect(folder.takeFolder?.takes.map(\.name) == ["Take 1", "Take 2"])
    // Take 2 lines up with the folder start: 2 s before its region.
    #expect(folder.takeFolder?.takes[1].content == .audio(AudioRegionContent(fileID: file.id, fileStartFrame: 192_000)))
    let after = PlaybackPlan(project: project, startPosition: .zero).audioSegments(startingIn: 0..<10).map(\.fileStartFrame)
    #expect(after == before, "The comp plays what the regions played")
  }

  @Test func packingNeedsRegionsOnOneTrack() {
    let a = Region(name: "A", start: .zero, length: bar, content: .midi(MIDISequence()))
    let b = Region(name: "B", start: .zero, length: bar, content: .midi(MIDISequence()))
    var project = Project(tracks: [
      Track(name: "One", kind: .softwareInstrument, regions: [a]), Track(name: "Two", kind: .softwareInstrument, regions: [b]),
    ])
    #expect(throws: EditError.self) { try PackTakeFolder([a.id, b.id]).apply(to: &project) }
    #expect(throws: EditError.self) { try PackTakeFolder([a.id]).apply(to: &project) }
  }

  @Test func packedMIDITakesLineUpWithTheFolder() throws {
    let a = Region(name: "A", start: .zero, length: bar, content: .midi(MIDISequence(notes: [MIDINote(pitch: 60, start: .zero, length: .quarterNotes(1))])))
    let b = Region(name: "B", start: bar, length: bar, content: .midi(MIDISequence(notes: [MIDINote(pitch: 64, start: .zero, length: .quarterNotes(1))])))
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [a, b])])
    try PackTakeFolder([a.id, b.id]).apply(to: &project)
    guard case .midi(let second) = project.tracks[0].regions[0].takeFolder?.takes[1].content else { Issue.record("Not MIDI"); return }
    #expect(second.notes.first?.start == bar)
    let noteOns = PlaybackPlan(project: project, startPosition: .zero).midiEvents(in: 0..<10).filter { $0.bytes.first == 0x90 }
    #expect(noteOns.map(\.playbackTime) == [0, 2], "Both notes still play where they did")
  }
}
