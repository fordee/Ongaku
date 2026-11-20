//
//  SmartControlsView.swift
//  Ongaku
//

import OngakuCore
import SwiftUI

/// Logic's Smart Controls (B): eight big knobs for the selected track's most useful
/// controls. Until they're mapped they suggest some (its instrument's first parameters, or
/// its fader, pan and sends). Right-click a knob to map it, or to learn a MIDI controller
/// for it: then turn a knob on the controller.
struct SmartControlsView: View {
  let model: ProjectWindowModel

  static let idealHeight: CGFloat = 210

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(title: "Smart Controls", symbol: "dial.medium", closeTitle: "Close Smart Controls") {
        model.cancelMIDILearn()
        model.bottomPane = nil
      }
      if let track = model.selectedTrack {
        SmartControlsPanel(model: model, track: track)
      } else {
        ContentUnavailableView(
          "No Track Selected", systemImage: "dial.medium",
          description: Text("Select a track to play its Smart Controls."))
          .foregroundStyle(Theme.secondaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(Theme.lanes)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("smart-controls")
  }
}

private struct SmartControlsPanel: View {
  let model: ProjectWindowModel
  let track: Track

  var body: some View {
    let controls = model.smartControls(for: track)
    HStack(alignment: .top, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 6) {
          RoundedRectangle(cornerRadius: 2).fill(track.color.color).frame(width: 4, height: 16)
          Text(track.name).font(Theme.font(13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
        }
        Text(track.smartControls.isEmpty ? "Suggested controls. Right-click a knob to choose its own." : "Right-click a knob to map it or learn a MIDI controller.")
          .font(Theme.font(10))
          .foregroundStyle(Theme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        if model.midiLearnTarget != nil {
          Label("Move a knob, fader or wheel on your MIDI controller…", systemImage: "dot.radiowaves.left.and.right")
            .font(Theme.font(10, weight: .semibold))
            .foregroundStyle(Theme.cycle)
            .fixedSize(horizontal: false, vertical: true)
          Button("Cancel Learn") { model.cancelMIDILearn() }
            .buttonStyle(ThemeButtonStyle(height: 20))
        }
      }
      .frame(width: 170, alignment: .leading)
      .padding(14)

      // Plug-in parameters change in their own windows too, so the knobs look again a few
      // times a second.
      TimelineView(.periodic(from: .now, by: 0.25)) { _ in
        HStack(spacing: 6) {
          ForEach(0..<SmartControl.count, id: \.self) { index in
            SmartKnob(model: model, track: track, index: index, parameter: controls.indices.contains(index) ? controls[index] : nil)
          }
        }
      }
      .padding(.vertical, 14)
      Spacer(minLength: 0)
    }
  }
}

/// One knob: its control's name and value, and the MIDI controller that plays it.
private struct SmartKnob: View {
  let model: ProjectWindowModel
  let track: Track
  let index: Int
  let parameter: AutomationParameter?

  @State private var dragValue: Double?

  var body: some View {
    VStack(spacing: 6) {
      if let parameter {
        let target = SmartControlTarget(trackID: track.id, parameter: parameter)
        let isLearning = model.midiLearnTarget == target
        // Levels turn along the fader's scale, so 0 dB sits where it does on a fader.
        let current = dragValue ?? model.smartControlValue(parameter, on: track)
        Knob(
          value: parameter.isDecibels ? FaderScale.position(forDecibels: current) : current,
          range: parameter.isDecibels ? 0...1 : parameter.range,
          isBipolar: parameter == .pan, size: 48, tint: isLearning ? Theme.cycle : track.color.color,
          label: model.controlName(parameter, on: track),
          valueText: { Self.valueText(parameter.isDecibels ? FaderScale.decibels(atPosition: $0) : $0, for: parameter) }
        ) { knob in
          let value = parameter.isDecibels ? FaderScale.decibels(atPosition: knob) : knob
          dragValue = value
          model.smartControlChanged(target, to: value)
        } onCommit: { knob in
          model.smartControlReleased(target, at: parameter.isDecibels ? FaderScale.decibels(atPosition: knob) : knob)
          dragValue = nil
        }
        .overlay {
          if isLearning { Circle().strokeBorder(Theme.cycle, lineWidth: 2).frame(width: 58, height: 58) }
        }
        Text(model.controlName(parameter, on: track))
          .font(Theme.font(10, weight: .medium))
          .foregroundStyle(Theme.text)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .frame(height: 26, alignment: .top)
        Text(Self.valueText(current, for: parameter))
          .font(Theme.monospaced(9))
          .foregroundStyle(Theme.secondaryText)
        let assignment = model.project.controllerAssignment(for: parameter, on: track.id)
        Text(isLearning ? "Learning…" : assignment.map { "CC \($0.controller) · Ch \($0.channel + 1)" } ?? " ")
          .font(Theme.font(9, weight: .semibold))
          .foregroundStyle(isLearning ? Theme.cycle : Theme.tertiaryText)
      } else {
        Menu {
          mapItems
        } label: {
          Circle()
            .strokeBorder(Theme.divider, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            .frame(width: 48, height: 48)
            .overlay(Image(systemName: "plus").foregroundStyle(Theme.tertiaryText))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Choose a control for this knob")
        Text("Unmapped").font(Theme.font(10)).foregroundStyle(Theme.tertiaryText).frame(height: 26, alignment: .top)
      }
    }
    .frame(width: 92, height: 140, alignment: .top)
    .padding(.vertical, 8)
    .background(Theme.panel, in: .rect(cornerRadius: 6))
    .contentShape(.rect)
    .contextMenu {
      if let parameter {
        let target = SmartControlTarget(trackID: track.id, parameter: parameter)
        Button("Learn MIDI Controller") { model.beginMIDILearn(target) }
        if let assignment = model.project.controllerAssignment(for: parameter, on: track.id) {
          Button("Forget \(assignment.description)") { model.perform(RemoveControllerAssignment(assignment.id)) }
        }
        Divider()
      }
      Menu("Map to") { mapItems }
      if parameter != nil {
        Button("Clear Knob") { model.mapSmartControl(index, on: track, to: nil) }
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(parameter.map { "Smart Control \(index + 1), \(model.controlName($0, on: track))" } ?? "Smart Control \(index + 1), unmapped")
    .accessibilityIdentifier("smart-control")
  }

  @ViewBuilder private var mapItems: some View {
    ForEach(model.mappableControls(for: track), id: \.title) { group in
      Menu(group.title) {
        ForEach(group.parameters, id: \.self) { candidate in
          Toggle(model.controlName(candidate, on: track), isOn: Binding(
            get: { candidate == parameter },
            set: { _ in model.mapSmartControl(index, on: track, to: candidate) }))
        }
      }
    }
  }

  static func valueText(_ value: Double, for parameter: AutomationParameter) -> String {
    if case .plugin = parameter { return "\(Int((value * 100).rounded())) %" }
    return AutomationScale.label(value, for: parameter)
  }
}

#Preview {
  var keys = Track(name: "Keys", kind: .softwareInstrument, color: .teal)
  let verb = Track(name: "Reverb", kind: .aux)
  keys.channel.sends = [Send(destinationTrackID: verb.id, level: -12)]
  let model = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [keys, verb])))
  model.selectedTrackID = keys.id
  return SmartControlsView(model: model).frame(width: 1100, height: SmartControlsView.idealHeight)
}
