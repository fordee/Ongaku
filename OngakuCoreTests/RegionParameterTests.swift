//
//  RegionParameterTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// The Region Inspector's settings: they change how regions play, not what's in them.
struct RegionParameterTests {
  private func midiRegion(at start: Tick = .zero, length: Tick = .quarterNotes(4), notes: [MIDINote]) -> Region {
    Region(name: "Notes", start: start, length: length, content: .midi(MIDISequence(notes: notes)))
  }

  @Test func transposeAndVelocityChangeHowNotesPlay() {
    var region = midiRegion(notes: [
      MIDINote(pitch: 60, velocity: 100, start: .zero, length: .quarterNotes(1)),
      MIDINote(pitch: 125, velocity: 10, start: .quarterNotes(1), length: .quarterNotes(1)),
    ])
    region.transpose = 5
    region.velocityOffset = -20
    let played = region.playedNotes
    #expect(played.map(\.pitch) == [65], "A note pushed past 127 doesn't play")
    #expect(played.map(\.velocity) == [80])
    guard case .midi(let sequence) = region.content else { return }
    #expect(sequence.notes.map(\.pitch) == [60, 125], "The notes themselves don't change")
  }

  @Test func velocityStaysInRange() {
    var region = midiRegion(notes: [MIDINote(pitch: 60, velocity: 10, start: .zero, length: .quarterNotes(1))])
    region.velocityOffset = -99
    #expect(region.playedNotes.first?.velocity == 1)
    region.velocityOffset = 99
    #expect(region.playedNotes.first?.velocity == 109)
  }

  @Test func playbackQuantizeMovesNotesToTheGrid() {
    var region = midiRegion(notes: [
      MIDINote(pitch: 60, start: Tick(250), length: .quarterNotes(1)),
      MIDINote(pitch: 62, start: Tick(700), length: .quarterNotes(1)),
    ])
    region.playbackQuantize = Tick(480)
    #expect(region.playedNotes.map(\.start) == [Tick(480), Tick(480)])
  }

  @Test func mixedPlaybackQuantizeKeepsTripletsAndStraightNotes() throws {
    // A 1/8-triplet note played late (exact 320) and a straight 1/16 (exact 720).
    var region = midiRegion(notes: [
      MIDINote(pitch: 60, start: Tick(335), length: Tick(100)),
      MIDINote(pitch: 62, start: Tick(730), length: Tick(100)),
    ])
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [region])])
    try SetRegionParameter(.playbackQuantize(Tick(240), or: Tick(320)), for: [region.id]).apply(to: &project)
    region = project.tracks[0].regions[0]
    #expect(region.playedNotes.map(\.start) == [Tick(320), Tick(720)])
    #expect(try ProjectArchive.decode(ProjectArchive.encode(project)).tracks[0].regions[0] == region)
    try SetRegionParameter(.playbackQuantize(nil), for: [region.id]).apply(to: &project)
    #expect(project.tracks[0].regions[0].playbackQuantizeAlternative == nil, "Turning quantize off clears both grids")
    #expect(throws: EditError.self) { try SetRegionParameter(.playbackQuantize(Tick(240), or: .zero), for: [region.id]).apply(to: &project) }
  }

  // MARK: - Loops

  @Test func loopsRepeatUntilTheNextRegion() {
    var looped = midiRegion(length: .quarterNotes(4), notes: [])
    looped.isLooped = true
    let next = midiRegion(at: .quarterNotes(14), notes: [])
    let track = Track(name: "Keys", kind: .softwareInstrument, regions: [looped, next])
    let played = track.playedRegions(until: .quarterNotes(100))
    #expect(played.map(\.start) == [.zero, .quarterNotes(4), .quarterNotes(8), .quarterNotes(12), .quarterNotes(14)])
    #expect(played[3].length == .quarterNotes(2), "The last repeat is cut short by the next region")
  }

  @Test func loopsRepeatUntilTheProjectEnd() {
    var looped = midiRegion(length: .quarterNotes(4), notes: [])
    looped.isLooped = true
    let track = Track(name: "Keys", kind: .softwareInstrument, regions: [looped])
    #expect(track.playedRegions(until: .quarterNotes(10)).map(\.length) == [.quarterNotes(4), .quarterNotes(4), .quarterNotes(2)])
  }

  @Test func loopedNotesPlayInEveryRepeat() {
    var looped = midiRegion(length: .quarterNotes(4), notes: [MIDINote(pitch: 60, start: .zero, length: .quarterNotes(1))])
    looped.isLooped = true
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [looped])])
    project.endPosition = .quarterNotes(12)
    let plan = PlaybackPlan(project: project, startPosition: .zero)
    let noteOns = plan.midiEvents(in: 0..<10).filter { $0.bytes.first.map { $0 & 0xF0 == 0x90 } ?? false }
    // 120 BPM: a repeat every 2 seconds.
    #expect(noteOns.map(\.playbackTime) == [0, 2, 4])
    #expect(project.bounceRange == Tick.zero..<Tick.quarterNotes(12), "Bounces include the repeats")
  }

  // MARK: - Audio gain

  @Test func audioGainIsInTheSegmentEnvelope() throws {
    let file = AudioFileReference(fileName: "Take.caf", sampleRate: 48_000, channelCount: 2, frameCount: 96_000)
    let region = Region(
      name: "Take", start: .zero, length: .quarterNotes(4), content: .audio(AudioRegionContent(fileID: file.id, gain: -6)))
    let project = Project(tracks: [Track(name: "Audio", kind: .audio, regions: [region])], audioFiles: [file])
    let segment = try #require(PlaybackPlan(project: project, startPosition: .quarterNotes(1)).audioSegments(startingIn: 0..<1).first)
    #expect(abs(segment.envelope.gain - 0.501) < 0.001)
    #expect(segment.envelope.offset == 0.5, "Playback started half a second into the region")
    #expect(segment.envelope.regionDuration == 2)
  }

  // MARK: - The command

  @Test func settingsApplyToTheRegionsTheyFit() throws {
    let midi = midiRegion(notes: [])
    let file = AudioFileReference(fileName: "Take.caf", sampleRate: 48_000, channelCount: 2, frameCount: 96_000)
    let audio = Region(name: "Take", start: .zero, length: .quarterNotes(4), content: .audio(AudioRegionContent(fileID: file.id)))
    var project = Project(
      tracks: [
        Track(name: "Keys", kind: .softwareInstrument, regions: [midi]),
        Track(name: "Audio", kind: .audio, regions: [audio]),
      ], audioFiles: [file])
    try SetRegionParameter(.transpose(12), for: [midi.id, audio.id]).apply(to: &project)
    try SetRegionParameter(.velocityOffset(10), for: [midi.id, audio.id]).apply(to: &project)
    try SetRegionParameter(.gain(-3), for: [midi.id, audio.id]).apply(to: &project)
    try SetRegionParameter(.looped(true), for: [midi.id, audio.id]).apply(to: &project)
    #expect(project.region(withID: midi.id)?.transpose == 12)
    // Both kinds transpose (audio by pitch-shifting); velocity is for MIDI only.
    #expect(project.region(withID: audio.id)?.transpose == 12)
    #expect(project.region(withID: midi.id)?.velocityOffset == 10)
    #expect(project.region(withID: audio.id)?.velocityOffset == 0)
    #expect(project.region(withID: audio.id)?.content == .audio(AudioRegionContent(fileID: file.id, gain: -3)))
    #expect(project.region(withID: midi.id)?.isLooped == true)
    #expect(project.region(withID: audio.id)?.isLooped == true)
    #expect(throws: EditError.self) { try SetRegionParameter(.transpose(200), for: [midi.id]).apply(to: &project) }
  }

  @Test func settingsAreSaved() throws {
    var region = midiRegion(notes: [])
    region.isLooped = true
    region.transpose = -7
    region.velocityOffset = 12
    region.playbackQuantize = Tick(240)
    let project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [region])])
    let reopened = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(reopened.tracks[0].regions[0] == region)
  }

  @Test func olderRegionsPlayAsRecorded() throws {
    let json = #"{"id":"6F1C3A8E-1111-4222-8333-944455556666","name":"Old","start":0,"length":3840,"isMuted":false,"content":{"midi":{"_0":{"notes":[]}}}}"#
    let region = try JSONDecoder().decode(Region.self, from: Data(json.utf8))
    #expect(!region.isLooped)
    #expect(region.transpose == 0)
    #expect(region.playbackQuantize == nil)
  }
}
