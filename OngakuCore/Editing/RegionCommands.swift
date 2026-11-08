//
//  RegionCommands.swift
//  OngakuCore
//

import Foundation

public struct AddRegion: EditCommand {
  public var trackID: Track.ID
  public var region: Region

  public init(_ region: Region, to trackID: Track.ID) {
    self.trackID = trackID
    self.region = region
  }

  public var actionName: String { "New Region" }

  public func apply(to project: inout Project) throws {
    let trackIndex = try project.requireTrackIndex(trackID)
    guard project.regionLocation(for: region.id) == nil else { throw EditError.duplicateID(region.id) }
    try validate(region, on: project.tracks[trackIndex], in: project)
    project.tracks[trackIndex].regions.append(region)
    project.tracks[trackIndex].sortRegions()
  }
}

public struct DeleteRegions: EditCommand {
  public var regionIDs: Set<Region.ID>

  public init(_ regionIDs: Set<Region.ID>) {
    self.regionIDs = regionIDs
  }

  public var actionName: String { regionIDs.count == 1 ? "Delete Region" : "Delete Regions" }

  public func apply(to project: inout Project) throws {
    for regionID in regionIDs {
      _ = try project.requireRegionLocation(regionID)
    }
    for index in project.tracks.indices {
      project.tracks[index].regions.removeAll { regionIDs.contains($0.id) }
    }
  }
}

/// Moves a region in time and optionally onto another track of the same kind.
public struct MoveRegion: EditCommand {
  public var regionID: Region.ID
  public var start: Tick
  public var destinationTrackID: Track.ID?

  public init(_ regionID: Region.ID, to start: Tick, track destinationTrackID: Track.ID? = nil) {
    self.regionID = regionID
    self.start = start
    self.destinationTrackID = destinationTrackID
  }

  public var actionName: String { "Move Region" }

  public func apply(to project: inout Project) throws {
    guard start >= .zero else { throw EditError.invalidValue("Regions can’t start before the project start.") }
    let location = try project.requireRegionLocation(regionID)
    var region = project.tracks[location.track].regions.remove(at: location.region)
    region.start = start

    let destinationIndex = try destinationTrackID.map { try project.requireTrackIndex($0) } ?? location.track
    try validate(region, on: project.tracks[destinationIndex], in: project)
    project.tracks[destinationIndex].regions.append(region)
    project.tracks[destinationIndex].sortRegions()
  }
}

/// Changes a region's start and length while keeping its content where it is on the
/// timeline, like dragging the edges of a region in Logic.
public struct TrimRegion: EditCommand {
  public var regionID: Region.ID
  public var start: Tick
  public var length: Tick

  public init(_ regionID: Region.ID, start: Tick, length: Tick) {
    self.regionID = regionID
    self.start = start
    self.length = length
  }

  public var actionName: String { "Resize Region" }

  public func apply(to project: inout Project) throws {
    guard start >= .zero, length > .zero else {
      throw EditError.invalidValue("A region needs a positive length and can’t start before the project start.")
    }
    let location = try project.requireRegionLocation(regionID)
    var region = project.tracks[location.track].regions[location.region]
    try region.requireNotTakeFolder()
    let shift = start - region.start

    switch region.content {
    case .midi(var sequence):
      // Notes and controls are stored relative to the region start, so move them the
      // opposite way.
      for index in sequence.notes.indices {
        sequence.notes[index].start -= shift
      }
      for index in sequence.controls.indices {
        sequence.controls[index].position -= shift
      }
      region.content = .midi(sequence)
    case .audio(var audio):
      audio.fileStartFrame += try project.audioFrames(from: region.start, to: start, fileID: audio.fileID)
      guard audio.fileStartFrame >= 0 else {
        throw EditError.invalidValue("The region can’t extend before the start of its audio file.")
      }
      region.content = .audio(audio)
    }

    // A loop end stays where it was on the timeline (and goes if the region now reaches it).
    if let loopEnd = region.loopEnd {
      region.loopedLength = loopEnd > start + length ? loopEnd - start : nil
      if region.loopedLength == nil { region.isLooped = false }
    }
    region.start = start
    region.length = length
    // A pattern plays from the region's start and fills its new length, as does a drummer.
    region.renderPattern()
    region.renderDrummer(tempoMap: project.tempoMap)
    region.renderPlayer(in: project)
    project.tracks[location.track].regions[location.region] = region
    project.tracks[location.track].sortRegions()
  }
}

/// Splits a region in two at a timeline position.
public struct SplitRegion: EditCommand {
  public var regionID: Region.ID
  public var position: Tick
  /// The identifier of the new right-hand region, so callers can select it.
  public var newRegionID: Region.ID

  public init(_ regionID: Region.ID, at position: Tick, newRegionID: Region.ID = UUID()) {
    self.regionID = regionID
    self.position = position
    self.newRegionID = newRegionID
  }

  public var actionName: String { "Split Region" }

  public func apply(to project: inout Project) throws {
    let location = try project.requireRegionLocation(regionID)
    var left = project.tracks[location.track].regions[location.region]
    try left.requireNotTakeFolder()
    guard position > left.start, position < left.end else {
      throw EditError.invalidValue("The split position must be inside the region.")
    }

    let splitOffset = position - left.start
    var right = left
    right.id = newRegionID
    right.start = position
    right.length = left.end - position
    left.length = splitOffset
    // A looped region's repeats carry on after its right-hand half.
    right.loopedLength = left.loopedLength.map { $0 - splitOffset }
    left.isLooped = false
    left.loopedLength = nil

    // The halves of a pattern region keep its notes as they were, as ordinary MIDI regions
    // (a pattern always starts at its region's start, which would shift the second half).
    left.pattern = nil
    right.pattern = nil
    // A drummer or player carries on in both halves, the fill (or lead-in) staying at the
    // end and the crash at the start, as the whole region played them.
    left.drummer?.fillsAtEnd = false
    right.drummer?.crashesAtStart = false
    left.player?.leadsIntoNext = false
    switch left.content {
    case .midi(let sequence):
      // A note belongs to the half it starts in, as in Logic's default split behavior.
      let leftNotes = sequence.notes.filter { $0.start < splitOffset }
      let rightNotes = sequence.notes.filter { $0.start >= splitOffset }.map { note in
        var shifted = note
        shifted.start -= splitOffset
        return shifted
      }
      let leftControls = sequence.controls.filter { $0.position < splitOffset }
      let rightControls = sequence.controls.filter { $0.position >= splitOffset }.map { event in
        var shifted = event
        shifted.position -= splitOffset
        return shifted
      }
      left.content = .midi(MIDISequence(notes: leftNotes, controls: leftControls))
      right.content = .midi(MIDISequence(notes: rightNotes, controls: rightControls))
      // Each generated half plays for its own length, as a resized one does.
      left.renderDrummer(tempoMap: project.tempoMap)
      right.renderDrummer(tempoMap: project.tempoMap)
      left.renderPlayer(in: project)
      right.renderPlayer(in: project)
    case .audio(let audio):
      // The fade in stays on the left half and the fade out on the right.
      var leftAudio = audio
      leftAudio.fadeOut = 0
      var rightAudio = audio
      rightAudio.fadeIn = 0
      rightAudio.fileStartFrame += try project.audioFrames(from: left.start, to: position, fileID: audio.fileID)
      left.content = .audio(leftAudio)
      right.content = .audio(rightAudio)
    }

    project.tracks[location.track].regions[location.region] = left
    project.tracks[location.track].regions.append(right)
    project.tracks[location.track].sortRegions()
  }
}

public struct SetRegionMuted: EditCommand {
  public var regionID: Region.ID
  public var isMuted: Bool

  public init(_ regionID: Region.ID, isMuted: Bool) {
    self.regionID = regionID
    self.isMuted = isMuted
  }

  public var actionName: String { isMuted ? "Mute Region" : "Unmute Region" }

  public func apply(to project: inout Project) throws {
    let location = try project.requireRegionLocation(regionID)
    project.tracks[location.track].regions[location.region].isMuted = isMuted
  }
}

/// Checks that a region can be placed on a track.
private func validate(_ region: Region, on track: Track, in project: Project) throws {
  guard region.content.trackKind == track.kind else {
    throw EditError.trackKindMismatch(expected: region.content.trackKind, found: track.kind)
  }
  guard region.start >= .zero, region.length > .zero else {
    throw EditError.invalidValue("A region needs a positive length and can’t start before the project start.")
  }
  if case .audio(let audio) = region.content, project.audioFile(withID: audio.fileID) == nil {
    throw EditError.audioFileNotFound(audio.fileID)
  }
}

/// Joins regions into one per track, like Logic's Glue tool and Edit › Join Regions. The
/// joined region runs from the first one's start to the last one's end, and takes the first
/// one's name and identifier.
///
/// MIDI regions keep the notes and controllers that played (those inside their region and
/// not muted). Audio regions can only be joined when they play one unbroken stretch of the
/// same file, such as the pieces of a split recording: other audio would need a new file.
public struct GlueRegions: EditCommand {
  public var regionIDs: Set<Region.ID>

  public init(_ regionIDs: Set<Region.ID>) {
    self.regionIDs = regionIDs
  }

  public var actionName: String { "Join Regions" }

  /// The name for the undo menu: joining regions that play generated parts which can't
  /// carry on as one (a pattern, or drummers or players set differently) leaves their notes.
  public func actionName(in project: Project) -> String {
    let convertsAny = project.tracks.contains { track in
      let regions = track.regions.filter { regionIDs.contains($0.id) }
      return regions.count > 1 && regions.contains { $0.pattern != nil || $0.drummer != nil || $0.player != nil }
        && Self.generatedPart(of: regions) == nil
    }
    return convertsAny ? "Join and Convert to MIDI" : actionName
  }

  /// The drummer or player that regions joined together carry on playing, when they all have
  /// the same one (apart from how each starts and ends): its crash from the first, its fill
  /// or lead-in from the last.
  static func generatedPart(of regions: [Region]) -> (drummer: DrummerPerformance?, player: PlayerPerformance?)? {
    let sorted = regions.sorted { $0.start < $1.start }
    guard let first = sorted.first, let last = sorted.max(by: { $0.end < $1.end }),
      !sorted.contains(where: { $0.pattern != nil })
    else { return nil }
    if let drummer = first.drummer {
      let unedged = { (part: DrummerPerformance) -> DrummerPerformance in
        var part = part
        (part.fillsAtEnd, part.crashesAtStart) = (false, false)
        return part
      }
      let parts = sorted.compactMap(\.drummer)
      guard parts.count == sorted.count, parts.allSatisfy({ unedged($0) == unedged(drummer) }) else { return nil }
      var joined = drummer
      joined.fillsAtEnd = last.drummer?.fillsAtEnd ?? drummer.fillsAtEnd
      return (joined, nil)
    }
    if let player = first.player {
      let unedged = { (part: PlayerPerformance) -> PlayerPerformance in
        var part = part
        part.leadsIntoNext = false
        return part
      }
      let parts = sorted.compactMap(\.player)
      guard parts.count == sorted.count, parts.allSatisfy({ unedged($0) == unedged(player) }) else { return nil }
      var joined = player
      joined.leadsIntoNext = last.player?.leadsIntoNext ?? player.leadsIntoNext
      return (nil, joined)
    }
    return nil
  }

  public func apply(to project: inout Project) throws {
    for regionID in regionIDs {
      _ = try project.requireRegionLocation(regionID)
    }
    var joinedAny = false
    for trackIndex in project.tracks.indices {
      let regions = project.tracks[trackIndex].regions.filter { regionIDs.contains($0.id) }
      guard regions.count > 1 else { continue }
      for region in regions { try region.requireNotTakeFolder() }
      var joined = try join(regions, in: project)
      // Matching drummers or players carry on as one, played over the whole length.
      if let part = Self.generatedPart(of: regions) {
        joined.drummer = part.drummer
        joined.player = part.player
        joined.renderDrummer(tempoMap: project.tempoMap)
        joined.renderPlayer(in: project)
      }
      project.tracks[trackIndex].regions.removeAll { regionIDs.contains($0.id) }
      project.tracks[trackIndex].regions.append(joined)
      project.tracks[trackIndex].sortRegions()
      joinedAny = true
    }
    guard joinedAny else { throw EditError.invalidValue("Select two or more regions on a track to join them.") }
  }

  private func join(_ regions: [Region], in project: Project) throws -> Region {
    let sorted = regions.sorted { $0.start < $1.start }
    let first = sorted[0]
    let start = first.start
    let end = sorted.map(\.end).max() ?? first.end
    var joined = first
    joined.length = end - start
    // Joined patterns become the notes they play (unless a drummer or player carries on;
    // see `apply(to:)`).
    joined.pattern = nil
    joined.drummer = nil
    joined.player = nil
    // The joined region is muted only if everything in it was.
    let playing = sorted.filter { !$0.isMuted }
    joined.isMuted = playing.isEmpty

    switch first.content {
    case .midi:
      var notes: [MIDINote] = []
      var controls: [MIDIControlEvent] = []
      for region in playing.isEmpty ? sorted : playing {
        guard case .midi(let sequence) = region.content else { continue }
        let offset = region.start - start
        for note in sequence.notes where note.start >= .zero && note.start < region.length {
          var moved = note
          moved.start += offset
          notes.append(moved)
        }
        for event in sequence.controls where event.position >= .zero && event.position < region.length {
          var moved = event
          moved.position += offset
          controls.append(moved)
        }
      }
      joined.content = .midi(MIDISequence(notes: notes, controls: controls))
    case .audio(let audio):
      var reachedEnd = first.end
      for region in sorted.dropFirst() {
        guard case .audio(let other) = region.content, other.fileID == audio.fileID, other.gain == audio.gain,
          region.start <= reachedEnd
        else { throw Self.audioError }
        // Each piece must play the part of the file that lines up with the first one.
        let expected = audio.fileStartFrame + (try project.audioFrames(from: start, to: region.start, fileID: audio.fileID))
        guard abs(other.fileStartFrame - expected) <= 1 else { throw Self.audioError }
        reachedEnd = max(reachedEnd, region.end)
      }
      // Fades inside the joined region go; it keeps the first's fade in and the last's fade out.
      var joinedAudio = audio
      if let last = sorted.max(by: { $0.end < $1.end }), case .audio(let lastAudio) = last.content {
        joinedAudio.fadeOut = lastAudio.fadeOut
      }
      joined.content = .audio(joinedAudio)
    }
    return joined
  }

  private static let audioError = EditError.invalidValue(
    "Audio regions can only be joined when they’re neighbouring pieces of the same recording.")
}

/// A setting from Logic's Region Inspector.
public enum RegionParameter: Sendable, Equatable {
  case looped(Bool)
  /// MIDI regions play their notes transposed; audio regions are pitch-shifted (rendered,
  /// as Flex is).
  case transpose(Int)
  /// MIDI regions only.
  case velocityOffset(Int)
  /// MIDI regions only; `nil` turns playback quantize off. A second grid makes it a mixed
  /// quantize (the nearer of the two).
  case playbackQuantize(Tick?, or: Tick? = nil)
  /// Audio regions only, in decibels.
  case gain(Double)
  /// Audio regions only, in seconds (kept within the region).
  case fadeIn(Double)
  /// Audio regions only, in seconds (kept within the region).
  case fadeOut(Double)

  public static let gainRange: ClosedRange<Double> = -96...30
}

/// Changes a Region Inspector setting on regions. MIDI-only and audio-only settings skip
/// regions of the other kind, so a mixed selection can be edited together.
public struct SetRegionParameter: EditCommand {
  public var regionIDs: Set<Region.ID>
  public var parameter: RegionParameter

  public init(_ parameter: RegionParameter, for regionIDs: Set<Region.ID>) {
    self.regionIDs = regionIDs
    self.parameter = parameter
  }

  public var actionName: String {
    switch parameter {
    case .looped(let isLooped): isLooped ? "Loop Region" : "Stop Looping Region"
    case .transpose: "Transpose Region"
    case .velocityOffset: "Change Region Velocity"
    case .playbackQuantize: "Quantize Region"
    case .gain: "Change Region Gain"
    case .fadeIn, .fadeOut: "Change Fade"
    }
  }

  public func apply(to project: inout Project) throws {
    switch parameter {
    case .transpose(let value) where !Region.transposeRange.contains(value):
      throw EditError.invalidValue("Transpose must be between −96 and +96 semitones.")
    case .velocityOffset(let value) where !Region.velocityOffsetRange.contains(value):
      throw EditError.invalidValue("Velocity must be between −99 and +99.")
    case .playbackQuantize(let grid, let other) where (grid ?? Tick(1)) <= .zero || (other ?? Tick(1)) <= .zero:
      throw EditError.invalidValue("The quantize grid must be longer than zero.")
    default:
      break
    }
    for regionID in regionIDs {
      let location = try project.requireRegionLocation(regionID)
      var region = project.tracks[location.track].regions[location.region]
      switch (parameter, region.content) {
      case (.looped(let isLooped), _):
        // The Loop switch loops to the next region, as in Logic's Region Inspector.
        region.isLooped = isLooped
        region.loopedLength = nil
      case (.transpose(let value), _):
        region.transpose = value
      case (.velocityOffset(let value), .midi):
        region.velocityOffset = value
      case (.playbackQuantize(let grid, let other), .midi):
        region.playbackQuantize = grid
        region.playbackQuantizeAlternative = grid == nil ? nil : other
      case (.gain(let decibels), .audio(var audio)):
        audio.gain = min(max(decibels, RegionParameter.gainRange.lowerBound), RegionParameter.gainRange.upperBound)
        region.content = .audio(audio)
      case (.fadeIn(let seconds), .audio(var audio)):
        // A fade can reach as far as the other fade.
        audio.fadeIn = min(max(0, seconds), max(0, project.duration(of: region) - audio.fadeOut))
        region.content = .audio(audio)
      case (.fadeOut(let seconds), .audio(var audio)):
        audio.fadeOut = min(max(0, seconds), max(0, project.duration(of: region) - audio.fadeIn))
        region.content = .audio(audio)
      default:
        continue
      }
      project.tracks[location.track].regions[location.region] = region
    }
  }
}

extension Project {
  /// How long a region plays, in seconds.
  public func duration(of region: Region) -> Double {
    tempoMap.seconds(at: region.end) - tempoMap.seconds(at: region.start)
  }
}

/// Crossfades two neighbouring audio regions on a track, as dragging Logic's Fade tool
/// across the border between them does: each region is extended by half the crossfade into
/// the other (as far as its file allows), and the first fades out while the second fades in
/// over the overlap.
public struct CrossfadeRegions: EditCommand {
  public var firstID: Region.ID
  public var secondID: Region.ID
  /// The crossfade's length, in seconds.
  public var duration: Double

  public init(_ firstID: Region.ID, _ secondID: Region.ID, duration: Double) {
    self.firstID = firstID
    self.secondID = secondID
    self.duration = duration
  }

  public var actionName: String { "Crossfade" }

  public func apply(to project: inout Project) throws {
    let firstLocation = try project.requireRegionLocation(firstID)
    let secondLocation = try project.requireRegionLocation(secondID)
    guard firstLocation.track == secondLocation.track else {
      throw EditError.invalidValue("Only regions on the same track can be crossfaded.")
    }
    var first = project.tracks[firstLocation.track].regions[firstLocation.region]
    var second = project.tracks[secondLocation.track].regions[secondLocation.region]
    try first.requireNotTakeFolder()
    try second.requireNotTakeFolder()
    if second.start < first.start { swap(&first, &second) }
    guard case .audio(var firstAudio) = first.content, case .audio(var secondAudio) = second.content,
      let firstFile = project.audioFile(withID: firstAudio.fileID), let secondFile = project.audioFile(withID: secondAudio.fileID)
    else { throw EditError.invalidValue("Only audio regions can be crossfaded.") }
    guard second.start <= first.end, duration > 0 else {
      throw EditError.invalidValue("Crossfades join regions that touch or overlap.")
    }

    let tempoMap = project.tempoMap
    let half = duration / 2
    if second.start == first.end {
      // Extend each region into the other by up to half the crossfade, as far as its file has
      // audio: the first past its end, the second before its start.
      let firstEndFrame = firstAudio.fileStartFrame + Int64((project.duration(of: first) * firstFile.sampleRate).rounded())
      let firstSpare = Double(firstFile.frameCount - firstEndFrame) / firstFile.sampleRate
      let secondSpare = Double(secondAudio.fileStartFrame) / secondFile.sampleRate
      let border = tempoMap.seconds(at: first.end)
      let newEnd = tempoMap.tickPosition(atSeconds: border + min(half, max(0, firstSpare)))
      let newStart = tempoMap.tickPosition(atSeconds: border - min(half, max(0, secondSpare)))
      secondAudio.fileStartFrame -= Int64(((tempoMap.seconds(at: second.start) - tempoMap.seconds(at: newStart)) * secondFile.sampleRate).rounded())
      secondAudio.fileStartFrame = max(0, secondAudio.fileStartFrame)
      first.length = newEnd - first.start
      second.length = second.end - newStart
      second.start = newStart
    }
    // Fade across the overlap.
    let overlap = max(0, tempoMap.seconds(at: first.end) - tempoMap.seconds(at: second.start))
    guard overlap > 0 else {
      throw EditError.invalidValue("There’s no audio beyond these regions’ edges to crossfade with.")
    }
    firstAudio.fadeOut = min(overlap, project.duration(of: first) - firstAudio.fadeIn)
    secondAudio.fadeIn = min(overlap, project.duration(of: second) - secondAudio.fadeOut)
    first.content = .audio(firstAudio)
    second.content = .audio(secondAudio)

    let track = firstLocation.track
    project.tracks[track].regions.removeAll { $0.id == first.id || $0.id == second.id }
    project.tracks[track].regions += [first, second]
    project.tracks[track].sortRegions()
  }
}

extension Region {
  /// Take folders are resized, split and joined by flattening them first, and flexed regions
  /// by removing their markers.
  func requireNotTakeFolder() throws {
    if takeFolder != nil {
      throw EditError.invalidValue("“\(name)” is a take folder. Flatten it first to resize, split, join or crossfade it.")
    }
    // Flex markers are placed in the region's own time, which these edits would shift. They
    // stay when Flex is turned off (hidden), so the message says where to remove them.
    guard case .audio(let audio) = content else { return }
    var fixes: [String] = []
    if !audio.flexMarkers.isEmpty { fixes.append("its flex markers (Remove Flex Markers)") }
    if !audio.pitchEdits.isEmpty { fixes.append("its retuned notes (Reset Retuned Notes)") }
    if abs(audio.stretch - 1) > 0.0001 { fixes.append("its Smart Tempo stretch (Remove Stretch)") }
    if !fixes.isEmpty {
      throw EditError.invalidValue(
        "To resize, split, join or crossfade “\(name)”, first remove \(fixes.formatted(.list(type: .and))): select it and use the button in the Region Inspector.")
    }
  }
}

// MARK: - Step Sequencer patterns

/// Changes a pattern region's pattern, rendering its notes again.
public struct SetStepPattern: EditCommand {
  public var regionID: Region.ID
  public var pattern: StepPattern
  public var actionName: String

  public init(_ pattern: StepPattern, for regionID: Region.ID, actionName: String = "Edit Pattern") {
    self.regionID = regionID
    self.pattern = pattern
    self.actionName = actionName
  }

  public func apply(to project: inout Project) throws {
    let location = try project.requireRegionLocation(regionID)
    var region = project.tracks[location.track].regions[location.region]
    guard case .midi = region.content else { throw EditError.trackKindMismatch(expected: .softwareInstrument, found: .audio) }
    guard StepPattern.lengthRange.contains(pattern.length), pattern.rows.allSatisfy({ MIDINote.pitchRange.contains($0.pitch) })
    else { throw EditError.invalidValue("A pattern has 1 to 64 steps, and notes in the MIDI range.") }
    region.pattern = pattern
    region.renderPattern()
    project.tracks[location.track].regions[location.region] = region
  }
}

/// Turns a pattern or drummer region into an ordinary MIDI region with the notes it plays,
/// to edit in the Piano Roll.
public struct ConvertPatternToNotes: EditCommand {
  public var regionIDs: Set<Region.ID>

  public init(_ regionIDs: Set<Region.ID>) {
    self.regionIDs = regionIDs
  }

  public var actionName: String { "Convert to MIDI Region" }

  public func apply(to project: inout Project) throws {
    for trackIndex in project.tracks.indices {
      for regionIndex in project.tracks[trackIndex].regions.indices where regionIDs.contains(project.tracks[trackIndex].regions[regionIndex].id) {
        project.tracks[trackIndex].regions[regionIndex].renderPattern()
        project.tracks[trackIndex].regions[regionIndex].pattern = nil
        project.tracks[trackIndex].regions[regionIndex].drummer = nil
        project.tracks[trackIndex].regions[regionIndex].player = nil
      }
    }
  }
}

// MARK: - Drummer

/// Changes a drummer region's performance, playing its notes again.
public struct SetDrummerPerformance: EditCommand {
  public var regionIDs: Set<Region.ID>
  public var change: @Sendable (inout DrummerPerformance) -> Void
  public var actionName: String

  /// Applies `change` to each region's own performance, so one setting can change across
  /// several drummer regions and leave the rest of each as it was.
  public init(
    for regionIDs: Set<Region.ID>, actionName: String = "Edit Drummer", change: @escaping @Sendable (inout DrummerPerformance) -> Void
  ) {
    self.regionIDs = regionIDs
    self.change = change
    self.actionName = actionName
  }

  public func apply(to project: inout Project) throws {
    var changed = false
    for trackIndex in project.tracks.indices {
      for regionIndex in project.tracks[trackIndex].regions.indices
      where regionIDs.contains(project.tracks[trackIndex].regions[regionIndex].id) {
        guard var drummer = project.tracks[trackIndex].regions[regionIndex].drummer else { continue }
        change(&drummer)
        drummer.complexity = min(max(drummer.complexity, 0), 1)
        drummer.loudness = min(max(drummer.loudness, 0), 1)
        drummer.fills = min(max(drummer.fills, 0), 1)
        drummer.swing = min(max(drummer.swing, 0), 1)
        project.tracks[trackIndex].regions[regionIndex].drummer = drummer
        project.tracks[trackIndex].regions[regionIndex].renderDrummer(tempoMap: project.tempoMap)
        changed = true
      }
    }
    guard changed else { throw EditError.invalidValue("Select a Drummer region.") }
  }
}
