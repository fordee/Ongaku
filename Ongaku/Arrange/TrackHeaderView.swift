//
//  TrackHeaderView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// The column of track headers to the left of the lanes.
struct TrackHeadersColumn: View {
  let model: ProjectWindowModel
  /// The lanes' height, so the column covers everything scrolling underneath it.
  var height: CGFloat

  var body: some View {
    // Like the lanes, only the rows near the viewport are built. Numbers count every track,
    // including a collapsed stack's hidden subtracks, as in Logic.
    let tracks = model.displayedTracks
    let rows = model.scroll.visibleRows.clamped(to: 0..<tracks.count)
    let numbers = Dictionary(uniqueKeysWithValues: model.project.tracks.enumerated().map { ($1.id, $0 + 1) })
    let liveMIDITrackIDs = Set(model.liveMIDITrackIDs)
    ZStack(alignment: .topLeading) {
      // The space below the tracks: right-click for a new track at the end, or an import.
      Color.clear
        .contentShape(.rect)
        .contextMenu {
          Menu("New Track") {
            NewTrackMenuItems(model: model) { model.selectedTrackID = nil }
          }
          Divider()
          Button("Import Audio Files…") { model.activeImporter = .audio }
          Button("Import MIDI File…") { model.activeImporter = .midi }
        }
      ForEach(rows.map { (index: $0, track: tracks[$0]) }, id: \.track.id) { row in
        TrackHeaderView(
          model: model, track: row.track, number: numbers[row.track.id] ?? row.index + 1,
          isSelected: model.selectedTrackIDs.contains(row.track.id), stackRole: stackRole(of: row.track),
          freezeProgress: model.freezeProgress[row.track.id], playsMIDIInput: liveMIDITrackIDs.contains(row.track.id),
          height: model.trackHeight
        )
        .equatable()
        .offset(y: CGFloat(row.index) * model.rowHeight)
        // The automation strip's header: which parameter it shows and the mode.
        if model.isAutomationVisible {
          AutomationStripHeader(model: model, track: row.track)
            .offset(y: CGFloat(row.index) * model.rowHeight + model.trackHeight)
        }
      }
    }
    .frame(height: height, alignment: .top)
    .coordinateSpace(.named(Self.coordinateSpace))
    // Where a dragged track header would land.
    .overlay(alignment: .topLeading) {
      if let drag = model.trackDrag {
        Rectangle()
          .fill(Theme.accent)
          .frame(height: 2)
          .offset(y: CGFloat(drag.row) * model.rowHeight - 1)
          .allowsHitTesting(false)
      }
    }
    .frame(width: model.headerWidth)
    .background(Theme.panel)
    .overlay(alignment: .trailing) {
      Rectangle().fill(Theme.separator).frame(width: 1)
    }
    .overlay(alignment: .trailing) {
      HeaderResizeHandle(model: model)
    }
  }
}

extension TrackHeadersColumn {
  static let coordinateSpace = "track-headers"

  private func stackRole(of track: Track) -> TrackHeaderView.StackRole {
    if track.isStack { return .stack(isCollapsed: model.isStackCollapsed(track.id)) }
    return track.stackID == nil ? .none : .subtrack
  }
}

/// The kinds of new track, for the New Track button and the tracks' context menus.
/// `prepare` runs first, to choose where the track goes (new tracks follow the selected one).
struct NewTrackMenuItems: View {
  let model: ProjectWindowModel
  var prepare: () -> Void = {}

  var body: some View {
    Button("Audio") { add { model.addTrack(.audio) } }
    Button("Software Instrument") { add { model.addTrack(.softwareInstrument) } }
    Button("Aux") { add { model.addTrack(.aux) } }
    Divider()
    Button("Drummer") { add { model.addDrummerTrack() } }
    Button("Drummer (Drum Machine)") { add { model.addDrummerTrack(style: .electronic, kit: .drumMachine) } }
    Button("Bass Player") { add { model.addPlayerTrack(.bass) } }
    Button("Keyboard Player") { add { model.addPlayerTrack(.keys) } }
  }

  private func add(_ action: () -> Void) {
    prepare()
    action()
  }
}

/// The track headers' right edge: drag it to make the headers wider or narrower.
/// Double-clicking returns them to their default width.
struct HeaderResizeHandle: View {
  let model: ProjectWindowModel

  @State private var startWidth: CGFloat?

  var body: some View {
    Color.clear
      .frame(width: 6)
      .contentShape(.rect)
      .pointerStyle(.frameResize(position: .trailing))
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { drag in
            let start = startWidth ?? model.headerWidth
            startWidth = start
            let range = ProjectWindowModel.Layout.headerWidthRange
            model.headerWidth = min(max(start + drag.translation.width, range.lowerBound), range.upperBound)
          }
          .onEnded { _ in startWidth = nil }
      )
      .onTapGesture(count: 2) { model.headerWidth = ProjectWindowModel.Layout.defaultHeaderWidth }
      .help("Drag to resize the track headers")
      .accessibilityElement()
      .accessibilityLabel("Track Header Width")
      .accessibilityValue("\(Int(model.headerWidth)) points")
      .accessibilityIdentifier("header-resize-handle")
      .accessibilityAdjustableAction { direction in
        let range = ProjectWindowModel.Layout.headerWidthRange
        let step: CGFloat = direction == .increment ? 20 : -20
        model.headerWidth = min(max(model.headerWidth + step, range.lowerBound), range.upperBound)
      }
  }
}

/// A Logic-style track header: number, colour stripe, icon, name and instrument, and the
/// mute, solo and record buttons. A summing stack has a disclosure triangle and its
/// subtracks are indented under it.
private struct TrackHeaderView: View, Equatable {
  nonisolated enum StackRole: Equatable {
    case none
    case stack(isCollapsed: Bool)
    case subtrack
  }

  let model: ProjectWindowModel
  let track: Track
  let number: Int
  let isSelected: Bool
  let stackRole: StackRole
  /// How far a freeze has got, while the track is being frozen.
  let freezeProgress: Double?
  /// Whether MIDI keyboards play this track (see `ProjectWindowModel.liveMIDITrackIDs`).
  let playsMIDIInput: Bool
  /// The lane's height (vertical zoom).
  let height: CGFloat

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.track == rhs.track && lhs.number == rhs.number && lhs.isSelected == rhs.isSelected && lhs.stackRole == rhs.stackRole
      && lhs.freezeProgress == rhs.freezeProgress && lhs.playsMIDIInput == rhs.playsMIDIInput && lhs.height == rhs.height
  }

  private static let disclosureWidth: CGFloat = 16

  @State private var isRenaming = false
  @State private var name = ""
  @FocusState private var isNameFieldFocused: Bool

  var body: some View {
    HStack(spacing: 0) {
      Text("\(number)")
        .font(Theme.monospaced(10))
        .foregroundStyle(isSelected ? Theme.text : Theme.tertiaryText)
        .frame(width: 24)

      Rectangle()
        .fill(track.color.color)
        .frame(width: 3)
        .padding(.vertical, 1)

      switch stackRole {
      case .stack(let isCollapsed):
        Button(isCollapsed ? "Expand Stack" : "Collapse Stack", systemImage: isCollapsed ? "chevron.right" : "chevron.down") {
          model.toggleStackCollapsed(track.id)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(Theme.font(10, weight: .bold))
        .foregroundStyle(Theme.secondaryText)
        .frame(width: Self.disclosureWidth)
        .padding(.leading, 4)
        .help(isCollapsed ? "Show the stack’s subtracks" : "Hide the stack’s subtracks")
      case .subtrack:
        // Indented under the stack's disclosure triangle.
        Color.clear.frame(width: Self.disclosureWidth + 4 + 12)
      case .none:
        EmptyView()
      }

      TrackIcon(kind: track.kind, color: track.color.color, symbolName: track.isFolderStack ? "folder" : track.isSummingStack ? "square.stack.3d.up" : nil)
        .padding(.horizontal, 8)

      VStack(alignment: .leading, spacing: 3) {
        if isRenaming {
          TextField("Name", text: $name)
            .textFieldStyle(.roundedBorder)
            .font(Theme.font(12))
            .focused($isNameFieldFocused)
            .onSubmit(commitRename)
            .onExitCommand { isRenaming = false }
            .onChange(of: isNameFieldFocused) { _, isFocused in
              if !isFocused { commitRename() }
            }
        } else {
          HStack(spacing: 4) {
            Text(track.name)
              .font(Theme.font(12, weight: .medium))
              .foregroundStyle(Theme.text)
              .lineLimit(1)
              .onTapGesture(count: 2, perform: beginRename)
            if playsMIDIInput {
              MIDIInputIndicator(isArmed: track.isRecordArmed)
            }
          }
        }
        if track.kind == .softwareInstrument {
          InstrumentMenu(model: model, track: track) {
            Text(track.channel.instrument?.displayName ?? "No Instrument")
              .font(Theme.font(10))
              .foregroundStyle(Theme.secondaryText)
              .lineLimit(1)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 3) {
        if track.canFreeze {
          FreezeButton(isFrozen: track.isFrozen, progress: freezeProgress) { model.toggleFreeze(track.id) }
            // Freeze Mode beside the button that uses it (the Inspector has it too).
            .contextMenu {
              Section("Freeze Mode") {
                ForEach(FreezeMode.allCases, id: \.self) { mode in
                  Toggle(mode.displayName, isOn: Binding(
                    get: { track.freezeMode == mode },
                    set: { _ in if track.freezeMode != mode { model.perform(SetFreezeMode(track.id, to: mode)) } }))
                }
              }
              .disabled(track.isFrozen)
            }
        }
        if track.isHidden {
          // Only shown while hidden tracks are: click to show the track again.
          ChannelButton(label: "H", accessibilityName: "Hidden", isOn: true, onColor: Theme.accent) {
            model.perform(SetTracksHidden([track.id], isHidden: false))
          }
          .help("Hidden: click to show this track again")
        }
        ChannelButton(label: "M", accessibilityName: "Mute", isOn: track.channel.isMuted, onColor: Theme.mute) {
          setChannel(\.isMuted, !track.channel.isMuted, actionName: "Mute")
        }
        .help("Mute")
        ChannelButton(label: "S", accessibilityName: "Solo", isOn: track.channel.isSoloed, onColor: Theme.solo) {
          setChannel(\.isSoloed, !track.channel.isSoloed, actionName: "Solo")
        }
        .help("Solo")
        if track.kind == .audio {
          ChannelButton(label: "I", accessibilityName: "Input Monitoring", isOn: track.isInputMonitored, onColor: Theme.inputMonitor) {
            model.setInputMonitoring(track.id, !track.isInputMonitored)
          }
          .disabled(track.isFrozen)
          .help("Input Monitoring: hear the track’s input through its plug-ins. Use headphones to avoid feedback.")
        }
        if track.kind.canRecord {
          ChannelButton(label: "R", accessibilityName: "Record", isOn: track.isRecordArmed, onColor: Theme.record) {
            model.setRecordArmed(track.id, !track.isRecordArmed)
          }
          .disabled(track.isFrozen)
          .help(track.isFrozen ? "Frozen tracks can’t record" : "Record Enable")
        } else {
          Color.clear.frame(width: 20, height: 17)
        }
      }
      .padding(.trailing, 8)
    }
    .frame(height: height)
    // Narrow headers squeeze the name and instrument; nothing may draw into the lanes.
    .clipped()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityName)
    .accessibilityIdentifier("track-header")
    .background(isSelected ? Theme.headerSelected : Theme.header)
    .opacity(track.isHidden ? 0.55 : 1)
    .overlay(alignment: .bottom) {
      Rectangle().fill(Theme.separator).frame(height: 1)
    }
    .contentShape(.rect)
    .simultaneousGesture(TapGesture().onEnded { model.selectTrack(track.id, modifiers: NSEvent.modifierFlags) })
    // Dragging a header up or down moves the track, as in Logic.
    .gesture(
      DragGesture(minimumDistance: 6, coordinateSpace: .named(TrackHeadersColumn.coordinateSpace))
        .onChanged { value in model.trackDrag = (track.id, model.trackDropRow(at: value.location.y)) }
        .onEnded { value in
          model.trackDrag = nil
          model.moveTrack(track.id, toRow: model.trackDropRow(at: value.location.y))
        })
    .contextMenu {
      // New tracks go after the track clicked (joining its stack, if it's in one).
      Menu("New Track") {
        NewTrackMenuItems(model: model) { model.selectedTrackID = track.id }
      }
      Button("Duplicate Track") {
        model.selectedTrackID = track.id
        model.duplicateSelectedTrack()
      }
      .disabled(track.isStack)
      Button(track.isHidden ? "Show Track" : "Hide Track") {
        model.perform(SetTracksHidden([track.id], isHidden: !track.isHidden))
      }
      Divider()
      Button("Rename Track", action: beginRename)
      stackMenuItems
      if track.canFreeze {
        Button(track.isFrozen ? "Unfreeze Track" : freezeProgress == nil ? "Freeze Track" : "Stop Freezing") {
          model.toggleFreeze(track.id)
        }
      }
      if track.kind == .softwareInstrument {
        InstrumentMenu(model: model, track: track) { Text("Instrument") }
      }
      Menu("Color") {
        ForEach(TrackColor.allCases, id: \.self) { color in
          Button(color.name) {
            model.perform(SetTrackColor(track.id, to: color))
          }
        }
      }
      Divider()
      // Like Logic, deleting from a selected track's menu deletes every selected track.
      let deletesSelection = model.selectedTrackIDs.contains(track.id) && model.selectedTrackIDs.count > 1
      Button(deletesSelection ? "Delete Tracks" : "Delete Track", role: .destructive) {
        if deletesSelection {
          model.deleteSelectedTracks()
        } else {
          model.perform(DeleteTracks([track.id]))
        }
      }
    }
  }

  private var accessibilityName: String {
    let name = switch stackRole {
    case .stack: "\(track.name), \(track.isFolderStack ? "folder" : "summing") stack"
    case .subtrack: "\(track.name), \(track.kind.displayName) track in a stack"
    case .none: "\(track.name), \(track.kind.displayName) track"
    }
    return track.isFrozen ? "\(name), frozen" : name
  }

  /// Create Folder or Summing Stack for the selection (including this track), or Flatten Stack.
  @ViewBuilder private var stackMenuItems: some View {
    if track.isStack || track.stackID != nil {
      Button("Flatten Stack") { model.flattenStack(track.isStack ? track.id : track.stackID ?? track.id) }
    } else {
      Button("Create Folder Stack") {
        if !model.selectedTrackIDs.contains(track.id) {
          model.selectedTrackID = track.id
        }
        model.createStack(folder: true)
      }
      .disabled(!model.canCreateSummingStack && model.selectedTrackIDs.contains(track.id))
      Button("Create Summing Stack") {
        if !model.selectedTrackIDs.contains(track.id) {
          model.selectedTrackID = track.id
        }
        model.createStack(folder: false)
      }
      .disabled(!model.canCreateSummingStack && model.selectedTrackIDs.contains(track.id))
    }
  }

  private func beginRename() {
    name = track.name
    isRenaming = true
    isNameFieldFocused = true
  }

  private func commitRename() {
    guard isRenaming else { return }
    isRenaming = false
    if name != track.name {
      model.perform(RenameTrack(track.id, to: name))
    }
  }

  /// Mute and solo carry to the track's mixer group.
  private func setChannel(_ keyPath: WritableKeyPath<ChannelStrip, Bool>, _ value: Bool, actionName: String) {
    model.setChannel(track.id, actionName: actionName) { $0[keyPath: keyPath] = value }
  }
}

/// Logic's Freeze button: a snowflake, lit while the track is frozen. While the freeze
/// renders it shows the progress, and clicking it stops the freeze.
private struct FreezeButton: View {
  let isFrozen: Bool
  let progress: Double?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      ZStack {
        if let progress {
          ProgressView(value: progress)
            .progressViewStyle(.circular)
            .controlSize(.mini)
            .tint(Theme.freeze)
        } else {
          Image(systemName: "snowflake")
            .font(Theme.font(10, weight: .bold))
        }
      }
      .frame(width: 20, height: 17)
      .foregroundStyle(isFrozen ? Color.black.opacity(0.85) : Theme.secondaryText)
      .background(isFrozen ? Theme.freeze : Theme.raised, in: .rect(cornerRadius: 3))
      .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.35)))
    }
    .buttonStyle(.plain)
    .help(progress != nil ? "Freezing… Click to stop" : isFrozen ? "Unfreeze" : "Freeze. Control-click for Freeze Mode")
    .accessibilityLabel("Freeze")
    .accessibilityValue(progress.map { "Freezing, \(Int($0 * 100)) percent" } ?? (isFrozen ? "On" : "Off"))
    .accessibilityIdentifier("freeze")
  }
}

/// A small keyboard beside the name of each track MIDI keyboards play, so it's clear which
/// one a keyboard will sound (several when more than one is record-enabled).
private struct MIDIInputIndicator: View {
  let isArmed: Bool

  var body: some View {
    Image(systemName: "pianokeys")
      .font(Theme.font(9, weight: .semibold))
      .foregroundStyle(Theme.accent)
      .fixedSize()
      .help(isArmed
        ? "MIDI keyboards play this track, as it’s record-enabled. Every record-enabled instrument track plays together."
        : "MIDI keyboards play this track, as it’s selected. Record-enable instrument tracks to play those instead.")
      .accessibilityLabel("Plays MIDI input")
      .accessibilityIdentifier("midi-input-indicator")
  }
}

/// The track's icon on a tile of its colour, like Logic's track icons.
private struct TrackIcon: View {
  let kind: TrackKind
  let color: Color
  /// Instead of the kind's symbol (a summing stack's, say).
  var symbolName: String?

  var body: some View {
    Image(systemName: symbolName ?? kind.symbolName)
      .font(Theme.font(14, weight: .medium))
      .foregroundStyle(color)
      .frame(width: 30, height: 30)
      .background(color.opacity(0.16), in: .rect(cornerRadius: 6))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.35)))
  }
}

/// Chooses a track's instrument: a General MIDI program, the drum kit or an installed
/// Audio Unit. For Audio Units it can also open the plug-in's window.
struct InstrumentMenu<Label: View>: View {
  let model: ProjectWindowModel
  let track: Track
  @ViewBuilder let label: () -> Label

  var body: some View {
    Menu {
      if case .audioUnit = track.channel.instrument {
        Button("Show Instrument Window…") { model.showInstrumentWindow(for: track.id) }
        Divider()
      }
      Section("Ongaku") {
        ForEach(InstrumentLibrary.ongakuInstruments()) { entry in
          Toggle(entry.name, isOn: Binding(
            get: {
              guard case .audioUnit(let plugin) = track.channel.instrument else { return false }
              return plugin.componentManufacturer == entry.componentManufacturer && plugin.componentSubType == entry.componentSubType
            },
            set: { _ in model.setInstrument(.audioUnit(entry.makeReference()), for: track.id) }))
        }
      }
      Menu("General MIDI") {
        ForEach(GeneralMIDI.families) { family in
          Menu(family.name) {
            ForEach(family.programs, id: \.self) { program in
              Toggle(GeneralMIDI.programName(program), isOn: Binding(
                get: { track.channel.instrument == .generalMIDI(program: program) },
                set: { _ in model.setInstrument(.generalMIDI(program: program), for: track.id) }))
            }
          }
        }
      }
      Menu("Drum Kits") {
        ForEach(GeneralMIDI.drumKits, id: \.kit) { kit in
          Toggle(kit.name, isOn: Binding(
            get: { track.channel.instrument == .generalMIDIPercussion(kit: kit.kit) },
            set: { _ in model.setInstrument(.generalMIDIPercussion(kit: kit.kit), for: track.id) }))
        }
      }
      Menu("Audio Units") {
        AudioUnitMenuItems(entries: model.audioUnitInstruments, emptyMessage: "No Audio Unit instruments are installed") { entry in
          model.setInstrument(.audioUnit(entry.makeReference()), for: track.id)
        }
      }
      let outputs = model.engine.extraInstrumentOutputNames(forTrack: track.id)
      if !outputs.isEmpty {
        Divider()
        // A multi-output instrument (a drum kit, say): each output on its own channel strip.
        Button("Add Aux for Each Output (\(outputs.count))") {
          model.perform(AddInstrumentOutputs(of: track.id, outputNames: outputs))
        }
      }
    } label: {
      label()
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    // Not fixed-size: a long name (Audio Units show "Maker: Name") truncates to the space
    // it's given rather than spilling out of the track header or channel strip.
    .accessibilityLabel("Instrument")
    .accessibilityValue(track.channel.instrument?.displayName ?? "None")
    .accessibilityIdentifier("instrument-menu")
  }
}

extension TrackKind {
  /// The SF Symbol shown on track headers.
  var symbolName: String {
    switch self {
    case .softwareInstrument: "pianokeys"
    case .audio: "waveform"
    case .aux: "arrow.triangle.merge"
    }
  }
}
