//
//  PlaybackPlanTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

struct PlaybackPlanTests {
  /// 120 BPM, 4/4: one bar is 3840 ticks and 2 seconds. The audio file is 48 kHz and 60 s long.
  private let bar = Tick(3840)
  private let file = AudioFileReference(fileName: "Loop.wav", sampleRate: 48_000, channelCount: 2, frameCount: 48_000 * 60)

  private func makeProject(regionStart: Tick, regionLength: Tick, cycle: CycleRange? = nil) -> (Project, Region) {
    let region = Region.audio(for: file, at: regionStart, tempoMap: TempoMap())
    var sized = region
    sized.length = regionLength
    let track = Track(name: "Audio 1", kind: .audio, regions: [sized])
    var project = Project(tracks: [track], audioFiles: [file])
    if let cycle { project.cycle = cycle }
    return (project, sized)
  }

  /// A count-in clicks every beat of the bars before the start, at the tempo and meter there.
  @Test func countInClicksBeforeTheStart() throws {
    var tempoMap = TempoMap()
    try tempoMap.setTempo(90, at: .zero)
    try tempoMap.setTimeSignature(TimeSignature(beatsPerBar: 6, beatUnit: 8), atBarIndex: 0)
    let countIn = PlaybackPlan.countIn(bars: 2, before: bar * 3, in: tempoMap)

    // An eighth note at 90 quarter notes a minute lasts a third of a second.
    #expect(countIn.clicks.count == 12)
    #expect(abs(countIn.duration - 4) < 1e-9)
    #expect(abs(countIn.clicks[0].playbackTime - -4) < 1e-9)
    #expect(abs(countIn.clicks[11].playbackTime - -1.0 / 3) < 1e-9)
    #expect(countIn.clicks.map(\.isDownbeat) == [true] + Array(repeating: false, count: 5) + [true] + Array(repeating: false, count: 5))
    #expect(PlaybackPlan.countIn(bars: 0, before: .zero, in: tempoMap).clicks.isEmpty)
  }

  @Test func regionLengthMatchesFileDuration() {
    let region = Region.audio(for: file, at: bar, tempoMap: TempoMap())
    // 60 seconds at 120 BPM is 30 bars.
    #expect(region.length == bar * 30)
    #expect(region.name == "Loop")
  }

  @Test func segmentStartsWhenTheRegionStarts() {
    let (project, region) = makeProject(regionStart: bar, regionLength: bar * 2)
    let plan = PlaybackPlan(project: project, startPosition: .zero)

    let segments = plan.audioSegments(startingIn: 0..<10)
    #expect(segments.count == 1)
    #expect(segments.first?.regionID == region.id)
    #expect(segments.first?.playbackTime == 2)
    #expect(segments.first?.fileStartFrame == 0)
    #expect(segments.first?.frameCount == 192_000)
  }

  @Test func startingInsideARegionPlaysTheRestOfIt() {
    let (project, _) = makeProject(regionStart: .zero, regionLength: bar * 2)
    let plan = PlaybackPlan(project: project, startPosition: bar)

    let segment = plan.audioSegments(startingIn: 0..<1).first
    #expect(segment?.playbackTime == 0)
    #expect(segment?.fileStartFrame == 96_000)
    #expect(segment?.frameCount == 96_000)
  }

  @Test func eachSegmentIsReportedInExactlyOneWindow() {
    let (project, _) = makeProject(regionStart: bar, regionLength: bar)
    let plan = PlaybackPlan(project: project, startPosition: .zero)
    let windows = stride(from: 0.0, to: 10, by: 0.5).map { $0..<($0 + 0.5) }
    let total = windows.map { plan.audioSegments(startingIn: $0).count }.reduce(0, +)
    #expect(total == 1)
  }

  @Test func mutedRegionsAreSkipped() {
    var (project, _) = makeProject(regionStart: .zero, regionLength: bar)
    project.tracks[0].regions[0].isMuted = true
    let plan = PlaybackPlan(project: project, startPosition: .zero)
    #expect(plan.audioSegments(startingIn: 0..<10).isEmpty)
  }

  @Test func cycleRepeatsSegmentsAndWrapsThePlayhead() {
    // Cycle bars 1–2 (4 seconds); the region fills bar 1.
    let cycle = CycleRange(isEnabled: true, start: .zero, end: bar * 2)
    let (project, _) = makeProject(regionStart: .zero, regionLength: bar, cycle: cycle)
    let plan = PlaybackPlan(project: project, startPosition: .zero)

    #expect(plan.duration == nil)
    let times = plan.audioSegments(startingIn: 0..<12).map(\.playbackTime)
    #expect(times == [0, 4, 8])

    #expect(plan.timelinePosition(atPlaybackTime: 1) == Tick(1920))
    #expect(plan.timelinePosition(atPlaybackTime: 5) == Tick(1920))
  }

  @Test func startingBeforeTheCyclePlaysIntoIt() {
    // Cycle bars 3–4; start at bar 1. The first pass lasts until the end of bar 4 (8 s).
    let cycle = CycleRange(isEnabled: true, start: bar * 2, end: bar * 4)
    let (project, _) = makeProject(regionStart: bar * 2, regionLength: bar, cycle: cycle)
    let plan = PlaybackPlan(project: project, startPosition: .zero)

    let times = plan.audioSegments(startingIn: 0..<16).map(\.playbackTime)
    #expect(times == [4, 8, 12])
    #expect(plan.timelinePosition(atPlaybackTime: 9) == bar * 2 + Tick(1920))
  }

  @Test func startingAfterTheCycleDoesNotLoop() {
    let cycle = CycleRange(isEnabled: true, start: .zero, end: bar)
    let (project, _) = makeProject(regionStart: .zero, regionLength: bar, cycle: cycle)
    let plan = PlaybackPlan(project: project, startPosition: bar * 2)
    #expect(plan.duration != nil)
  }

  @Test func playbackStopsAtTheProjectEnd() {
    var (project, _) = makeProject(regionStart: .zero, regionLength: bar)
    project.endPosition = bar * 8
    let plan = PlaybackPlan(project: project, startPosition: bar * 2)
    #expect(plan.duration == 12)
  }

  @Test func metronomeClicksOnEveryBeatAndAccentsDownbeats() {
    let (project, _) = makeProject(regionStart: .zero, regionLength: bar)
    let plan = PlaybackPlan(project: project, startPosition: .zero)
    let clicks = plan.clicks(in: 0..<2)
    #expect(clicks.map(\.playbackTime) == [0, 0.5, 1, 1.5])
    #expect(clicks.map(\.isDownbeat) == [true, false, false, false])
  }

  @Test func metronomeFollowsTheCycle() {
    let cycle = CycleRange(isEnabled: true, start: .zero, end: bar)
    let (project, _) = makeProject(regionStart: .zero, regionLength: bar, cycle: cycle)
    let plan = PlaybackPlan(project: project, startPosition: .zero)
    let downbeats = plan.clicks(in: 0..<6).filter(\.isDownbeat).map(\.playbackTime)
    #expect(downbeats == [0, 2, 4])
  }

  // MARK: - MIDI

  /// An instrument track with a two-bar MIDI region at bar 2 holding the given notes.
  private func makeMIDIProject(_ notes: [MIDINote], controls: [MIDIControlEvent] = [], cycle: CycleRange? = nil) -> Project {
    let region = Region(
      name: "Riff", start: bar, length: bar * 2, content: .midi(MIDISequence(notes: notes, controls: controls)))
    var project = Project(tracks: [Track(name: "Inst 1", kind: .softwareInstrument, regions: [region])])
    if let cycle { project.cycle = cycle }
    return project
  }

  @Test func notesProduceNoteOnAndNoteOff() {
    // A quarter note on beat 2 of the region: on at 2.5 s, off at 3 s.
    let project = makeMIDIProject([MIDINote(pitch: 60, velocity: 90, start: Tick(960), length: Tick(960))])
    let events = PlaybackPlan(project: project, startPosition: .zero).midiEvents(in: 0..<10)

    #expect(events.map(\.playbackTime) == [2.5, 3])
    #expect(events.map(\.kind) == [.noteOn(velocity: 90), .noteOff])
    #expect(events.first?.bytes == [0x90, 60, 90])
    #expect(events.last?.bytes == [0x80, 60, 0])
  }

  @Test func controllersPlayAtTheirTimeAfterStartingFromNeutral() {
    // Volume 80 on beat 2 of the region, 2.5 s in. Playback starts before it, so the volume
    // is first set to its neutral value.
    let project = makeMIDIProject([], controls: [MIDIControlEvent(kind: .volume, position: Tick(960), value: 80)])
    let events = PlaybackPlan(project: project, startPosition: .zero).midiEvents(in: 0..<10)
    #expect(events.map(\.playbackTime) == [0, 2.5])
    #expect(events.map(\.kind) == [.control(.volume, value: 100), .control(.volume, value: 80)])
    #expect(events.last?.bytes == [0xB0, 7, 80])
  }

  @Test func startingMidSongChasesEachControllersLatestValue() {
    let project = makeMIDIProject([], controls: [
      MIDIControlEvent(kind: .volume, position: Tick(960), value: 80),
      MIDIControlEvent(kind: .pitchBend, channel: 2, position: Tick(1000), value: 3000),
      MIDIControlEvent(kind: .volume, position: Tick(2880), value: 40),
    ])
    // Start half way through the region's first bar (timeline 3 s).
    let events = PlaybackPlan(project: project, startPosition: bar + Tick(1920)).midiEvents(in: 0..<10)
    #expect(events.map(\.playbackTime) == [0, 0, 0.5])
    #expect(events.map(\.kind) == [
      .control(.volume, value: 80), .control(.pitchBend, value: 3000), .control(.volume, value: 40),
    ])
    #expect(events[1].channel == 2)
  }

  @Test func eachCyclePassStartsFromTheControllersValuesThere() {
    // Cycle the region's first bar; a bend half way through must not carry over the jump.
    let project = makeMIDIProject(
      [], controls: [MIDIControlEvent(kind: .pitchBend, position: Tick(1920), value: 1000)],
      cycle: CycleRange(isEnabled: true, start: bar, end: bar * 2))
    let events = PlaybackPlan(project: project, startPosition: bar).midiEvents(in: 0..<4)
    #expect(events.map(\.playbackTime) == [0, 1, 2, 3])
    #expect(events.map(\.kind) == [
      .control(.pitchBend, value: 0), .control(.pitchBend, value: 1000),
      .control(.pitchBend, value: 0), .control(.pitchBend, value: 1000),
    ])
  }

  @Test func controllersComeBetweenNoteOffsAndNoteOns() {
    let project = makeMIDIProject(
      [MIDINote(pitch: 60, start: .zero, length: Tick(960)), MIDINote(pitch: 62, start: Tick(960), length: Tick(960))],
      controls: [MIDIControlEvent(kind: .modulation, position: Tick(960), value: 64)])
    let atBeat2 = PlaybackPlan(project: project, startPosition: .zero).midiEvents(in: 0..<10).filter { $0.playbackTime == 2.5 }
    #expect(atBeat2.map(\.kind) == [.noteOff, .control(.modulation, value: 64), .noteOn(velocity: 100)])
  }

  @Test func controllersOutsideTheRegionDontPlay() {
    let project = makeMIDIProject([], controls: [
      MIDIControlEvent(kind: .volume, position: Tick(-960), value: 1),
      MIDIControlEvent(kind: .volume, position: bar * 2, value: 2),
    ])
    let events = PlaybackPlan(project: project, startPosition: .zero).midiEvents(in: 0..<20)
    #expect(events.isEmpty, "A track whose controllers are all trimmed away has nothing to chase")
  }

  @Test func notesAreCutAtTheRegionEnd() {
    // A note that runs past the end of the two-bar region stops at the region end (6 s).
    let project = makeMIDIProject([MIDINote(pitch: 60, start: bar, length: bar * 4)])
    let events = PlaybackPlan(project: project, startPosition: .zero).midiEvents(in: 0..<20)
    #expect(events.map(\.playbackTime) == [4, 6])
  }

  @Test func trimmedAwayNotesDontPlay() {
    let project = makeMIDIProject([
      MIDINote(pitch: 50, start: Tick(-960), length: Tick(480)),
      MIDINote(pitch: 52, start: bar * 3, length: Tick(480)),
    ])
    #expect(PlaybackPlan(project: project, startPosition: .zero).midiEvents(in: 0..<20).isEmpty)
  }

  @Test func notesBeforeTheStartPositionArentChased() {
    let project = makeMIDIProject([MIDINote(pitch: 60, start: .zero, length: bar)])
    let events = PlaybackPlan(project: project, startPosition: bar + Tick(960)).midiEvents(in: 0..<10)
    #expect(events.isEmpty)
  }

  @Test func cycleCutsHangingNotesAndRepeats() {
    // Cycle bars 2–3 (2 s–6 s); a note at the start of bar 3 that would last two bars.
    let cycle = CycleRange(isEnabled: true, start: bar, end: bar * 3)
    let project = makeMIDIProject([MIDINote(pitch: 64, start: bar, length: bar * 2)], cycle: cycle)
    let events = PlaybackPlan(project: project, startPosition: bar).midiEvents(in: 0..<9)

    // Pass 1: on at 2 s (bar 3 = 4 s into the timeline, 2 s into playback), off at the cycle end
    // (4 s). Pass 2 repeats 4 s later.
    #expect(events.map(\.playbackTime) == [2, 4, 6, 8])
    #expect(events.map(\.kind) == [.noteOn(velocity: 100), .noteOff, .noteOn(velocity: 100), .noteOff])
  }

  @Test func noteOffComesBeforeNoteOnAtTheSameTime() {
    let project = makeMIDIProject([
      MIDINote(pitch: 60, start: .zero, length: Tick(960)),
      MIDINote(pitch: 60, start: Tick(960), length: Tick(960)),
    ])
    let events = PlaybackPlan(project: project, startPosition: .zero).midiEvents(in: 2.4..<2.6)
    #expect(events.map(\.kind) == [.noteOff, .noteOn(velocity: 100)])
  }

  @Test func mutedMIDIRegionsAreSilent() {
    var project = makeMIDIProject([MIDINote(pitch: 60, start: .zero, length: Tick(960))])
    project.tracks[0].regions[0].isMuted = true
    #expect(PlaybackPlan(project: project, startPosition: .zero).midiEvents(in: 0..<10).isEmpty)
  }

  @Test func soloOverridesOtherTracks() {
    var project = Project(tracks: [
      Track(name: "A", kind: .audio), Track(name: "B", kind: .audio), Track(name: "C", kind: .audio),
    ])
    let ids = project.tracks.map(\.id)
    #expect(ids.allSatisfy(project.isTrackAudible))

    project.tracks[1].channel.isSoloed = true
    #expect(ids.map(project.isTrackAudible) == [false, true, false])

    project.tracks[1].channel.isMuted = true
    #expect(project.isTrackAudible(ids[1]) == false)
  }

  @Test func addAudioFileRejectsEmptyFiles() {
    var project = Project()
    let empty = AudioFileReference(fileName: "Empty.wav", sampleRate: 48_000, channelCount: 2, frameCount: 0)
    #expect(throws: EditError.self) { try AddAudioFile(empty).apply(to: &project) }
  }
}

// MARK: - MIDI FX

extension PlaybackPlanTests {
  private func notes(_ effects: [MIDIEffect], _ input: [EffectNote]) -> [EffectNote] {
    effects.process(input)
  }

  private var cMajor: [EffectNote] { [60, 64, 67].map { EffectNote(start: .zero, end: Tick(1920), pitch: $0, velocity: 90) } }

  @Test func theArpeggiatorStepsThroughHeldChords() {
    let up = notes([MIDIEffect(.arpeggiator(Arpeggiator(rate: .sixteenth, order: .up)))], cMajor)
    #expect(up.map(\.pitch) == [60, 64, 67, 60, 64, 67, 60, 64], "Half a note of sixteenths, climbing")
    #expect(up.map(\.start) == (0..<8).map { Tick(240) * Int64($0) })
    #expect(up.allSatisfy { $0.end - $0.start == Tick(192) && $0.velocity == 90 }, "80 % gate, played velocity")

    let twoOctaves = notes([MIDIEffect(.arpeggiator(Arpeggiator(rate: .eighth, order: .upDown, octaves: 2)))], cMajor)
    #expect(twoOctaves.map(\.pitch) == [60, 64, 67, 72], "Up through two octaves")
    let down = notes([MIDIEffect(.arpeggiator(Arpeggiator(rate: .quarter, order: .down, fixedVelocity: 127)))], cMajor)
    #expect(down.map(\.pitch) == [67, 64] && down.allSatisfy { $0.velocity == 127 })
    let chord = notes([MIDIEffect(.arpeggiator(Arpeggiator(rate: .quarter, order: .chord)))], cMajor)
    #expect(chord.count == 6, "The whole chord on each beat")
  }

  @Test func theArpeggiatorStartsAgainAfterTheKeysAreLetGo() {
    let first = [60, 64].map { EffectNote(start: .zero, end: Tick(480), pitch: $0, velocity: 80) }
    // A rest, then the same chord again a bar later.
    let again = [60, 64].map { EffectNote(start: Tick(3840), end: Tick(4320), pitch: $0, velocity: 80) }
    let played = notes([MIDIEffect(.arpeggiator(Arpeggiator(rate: .eighth)))], first + again)
    #expect(played.map(\.pitch) == [60, 60], "Each phrase starts from the bottom")
    #expect(played.map(\.start) == [.zero, Tick(3840)])
  }

  @Test func chordsScalesRepeatsTranspositionAndVelocity() {
    let c = EffectNote(start: .zero, end: Tick(480), pitch: 60, velocity: 100)
    #expect(notes([MIDIEffect(.chordTrigger(ChordTrigger(chord: .minorSeventh)))], [c]).map(\.pitch) == [60, 63, 67, 70])

    let cSharp = EffectNote(start: .zero, end: Tick(480), pitch: 61, velocity: 100)
    let aMinor = MIDIEffect(.scaleQuantize(ScaleQuantize(root: 9, scale: .naturalMinor)))
    #expect(notes([aMinor], [cSharp]).first?.pitch == 60, "C♯ isn't in A minor: down to C")

    let echoes = notes([MIDIEffect(.noteRepeater(NoteRepeater(rate: .eighth, repeats: 3, velocityChange: -50, transpose: 12)))], [c])
    #expect(echoes.map(\.start) == [.zero, Tick(480), Tick(960), Tick(1440)])
    #expect(echoes.map(\.velocity) == [100, 50, 25, 13])
    #expect(echoes.map(\.pitch) == [60, 72, 84, 96])

    #expect(notes([MIDIEffect(.transposer(Transposer(semitones: -12)))], [c]).first?.pitch == 48)
    let louder = MIDIEffect(.velocityProcessor(VelocityProcessor(scale: 150, offset: 5, maximum: 120)))
    #expect(notes([louder], [c]).first?.velocity == 120, "150 % plus 5, limited to 120")
    let bypassed = MIDIEffect(.transposer(Transposer(semitones: 7)), isBypassed: true)
    #expect(notes([bypassed], [c]).first?.pitch == 60)
  }

  @Test func theRandomizerIsTheSameEveryTime() {
    let line = (0..<16).map { EffectNote(start: Tick(240) * Int64($0), end: Tick(240) * Int64($0) + Tick(200), pitch: 60, velocity: 80) }
    let randomizer = MIDIEffect(.randomizer(Randomizer(velocity: 20, timing: 10)))
    let once = notes([randomizer], line), twice = notes([randomizer], line)
    #expect(once == twice)
    #expect(once.contains { $0.velocity != 80 })
    #expect(once.allSatisfy { abs($0.velocity - 80) <= 20 })
  }

  @Test func playbackPlaysTheTrackThroughItsMIDIEffects() {
    // A C held for a quarter note on the region's first beat, arpeggiated in sixteenths over
    // two octaves, then transposed up a fifth.
    var project = makeMIDIProject([MIDINote(pitch: 60, velocity: 100, start: .zero, length: Tick(960))])
    project.tracks[0].channel.midiEffects = [
      MIDIEffect(.arpeggiator(Arpeggiator(rate: .sixteenth, octaves: 2))),
      MIDIEffect(.transposer(Transposer(semitones: 7))),
    ]
    let ons = PlaybackPlan(project: project, startPosition: .zero).midiEvents(in: 0..<10).filter {
      if case .noteOn = $0.kind { true } else { false }
    }
    #expect(ons.map(\.pitch) == [67, 79, 67, 79])
    #expect(ons.map(\.playbackTime) == [2, 2.125, 2.25, 2.375], "Sixteenths from the region's start (2 s at 120 BPM)")
  }

  @Test func midiEffectsAreSavedAndOldSongsHaveNone() throws {
    var project = makeMIDIProject([])
    project.tracks[0].channel.midiEffects = [MIDIEffect(.chordTrigger(ChordTrigger(chord: .sus4)))]
    let reread = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(reread.tracks[0].channel.midiEffects == project.tracks[0].channel.midiEffects)
    let old = try JSONDecoder().decode(ChannelStrip.self, from: Data(#"{"volume":0,"pan":0,"isMuted":false,"isSoloed":false}"#.utf8))
    #expect(old.midiEffects.isEmpty)
  }
}
