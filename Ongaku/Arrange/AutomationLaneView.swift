//
//  AutomationLaneView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// Where a parameter's values sit in a lane, from 0 (bottom) to 1 (top). Volume and send
/// levels use the fader's taper, so a curve looks like the fader moving.
enum AutomationScale {
  static func fraction(of value: Double, for parameter: AutomationParameter) -> Double {
    switch parameter {
    case .volume, .sendLevel: FaderScale.position(forDecibels: value)
    case .pan: (value + 1) / 2
    case .plugin: value
    }
  }

  static func value(atFraction fraction: Double, for parameter: AutomationParameter) -> Double {
    let fraction = min(max(fraction, 0), 1)
    return switch parameter {
    case .volume, .sendLevel: FaderScale.decibels(atPosition: fraction)
    case .pan: fraction * 2 - 1
    case .plugin: fraction
    }
  }

  /// "−6.0 dB", "L 40" / "R 40" / "C", or a plug-in parameter in its own unit ("1.50 kHz")
  /// when `format` says how it reads (otherwise "75%" of its range), for the value shown
  /// while dragging.
  static func label(_ value: Double, for parameter: AutomationParameter, format: PluginValueFormat? = nil) -> String {
    switch parameter {
    case .volume, .sendLevel:
      return "\(FaderScale.label(value)) dB"
    case .pan:
      let amount = Int((abs(value) * 64).rounded())
      return amount == 0 ? "C" : "\(value < 0 ? "L" : "R") \(amount)"
    case .plugin:
      return format?.label(forFraction: value) ?? "\(Int((value * 100).rounded()))%"
    }
  }
}

/// A track's automation, in its strip under the track's lane while automation is shown. Click
/// to add a point, drag a point to move it, double-click a point to delete it. Points snap
/// like regions do (Control while dragging moves them freely).
struct AutomationLaneView: View {
  let model: ProjectWindowModel
  let track: Track

  @State private var dragged: AutomationPoint?

  static let pointRadius: CGFloat = 4
  /// Keeps the top and bottom points clear of the lane's edges.
  private static let inset: CGFloat = 6
  private typealias Layout = ProjectWindowModel.Layout

  var body: some View {
    let parameter = model.displayedAutomationParameter(for: track.id)
    let points = displayedPoints(for: parameter)
    let format = model.pluginValueFormat(for: parameter, on: track.id)
    let width = model.contentWidth
    let color = track.automationMode.plays ? track.color.color : Color.secondary

    ZStack(alignment: .topLeading) {
      // The strip's own background, a shade darker than the lane above; it takes clicks
      // for new points.
      Rectangle()
        .fill(Color.black.opacity(0.22))
        .overlay(alignment: .top) {
          Rectangle().fill(Theme.separator.opacity(0.5)).frame(height: 1)
        }
        .contentShape(.rect)
        .gesture(SpatialTapGesture().onEnded { tap in
          model.beginEditing(in: .tracks)
          model.selectedTrackID = track.id
          model.addAutomationPoint(
            at: model.snap(model.position(forX: tap.location.x)), value: value(atY: tap.location.y, for: parameter),
            to: parameter, on: track.id)
        })

      Canvas { context, _ in
        var line = Path()
        if let first = points.first, let last = points.last {
          line.move(to: CGPoint(x: 0, y: y(for: first.value, parameter)))
          for point in points {
            line.addLine(to: location(of: point, parameter))
          }
          line.addLine(to: CGPoint(x: width, y: y(for: last.value, parameter)))
          // A dark edge keeps the line visible over regions of the same colour.
          context.stroke(line, with: .color(.black.opacity(0.45)), lineWidth: 3.5)
          context.stroke(line, with: .color(color), lineWidth: 1.5)
        } else {
          // No automation yet: the channel strip's setting, dashed.
          let y = y(for: parameter.value(in: track.channel), parameter)
          line.move(to: CGPoint(x: 0, y: y))
          line.addLine(to: CGPoint(x: width, y: y))
          context.stroke(line, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
      }
      .allowsHitTesting(false)

      ForEach(visible(points)) { point in
        AutomationPointView(isDragged: dragged?.id == point.id, color: color)
          .position(location(of: point, parameter))
          .gesture(drag(point, parameter))
          .onTapGesture(count: 2) {
            model.deleteAutomationPoint(point.id, from: parameter, on: track.id)
          }
          .accessibilityElement()
          .accessibilityLabel("\(model.automationName(of: parameter, on: track)) point")
          .accessibilityValue(AutomationScale.label(point.value, for: parameter, format: format))
      }

      if let dragged {
        Text(AutomationScale.label(dragged.value, for: parameter, format: format))
          .font(.caption2.monospacedDigit())
          .padding(.horizontal, 4)
          .background(.regularMaterial, in: .rect(cornerRadius: 3))
          .position(x: location(of: dragged, parameter).x, y: 8)
          .allowsHitTesting(false)
      }
    }
    .frame(width: width, height: Layout.automationHeight, alignment: .topLeading)
    .coordinateSpace(.named(Self.coordinateSpace))
  }

  private static let coordinateSpace = "automation-lane"

  /// The lane's points, with the one being dragged at its new place.
  private func displayedPoints(for parameter: AutomationParameter) -> [AutomationPoint] {
    let points = track.automationLane(for: parameter)?.points ?? []
    guard let dragged else { return points }
    return points.map { $0.id == dragged.id ? dragged : $0 }.sorted { $0.position < $1.position }
  }

  /// Points inside the drawn part of the timeline; a recorded curve can have many.
  private func visible(_ points: [AutomationPoint]) -> [AutomationPoint] {
    let range = model.scroll.renderRange
    return points.filter { range.contains(model.x(for: $0.position)) }
  }

  private func drag(_ point: AutomationPoint, _ parameter: AutomationParameter) -> some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordinateSpace))
      .onChanged { drag in
        var moved = point
        moved.position = model.snap(model.position(forX: drag.location.x))
        moved.value = value(atY: drag.location.y, for: parameter)
        dragged = moved
      }
      .onEnded { _ in
        if let dragged {
          model.moveAutomationPoint(dragged, in: parameter, on: track.id)
        }
        dragged = nil
      }
  }

  private func location(of point: AutomationPoint, _ parameter: AutomationParameter) -> CGPoint {
    CGPoint(x: model.x(for: point.position), y: y(for: point.value, parameter))
  }

  private func y(for value: Double, _ parameter: AutomationParameter) -> CGFloat {
    let usable = Layout.automationHeight - Self.inset * 2
    return Self.inset + usable * (1 - AutomationScale.fraction(of: value, for: parameter))
  }

  private func value(atY y: CGFloat, for parameter: AutomationParameter) -> Double {
    let usable = Layout.automationHeight - Self.inset * 2
    return AutomationScale.value(atFraction: 1 - Double((y - Self.inset) / usable), for: parameter)
  }
}

private struct AutomationPointView: View {
  let isDragged: Bool
  let color: Color

  var body: some View {
    Circle()
      .fill(isDragged ? Color.white : color)
      .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
      .frame(width: AutomationLaneView.pointRadius * 2, height: AutomationLaneView.pointRadius * 2)
      // A larger target than the dot, so points are easy to grab.
      .padding(4)
      .contentShape(.circle)
  }
}

/// The header of a track's automation strip, under its track header.
struct AutomationStripHeader: View {
  let model: ProjectWindowModel
  let track: Track

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
        .font(Theme.font(10))
        .foregroundStyle(Theme.secondaryText)
        .accessibilityHidden(true)
      AutomationHeaderControls(model: model, track: track)
      Spacer(minLength: 0)
    }
    .padding(.leading, 28)
    .padding(.trailing, 8)
    .frame(width: model.headerWidth, height: ProjectWindowModel.Layout.automationHeight)
    .background(Color.black.opacity(0.22))
    .overlay(alignment: .top) {
      Rectangle().fill(Theme.separator.opacity(0.5)).frame(height: 1)
    }
    .clipped()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(track.name) automation")
  }
}

/// Which parameter a track's automation strip shows, and the track's automation mode.
struct AutomationHeaderControls: View {
  let model: ProjectWindowModel
  let track: Track

  var body: some View {
    let parameter = model.displayedAutomationParameter(for: track.id)
    let name = model.automationName(of: parameter, on: track)
    HStack(spacing: 6) {
      Menu {
        ForEach(AutomationParameter.channelParameters, id: \.self) { candidate in
          parameterToggle(candidate, selected: parameter)
        }
        // Each send's level, as in Logic's lane menu.
        if !track.channel.sends.isEmpty {
          Divider()
          ForEach(track.channel.sends) { send in
            parameterToggle(.sendLevel(send.id), selected: parameter)
          }
        }
        // Each insert's parameters, read from the loaded plug-in.
        if !track.channel.inserts.isEmpty {
          Divider()
          ForEach(track.channel.inserts) { insert in
            Menu(insert.name) {
              let parameters = model.engine.automatableParameters(ofInsert: insert.id, onTrack: track.id)
              if parameters.isEmpty {
                Text("No automatable parameters")
              }
              ForEach(parameters, id: \.address) { pluginParameter in
                parameterToggle(.plugin(pluginParameter), selected: parameter)
              }
            }
          }
        }
        Divider()
        Button("Delete \(name) Automation") {
          model.perform(ClearAutomation(parameter, on: track.id))
        }
        .disabled(track.automationLane(for: parameter) == nil)
      } label: {
        Text(name)
      }
      .accessibilityLabel("Automation Parameter")
      .accessibilityValue(name)

      Menu {
        ForEach(AutomationMode.allCases, id: \.self) { mode in
          Toggle(mode.name, isOn: Binding(
            get: { track.automationMode == mode },
            set: { _ in model.setAutomationMode(mode, for: track.id) }))
        }
      } label: {
        Text(track.automationMode.name)
          .foregroundStyle(track.automationMode.color)
      }
      .accessibilityLabel("Automation Mode")
      .accessibilityValue(track.automationMode.name)
    }
    .font(.caption)
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.visible)
    .fixedSize()
  }
}

extension AutomationHeaderControls {
  /// A menu item showing a parameter's lane, ticked when it's the one shown; a dot marks
  /// parameters that have automation.
  private func parameterToggle(_ candidate: AutomationParameter, selected: AutomationParameter) -> some View {
    let hasAutomation = track.automationLane(for: candidate)?.points.isEmpty == false
    let title = model.automationName(of: candidate, on: track) + (hasAutomation ? "  •" : "")
    return Toggle(title, isOn: Binding(
      get: { candidate == selected },
      set: { _ in model.automationParameters[track.id] = candidate }))
  }
}

extension ProjectWindowModel {
  /// A parameter's name in lane menus: "Volume", "Send to Reverb", or "Delay: Mix".
  func automationName(of parameter: AutomationParameter, on track: Track) -> String {
    switch parameter {
    case .volume, .pan:
      return parameter.name
    case .sendLevel(let id):
      let destination = track.channel.sends.first { $0.id == id }.flatMap { project.track(withID: $0.destinationTrackID) }
      return "Send to \(destination?.name ?? "Aux")"
    case .plugin(let pluginParameter):
      let plugin = track.channel.inserts.first { $0.id == pluginParameter.pluginID }
      return plugin.map { "\($0.name): \(pluginParameter.name)" } ?? pluginParameter.name
    }
  }
}

extension AutomationMode {
  /// Logic's colours: Read green, Touch yellow, Latch purple.
  var color: Color {
    switch self {
    case .off: Theme.secondaryText
    case .read: Color(hex: 0x52B865)
    case .touch: Theme.solo
    case .latch: Color(hex: 0x9C72DC)
    }
  }
}

#Preview {
  var keys = Track(name: "Keys", kind: .softwareInstrument, automationMode: .touch)
  let note = MIDINote(pitch: 60, start: .zero, length: .quarterNotes(2))
  keys.regions = [Region(name: "Chords", start: .zero, length: .quarterNotes(16), content: .midi(MIDISequence(notes: [note])))]
  keys.automation = [AutomationLane(parameter: .volume, points: [
    AutomationPoint(position: .zero, value: 0), AutomationPoint(position: .quarterNotes(8), value: -18),
    AutomationPoint(position: .quarterNotes(12), value: -6),
  ])]
  let bass = Track(name: "Bass", kind: .audio)
  let model = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [keys, bass])))
  model.isAutomationVisible = true
  return ArrangeView(model: model).frame(width: 900, height: 300)
}
