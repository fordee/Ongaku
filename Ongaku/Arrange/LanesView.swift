//
//  LanesView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI
import UniformTypeIdentifiers

/// The track lanes: backgrounds, the bar grid, regions and automation. Audio and MIDI files
/// can be dropped anywhere; audio dropped below the last track creates new tracks.
///
/// Lanes and regions are drawn in tiles (see `LaneTiles`) and every click and drag goes to
/// one interaction layer, so no SwiftUI views are built per track or per region. Only
/// automation lanes, when shown, are views, and only for the rows near the viewport.
struct LanesView: View {
  static let coordinateSpace = "lanes"

  let model: ProjectWindowModel
  /// At least this tall, so the grid fills the window when there are only a few tracks.
  var minimumHeight: CGFloat = 0

  private typealias Layout = ProjectWindowModel.Layout

  var body: some View {
    // Collapsed stacks' subtracks aren't shown, so rows count the displayed tracks.
    let tracks = model.displayedTracks
    let rowHeight = model.rowHeight
    let tracksHeight = CGFloat(tracks.count) * rowHeight
    let lanesHeight = max(tracksHeight + Layout.trailingSpace, minimumHeight)
    let rows = model.scroll.visibleRows.clamped(to: 0..<tracks.count)

    ZStack(alignment: .topLeading) {
      // Behind the tracks, and visible in the space below them.
      Theme.lanes.opacity(0.7)
        .allowsHitTesting(false)
      LaneBackgrounds(model: model, tracksHeight: tracksHeight)
      GridLines(model: model, height: lanesHeight)

      LaneTiles(model: model)
      FlexProcessingLabels(model: model)

      LaneInteractionLayer(model: model, height: lanesHeight)

      // Each track's automation in its own strip under its lane, so regions stay
      // editable above it. Aux tracks have no regions but do have automation.
      if model.isAutomationVisible {
        ForEach(rows, id: \.self) { index in
          AutomationLaneView(model: model, track: tracks[index])
            .frame(width: model.contentWidth, height: Layout.automationHeight, alignment: .topLeading)
            .offset(y: CGFloat(index) * rowHeight + Layout.trackHeight)
        }
      }

      RegionDragLayer(model: model, visibleRows: rows)
    }
    .frame(width: model.contentWidth, height: lanesHeight, alignment: .topLeading)
    .coordinateSpace(.named(LanesView.coordinateSpace))
    .dropDestination(for: URL.self) { urls, location in
      let trackIndex = Int(location.y / rowHeight)
      let trackID = tracks.indices.contains(trackIndex) ? tracks[trackIndex].id : nil
      let position = model.snap(model.position(forX: location.x))
      let midiURLs = urls.filter { url in
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .midi)) == true
      }
      let otherURLs = urls.filter { !midiURLs.contains($0) }
      Task {
        if !midiURLs.isEmpty { await model.importMIDIFiles(midiURLs, at: position) }
        if !otherURLs.isEmpty { await model.importAudio(otherURLs, at: position, onTrack: trackID) }
      }
      return true
    }
  }
}

/// The lanes' backgrounds: one rectangle for all the tracks and one for each selected
/// track, so changing the selection redraws almost nothing.
private struct LaneBackgrounds: View {
  let model: ProjectWindowModel
  let tracksHeight: CGFloat

  private typealias Layout = ProjectWindowModel.Layout

  var body: some View {
    let selection = model.selectedTrackIDs
    let selectedRows = model.displayedTracks.indices.filter { selection.contains(model.displayedTracks[$0].id) }
    let frozenRows = model.displayedTracks.indices.filter { model.displayedTracks[$0].isFrozen }
    ZStack(alignment: .topLeading) {
      Theme.lanes
        .frame(width: model.contentWidth, height: tracksHeight)
      // Frozen tracks' lanes are tinted icy, as their regions can't be edited.
      ForEach(frozenRows, id: \.self) { row in
        Theme.freeze.opacity(0.07)
          .frame(width: model.contentWidth, height: Layout.trackHeight)
          .offset(y: CGFloat(row) * model.rowHeight)
      }
      ForEach(selectedRows, id: \.self) { row in
        Theme.laneSelected
          .frame(width: model.contentWidth, height: Layout.trackHeight)
          .offset(y: CGFloat(row) * model.rowHeight)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// "Processing" on each flexed region whose render is still being made (it plays as
/// recorded until then). Drawn over the tiles rather than in them, so a render starting or
/// finishing redraws no tile; only reads the project while something is processing.
private struct FlexProcessingLabels: View {
  let model: ProjectWindowModel

  private typealias Layout = ProjectWindowModel.Layout

  var body: some View {
    let regionIDs = model.flexProcessingRegionIDs
    if !regionIDs.isEmpty {
      let tracks = model.displayedTracks
      let rowHeight = model.rowHeight
      ZStack(alignment: .topLeading) {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { row, track in
          ForEach(track.regions.filter { regionIDs.contains($0.id) }) { region in
            HStack(spacing: 4) {
              ProgressView().controlSize(.mini)
              Text("Processing…").font(Theme.font(9, weight: .semibold))
            }
            .padding(.horizontal, 5)
            .frame(height: 16)
            .foregroundStyle(Theme.text)
            .background(Capsule().fill(Theme.window.opacity(0.8)))
            .fixedSize()
            .offset(x: model.x(for: region.start) + 4, y: CGFloat(row) * rowHeight + Layout.trackHeight - 20)
          }
        }
      }
      .allowsHitTesting(false)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Processing flex edits")
    }
  }
}

/// Bar and beat lines, and the line under each track, drawn only across the render range.
private struct GridLines: View {
  let model: ProjectWindowModel
  let height: CGFloat

  var body: some View {
    let range = model.scroll.renderRange
    let timeline = model.timeline
    let width = range.upperBound - range.lowerBound
    let rows = model.scroll.visibleRows.clamped(to: 0..<model.displayedTracks.count)
    let rowHeight = model.rowHeight
    Canvas { context, size in
      GridDrawing.draw(timeline, originX: range.lowerBound, width: width, height: size.height, in: &context)
      // The line under each track.
      var separators = Path()
      for row in rows {
        separators.addRect(CGRect(x: 0, y: CGFloat(row + 1) * rowHeight - 1, width: width, height: 1))
      }
      context.fill(separators, with: .color(Theme.separator.opacity(0.7)))
    }
    .frame(width: width, height: height)
    .offset(x: range.lowerBound)
    .allowsHitTesting(false)
  }
}
