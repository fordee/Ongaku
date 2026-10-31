//
//  MixerView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// Logic's Mixer: a channel strip for every track, and Stereo Out on the right.
struct MixerView: View {
  let model: ProjectWindowModel

  @State private var stripAreaHeight: CGFloat = 0

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Mixer", symbol: "slider.vertical.3", closeTitle: "Close Mixer") { model.bottomPane = nil }
      HStack(spacing: 0) {
        // Strips fill the pane's height, with the faders taking up the slack; when inserts
        // and sends make them taller than the pane, it scrolls vertically too.
        ScrollView([.horizontal, .vertical]) {
          // Lazy, so a 100-track mixer only builds the strips near the visible ones.
          let auxes = model.project.tracks.filter { $0.kind == .aux }.map { AuxDestination(id: $0.id, name: $0.name) }
          LazyHStack(spacing: 1) {
            ForEach(model.project.tracks) { track in
              ChannelStripView(
                model: model, track: track, isSelected: model.selectedTrackIDs.contains(track.id),
                sendDestinations: model.sendDestinations(for: track.id).map { AuxDestination(id: $0.id, name: $0.name) },
                outputDestinations: model.outputDestinations(for: track.id).map { AuxDestination(id: $0.id, name: $0.name) },
                auxes: auxes
              )
              .equatable()
              // Every strip gets an exact height, so each one fills the pane after a resize
              // (a lazy stack under a vertical scroll view otherwise keeps the heights it
              // measured before), and the strips stay level with each other.
              .frame(height: max(stripAreaHeight, smallestStripHeight))
            }
          }
          .background(Theme.separator)
        }
        .background(Theme.lanes)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stripAreaHeight = $0 }
        PanelSeparator()
        MasterStripView(model: model)
      }
    }
    .background(Theme.window)
    .background { MixerSizer(model: model) }
    // A container, so the Mixer's strips can be told apart from the Inspector's.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("mixer")
  }

  /// The tallest strip's height with its fader at the smallest: below this the strips
  /// scroll vertically instead of shrinking.
  private var smallestStripHeight: CGFloat {
    guard let ideal = model.mixerIdealHeight else { return 0 }
    let faderGrowth = ChannelStripView.faderHeight.upperBound - ChannelStripView.faderHeight.lowerBound
    return ideal - paneHeaderHeight - faderGrowth
  }
}

/// Measures how tall the mixer must be to show its tallest strip whole, with full-size
/// faders, so the pane can open at that height. The tallest strip is the one with the most
/// insert and send slots; an invisible copy of it is laid out at its natural size, where
/// its fader is at the smallest.
private struct MixerSizer: View {
  let model: ProjectWindowModel

  var body: some View {
    if let tallest = model.project.tracks.max(by: { Self.slotCount($0) < Self.slotCount($1) }) {
      ChannelStripView(model: model, track: tallest, isSelected: false, sendDestinations: [], outputDestinations: [], auxes: [])
        .fixedSize()
        .hidden()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stripHeight in
          let faderGrowth = ChannelStripView.faderHeight.upperBound - ChannelStripView.faderHeight.lowerBound
          model.mixerIdealHeight = paneHeaderHeight + stripHeight + faderGrowth
        }
    }
  }

  /// Insert and send slots, including the empty ones for adding another.
  private static func slotCount(_ track: Track) -> Int {
    let inserts = track.channel.inserts.count
    let midiEffects = track.kind == .softwareInstrument ? track.channel.midiEffects.count + 1 : 0
    return inserts + (inserts < ChannelStrip.maximumInserts ? 1 : 0) + track.channel.sends.count + 1 + midiEffects
  }
}

/// One track's channel strip, top to bottom like Logic's: input or instrument, inserts,
/// sends, pan, fader and meter, mute/solo/record, and the name.
struct ChannelStripView: View, Equatable {
  let model: ProjectWindowModel
  let track: Track
  /// The Mixer tints the selected tracks' strips; the Inspector, which only ever shows the
  /// selected track, passes `false`.
  var isSelected: Bool
  /// The auxes this strip can add a send to.
  var sendDestinations: [AuxDestination]
  /// The auxes (and summing stacks) this strip can output to instead of Stereo Out.
  var outputDestinations: [AuxDestination]
  /// Every aux, for naming existing sends.
  var auxes: [AuxDestination]

  /// Everything the strip shows comes from these (and the strip's own automated values), so
  /// editing one track doesn't redraw every other strip.
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.track == rhs.track && lhs.isSelected == rhs.isSelected && lhs.sendDestinations == rhs.sendDestinations
      && lhs.outputDestinations == rhs.outputDestinations && lhs.auxes == rhs.auxes
  }

  static let width: CGFloat = 100
  /// The fader and meter: up to 200 points tall, like Logic's, shrinking to 120 when the
  /// pane is short.
  static let faderHeight: ClosedRange<CGFloat> = 120...200

  var body: some View {
    VStack(spacing: 6) {
      // As in Logic, MIDI effects sit above the instrument they play.
      if track.kind == .softwareInstrument {
        StripSection("MIDI FX") {
          ForEach(track.channel.midiEffects) { effect in
            MIDIEffectSlot(model: model, track: track, effect: effect)
          }
          .disabled(track.isFrozen)
          if track.channel.midiEffects.count < MIDIEffect.maximumCount, !track.isFrozen {
            AddMIDIEffectMenu(model: model, track: track)
          }
        }
      }
      SourceSlot(model: model, track: track)

      // A track frozen Pre Fader has its inserts rendered into the freeze file.
      let insertsFrozen = track.isFrozen && track.freezesInserts
      StripSection("Audio FX") {
        ForEach(track.channel.inserts) { plugin in
          InsertSlot(model: model, channelID: track.id, inserts: track.channel.inserts, plugin: plugin)
        }
        .disabled(insertsFrozen)
        if track.channel.inserts.count < ChannelStrip.maximumInserts, !insertsFrozen {
          AddInsertMenu(model: model, channelID: track.id)
        }
      }

      StripSection("Sends") {
        ForEach(track.channel.sends) { send in
          SendSlot(
            model: model, track: track, send: send,
            destinationName: auxes.first { $0.id == send.destinationTrackID }?.name ?? "Missing")
        }
        AddSendMenu(model: model, track: track, destinations: sendDestinations)
      }

      // As in Logic, extra height goes to the slot area; the fader section below keeps
      // its size and sits at the bottom of the strip.
      Spacer(minLength: 0)

      StripSection("Output") {
        OutputMenu(model: model, track: track, destinations: outputDestinations, auxes: auxes)
      }
      GroupSlot(model: model, track: track)
      AutomationModeSlot(model: model, track: track)

      StripControls(model: model, track: track)
        .equatable()

      // Audio strips fit a fourth button, Input Monitoring, in the same width.
      let buttonSize = CGSize(width: track.kind == .audio ? 19 : 24, height: 18)
      HStack(spacing: 3) {
        ChannelButton(label: "M", accessibilityName: "Mute", isOn: track.channel.isMuted, onColor: Theme.mute, size: buttonSize) {
          model.setChannel(track.id, actionName: "Mute") { $0.isMuted.toggle() }
        }
        ChannelButton(label: "S", accessibilityName: "Solo", isOn: track.channel.isSoloed, onColor: Theme.solo, size: buttonSize) {
          model.setChannel(track.id, actionName: "Solo") { $0.isSoloed.toggle() }
        }
        if track.kind == .audio {
          ChannelButton(label: "I", accessibilityName: "Input Monitoring", isOn: track.isInputMonitored, onColor: Theme.inputMonitor, size: buttonSize) {
            model.setInputMonitoring(track.id, !track.isInputMonitored)
          }
          .disabled(track.isFrozen)
          .help("Input Monitoring: hear the track’s input through its plug-ins. Use headphones to avoid feedback.")
        }
        if track.kind.canRecord {
          ChannelButton(label: "R", accessibilityName: "Record Enable", isOn: track.isRecordArmed, onColor: Theme.record, size: buttonSize) {
            model.setRecordArmed(track.id, !track.isRecordArmed)
          }
          .disabled(track.isFrozen)
        }
      }

      StripName(name: track.name, color: track.color.color)
    }
    .padding(6)
    .frame(width: Self.width)
    .background(isSelected ? Theme.header.mix(with: Theme.accent, by: 0.12) : Theme.panel)
    .contentShape(.rect)
    // Shift- and Command-click select more tracks, as on the track headers (for New Group
    // with Selected Tracks, say).
    .onTapGesture { model.selectTrack(track.id, modifiers: NSEvent.modifierFlags) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(track.name) channel strip")
    .accessibilityIdentifier("channel-strip")
  }
}

/// Pan, the level readout, the fader and the meter. Separate from the rest of the strip
/// because these follow automation during playback: only this part redraws as they move.
private struct StripControls: View, Equatable {
  let model: ProjectWindowModel
  let track: Track

  @State private var pan: Double?

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.track.channel == rhs.track.channel && lhs.track.automation == rhs.track.automation
      && lhs.track.automationMode == rhs.track.automationMode && lhs.track.id == rhs.track.id
  }

  var body: some View {
    VStack(spacing: 6) {
      // Both controls follow automation during playback; moving them by hand in Touch or
      // Latch records automation instead of changing the strip's setting.
      let volume = model.displayedValue(of: .volume, on: track)
      HStack(alignment: .center, spacing: 6) {
        Knob(
          value: pan ?? model.displayedValue(of: .pan, on: track), range: ChannelStrip.panRange,
          isBipolar: true, size: 30, label: "Pan", valueText: { AutomationScale.label($0, for: .pan) }
        ) { value in
          pan = value
          model.controlChanged(.pan, to: value, on: track.id)
        } onCommit: { value in
          if !model.controlReleased(.pan, on: track.id) {
            model.setChannel(track.id, actionName: "Pan") { $0.pan = value }
          }
          pan = nil
        }
        Text(FaderScale.label(volume))
          .font(Theme.monospaced(10))
          .foregroundStyle(Theme.text)
          .frame(maxWidth: .infinity)
          .frame(height: 17)
          .background(Color.black.opacity(0.4), in: .rect(cornerRadius: 3))
          .accessibilityIdentifier("volume-readout")
      }

      HStack(spacing: 6) {
        FaderView(decibels: volume) { value in
          model.controlChanged(.volume, to: value, on: track.id)
        } onCommit: { value in
          if !model.controlReleased(.volume, on: track.id) {
            model.setChannel(track.id, actionName: "Volume") { $0.volume = value }
          }
        }
        MeterView(level: model.meterLevel(for: track.id))
          .frame(width: 10)
          .padding(.vertical, 13)
      }
      .frame(minHeight: ChannelStripView.faderHeight.lowerBound, maxHeight: ChannelStripView.faderHeight.upperBound)
    }
  }
}

/// Opens Ongaku Mastering, putting it on Stereo Out if it isn't there yet.
private struct MasterButton: View {
  let model: ProjectWindowModel

  var body: some View {
    // Not lit when Mastering is on: its own slot above already shows that, and a lit
    // "Master…" read like a second, cut-off copy of the plug-in's name.
    Button {
      model.showMastering()
    } label: {
      ThemeSlot { Text("Master Song") }
    }
    .buttonStyle(.plain)
    .help(model.stereoOutMastering == nil
      ? "Put Ongaku Mastering on Stereo Out and open it, to finish the song for release"
      : "Open Ongaku Mastering")
    .accessibilityLabel("Mastering")
    .accessibilityIdentifier("stereo-out-mastering")
  }
}

/// Stereo Out: the master fader and meter.
struct MasterStripView: View {
  let model: ProjectWindowModel

  var body: some View {
    VStack(spacing: 6) {
      // The same rows as a track strip with empty slots, so the faders line up side by side.
      ThemeSlot { Text("Stereo Out") }
      // Plug-ins here process the whole mix, before the fader: the place for mastering.
      StripSection("Audio FX") {
        ForEach(model.project.stereoOutInserts) { plugin in
          InsertSlot(model: model, channelID: Project.stereoOutID, inserts: model.project.stereoOutInserts, plugin: plugin)
        }
        if model.project.stereoOutInserts.count < ChannelStrip.maximumInserts {
          AddInsertMenu(model: model, channelID: Project.stereoOutID)
        }
      }
      StripSection("Sends") { ThemeSlot { Text(" ") } }
      Spacer(minLength: 0)
      StripSection("Output") { ThemeSlot { Text("Output 1–2") } }
      MasterButton(model: model)
      HStack(spacing: 6) {
        Color.clear.frame(width: 30, height: 30)
        Text(FaderScale.label(model.project.masterVolume))
          .font(Theme.monospaced(10))
          .foregroundStyle(Theme.text)
          .frame(maxWidth: .infinity)
          .frame(height: 17)
          .background(Color.black.opacity(0.4), in: .rect(cornerRadius: 3))
      }
      HStack(spacing: 6) {
        FaderView(decibels: model.project.masterVolume) { value in
          model.engine.setLiveMasterVolume(value)
        } onCommit: { value in
          model.perform(SetMasterVolume(value))
        }
        MeterView(level: model.meterLevel(for: LevelMeters.masterID))
          .frame(width: 10)
          .padding(.vertical, 13)
      }
      .frame(minHeight: ChannelStripView.faderHeight.lowerBound, maxHeight: ChannelStripView.faderHeight.upperBound)
      // Lines up with the mute, solo and record buttons on the track strips.
      Color.clear.frame(height: 18)
      StripName(name: "Stereo Out", color: TrackColor.gray.color)
    }
    .padding(6)
    .frame(width: ChannelStripView.width)
    .background(Theme.panel)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Stereo Out channel strip")
    .accessibilityIdentifier("master-strip")
  }
}

// MARK: - Strip parts

private struct StripSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.content = content
  }

  var body: some View {
    VStack(spacing: 3) {
      PanelHeading(title)
      content()
    }
  }
}

/// A slot-shaped menu button, like the plug-in slots on Logic's channel strips.
private struct SlotLabel: View {
  let title: String
  var isDimmed = false
  var isEmpty = false

  var body: some View {
    ThemeSlot(isActive: !isEmpty && !isDimmed) {
      Text(title)
    }
    // A fixed width: menus size to their label, so long names would overflow the strip.
    .frame(width: ChannelStripView.width - 12)
  }
}

/// The input (audio), instrument (software instrument) or "Aux" slot at the top.
private struct SourceSlot: View {
  let model: ProjectWindowModel
  let track: Track

  var body: some View {
    // A frozen track's source is rendered into its freeze file.
    Group {
      source
    }
    .disabled(track.isFrozen)
  }

  @ViewBuilder private var source: some View {
    switch track.kind {
    case .audio:
      Menu {
        let current = track.channel.audioInput ?? .defaultInput
        Section("Mono") {
          ForEach(0..<8, id: \.self) { channel in
            let input = AudioInputSelection(firstChannel: channel, isStereo: false)
            Toggle(input.displayName, isOn: Binding(get: { current == input }, set: { _ in setInput(input) }))
          }
        }
        Section("Stereo") {
          ForEach(Array(stride(from: 0, to: 8, by: 2)), id: \.self) { channel in
            let input = AudioInputSelection(firstChannel: channel, isStereo: true)
            Toggle(input.displayName, isOn: Binding(get: { current == input }, set: { _ in setInput(input) }))
          }
        }
      } label: {
        SlotLabel(title: (track.channel.audioInput ?? .defaultInput).displayName)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .accessibilityLabel("Input")
    case .softwareInstrument:
      InstrumentMenu(model: model, track: track) {
        SlotLabel(title: track.channel.instrument?.displayName ?? "No Instrument")
      }
    case .aux:
      SlotLabel(title: "Aux", isDimmed: true)
    }
  }

  private func setInput(_ input: AudioInputSelection) {
    model.perform(SetAudioInput(input, for: track.id))
  }
}

/// An insert on a strip, like a MIDI effect's slot: click it to open its window; its menu
/// (hold, or Control-click) bypasses, moves or removes it. `channelID` is the track's, or
/// `Project.stereoOutID`.
private struct InsertSlot: View {
  let model: ProjectWindowModel
  let channelID: Track.ID
  let inserts: [PluginReference]
  let plugin: PluginReference

  var body: some View {
    Menu {
      menuItems
    } label: {
      SlotLabel(title: plugin.name, isDimmed: plugin.isBypassed)
    } primaryAction: {
      model.showInsertWindow(plugin.id, on: channelID)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .contextMenu { menuItems }
    .help("Click to open; hold for more")
    .accessibilityLabel("Insert \(plugin.name)\(plugin.isBypassed ? ", bypassed" : "")")
    .accessibilityIdentifier("insert-slot")
  }

  @ViewBuilder private var menuItems: some View {
    let index = inserts.firstIndex { $0.id == plugin.id } ?? 0
    Button("Show Plug-in Window…") { model.showInsertWindow(plugin.id, on: channelID) }
    Toggle("Bypass", isOn: Binding(
      get: { plugin.isBypassed },
      set: { model.perform(SetInsertBypassed(plugin.id, in: channelID, isBypassed: $0)) }))
    Divider()
    Button("Move Up") { model.perform(MoveInsert(plugin.id, in: channelID, to: index - 1)) }
      .disabled(index == 0)
    Button("Move Down") { model.perform(MoveInsert(plugin.id, in: channelID, to: index + 1)) }
      .disabled(index == inserts.count - 1)
    Divider()
    Button("Remove", role: .destructive) { model.removeInsert(plugin.id, from: channelID) }
  }
}

/// A MIDI effect on the strip: click it to edit it; its menu (hold, or Control-click)
/// bypasses, moves or removes it.
private struct MIDIEffectSlot: View {
  let model: ProjectWindowModel
  let track: Track
  let effect: MIDIEffect

  @State private var isEditing = false

  var body: some View {
    Menu {
      menuItems
    } label: {
      SlotLabel(title: effect.name, isDimmed: effect.isBypassed)
    } primaryAction: {
      isEditing = true
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .contextMenu { menuItems }
    .popover(isPresented: $isEditing, arrowEdge: .trailing) {
      MIDIEffectEditor(model: model, trackID: track.id, effect: effect)
    }
    .help("Click to edit; hold for more")
    .accessibilityLabel("MIDI effect \(effect.name)\(effect.isBypassed ? ", bypassed" : "")")
    .accessibilityIdentifier("midi-effect-slot")
  }

  @ViewBuilder private var menuItems: some View {
    let index = track.channel.midiEffects.firstIndex { $0.id == effect.id } ?? 0
    Button("Edit \(effect.name)…") { isEditing = true }
    Toggle("Bypass", isOn: Binding(
      get: { effect.isBypassed },
      set: { isBypassed in
        var changed = effect
        changed.isBypassed = isBypassed
        model.perform(UpdateMIDIEffect(changed, in: track.id, actionName: isBypassed ? "Bypass MIDI Effect" : "Turn On MIDI Effect"))
      }))
    Divider()
    Button("Move Up") { model.perform(MoveMIDIEffect(effect.id, in: track.id, to: index - 1)) }
      .disabled(index == 0)
    Button("Move Down") { model.perform(MoveMIDIEffect(effect.id, in: track.id, to: index + 1)) }
      .disabled(index == track.channel.midiEffects.count - 1)
    Divider()
    Button("Remove", role: .destructive) { model.perform(RemoveMIDIEffect(effect.id, from: track.id)) }
  }
}

private struct AddMIDIEffectMenu: View {
  let model: ProjectWindowModel
  let track: Track

  var body: some View {
    Menu {
      ForEach(MIDIEffect.Settings.all, id: \.name) { settings in
        Button(settings.name) { model.perform(AddMIDIEffect(MIDIEffect(settings), to: track.id)) }
      }
    } label: {
      SlotLabel(title: "+", isEmpty: true)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .accessibilityLabel("Add MIDI Effect")
    .accessibilityIdentifier("add-midi-effect")
  }
}

/// Adds an insert to a strip. `channelID` is the track's, or `Project.stereoOutID`.
private struct AddInsertMenu: View {
  let model: ProjectWindowModel
  let channelID: Track.ID

  var body: some View {
    Menu {
      Section("Ongaku") {
        ForEach(OngakuEffect.Category.allCases, id: \.self) { category in
          Menu(category.rawValue) {
            ForEach(OngakuEffect.allCases.filter { $0.category == category }, id: \.self) { effect in
              Button(effect.name) { model.addInsert(effect.makeReference(), to: channelID) }
            }
          }
        }
      }
      // Apple's own versions of some of the same effects, so each is named for the Audio
      // Unit it is.
      Section("Apple (built into macOS)") {
        ForEach(BuiltInEffect.allCases, id: \.self) { effect in
          Button {
            model.addInsert(effect.makeReference(), to: channelID)
          } label: {
            Text(effect.name)
            Text("Apple \(effect.audioUnitName)")
          }
        }
      }
      Menu("Audio Units") {
        let effects = model.audioUnitEffects
        if effects.isEmpty {
          Text("No Audio Unit effects are installed")
        }
        ForEach(effects) { entry in
          Button("\(entry.manufacturer): \(entry.name)") { model.addInsert(entry.makeReference(), to: channelID) }
        }
      }
    } label: {
      SlotLabel(title: "+", isEmpty: true)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .accessibilityLabel("Add Insert")
    .accessibilityIdentifier("add-insert")
  }
}

private struct SendSlot: View {
  let model: ProjectWindowModel
  let track: Track
  let send: Send
  let destinationName: String

  @State private var level: Double?

  var body: some View {
    VStack(spacing: 1) {
      Menu {
        Toggle("Pre-Fader", isOn: Binding(get: { send.isPreFader }, set: { isPreFader in
          var updated = send
          updated.isPreFader = isPreFader
          model.perform(UpdateSend(updated, on: track.id))
        }))
        Divider()
        Button("Remove Send", role: .destructive) { model.perform(RemoveSend(send.id, from: track.id)) }
      } label: {
        SlotLabel(title: send.isPreFader ? "\(destinationName) (pre)" : destinationName)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)

      // The knob turns through the fader's taper, so most of its travel is the useful range
      // around 0 dB and the bottom is off. Like the fader and pan, it follows automation and
      // writes it in Touch or Latch.
      let shown = level ?? model.displayedValue(of: .sendLevel(send.id), on: track)
      HStack(spacing: 4) {
        Knob(
          value: FaderScale.position(forDecibels: shown), range: 0...1,
          defaultValue: FaderScale.position(forDecibels: Send.defaultLevel), size: 20, tint: Theme.cycle,
          label: "Send level to \(destinationName)", valueText: { "\(FaderScale.label(FaderScale.decibels(atPosition: $0))) dB" }
        ) { position in
          let value = FaderScale.decibels(atPosition: position)
          level = value
          model.controlChanged(.sendLevel(send.id), to: value, on: track.id)
        } onCommit: { position in
          let value = FaderScale.decibels(atPosition: position)
          if !model.controlReleased(.sendLevel(send.id), on: track.id) {
            var updated = send
            updated.level = value
            model.perform(UpdateSend(updated, on: track.id))
          }
          level = nil
        }
        Text(FaderScale.label(shown))
          .font(Theme.monospaced(9, weight: .regular))
          .foregroundStyle(Theme.secondaryText)
        Spacer(minLength: 0)
      }
    }
  }
}

private struct AddSendMenu: View {
  let model: ProjectWindowModel
  let track: Track
  let destinations: [AuxDestination]

  var body: some View {
    Menu {
      ForEach(destinations) { aux in
        Button(aux.name) { model.addSend(from: track.id, to: aux.id) }
      }
      if track.kind != .aux {
        Divider()
        Button("New Aux") { model.sendToNewAux(from: track.id) }
      }
    } label: {
      SlotLabel(title: "+", isEmpty: true)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .accessibilityLabel("Add Send")
    .accessibilityIdentifier("add-send")
  }
}

/// Where the strip's output goes: Stereo Out or an aux (a subtrack's goes to its summing
/// stack), like Logic's Output slot.
private struct OutputMenu: View {
  let model: ProjectWindowModel
  let track: Track
  let destinations: [AuxDestination]
  let auxes: [AuxDestination]

  var body: some View {
    let current = track.channel.output.trackID.flatMap { id in auxes.first { $0.id == id } }
    Menu {
      Toggle("Stereo Out", isOn: Binding(
        get: { track.channel.output == .stereoOut },
        set: { _ in model.setOutput(of: track.id, to: .stereoOut) }))
      if !destinations.isEmpty {
        Divider()
        ForEach(destinations) { aux in
          Toggle(aux.name, isOn: Binding(
            get: { track.channel.output == .track(aux.id) },
            set: { _ in model.setOutput(of: track.id, to: .track(aux.id)) }))
        }
      }
    } label: {
      ThemeSlot(isActive: current != nil) { Text(current?.name ?? "Stereo Out") }
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .help(track.stackID != nil ? "This subtrack plays through its summing stack" : "Where this track’s output goes")
    .accessibilityLabel("Output")
    .accessibilityValue(current?.name ?? "Stereo Out")
    .accessibilityIdentifier("output-menu")
  }
}

/// An aux track a strip can send to.
nonisolated struct AuxDestination: Identifiable, Equatable {
  var id: Track.ID
  var name: String
}

/// The strip's automation mode, coloured like Logic's (Read green, Touch yellow, Latch
/// purple).
private struct AutomationModeSlot: View {
  let model: ProjectWindowModel
  let track: Track

  var body: some View {
    Menu {
      ForEach(AutomationMode.allCases, id: \.self) { mode in
        Toggle(mode.name, isOn: Binding(
          get: { track.automationMode == mode },
          set: { _ in model.setAutomationMode(mode, for: track.id) }))
      }
    } label: {
      Text(track.automationMode.name)
        .font(Theme.font(10, weight: .medium))
        .foregroundStyle(track.automationMode == .off ? Theme.tertiaryText : Color.black.opacity(0.85))
        .frame(width: ChannelStripView.width - 12, height: 17)
        .background(track.automationMode == .off ? Color.black.opacity(0.28) : track.automationMode.color,
          in: .rect(cornerRadius: 3))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .accessibilityLabel("Automation Mode")
    .accessibilityValue(track.automationMode.name)
  }
}

/// Logic's Group slot: which mixer group the track is in, and that group's settings. Reads
/// the groups itself, so changing a group's settings updates it without redrawing the strip.
private struct GroupSlot: View {
  let model: ProjectWindowModel
  let track: Track

  @State private var renamingGroupID: Int?
  @State private var name = ""

  var body: some View {
    let group = track.groupID.flatMap(model.project.mixerGroup(withID:))
    Menu {
      Toggle("No Group", isOn: Binding(get: { group == nil }, set: { _ in model.assignGroup(nil, to: track.id) }))
      ForEach(model.project.groups) { candidate in
        Toggle("\(candidate.id): \(candidate.name)", isOn: Binding(
          get: { candidate.id == group?.id },
          set: { _ in model.assignGroup(candidate.id, to: track.id) }))
      }
      Divider()
      Button("New Group with Selected Tracks") { model.createGroup(with: track.id) }
      if let group {
        Divider()
        Section("Group \(group.id) Settings") {
          linkToggle("On", group, \.isEnabled)
          linkToggle("Volume", group, \.linksVolume)
          linkToggle("Pan", group, \.linksPan)
          linkToggle("Mute", group, \.linksMute)
          linkToggle("Solo", group, \.linksSolo)
        }
        Button("Rename Group \(group.id)…") {
          name = group.name
          renamingGroupID = group.id
        }
        Button("Delete Group \(group.id)", role: .destructive) { model.perform(DeleteMixerGroup(group.id)) }
      }
    } label: {
      Text(group?.name ?? "Group")
        .font(Theme.font(10, weight: .medium))
        .lineLimit(1)
        .foregroundStyle(group == nil ? Theme.tertiaryText : (group!.isEnabled ? Theme.text : Theme.secondaryText))
        .frame(width: ChannelStripView.width - 12, height: 17)
        .background(group == nil ? Color.black.opacity(0.28) : Theme.raised, in: .rect(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(group?.isEnabled == true ? Theme.accent.opacity(0.7) : .clear))
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .help(group.map { "Group \($0.id): grouped tracks move together" } ?? "Mixer group: grouped tracks move together")
    .accessibilityLabel("Group")
    .accessibilityValue(group.map { "Group \($0.id), \($0.name)" } ?? "None")
    .alert("Rename Group", isPresented: Binding(get: { renamingGroupID != nil }, set: { if !$0 { renamingGroupID = nil } })) {
      TextField("Name", text: $name)
      Button("Rename") {
        if let renamingGroupID { model.renameGroup(renamingGroupID, to: name) }
        renamingGroupID = nil
      }
      Button("Cancel", role: .cancel) { renamingGroupID = nil }
    }
  }

  private func linkToggle(_ title: String, _ group: MixerGroup, _ keyPath: WritableKeyPath<MixerGroup, Bool>) -> some View {
    Toggle(title, isOn: Binding(
      get: { group[keyPath: keyPath] },
      set: { value in model.updateGroup(group.id) { $0[keyPath: keyPath] = value } }))
  }
}

/// The track name at the foot of a channel strip, on the track's colour.
private struct StripName: View {
  let name: String
  let color: Color

  var body: some View {
    Text(name)
      .font(Theme.font(10, weight: .semibold))
      .lineLimit(1)
      .foregroundStyle(Color.black.opacity(0.85))
      .frame(maxWidth: .infinity)
      .frame(height: 18)
      .background(color, in: .rect(cornerRadius: 3))
      .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.4)))
  }
}

/// The height of a bottom pane's title row.
let paneHeaderHeight: CGFloat = 30

/// The title row of a bottom pane (Mixer, Piano Roll), with a close button.
struct PaneHeader<Accessory: View>: View {
  let title: String
  let symbol: String
  let closeTitle: String
  let close: () -> Void
  @ViewBuilder var accessory: () -> Accessory

  init(title: String, symbol: String, closeTitle: String, close: @escaping () -> Void,
    @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
    self.title = title
    self.symbol = symbol
    self.closeTitle = closeTitle
    self.close = close
    self.accessory = accessory
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .font(Theme.font(11))
        .foregroundStyle(Theme.secondaryText)
      Text(title)
        .font(Theme.font(11, weight: .semibold))
        .foregroundStyle(Theme.text)
      accessory()
      Spacer()
      Button(closeTitle, systemImage: "xmark", action: close)
        .buttonStyle(ThemeButtonStyle(width: 22, height: 18))
    }
    .padding(.horizontal, 10)
    .frame(height: paneHeaderHeight)
    .background(LinearGradient(colors: [Theme.controlBarTop, Theme.controlBarBottom], startPoint: .top, endPoint: .bottom))
    .overlay(alignment: .bottom) {
      Rectangle().fill(Theme.separator).frame(height: 1)
    }
  }
}

#Preview {
  let model = ProjectWindowModel(document: OngakuDocument(project: .previewSong))
  MixerView(model: model).frame(width: 760, height: 460)
}
