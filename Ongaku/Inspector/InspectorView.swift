//
//  InspectorView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// Logic's Inspector (I): the selected track's details, its channel strip and, beside it,
/// Stereo Out — so the track can be mixed without opening the Mixer.
struct InspectorView: View {
  let model: ProjectWindowModel

  @State private var stripAreaHeight: CGFloat = 0

  static let width: CGFloat = ChannelStripView.width * 2 + 3

  var body: some View {
    VStack(spacing: 0) {
      // Logic shows the Region Inspector above the track's, while regions are selected.
      if let region = model.inspectedRegion {
        RegionInspector(model: model, region: region)
        Rectangle().fill(Theme.separator).frame(height: 1)
      }
      if let track = model.selectedTrack {
        TrackSummary(model: model, track: track)
        if track.canFreeze {
          FreezeModeRow(model: model, track: track)
        }
        if track.kind == .audio {
          FlexModeRow(model: model, track: track)
        }
      } else {
        Text("No Track Selected")
          .font(Theme.font(11, weight: .medium))
          .foregroundStyle(Theme.tertiaryText)
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      Rectangle().fill(Theme.separator).frame(height: 1)

      ScrollView(.vertical) {
        HStack(alignment: .top, spacing: 1) {
          if let track = model.selectedTrack {
            ChannelStripView(
              model: model, track: track, isSelected: false,
              sendDestinations: model.sendDestinations(for: track.id).map { AuxDestination(id: $0.id, name: $0.name) },
              outputDestinations: model.outputDestinations(for: track.id).map { AuxDestination(id: $0.id, name: $0.name) },
              auxes: model.project.tracks.filter { $0.kind == .aux }.map { AuxDestination(id: $0.id, name: $0.name) })
          } else {
            Theme.panel.frame(width: ChannelStripView.width)
          }
          MasterStripView(model: model)
        }
        .frame(minHeight: stripAreaHeight, alignment: .top)
        .background(Theme.separator)
      }
      .scrollIndicators(.never)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stripAreaHeight = $0 }
    }
    .frame(width: Self.width)
    .background(Theme.panel)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Inspector")
  }
}

/// The track's name, kind and colour at the top of the Inspector.
private struct TrackSummary: View {
  let model: ProjectWindowModel
  let track: Track

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: track.kind.symbolName)
        .font(Theme.font(15))
        .foregroundStyle(track.color.color)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 1) {
        Text(track.name)
          .font(Theme.font(12, weight: .semibold))
          .foregroundStyle(Theme.text)
          .lineLimit(1)
        Text(track.kind.displayName)
          .font(Theme.font(10))
          .foregroundStyle(Theme.secondaryText)
      }
      Spacer(minLength: 0)
      Menu {
        ForEach(TrackColor.allCases, id: \.self) { color in
          Button(color.name) { model.perform(SetTrackColor(track.id, to: color)) }
        }
      } label: {
        Circle().fill(track.color.color).frame(width: 12, height: 12)
          .overlay(Circle().strokeBorder(Color.black.opacity(0.4)))
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Track Color")
      .accessibilityLabel("Track Color")
    }
    .padding(.horizontal, 10)
    .frame(height: 44)
  }
}

/// Logic's Freeze Mode: whether freezing renders the inserts too. Fixed while the track is
/// frozen, since the freeze file was rendered one way.
private struct FreezeModeRow: View {
  let model: ProjectWindowModel
  let track: Track

  var body: some View {
    HStack(spacing: 6) {
      Text("Freeze Mode")
        .font(Theme.font(10))
        .foregroundStyle(Theme.secondaryText)
      Spacer(minLength: 0)
      Picker("Freeze Mode", selection: Binding(
        get: { track.freezeMode },
        set: { model.perform(SetFreezeMode(track.id, to: $0)) }
      )) {
        ForEach(FreezeMode.allCases, id: \.self) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      .labelsHidden()
      .controlSize(.small)
      .fixedSize()
      .disabled(track.isFrozen)
      .help(track.isFrozen ? "Unfreeze the track to change its freeze mode" : "What freezing the track renders")
    }
    .padding(.horizontal, 10)
    .padding(.bottom, 6)
  }
}

extension ProjectWindowModel {
  /// The region the Region Inspector shows: the first selected one. Its settings are
  /// shown, and edits apply to every selected region.
  var inspectedRegion: Region? {
    project.tracks.lazy.flatMap(\.regions).first { selectedRegionIDs.contains($0.id) }
  }
}

/// Logic's Region Inspector: how the selected regions play, without changing their notes or
/// audio. Loop for every region; Quantize, Transpose and Velocity for MIDI; Gain for audio.
private struct RegionInspector: View {
  let model: ProjectWindowModel
  let region: Region

  /// Playback quantize grids, as in Logic's Quantize menu.
  private static let grids: [(name: String, ticks: Tick?)] = [
    ("Off", nil), ("1/4 Note", Tick(960)), ("1/8 Note", Tick(480)), ("1/16 Note", Tick(240)), ("1/32 Note", Tick(120)),
    ("1/4 Triplet", Tick(640)), ("1/8 Triplet", Tick(320)), ("1/16 Triplet", Tick(160)), ("1/32 Triplet", Tick(80)),
  ]

  /// Logic's mixed grids: each note plays on the nearer of a straight and a triplet line.
  private static let mixedGrids: [(name: String, ticks: Tick, triplet: Tick)] = [
    ("1/8 & 1/12", Tick(480), Tick(320)), ("1/16 & 1/12", Tick(240), Tick(320)), ("1/16 & 1/24", Tick(240), Tick(160)),
    ("1/32 & 1/24", Tick(120), Tick(160)),
  ]

  /// The quantize menu's choices in order: the single grids, then the mixed ones.
  private static var quantizeChoices: [(name: String, ticks: Tick?, triplet: Tick?)] {
    grids.map { ($0.name, $0.ticks, nil) } + mixedGrids.map { ($0.name, $0.ticks, $0.triplet) }
  }

  var body: some View {
    let count = model.selectedRegionIDs.count
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(count > 1 ? "\(count) Regions" : region.name)
          .font(Theme.font(12, weight: .semibold))
          .foregroundStyle(Theme.text)
          .lineLimit(1)
        Spacer(minLength: 0)
        Text("Region")
          .font(Theme.font(10))
          .foregroundStyle(Theme.tertiaryText)
      }
      row("Mute") {
        Toggle("Mute", isOn: Binding(get: { region.isMuted }, set: { setMuted($0) }))
          .labelsHidden()
      }
      row("Loop") {
        Toggle("Loop", isOn: Binding(get: { region.isLooped }, set: { set(.looped($0)) }))
          .labelsHidden()
      }
      switch region.content {
      case .midi:
        row("Quantize") {
          let choices = Self.quantizeChoices
          Picker("Quantize", selection: Binding(
            get: {
              choices.firstIndex { $0.ticks == region.playbackQuantize && $0.triplet == region.playbackQuantizeAlternative } ?? 0
            },
            set: { set(.playbackQuantize(choices[$0].ticks, or: choices[$0].triplet)) }
          )) {
            ForEach(choices.indices, id: \.self) { index in
              if index == Self.grids.count { Divider() }
              Text(choices[index].name).tag(index)
            }
          }
          .labelsHidden()
          .fixedSize()
        }
        row("Transpose") {
          ValueStepper(value: region.transpose, range: Region.transposeRange, accessibilityName: "Transpose") {
            set(.transpose($0))
          }
        }
        row("Velocity") {
          ValueStepper(value: region.velocityOffset, range: Region.velocityOffsetRange, accessibilityName: "Velocity") {
            set(.velocityOffset($0))
          }
        }
      case .audio(let audio):
        let isFlexOn = model.project.tracks.first(where: { $0.regions.contains { $0.id == region.id } })?.flexMode != nil
        if isFlexOn {
          row("Flex") {
            Menu("Quantize Audio") {
              ForEach(Self.grids.dropFirst(), id: \.name) { grid in
                Button(grid.name) {
                  if let ticks = grid.ticks { model.quantizeFlex(region.id, grid: ticks) }
                }
              }
            }
            .fixedSize()
            .help("Move the region’s hits to the grid with Flex markers")
          }
        }
        // Shown whenever there are markers or retuned notes: with Flex off they're hidden but
        // still there, and they stop the region being resized, split or joined.
        let marked = model.selectedRegionIDs(where: { !$0.flexMarkers.isEmpty })
        if !marked.isEmpty {
          row("Flex Markers") {
            Button("Remove Flex Markers") { model.clearFlexMarkers(in: marked) }
              .controlSize(.small)
              .help(isFlexOn ? "Remove the flex markers, playing the audio as recorded"
                : "Flex is off on this track, but the regions still have flex markers")
          }
        }
        let retuned = model.selectedRegionIDs(where: { !$0.pitchEdits.isEmpty })
        if !retuned.isEmpty {
          row("Flex Pitch") {
            Button("Reset Retuned Notes") { model.resetPitchEdits(in: retuned) }
              .controlSize(.small)
              .help("Put every retuned note back to the pitch it was sung at")
          }
        }
        row("Smart Tempo") {
          SmartTempoControl(model: model, region: region, stretch: audio.stretch)
        }
        row("Gain") {
          ValueStepper(
            value: Int(audio.gain.rounded()), range: Int(RegionParameter.gainRange.lowerBound)...Int(RegionParameter.gainRange.upperBound),
            unit: " dB", accessibilityName: "Gain"
          ) {
            set(.gain(Double($0)))
          }
        }
        row("Fade In") {
          ValueStepper(
            value: Int((audio.fadeIn * 1000).rounded()), range: 0...60_000, step: 10, unit: " ms", accessibilityName: "Fade In",
            parse: Self.fadeMilliseconds
          ) {
            set(.fadeIn(Double($0) / 1000))
          }
        }
        row("Fade Out") {
          ValueStepper(
            value: Int((audio.fadeOut * 1000).rounded()), range: 0...60_000, step: 10, unit: " ms", accessibilityName: "Fade Out",
            parse: Self.fadeMilliseconds
          ) {
            set(.fadeOut(Double($0) / 1000))
          }
        }
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Region Inspector")
  }

  /// A fade length typed in milliseconds ("250", "250 ms"), or in seconds with an "s"
  /// ("1.5 s").
  nonisolated static func fadeMilliseconds(_ text: String) -> Int? {
    var text = text.trimmingCharacters(in: .whitespaces).lowercased()
    var scale = 1.0
    if text.hasSuffix("ms") {
      text.removeLast(2)
    } else if text.hasSuffix("s") {
      text.removeLast()
      scale = 1000
    }
    guard let number = Double(text.trimmingCharacters(in: .whitespaces)), number.isFinite else { return nil }
    return Int((number * scale).rounded())
  }

  private func row(_ title: String, @ViewBuilder control: () -> some View) -> some View {
    HStack(spacing: 6) {
      Text(title)
        .font(Theme.font(10))
        .foregroundStyle(Theme.secondaryText)
      Spacer(minLength: 0)
      control()
    }
    .frame(height: 20)
  }

  private func set(_ parameter: RegionParameter) {
    model.perform(SetRegionParameter(parameter, for: model.selectedRegionIDs))
  }

  private func setMuted(_ isMuted: Bool) {
    let commands = model.selectedRegionIDs.map { SetRegionMuted($0, isMuted: isMuted) }
    model.perform(CompositeCommand(isMuted ? "Mute Regions" : "Unmute Regions", commands: commands))
  }
}

/// A number with − and + buttons, like the value fields in Logic's inspectors. Shows "+3"
/// for positive values. With `parse`, clicking the number lets you type one (Return sets
/// it, Escape cancels).
private struct ValueStepper: View {
  let value: Int
  let range: ClosedRange<Int>
  var step = 1
  var unit = ""
  let accessibilityName: String
  /// Reads a typed value; it's then kept within the range. Without it the number can only
  /// be stepped.
  var parse: ((String) -> Int?)?
  let onChange: (Int) -> Void

  /// The number is text until clicked, so the Inspector never holds the keyboard (which
  /// would block the single-key shortcuts) until you choose to type.
  @State private var isEditing = false
  @State private var text = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 4) {
      Button("Decrease \(accessibilityName)", systemImage: "minus") { change(by: -step) }
        .disabled(value <= range.lowerBound)
      Group {
        if isEditing {
          TextField(accessibilityName, text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .focused($isFocused)
            .onSubmit(commit)
            .onExitCommand { isEditing = false }
            .onChange(of: isFocused) { _, isFocused in
              if !isFocused { isEditing = false }
            }
            .onAppear { isFocused = true }
        } else {
          Text("\(value > 0 ? "+" : "")\(value)\(unit)")
            .foregroundStyle(value == 0 ? Theme.secondaryText : Theme.text)
            .contentShape(.rect)
            .onTapGesture {
              guard parse != nil else { return }
              text = "\(value)"
              isEditing = true
            }
            .help(parse == nil ? "" : "Click to type a value")
        }
      }
      .font(Theme.monospaced(11))
      .frame(minWidth: 44)
      Button("Increase \(accessibilityName)", systemImage: "plus") { change(by: step) }
        .disabled(value >= range.upperBound)
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityName)
    .accessibilityValue("\(value)\(unit)")
    .accessibilityAdjustableAction { direction in
      change(by: direction == .increment ? step : -step)
    }
  }

  private func change(by step: Int) {
    let changed = min(max(value + step, range.lowerBound), range.upperBound)
    if changed != value { onChange(changed) }
  }

  private func commit() {
    isEditing = false
    guard let typed = parse?(text) else { return }
    let changed = min(max(typed, range.lowerBound), range.upperBound)
    if changed != value { onChange(changed) }
  }
}

/// Logic's Flex mode for an audio track: Off, or how flex markers stretch the audio.
private struct FlexModeRow: View {
  let model: ProjectWindowModel
  let track: Track

  var body: some View {
    HStack(spacing: 6) {
      Text("Flex")
        .font(Theme.font(10))
        .foregroundStyle(Theme.secondaryText)
      Spacer(minLength: 0)
      Picker("Flex", selection: Binding(get: { track.flexMode }, set: { model.setFlexMode($0, for: track.id) })) {
        Text("Off").tag(FlexMode?.none)
        ForEach(FlexMode.allCases, id: \.self) { mode in
          Text(mode.displayName).tag(FlexMode?.some(mode))
        }
      }
      .labelsHidden()
      .controlSize(.small)
      .fixedSize()
      .help("Flex Time: drag in the lower half of an audio region to move its audio in time")
    }
    .padding(.horizontal, 10)
    .padding(.bottom, 6)
  }
}

/// Smart Tempo for an audio region: find its tempo, then make the song follow it (Adapt) or
/// stretch it to the song (Match).
private struct SmartTempoControl: View {
  let model: ProjectWindowModel
  let region: Region
  let stretch: Double

  var body: some View {
    if model.tempoDetectionRegionIDs.contains(region.id) {
      ProgressView().controlSize(.mini)
    } else if let tempo = model.detectedTempos[region.id] {
      Menu(tempo.bpm.formatted(.number.precision(.fractionLength(1))) + " BPM") {
        Button("Adapt Project Tempo") { model.adaptProjectTempo(to: region.id) }
        Button("Match Project Tempo") { model.matchProjectTempo(region.id) }
        Divider()
        Button("Detect Again") { model.detectTempo(of: region.id) }
        if stretch != 1 {
          Button("Remove Stretch") { model.perform(ResetRegionStretch(region.id)) }
        }
      }
      .fixedSize()
      .help("The recording’s tempo. Adapt changes the song’s tempo to it; Match stretches the recording to the song’s.")
    } else {
      HStack(spacing: 4) {
        // Detected tempos aren't saved, so a stretch can be undone without detecting again.
        if abs(stretch - 1) > 0.0001 {
          Button("Remove Stretch") { model.perform(ResetRegionStretch(region.id)) }
            .help("Play the recording at the speed it was made")
        }
        Button("Detect Tempo") { model.detectTempo(of: region.id) }
          .help("Find the recording’s tempo")
      }
    }
  }
}
