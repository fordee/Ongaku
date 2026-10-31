//
//  PianoRollView.swift
//  Ongaku
//

import AppKit
import OngakuCore
import OngakuEngine
import SwiftUI

/// Logic's Piano Roll: a keyboard down the left, a bar ruler across the top and the notes of
/// the open MIDI region in between. Double-click to add a note, drag to move, drag a note's
/// right edge to resize, and press Delete to remove the selection (see `KeyCommandMonitor`).
struct PianoRollView: View {
  let model: PianoRollModel

  var body: some View {
    VStack(spacing: 0) {
      PianoRollHeader(model: model)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor-header")
      if let region = model.region, model.track != nil {
        switch model.shownEditor {
        case .pianoRoll: PianoRollGrid(model: model, region: region)
        case .stepEditor: StepEditorView(model: model, region: region)
        case .stepSequencer: StepSequencerView(model: model, region: region)
        case .drummer: DrummerEditorView(model: model, region: region)
        case .player: PlayerEditorView(model: model, region: region)
        case .takes: TakesEditorView(model: model, region: region)
        case .pitch: FlexPitchEditorView(model: model, region: region)
        }
      } else {
        ContentUnavailableView(
          "No MIDI Region", systemImage: "pianokeys",
          description: Text("Double-click a MIDI region to edit it here, or double-click an empty instrument lane to create one."))
          .foregroundStyle(Theme.secondaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(Theme.lanes)
    .onHover { model.isPointerOver = $0 }
    // A click anywhere here, the header too, makes the Piano Roll what keys edit.
    .simultaneousGesture(TapGesture().onEnded { model.window.beginEditing(in: .pianoRoll) })
    .overlay(alignment: .topTrailing) {
      if model.isToolMenuForPianoRoll {
        PianoRollToolMenuPanel(model: model)
          .padding(.top, 32)
          .padding(.trailing, 120)
      }
    }
  }
}

private struct PianoRollHeader: View {
  let model: PianoRollModel

  @State private var velocity = 100.0

  var body: some View {
    HStack(spacing: 12) {
      // Only worth showing when there's a choice of editors.
      if model.availableEditors.count > 1 {
        Picker("Editor", selection: Binding(get: { model.shownEditor }, set: { model.editorKind = $0 })) {
          ForEach(model.availableEditors) { kind in
            Text(kind.title).tag(kind)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel("Editor")
      }
      if model.shownEditor == .drummer || model.shownEditor == .player, let track = model.track {
        // The Drummer's own strip shows who's playing which section; just name the track.
        Text(track.name).font(Theme.font(11, weight: .semibold))
      } else if let region = model.region, let track = model.track {
        Text(region.name).font(Theme.font(11, weight: .semibold))
        Text(track.name).font(Theme.font(11)).foregroundStyle(Theme.secondaryText)
        // A take folder's notes are one take's: say which.
        if model.shownEditor == .pianoRoll || model.shownEditor == .stepEditor, let take = model.editedTake {
          Label("Editing \(take.name)", systemImage: "star.fill")
            .font(Theme.font(11, weight: .medium))
            .foregroundStyle(Theme.solo)
            .help("This take starts the comp, so it’s the one edited here. To edit another, click its name in Takes to play it throughout.")
        }
      } else {
        Text("Piano Roll").font(Theme.font(11, weight: .semibold))
      }
      Spacer()

      if model.shownEditor == .pianoRoll {
        PianoRollToolButton(model: model)
      }

      if model.shownEditor == .takes, let region = model.region {
        Button("Flatten") { model.window.perform(FlattenTakeFolder(region.id)) }
          .help("Replace the take folder with what its comp plays")
      }
      if model.shownEditor == .pitch, let region = model.region {
        Button("Correct Pitch") { model.window.correctPitch(of: region.id) }
          .help("Move every note to the nearest semitone")
        Button("Reset All") { model.window.perform(SetPitchEdits([], in: region.id, actionName: "Reset Pitch")) }
          .help("Put every note back where it was sung")
      }

      if !model.selectedNoteIDs.isEmpty, model.shownEditor == .pianoRoll {
        Text("Velocity")
          .font(Theme.font(11))
          .foregroundStyle(Theme.secondaryText)
        Slider(value: $velocity, in: 1...127, step: 1) { editing in
          if !editing { model.setVelocity(Int(velocity)) }
        }
        .frame(width: 120)
        .accessibilityLabel("Velocity")
        Text("\(Int(velocity))")
          .font(Theme.monospaced(11))
          .frame(width: 28, alignment: .trailing)
      }

      if ![.stepSequencer, .drummer, .player].contains(model.shownEditor) {
        Picker("Grid", selection: Binding(get: { model.gridSetting }, set: { model.gridSetting = $0 })) {
          Text(PianoRollModel.GridSetting.automatic.title).tag(PianoRollModel.GridSetting.automatic)
          Divider()
          ForEach(PianoRollModel.GridSetting.straight) { setting in
            Text(setting.title).tag(setting)
          }
          Divider()
          ForEach(PianoRollModel.GridSetting.triplets) { setting in
            Text(setting.title).tag(setting)
          }
        }
        .fixedSize()
        .help("What notes snap to. 1/8T and the other triplet grids put three notes where two straight ones go.")
      }

      if model.shownEditor == .pianoRoll {
        Button("Snap", systemImage: "squareshape.split.3x3") { model.isSnapEnabled.toggle() }
          .buttonStyle(ThemeButtonStyle(isOn: model.isSnapEnabled, onColor: Theme.accent, width: 26, height: 20))
          .help(model.isSnapEnabled
            ? "Notes snap to the grid. Click to turn snapping off, or press Control while dragging to move freely."
            : "Snapping is off: notes go exactly where you put them. Click to snap to the grid.")
          .accessibilityValue(model.isSnapEnabled ? "On" : "Off")
      }

      if model.shownEditor == .pianoRoll || model.shownEditor == .stepEditor {
        Menu("Quantize") {
          Button("Quantize to Grid (Q)") { model.quantizeSelection() }
          Section("Straight") {
            ForEach(PianoRollModel.GridSetting.straight) { setting in
              Button(setting.quantizeTitle) { model.quantizeSelection(to: setting) }
            }
          }
          Section("Triplets") {
            ForEach(PianoRollModel.GridSetting.triplets) { setting in
              Button(setting.quantizeTitle) { model.quantizeSelection(to: setting) }
            }
          }
          Section("Straight and Triplets") {
            ForEach(PianoRollModel.MixedQuantize.all) { mixed in
              Button(mixed.title) { model.quantizeSelection(to: mixed.straight, or: mixed.triplet) }
            }
          }
          Divider()
          Picker("Strength", selection: Binding(get: { model.quantizeStrength }, set: { model.quantizeStrength = $0 })) {
            ForEach([1.0, 0.75, 0.5, 0.25], id: \.self) { Text("\(Int($0 * 100)) %").tag($0) }
          }
          Picker("Swing", selection: Binding(get: { model.quantizeSwing }, set: { model.quantizeSwing = $0 })) {
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { Text($0 == 0 ? "Off" : "\(Int($0 * 100)) %").tag($0) }
          }
        }
        .fixedSize()
        .disabled(model.region == nil)
        .help("Quantize the selected notes, or every note if none are selected. Strength moves them part of the way; swing delays every second grid line.")
      }

      if model.shownEditor == .pianoRoll {
        Menu("Edit") {
          Button("Cut") { model.cutSelection() }.disabled(model.selectedNoteIDs.isEmpty)
          Button("Copy") { model.copySelection() }.disabled(model.selectedNoteIDs.isEmpty)
          Button("Paste at Playhead") { model.paste() }.disabled(!model.canPasteNotes)
          Button("Repeat") { model.repeatSelection() }.disabled(model.selectedNoteIDs.isEmpty)
          Button("Delete") { model.deleteSelection() }.disabled(model.selectedNoteIDs.isEmpty)
          Divider()
          Button("Select All") { model.selectAll() }
          Button("Select Same Pitches") { model.selectSamePitches() }.disabled(model.selectedNoteIDs.isEmpty)
          Button("Select Muted Notes") { model.selectMuted() }
          Button("Invert Selection") { model.invertSelection() }
          Button("Deselect All") { model.deselectAll() }
        }
        .fixedSize()
        .disabled(model.region == nil)
        Menu("Functions") {
          NoteFunctionItems(model: model)
        }
        .fixedSize()
        .disabled(model.notes.isEmpty)
        .help("Note functions, on the selected notes (or every note if none are selected)")
      }

      if model.shownEditor == .pianoRoll {
        MIDIDrawControls(model: model)
      }

      HStack(spacing: 3) {
        Button("Zoom Out", systemImage: "minus.magnifyingglass") { model.zoom(by: 1 / 1.5) }
        Button("Zoom In", systemImage: "plus.magnifyingglass") { model.zoom(by: 1.5) }
      }
      .buttonStyle(ThemeButtonStyle(width: 26, height: 20))

      Button("Close Editor", systemImage: "xmark") { model.window.isEditorVisible = false }
        .buttonStyle(ThemeButtonStyle(width: 22, height: 18))
    }
    .controlSize(.small)
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background(LinearGradient(colors: [Theme.controlBarTop, Theme.controlBarBottom], startPoint: .top, endPoint: .bottom))
    .overlay(alignment: .bottom) {
      Rectangle().fill(Theme.separator).frame(height: 1)
    }
    .onChange(of: model.selectedNoteIDs, initial: true) { syncVelocity() }
    .onChange(of: model.notes) { syncVelocity() }
  }

  /// Shows the first selected note's velocity.
  private func syncVelocity() {
    if let note = model.notes.first(where: { model.selectedNoteIDs.contains($0.id) }) {
      velocity = Double(note.velocity)
    }
  }
}

/// Chooses the Piano Roll's tool, showing the current one's icon (T, then a key, too).
private struct PianoRollToolButton: View {
  let model: PianoRollModel

  var body: some View {
    Menu {
      Picker("Tool", selection: Binding(get: { model.tool }, set: { model.tool = $0 })) {
        ForEach(PianoRollTool.allCases) { tool in
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
    .help("\(model.tool.name): \(model.tool.help). Press T to change tools; hold Command for the Pencil.")
    .accessibilityLabel("Piano Roll Tool")
    .accessibilityValue(model.tool.name)
  }
}

/// The T menu for the Piano Roll: each tool with the key that picks it.
struct PianoRollToolMenuPanel: View {
  let model: PianoRollModel

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(PianoRollTool.allCases) { tool in
        Button {
          model.tool = tool
          model.window.isShowingToolMenu = false
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
    .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
  }
}

/// Shows or hides the MIDI Draw lane, and chooses what it edits.
private struct MIDIDrawControls: View {
  let model: PianoRollModel

  var body: some View {
    HStack(spacing: 6) {
      Button("MIDI Draw", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
        model.isMIDIDrawVisible.toggle()
      }
      .buttonStyle(ThemeButtonStyle(isOn: model.isMIDIDrawVisible, onColor: Theme.accent, width: 26, height: 20))
      .help(model.isMIDIDrawVisible ? "Hide MIDI Draw" : "Show MIDI Draw: velocity, controllers, pitch bend and aftertouch")
      .accessibilityValue(model.isMIDIDrawVisible ? "Shown" : "Hidden")

      if model.isMIDIDrawVisible {
        let inUse = model.parametersInUse
        Menu {
          ForEach(MIDIDrawParameter.common, id: \.self) { parameter in
            parameterButton(parameter, inUse: inUse)
          }
          Divider()
          Menu("Other Controllers") {
            ForEach(Array(MIDIControlEvent.Kind.controllerNumbers), id: \.self) { number in
              let parameter = MIDIDrawParameter.control(.controller(number))
              if !MIDIDrawParameter.common.contains(parameter) {
                parameterButton(parameter, inUse: inUse)
              }
            }
          }
        } label: {
          Text(model.midiDrawParameter.name)
        }
        .fixedSize()
        .help("What the MIDI Draw lane shows. Parameters with data in this region are marked with a dot.")
      }
    }
  }

  @ViewBuilder
  private func parameterButton(_ parameter: MIDIDrawParameter, inUse: Set<MIDIDrawParameter>) -> some View {
    let title = inUse.contains(parameter) && parameter != .velocity ? "\(parameter.name)  •" : parameter.name
    Button {
      model.midiDrawParameter = parameter
      model.selectedControlIDs = []
    } label: {
      if model.midiDrawParameter == parameter {
        Label(title, systemImage: "checkmark")
      } else {
        Text(title)
      }
    }
  }
}

/// The scrolling area. The keyboard and ruler are pinned with `visualEffect` offsets, the same
/// way as the tracks area.
private struct PianoRollGrid: View {
  let model: PianoRollModel
  let region: Region

  @State private var scrollPosition = ScrollPosition()
  @State private var hasScrolledToMiddle = false

  private typealias Layout = PianoRollModel.Layout

  var body: some View {
    // The MIDI Draw lane is pinned to the bottom of what's visible.
    let visibleHeight = model.scroll.viewportSize.height
    ScrollView([.horizontal, .vertical]) {
      ZStack(alignment: .topLeading) {
        NotesArea(model: model, region: region)
          .offset(x: Layout.keyboardWidth, y: Layout.rulerHeight)

        if model.isMIDIDrawVisible {
          // Pinned to the bottom of the view; it scrolls sideways with the notes.
          // Laid out at the top of the content and moved by the visual effect alone: its
          // geometry is measured before any `offset` above it.
          MIDIDrawLane(model: model, region: region)
            .offset(x: Layout.keyboardWidth)
            .visualEffect { content, geometry in
              content.offset(y: visibleHeight - geometry.frame(in: .scrollView).maxY)
            }
        }

        EditorRuler(model: model, region: region)
          .offset(x: Layout.keyboardWidth)
          .visualEffect { content, geometry in
            content.offset(y: -geometry.frame(in: .scrollView).minY)
          }

        PianoKeyboard(model: model)
          .offset(y: Layout.rulerHeight)
          .visualEffect { content, geometry in
            content.offset(x: -geometry.frame(in: .scrollView).minX)
          }

        Rectangle()
          .fill(Theme.ruler)
          .frame(width: Layout.keyboardWidth, height: Layout.rulerHeight)
          .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
          .visualEffect { content, geometry in
            let frame = geometry.frame(in: .scrollView)
            return content.offset(x: -frame.minX, y: -frame.minY)
          }

        if model.isMIDIDrawVisible {
          MIDIDrawScale(model: model)
            .visualEffect { content, geometry in
              let frame = geometry.frame(in: .scrollView)
              return content.offset(x: -frame.minX, y: visibleHeight - frame.maxY)
            }
        }
      }
      // With the MIDI Draw lane showing, there's room below the lowest key so it can scroll
      // above the lane.
      .frame(
        width: Layout.keyboardWidth + model.contentWidth,
        height: Layout.rulerHeight + Layout.contentHeight + (model.isMIDIDrawVisible ? model.midiDrawHeight : 0),
        alignment: .topLeading)
    }
    .overlay(alignment: .topLeading) { PianoRollPlayhead(model: model, region: region) }
    .scrollPosition($scrollPosition)
    .onScrollGeometryChange(for: CGRect.self) { geometry in
      CGRect(origin: geometry.contentOffset, size: geometry.containerSize)
    } action: { _, visible in
      model.scroll.update(offset: visible.origin, viewportSize: visible.size)
    }
    .onAppear {
      // Start with the notes (or middle C) in view rather than at the top of the keyboard.
      guard !hasScrolledToMiddle else { return }
      hasScrolledToMiddle = true
      let pitches = model.notes.map(\.pitch)
      let centerPitch = pitches.isEmpty ? 60 : (pitches.min()! + pitches.max()!) / 2
      scrollPosition.scrollTo(y: max(0, model.y(forPitch: centerPitch + 12)))
    }
    .simultaneousGesture(TapGesture().onEnded { model.window.beginEditing(in: .pianoRoll) })
  }
}

/// Key rows, grid lines, the region bounds, notes and the playhead. What clicking and
/// dragging in empty space does depends on the tool: the Pointer drags a rubber band, the
/// Pencil draws a note, the Brush paints them along the grid.
private struct NotesArea: View {
  static let coordinateSpace = "pianoRollNotes"

  let model: PianoRollModel
  let region: Region

  /// The notes the Brush has passed over, painted when it's let go.
  @State private var brushCells: [(start: Tick, pitch: Int)] = []
  /// The note the Pencil is drawing.
  @State private var pencilNote: CGRect?

  private typealias Layout = PianoRollModel.Layout

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Clicks on empty space land on this background; clicks on notes never reach it, so
      // selecting a note can't also clear the selection.
      Color.clear
        .contentShape(.rect)
        .onTapGesture(count: 2) { location in
          if model.activeTool == .pointer {
            model.addNote(at: model.position(forX: location.x), pitch: model.pitch(forY: location.y))
          }
        }
        .onTapGesture { location in click(at: location) }
        .gesture(emptyDrag)

      KeyRows(model: model)
      EditorGridLines(model: model, region: region)

      // Outside the region: notes here are kept but don't play.
      Rectangle()
        .fill(Color.black.opacity(0.18))
        .frame(width: max(0, model.contentWidth - model.x(for: region.length)), height: Layout.contentHeight)
        .offset(x: model.x(for: region.length))
        .allowsHitTesting(false)

      // Each note gets just what it shows, so selecting one redraws only the notes that
      // changed (not every note on screen).
      let selected = model.selectedNoteIDs
      let drag = model.dragPreview, resize = model.resizePreview, velocities = model.velocityToolPreview
      let isCopyDrag = model.isCopyDrag, scale = model.pointsPerQuarterNote
      ForEach(model.shownNotes) { note in
        let isSelected = selected.contains(note.id)
        NoteView(
          model: model, note: note, regionLength: region.length, isSelected: isSelected, drag: isSelected ? drag : nil,
          resize: resize?.notes.contains(note.id) == true ? resize : nil, velocity: velocities?[note.id] ?? note.velocity,
          isCopyDrag: isCopyDrag, pointsPerQuarterNote: scale)
          .equatable()
      }

      // What the Pencil and Brush are drawing, and the rubber band.
      if let pencilNote {
        ghost(pencilNote)
      }
      ForEach(Array(brushCells.enumerated()), id: \.offset) { _, cell in
        ghost(CGRect(
          x: model.x(for: model.snapDown(cell.start)), y: model.y(forPitch: cell.pitch),
          width: model.x(for: model.grid), height: Layout.rowHeight - 1))
      }
      if let marquee = model.marquee {
        Rectangle()
          .fill(Theme.accent.opacity(0.12))
          .overlay(Rectangle().strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1))
          .frame(width: marquee.width, height: marquee.height)
          .offset(x: marquee.minX, y: marquee.minY)
          .allowsHitTesting(false)
      }
    }
    .frame(width: model.contentWidth, height: Layout.contentHeight, alignment: .topLeading)
    .coordinateSpace(.named(NotesArea.coordinateSpace))
    // One right-click menu for the whole area (one per note would be thousands of menus);
    // it works on the note under the pointer, if there is one.
    // The last place the pointer was is kept: it's where the right-click was while the
    // menu is open.
    .onContinuousHover(coordinateSpace: .named(NotesArea.coordinateSpace)) { phase in
      if case .active(let location) = phase { model.pointerLocation = location }
    }
    .contextMenu { PianoRollContextMenu(model: model) }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("piano-roll-notes")
  }

  private func ghost(_ rect: CGRect) -> some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(PianoRollModel.color(forVelocity: model.newNoteVelocity).opacity(0.55))
      .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
      .frame(width: max(4, rect.width), height: rect.height)
      .offset(x: rect.minX, y: rect.minY)
      .allowsHitTesting(false)
  }

  private func click(at location: CGPoint) {
    model.window.activeEditingArea = .pianoRoll
    let position = model.position(forX: location.x), pitch = model.pitch(forY: location.y)
    switch model.activeTool {
    case .pencil: model.drawNote(from: position, to: position, pitch: pitch)
    case .brush: model.paint([(position, pitch)])
    default:
      if !NSEvent.modifierFlags.contains(.shift) { model.deselectAll() }
    }
  }

  private var emptyDrag: some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .named(NotesArea.coordinateSpace))
      .onChanged { value in
        switch model.activeTool {
        case .pencil:
          let start = model.snapDown(model.position(forX: value.startLocation.x))
          let end = max(model.snap(model.position(forX: value.location.x)), start + model.grid)
          pencilNote = CGRect(
            x: model.x(for: start), y: model.y(forPitch: model.pitch(forY: value.startLocation.y)),
            width: model.x(for: end) - model.x(for: start), height: Layout.rowHeight - 1)
        case .brush:
          let cell = (start: model.snapDown(model.position(forX: value.location.x)), pitch: model.pitch(forY: value.location.y))
          if !brushCells.contains(where: { $0.start == cell.start && $0.pitch == cell.pitch }) {
            if brushCells.last?.pitch != cell.pitch { model.preview(pitch: cell.pitch, velocity: model.newNoteVelocity) }
            brushCells.append(cell)
          }
        default:
          model.marquee = CGRect(
            x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
            width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y))
        }
      }
      .onEnded { value in
        switch model.activeTool {
        case .pencil:
          pencilNote = nil
          model.drawNote(
            from: model.position(forX: value.startLocation.x), to: model.position(forX: value.location.x),
            pitch: model.pitch(forY: value.startLocation.y))
        case .brush:
          model.paint(brushCells)
          brushCells = []
        default:
          guard let rect = model.marquee else { return }
          model.marquee = nil
          model.selectNotes(
            over: model.position(forX: rect.minX)..<model.position(forX: rect.maxX),
            pitches: model.pitch(forY: rect.maxY)...model.pitch(forY: rect.minY),
            extending: NSEvent.modifierFlags.contains(.shift))
        }
      }
  }
}

/// Alternating shading for white- and black-key rows, drawn across the render range.
private struct KeyRows: View {
  let model: PianoRollModel

  var body: some View {
    let range = model.scroll.renderRange
    Canvas { context, size in
      var blackRows = Path()
      var octaveLines = Path()
      for pitch in 0..<PianoRollModel.Layout.pitchCount {
        let y = model.y(forPitch: pitch)
        if PianoRollModel.isBlackKey(pitch) {
          blackRows.addRect(CGRect(x: 0, y: y, width: size.width, height: PianoRollModel.Layout.rowHeight))
        }
        if pitch % 12 == 0 {
          octaveLines.addRect(CGRect(x: 0, y: y + PianoRollModel.Layout.rowHeight - 1, width: size.width, height: 1))
        }
      }
      context.fill(blackRows, with: .color(.black.opacity(0.22)))
      context.fill(octaveLines, with: .color(Theme.barLine))
    }
    .frame(width: range.upperBound - range.lowerBound, height: PianoRollModel.Layout.contentHeight)
    .offset(x: range.lowerBound)
    .allowsHitTesting(false)
  }
}

/// Bar, beat and grid lines across the render range, measured from the project's bar lines.
/// Also drawn behind the MIDI Draw lane, so its points line up with the notes.
struct EditorGridLines: View {
  let model: PianoRollModel
  let region: Region
  var height = PianoRollModel.Layout.contentHeight

  var body: some View {
    let range = model.scroll.renderRange
    let tempoMap = model.window.project.tempoMap
    let pointsPerQuarterNote = model.pointsPerQuarterNote
    let grid = model.grid
    let regionStart = region.start
    let firstAbsolute = regionStart + model.position(forX: range.lowerBound)
    let lastAbsolute = regionStart + model.position(forX: range.upperBound)

    Canvas { context, size in
      func x(_ absolute: Tick) -> CGFloat {
        CGFloat((absolute - regionStart).quarterNotes * pointsPerQuarterNote) - range.lowerBound
      }
      var bars = Path()
      var beats = Path()
      var divisions = Path()
      var (barIndex, barStart) = tempoMap.bar(containing: max(.zero, firstAbsolute))
      while barStart <= lastAbsolute {
        bars.addRect(CGRect(x: x(barStart), y: 0, width: 1, height: size.height))
        let signature = tempoMap.timeSignature(atBarIndex: barIndex)
        let barEnd = barStart + signature.ticksPerBar
        var position = barStart + grid
        while position < barEnd {
          let rect = CGRect(x: x(position), y: 0, width: 1, height: size.height)
          // Beats are the felt beat: dotted quarters in 6/8 and 12/8.
          if (position - barStart).rawValue % signature.pulse.rawValue == 0 {
            beats.addRect(rect)
          } else {
            divisions.addRect(rect)
          }
          position += grid
        }
        barIndex += 1
        barStart = tempoMap.tickPosition(ofBarIndex: barIndex)
      }
      context.fill(divisions, with: .color(Theme.beatLine.opacity(0.6)))
      context.fill(beats, with: .color(Theme.beatLine.mix(with: .white, by: 0.04)))
      context.fill(bars, with: .color(Theme.barLine.mix(with: .white, by: 0.06)))
    }
    .frame(width: range.upperBound - range.lowerBound, height: height)
    .offset(x: range.lowerBound)
    .allowsHitTesting(false)
  }
}

private struct NoteView: View, Equatable {
  let model: PianoRollModel
  let note: MIDINote
  let regionLength: Tick
  let isSelected: Bool
  /// The drag moving the selection, if this note is in it.
  let drag: PianoRollModel.NoteDragPreview?
  /// The resize of the selection, if this note is in it.
  let resize: PianoRollModel.ResizePreview?
  /// The velocity shown: the Velocity tool's, while it's dragged.
  let velocity: Int
  let isCopyDrag: Bool
  let pointsPerQuarterNote: Double

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.note == rhs.note && lhs.regionLength == rhs.regionLength && lhs.isSelected == rhs.isSelected
      && lhs.drag == rhs.drag && lhs.resize == rhs.resize && lhs.velocity == rhs.velocity && lhs.isCopyDrag == rhs.isCopyDrag
      && lhs.pointsPerQuarterNote == rhs.pointsPerQuarterNote
  }

  private typealias Layout = PianoRollModel.Layout

  /// Like the model's, but from this view's own values, so drawing reads nothing that would
  /// make every note redraw.
  private func x(for position: Tick) -> CGFloat {
    CGFloat(position.quarterNotes * pointsPerQuarterNote)
  }

  var body: some View {
    let (start, length) = shownSpan(drag: drag)
    let pitch = min(max(note.pitch + (drag?.pitchOffset ?? 0), 0), 127)
    let isOutsideRegion = note.start < .zero || note.start >= regionLength

    ZStack(alignment: .topLeading) {
      // While Option-dragging, the originals stay where they are.
      if drag != nil, isCopyDrag {
        RoundedRectangle(cornerRadius: 2)
          .fill(PianoRollModel.color(forVelocity: velocity).opacity(0.35))
          .frame(width: max(x(for: note.length), 4), height: Layout.rowHeight - 1)
          .offset(x: x(for: note.start) - x(for: start), y: model.y(forPitch: note.pitch) - model.y(forPitch: pitch))
      }
      RoundedRectangle(cornerRadius: 2)
        .fill(note.isMuted ? Color(white: 0.45) : PianoRollModel.color(forVelocity: velocity))
        .overlay {
          RoundedRectangle(cornerRadius: 2)
            .strokeBorder(isSelected ? Color.white : Color.black.opacity(0.55), lineWidth: isSelected ? 1.5 : 1)
        }
        .overlay(alignment: .leading) { edgeHandle(fromStart: true) }
        .overlay(alignment: .trailing) { edgeHandle(fromStart: false) }
    }
    .frame(width: max(x(for: length), 4), height: Layout.rowHeight - 1, alignment: .topLeading)
    .opacity(isOutsideRegion ? 0.35 : note.isMuted ? 0.7 : 1)
    .offset(x: x(for: start), y: model.y(forPitch: pitch))
    .zIndex(drag == nil ? 0 : 1)
    .onTapGesture(coordinateSpace: .named(NotesArea.coordinateSpace)) { location in
      if model.applyTool(to: note.id, at: model.position(forX: location.x)) { return }
      model.select(note.id, extending: NSEvent.modifierFlags.contains(.shift))
      model.preview(pitch: note.pitch, velocity: note.velocity)
    }
    .gesture(moveGesture)
    .accessibilityElement()
    .accessibilityLabel("Note \(PianoRollModel.noteName(note.pitch)), velocity \(note.velocity)\(note.isMuted ? ", muted" : "")")
    .accessibilityIdentifier("note")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// Where the note is drawn: moved by a drag, or resized with the selection.
  private func shownSpan(drag: PianoRollModel.NoteDragPreview?) -> (start: Tick, length: Tick) {
    guard let resize else {
      return (note.start + (drag?.offset ?? .zero), note.length)
    }
    if resize.fromStart {
      let moved = min(max(.zero, note.start + resize.delta), note.end - Tick(1))
      return (moved, note.end - moved)
    }
    return (note.start, max(Tick(1), note.length + resize.delta))
  }

  /// A note's start or end: drag it to resize the note (and the rest of the selection).
  private func edgeHandle(fromStart: Bool) -> some View {
    Rectangle()
      .fill(.clear)
      .frame(width: x(for: note.length) > 14 ? 6 : 3)
      .contentShape(.rect)
      .pointerStyle(.frameResize(position: fromStart ? .leading : .trailing))
      .gesture(resizeGesture(fromStart: fromStart))
  }

  private var moveGesture: some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .named(NotesArea.coordinateSpace))
      .onChanged { value in
        switch model.activeTool {
        case .velocity:
          model.velocityToolPreview = model.velocityChange(for: note.id, dragged: value.translation.height)
        case .pointer, .pencil:
          if !model.selectedNoteIDs.contains(note.id) {
            model.select(note.id, extending: false)
          }
          if model.dragPreview == nil { model.isCopyDrag = NSEvent.modifierFlags.contains(.option) }
          let preview = movePreview(for: value.translation)
          if preview.pitchOffset != model.dragPreview?.pitchOffset {
            model.preview(pitch: note.pitch + preview.pitchOffset, velocity: note.velocity)
          }
          model.dragPreview = preview
        default:
          break
        }
      }
      .onEnded { value in
        switch model.activeTool {
        case .velocity:
          if let velocities = model.velocityToolPreview { model.finishVelocityChange(velocities) }
          model.velocityToolPreview = nil
        case .pointer, .pencil:
          let preview = movePreview(for: value.translation)
          model.dragPreview = nil
          if model.isCopyDrag {
            model.copySelection(by: preview.offset, pitchOffset: preview.pitchOffset)
          } else {
            model.moveSelection(by: preview.offset, pitchOffset: preview.pitchOffset)
          }
          model.isCopyDrag = false
        default:
          break
        }
      }
  }

  private func movePreview(for translation: CGSize) -> PianoRollModel.NoteDragPreview {
    let proposedStart = max(.zero, note.start + model.position(forX: translation.width))
    let offset = model.snap(proposedStart) - note.start
    let pitchOffset = -Int((translation.height / Layout.rowHeight).rounded())
    return .init(offset: offset, pitchOffset: pitchOffset)
  }

  private func resizeGesture(fromStart: Bool) -> some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .named(NotesArea.coordinateSpace))
      .onChanged { value in
        guard model.activeTool.movesNotes else { return }
        let targets = model.selectedNoteIDs.contains(note.id) ? model.selectedNoteIDs : [note.id]
        model.resizePreview = .init(notes: targets, fromStart: fromStart, delta: snappedDelta(for: value.translation.width, fromStart: fromStart))
      }
      .onEnded { value in
        guard model.activeTool.movesNotes else { return }
        model.resizePreview = nil
        model.resizeSelection(note.id, fromStart: fromStart, by: snappedDelta(for: value.translation.width, fromStart: fromStart))
      }
  }

  /// How far the dragged edge moves: to the nearest grid line, keeping the note at least one
  /// grid step long.
  private func snappedDelta(for translation: CGFloat, fromStart: Bool) -> Tick {
    if fromStart {
      let start = min(model.snap(note.start + model.position(forX: translation)), note.end - model.grid)
      return max(.zero, start) - note.start
    }
    let end = model.snap(note.end + model.position(forX: translation))
    return max(end - note.start, model.grid) - note.length
  }
}

/// What right-clicking a note (or empty space) offers: Logic's editing, selecting and
/// function commands. On a note that isn't selected, it's selected first.
private struct PianoRollContextMenu: View {
  let model: PianoRollModel

  /// The note right-clicked, if it was on one.
  private var noteID: MIDINote.ID? {
    model.pointerLocation.flatMap(model.note(at:))?.id
  }

  var body: some View {
    Group {
      Button("Cut") { act { model.cutSelection() } }.disabled(noteID == nil && model.selectedNoteIDs.isEmpty)
      Button("Copy") { act { model.copySelection() } }.disabled(noteID == nil && model.selectedNoteIDs.isEmpty)
      Button("Paste") { model.paste() }.disabled(!model.canPasteNotes)
      Button("Repeat") { act { model.repeatSelection() } }.disabled(noteID == nil && model.selectedNoteIDs.isEmpty)
      Button("Delete") { act { model.deleteSelection() } }.disabled(noteID == nil && model.selectedNoteIDs.isEmpty)
      Divider()
      Button("Select All") { model.selectAll() }
      Button("Select Same Pitches") { act { model.selectSamePitches() } }
      Button("Invert Selection") { model.invertSelection() }
      Divider()
      NoteFunctionItems(model: model, before: { act {} })
    }
  }

  /// Right-clicking an unselected note works on that note, as in Logic.
  private func act(_ action: () -> Void) {
    if let noteID, !model.selectedNoteIDs.contains(noteID) {
      model.selectedNoteIDs = [noteID]
    }
    action()
  }
}

/// The note functions, for the Functions menu and right-click menus.
struct NoteFunctionItems: View {
  let model: PianoRollModel
  /// Runs first (selecting a right-clicked note).
  var before: () -> Void = {}

  var body: some View {
    Button("Quantize") { before(); model.quantizeSelection() }
    Menu("Transpose") {
      Button("Up a Semitone") { before(); model.apply(.transpose(1)) }
      Button("Down a Semitone") { before(); model.apply(.transpose(-1)) }
      Button("Up an Octave") { before(); model.apply(.transpose(12)) }
      Button("Down an Octave") { before(); model.apply(.transpose(-12)) }
    }
    Button("Mute / Unmute") { before(); model.toggleMuteSelection() }
    Divider()
    Menu("Note Length") {
      Button("Force Legato") { before(); model.apply(.legato) }
      Button("Remove Overlaps") { before(); model.apply(.removeOverlaps) }
      Button("Set to Grid (\(model.gridSetting.title == "Auto" ? "Auto" : model.gridSetting.title))") {
        before(); model.apply(.setLength(model.grid))
      }
    }
    Menu("Velocity") {
      Button("Louder (+10 %)") { before(); model.apply(.scaleVelocity(1.1)) }
      Button("Softer (−10 %)") { before(); model.apply(.scaleVelocity(0.9)) }
      Divider()
      ForEach([127, 100, 80, 64, 40], id: \.self) { velocity in
        Button("Set to \(velocity)") { before(); model.apply(.setVelocity(velocity)) }
      }
    }
    Divider()
    Button("Humanize") { before(); model.humanizeSelection() }
    Button("Reverse") { before(); model.apply(.reverse) }
    Button("Invert Pitches") { before(); model.apply(.invert) }
  }
}

/// The piano keyboard down the left. Click a key to hear it and select its notes.
private struct PianoKeyboard: View {
  let model: PianoRollModel

  private typealias Layout = PianoRollModel.Layout

  var body: some View {
    Canvas { context, size in
      // White keys first, as full-width ivory strips with a shadow line between them…
      for pitch in 0..<Layout.pitchCount where !PianoRollModel.isBlackKey(pitch) {
        let y = model.y(forPitch: pitch)
        let rect = CGRect(x: 0, y: y, width: size.width, height: Layout.rowHeight)
        context.fill(Path(rect), with: .linearGradient(
          Gradient(colors: [Color(hex: 0xD8D8DA), Color(hex: 0xF4F4F2)]),
          startPoint: CGPoint(x: 0, y: rect.midY), endPoint: CGPoint(x: size.width, y: rect.midY)))
        if (pitch % 12 == 0) || (pitch % 12 == 5) {
          // Between B–C and E–F, where white keys meet without a black key.
          context.fill(Path(CGRect(x: 0, y: rect.maxY - 1, width: size.width, height: 1)), with: .color(.black.opacity(0.35)))
        }
        if pitch % 12 == 0 {
          context.draw(
            Text(PianoRollModel.noteName(pitch)).font(Theme.font(8, weight: .medium)).foregroundStyle(Color(hex: 0x55555A)),
            at: CGPoint(x: size.width - 4, y: y + Layout.rowHeight / 2), anchor: .trailing)
        }
      }
      // …then the black keys on top, shorter, with rounded, lit ends.
      for pitch in 0..<Layout.pitchCount where PianoRollModel.isBlackKey(pitch) {
        let y = model.y(forPitch: pitch)
        let rect = CGRect(x: 0, y: y, width: size.width * 0.6, height: Layout.rowHeight)
        let key = Path(roundedRect: rect, cornerSize: CGSize(width: 2, height: 2))
        context.fill(key, with: .linearGradient(
          Gradient(colors: [Color(hex: 0x111113), Color(hex: 0x2C2C30), Color(hex: 0x48484D)]),
          startPoint: CGPoint(x: 0, y: rect.midY), endPoint: CGPoint(x: rect.maxX, y: rect.midY)))
      }
    }
    .frame(width: Layout.keyboardWidth, height: Layout.contentHeight)
    .overlay(alignment: .trailing) {
      Rectangle().fill(Theme.separator).frame(width: 1)
    }
    .contentShape(.rect)
    .onTapGesture { location in
      // As in Logic: clicking a key selects every note of its pitch (Shift adds them).
      let pitch = model.pitch(forY: location.y)
      model.preview(pitch: pitch)
      model.selectAll(pitch: pitch, extending: NSEvent.modifierFlags.contains(.shift))
    }
    .accessibilityLabel("Keyboard")
  }
}

/// Bar numbers across the top, matching the tracks area's ruler.
private struct EditorRuler: View {
  let model: PianoRollModel
  let region: Region

  var body: some View {
    let range = model.scroll.renderRange
    let tempoMap = model.window.project.tempoMap
    let pointsPerQuarterNote = model.pointsPerQuarterNote
    let regionStart = region.start
    let firstAbsolute = regionStart + model.position(forX: range.lowerBound)
    let lastAbsolute = regionStart + model.position(forX: range.upperBound)

    ZStack(alignment: .topLeading) {
      Rectangle()
        .fill(Theme.ruler)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
      Canvas { context, size in
        func x(_ absolute: Tick) -> CGFloat {
          CGFloat((absolute - regionStart).quarterNotes * pointsPerQuarterNote) - range.lowerBound
        }
        var ticks = Path()
        var (barIndex, barStart) = tempoMap.bar(containing: max(.zero, firstAbsolute))
        while barStart <= lastAbsolute {
          let barX = x(barStart)
          ticks.addRect(CGRect(x: barX, y: size.height - 12, width: 1, height: 12))
          context.draw(
            Text("\(barIndex + 1)").font(Theme.monospaced(10)).foregroundStyle(Theme.rulerText),
            at: CGPoint(x: barX + 3, y: size.height - 13), anchor: .topLeading)
          barIndex += 1
          barStart = tempoMap.tickPosition(ofBarIndex: barIndex)
        }
        context.fill(ticks, with: .color(Theme.rulerTick))
      }
      .frame(width: range.upperBound - range.lowerBound)
      .offset(x: range.lowerBound)
    }
    // Top-leading alignment matters: the canvas can be wider than the ruler, and a centered
    // canvas would shift every bar number.
    .frame(width: model.contentWidth, height: PianoRollModel.Layout.rulerHeight, alignment: .topLeading)
    .allowsHitTesting(false)
  }
}

/// The playhead, drawn over the scroll view rather than among the notes, so moving it 30
/// times a second while playing doesn't touch them (as in the tracks area).
private struct PianoRollPlayhead: View {
  let model: PianoRollModel
  let region: Region

  private typealias Layout = PianoRollModel.Layout

  var body: some View {
    let scroll = model.scroll
    let x = Layout.keyboardWidth + model.x(for: model.window.engine.playheadPosition - region.start) - scroll.offset.x
    if x >= Layout.keyboardWidth, x <= scroll.viewportSize.width {
      Rectangle()
        .fill(Theme.playhead.opacity(0.9))
        .frame(width: 1, height: max(0, scroll.viewportSize.height - Layout.rulerHeight))
        .offset(x: x, y: Layout.rulerHeight)
        .allowsHitTesting(false)
    }
  }
}

/// Holds the window model for the preview: the piano roll only keeps an unowned reference.
private struct PianoRollPreview: View {
  @State private var window: ProjectWindowModel = {
    let window = ProjectWindowModel(document: OngakuDocument(project: .previewSong))
    window.openEditor(for: window.project.tracks[2].regions[0].id)
    return window
  }()

  var body: some View {
    PianoRollView(model: window.pianoRoll)
  }
}

#Preview {
  PianoRollPreview().frame(width: 900, height: 360)
}
