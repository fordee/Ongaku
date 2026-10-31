//
//  Theme.swift
//  Ongaku
//

import AppKit
import OngakuCore
import SwiftUI

/// Ongaku's look: a fixed dark palette in the spirit of Logic Pro. Every view takes its
/// colours from here rather than from the system, so the app looks the same whatever the
/// macOS appearance setting.
enum Theme {
  // MARK: Surfaces, darkest to lightest

  /// Behind everything; the gaps between panels.
  static let window = Color(hex: 0x161618)
  /// The tracks area behind the lanes.
  static let lanes = Color(hex: 0x252527)
  /// A selected track's lane.
  static let laneSelected = Color(hex: 0x2C2F36)
  /// Inspector, Library, Mixer and editor backgrounds.
  static let panel = Color(hex: 0x29292B)
  /// Track headers.
  static let header = Color(hex: 0x2F2F31)
  static let headerSelected = Color(hex: 0x3A4250)
  /// Slots, fields and buttons sitting on a panel.
  static let raised = Color(hex: 0x3A3A3D)
  static let raisedHover = Color(hex: 0x46464A)
  /// Buttons: a little lighter than the control bar so they stand out from it.
  static let buttonTop = Color(hex: 0x56565B)
  static let buttonBottom = Color(hex: 0x47474B)
  /// The control bar's gradient.
  static let controlBarTop = Color(hex: 0x3B3B3E)
  static let controlBarBottom = Color(hex: 0x2F2F32)
  /// Hairlines between areas.
  static let separator = Color(hex: 0x111112)
  static let divider = Color(hex: 0x3E3E42)

  // MARK: Text

  static let text = Color(hex: 0xE4E4E6)
  static let secondaryText = Color(hex: 0x9C9CA2)
  static let tertiaryText = Color(hex: 0x6C6C72)

  // MARK: Ruler and grid

  static let ruler = Color(hex: 0x353538)
  static let rulerText = Color(hex: 0xBDBDC2)
  static let rulerTick = Color(hex: 0x76767C)
  static let barLine = Color(hex: 0x37373A)
  static let beatLine = Color(hex: 0x2D2D30)

  // MARK: LCD

  // The screen's own colours depend on its backlight; see `LCDPalette`.

  /// The recessed frame the screen sits in.
  static let lcdBezelTop = Color(hex: 0x0E0E10)
  static let lcdBezelBottom = Color(hex: 0x232326)

  // MARK: States

  static let accent = Color(hex: 0x4C8FE8)
  static let playhead = Color.white
  static let cycle = Color(hex: 0xE4B53E)
  static let cycleOff = Color(hex: 0x5A5A5E)
  static let mute = Color(hex: 0x3BA7E6)
  static let solo = Color(hex: 0xF0C230)
  static let record = Color(hex: 0xE5484D)
  /// Input Monitoring, Logic's orange.
  static let inputMonitor = Color(hex: 0xF0913A)
  /// Frozen tracks' snowflake buttons and lanes, a paler ice blue than Mute.
  static let freeze = Color(hex: 0xBFE6FF)
  /// An AI agent at work in the song (the control bar's agent badge): a soft violet, unlike
  /// any track or state colour.
  static let agent = Color(hex: 0xB79CF7)
  static let play = Color(hex: 0x3FCF62)
  static let stop = Color(hex: 0xE5484D)

  // MARK: Meters

  static let meterLow = Color(hex: 0x3BC95A)
  static let meterMid = Color(hex: 0xE3D13A)
  static let meterHigh = Color(hex: 0xE5484D)
  static let meterOff = Color(hex: 0x1A1A1C)

  // MARK: Type

  static func font(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight)
  }

  static func monospaced(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
    .system(size: size, weight: weight).monospacedDigit()
  }

  /// Makes the whole app dark — menus, sheets, panels and pop-ups included — whatever the
  /// system setting.
  @MainActor static func applyAppearance() {
    NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
  }
}

extension Color {
  /// A colour from a 0xRRGGBB value.
  init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255, opacity: opacity)
  }
}

extension TrackColor {
  /// Logic-like track and region colours: saturated but not neon, so they read well on the
  /// dark lanes.
  var color: Color {
    switch self {
    case .red: Color(hex: 0xDC5148)
    case .orange: Color(hex: 0xE58A3A)
    case .yellow: Color(hex: 0xD9BC3A)
    case .green: Color(hex: 0x4DB45E)
    case .teal: Color(hex: 0x37B0AA)
    case .blue: Color(hex: 0x4A8BD4)
    case .purple: Color(hex: 0x9768D6)
    case .pink: Color(hex: 0xD668A6)
    case .gray: Color(hex: 0x8C8C92)
    }
  }
}

// MARK: - Controls

/// The rounded, dark buttons of the control bar and panels. `isOn` lights the symbol in
/// `onColor`, like Logic's cycle, metronome and view buttons.
struct ThemeButtonStyle: ButtonStyle {
  var isOn = false
  var onColor: Color = Theme.text
  var width: CGFloat? = 30
  var height: CGFloat = 24

  func makeBody(configuration: Configuration) -> some View {
    ThemeButtonBody(configuration: configuration, isOn: isOn, onColor: onColor, width: width, height: height)
  }
}

private struct ThemeButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let isOn: Bool
  let onColor: Color
  let width: CGFloat?
  let height: CGFloat

  @State private var isHovered = false
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    configuration.label
      .labelStyle(.iconOnly)
      .font(Theme.font(13, weight: .medium))
      .foregroundStyle(isOn ? onColor : Theme.text.opacity(isEnabled ? 0.85 : 0.35))
      .frame(width: width, height: height)
      .padding(.horizontal, width == nil ? 8 : 0)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(LinearGradient(
            colors: configuration.isPressed
              ? [Theme.buttonBottom, Theme.buttonBottom]
              : [isHovered ? Theme.buttonTop.mix(with: .white, by: 0.06) : Theme.buttonTop, Theme.buttonBottom],
            startPoint: .top, endPoint: .bottom))
          .shadow(color: .black.opacity(0.45), radius: 0.5, y: 1)
      )
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.08)))
      .contentShape(.rect(cornerRadius: 5))
      .onHover { isHovered = $0 }
  }
}

/// Logic's small square mute, solo and record buttons: grey when off, coloured when on.
struct ChannelButton: View {
  let label: String
  let accessibilityName: String
  let isOn: Bool
  let onColor: Color
  var size = CGSize(width: 20, height: 17)
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(Theme.font(10, weight: .bold))
        .frame(width: size.width, height: size.height)
        .foregroundStyle(isOn ? Color.black.opacity(0.85) : Theme.secondaryText)
        .background(isOn ? onColor : Theme.raised, in: .rect(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.black.opacity(0.35)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityName)
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityIdentifier(accessibilityName.lowercased())
  }
}

/// A recessed dark field, as used for slots and readouts on channel strips.
struct ThemeSlot<Content: View>: View {
  var isActive = false
  var tint: Color = Theme.accent
  @ViewBuilder let content: () -> Content

  var body: some View {
    content()
      .font(Theme.font(10))
      .foregroundStyle(isActive ? Theme.text : Theme.tertiaryText)
      .lineLimit(1)
      .frame(maxWidth: .infinity)
      .frame(height: 17)
      .background(isActive ? tint.opacity(0.35) : Color.black.opacity(0.28), in: .rect(cornerRadius: 3))
      .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(isActive ? 0.12 : 0.05)))
  }
}

/// A panel section title, in Logic's small uppercase grey.
struct PanelHeading: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title.uppercased())
      .font(Theme.font(9, weight: .semibold))
      .tracking(0.6)
      .foregroundStyle(Theme.tertiaryText)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The colours of the LCD's backlit screen. The Display settings choose one.
struct LCDPalette: Equatable {
  var text: Color
  var caption: Color
  /// The backlight: tints the glass and makes the characters glow.
  var glow: Color
  var glassTop: Color
  var glassBottom: Color

  /// Cool white characters on blue-black glass, like Logic's display.
  static let blue = LCDPalette(
    text: Color(hex: 0xD8EEFF), caption: Color(hex: 0x6F8799), glow: Color(hex: 0x6CBCFF),
    glassTop: Color(hex: 0x17222C), glassBottom: Color(hex: 0x0C1217))
  /// A warm amber display, like vintage studio gear.
  static let amber = LCDPalette(
    text: Color(hex: 0xFFC76A), caption: Color(hex: 0xA07A3C), glow: Color(hex: 0xFFA42E),
    glassTop: Color(hex: 0x261A0C), glassBottom: Color(hex: 0x120C05))
  /// A green phosphor display.
  static let green = LCDPalette(
    text: Color(hex: 0xA8FF9E), caption: Color(hex: 0x5E9A57), glow: Color(hex: 0x4CFF5E),
    glassTop: Color(hex: 0x112215), glassBottom: Color(hex: 0x07110A))
  /// Neutral white on grey, without a tint.
  static let white = LCDPalette(
    text: Color(hex: 0xF2F2F4), caption: Color(hex: 0x8A8A90), glow: Color(hex: 0xC8C8D0),
    glassTop: Color(hex: 0x1E1F21), glassBottom: Color(hex: 0x101112))
}

extension EnvironmentValues {
  /// The LCD's colours, for the views drawn on it.
  @Entry var lcdPalette = LCDPalette.blue
}
