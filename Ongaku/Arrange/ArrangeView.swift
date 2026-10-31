//
//  ArrangeView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// Logic's main window area: the ruler across the top, track headers down the left and the
/// lanes in between, all in one scroll view.
///
/// The ruler, headers and the corner between them are pinned with `visualEffect` offsets,
/// which are applied at render time and so stay in place without lagging behind scrolling.
struct ArrangeView: View {
  let model: ProjectWindowModel

  @State private var scrollPosition = ScrollPosition()
  /// The visible height, so the lanes fill the window when there are only a few tracks.
  /// Measured from the scroll view's frame rather than its scroll geometry: sizing content
  /// from scroll geometry would change that geometry again in the same frame.
  @State private var viewportHeight: CGFloat = 0

  private typealias Layout = ProjectWindowModel.Layout

  var body: some View {
    let tracksHeight = CGFloat(model.displayedTracks.count) * model.rowHeight
    let topHeight = model.topHeight
    let minimumLanesHeight = max(0, viewportHeight - topHeight)
    let lanesHeight = max(tracksHeight + Layout.trailingSpace, minimumLanesHeight)
    let contentSize = CGSize(
      width: model.headerWidth + model.contentWidth,
      height: topHeight + lanesHeight)

    ScrollView([.horizontal, .vertical]) {
      ZStack(alignment: .topLeading) {
        LanesView(model: model, minimumHeight: minimumLanesHeight)
          .offset(x: model.headerWidth, y: topHeight)

        if model.isGlobalTracksVisible {
          // Pinned like the ruler, with padding (rather than an offset) to sit under it.
          GlobalTrackLanes(model: model)
            .padding(.top, Layout.rulerHeight)
            .offset(x: model.headerWidth)
            .visualEffect { content, geometry in
              content.offset(y: -geometry.frame(in: .scrollView).minY)
            }
        }

        RulerView(model: model)
          .offset(x: model.headerWidth)
          .visualEffect { content, geometry in
            content.offset(y: -geometry.frame(in: .scrollView).minY)
          }

        TrackHeadersColumn(model: model, height: lanesHeight)
          .offset(y: topHeight)
          .visualEffect { content, geometry in
            content.offset(x: -geometry.frame(in: .scrollView).minX)
          }

        CornerView(model: model)
          .visualEffect { content, geometry in
            let frame = geometry.frame(in: .scrollView)
            return content.offset(x: -frame.minX, y: -frame.minY)
          }
      }
      .frame(width: contentSize.width, height: contentSize.height, alignment: .topLeading)
    }
    .scrollPosition($scrollPosition)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.height
    } action: { height in
      viewportHeight = height
    }
    .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
      ScrollMetrics(offset: geometry.contentOffset, viewportSize: geometry.containerSize)
    } action: { _, metrics in
      model.scroll.update(offset: metrics.offset, viewportSize: metrics.viewportSize)
    }
    .background {
      PlayheadFollower(model: model, scrollPosition: $scrollPosition)
    }
    // The playhead is drawn above the scroll view rather than inside it, so moving it 30
    // times a second during playback doesn't touch the tracks.
    .overlay(alignment: .topLeading) {
      PlayheadOverlay(model: model)
    }
    // The Tool menu that T opens, under the tool button. Drawn in the window (not a popover)
    // so the next key press still reaches the window's key commands.
    .overlay(alignment: .topLeading) {
      if model.isShowingToolMenu, !model.pianoRoll.isToolMenuForPianoRoll {
        ToolMenuPanel(model: model)
          .offset(x: max(8, model.headerWidth - 196), y: topHeight + 2)
      }
    }
    .modifier(RenameModifier(model: model))
    .simultaneousGesture(TapGesture().onEnded { model.beginEditing(in: .tracks) })
    .onHover { model.isPointerOverTracks = $0 }
  }
}

private struct ScrollMetrics: Equatable {
  var offset: CGPoint
  var viewportSize: CGSize
}

/// The top-left corner above the track headers: adds tracks, as Logic's + button does, and
/// names the global tracks when they're shown.
private struct CornerView: View {
  let model: ProjectWindowModel

  var body: some View {
    VStack(spacing: 0) {
      topRow
      if model.isGlobalTracksVisible {
        GlobalTrackHeaders(model: model)
      }
    }
    .frame(width: model.headerWidth, height: model.topHeight, alignment: .top)
    .background(Theme.ruler)
    .overlay(alignment: .trailing) {
      Rectangle().fill(Theme.separator).frame(width: 1)
    }
    .overlay(alignment: .trailing) {
      HeaderResizeHandle(model: model)
        .accessibilityHidden(true)
    }
  }

  private var topRow: some View {
    HStack(spacing: 6) {
      Menu {
        Button("Audio") { model.addTrack(.audio) }
        Button("Software Instrument") { model.addTrack(.softwareInstrument) }
        Button("Aux") { model.addTrack(.aux) }
        Divider()
        Button("Drummer") { model.addDrummerTrack() }
        Button("Drummer (Drum Machine)") { model.addDrummerTrack(style: .electronic, kit: .drumMachine) }
        Button("Bass Player") { model.addPlayerTrack(.bass) }
        Button("Keyboard Player") { model.addPlayerTrack(.keys) }
      } label: {
        Image(systemName: "plus")
          .font(Theme.font(12, weight: .semibold))
          .foregroundStyle(Theme.text)
          .frame(width: 24, height: 20)
          .background(Theme.raised, in: .rect(cornerRadius: 4))
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("New Track")
      .accessibilityLabel("New Track")
      Text("Tracks")
        .font(Theme.font(11, weight: .semibold))
        .foregroundStyle(Theme.secondaryText)
      Spacer()
      SnapButton()
      ToolButton(model: model)
    }
    .padding(.horizontal, 8)
    .frame(height: ProjectWindowModel.Layout.rulerHeight)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Theme.separator).frame(height: 1)
    }
  }
}

/// Chooses what regions snap to, like the Snap menu above Logic's tracks. The same setting
/// as Settings › General. Lit while snapping is on.
private struct SnapButton: View {
  @AppStorage(AppSettings.snapModeKey) private var snapMode = AppSettings.SnapMode.automatic

  var body: some View {
    Menu {
      Picker("Snap", selection: $snapMode) {
        ForEach(AppSettings.SnapMode.allCases, id: \.self) { Text($0.title).tag($0) }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      Image(systemName: "squareshape.split.3x3")
        .font(Theme.font(11, weight: .semibold))
        .foregroundStyle(snapMode == .off ? Theme.secondaryText : Theme.text)
        .frame(width: 24, height: 20)
        .background(Theme.raised, in: .rect(cornerRadius: 4))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Snap: \(snapMode.title). Press Control while dragging to move freely.")
    .accessibilityLabel("Snap")
    .accessibilityValue(snapMode.title)
  }
}

/// Chooses the tool for the tracks area, like the Tool menu above Logic's tracks. Shows the
/// current tool's icon.
private struct ToolButton: View {
  let model: ProjectWindowModel

  var body: some View {
    Menu {
      Picker("Tool", selection: Binding(get: { model.tool }, set: { model.tool = $0 })) {
        ForEach(ArrangeTool.allCases) { tool in
          Label(tool.name, systemImage: tool.symbolName).tag(tool)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      Image(systemName: model.tool.symbolName)
        .font(Theme.font(11, weight: .semibold))
        .foregroundStyle(model.tool == .pointer ? Theme.text : Theme.accent)
        .frame(width: 24, height: 20)
        .background(Theme.raised, in: .rect(cornerRadius: 4))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("\(model.tool.name): \(model.tool.help). Press T to change tools.")
    .accessibilityLabel("Tool")
    .accessibilityValue(model.tool.name)
    .accessibilityIdentifier("tool-menu")
  }
}

/// Logic's T menu: each tool with the key that picks it.
private struct ToolMenuPanel: View {
  let model: ProjectWindowModel

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(ArrangeTool.allCases) { tool in
        Button {
          model.tool = tool
          model.isShowingToolMenu = false
        } label: {
          HStack(spacing: 8) {
            Text(String(tool.key).uppercased())
              .font(Theme.monospaced(10))
              .foregroundStyle(Theme.secondaryText)
              .frame(width: 14)
            Image(systemName: tool.symbolName)
              .frame(width: 16)
            Text(tool.name)
            Spacer(minLength: 0)
          }
          .font(Theme.font(11))
          .foregroundStyle(tool == model.tool ? Color.black.opacity(0.85) : Theme.text)
          .padding(.horizontal, 8)
          .frame(height: 22)
          .background(tool == model.tool ? Theme.accent : Color.clear, in: .rect(cornerRadius: 4))
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(4)
    .frame(width: 180)
    .background(Theme.raised, in: .rect(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.black.opacity(0.5)))
    .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Tool Menu")
  }
}

/// The playhead: Logic's white marker in the ruler and the line down through the lanes.
private struct PlayheadOverlay: View {
  let model: ProjectWindowModel

  private typealias Layout = ProjectWindowModel.Layout

  var body: some View {
    let scroll = model.scroll
    let x = model.headerWidth + model.x(for: model.engine.playheadPosition) - scroll.offset.x
    // Hidden while it's scrolled under the track headers.
    if x >= model.headerWidth, scroll.viewportSize.width > 0 {
      let rulerBottom = Layout.rulerHeight
      ZStack(alignment: .topLeading) {
        Rectangle()
          .fill(Theme.playhead.opacity(0.9))
          .frame(width: 1, height: max(0, scroll.viewportSize.height - rulerBottom))
          .offset(x: x, y: rulerBottom)
        PlayheadMarker()
          .fill(Theme.playhead)
          .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
          .frame(width: 12, height: 13)
          .offset(x: x - 6, y: rulerBottom - 13)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }
}

/// A pentagon pointing down into the lanes.
private struct PlayheadMarker: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.55))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.55))
      path.closeSubpath()
    }
  }
}

/// Keeps the playhead in view during playback by paging the tracks area, like Logic's
/// Catch mode, and brings it into view when it jumps while stopped (Go to Beginning, a bar
/// back or forward, a marker), so the jump can be seen. It is a separate view so only it
/// reads the playhead position.
private struct PlayheadFollower: View {
  let model: ProjectWindowModel
  @Binding var scrollPosition: ScrollPosition
  @AppStorage(AppSettings.followsPlayheadKey) private var followsPlayhead = true

  var body: some View {
    Color.clear
      .onChange(of: model.engine.playheadPosition) { _, position in
        if model.engine.isRecording { model.makeRoomForRecording(at: position) }
        // The setting only governs following during playback; a jump while stopped is
        // always shown.
        guard !model.engine.isPlaying || followsPlayhead else { return }
        let lanesWidth = model.scroll.viewportSize.width - model.headerWidth
        guard lanesWidth > 0 else { return }
        let playheadX = model.x(for: position)
        let visibleStart = model.scroll.offset.x
        if playheadX > visibleStart + lanesWidth - 20 || playheadX < visibleStart {
          scrollPosition.scrollTo(point: CGPoint(x: max(0, playheadX - 40), y: model.scroll.offset.y))
        }
      }
      .onChange(of: model.engine.isRecording) { _, isRecording in
        if !isRecording { model.canvasEndWhileRecording = nil }
      }
  }
}
