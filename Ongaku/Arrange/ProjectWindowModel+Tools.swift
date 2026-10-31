//
//  ProjectWindowModel+Tools.swift
//  Ongaku
//

import AppKit
import OngakuCore

/// The tools for the tracks area, as in Logic's Tool menu (press T, then the tool's key).
enum ArrangeTool: String, CaseIterable, Identifiable {
  case pointer, pencil, eraser, scissors, glue, mute, fade

  var id: Self { self }

  var name: String {
    switch self {
    case .pointer: "Pointer Tool"
    case .pencil: "Pencil Tool"
    case .eraser: "Eraser Tool"
    case .scissors: "Scissors Tool"
    case .glue: "Glue Tool"
    case .mute: "Mute Tool"
    case .fade: "Fade Tool"
    }
  }

  var symbolName: String {
    switch self {
    case .pointer: "cursorarrow"
    case .pencil: "pencil"
    case .eraser: "eraser"
    case .scissors: "scissors"
    case .glue: "drop"
    case .mute: "speaker.slash"
    case .fade: "line.diagonal"
    }
  }

  /// The key that picks the tool while the Tool menu is open (Logic's).
  var key: Character {
    switch self {
    case .pointer: "t"
    case .pencil: "p"
    case .eraser: "e"
    case .scissors: "i"
    case .glue: "g"
    case .mute: "m"
    case .fade: "a"
    }
  }

  /// What clicking does with the tool, for its help tag.
  var help: String {
    switch self {
    case .pointer: "Select, move and resize regions"
    case .pencil: "Click an empty instrument lane to add a region"
    case .eraser: "Click a region to delete it"
    case .scissors: "Click a region to split it there"
    case .glue: "Click a selected region to join the selected regions"
    case .mute: "Click a region to mute or unmute it"
    case .fade: "Drag over an audio region’s start or end to fade it, or across two regions to crossfade"
    }
  }

  /// Whether regions can be moved and resized with the tool.
  var movesRegions: Bool { self == .pointer || self == .pencil }
}

extension ProjectWindowModel {
  /// T opens the Tool menu of the area the pointer is over (or, if it's over neither, the
  /// one clicked last); the next key picks a tool, as in Logic.
  func showToolMenu() {
    if pianoRoll.isPointerOver, isEditorVisible {
      activeEditingArea = .pianoRoll
    } else if isPointerOverTracks {
      activeEditingArea = .tracks
    }
    isShowingToolMenu = true
  }

  /// Handles a key pressed while the Tool menu is open. Returns `true` if it picked a tool.
  func pickTool(forKey key: String) -> Bool {
    let forPianoRoll = pianoRoll.isToolMenuForPianoRoll
    isShowingToolMenu = false
    if forPianoRoll {
      guard let tool = PianoRollTool.allCases.first(where: { String($0.key) == key }) else { return false }
      pianoRoll.tool = tool
      return true
    }
    guard let tool = ArrangeTool.allCases.first(where: { String($0.key) == key }) else { return false }
    self.tool = tool
    return true
  }

  /// What a click with the current tool does to a region. Returns `false` when the tool
  /// leaves the click to the usual selection (the pointer and pencil do).
  func applyTool(to regionID: Region.ID, at position: Tick) -> Bool {
    // A click on a selected region acts on the whole selection, as in Logic.
    let targets = selectedRegionIDs.contains(regionID) ? selectedRegionIDs : [regionID]
    switch tool {
    case .pointer, .pencil:
      return false
    case .fade:
      // Fades are dragged; a click does nothing.
      break
    case .eraser:
      perform(DeleteRegions(targets))
      selectedRegionIDs.subtract(targets)
    case .scissors:
      split(targets, at: snap(position))
    case .glue:
      guard targets.count > 1 else {
        errorMessage = "Select the regions to join, then click one of them with the Glue tool."
        return true
      }
      let glue = GlueRegions(targets)
      perform(glue, named: glue.actionName(in: project))
      selectedRegionIDs = Set(selectedRegionIDs.filter { project.region(withID: $0) != nil })
    case .mute:
      // Logic mutes them all, unless the clicked one is muted: then it unmutes them all.
      let mute = project.region(withID: regionID)?.isMuted != true
      let commands = targets.map { SetRegionMuted($0, isMuted: mute) }
      perform(CompositeCommand(mute ? "Mute Regions" : "Unmute Regions", commands: commands))
    }
    return true
  }

  /// Splits regions at a position. Both halves end up selected, as with Split at Playhead.
  func split(_ regionIDs: Set<Region.ID>, at position: Tick) {
    var newIDs: Set<Region.ID> = []
    let commands: [any EditCommand] = regionIDs.compactMap { id in
      guard let region = project.region(withID: id), position > region.start, position < region.end else { return nil }
      let command = SplitRegion(id, at: position)
      newIDs.insert(command.newRegionID)
      return command
    }
    guard !commands.isEmpty else { return }
    perform(CompositeCommand(commands.count == 1 ? "Split Region" : "Split Regions", commands: commands))
    if newIDs.allSatisfy({ project.region(withID: $0) != nil }) {
      selectedRegionIDs = regionIDs.union(newIDs)
    }
  }

  /// Where a Fade tool drag starting at `position` on a region fades: in from the start if it
  /// begins in the first half, otherwise out to the end; or a crossfade if it begins where
  /// the region meets a neighbouring audio region: anywhere they overlap, or near the border
  /// if they only touch.
  func fadeTarget(for regionID: Region.ID, at position: Tick, borderTolerance: Tick) -> FadeTarget? {
    guard let location = project.regionLocation(for: regionID) else { return nil }
    let regions = project.tracks[location.track].regions
    let region = regions[location.region]
    guard case .audio = region.content else { return nil }
    let neighbours = regions.filter { $0.id != region.id && $0.content.trackKind == .audio }
    // One that starts inside this region (or at its end) and goes on past it.
    if let next = neighbours.first(where: { $0.start > region.start && $0.start <= region.end && $0.end > region.end }),
      position >= next.start - borderTolerance, position <= region.end + borderTolerance
    {
      return .crossfade(region.id, next.id)
    }
    // One that started before this region and ends inside it (or at its start).
    if let previous = neighbours.last(where: { $0.start < region.start && $0.end >= region.start && $0.end < region.end }),
      position >= region.start - borderTolerance, position <= previous.end + borderTolerance
    {
      return .crossfade(previous.id, region.id)
    }
    let middle = region.start + Tick(region.length.rawValue / 2)
    return position < middle ? .fadeIn(region.id) : .fadeOut(region.id)
  }

  /// The fade a Fade tool drag from `start` to `end` makes.
  func fadeChange(_ target: FadeTarget, from start: Tick, to end: Tick) -> FadePreview? {
    let tempoMap = project.tempoMap
    switch target {
    case .fadeIn(let id):
      guard let region = project.region(withID: id) else { return nil }
      let seconds = tempoMap.seconds(at: max(end, region.start)) - tempoMap.seconds(at: region.start)
      return FadePreview(regionID: id, fadeIn: seconds)
    case .fadeOut(let id):
      guard let region = project.region(withID: id) else { return nil }
      let seconds = tempoMap.seconds(at: region.end) - tempoMap.seconds(at: min(end, region.end))
      return FadePreview(regionID: id, fadeOut: seconds)
    case .crossfade:
      // Crossfades are as long as twice the drag, centred on the border.
      return nil
    }
  }

  /// Ends a Fade tool drag.
  func finishFade(_ target: FadeTarget, from start: Tick, to end: Tick) {
    switch target {
    case .fadeIn(let id):
      if let seconds = fadeChange(target, from: start, to: end)?.fadeIn {
        perform(SetRegionParameter(.fadeIn(seconds), for: [id]))
      }
    case .fadeOut(let id):
      if let seconds = fadeChange(target, from: start, to: end)?.fadeOut {
        perform(SetRegionParameter(.fadeOut(seconds), for: [id]))
      }
    case .crossfade(let first, let second):
      let tempoMap = project.tempoMap
      let seconds = abs(tempoMap.seconds(at: end) - tempoMap.seconds(at: start)) * 2
      guard seconds > 0.001 else { return }
      perform(CrossfadeRegions(first, second, duration: seconds))
    }
  }

  /// Edit › Pack Take Folder (⌥⌘F): the selected regions on a track become one take
  /// folder, which is then selected.
  func packTakeFolder() {
    guard let firstID = selectedRegionIDs.first(where: { project.region(withID: $0) != nil }) else { return }
    perform(PackTakeFolder(selectedRegionIDs))
    if project.region(withID: firstID)?.takeFolder != nil {
      selectedRegionIDs = [firstID]
    }
  }

  /// Edit › Join Regions (⌘J): joins the selected regions on each track.
  func joinSelectedRegions() {
    let glue = GlueRegions(selectedRegionIDs)
    perform(glue, named: glue.actionName(in: project))
    selectedRegionIDs = Set(selectedRegionIDs.filter { project.region(withID: $0) != nil })
  }
}

/// What a Fade tool drag changes.
enum FadeTarget: Equatable {
  case fadeIn(Region.ID)
  case fadeOut(Region.ID)
  case crossfade(Region.ID, Region.ID)
}

/// A fade being dragged, drawn before it's applied.
struct FadePreview: Equatable {
  var regionID: Region.ID
  var fadeIn: Double?
  var fadeOut: Double?
}
