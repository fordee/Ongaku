//
//  ControlBar.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// Logic's control bar across the top of the window: view buttons on the left, the
/// transport, the LCD in the middle, mode buttons, and zoom and import on the right.
///
/// It replaces the window toolbar and runs under the title bar (whose background and title
/// are hidden), leaving room for the window buttons. Dragging its background moves the window.
struct ControlBar: View {
  let model: ProjectWindowModel

  static let height: CGFloat = 52
  /// Clears the close, minimize and zoom buttons.
  private static let windowButtonsWidth: CGFloat = 78

  var body: some View {
    HStack(spacing: 14) {
      HStack(spacing: 4) {
        ViewToggle(title: "Library", symbol: "books.vertical", shortcut: "Y", isOn: model.isLibraryVisible, action: model.toggleLibrary)
        ViewToggle(title: "Inspector", symbol: "info.circle", shortcut: "I", isOn: model.isInspectorVisible, action: model.toggleInspector)
      }

      TransportControls(model: model)

      Spacer(minLength: 8)
      LCDView(model: model)
      AgentStatusBadge()
      Spacer(minLength: 8)

      HStack(spacing: 4) {
        ModeToggle(title: "Cycle", symbol: "repeat", shortcut: "C", isOn: model.project.cycle.isEnabled, onColor: Theme.cycle, action: model.toggleCycle)
        ModeToggle(title: "Metronome", symbol: "metronome.fill", shortcut: "K", isOn: model.project.isMetronomeEnabled, onColor: Theme.text, action: model.toggleMetronome)
        CountInToggle()
        ModeToggle(title: "Automation", symbol: "point.topleft.down.to.point.bottomright.curvepath", shortcut: "A", isOn: model.isAutomationVisible, onColor: Theme.cycle, action: model.toggleAutomation)
      }

      HStack(spacing: 4) {
        ViewToggle(title: "Mixer", symbol: "slider.vertical.3", shortcut: "X", isOn: model.bottomPane == .mixer, action: model.toggleMixer)
        // It opens whichever editor suits the region: Piano Roll, Step Sequencer, Drummer…
        ViewToggle(title: "Editor", symbol: "pianokeys", shortcut: "E", isOn: model.isEditorVisible, action: model.toggleEditor)
      }

      HStack(spacing: 4) {
        Button("Zoom Out", systemImage: "minus.magnifyingglass") { model.zoom(by: 1 / 1.5) }
          .help("Zoom Out (⌘−)")
        Button("Zoom In", systemImage: "plus.magnifyingglass") { model.zoom(by: 1.5) }
          .help("Zoom In (⌘=)")
        Button("Import Audio", systemImage: "square.and.arrow.down") { model.activeImporter = .audio }
          .help("Import Audio Files… (⇧⌘I)")
      }
      .buttonStyle(ThemeButtonStyle())
    }
    .padding(.leading, Self.windowButtonsWidth)
    .padding(.trailing, 12)
    .frame(height: Self.height)
    .background {
      LinearGradient(colors: [Theme.controlBarTop, Theme.controlBarBottom], startPoint: .top, endPoint: .bottom)
        .gesture(WindowDragGesture())
        .allowsWindowActivationEvents()
    }
    .overlay(alignment: .bottom) {
      Rectangle().fill(Theme.separator).frame(height: 1)
    }
  }
}

/// Shows or hides an area of the window; lit while it's showing.
private struct ViewToggle: View {
  let title: String
  let symbol: String
  let shortcut: String
  let isOn: Bool
  let action: () -> Void

  var body: some View {
    Button(title, systemImage: symbol, action: action)
      .buttonStyle(ThemeButtonStyle(isOn: isOn, onColor: Theme.accent))
      .help("\(title) (\(shortcut))")
      .accessibilityValue(isOn ? "Shown" : "Hidden")
  }
}

/// Cycle, metronome and automation: lit in their own colours while on.
private struct ModeToggle: View {
  let title: String
  let symbol: String
  let shortcut: String
  let isOn: Bool
  let onColor: Color
  let action: () -> Void

  var body: some View {
    Button(title, systemImage: symbol, action: action)
      .buttonStyle(ThemeButtonStyle(isOn: isOn, onColor: onColor))
      .help("\(title) (\(shortcut))")
      .accessibilityValue(isOn ? "On" : "Off")
  }
}

/// Logic's count-in button, lit while recording starts with a count-in. It switches the
/// Recording setting itself: on uses the bars last chosen there (1 if none were), off is
/// none.
private struct CountInToggle: View {
  @AppStorage(AppSettings.countInBarsKey) private var countInBars = 0
  @AppStorage(AppSettings.countInBarsWhenOnKey) private var barsWhenOn = 1

  var body: some View {
    let isOn = countInBars > 0
    let bars = isOn ? countInBars : max(barsWhenOn, 1)
    Button("Count-in", systemImage: "123.rectangle") { countInBars = isOn ? 0 : bars }
      .buttonStyle(ThemeButtonStyle(isOn: isOn, onColor: Theme.text))
      .help("Count-in: \(bars) \(bars == 1 ? "bar" : "bars") of clicks before recording starts. Choose how many in Settings › Recording.")
      .accessibilityValue(isOn ? "On" : "Off")
  }
}

/// Go to beginning, back and forward a bar, play/stop and record, as one group.
private struct TransportControls: View {
  let model: ProjectWindowModel

  var body: some View {
    let isPlaying = model.engine.isPlaying
    let isRecording = model.engine.isRecording
    HStack(spacing: 2) {
      Button("Go to Beginning", systemImage: "backward.end.fill", action: model.goToBeginning)
        .help("Go to Beginning (Return)")
      Button("Back One Bar", systemImage: "backward.fill") { model.moveByBars(-1) }
        .help("Back One Bar (,)")
      Button("Forward One Bar", systemImage: "forward.fill") { model.moveByBars(1) }
        .help("Forward One Bar (.)")
      Button(isPlaying ? "Stop" : "Play", systemImage: isPlaying ? "stop.fill" : "play.fill", action: model.togglePlayback)
        .buttonStyle(ThemeButtonStyle(isOn: true, onColor: isPlaying ? Theme.stop : Theme.play, width: 36))
        .help("Play or Stop (Space)")
      Button(isRecording ? "Stop Recording" : "Record", systemImage: "record.circle.fill", action: model.toggleRecording)
        .buttonStyle(ThemeButtonStyle(isOn: true, onColor: isRecording ? Theme.record : Theme.record.opacity(0.75), width: 36))
        .symbolEffect(.pulse, isActive: isRecording)
        .help("Record (R)")
    }
    .buttonStyle(ThemeButtonStyle())
  }
}

/// Logic's LCD: the playhead position, tempo, time signature and key on a dark display.
private struct LCDView: View {
  let model: ProjectWindowModel

  @AppStorage(AppSettings.lcdColorKey) private var lcdColor = AppSettings.LCDColor.blue

  var body: some View {
    let palette = lcdColor.palette

    HStack(spacing: 0) {
      PositionReadout(model: model)
        .padding(.horizontal, 14)

      LCDDivider()

      TempoField(model: model)

      LCDDivider()
      TimeSignatureMenu(model: model)
      LCDDivider()
      KeySignatureMenu(model: model)
    }
    // Always as wide as its readouts: the spacers beside it would otherwise squeeze the
    // tempo column and hide its caption.
    .fixedSize(horizontal: true, vertical: false)
    .frame(height: 38)
    .padding(LCDScreen.bezelWidth)
    .background(LCDScreen())
    .environment(\.lcdPalette, palette)
  }
}

/// The tempo at the playhead, as on Logic's LCD. Double-click to type a new one: it changes
/// the tempo in effect there (the one at the start of the song, or the latest tempo change
/// on the Tempo track). Separate so only it redraws as the playhead crosses tempo changes.
private struct TempoField: View {
  let model: ProjectWindowModel

  @State private var tempoText = ""
  /// The tempo is shown as text and becomes a field when double-clicked, so the window
  /// never opens with a text field holding the keyboard (which would block the single-key
  /// shortcuts).
  @State private var isEditingTempo = false
  @FocusState private var isTempoFocused: Bool
  @Environment(\.lcdPalette) private var palette

  /// The tempo change in effect at the playhead.
  private var currentChange: TempoMap.TempoChange {
    let tempoMap = model.project.tempoMap
    let playhead = model.engine.playheadPosition
    return tempoMap.tempoChanges.last { $0.position <= playhead } ?? tempoMap.tempoChanges[0]
  }

  var body: some View {
    VStack(spacing: 1) {
      Group {
        if isEditingTempo {
          TextField("Tempo", text: $tempoText)
            .textFieldStyle(.plain)
            .focused($isTempoFocused)
            .onSubmit(commitTempo)
            .onExitCommand { isEditingTempo = false }
            .onChange(of: isTempoFocused) { _, isFocused in
              if !isFocused { isEditingTempo = false }
            }
            .onAppear { isTempoFocused = true }
        } else {
          Text(tempoText)
            .onTapGesture(count: 2) {
              resetTempoText()
              isEditingTempo = true
            }
        }
      }
      .font(Theme.monospaced(19))
      .foregroundStyle(palette.text)
      .lcdGlow()
      .multilineTextAlignment(.center)
      .frame(width: 62)
      .accessibilityLabel("Tempo")
      .accessibilityValue(tempoText)
      LCDCaption("TEMPO")
    }
    .padding(.horizontal, 12)
    .help("Double-click to type a new tempo")
    .onAppear(perform: resetTempoText)
    .onChange(of: currentChange.bpm) { resetTempoText() }
  }

  private func commitTempo() {
    if let bpm = Double(tempoText.trimmingCharacters(in: .whitespaces)) {
      model.perform(SetTempo(bpm, at: currentChange.position))
    }
    isEditingTempo = false
    resetTempoText()
  }

  private func resetTempoText() {
    tempoText = currentChange.bpm.formatted(.number.precision(.fractionLength(0...2)))
  }
}

/// The LCD's hardware, drawn behind its readouts: a screen set into a recessed bezel, with
/// backlit glass, a fine pixel grid and a reflection across the top. Nothing here changes
/// as the playhead moves, so it's drawn once and cached.
private struct LCDScreen: View {
  static let bezelWidth: CGFloat = 3
  private static let screenShape = RoundedRectangle(cornerRadius: 4.5)
  @Environment(\.lcdPalette) private var palette

  var body: some View {
    ZStack {
      // The bezel: darker at the top, where its lip shades the recess.
      RoundedRectangle(cornerRadius: 7.5)
        .fill(LinearGradient(colors: [Theme.lcdBezelTop, Theme.lcdBezelBottom], startPoint: .top, endPoint: .bottom))
        .overlay {
          // Light catching the bottom edge of the recess, and the control bar's surface just
          // above it in shadow.
          RoundedRectangle(cornerRadius: 7.5)
            .strokeBorder(
              LinearGradient(colors: [.black.opacity(0.5), .white.opacity(0.13)], startPoint: .top, endPoint: .bottom),
              lineWidth: 1)
        }

      ZStack {
        // Backlit glass, brightest in the middle where the light sits.
        Self.screenShape
          .fill(LinearGradient(colors: [palette.glassTop, palette.glassBottom], startPoint: .top, endPoint: .bottom))
        EllipticalGradient(colors: [palette.glow.opacity(0.13), .clear], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.6)
        PixelGrid()
        // The glass sits below the bezel, so the bezel casts a shadow onto it.
        Self.screenShape
          .fill(Color.clear.shadow(.inner(color: .black.opacity(0.85), radius: 3, y: 1.5)))
        // A reflection on the glass, across the top half.
        LinearGradient(
          stops: [.init(color: .white.opacity(0.07), location: 0), .init(color: .white.opacity(0.025), location: 0.48), .init(color: .clear, location: 0.5)],
          startPoint: .top, endPoint: .bottom)
      }
      .clipShape(Self.screenShape)
      .padding(Self.bezelWidth)
    }
    .compositingGroup()
    .drawingGroup()
    .accessibilityHidden(true)
  }
}

/// The faint grid between an LCD's pixels.
private struct PixelGrid: View {
  var body: some View {
    Canvas { context, size in
      var lines = Path()
      let pitch: CGFloat = 2
      for x in stride(from: 0, through: size.width, by: pitch) {
        lines.addRect(CGRect(x: x, y: 0, width: 0.5, height: size.height))
      }
      for y in stride(from: 0, through: size.height, by: pitch) {
        lines.addRect(CGRect(x: 0, y: y, width: size.width, height: 0.5))
      }
      context.fill(lines, with: .color(.black.opacity(0.28)))
    }
  }
}

extension View {
  /// Lit LCD characters: they glow a little in the backlight's colour.
  fileprivate func lcdGlow() -> some View {
    modifier(LCDGlow())
  }
}

private struct LCDGlow: ViewModifier {
  @Environment(\.lcdPalette) private var palette

  func body(content: Content) -> some View {
    content.shadow(color: palette.glow.opacity(0.55), radius: 2.5)
  }
}

/// Bar, beat, division and tick. Separate so only it redraws as the playhead moves.
private struct PositionReadout: View {
  let model: ProjectWindowModel

  var body: some View {
    let position = model.project.tempoMap.musicalPosition(at: model.engine.playheadPosition)
    HStack(alignment: .top, spacing: 10) {
      LCDNumber(value: position.bar, caption: "BAR", width: 36)
      LCDNumber(value: position.beat, caption: "BEAT", width: 28)
      LCDNumber(value: position.division, caption: "DIV", width: 24)
      LCDNumber(value: position.tick, caption: "TICK", width: 36)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Position: bar \(position.bar), beat \(position.beat)")
    .accessibilityIdentifier("lcd-position")
  }
}

private struct LCDNumber: View {
  let value: Int
  let caption: String
  let width: CGFloat
  @Environment(\.lcdPalette) private var palette

  var body: some View {
    VStack(spacing: 1) {
      Text("\(value)")
        .font(Theme.monospaced(19))
        .foregroundStyle(palette.text)
        .lcdGlow()
        .frame(width: width, alignment: .trailing)
      LCDCaption(caption)
        .frame(width: width, alignment: .trailing)
    }
  }
}

private struct LCDField: View {
  let value: String
  let caption: String
  @Environment(\.lcdPalette) private var palette

  var body: some View {
    VStack(spacing: 1) {
      Text(value)
        .font(Theme.monospaced(19))
        .foregroundStyle(palette.text)
        .lcdGlow()
      LCDCaption(caption)
    }
    .padding(.horizontal, 12)
  }
}

/// The time signature on the LCD; clicking it offers the common meters, like Logic.
private struct TimeSignatureMenu: View {
  let model: ProjectWindowModel

  var body: some View {
    // The meter in effect at the playhead; choosing another changes that meter change.
    let tempoMap = model.project.tempoMap
    let bar = tempoMap.bar(containing: model.engine.playheadPosition).index
    let change = tempoMap.meterChanges.last { $0.barIndex <= bar } ?? tempoMap.meterChanges[0]
    let current = change.signature
    // A meter from an imported file that isn't in the list still shows as chosen.
    let choices = TimeSignature.common.contains(current) ? TimeSignature.common : [current] + TimeSignature.common
    let selection = Binding(
      get: { current },
      set: { if $0 != current { model.perform(SetTimeSignature($0, atBarIndex: change.barIndex)) } })

    Menu {
      Picker("Time Signature", selection: selection) {
        ForEach(choices, id: \.self) { signature in
          Text(signature.description).tag(signature)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      LCDField(value: current.description, caption: "TIME")
    }
    .lcdMenuStyle()
    .accessibilityLabel("Time Signature")
    .accessibilityValue(current.description)
    .help("Click to choose a time signature")
  }
}

/// The key on the LCD; clicking it offers every major and minor key.
private struct KeySignatureMenu: View {
  let model: ProjectWindowModel

  var body: some View {
    // The key in effect at the playhead; choosing another changes that key (the song's, or
    // a key change's).
    let playhead = model.engine.playheadPosition
    let current = model.project.key(at: playhead)
    let start = model.project.keyStart(at: playhead)
    let selection = Binding(
      get: { current },
      set: { if $0 != current { model.perform(SetKey($0, at: start)) } })

    Menu {
      Picker("Key", selection: selection) {
        ForEach(KeySignature.Mode.allCases, id: \.self) { mode in
          Section(mode == .major ? "Major" : "Minor") {
            ForEach(0..<12, id: \.self) { tonic in
              let key = KeySignature(tonic: tonic, mode: mode)
              Text(key.description).tag(key)
            }
          }
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      LCDField(value: current.description, caption: "KEY")
    }
    .lcdMenuStyle()
    .accessibilityLabel("Key")
    .accessibilityValue(current.description)
    .help("Click to choose a key")
  }
}

extension View {
  /// A menu that looks like the rest of the LCD: no button chrome and no arrow.
  fileprivate func lcdMenuStyle() -> some View {
    menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .contentShape(.rect)
  }
}

private struct LCDCaption: View {
  let text: String
  @Environment(\.lcdPalette) private var palette

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(Theme.font(8, weight: .semibold))
      .tracking(0.5)
      .foregroundStyle(palette.caption)
  }
}

private struct LCDDivider: View {
  @Environment(\.lcdPalette) private var palette

  var body: some View {
    // Engraved into the glass: a dark groove with a lit edge beside it.
    HStack(spacing: 0) {
      Rectangle().fill(Color.black.opacity(0.45))
      Rectangle().fill(palette.glow.opacity(0.1))
    }
    .frame(width: 2, height: 24)
  }
}
