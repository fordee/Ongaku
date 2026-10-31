//
//  SmartTempoCommands.swift
//  OngakuCore
//

import Foundation

extension Project {
  /// The beat line nearest a position (beats as the time signature counts them).
  func nearestBeat(to position: Tick) -> Tick {
    let bar = tempoMap.bar(containing: max(.zero, position))
    let beat = tempoMap.timeSignature(atBarIndex: bar.index).ticksPerBeat
    let steps = (Double((position - bar.start).rawValue) / Double(beat.rawValue)).rounded()
    return bar.start + beat * Int64(steps)
  }

  /// Where a region should start so that `beatSeconds` into it lands on a beat line, as near
  /// to where it is now as possible.
  func startAligningBeat(of region: Region, at beatSeconds: Double) -> Tick {
    let beatTime = tempoMap.seconds(at: region.start) + beatSeconds
    var beat = nearestBeat(to: tempoMap.tickPosition(atSeconds: beatTime))
    var start = tempoMap.tickPosition(atSeconds: tempoMap.seconds(at: beat) - beatSeconds)
    // Never before the project start: use the next beat instead.
    while start < .zero {
      let bar = tempoMap.bar(containing: beat)
      beat = beat + tempoMap.timeSignature(atBarIndex: bar.index).ticksPerBeat
      start = tempoMap.tickPosition(atSeconds: tempoMap.seconds(at: beat) - beatSeconds)
    }
    return start
  }
}

/// Smart Tempo's Adapt Project Tempo: the song takes the recording's tempo (the tempo in
/// effect where the region starts changes), and the region moves so its first beat lands on
/// a beat line. Its length is kept in seconds, so it still plays all of its audio.
public struct AdaptProjectTempo: EditCommand {
  public var regionID: Region.ID
  public var tempo: DetectedTempo

  public init(to tempo: DetectedTempo, of regionID: Region.ID) {
    self.regionID = regionID
    self.tempo = tempo
  }

  public var actionName: String { "Adapt Project Tempo" }

  public func apply(to project: inout Project) throws {
    let location = try project.requireRegionLocation(regionID)
    var region = project.tracks[location.track].regions[location.region]
    guard case .audio = region.content else { throw EditError.invalidValue("Smart Tempo works on audio regions.") }
    let seconds = project.duration(of: region)
    let change = project.tempoMap.tempoChanges.last { $0.position <= region.start } ?? project.tempoMap.tempoChanges[0]
    try project.tempoMap.setTempo((tempo.bpm * 100).rounded() / 100, at: change.position)
    region.start = project.startAligningBeat(of: region, at: tempo.firstBeat)
    region.length = project.tempoMap.tickPosition(atSeconds: project.tempoMap.seconds(at: region.start) + seconds) - region.start
    project.tracks[location.track].regions[location.region] = region
    project.tracks[location.track].sortRegions()
  }
}

/// Smart Tempo's Match Project Tempo (Logic's "Keep Project Tempo"): the region is
/// time-stretched to the song's tempo where it starts, and moved so its first beat lands on
/// a beat line.
public struct MatchProjectTempo: EditCommand {
  public var regionID: Region.ID
  public var tempo: DetectedTempo

  public init(_ regionID: Region.ID, from tempo: DetectedTempo) {
    self.regionID = regionID
    self.tempo = tempo
  }

  public var actionName: String { "Match Project Tempo" }

  public func apply(to project: inout Project) throws {
    let location = try project.requireRegionLocation(regionID)
    var region = project.tracks[location.track].regions[location.region]
    guard region.takeFolder == nil, case .audio(var audio) = region.content else {
      throw EditError.invalidValue("Smart Tempo works on audio regions (flatten take folders first).")
    }
    guard audio.flexMarkers.isEmpty else { throw EditError.invalidValue("Remove the region’s flex markers first.") }
    guard tempo.bpm > 0 else { throw EditError.invalidValue("The recording’s tempo couldn’t be found.") }
    // How much of the recording it plays now, and how fast it should go.
    let sourceSeconds = project.duration(of: region) * audio.stretch
    let stretch = project.tempoMap.tempo(at: region.start) / tempo.bpm
    audio.stretch = stretch
    region.content = .audio(audio)
    region.start = project.startAligningBeat(of: region, at: tempo.firstBeat / stretch)
    let startSeconds = project.tempoMap.seconds(at: region.start)
    region.length = project.tempoMap.tickPosition(atSeconds: startSeconds + sourceSeconds / stretch) - region.start
    project.tracks[location.track].regions[location.region] = region
    project.tracks[location.track].sortRegions()
  }
}

/// Puts a region back to playing its recording at the speed it was made.
public struct ResetRegionStretch: EditCommand {
  public var regionID: Region.ID

  public init(_ regionID: Region.ID) {
    self.regionID = regionID
  }

  public var actionName: String { "Remove Smart Tempo Stretch" }

  public func apply(to project: inout Project) throws {
    let location = try project.requireRegionLocation(regionID)
    var region = project.tracks[location.track].regions[location.region]
    guard case .audio(var audio) = region.content, audio.stretch != 1 else { return }
    let sourceSeconds = project.duration(of: region) * audio.stretch
    audio.stretch = 1
    region.content = .audio(audio)
    region.length = project.tempoMap.tickPosition(atSeconds: project.tempoMap.seconds(at: region.start) + sourceSeconds) - region.start
    project.tracks[location.track].regions[location.region] = region
  }
}
