//
//  RegionView.swift
//  Ongaku
//

import AppKit
import OngakuCore
import SwiftUI

/// What's needed to turn timeline positions into points, as a plain value. Drawing code takes
/// this rather than the window model, so it doesn't read (and track) observable state for
/// every region it draws, and so views can tell cheaply whether the scale changed.
nonisolated struct TimelineScale: Equatable {
  var pointsPerQuarterNote: Double
  var tempoMap: TempoMap

  func x(for position: Tick) -> CGFloat {
    CGFloat(position.quarterNotes * pointsPerQuarterNote)
  }

  func position(forX x: CGFloat) -> Tick {
    .quarterNotes(Double(x) / pointsPerQuarterNote)
  }
}

extension ProjectWindowModel {
  var timeline: TimelineScale {
    TimelineScale(pointsPerQuarterNote: pointsPerQuarterNote, tempoMap: project.tempoMap)
  }
}

// MARK: - Tiles

/// The visible part of the tracks area, drawn as a grid of tiles, the way Logic draws its
/// tracks area. Each tile is one canvas covering a fixed stretch of the timeline and a band
/// of tracks, holding that stretch's regions. Lane backgrounds and the grid are drawn
/// underneath (see `LanesView`), so selecting a track or moving the playhead never redraws
/// a tile.
///
/// Building SwiftUI views per track (or per region) made scrolling a large song stall each
/// time new tracks came into view, and paging during playback stalled for a third of a
/// second. Tiles sit at fixed places, so scrolling only creates the tiles coming into view,
/// and a tile whose contents haven't changed is never redrawn.
struct LaneTiles: View {
  let model: ProjectWindowModel

  private typealias Layout = ProjectWindowModel.Layout
  static let tileWidth = ScrollState.chunkWidth
  static let tileRows = ScrollState.rowChunk

  var body: some View {
    let tracks = model.displayedTracks
    let rows = model.scroll.visibleRows.clamped(to: 0..<tracks.count)
    let range = model.scroll.renderRange
    let firstColumn = Int(range.lowerBound / Self.tileWidth)
    let lastColumn = max(firstColumn, Int((range.upperBound / Self.tileWidth).rounded(.up)))
    let firstBand = rows.lowerBound / Self.tileRows
    let lastBand = rows.isEmpty ? firstBand : (rows.upperBound - 1) / Self.tileRows + 1
    let context = TileContext(model: model, firstColumn: firstColumn)

    ZStack(alignment: .topLeading) {
      ForEach(firstBand..<lastBand, id: \.self) { band in
        let bandRows = band * Self.tileRows..<min((band + 1) * Self.tileRows, tracks.count)
        ForEach(firstColumn..<lastColumn, id: \.self) { column in
          context.tile(column: column, rows: bandRows)
            .equatable()
            .offset(x: CGFloat(column) * Self.tileWidth, y: CGFloat(bandRows.lowerBound) * model.rowHeight)
        }
      }
    }
    .allowsHitTesting(false)
  }
}

/// What every tile needs, read from the model once per update rather than once per tile.
@MainActor
private struct TileContext {
  let tracks: [Track]
  let timeline: TimelineScale
  let selection: Set<Region.ID>
  let trim: ProjectWindowModel.RegionTrimPreview?
  let isDragging: Bool
  let waveforms: [AudioFileReference.ID: Waveform]
  let firstColumn: Int
  /// Where looped regions stop repeating, if nothing comes after them.
  let projectEnd: Tick
  let fadePreview: FadePreview?
  let flexPreview: (regionID: Region.ID, markers: [FlexMarker])?
  let loopPreview: LoopPreview?
  let rowHeight: CGFloat

  /// A collapsed stack's subtracks, whose regions its row shows.
  let collapsedMembers: [Track.ID: [Track]]

  init(model: ProjectWindowModel, firstColumn: Int) {
    tracks = model.displayedTracks
    rowHeight = model.rowHeight
    collapsedMembers = Dictionary(uniqueKeysWithValues: model.collapsedStackIDs.map { ($0, model.project.stackMembers(of: $0)) })
    timeline = model.timeline
    selection = model.selectedRegionIDs
    trim = model.regionTrimPreview
    isDragging = model.regionDragPreview.map { !$0.isCopy } ?? false
    waveforms = model.waveforms.waveforms
    self.firstColumn = firstColumn
    projectEnd = model.project.endPosition
    fadePreview = model.fadePreview
    flexPreview = model.flexPreview
    loopPreview = model.loopPreview
  }

  func tile(column: Int, rows: Range<Int>) -> LaneTile {
    let originX = CGFloat(column) * LaneTiles.tileWidth
    let endX = originX + LaneTiles.tileWidth
    var tileWaveforms: [AudioFileReference.ID: Waveform] = [:]
    let tileRows = rows.map { index in
      var track = tracks[index]
      // A loop handle being dragged shows the repeats straight away.
      if let loopPreview, let regionIndex = track.regions.firstIndex(where: { $0.id == loopPreview.regionID }) {
        let region = track.regions[regionIndex]
        track.regions[regionIndex].isLooped = loopPreview.end > region.end
        track.regions[regionIndex].loopedLength = loopPreview.end > region.end ? loopPreview.end - region.start : nil
      }
      var items: [LaneTile.Item] = []
      // A collapsed stack's row shows where its subtracks have regions, each subtrack as a
      // thin strip in its own colour, as in Logic (only to look at: regions are edited on
      // the subtracks).
      if let members = collapsedMembers[track.id] {
        for (band, member) in members.enumerated() {
          for region in member.regions where timeline.x(for: region.end) >= originX && timeline.x(for: region.start) <= endX {
            items.append(LaneTile.Item(
              region: region, start: region.start, end: region.end, isSelected: false, isAccessible: false,
              summary: LaneTile.Summary(band: band, bandCount: members.count, color: member.color.color)))
          }
        }
      }
      for var region in track.regions {
        // A fade being dragged shows on its region straight away.
        if let fadePreview, fadePreview.regionID == region.id, case .audio(var audio) = region.content {
          audio.fadeIn = fadePreview.fadeIn ?? audio.fadeIn
          audio.fadeOut = fadePreview.fadeOut ?? audio.fadeOut
          region.content = .audio(audio)
        }
        // A flex marker being dragged shows straight away too.
        if let flexPreview, flexPreview.regionID == region.id, case .audio(var audio) = region.content {
          audio.flexMarkers = flexPreview.markers
          region.content = .audio(audio)
        }
        let isSelected = selection.contains(region.id)
        // Regions being dragged are drawn by the drag layer, at their new places (unless
        // they're being copied: then the originals stay too).
        guard !(isDragging && isSelected) else { continue }
        let (start, end) = trim?.regionID == region.id ? (trim!.start, trim!.end) : (region.start, region.end)
        let startX = timeline.x(for: start)
        guard timeline.x(for: end) >= originX, startX <= endX else { continue }
        // Each region's accessibility element belongs to the tile its start is in (or the
        // first tile, if it starts before them).
        let isAccessible = startX >= originX || column == firstColumn
        items.append(LaneTile.Item(region: region, start: start, end: end, isSelected: isSelected, isAccessible: isAccessible))
        if case .audio(let content) = region.content, let waveform = waveforms[content.fileID] {
          tileWaveforms[content.fileID] = waveform
        }
      }
      // A looped region's repeats, drawn fainter after it (they can't be clicked).
      if track.regions.contains(where: \.isLooped) {
        let originals = Set(track.regions.map { RegionPlacement(id: $0.id, start: $0.start) })
        for loop in track.playedRegions(until: projectEnd) where !originals.contains(RegionPlacement(id: loop.id, start: loop.start)) {
          guard timeline.x(for: loop.end) >= originX, timeline.x(for: loop.start) <= endX else { continue }
          items.append(LaneTile.Item(
            region: loop, start: loop.start, end: loop.end, isSelected: false, isAccessible: false, isLoopRepeat: true))
          if case .audio(let content) = loop.content, let waveform = waveforms[content.fileID] {
            tileWaveforms[content.fileID] = waveform
          }
        }
      }
      return LaneTile.Row(trackID: track.id, color: track.color.color, items: items, showsFlex: track.flexMode != nil)
    }
    return LaneTile(rows: tileRows, originX: originX, timeline: timeline, waveforms: tileWaveforms, rowHeight: rowHeight)
  }
}

/// A region at a place on the timeline: a looped region's repeats share its identifier.
private struct RegionPlacement: Hashable {
  var id: Region.ID
  var start: Tick
}

/// One tile: a stretch of the timeline across a band of tracks, drawn in a single canvas.
/// Equatable, so it's redrawn only when something it shows changes.
struct LaneTile: View, Equatable {
  nonisolated struct Item: Equatable {
    var region: Region
    var start: Tick
    var end: Tick
    var isSelected: Bool
    var isAccessible: Bool
    /// For a subtrack's region shown in its collapsed stack's row.
    var summary: Summary?
    /// A repeat of a looped region.
    var isLoopRepeat = false
  }

  /// Where a subtrack's region goes in its collapsed stack's row: one of `bandCount`
  /// strips, top to bottom.
  nonisolated struct Summary: Equatable {
    var band: Int
    var bandCount: Int
    var color: Color
  }

  nonisolated struct Row: Equatable {
    var trackID: Track.ID
    var color: Color
    var items: [Item]
    /// Flex is on for the track: its regions show their flex markers.
    var showsFlex = false
  }

  let rows: [Row]
  let originX: CGFloat
  let timeline: TimelineScale
  /// Only the waveforms this tile draws.
  let waveforms: [AudioFileReference.ID: Waveform]
  /// How far apart the rows are (taller while automation is shown).
  let rowHeight: CGFloat

  private typealias Layout = ProjectWindowModel.Layout

  nonisolated static func == (lhs: LaneTile, rhs: LaneTile) -> Bool {
    lhs.originX == rhs.originX && lhs.timeline == rhs.timeline && lhs.rows == rhs.rows
      && Set(lhs.waveforms.keys) == Set(rhs.waveforms.keys) && lhs.rowHeight == rhs.rowHeight
  }

  var body: some View {
    let width = LaneTiles.tileWidth
    let height = CGFloat(rows.count) * rowHeight
    Canvas { context, _ in
      for (index, row) in rows.enumerated() {
        var rowContext = context
        rowContext.translateBy(x: 0, y: CGFloat(index) * rowHeight)
        for item in row.items {
          if let summary = item.summary {
            let bandHeight = (Layout.trackHeight - 6) / CGFloat(max(summary.bandCount, 1))
            let rect = CGRect(
              x: timeline.x(for: item.start) - originX, y: 3 + CGFloat(summary.band) * bandHeight,
              width: max(timeline.x(for: item.end) - timeline.x(for: item.start), 2), height: max(bandHeight - 1, 1))
            rowContext.fill(Path(roundedRect: rect, cornerRadius: min(2, bandHeight / 3)), with: .color(summary.color.opacity(0.8)))
            continue
          }
          var regionContext = rowContext
          if item.isLoopRepeat {
            regionContext.opacity = 0.45
          }
          RegionDrawing.draw(
            item.region, from: item.start, to: item.end, color: row.color, isSelected: item.isSelected,
            originX: originX, visibleWidth: width, timeline: timeline, waveforms: waveforms, showsFlex: row.showsFlex,
            in: &regionContext)
        }
      }
    }
    .frame(width: width, height: height)
    // Invisible stand-ins so VoiceOver and UI tests can find each region.
    .accessibilityChildren {
      ZStack(alignment: .topLeading) {
        ForEach(Array(rows.enumerated()), id: \.element.trackID) { index, row in
          ForEach(row.items.filter(\.isAccessible), id: \.region.id) { item in
            let startX = timeline.x(for: item.start)
            Color.clear
              .frame(width: max(timeline.x(for: item.end) - startX, 3), height: Layout.trackHeight - 4)
              .offset(x: startX - originX, y: CGFloat(index) * rowHeight + 2)
              .accessibilityElement()
              .accessibilityLabel("Region \(item.region.name)")
              .accessibilityIdentifier("region")
              .accessibilityAddTraits(item.isSelected ? .isSelected : [])
          }
        }
      }
      .frame(width: width, height: height, alignment: .topLeading)
    }
  }
}

// MARK: - Interaction

/// Takes every click and drag on the tracks area, in one view rather than one per track:
/// click to select (Shift-click to add to the selection), drag a region to move it, drag
/// either edge to resize, double-click to open the Piano Roll. On an empty part of an
/// instrument lane, double-click creates a region. Other tools (see `ArrangeTool`) change
/// what a click on a region does; only the Pointer and Pencil move and resize regions.
struct LaneInteractionLayer: View {
  let model: ProjectWindowModel
  let height: CGFloat

  private enum Part: Equatable {
    case body(Region.ID)
    case leadingEdge(Region.ID)
    case trailingEdge(Region.ID)
    /// The upper half of the right edge: Logic's loop handle.
    case loopHandle(Region.ID)
    case empty

    var regionID: Region.ID? {
      switch self {
      case .body(let id), .leadingEdge(let id), .trailingEdge(let id), .loopHandle(let id): id
      case .empty: nil
      }
    }

    var isEdge: Bool {
      switch self {
      case .leadingEdge, .trailingEdge: true
      case .body, .loopHandle, .empty: false
      }
    }
  }

  /// What's under a point: a track (or none, below the last) and what part of it.
  private struct Target: Equatable {
    var row: Int?
    var part: Part
  }

  /// What the current press started on.
  @State private var pressed: Target?
  /// A flex marker being dragged (a new one, or one the press grabbed), on Flex tracks.
  @State private var flexDrag: (regionID: Region.ID, marker: FlexMarker)?
  /// What the pointer shows: resize arrows over an edge, the loop pointer over a loop handle.
  @State private var pointer = LanePointer.normal
  /// The region last under the pointer, for the context menu. A box, so moving the pointer
  /// doesn't update the view.
  @State private var hovered = HoveredRegion()
  /// The rubber band being dragged across empty lane space, selecting what it touches.
  @State private var marquee: CGRect?

  private typealias Layout = ProjectWindowModel.Layout
  private static let edgeWidth: CGFloat = 6

  var body: some View {
    Color.clear
      .frame(width: model.contentWidth, height: height)
      .contentShape(.rect)
      .pointerStyle(pointer.style)
      .onContinuousHover { phase in
        guard case .active(let location) = phase else { return }
        let target = target(at: location)
        hovered.regionID = target.part.regionID
        hovered.row = target.row
        hovered.position = model.position(forX: location.x)
        let newPointer: LanePointer
        if !model.tool.movesRegions {
          newPointer = .normal
        } else if case .loopHandle = target.part {
          newPointer = .loop
        } else {
          newPointer = target.part.isEdge ? .resize : .normal
        }
        if newPointer != pointer { pointer = newPointer }
      }
      .gesture(pressGesture)
      .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
        let target = target(at: tap.location)
        // Double-clicking a flex marker deletes it (only where they're shown: with Flex on).
        if let id = target.part.regionID, let region = region(id), let row = target.row,
          model.displayedTracks[row].flexMode != nil, isInFlexHalf(tap.location, row: row),
          let marker = model.flexMarker(in: region, near: model.position(forX: tap.location.x), tolerance: flexTolerance)
        {
          model.deleteFlexMarker(marker.id, in: id)
          return
        }
        if let id = target.part.regionID {
          model.select(id, extending: false)
          model.openEditor(for: id)
        } else if let row = target.row, model.displayedTracks[row].kind == .softwareInstrument {
          // Like clicking an empty lane with Logic's pencil tool.
          model.createMIDIRegion(on: model.displayedTracks[row].id, at: model.position(forX: tap.location.x))
        }
      })
      .overlay(alignment: .topLeading) {
        if let marquee {
          Rectangle()
            .fill(Color.accentColor.opacity(0.12))
            .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1)
            .frame(width: marquee.width, height: marquee.height)
            .offset(x: marquee.minX, y: marquee.minY)
            .allowsHitTesting(false)
        }
      }
      .contextMenu { contextMenu }
      .accessibilityHidden(true)
  }

  // MARK: Hit testing

  /// The topmost (last drawn) region under a point wins.
  private func target(at location: CGPoint) -> Target {
    let tracks = model.displayedTracks
    let row = Int((location.y / model.rowHeight).rounded(.down))
    guard location.y >= 0, tracks.indices.contains(row) else { return Target(row: nil, part: .empty) }
    let y = location.y - CGFloat(row) * model.rowHeight
    guard y >= 2, y <= Layout.trackHeight - 2 else { return Target(row: row, part: .empty) }
    // The end of a region's loops can be grabbed again to lengthen or shorten them.
    if y < Layout.trackHeight / 2 {
      for region in tracks[row].regions.reversed() {
        guard let loopEnd = region.loopEnd, abs(location.x - model.x(for: loopEnd)) <= Self.edgeWidth else { continue }
        return Target(row: row, part: .loopHandle(region.id))
      }
    }
    for region in tracks[row].regions.reversed() {
      let startX = model.x(for: region.start)
      let endX = max(model.x(for: region.end), startX + 3)
      guard location.x >= startX, location.x <= endX else { continue }
      if endX - startX > Self.edgeWidth * 3 {
        if location.x <= startX + Self.edgeWidth { return Target(row: row, part: .leadingEdge(region.id)) }
        if location.x >= endX - Self.edgeWidth {
          // Like Logic: the upper half of the right edge loops, the lower half resizes.
          if y < Layout.trackHeight / 2, region.takeFolder == nil { return Target(row: row, part: .loopHandle(region.id)) }
          return Target(row: row, part: .trailingEdge(region.id))
        }
      }
      return Target(row: row, part: .body(region.id))
    }
    return Target(row: row, part: .empty)
  }

  private func region(_ id: Region.ID) -> Region? {
    model.project.region(withID: id)
  }

  // MARK: Flex

  /// How near a click must be to a flex marker to grab it.
  private var flexTolerance: Tick {
    model.position(forX: Self.edgeWidth) - model.position(forX: 0)
  }

  /// Whether a point is in the lower half of its track's lane, where flex markers are made.
  private func isInFlexHalf(_ location: CGPoint, row: Int?) -> Bool {
    guard let row else { return false }
    return location.y - CGFloat(row) * model.rowHeight > Layout.trackHeight / 2
  }

  /// The flex marker a press in the lower half of an audio region on a Flex track drags: the
  /// one under it, or a new one where it pressed.
  private func flexMarkerToDrag(at location: CGPoint) -> (regionID: Region.ID, marker: FlexMarker)? {
    let target = target(at: location)
    guard model.tool.movesRegions, case .body(let id) = target.part, isInFlexHalf(location, row: target.row),
      let row = target.row, model.displayedTracks[row].flexMode != nil,
      let region = region(id), case .audio(let audio) = region.content
    else { return nil }
    let position = model.position(forX: location.x)
    if let existing = model.flexMarker(in: region, near: position, tolerance: flexTolerance) {
      return (id, existing)
    }
    let duration = model.project.duration(of: region)
    let map = FlexMap(markers: audio.flexMarkers, duration: duration, sourceDuration: duration * audio.stretch)
    let seconds = model.regionSeconds(region, at: position)
    return (id, FlexMarker(source: map.sourceTime(atTarget: seconds), target: seconds))
  }

  // MARK: Gestures

  private var pressGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if pressed == nil {
          pressed = target(at: value.startLocation)
          flexDrag = flexMarkerToDrag(at: value.startLocation)
        }
        let isDrag = abs(value.translation.width) > 3 || abs(value.translation.height) > 3
        if let flexDrag {
          // Dragging in the lower half of a flexed region moves audio in time.
          if isDrag, let region = region(flexDrag.regionID), case .audio(let audio) = region.content {
            var moved = flexDrag.marker
            moved.target = model.regionSeconds(region, at: model.snap(model.position(forX: value.location.x)))
            let markers = audio.flexMarkers.filter { $0.id != moved.id } + [moved]
            model.flexPreview = (flexDrag.regionID, markers)
          }
          return
        }
        if model.tool == .fade {
          if isDrag, let pressed, let id = pressed.part.regionID, let fade = fadeTarget(id, startX: value.startLocation.x) {
            let preview = model.fadeChange(
              fade, from: model.position(forX: value.startLocation.x), to: model.position(forX: value.location.x))
            if model.fadePreview != preview { model.fadePreview = preview }
          }
          return
        }
        guard isDrag, let pressed, model.tool.movesRegions else { return }
        switch pressed.part {
        case .body(let id):
          if !model.selectedRegionIDs.contains(id) {
            model.select(id, extending: false)
          }
          if let region = region(id) {
            let preview = movePreview(for: region, translation: value.translation)
            if model.regionDragPreview != preview { model.regionDragPreview = preview }
            // Option-dragging copies: the copy pointer shows it before the drop.
            let newPointer: LanePointer = preview.isCopy ? .copy : .normal
            if newPointer != pointer {
              pointer = newPointer
              newPointer.set()
            }
          }
        case .leadingEdge(let id), .trailingEdge(let id):
          let preview = trimmedRange(id, leading: pressed.part == .leadingEdge(id), translation: value.translation.width)
          if model.regionTrimPreview != preview { model.regionTrimPreview = preview }
        case .loopHandle(let id):
          if let end = model.loopEnd(for: id, draggedTo: model.position(forX: value.location.x)) {
            let preview = LoopPreview(regionID: id, end: end)
            if model.loopPreview != preview { model.loopPreview = preview }
          }
        case .empty:
          // Dragging across empty space with the Pointer draws a rubber band.
          if isDrag, model.tool == .pointer {
            marquee = CGRect(
              x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
              width: abs(value.translation.width), height: abs(value.translation.height))
          }
        }
      }
      .onEnded { value in
        defer {
          pressed = nil
          flexDrag = nil
          model.regionTrimPreview = nil
          model.flexPreview = nil
          model.loopPreview = nil
          if pointer == .copy {
            pointer = .normal
            pointer.set()
          }
        }
        let isDrag = abs(value.translation.width) > 3 || abs(value.translation.height) > 3
        if let flexDrag, isDrag {
          model.finishFlexDrag(flexDrag.marker, in: flexDrag.regionID, to: model.position(forX: value.location.x))
          return
        }
        let target = pressed ?? target(at: value.startLocation)
        // A click (no real movement) on a region uses the tool on it; the Pointer and Pencil
        // select it, wherever on the region it was.
        if !isDrag, let id = target.part.regionID {
          model.beginEditing(in: .tracks)
          if !model.applyTool(to: id, at: model.position(forX: value.location.x)) {
            model.select(id, extending: NSEvent.modifierFlags.contains(.shift))
          }
          return
        }
        if model.tool == .fade, let id = target.part.regionID {
          model.fadePreview = nil
          if let fade = fadeTarget(id, startX: value.startLocation.x) {
            model.finishFade(fade, from: model.position(forX: value.startLocation.x), to: model.position(forX: value.location.x))
          }
          return
        }
        guard model.tool.movesRegions || target.part == .empty else { return }
        switch target.part {
        case .body(let id):
          let preview = region(id).map { movePreview(for: $0, translation: value.translation) }
          model.regionDragPreview = nil
          if let preview, preview.offset != .zero || preview.trackOffset != 0 {
            // Option-dragging copies, as in Logic.
            if NSEvent.modifierFlags.contains(.option) {
              model.copySelection(by: preview.offset, trackOffset: preview.trackOffset)
            } else {
              model.moveSelection(by: preview.offset, trackOffset: preview.trackOffset)
            }
          }
        case .leadingEdge(let id), .trailingEdge(let id):
          if let trim = model.regionTrimPreview, trim.regionID == id, let region = region(id),
            trim.start != region.start || trim.end != region.end
          {
            model.perform(TrimRegion(id, start: trim.start, length: trim.end - trim.start))
          }
        case .loopHandle:
          if let preview = model.loopPreview {
            model.finishLoopDrag(preview)
          }
        case .empty:
          if let band = marquee {
            marquee = nil
            model.beginEditing(in: .tracks)
            let rows = Int(max(0, band.minY) / model.rowHeight)...Int(max(0, band.maxY) / model.rowHeight)
            model.selectRegions(
              inRows: rows, over: model.position(forX: band.minX)..<model.position(forX: band.maxX),
              extending: NSEvent.modifierFlags.contains(.shift))
            return
          }
          guard !isDrag else { return }
          model.beginEditing(in: .tracks)
          // Clicking a lane selects its track; clicking below the tracks only deselects.
          if let row = target.row {
            let track = model.displayedTracks[row]
            model.selectedTrackID = track.id
            // The Pencil adds a region where it clicks on an instrument lane.
            if model.tool == .pencil, track.kind == .softwareInstrument {
              model.createMIDIRegion(on: track.id, at: model.position(forX: value.location.x))
              return
            }
          }
          model.selectedRegionIDs = []
        }
      }
  }

  /// What a Fade tool drag starting at `startX` on a region fades.
  private func fadeTarget(_ id: Region.ID, startX: CGFloat) -> FadeTarget? {
    let tolerance = model.position(forX: Self.edgeWidth * 2) - model.position(forX: 0)
    return model.fadeTarget(for: id, at: model.position(forX: startX), borderTolerance: tolerance)
  }

  private func movePreview(for region: Region, translation: CGSize) -> ProjectWindowModel.RegionDragPreview {
    let proposedStart = max(.zero, region.start + model.position(forX: translation.width))
    let offset = model.snap(proposedStart) - region.start
    let trackOffset = Int((translation.height / model.rowHeight).rounded())
    return .init(offset: offset, trackOffset: trackOffset, isCopy: NSEvent.modifierFlags.contains(.option))
  }

  private func trimmedRange(_ id: Region.ID, leading: Bool, translation: CGFloat) -> ProjectWindowModel.RegionTrimPreview? {
    guard let region = region(id) else { return nil }
    let delta = model.position(forX: translation)
    if leading {
      let start = min(max(.zero, model.snap(region.start + delta)), region.end - Tick(1))
      return .init(regionID: id, start: start, end: region.end)
    } else {
      let end = max(model.snap(region.end + delta), region.start + Tick(1))
      return .init(regionID: id, start: region.start, end: end)
    }
  }

  // MARK: Context menu

  /// The region under the pointer when the menu opened (selected, if it wasn't, so the
  /// edits act on it), then what's under the pointer in the lane: its track and time.
  @ViewBuilder private var contextMenu: some View {
    Button("Cut") { actOnHoveredRegion { model.cutSelection() } }
    Button("Copy") { actOnHoveredRegion { model.copySelection() } }
    Button("Paste") { pasteAtPointer() }
      .disabled(!model.canPasteRegions)
    Menu("Repeat") {
      ForEach([1, 2, 3, 4, 8], id: \.self) { times in
        Button(times == 1 ? "Once" : "\(times) Times") { actOnHoveredRegion { model.repeatSelection(times: times) } }
      }
    }
    Button("Delete", role: .destructive) { actOnHoveredRegion { model.deleteSelection() } }
    Divider()
    Button("Split at Playhead") { actOnHoveredRegion { model.splitAtPlayhead() } }
    Button("Join Selected Regions") { model.joinSelectedRegions() }
      .disabled(model.selectedRegionIDs.count < 2)
    Button("Mute or Unmute") {
      actOnHoveredRegion {
        let regions = model.project.tracks.flatMap(\.regions).filter { model.selectedRegionIDs.contains($0.id) }
        let mute = regions.contains { !$0.isMuted }
        model.perform(CompositeCommand(mute ? "Mute Regions" : "Unmute Regions",
          commands: regions.map { SetRegionMuted($0.id, isMuted: mute) }))
      }
    }
    Button("Convert Loops to Regions") { actOnHoveredRegion { model.convertLoopsToRegions() } }
    Button("Loop or Unloop") {
      actOnHoveredRegion {
        let regions = model.project.tracks.flatMap(\.regions).filter { model.selectedRegionIDs.contains($0.id) }
        let loop = regions.contains { !$0.isLooped }
        model.perform(SetRegionParameter(.looped(loop), for: model.selectedRegionIDs))
      }
    }
    Divider()
    Button("Select All Following") {
      guard let region = hoveredRegion() else { return }
      model.selectAllFollowing(region.id)
    }
    Button("Select All on Track") {
      guard let row = hovered.row, model.displayedTracks.indices.contains(row) else { return }
      model.selectAllRegions(onTrack: model.displayedTracks[row].id)
    }
    Divider()
    Button("Open in Editor") {
      guard let region = hoveredRegion() else { return }
      model.openEditor(for: region.id)
    }
    Button("New MIDI Region") {
      guard let row = hovered.row, model.displayedTracks.indices.contains(row),
        model.displayedTracks[row].kind == .softwareInstrument
      else { return }
      model.createMIDIRegion(on: model.displayedTracks[row].id, at: hovered.position)
    }
    Button("New Pattern Region") {
      guard let row = hovered.row, model.displayedTracks.indices.contains(row),
        model.displayedTracks[row].kind == .softwareInstrument
      else { return }
      model.createPatternRegion(on: model.displayedTracks[row].id, at: hovered.position)
    }
    // Only on drum tracks, so the drummer doesn't play its kit on a glockenspiel; New
    // Drummer Track makes one.
    let hoveredDrumTrack = hovered.row.flatMap { row in
      model.displayedTracks.indices.contains(row) && model.playsDrums(model.displayedTracks[row]) ? model.displayedTracks[row] : nil
    }
    Button(hoveredDrumTrack == nil ? "New Drummer Region (Drum Tracks Only)" : "New Drummer Region") {
      guard let track = hoveredDrumTrack else { return }
      model.createDrummerRegion(on: track.id, at: hovered.position)
    }
    .disabled(hoveredDrumTrack == nil)
    // Players go on instrument tracks that aren't drums; they follow the Chord track.
    let hoveredPlayerTrack = hovered.row.flatMap { row in
      model.displayedTracks.indices.contains(row) && model.displayedTracks[row].kind == .softwareInstrument
        && !model.playsDrums(model.displayedTracks[row]) ? model.displayedTracks[row] : nil
    }
    Button("New Player Region") {
      guard let track = hoveredPlayerTrack else { return }
      model.createPlayerRegion(on: track.id, at: hovered.position)
    }
    .disabled(hoveredPlayerTrack == nil)
    Button("Detect Chords") {
      guard let region = hoveredRegion() else { return }
      model.detectChords(from: region.id)
    }
    .disabled(!canDetectChords(in: hoveredRegion()))
    // The same label as the Step Sequencer's, Drummer's and Player's own buttons.
    Button("Convert to MIDI Region") {
      actOnHoveredRegion {
        let generated = model.selectedRegionIDs.filter {
          let region = model.project.region(withID: $0)
          return region?.pattern != nil || region?.drummer != nil || region?.player != nil
        }
        if !generated.isEmpty { model.perform(ConvertPatternToNotes(generated)) }
      }
    }
    .disabled(hoveredRegion().map { $0.pattern == nil && $0.drummer == nil && $0.player == nil } ?? true)
    Menu("Take Folder") {
      Button("Pack Take Folder") { actOnHoveredRegion { model.packTakeFolder() } }
      Button("Flatten Take Folder") {
        guard let region = hoveredRegion(), region.takeFolder != nil else { return }
        model.perform(FlattenTakeFolder(region.id))
      }
    }
    Menu("Section Between Locators") {
      Button("Cut Section") { model.cutSection() }
      Button("Insert Silence") { model.insertSilence() }
      Button("Repeat Section") { model.repeatSection() }
    }
    .disabled(model.locatorRange == nil)
  }

  /// Chords can be found in a MIDI region of notes (not drums, not a player's own part).
  private func canDetectChords(in region: Region?) -> Bool {
    region.map(model.canDetectChords(in:)) ?? false
  }

  /// Runs an edit on the selection, first selecting the region under the pointer if it
  /// isn't already part of it (as right-clicking in Logic does).
  private func actOnHoveredRegion(_ edit: () -> Void) {
    if let region = hoveredRegion(), !model.selectedRegionIDs.contains(region.id) {
      model.select(region.id, extending: false)
    }
    guard !model.selectedRegionIDs.isEmpty else { return }
    edit()
  }

  /// Pastes where the pointer was: on its track, at its time (snapped).
  private func pasteAtPointer() {
    guard let row = hovered.row, model.displayedTracks.indices.contains(row) else {
      model.paste()
      return
    }
    model.paste(at: model.snap(hovered.position), onTrack: model.displayedTracks[row].id)
  }

  private func hoveredRegion() -> Region? {
    hovered.regionID.flatMap(region)
  }
}

/// Where the pointer last was over the lanes. A plain reference so updating it doesn't redraw.
final class HoveredRegion {
  var regionID: Region.ID?
  /// The track row and the time under the pointer, for pasting and adding where it is.
  var row: Int?
  var position: Tick = .zero
}

// MARK: - Dragging

/// The regions being dragged, drawn at their new places above every lane (a region dragged
/// to another track has to be drawn outside its own lane).
struct RegionDragLayer: View {
  let model: ProjectWindowModel
  let visibleRows: Range<Int>

  private typealias Layout = ProjectWindowModel.Layout

  var body: some View {
    if let preview = model.regionDragPreview {
      let renderRange = model.scroll.renderRange
      let width = renderRange.upperBound - renderRange.lowerBound
      let tracks = model.displayedTracks
      let selection = model.selectedRegionIDs
      let waveforms = model.waveforms.waveforms
      let timeline = model.timeline
      let rowHeight = model.rowHeight
      Canvas { context, _ in
        for (index, track) in tracks.enumerated() {
          let row = index + preview.trackOffset
          guard visibleRows.contains(row) || visibleRows.contains(index) else { continue }
          for region in track.regions where selection.contains(region.id) {
            var rowContext = context
            rowContext.translateBy(x: 0, y: CGFloat(row) * rowHeight)
            RegionDrawing.draw(
              region, from: region.start + preview.offset, to: region.end + preview.offset, color: track.color.color,
              isSelected: true, originX: renderRange.lowerBound, visibleWidth: width, timeline: timeline,
              waveforms: waveforms, contentOffset: preview.offset, in: &rowContext)
          }
        }
      }
      .frame(width: width, height: CGFloat(tracks.count) * rowHeight)
      .offset(x: renderRange.lowerBound)
      .allowsHitTesting(false)
    }
  }
}

// MARK: - Drawing

/// Bar and beat lines.
@MainActor
enum GridDrawing {
  /// Draws the lines between `originX` and `originX + width` (timeline x), with the
  /// context's left edge at `originX`.
  static func draw(_ timeline: TimelineScale, originX: CGFloat, width: CGFloat, height: CGFloat, in context: inout GraphicsContext) {
    let tempoMap = timeline.tempoMap
    let lastPosition = timeline.position(forX: originX + width)
    var bars = Path()
    var beats = Path()
    var offBeats = Path()
    var barIndex = max(tempoMap.bar(containing: timeline.position(forX: originX)).index, 0)
    var barStart = tempoMap.tickPosition(ofBarIndex: barIndex)
    while barStart <= lastPosition {
      bars.addRect(CGRect(x: timeline.x(for: barStart) - originX, y: 0, width: 1, height: height))
      let signature = tempoMap.timeSignature(atBarIndex: barIndex)
      // Lines on the felt beats (dotted quarters in 6/8 and 12/8), and on every beat of a
      // compound meter once there's room.
      let beatWidth = signature.ticksPerBeat.quarterNotes * timeline.pointsPerQuarterNote
      let pulseBeats = signature.isCompound ? 3 : 1
      for beat in 1..<signature.beatsPerBar where beatWidth * Double(pulseBeats) >= 12 {
        let position = barStart + signature.ticksPerBeat * Int64(beat)
        let rect = CGRect(x: timeline.x(for: position) - originX, y: 0, width: 1, height: height)
        if beat % pulseBeats == 0 {
          beats.addRect(rect)
        } else if beatWidth >= 12 {
          offBeats.addRect(rect)
        }
      }
      barIndex += 1
      barStart = tempoMap.tickPosition(ofBarIndex: barIndex)
    }
    context.fill(offBeats, with: .color(Theme.beatLine.opacity(0.5)))
    context.fill(beats, with: .color(Theme.beatLine))
    context.fill(bars, with: .color(Theme.barLine))
  }
}

/// Draws a region: its body, title bar, contents (waveform or notes) and outline, in Logic's
/// style. Contents are only drawn across the visible width.
@MainActor
enum RegionDrawing {
  private typealias Layout = ProjectWindowModel.Layout
  static let headerHeight: CGFloat = 15

  /// - Parameters:
  ///   - start, end: Where to draw the region (a trim or drag preview may differ from it).
  ///   - originX: The timeline x at the canvas's left edge.
  ///   - contentOffset: How far a dragged region has moved, so its contents move with it.
  static func draw(
    _ region: Region, from start: Tick, to end: Tick, color trackColor: Color, isSelected: Bool,
    originX: CGFloat, visibleWidth: CGFloat, timeline: TimelineScale, waveforms: [AudioFileReference.ID: Waveform],
    contentOffset: Tick = .zero, showsFlex: Bool = false, in context: inout GraphicsContext
  ) {
    let x = timeline.x(for: start) - originX
    let width = max(timeline.x(for: end) - timeline.x(for: start), 3)
    let rect = CGRect(x: x, y: 2, width: width, height: Layout.trackHeight - 4)
    guard rect.maxX >= 0, rect.minX <= visibleWidth else { return }
    // Muted regions turn grey, as in Logic.
    let color = region.isMuted ? TrackColor.gray.color.opacity(0.6) : trackColor
    let shape = Path(roundedRect: rect, cornerRadius: 3)

    context.fill(shape, with: .color(Theme.lanes))
    context.fill(shape, with: .color(color.opacity(isSelected ? 0.82 : 0.6)))

    var inside = context
    inside.clip(to: shape)
    let header = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: headerHeight)
    inside.fill(Path(header), with: .color(isSelected ? color.mix(with: .white, by: 0.25) : color))

    // The name, clipped to the title bar. It's drawn at the region's start even when that's
    // outside this canvas, so a name crossing from one tile into the next lines up.
    if rect.minX + 5 <= visibleWidth {
      var title = inside
      title.clip(to: Path(header))
      // A take folder says how many takes it holds, like Logic's folder badge.
      let name = region.takeFolder.map { "\(region.name)  ·  \($0.takes.count) takes" } ?? region.name
      title.draw(
        Text(name).font(Theme.font(10, weight: .semibold)).foregroundStyle(Color.black.opacity(0.82)),
        at: CGPoint(x: rect.minX + 5, y: header.midY), anchor: .leading)
    }

    let body = CGRect(x: rect.minX, y: header.maxY, width: rect.width, height: rect.height - headerHeight)
    let visibleBody = body.intersection(CGRect(x: 0, y: body.minY, width: visibleWidth, height: body.height))
    if !visibleBody.isNull, visibleBody.width > 0 {
      var contents = inside
      contents.clip(to: Path(visibleBody))
      let regionX = timeline.x(for: region.start + contentOffset) - originX
      switch region.content {
      case .audio(let content):
        if let waveform = waveforms[content.fileID] {
          drawWaveform(waveform, content: content, region: region, in: visibleBody, regionX: regionX, timeline: timeline, context: &contents)
        }
        drawFades(content, from: start, to: end, body: body, originX: originX, timeline: timeline, context: &inside)
        if showsFlex {
          drawFlexMarkers(content, from: start, body: body, originX: originX, timeline: timeline, context: &inside)
        }
      case .midi(let sequence):
        drawNotes(sequence, region: region, body: body, regionX: regionX, visible: visibleBody, timeline: timeline, context: &contents)
      }
    }

    context.stroke(
      Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 3),
      with: .color(isSelected ? Color.white.opacity(0.95) : Color.black.opacity(0.45)), lineWidth: isSelected ? 1.5 : 1)
  }

  private static func drawWaveform(
    _ waveform: Waveform, content: AudioRegionContent, region: Region, in visible: CGRect,
    regionX: CGFloat, timeline: TimelineScale, context: inout GraphicsContext
  ) {
    let tempoMap = timeline.tempoMap
    let pointsPerQuarterNote = timeline.pointsPerQuarterNote
    let regionStart = region.start
    let startSeconds = tempoMap.seconds(at: regionStart)
    func frame(atX x: CGFloat) -> Int64 {
      let position = regionStart + .quarterNotes(Double(x - regionX) / pointsPerQuarterNote)
      // A stretched region plays `stretch` seconds of the recording per second.
      let seconds = (tempoMap.seconds(at: position) - startSeconds) * content.stretch
      return content.fileStartFrame + Int64((seconds * waveform.sampleRate).rounded())
    }
    // The tempo conversion is exact every 32 points and interpolated in between: tempo
    // can't change audibly within a few pixels, and this keeps drawing cheap.
    let step: CGFloat = 32
    var anchorX = visible.minX
    var anchorFrame = frame(atX: anchorX)
    var nextAnchorFrame = frame(atX: anchorX + step)
    func interpolatedFrame(atX x: CGFloat) -> Int64 {
      while x > anchorX + step {
        anchorX += step
        anchorFrame = nextAnchorFrame
        nextAnchorFrame = frame(atX: anchorX + step)
      }
      let fraction = Double((x - anchorX) / step)
      return anchorFrame + Int64((Double(nextAnchorFrame - anchorFrame) * fraction).rounded())
    }
    let middle = visible.midY
    let halfHeight = visible.height / 2
    var path = Path()
    var column = visible.minX
    var previousFrame = anchorFrame
    while column < visible.maxX {
      let nextFrame = interpolatedFrame(atX: column + 1)
      let peak = CGFloat(waveform.peak(fromFrame: previousFrame, toFrame: nextFrame))
      let height = max(0.5, peak * halfHeight)
      path.addRect(CGRect(x: column, y: middle - height, width: 1, height: height * 2))
      previousFrame = nextFrame
      column += 1
    }
    // Logic draws region contents in dark ink on the region's colour.
    context.fill(path, with: .color(.black.opacity(0.55)))
  }

  /// Logic's fade curves: the faded part of the region darkened, under a line from silence
  /// to full level.
  private static func drawFades(
    _ content: AudioRegionContent, from start: Tick, to end: Tick, body: CGRect, originX: CGFloat, timeline: TimelineScale,
    context: inout GraphicsContext
  ) {
    guard content.fadeIn > 0 || content.fadeOut > 0 else { return }
    let tempoMap = timeline.tempoMap
    var shade = Path()
    var lines = Path()
    if content.fadeIn > 0 {
      let fadeEnd = tempoMap.tickPosition(atSeconds: tempoMap.seconds(at: start) + content.fadeIn)
      let x = min(timeline.x(for: fadeEnd) - originX, body.maxX)
      shade.addLines([CGPoint(x: body.minX, y: body.minY), CGPoint(x: x, y: body.minY), CGPoint(x: body.minX, y: body.maxY)])
      shade.closeSubpath()
      lines.move(to: CGPoint(x: body.minX, y: body.maxY))
      lines.addLine(to: CGPoint(x: x, y: body.minY))
    }
    if content.fadeOut > 0 {
      let fadeStart = tempoMap.tickPosition(atSeconds: tempoMap.seconds(at: end) - content.fadeOut)
      let x = max(timeline.x(for: fadeStart) - originX, body.minX)
      shade.addLines([CGPoint(x: x, y: body.minY), CGPoint(x: body.maxX, y: body.minY), CGPoint(x: body.maxX, y: body.maxY)])
      shade.closeSubpath()
      lines.move(to: CGPoint(x: x, y: body.minY))
      lines.addLine(to: CGPoint(x: body.maxX, y: body.maxY))
    }
    context.fill(shade, with: .color(.black.opacity(0.35)))
    context.stroke(lines, with: .color(.white.opacity(0.85)), lineWidth: 1)
  }

  /// Flex markers: a line where each one plays, with a handle in the lower half (where
  /// they're dragged).
  private static func drawFlexMarkers(
    _ content: AudioRegionContent, from start: Tick, body: CGRect, originX: CGFloat, timeline: TimelineScale,
    context: inout GraphicsContext
  ) {
    guard !content.flexMarkers.isEmpty else { return }
    let tempoMap = timeline.tempoMap
    let startSeconds = tempoMap.seconds(at: start)
    var lines = Path()
    var handles = Path()
    for marker in content.flexMarkers {
      let x = timeline.x(for: tempoMap.tickPosition(atSeconds: startSeconds + marker.target)) - originX
      lines.addRect(CGRect(x: x - 0.5, y: body.minY, width: 1, height: body.height))
      handles.addRoundedRect(in: CGRect(x: x - 3, y: body.maxY - 10, width: 6, height: 8), cornerSize: CGSize(width: 1.5, height: 1.5))
    }
    context.fill(lines, with: .color(Theme.solo.opacity(0.9)))
    context.fill(handles, with: .color(Theme.solo))
  }

  private static func drawNotes(
    _ sequence: MIDISequence, region: Region, body: CGRect, regionX: CGFloat, visible: CGRect,
    timeline: TimelineScale, context: inout GraphicsContext
  ) {
    let pointsPerQuarterNote = timeline.pointsPerQuarterNote
    // Show at least an octave so a few notes draw as thin lines rather than tall blocks.
    var lowestPitch = 127
    var highestPitch = 0
    for note in sequence.notes {
      lowestPitch = min(lowestPitch, note.pitch)
      highestPitch = max(highestPitch, note.pitch)
    }
    if sequence.notes.isEmpty { (lowestPitch, highestPitch) = (60, 60) }
    let middle = (lowestPitch + highestPitch) / 2
    let lowest = min(lowestPitch - 2, middle - 6)
    let highest = max(highestPitch + 2, middle + 6)
    let rowHeight = body.height / CGFloat(max(highest - lowest, 1))
    var path = Path()
    for note in sequence.notes where note.start < region.length && note.end > .zero {
      let x = regionX + CGFloat(note.start.quarterNotes * pointsPerQuarterNote)
      let width = max(CGFloat(note.length.quarterNotes * pointsPerQuarterNote), 1)
      guard x + width >= visible.minX, x <= visible.maxX else { continue }
      let y = body.minY + CGFloat(highest - note.pitch) * rowHeight
      path.addRect(CGRect(x: x, y: y, width: width, height: max(rowHeight, 1.5)))
    }
    context.fill(path, with: .color(.black.opacity(0.6)))
  }
}

#Preview("Flex markers") {
  let file = AudioFileReference(fileName: "Drums.caf", sampleRate: 48_000, channelCount: 2, frameCount: 480_000)
  let region = Region(
    name: "Drums", start: .zero, length: .quarterNotes(16),
    content: .audio(AudioRegionContent(fileID: file.id, flexMarkers: [
      FlexMarker(source: 1, target: 1.1), FlexMarker(source: 3, target: 2.9), FlexMarker(source: 5.5, target: 5.5),
    ])))
  let track = Track(name: "Drums", kind: .audio, regions: [region], flexMode: .slicing)
  let model = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [track], audioFiles: [file])))
  return ArrangeView(model: model).frame(width: 900, height: 200)
}

/// The pointer over the lanes.
private enum LanePointer: Equatable {
  case normal, resize, loop
  /// While Option-dragging regions, which copies them.
  case copy

  var style: PointerStyle? {
    switch self {
    case .normal: .default
    case .resize: .frameResize(position: .trailing)
    // Logic's loop pointer is a circular arrow.
    case .loop: .image(Image(systemName: "arrow.trianglehead.clockwise"), hotSpot: .center)
    case .copy: Self.copyStyle
    }
  }

  /// The system's copy pointer (an arrow with a plus), as a pointer style.
  private static var copyStyle: PointerStyle {
    let cursor = NSCursor.dragCopy
    let size = cursor.image.size
    return .image(Image(nsImage: cursor.image), hotSpot: UnitPoint(x: cursor.hotSpot.x / size.width, y: cursor.hotSpot.y / size.height))
  }

  /// Shows the pointer straight away: pointer styles may only update once the mouse is up.
  func set() {
    switch self {
    case .copy: NSCursor.dragCopy.set()
    case .normal, .resize, .loop: NSCursor.arrow.set()
    }
  }
}
