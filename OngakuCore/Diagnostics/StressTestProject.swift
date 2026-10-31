//
//  StressTestProject.swift
//  OngakuCore
//

import Foundation

/// Builds a large, realistic-looking song for performance testing: about the size of a
/// busy Logic project. The same configuration always produces the same project, so
/// measurements can be compared between runs.
public enum StressTestProject {
  public struct Configuration: Sendable {
    public var instrumentTracks = 60
    public var audioTracks = 32
    public var auxTracks = 8
    public var bars = 64
    /// Regions are this many bars long, with a bar's gap between them.
    public var regionBars = 4
    /// Notes in each MIDI region (sixteenth notes, so 64 fills a 4-bar region).
    public var notesPerRegion = 64
    /// Volume automation points per track; half the tracks get pan automation too.
    public var automationPoints = 32
    /// Every nth track gets a Channel EQ insert.
    public var equalizerEvery = 3

    public init() {}

    public var trackCount: Int { instrumentTracks + audioTracks + auxTracks }
  }

  /// The song. Audio regions use `audioFiles` in turn (none if it's empty).
  public static func make(_ configuration: Configuration = Configuration(), audioFiles: [AudioFileReference] = []) -> Project {
    var random = SeededGenerator(seed: 0x0_DA0_0000_5EED)
    let tempoMap = TempoMap(bpm: 120)
    let bar = Tick.quarterNotes(4)
    let regionLength = bar * Int64(configuration.regionBars)
    let regionStep = bar * Int64(configuration.regionBars + 1)
    let songEnd = bar * Int64(configuration.bars)

    var auxes: [Track] = []
    for index in 0..<configuration.auxTracks {
      var aux = Track(name: "Bus \(index + 1)", kind: .aux)
      aux.channel.inserts = [index.isMultiple(of: 2) ? BuiltInEffect.reverb.makeReference() : BuiltInEffect.delay.makeReference()]
      auxes.append(aux)
    }

    var tracks: [Track] = []
    let colors = TrackColor.allCases
    for index in 0..<(configuration.instrumentTracks + configuration.audioTracks) {
      let isInstrument = index < configuration.instrumentTracks
      var track = Track(
        name: isInstrument ? "Inst \(index + 1)" : "Audio \(index - configuration.instrumentTracks + 1)",
        kind: isInstrument ? .softwareInstrument : .audio,
        color: colors[index % colors.count])
      if isInstrument {
        track.channel.instrument = index % 10 == 0 ? .generalMIDIPercussion(kit: 0) : .generalMIDI(program: (index * 7) % 128)
      }
      track.channel.volume = -Double(random.next(upTo: 12))
      track.channel.pan = Double(random.next(upTo: 200)) / 100 - 1
      if index.isMultiple(of: configuration.equalizerEvery) {
        track.channel.inserts = [BuiltInEffect.channelEQ.makeReference()]
      }
      if !auxes.isEmpty {
        track.channel.sends = [Send(destinationTrackID: auxes[index % auxes.count].id, level: -12)]
      }

      // Regions across the song, staggered so tracks don't all line up.
      var start = bar * Int64(index % (configuration.regionBars + 1))
      var regionNumber = 1
      while start + regionLength <= songEnd {
        if isInstrument {
          track.regions.append(Region(
            name: "\(track.name) \(regionNumber)", start: start, length: regionLength,
            content: .midi(notes(count: configuration.notesPerRegion, length: regionLength, random: &random))))
        } else if !audioFiles.isEmpty {
          let file = audioFiles[(index + regionNumber) % audioFiles.count]
          var region = Region.audio(for: file, at: start, tempoMap: tempoMap)
          region.name = "\(track.name) \(regionNumber)"
          region.length = min(region.length, regionLength)
          track.regions.append(region)
        }
        start += regionStep
        regionNumber += 1
      }

      track.automation = [automation(.volume, points: configuration.automationPoints, end: songEnd, random: &random)]
      if index.isMultiple(of: 2) {
        track.automation.append(automation(.pan, points: configuration.automationPoints, end: songEnd, random: &random))
      }
      tracks.append(track)
    }

    return Project(tempoMap: tempoMap, endPosition: songEnd + bar * 4, tracks: tracks + auxes, audioFiles: audioFiles)
  }

  private static func notes(count: Int, length: Tick, random: inout SeededGenerator) -> MIDISequence {
    let step = Tick(length.rawValue / Int64(max(count, 1)))
    let root = 48 + random.next(upTo: 24)
    let notes = (0..<count).map { index in
      MIDINote(
        pitch: root + [0, 3, 5, 7, 10, 12][random.next(upTo: 6)], velocity: 60 + random.next(upTo: 60),
        start: step * Int64(index), length: Tick(step.rawValue * 3 / 4))
    }
    return MIDISequence(notes: notes)
  }

  private static func automation(_ parameter: AutomationParameter, points: Int, end: Tick, random: inout SeededGenerator) -> AutomationLane {
    let step = Tick(end.rawValue / Int64(max(points, 1)))
    let range = parameter.range
    let values = (0..<points).map { index in
      AutomationPoint(
        position: step * Int64(index),
        value: parameter == .volume
          ? -Double(random.next(upTo: 30))
          : range.lowerBound + (range.upperBound - range.lowerBound) * Double(random.next(upTo: 100)) / 100)
    }
    return AutomationLane(parameter: parameter, points: values)
  }
}

/// A small deterministic random number generator (SplitMix64), so the stress project is the
/// same every run.
struct SeededGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func nextValue() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// A number in 0..<bound.
  mutating func next(upTo bound: Int) -> Int {
    Int(nextValue() % UInt64(max(bound, 1)))
  }
}
