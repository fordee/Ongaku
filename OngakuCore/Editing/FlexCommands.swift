//
//  FlexCommands.swift
//  OngakuCore
//

import Foundation

/// Turns Flex Time on (in a mode) or off for an audio track.
public struct SetFlexMode: EditCommand {
  public var trackID: Track.ID
  public var mode: FlexMode?

  public init(_ mode: FlexMode?, for trackID: Track.ID) {
    self.trackID = trackID
    self.mode = mode
  }

  public var actionName: String { mode == nil ? "Turn Flex Off" : "Flex Mode" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    guard project.tracks[index].kind == .audio || mode == nil else {
      throw EditError.invalidValue("Flex Time is for audio tracks.")
    }
    project.tracks[index].flexMode = mode
  }
}

/// Replaces an audio region's flex markers (adding, moving and deleting markers all go
/// through this). Markers must stay in order, apart, and inside the region.
public struct SetFlexMarkers: EditCommand {
  public var regionID: Region.ID
  public var markers: [FlexMarker]
  public var actionName: String

  public init(_ markers: [FlexMarker], in regionID: Region.ID, actionName: String = "Flex") {
    self.regionID = regionID
    self.markers = markers
    self.actionName = actionName
  }

  public func apply(to project: inout Project) throws {
    let location = try project.requireRegionLocation(regionID)
    var region = project.tracks[location.track].regions[location.region]
    guard region.takeFolder == nil else { throw EditError.invalidValue("Flatten the take folder before flexing it.") }
    guard case .audio(var audio) = region.content else { throw EditError.invalidValue("Only audio regions can be flexed.") }
    let duration = project.duration(of: region)
    guard FlexMap.isValid(markers, duration: duration, sourceDuration: duration * audio.stretch) else {
      throw EditError.invalidValue("Flex markers can’t pass each other or the region’s edges.")
    }
    audio.flexMarkers = markers.sorted { $0.source < $1.source }
    region.content = .audio(audio)
    project.tracks[location.track].regions[location.region] = region
  }
}

extension Project {
  /// Flex markers that move each transient (seconds into the region's audio) to the nearest
  /// grid line, by `strength` (0…1, Logic's Q-Strength). Transients too close to the
  /// region's edges, or that would cross a neighbour, are left alone.
  public func quantizedFlexMarkers(for region: Region, transients: [Double], grid: Tick, strength: Double = 1) -> [FlexMarker] {
    guard grid > .zero else { return [] }
    let duration = self.duration(of: region)
    let regionStartSeconds = tempoMap.seconds(at: region.start)
    var markers: [FlexMarker] = []
    for transient in transients.sorted() where transient > FlexMap.minimumGap && transient < duration - FlexMap.minimumGap {
      // The grid line nearest the transient, counting from the bar it's in.
      let position = tempoMap.tickPosition(atSeconds: regionStartSeconds + transient)
      let barStart = tempoMap.bar(containing: position).start
      let steps = (Double((position - barStart).rawValue) / Double(grid.rawValue)).rounded()
      let gridSeconds = tempoMap.seconds(at: barStart + grid * Int64(steps)) - regionStartSeconds
      let target = transient + (gridSeconds - transient) * min(max(strength, 0), 1)
      let candidate = FlexMarker(source: transient, target: target)
      guard FlexMap.isValid(markers + [candidate], duration: duration) else { continue }
      markers.append(candidate)
    }
    return markers
  }

  /// Where flexed audio is rendered for playback: one file per distinct flex edit.
  public struct FlexRenderKey: Hashable, Sendable {
    public var fileID: AudioFileReference.ID
    public var fileStartFrame: Int64
    /// The region's length, in frames of the file.
    public var frameCount: Int64
    /// How much of the file it plays, in frames (more or less than `frameCount` when the
    /// region is time-stretched).
    public var sourceFrameCount: Int64
    public var markers: [FlexMarker]
    public var mode: FlexMode
    public var pitchEdits: [PitchEdit]

    public init(
      fileID: AudioFileReference.ID, fileStartFrame: Int64, frameCount: Int64, markers: [FlexMarker], mode: FlexMode,
      pitchEdits: [PitchEdit] = [], sourceFrameCount: Int64? = nil
    ) {
      self.fileID = fileID
      self.fileStartFrame = fileStartFrame
      self.frameCount = frameCount
      self.sourceFrameCount = sourceFrameCount ?? frameCount
      self.markers = markers
      self.mode = mode
      self.pitchEdits = pitchEdits
    }
  }

  /// What a flexed audio region needs rendered, or `nil` if it plays as recorded (Flex is off
  /// on its track, or it has no markers, retuned notes or stretch).
  public func flexRenderKey(for region: Region, on track: Track) -> FlexRenderKey? {
    guard case .audio(let audio) = region.content, let file = audioFile(withID: audio.fileID) else { return nil }
    let isStretched = abs(audio.stretch - 1) > 0.0001
    // A stretched region is rendered even with Flex off (Rhythmic, as Smart Tempo does).
    guard let mode = track.flexMode ?? (isStretched ? .rhythmic : nil) else { return nil }
    let pitchEdits = mode == .pitch ? audio.pitchEdits.filter { abs($0.semitones) > 0.001 } : []
    let markers = track.flexMode == nil ? [] : audio.flexMarkers
    guard !markers.isEmpty || !pitchEdits.isEmpty || isStretched else { return nil }
    let seconds = duration(of: region)
    return FlexRenderKey(
      fileID: audio.fileID, fileStartFrame: audio.fileStartFrame, frameCount: Int64((seconds * file.sampleRate).rounded()),
      markers: markers, mode: mode, pitchEdits: pitchEdits,
      sourceFrameCount: Int64((seconds * audio.stretch * file.sampleRate).rounded()))
  }

  /// The project as playback hears it with Flex: each flexed region plays its rendered file
  /// (from `renders`) instead of the original. A region whose render isn't ready yet plays
  /// as recorded until it is.
  public func playingFlexRenders(_ renders: [FlexRenderKey: AudioFileReference]) -> Project {
    guard !renders.isEmpty else { return self }
    var played = self
    for trackIndex in played.tracks.indices {
      let track = played.tracks[trackIndex]
      guard track.kind == .audio else { continue }
      for regionIndex in track.regions.indices {
        let region = track.regions[regionIndex]
        guard let key = flexRenderKey(for: region, on: track), let render = renders[key],
          case .audio(let audio) = region.content
        else { continue }
        let rendered = AudioRegionContent(fileID: render.id, gain: audio.gain, fadeIn: audio.fadeIn, fadeOut: audio.fadeOut)
        played.tracks[trackIndex].regions[regionIndex].content = .audio(rendered)
        if played.audioFile(withID: render.id) == nil {
          played.audioFiles.append(render)
        }
      }
    }
    return played
  }
}

/// Replaces an audio region's Flex Pitch edits (retuning, resetting and correcting notes).
public struct SetPitchEdits: EditCommand {
  public var regionID: Region.ID
  public var edits: [PitchEdit]
  public var actionName: String

  public init(_ edits: [PitchEdit], in regionID: Region.ID, actionName: String = "Flex Pitch") {
    self.regionID = regionID
    self.edits = edits
    self.actionName = actionName
  }

  public func apply(to project: inout Project) throws {
    let location = try project.requireRegionLocation(regionID)
    var region = project.tracks[location.track].regions[location.region]
    guard region.takeFolder == nil else { throw EditError.invalidValue("Flatten the take folder before retuning it.") }
    guard case .audio(var audio) = region.content else { throw EditError.invalidValue("Only audio regions can be retuned.") }
    guard edits.allSatisfy({ $0.end > $0.start && $0.start >= 0 && abs($0.semitones) <= 24 }) else {
      throw EditError.invalidValue("Notes can be moved up to two octaves.")
    }
    audio.pitchEdits = edits.sorted { $0.start < $1.start }
    region.content = .audio(audio)
    project.tracks[location.track].regions[location.region] = region
  }
}
