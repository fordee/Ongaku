//
//  ContentView.swift
//  Ongaku
//
//  Created by John Forde on 21/10/2026.
//

import OngakuCore
import OngakuEngine
import SwiftUI
import UniformTypeIdentifiers

/// The root of a document window. It creates the window model (and with it the playback
/// engine) once, when the window appears.
struct ContentView: View {
  let document: OngakuDocument

  @State private var model: ProjectWindowModel?
  @Environment(\.undoManager) private var undoManager

  var body: some View {
    Group {
      if let model {
        ProjectWindow(model: model)
      } else {
        Color.clear
      }
    }
    .frame(minWidth: 900, minHeight: 500)
    .onAppear {
      if model == nil {
        model = ProjectWindowModel(document: document)
        #if DEBUG
        // The manual's screenshots: the demo song, set up for one scene.
        if let scene = ManualDemo.scene, let model {
          Task { await ManualDemo.setUp(model, for: scene) }
        }
        #endif
      }
      model?.undoManager = undoManager
    }
    .onChange(of: undoManager) { _, undoManager in
      model?.undoManager = undoManager
    }
    .onDisappear {
      model?.engine.shutDown()
    }
  }
}

/// The tracks area, with the mixer or piano roll below it and a divider between them to
/// drag. A pane opens at the height it was last dragged to; until then the mixer opens
/// tall enough to show its strips whole and the piano roll takes half the space.
/// Double-clicking the divider goes back to that default.
///
/// While the divider is dragged, only a guide line moves; the panes resize once, when it's
/// let go. Resizing both on every movement redrew the tracks and the pane continuously,
/// which flickered.
private struct EditingArea: View {
  let model: ProjectWindowModel

  static let minimumTracksHeight: CGFloat = 200
  /// Until the mixer has measured itself: about one plain strip with full-size faders.
  private static let fallbackMixerHeight: CGFloat = 490

  @State private var availableHeight: CGFloat = 0
  /// While the divider is dragged: the height the pane will become.
  @State private var proposedHeight: CGFloat?

  var body: some View {
    VStack(spacing: 0) {
      ArrangeView(model: model)
        .frame(minHeight: Self.minimumTracksHeight)
        .modifier(KeyFocusOutline(isShown: model.bottomPane == .pianoRoll && model.highlightedArea != .pianoRoll))
      if let pane = model.bottomPane {
        PaneDivider()
          .gesture(resizeGesture(for: pane))
          .onTapGesture(count: 2) {
            model.paneHeights[pane] = nil
            model.savePaneHeight(pane)
          }
          // Above the panes either side, so all of its grab area takes the drag.
          .zIndex(1)
        Group {
          switch pane {
          case .pianoRoll: PianoRollView(model: model.pianoRoll)
          case .mixer: MixerView(model: model)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(height: height(of: pane))
        .modifier(KeyFocusOutline(isShown: pane == .pianoRoll && model.highlightedArea == .pianoRoll))
      }
    }
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { availableHeight = $0 }
    .overlay(alignment: .topLeading) {
      if let proposedHeight, let pane = model.bottomPane {
        ResizeGuide(title: pane == .mixer ? "Mixer" : "Editor", height: proposedHeight)
          .offset(y: availableHeight - proposedHeight - PaneDivider.thickness - ResizeGuide.lineThickness / 2)
          .allowsHitTesting(false)
      }
    }
  }

  private func defaultHeight(of pane: ProjectWindowModel.BottomPane) -> CGFloat {
    switch pane {
    case .mixer: model.mixerIdealHeight ?? Self.fallbackMixerHeight
    case .pianoRoll: availableHeight / 2
    }
  }

  /// The pane's height, kept between its minimum and what leaves the tracks area room.
  private func height(of pane: ProjectWindowModel.BottomPane) -> CGFloat {
    clamped(model.paneHeights[pane] ?? defaultHeight(of: pane), for: pane)
  }

  private func clamped(_ height: CGFloat, for pane: ProjectWindowModel.BottomPane) -> CGFloat {
    let maximum = max(pane.minimumHeight, availableHeight - Self.minimumTracksHeight - PaneDivider.thickness)
    return min(max(height, pane.minimumHeight), maximum)
  }

  private func resizeGesture(for pane: ProjectWindowModel.BottomPane) -> some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .global)
      .onChanged { drag in
        // Dragging up makes the pane taller. Only the guide moves for now.
        proposedHeight = clamped(height(of: pane) - drag.translation.height, for: pane)
      }
      .onEnded { _ in
        if let proposedHeight {
          model.paneHeights[pane] = proposedHeight
          model.savePaneHeight(pane)
        }
        proposedHeight = nil
      }
  }
}

/// Where the divider will go, shown while it's dragged: a highlighted line, and the pane's
/// height.
private struct ResizeGuide: View {
  let title: String
  let height: CGFloat

  static let lineThickness: CGFloat = 3

  var body: some View {
    ZStack(alignment: .leading) {
      Rectangle()
        .fill(Color.accentColor)
        .frame(height: Self.lineThickness)
        .shadow(color: .black.opacity(0.5), radius: 2)
      Text("\(title) height \(Int(height.rounded())) pt")
        .font(.system(size: 10, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.accentColor))
        .offset(x: 12, y: -12)
    }
  }
}

/// The line between the tracks area and the pane below, with a taller area to grab.
private struct PaneDivider: View {
  static let thickness: CGFloat = 1

  var body: some View {
    Rectangle()
      .fill(Theme.separator)
      .frame(height: Self.thickness)
      .overlay {
        Color.clear
          .frame(height: 10)
          .contentShape(.rect)
          .pointerStyle(.rowResize)
      }
      .accessibilityElement()
      .accessibilityLabel("Resize pane")
      .accessibilityHint("Drag to change the height of the pane below; double-click to restore its default height.")
  }
}

struct ProjectWindow: View {
  let model: ProjectWindowModel

  @Environment(\.appearsActive) private var appearsActive

  var body: some View {
    VStack(spacing: 0) {
      ControlBar(model: model)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("control-bar")
      HStack(spacing: 0) {
        if model.isInspectorVisible {
          InspectorView(model: model)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inspector")
          PanelSeparator()
        }
        if model.isLibraryVisible {
          LibraryView(model: model)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library")
          PanelSeparator()
        }
        EditingArea(model: model)
      }
    }
    .background(Theme.window)
    // The control bar takes the title bar's place: its title and background are hidden and
    // the content runs up under the window buttons.
    .ignoresSafeArea(.container, edges: .top)
    .toolbar(removing: .title)
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .foregroundStyle(Theme.text)
    .tint(Theme.accent)
    .preferredColorScheme(.dark)
    .background(AutomatedControlsFollower(model: model))
    .task { await model.runMeters() }
    .background(WindowReader { window in
      model.hostWindow = window
      // Also refuse tabs per window, in case a window was restored into a tab group.
      window?.tabbingMode = .disallowed
    })
    .onAppear {
      KeyCommandMonitor.shared.install(for: model)
      AgentServer.shared.register(model)
    }
    .onDisappear {
      KeyCommandMonitor.shared.remove(model)
      AgentServer.shared.unregister(model)
    }
    .focusedSceneValue(\.projectWindow, model)
    .onChange(of: model.project) { model.projectDidChange() }
    // MIDI keyboards play the armed or selected instrument tracks of the frontmost window
    // (arming may change by undo, too).
    .onChange(of: appearsActive, initial: true) {
      if appearsActive { model.connectMIDIInput() }
    }
    .onChange(of: model.liveMIDITrackIDs) {
      if appearsActive { model.connectMIDIInput() }
    }
    // A Latch write runs until the transport stops.
    .onChange(of: model.engine.isPlaying) { _, isPlaying in
      if !isPlaying { model.transportDidStop(at: model.engine.playheadPosition) }
    }
    .onChange(of: model.engine.lastError) { _, error in
      if let error { model.errorMessage = error }
    }
    .fileImporter(
      isPresented: Binding(get: { model.activeImporter != nil }, set: { if !$0 { model.activeImporter = nil } }),
      allowedContentTypes: model.importerKind.allowedContentTypes,
      allowsMultipleSelection: true
    ) { result in
      guard case .success(let urls) = result else { return }
      let position = model.engine.playheadPosition
      let trackID = model.selectedTrackID
      switch model.importerKind {
      case .midi:
        Task { await model.importMIDIFiles(urls, at: position) }
      case .audio:
        // Snapped, as dropped audio is (MIDI files go to the bar either way).
        Task { await model.importAudio(urls, at: model.snap(position), onTrack: trackID) }
      }
    }
    .fileExporter(
      isPresented: Binding(get: { model.isShowingMIDIExporter }, set: { model.isShowingMIDIExporter = $0 }),
      item: model.isShowingMIDIExporter ? model.midiExport() : nil,
      contentTypes: [.midi],
      defaultFilename: model.exportFileName
    ) { result in
      if case .failure(let error) = result {
        model.errorMessage = error.localizedDescription
      }
    }
    .sheet(isPresented: Binding(get: { model.bounce != nil }, set: { if !$0 { model.closeBounce() } })) {
      if let bounce = model.bounce {
        BounceView(model: model, bounce: bounce)
      }
    }
    .sheet(isPresented: Binding(get: { model.songAnalysis != nil }, set: { if !$0 { model.songAnalysis?.cancel() } })) {
      if let analysis = model.songAnalysis {
        SongAnalysisView(model: model, analysis: analysis)
      }
    }
    .alert(
      "Something went wrong",
      isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    ) {
      Button("OK") {}
    } message: {
      Text(model.errorMessage ?? "")
    }
  }
}

/// Keeps automated faders and pan controls in step with the playhead. A separate view so
/// only it reads the playhead, not the whole window.
private struct AutomatedControlsFollower: View {
  let model: ProjectWindowModel

  var body: some View {
    Color.clear
      .onChange(of: model.engine.playheadPosition) { model.refreshAutomatedControls() }
  }
}

/// The dark hairline between side-by-side panels.
struct PanelSeparator: View {
  var body: some View {
    Rectangle().fill(Theme.separator).frame(width: 1)
  }
}

#Preview {
  ContentView(document: OngakuDocument(project: .previewSong))
    .frame(width: 1440, height: 900)
}

extension Project {
  /// A small song for previews: drums, bass, keys, a vocal track and a reverb aux.
  static var previewSong: Project {
    func notes(_ pitches: [Int], every step: Double, length: Double, bars: Int) -> MIDISequence {
      var result: [MIDINote] = []
      var beat = 0.0
      while beat < Double(bars * 4) {
        for (offset, pitch) in pitches.enumerated() {
          result.append(MIDINote(pitch: pitch, velocity: 90 + offset * 5, start: .quarterNotes(beat), length: .quarterNotes(length)))
        }
        beat += step
      }
      return MIDISequence(notes: result)
    }
    func midiRegion(_ name: String, at bar: Int, bars: Int, _ sequence: MIDISequence) -> Region {
      Region(name: name, start: .quarterNotes(Double(bar * 4)), length: .quarterNotes(Double(bars * 4)), content: .midi(sequence))
    }
    var drums = Track(name: "Drums", kind: .softwareInstrument, color: .yellow)
    drums.channel.instrument = .generalMIDIPercussion(kit: 0)
    drums.regions = [midiRegion("Beat", at: 0, bars: 8, notes([36, 42], every: 0.5, length: 0.25, bars: 8))]
    var bass = Track(name: "Bass", kind: .softwareInstrument, color: .orange)
    bass.channel.instrument = .generalMIDI(program: 33)
    bass.regions = [midiRegion("Bass Line", at: 0, bars: 4, notes([40], every: 1, length: 0.75, bars: 4)),
      midiRegion("Bass Line 2", at: 4, bars: 4, notes([43], every: 0.5, length: 0.4, bars: 4))]
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.channel.instrument = .generalMIDI(program: 4)
    keys.regions = [midiRegion("Chords", at: 2, bars: 6, notes([60, 64, 67], every: 2, length: 1.8, bars: 6))]
    let vocals = Track(name: "Vocals", kind: .audio)
    let reverb = Track(name: "Reverb", kind: .aux)
    return Project(tracks: [drums, bass, keys, vocals, reverb])
  }
}

/// Outlines the tracks area or the editor, whichever was clicked last, while both are
/// showing: Delete, the clipboard and the editor's keys act on the outlined one.
private struct KeyFocusOutline: ViewModifier {
  let isShown: Bool

  func body(content: Content) -> some View {
    content.overlay {
      if isShown {
        Rectangle()
          .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5)
          .allowsHitTesting(false)
      }
    }
  }
}
