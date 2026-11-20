//
//  SamplerZonesView.swift
//  OngakuEffects
//

import AppKit
import OngakuCore
import SwiftUI

/// Switches the Sampler's sample section between the selected zone's waveform and the
/// zones.
struct PageSwitch: View {
  @Binding var page: SamplerView.Page
  let zoneCount: Int
  let accent: Color

  var body: some View {
    HStack(spacing: 2) {
      button(.waveform, "WAVEFORM", help: "The selected zone's sample, with its markers and loop.")
      button(.zones, zoneCount > 1 ? "ZONES · \(zoneCount)" : "ZONES", help: "Where each sample plays: its keys and velocities.")
    }
    .padding(2)
    .background(RoundedRectangle(cornerRadius: 5).fill(Synth.section))
  }

  private func button(_ target: SamplerView.Page, _ title: String, help: String) -> some View {
    Button { page = target } label: {
      Text(title)
        .font(.system(size: 9, weight: .bold))
        .tracking(0.8)
        .foregroundStyle(page == target ? .black : Synth.value)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 4).fill(page == target ? accent : Color.black.opacity(0.3)))
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityAddTraits(page == target ? .isSelected : [])
  }
}

/// The zones laid out like Logic's Sampler mapping: keys across (a keyboard along the
/// bottom), velocities up, each zone a coloured box with its root note marked. Click one to
/// select it; drag it to move it, or its edges to change its keys and velocities. Drop
/// files on it to add them as zones.
struct ZoneMap: View {
  let zones: [SamplerZoneInfo]
  let selectedID: UUID?
  let rootKnob: Int
  let accent: Color
  let select: (UUID) -> Void
  let change: (UUID, SamplerZoneSettings) -> Void
  let drop: ([URL]) -> Void

  @State private var drag: DragState?
  @State private var isTargeted = false

  private struct DragState {
    let id: UUID
    let original: SamplerZoneSettings
    let part: Part
  }

  private enum Part { case body, lowKey, highKey, lowVelocity, highVelocity }

  static let colors = [
    Color(red: 0.3, green: 0.85, blue: 0.78), Synth.oscillator, Synth.filter, Synth.lfo, Synth.envelope, Synth.unison,
  ]
  private static let keyboardHeight: CGFloat = 16

  var body: some View {
    SynthScreen {
      GeometryReader { proxy in
        let size = proxy.size
        Canvas { context, size in draw(in: &context, size: size) }
          .contentShape(.rect)
          .gesture(
            DragGesture(minimumDistance: 0)
              .onChanged { value in dragged(value, size: size) }
              .onEnded { _ in drag = nil })
          .overlay {
            if zones.isEmpty {
              VStack(spacing: 4) {
                Text("No zones yet").font(.system(size: 13, weight: .semibold)).foregroundStyle(Synth.value)
                Text("Drag audio files here, or click Add Samples…").font(.system(size: 11)).foregroundStyle(Synth.label)
              }
              .allowsHitTesting(false)
            }
          }
      }
    }
    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(accent, lineWidth: isTargeted ? 2 : 0))
    .dropDestination(for: URL.self) { urls, _ in
      guard !urls.isEmpty else { return false }
      drop(urls)
      return true
    } isTargeted: { isTargeted = $0 }
    .accessibilityElement()
    .accessibilityLabel("Zones")
    .accessibilityValue(accessibilityValue)
    .accessibilityAdjustableAction { direction in
      // Steps the selection through the zones.
      guard !zones.isEmpty else { return }
      let index = zones.firstIndex { $0.id == selectedID } ?? 0
      let next = direction == .increment ? min(zones.count - 1, index + 1) : max(0, index - 1)
      select(zones[next].id)
    }
  }

  private var accessibilityValue: String {
    guard let zone = zones.first(where: { $0.id == selectedID }) else { return "No zones" }
    let settings = zone.settings
    return "\(zones.count) zones. Selected \(zone.name): keys \(Self.noteName(settings.lowKey)) to \(Self.noteName(settings.highKey)), "
      + "velocities \(settings.lowVelocity) to \(settings.highVelocity), root \(Self.noteName(settings.root ?? rootKnob))"
  }

  static func noteName(_ note: Int) -> String { DrumMachineView.noteName(note) }

  // MARK: - Geometry

  private func keyWidth(_ size: CGSize) -> CGFloat { size.width / 128 }
  private func mapHeight(_ size: CGSize) -> CGFloat { size.height - Self.keyboardHeight }

  private func rect(_ settings: SamplerZoneSettings, _ size: CGSize) -> CGRect {
    let width = keyWidth(size), height = mapHeight(size)
    let top = height * (1 - CGFloat(settings.highVelocity) / 127)
    let bottom = height * (1 - CGFloat(settings.lowVelocity - 1) / 127)
    return CGRect(
      x: CGFloat(settings.lowKey) * width, y: top, width: CGFloat(settings.highKey - settings.lowKey + 1) * width, height: bottom - top)
  }

  private static func isBlack(_ key: Int) -> Bool { [1, 3, 6, 8, 10].contains(key % 12) }

  // MARK: - Drawing

  private func draw(in context: inout GraphicsContext, size: CGSize) {
    let width = keyWidth(size), height = mapHeight(size)
    // The black keys' columns, a little darker; a line at each C, and the velocity quarters.
    for key in 0..<128 where Self.isBlack(key) {
      context.fill(Path(CGRect(x: CGFloat(key) * width, y: 0, width: width, height: height)), with: .color(.black.opacity(0.25)))
    }
    for key in stride(from: 0, to: 128, by: 12) {
      context.fill(Path(CGRect(x: CGFloat(key) * width, y: 0, width: 1, height: height)), with: .color(.white.opacity(0.1)))
    }
    for velocity in [32, 64, 96] {
      let y = height * (1 - CGFloat(velocity) / 127)
      context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
        with: .color(.white.opacity(0.06)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }
    // The zones, the selected one last so it's on top.
    let ordered = zones.enumerated().sorted { ($0.element.id == selectedID ? 1 : 0) < ($1.element.id == selectedID ? 1 : 0) }
    for (index, zone) in ordered {
      let color = Self.colors[index % Self.colors.count]
      let isSelected = zone.id == selectedID
      let box = rect(zone.settings, size).insetBy(dx: 0.5, dy: 0.5)
      context.fill(Path(roundedRect: box, cornerRadius: 2), with: .color(color.opacity(isSelected ? 0.45 : 0.25)))
      context.stroke(Path(roundedRect: box, cornerRadius: 2), with: .color(isSelected ? .white : color.opacity(0.9)), lineWidth: isSelected ? 1.5 : 1)
      if box.width > 40, box.height > 16 {
        var text = context.resolve(Text(zone.name).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Synth.value))
        text.shading = .color(Synth.value)
        context.drawLayer { layer in
          layer.clip(to: Path(box.insetBy(dx: 3, dy: 2)))
          layer.draw(text, at: CGPoint(x: box.minX + 4, y: box.minY + 3), anchor: .topLeading)
        }
      }
    }
    // The keyboard along the bottom, with octave names.
    let keyTop = height
    context.fill(Path(CGRect(x: 0, y: keyTop, width: size.width, height: Self.keyboardHeight)), with: .color(Color(white: 0.85)))
    for key in 0..<128 where Self.isBlack(key) {
      context.fill(Path(CGRect(x: CGFloat(key) * width, y: keyTop, width: width, height: Self.keyboardHeight * 0.6)), with: .color(.black))
    }
    for key in stride(from: 0, to: 128, by: 12) {
      context.draw(Text(Self.noteName(key)).font(.system(size: 7.5, weight: .semibold)).foregroundStyle(Color(white: 0.25)),
        at: CGPoint(x: CGFloat(key) * width + 2, y: keyTop + Self.keyboardHeight - 1), anchor: .bottomLeading)
    }
    // Each zone's root on the keyboard: the selected zone's bright.
    for (index, zone) in zones.enumerated() {
      let root = zone.settings.root ?? rootKnob
      let isSelected = zone.id == selectedID
      let x = (CGFloat(root) + 0.5) * width
      var marker = Path()
      marker.move(to: CGPoint(x: x - 3.5, y: keyTop))
      marker.addLine(to: CGPoint(x: x + 3.5, y: keyTop))
      marker.addLine(to: CGPoint(x: x, y: keyTop + 6))
      marker.closeSubpath()
      context.fill(marker, with: .color(isSelected ? .white : Self.colors[index % Self.colors.count]))
      if isSelected {
        context.stroke(marker, with: .color(.black), lineWidth: 0.5)
      }
    }
  }

  // MARK: - Dragging

  /// What's under a point: the selected zone first, then the topmost; and which part (an
  /// edge, if the zone is big enough to have one, else its body).
  private func hit(_ point: CGPoint, size: CGSize) -> DragState? {
    let candidates = zones.filter { $0.id == selectedID } + zones.reversed().filter { $0.id != selectedID }
    for zone in candidates {
      let box = rect(zone.settings, size)
      guard box.insetBy(dx: -3, dy: -3).contains(point) else { continue }
      let edge: CGFloat = 4
      var part = Part.body
      if box.width >= 14, abs(point.x - box.minX) <= edge { part = .lowKey }
      else if box.width >= 14, abs(point.x - box.maxX) <= edge { part = .highKey }
      else if box.height >= 14, abs(point.y - box.minY) <= edge { part = .highVelocity }
      else if box.height >= 14, abs(point.y - box.maxY) <= edge { part = .lowVelocity }
      else if !box.contains(point) { continue }
      return DragState(id: zone.id, original: zone.settings, part: part)
    }
    return nil
  }

  private func dragged(_ value: DragGesture.Value, size: CGSize) {
    if drag == nil {
      guard let found = hit(value.startLocation, size: size) else { return }
      drag = found
      if found.id != selectedID { select(found.id) }
    }
    guard let drag else { return }
    let keys = Int((value.translation.width / keyWidth(size)).rounded())
    let velocities = Int((-value.translation.height / max(1, mapHeight(size)) * 127).rounded())
    guard keys != 0 || velocities != 0 else { return }
    var settings = drag.original
    switch drag.part {
    case .body:
      let keyShift = min(127 - settings.highKey, max(-settings.lowKey, keys))
      let velocityShift = min(127 - settings.highVelocity, max(1 - settings.lowVelocity, velocities))
      settings.lowKey += keyShift
      settings.highKey += keyShift
      settings.root = settings.root.map { $0 + keyShift }
      settings.lowVelocity += velocityShift
      settings.highVelocity += velocityShift
    case .lowKey: settings.lowKey = min(settings.highKey, max(0, settings.lowKey + keys))
    case .highKey: settings.highKey = max(settings.lowKey, min(127, settings.highKey + keys))
    case .lowVelocity: settings.lowVelocity = min(settings.highVelocity, max(1, settings.lowVelocity + velocities))
    case .highVelocity: settings.highVelocity = max(settings.lowVelocity, min(127, settings.highVelocity + velocities))
    }
    change(drag.id, settings)
  }
}

/// The selected zone's settings: its keys, velocities, root, tuning, level and pan, and
/// buttons to give it another sample or remove it.
struct ZoneInspector: View {
  let zone: SamplerZoneInfo?
  let rootKnob: Int
  let change: ((inout SamplerZoneSettings) -> Void) -> Void
  let replace: () -> Void
  let remove: () -> Void
  let hover: (Bool, String) -> Void

  var body: some View {
    if let zone {
      let settings = zone.settings
      VStack(alignment: .leading, spacing: 5) {
        Text(zone.name)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Synth.value)
          .lineLimit(1)
          .truncationMode(.middle)
        row("Keys", help: "The lowest and highest keys the zone plays.") {
          stepper(ZoneMap.noteName(settings.lowKey), label: "Lowest key") { $0.lowKey = min($0.highKey, $0.lowKey + $1) }
          dash
          stepper(ZoneMap.noteName(settings.highKey), label: "Highest key") { $0.highKey = max($0.lowKey, $0.highKey + $1) }
        }
        row("Velocity", help: "How hard a key must be played for the zone to sound: softest and hardest.") {
          stepper("\(settings.lowVelocity)", label: "Softest velocity") { $0.lowVelocity = min($0.highVelocity, $0.lowVelocity + $1) }
          dash
          stepper("\(settings.highVelocity)", label: "Hardest velocity") { $0.highVelocity = max($0.lowVelocity, $0.highVelocity + $1) }
        }
        row("Root", help: "The key that plays the sample at its own pitch. Zones that haven't their own follow the Root Note knob.") {
          stepper(ZoneMap.noteName(settings.root ?? rootKnob) + (settings.root == nil ? " (knob)" : ""), label: "Root note") {
            $0.root = ($0.root ?? rootKnob) + $1
          }
        }
        row("Tune", help: "Tunes this zone in cents, on top of the Fine knob.") {
          stepper(String(format: "%+.0f ¢", settings.tune), label: "Tune") { $0.tune += Double($1) }
        }
        row("Level", help: "This zone's level, to balance it with the others.") {
          stepper(String(format: "%+.1f dB", settings.gain), label: "Level") { $0.gain += Double($1) * 0.5 }
        }
        row("Pan", help: "Where this zone sits between the speakers.") {
          stepper(settings.pan == 0 ? "C" : String(format: "%@ %.0f", settings.pan < 0 ? "L" : "R", abs(settings.pan)), label: "Pan") {
            $0.pan += Double($1) * 5
          }
        }
        HStack(spacing: 6) {
          Button("Replace Sample…", action: replace)
            .help("Plays another sound in this zone, keeping where it plays.")
          Button("Remove", role: .destructive, action: remove)
            .help("Removes this zone.")
        }
        .controlSize(.small)
      }
    } else {
      Text("Select a zone to change where it plays.")
        .font(.system(size: 11))
        .foregroundStyle(Synth.label)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var dash: some View {
    Text("–").font(.system(size: 10)).foregroundStyle(Synth.label)
  }

  private func row(_ title: String, help: String, @ViewBuilder _ content: () -> some View) -> some View {
    HStack(spacing: 4) {
      Text(title.uppercased())
        .font(.system(size: 8.5, weight: .semibold))
        .tracking(0.5)
        .foregroundStyle(Synth.label)
        .frame(width: 52, alignment: .leading)
      content()
      Spacer(minLength: 0)
    }
    .frame(height: 17)
    .help(help)
    .onHover { hover($0, help) }
  }

  /// A value with arrows to step it (by one step of whatever `step` does with ±1).
  private func stepper(_ text: String, label: String, _ step: @escaping (inout SamplerZoneSettings, Int) -> Void) -> some View {
    Stepper {
      Text(text)
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .foregroundStyle(Synth.value)
        .lineLimit(1)
    } onIncrement: {
      change { step(&$0, 1) }
    } onDecrement: {
      change { step(&$0, -1) }
    }
    .controlSize(.mini)
    .accessibilityLabel(label)
    .accessibilityValue(text)
  }
}

#Preview("Sampler Zones") {
  PluginPreview(effect: .sampler) { audioUnit in
    // A few notes of a made-up instrument, two of them with soft and hard layers, and a
    // drum on a key of its own.
    let rate = 48_000.0
    func tone(_ note: Int, _ level: Float) -> SamplerSampleBuffer {
      let frequency = 440 * pow(2, Double(note - 69) / 12)
      let samples = (0..<Int(rate)).map { level * Float(sin(2 * .pi * frequency * Double($0) / rate) * exp(-3 * Double($0) / rate)) }
      return SamplerSampleBuffer(name: "Vibes \(ZoneMap.noteName(note))\(level < 0.5 ? " soft" : "")", sampleRate: rate, channels: [samples])
    }
    let samples = [(48, Float(0.8)), (55, 0.3), (55, 0.8), (62, 0.3), (62, 0.8), (69, 0.8), (76, 0.8)]
    let layout = SamplerZoneLayout.map(samples.map { .init(root: $0.0, level: $0.1) })
    var zones = zip(samples, layout).map { SamplerZone(buffer: tone($0.0, $0.1), settings: $1) }
    zones.append(SamplerZone(buffer: tone(36, 0.9), settings: SamplerZoneSettings(lowKey: 30, highKey: 30, root: 30)))
    audioUnit.setZones(zones)
    audioUnit.selectZone(zones[2].id)
    audioUnit.samplerDisplay.showsZones = true
  }
}
