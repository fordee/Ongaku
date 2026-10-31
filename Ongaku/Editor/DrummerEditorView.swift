//
//  DrummerEditorView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// The Drummer editor, built around the drummer as a bandmate: pick who plays, steer them
/// on a pad from soft and simple to loud and busy, click drums on the kit to bring them in
/// or out, and see (and hear) the groove change as you go. The song strip across the top
/// shows every section the drummer plays, to move between them.
struct DrummerEditorView: View {
  let model: PianoRollModel
  let region: Region

  /// While the pad or a knob is being dragged: the performance it would make, so the groove
  /// preview follows the pointer before anything is committed.
  @State private var preview: DrummerPerformance?

  var body: some View {
    if let drummer = region.drummer {
      let shown = preview ?? drummer
      VStack(spacing: 0) {
        DrummerSongStrip(model: model, region: region, drummer: drummer)
        GeometryReader { proxy in
          let layout = Layout(fitting: proxy.size)
          ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 22) {
              StylePicker(model: model, selected: drummer.style)
              VStack(spacing: 10) {
                DrummerPad(model: model, drummer: drummer, size: layout.padSize, preview: $preview)
                GrooveView(
                  model: model, region: region, drummer: shown, isPreview: preview != nil,
                  width: layout.padSize.width - GrooveView.labelWidth - 6, height: layout.grooveHeight)
              }
              if layout.isStacked {
                // A narrow pane: the groove controls go under the kit.
                VStack(alignment: .leading, spacing: 16) {
                  DrumKitView(model: model, region: region, drummer: drummer, scale: layout.kitScale)
                  DrummerFeelControls(model: model, drummer: drummer, knobSize: layout.knobSize, preview: $preview)
                    .frame(width: layout.feelWidth)
                }
              } else {
                DrumKitView(model: model, region: region, drummer: drummer, scale: layout.kitScale)
                DrummerFeelControls(model: model, drummer: drummer, knobSize: layout.knobSize, preview: $preview)
                  .frame(width: layout.feelWidth)
              }
            }
            .padding(.horizontal, Layout.padding)
            .padding(.vertical, 12)
            // Centred across a wide pane and from the top down; scrolling in a small pane.
            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .top)
          }
        }
      }
      .background(Theme.lanes)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Drummer Editor")
    }
  }
}

/// How the editor fills its pane. Standard controls (pickers, buttons, text) keep their
/// usual size; the drawn parts grow into the space: the kit and the knobs with the height,
/// the pad and groove chart with the height and whatever width is left over.
private struct Layout {
  static let castWidth: CGFloat = 280
  static let spacing: CGFloat = 22
  static let padding: CGFloat = 16
  /// The kit as drawn at its natural size.
  static let kitSize = CGSize(width: 300, height: 170)

  var padSize: CGSize
  var grooveHeight: CGFloat
  var kitScale: CGFloat
  var knobSize: CGFloat
  var feelWidth: CGFloat
  /// Too narrow for four columns: the groove controls go under the kit.
  var isStacked: Bool

  static let smallestPadWidth: CGFloat = 260

  init(fitting size: CGSize) {
    let height = max(0, size.height - 24)
    let fourColumns = Self.castWidth + Self.smallestPadWidth + Self.kitSize.width * 0.84 + 160 + Self.spacing * 3
      + Self.padding * 2
    isStacked = size.width < fourColumns
    // The kit grows with the height (to a point; titles and the timekeeper picker take
    // about 70 points), but only into width left once the pad has its smallest size.
    let heightScale = (min(height, 380) - 70) / Self.kitSize.height
    let spareWidth = size.width - Self.castWidth - Self.smallestPadWidth - (isStacked ? 0 : 160)
      - Self.spacing * (isStacked ? 2 : 3) - Self.padding * 2
    kitScale = min(max(min(heightScale, spareWidth / Self.kitSize.width), 0.84), 1.5)
    knobSize = isStacked ? 46 : min(max(46 * kitScale, 46), 64)
    feelWidth = max(160, knobSize * 2 + 48)
    grooveHeight = min(max(height * 0.25, 66), 120)
    let fixedWidth = Self.castWidth + Self.kitSize.width * kitScale + (isStacked ? 0 : feelWidth)
      + Self.spacing * (isStacked ? 2 : 3) + Self.padding * 2
    // The pad fills what's left of the height (up to 300 points) and the width, but stays
    // landscape: no taller than two thirds of its width, no wider than 2.6 times its height.
    var padHeight = min(max(140, height - 22 - 10 - grooveHeight - 8), 300)
    let padWidth = min(max(Self.smallestPadWidth, size.width - fixedWidth), padHeight * 2.6)
    padHeight = max(120, min(padHeight, padWidth * 0.66))
    padSize = CGSize(width: padWidth, height: padHeight)
  }
}

// MARK: - The styles

/// How each style looks: a colour, a symbol, and a word or two about how it plays.
extension DrummerPerformance.Style {
  /// A few words for the style's card.
  var shortDescription: String {
    switch self {
    case .rock: "Big backbeat"
    case .pop: "Tight & bright"
    case .funk: "Ghost notes"
    case .hipHop: "Laid back"
    case .songwriter: "Gentle"
    case .electronic: "On the grid"
    case .shuffle: "Half-time triplets"
    }
  }

  var color: Color {
    switch self {
    case .rock: Color(hex: 0xE5713A)
    case .pop: Color(hex: 0xE45C9A)
    case .funk: Color(hex: 0x9B6BF0)
    case .hipHop: Color(hex: 0x2FB7A6)
    case .songwriter: Color(hex: 0xD9A73A)
    case .electronic: Color(hex: 0x4C8FE8)
    case .shuffle: Color(hex: 0xB5835A)
    }
  }

  var symbol: String {
    switch self {
    case .rock: "bolt.fill"
    case .pop: "sparkles"
    case .funk: "waveform.path"
    case .hipHop: "headphones"
    case .songwriter: "music.note"
    case .electronic: "dot.radiowaves.left.and.right"
    case .shuffle: "music.quarternote.3"
    }
  }
}

/// A style's badge: its symbol on its colour.
private struct StyleBadge: View {
  let style: DrummerPerformance.Style
  var size: CGFloat = 40

  var body: some View {
    Circle()
      .fill(LinearGradient(colors: [style.color, style.color.mix(with: .black, by: 0.45)], startPoint: .top, endPoint: .bottom))
      .overlay(
        Image(systemName: style.symbol)
          .font(.system(size: size * 0.42, weight: .bold))
          .foregroundStyle(.white))
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// The seven styles to choose from.
private struct StylePicker: View {
  let model: PianoRollModel
  let selected: DrummerPerformance.Style

  @State private var hovered: DrummerPerformance.Style?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionTitle("Style")
      LazyVGrid(columns: [GridItem(.fixed(136), spacing: 8), GridItem(.fixed(136), spacing: 8)], spacing: 6) {
        ForEach(DrummerPerformance.Style.allCases) { style in
          let isSelected = style == selected
          Button {
            model.editDrummer("Change Style") {
              $0.style = style
              $0.swing = style.defaultSwing
            }
          } label: {
            HStack(spacing: 8) {
              StyleBadge(style: style, size: isSelected ? 28 : 26)
              VStack(alignment: .leading, spacing: 1) {
                Text(style.title).font(Theme.font(12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(style.shortDescription).font(Theme.font(10))
                  .foregroundStyle(isSelected ? style.color : Theme.secondaryText)
                  .lineLimit(1)
                  .minimumScaleFactor(0.85)
              }
              Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .frame(width: 136, height: 44)
            .background(
              RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? style.color.opacity(0.16) : hovered == style ? Theme.raised : Theme.panel))
            .overlay(
              RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? style.color : Color.white.opacity(0.05), lineWidth: isSelected ? 2 : 1))
            .shadow(color: isSelected ? style.color.opacity(0.45) : .clear, radius: 8)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .onHover { hovered = $0 ? style : (hovered == style ? nil : hovered) }
          .help("\(style.title): \(style.summary)")
          .accessibilityLabel(style.title)
          .accessibilityHint(style.summary)
          .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
      }
      .frame(width: 280, alignment: .leading)
      Text(selected.summary)
        .font(Theme.font(11))
        .foregroundStyle(Theme.secondaryText)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 280, alignment: .leading)
    }
    .animation(.spring(duration: 0.3), value: selected)
  }
}

// MARK: - The song strip

/// The drummer's sections in song order: click one to edit it. Each shows how hard and how
/// busy it plays. On the right: hear this section, a new take, and more.
private struct DrummerSongStrip: View {
  let model: PianoRollModel
  let region: Region
  let drummer: DrummerPerformance

  @State private var diceTurns = 0.0
  /// The names of the drummer regions Match Song Sections would remove, while asking.
  @State private var regionsToRemove: [String] = []

  private var sections: [Region] {
    (model.track?.regions ?? []).filter { $0.drummer != nil }.sorted { $0.start < $1.start }
  }

  /// A section's name, or its bars when it isn't named after a part of the song.
  private func title(of section: Region) -> String {
    let isSongSection = ArrangementSection.suggestedNames.contains { $0.caseInsensitiveCompare(section.name) == .orderedSame }
      || model.window.project.arrangement.contains { $0.name == section.name }
    if isSongSection { return section.name }
    let tempoMap = model.window.project.tempoMap
    let first = tempoMap.bar(containing: section.start).index + 1
    let last = tempoMap.bar(containing: max(section.start, section.end - Tick(1))).index + 1
    return first == last ? "Bar \(first)" : "Bars \(first)–\(last)"
  }

  /// Song sections in their arrangement colours; anything else in the drummer's colour.
  private func color(of section: Region, drummer: DrummerPerformance) -> Color {
    if let arranged = model.window.project.arrangement.first(where: { $0.name == section.name }) {
      return arranged.color.color
    }
    let isSongSection = ArrangementSection.suggestedNames.contains { $0.caseInsensitiveCompare(section.name) == .orderedSame }
    return isSongSection ? ArrangementSection(name: section.name, start: .zero, length: Tick(1)).color.color : drummer.style.color
  }

  var body: some View {
    HStack(spacing: 10) {
      StyleBadge(style: drummer.style, size: 26)
      Text("\(drummer.style.title) drums")
        .font(Theme.font(12, weight: .semibold))
        .foregroundStyle(Theme.text)
        .fixedSize()
      Rectangle().fill(Theme.divider).frame(width: 1, height: 20)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(sections) { section in
            SectionChip(
              section: section, title: title(of: section), color: color(of: section, drummer: drummer),
              isSelected: section.id == region.id
            ) {
              model.window.select(section.id, extending: false)
              model.window.openEditor(for: section.id)
            }
          }
        }
      }
      if let trackID = model.track?.id, !model.window.drummerMatchesSections(on: trackID) {
        Button {
          // Removing regions loses their settings, so that's asked about first.
          if let match = model.window.drummerSectionMatch(on: trackID), !match.removed.isEmpty {
            regionsToRemove = match.removed.map(\.name)
          } else {
            model.window.matchDrummerToSections(on: trackID)
          }
        } label: {
          Label("Match Song Sections", systemImage: "rectangle.split.3x1")
            .font(Theme.font(11, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().strokeBorder(drummer.style.color, lineWidth: 1.5))
            .foregroundStyle(Theme.text)
        }
        .buttonStyle(.plain)
        .help("Give each arrangement section (Intro, Verse, Chorus…) its own drummer region, played to suit it")
        .confirmationDialog(
          "Remove the drummer regions for sections that are gone?",
          isPresented: Binding(get: { !regionsToRemove.isEmpty }, set: { if !$0 { regionsToRemove = [] } }),
          titleVisibility: .visible
        ) {
          Button(regionsToRemove.count == 1 ? "Match and Remove 1 Region" : "Match and Remove \(regionsToRemove.count) Regions",
            role: .destructive) {
            model.window.matchDrummerToSections(on: trackID)
          }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("\(regionsToRemove.formatted(.list(type: .and))) and their settings go. Sections that are still in the song keep theirs. You can undo this.")
        }
      } else if model.window.project.arrangement.isEmpty {
        Text("Tip: add arrangement markers (Track ▸ Add Arrangement Marker) and the drummer plays each section its own way")
          .font(Theme.font(10))
          .foregroundStyle(Theme.tertiaryText)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      let isPlayingHere = model.window.engine.isPlaying && model.window.project.cycle.isEnabled
        && model.window.project.cycle.start == region.start && model.window.project.cycle.end == region.end
      Button {
        if isPlayingHere {
          model.window.engine.stop()
        } else {
          model.window.perform(SetCycle(CycleRange(isEnabled: true, start: region.start, end: region.end)), named: "Play Section")
          if model.window.engine.isPlaying { model.window.engine.stop() }
          model.window.engine.locate(to: region.start)
          model.window.engine.play()
        }
      } label: {
        Label(isPlayingHere ? "Stop" : "Play Section", systemImage: isPlayingHere ? "stop.fill" : "play.fill")
          .font(Theme.font(11, weight: .semibold))
          .padding(.horizontal, 10)
          .frame(height: 26)
          .background(Capsule().fill(isPlayingHere ? Theme.stop.opacity(0.85) : Theme.play.opacity(0.85)))
          .foregroundStyle(.white)
      }
      .buttonStyle(.plain)
      .help(isPlayingHere ? "Stop playing" : "Loop this section, to hear changes as you make them")
      Button {
        withAnimation(.spring(duration: 0.5)) { diceTurns += 1 }
        model.newDrummerTake()
      } label: {
        Label("New Take", systemImage: "dice.fill")
          .font(Theme.font(11, weight: .semibold))
          .padding(.horizontal, 10)
          .frame(height: 26)
          .background(Capsule().fill(Theme.raised))
          .foregroundStyle(Theme.text)
          .rotationEffect(.degrees(diceTurns * 360), anchor: .center)
      }
      .buttonStyle(.plain)
      .help("Same settings, played a different way")
      Menu {
        Toggle("Fill into the Next Section", isOn: Binding(get: { drummer.fillsAtEnd }, set: { value in
          model.editDrummer("Drummer Fill") { $0.fillsAtEnd = value }
        }))
        Toggle("Crash as the Section Starts", isOn: Binding(get: { drummer.crashesAtStart }, set: { value in
          model.editDrummer("Drummer Crash") { $0.crashesAtStart = value }
        }))
        Divider()
        Button("Convert to MIDI Region") { model.convertDrummerToNotes() }
      } label: {
        Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(Theme.secondaryText)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("More")
      .accessibilityLabel("More drummer options")
    }
    .padding(.horizontal, 12)
    .frame(height: 42)
    .background(Theme.panel)
    .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
  }
}

/// One section of the song: its name, and bars for how loud and busy the drummer plays it.
private struct SectionChip: View {
  let section: Region
  let title: String
  let color: Color
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    let drummer = section.drummer
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title).font(Theme.font(11, weight: isSelected ? .semibold : .medium)).lineLimit(1)
        HStack(alignment: .bottom, spacing: 2) {
          meter(drummer?.loudness ?? 0)
          meter(drummer?.complexity ?? 0)
        }
        .frame(height: 14)
      }
      .padding(.horizontal, 9)
      .frame(height: 26)
      .foregroundStyle(isSelected ? Color.white : Theme.text)
      .background(Capsule().fill(isSelected ? color : color.opacity(0.22)))
      .overlay(Capsule().strokeBorder(color.opacity(isSelected ? 0 : 0.6), lineWidth: 1))
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .help("\(title): \(Int((drummer?.loudness ?? 0) * 100)) % loud, \(Int((drummer?.complexity ?? 0) * 100)) % busy")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func meter(_ value: Double) -> some View {
    RoundedRectangle(cornerRadius: 1)
      .fill(Color.white.opacity(0.85))
      .frame(width: 3, height: max(2, 14 * value))
  }
}

// MARK: - The pad

/// Steer the drummer: across from simple to busy, up from soft to loud. The groove below
/// follows while dragging; the part is played again when the drag ends.
private struct DrummerPad: View {
  let model: PianoRollModel
  let drummer: DrummerPerformance
  let size: CGSize
  @Binding var preview: DrummerPerformance?

  @State private var isDragging = false

  var body: some View {
    let shown = preview ?? drummer
    let point = CGPoint(x: shown.complexity, y: shown.loudness)
    let color = drummer.style.color
    VStack(alignment: .leading, spacing: 8) {
      SectionTitle("Loud or Soft, Busy or Simple")
      field(point: point, color: color)
      .accessibilityElement()
      .accessibilityLabel("Loudness and busyness")
      .accessibilityValue(spoken(point))
      .accessibilityAdjustableAction { nudge(loudness: $0 == .increment ? 0.1 : -0.1) }
      // The pad has two axes; incrementing only reaches one, so each direction is an action.
      .accessibilityAction(named: "Louder") { nudge(loudness: 0.1) }
      .accessibilityAction(named: "Softer") { nudge(loudness: -0.1) }
      .accessibilityAction(named: "Busier") { nudge(complexity: 0.1) }
      .accessibilityAction(named: "Simpler") { nudge(complexity: -0.1) }
      .help("Drag the dot: right for a busier part, up for a louder one")
    }
  }

  /// The pad itself: the field of dots, the corner labels and the dot, dragged to set
  /// both. (Its own function, so the body's modifier chains stay short enough for previews
  /// to type-check.)
  private func field(point: CGPoint, color: Color) -> some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 12)
        .fill(LinearGradient(
          colors: [color.opacity(0.08), color.opacity(0.55)], startPoint: .bottomLeading, endPoint: .topTrailing))
      RoundedRectangle(cornerRadius: 12).fill(Theme.window.opacity(0.35))
      // A field of dots, brighter toward the puck.
      Canvas { context, size in
        let columns = max(12, Int(size.width / 22))
        let rows = max(6, Int(size.height / 22))
        for column in 0...columns {
          for row in 0...rows {
            let x = CGFloat(column) / CGFloat(columns) * (size.width - 24) + 12
            let y = CGFloat(row) / CGFloat(rows) * (size.height - 24) + 12
            let puck = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
            let distance = hypot(x - puck.x, y - puck.y)
            let glow = max(0, 1 - distance / 120)
            context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)),
              with: .color(Color.white.opacity(0.08 + 0.5 * glow)))
          }
        }
      }
      cornerLabel("Loud & Simple", alignment: .topLeading)
      cornerLabel("Loud & Busy", alignment: .topTrailing)
      cornerLabel("Soft & Simple", alignment: .bottomLeading)
      cornerLabel("Soft & Busy", alignment: .bottomTrailing)
      Circle()
        .fill(Color.white)
        .overlay(Circle().strokeBorder(color, lineWidth: 4))
        .frame(width: isDragging ? 26 : 22, height: isDragging ? 26 : 22)
        .shadow(color: color.opacity(0.9), radius: isDragging ? 14 : 8)
        .position(x: point.x * size.width, y: (1 - point.y) * size.height)
        .allowsHitTesting(false)
    }
    .frame(width: size.width, height: size.height)
    .clipShape(.rect(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(0.5), lineWidth: 1))
    .contentShape(.rect)
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { drag in
          if !isDragging { withAnimation(.spring(duration: 0.2)) { isDragging = true } }
          var moved = preview ?? drummer
          moved.complexity = Double(min(max(drag.location.x / size.width, 0), 1))
          moved.loudness = Double(min(max(1 - drag.location.y / size.height, 0), 1))
          preview = moved
        }
        .onEnded { _ in
          withAnimation(.spring(duration: 0.2)) { isDragging = false }
          guard let preview else { return }
          let complexity = preview.complexity, loudness = preview.loudness
          model.editDrummer("Drummer Pad") {
            $0.complexity = complexity
            $0.loudness = loudness
          }
          self.preview = nil
        }
    )
  }

  /// Where the dot is, for VoiceOver.
  private func spoken(_ point: CGPoint) -> String {
    let loud = Int(point.y * 100), busy = Int(point.x * 100)
    return "\(loud) % loud, \(busy) % busy"
  }

  /// Moves the dot a step, from VoiceOver. (A method, so the long modifier chain above
  /// type-checks quickly, which previews need.)
  private func nudge(loudness: Double = 0, complexity: Double = 0) {
    model.editDrummer("Drummer Pad") {
      $0.loudness += loudness
      $0.complexity += complexity
    }
  }

  private func cornerLabel(_ text: String, alignment: Alignment) -> some View {
    Text(text)
      .font(Theme.font(9, weight: .semibold))
      .foregroundStyle(Color.white.opacity(0.55))
      .padding(8)
      .frame(width: size.width, height: size.height, alignment: alignment)
      .allowsHitTesting(false)
  }
}

// MARK: - The groove

/// The first bars of the part (two, or four when wide) as a little drum chart, a row for each part of the kit
/// with a dot for each hit (bigger for harder). It follows the pad while dragging, and
/// shows where the song is while it plays.
private struct GrooveView: View {
  let model: PianoRollModel
  let region: Region
  let drummer: DrummerPerformance
  let isPreview: Bool
  let width: CGFloat
  let height: CGFloat

  static let labelWidth: CGFloat = 38

  static let rows: [(name: String, pitches: Set<Int>)] = [
    ("Cymbals", [49, 51]), ("Hi-Hat", [42, 44, 46]), ("Toms", [45, 47, 50]), ("Snare", [37, 38, 39]), ("Kick", [36]),
    ("Perc", [56, 70]),
  ]

  /// As wide as the pad, with the row names beside it.
  private var size: CGSize { CGSize(width: width, height: height) }

  var body: some View {
    let tempoMap = model.window.project.tempoMap
    let firstBar = tempoMap.bar(containing: region.start)
    // Two bars, or four once there's room for them.
    let bars = width > 440 ? 4 : 2
    let shownBars = tempoMap.tickPosition(ofBarIndex: firstBar.index + bars) - region.start
    let span = min(region.length, shownBars)
    // While previewing, play the part in memory; otherwise read the region's notes.
    let notes = isPreview ? drummer.notes(from: region.start, length: span, tempoMap: tempoMap) : regionNotes(before: span)
    let color = drummer.style.color
    HStack(spacing: 6) {
      VStack(alignment: .trailing, spacing: 0) {
        ForEach(Self.rows, id: \.name) { row in
          Text(row.name).font(Theme.font(8, weight: .medium)).foregroundStyle(Theme.tertiaryText)
            .frame(width: Self.labelWidth, height: size.height / CGFloat(Self.rows.count), alignment: .trailing)
        }
      }
      Canvas { context, size in
        let rowHeight = size.height / CGFloat(Self.rows.count)
        // Beats, lighter on the bar lines.
        var beat = Tick(0)
        let beatLength = tempoMap.timeSignature(atBarIndex: firstBar.index).pulse
        while beat < span {
          let x = CGFloat(beat.rawValue) / CGFloat(span.rawValue) * size.width
          let isBar = tempoMap.bar(containing: region.start + beat).start == region.start + beat
          context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
            with: .color(Color.white.opacity(isBar ? 0.18 : 0.06)))
          beat += beatLength
        }
        for note in notes {
          guard let row = Self.rows.firstIndex(where: { $0.pitches.contains(note.pitch) }) else { continue }
          let x = CGFloat(note.start.rawValue) / CGFloat(span.rawValue) * size.width
          let strength = Double(note.velocity) / 127
          let diameter = 3 + 6 * strength
          let rect = CGRect(x: x - diameter / 2 + 3, y: CGFloat(row) * rowHeight + (rowHeight - diameter) / 2,
            width: diameter, height: diameter)
          context.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.35 + 0.65 * strength)))
        }
      }
      .frame(width: size.width, height: size.height)
      .padding(.vertical, 4)
      .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
      .overlay { GroovePlayhead(model: model, region: region, span: span, width: size.width) }
    }
    .accessibilityElement()
    .accessibilityLabel("Groove")
    .accessibilityValue("\(notes.count) hits in the first \(bars) bars")
  }

  private func regionNotes(before span: Tick) -> [MIDINote] {
    guard case .midi(let sequence) = region.content else { return [] }
    return sequence.notes.filter { $0.start < span }
  }
}

/// The song's position across the groove chart, while it plays in the first two bars.
private struct GroovePlayhead: View {
  let model: PianoRollModel
  let region: Region
  let span: Tick
  let width: CGFloat

  var body: some View {
    let engine = model.window.engine
    TimelineView(.animation(minimumInterval: 1 / 30, paused: !engine.isPlaying)) { _ in
      let position = engine.playheadPosition - region.start
      if engine.isPlaying, position >= .zero, span > .zero {
        // Past two bars it loops round, so the chart always shows where the beat is.
        let wrapped = Tick(position.rawValue % span.rawValue)
        Rectangle()
          .fill(Color.white.opacity(0.8))
          .frame(width: 1.5)
          .offset(x: CGFloat(wrapped.rawValue) / CGFloat(span.rawValue) * width - width / 2)
      }
    }
    .allowsHitTesting(false)
  }
}

// MARK: - The kit

/// A drum kit from above. Click a drum to bring its part of the kit in or out; while the
/// song plays, each drum lights as it's hit.
private struct DrumKitView: View {
  let model: PianoRollModel
  let region: Region
  let drummer: DrummerPerformance
  /// The drawing's size, against its natural 300 × 170.
  let scale: CGFloat

  enum Piece: CaseIterable {
    case crash, hiHat, ride, highTom, midTom, floorTom, snare, kick, shaker

    var name: String {
      switch self {
      case .crash: "Crash"
      case .hiHat: "Hi-Hat"
      case .ride: "Ride"
      case .highTom: "High Tom"
      case .midTom: "Mid Tom"
      case .floorTom: "Floor Tom"
      case .snare: "Snare"
      case .kick: "Kick"
      case .shaker: "Shaker"
      }
    }

    var pitches: Set<Int> {
      switch self {
      case .crash: [49]
      case .hiHat: [42, 44, 46]
      case .ride: [51]
      case .highTom: [50]
      case .midTom: [47]
      case .floorTom: [45]
      case .snare: [37, 38, 39]
      case .kick: [36]
      case .shaker: [70, 56]
      }
    }

    /// Where it sits in a 300 × 170 kit, and how big it is.
    var frame: CGRect {
      switch self {
      case .crash: CGRect(x: 18, y: 8, width: 70, height: 70)
      case .hiHat: CGRect(x: 6, y: 84, width: 56, height: 56)
      case .ride: CGRect(x: 214, y: 6, width: 80, height: 80)
      case .highTom: CGRect(x: 98, y: 26, width: 46, height: 46)
      case .midTom: CGRect(x: 150, y: 26, width: 50, height: 50)
      case .floorTom: CGRect(x: 214, y: 94, width: 62, height: 62)
      case .snare: CGRect(x: 66, y: 92, width: 56, height: 56)
      case .kick: CGRect(x: 124, y: 86, width: 76, height: 76)
      case .shaker: CGRect(x: 268, y: 140, width: 26, height: 26)
      }
    }

    var isCymbal: Bool { self == .crash || self == .hiHat || self == .ride }
  }

  private func isOn(_ piece: Piece) -> Bool {
    switch piece {
    case .crash, .hiHat, .ride: drummer.playsCymbals
    case .highTom, .midTom, .floorTom: drummer.playsToms
    case .snare, .kick: drummer.playsKickAndSnare
    case .shaker: drummer.playsPercussion
    }
  }

  /// Clicking a drum brings its part of the kit in or out.
  private func toggle(_ piece: Piece) {
    let on = !isOn(piece)
    switch piece {
    case .crash, .hiHat, .ride: model.editDrummer(on ? "Add Cymbals" : "Remove Cymbals") { $0.playsCymbals = on }
    case .highTom, .midTom, .floorTom: model.editDrummer(on ? "Add Toms" : "Remove Toms") { $0.playsToms = on }
    case .snare, .kick: model.editDrummer(on ? "Add Kick & Snare" : "Remove Kick & Snare") { $0.playsKickAndSnare = on }
    case .shaker: model.editDrummer(on ? "Add Percussion" : "Remove Percussion") { $0.playsPercussion = on }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionTitle("The Kit")
      TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.window.engine.isPlaying)) { _ in
        let lit = litPieces()
        ZStack(alignment: .topLeading) {
          RoundedRectangle(cornerRadius: 12).fill(Theme.panel)
          // The rug.
          Ellipse().fill(drummer.style.color.opacity(0.1)).frame(width: 250, height: 150).offset(x: 25, y: 12)
          ForEach(Piece.allCases, id: \.self) { piece in
            KitPieceView(piece: piece, isOn: isOn(piece), isLit: lit.contains(piece), color: drummer.style.color) {
              toggle(piece)
            }
            .offset(x: piece.frame.minX, y: piece.frame.minY)
          }
        }
        .frame(width: 300, height: 170)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: 300 * scale, height: 170 * scale, alignment: .topLeading)
      }
      Picker("Time on", selection: Binding(get: { drummer.timekeeper }, set: { value in
        model.editDrummer("Drummer Timekeeper") { $0.timekeeper = value }
      })) {
        Text("Hi-Hat").tag(DrummerPerformance.Timekeeper.hiHat)
        Text("Auto").tag(DrummerPerformance.Timekeeper.automatic)
        Text("Ride").tag(DrummerPerformance.Timekeeper.ride)
      }
      .pickerStyle(.segmented)
      .controlSize(.small)
      .font(Theme.font(11))
      .frame(width: min(300 * scale, 300))
      .help("What keeps time. Auto opens up to the ride when the part gets loud.")
    }
  }

  /// The drums hit in the last moment, while the song plays through the region.
  private func litPieces() -> Set<Piece> {
    let engine = model.window.engine
    guard engine.isPlaying, case .midi(let sequence) = region.content else { return [] }
    let position = engine.playheadPosition - region.start
    guard position >= .zero, position < region.length else { return [] }
    let recent = Tick(110)
    var lit: Set<Piece> = []
    for note in sequence.notes where note.start <= position && note.start > position - recent {
      if let piece = Piece.allCases.first(where: { $0.pitches.contains(note.pitch) }) { lit.insert(piece) }
    }
    return lit
  }
}

private struct KitPieceView: View {
  let piece: DrumKitView.Piece
  let isOn: Bool
  let isLit: Bool
  let color: Color
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    let size = piece.frame.size
    Button(action: action) {
      ZStack {
        if piece.isCymbal {
          // Brass, with rings.
          Circle()
            .fill(RadialGradient(
              colors: [Color(hex: 0xE8C76A), Color(hex: 0xA9822F), Color(hex: 0x7A5B1E)], center: .center, startRadius: 2,
              endRadius: size.width / 2))
          ForEach([0.35, 0.65], id: \.self) { ring in
            Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 1).padding(size.width * ring / 2)
          }
          Circle().fill(Color(hex: 0x3A2C10)).frame(width: 6, height: 6)
        } else if piece == .shaker {
          Capsule().fill(Color(hex: 0xC9A06B)).frame(width: size.width * 0.5, height: size.height)
        } else {
          // A drum: a coloured shell and a pale head.
          Circle().fill(color.mix(with: .black, by: 0.35))
          Circle()
            .fill(RadialGradient(colors: [Color(hex: 0xF4F1EA), Color(hex: 0xCFCAC0)], center: .center, startRadius: 1,
              endRadius: size.width / 2))
            .padding(4)
          if piece == .kick {
            Text("ongaku").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(color.opacity(0.8))
          }
        }
        if isLit {
          Circle().fill(Color.white.opacity(0.55)).blendMode(.plusLighter)
        }
      }
      .frame(width: size.width, height: size.height)
      .opacity(isOn ? 1 : 0.22)
      .saturation(isOn ? 1 : 0)
      .scaleEffect(isLit ? 1.06 : isHovered ? 1.03 : 1)
      .shadow(color: isLit ? color : .black.opacity(0.4), radius: isLit ? 10 : 3, y: isLit ? 0 : 2)
      .overlay {
        if !isOn {
          Circle().strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
      }
      .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .onHover { hovered in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovered } }
    .animation(.easeOut(duration: 0.08), value: isLit)
    .help(isOn ? "\(piece.name): click to leave it out" : "\(piece.name): click to bring it in")
    .accessibilityLabel(piece.name)
    .accessibilityValue(isOn ? "Playing" : "Left out")
  }
}

// MARK: - Fills, swing and feel

private struct DrummerFeelControls: View {
  let model: PianoRollModel
  let drummer: DrummerPerformance
  let knobSize: CGFloat
  @Binding var preview: DrummerPerformance?

  var body: some View {
    VStack(alignment: .center, spacing: 10) {
      SectionTitle("Groove")
      HStack(alignment: .top, spacing: 12) {
      knob("Fills", value: (preview ?? drummer).fills, words: ["None", "A few", "Some", "Lots"]) { value in
        var changed = preview ?? drummer
        changed.fills = value
        preview = changed
      } commit: { value in
        model.editDrummer("Drummer Fills") { $0.fills = value }
        preview = nil
      }
      // In the Purdie Shuffle the triplets are the swing, so the knob sets the ghost notes.
      let isShuffle = drummer.style == .shuffle
      knob(
        isShuffle ? "Ghosts" : "Swing", value: (preview ?? drummer).swing,
        words: isShuffle ? ["Whisper", "Soft", "Present", "Hard"] : ["Straight", "A little", "Swung", "Shuffle"]
      ) { value in
        var changed = preview ?? drummer
        changed.swing = value
        preview = changed
      } commit: { value in
        model.editDrummer("Drummer Swing") { $0.swing = value }
        preview = nil
      }
      }
      VStack(spacing: 6) {
        Text("Feel").font(Theme.font(10, weight: .semibold)).foregroundStyle(Theme.secondaryText)
        HStack(spacing: 4) {
          feelButton(.halfTime, symbol: "tortoise.fill", help: "Half time: the backbeat once a bar, for a big, slow feel")
          feelButton(.normal, symbol: "figure.walk", help: "Normal")
          feelButton(.doubleTime, symbol: "hare.fill", help: "Double time: twice as driving")
        }
        Text(drummer.feel.title).font(Theme.font(10)).foregroundStyle(Theme.text)
      }
    }
  }

  private func knob(
    _ name: String, value: Double, words: [String], change: @escaping (Double) -> Void, commit: @escaping (Double) -> Void
  ) -> some View {
    VStack(spacing: 4) {
      Text(name).font(Theme.font(10, weight: .semibold)).foregroundStyle(Theme.secondaryText)
      Knob(
        value: value, range: 0...1, defaultValue: 0, size: knobSize, tint: drummer.style.color, label: name,
        valueText: { "\(Int($0 * 100)) %" }, onChange: change, onCommit: commit)
      Text(words[min(words.count - 1, Int(value * Double(words.count)))])
        .font(Theme.font(10))
        .foregroundStyle(Theme.text)
        .frame(width: 70)
    }
  }

  private func feelButton(_ feel: DrummerPerformance.Feel, symbol: String, help: String) -> some View {
    let isSelected = drummer.feel == feel
    return Button {
      model.editDrummer("Drummer Feel") { $0.feel = feel }
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 34, height: 28)
        .foregroundStyle(isSelected ? Color.white : Theme.secondaryText)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? drummer.style.color : Theme.raised))
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(feel.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct SectionTitle: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text.uppercased())
      .font(Theme.font(10, weight: .bold))
      .tracking(0.8)
      .foregroundStyle(Theme.secondaryText)
  }
}

/// Holds the window model for the preview (the editor's model only keeps an unowned
/// reference to it).
private struct DrummerEditorPreview: View {
  var hasSections = true
  var bars = 24
  var style = DrummerPerformance.Style.funk
  var size = CGSize(width: 1100, height: 330)

  var body: some View {
    DrummerEditorPreviewContent(window: Self.makeWindow(hasSections: hasSections, bars: bars, style: style))
      .frame(width: size.width, height: size.height)
  }

  static func makeWindow(hasSections: Bool, bars: Int, style: DrummerPerformance.Style) -> ProjectWindowModel {
    var project = Project()
    var song = Track(name: "Bass", kind: .softwareInstrument)
    song.regions = [Region(name: "Bass", start: .zero, length: Tick(3840 * Int64(bars)), content: .midi(MIDISequence()))]
    project.tracks = [song]
    guard hasSections else {
      let window = ProjectWindowModel(document: OngakuDocument(project: project))
      window.addDrummerTrack(style: .songwriter)
      return window
    }
    project.arrangement = [
      ArrangementSection(name: "Intro", start: .zero, length: Tick(3840 * 4)),
      ArrangementSection(name: "Verse", start: Tick(3840 * 4), length: Tick(3840 * 8)),
      ArrangementSection(name: "Chorus", start: Tick(3840 * 12), length: Tick(3840 * 8)),
      ArrangementSection(name: "Outro", start: Tick(3840 * 20), length: Tick(3840 * 4)),
    ]
    let window = ProjectWindowModel(document: OngakuDocument(project: project))
    window.addDrummerTrack(style: style)
    if let verse = window.project.tracks.last?.regions.dropFirst().first {
      window.select(verse.id, extending: false)
      window.openEditor(for: verse.id)
    }
    return window
  }
}

private struct DrummerEditorPreviewContent: View {
  @State var window: ProjectWindowModel

  var body: some View {
    if let region = window.pianoRoll.region {
      DrummerEditorView(model: window.pianoRoll, region: region)
    }
  }
}

#Preview("Drummer Editor") {
  DrummerEditorPreview()
}

#Preview("Purdie Shuffle") {
  DrummerEditorPreview(style: .shuffle)
}

#Preview("Full Screen") {
  DrummerEditorPreview(size: CGSize(width: 2400, height: 560))
}

#Preview("Long Song, Short Pane") {
  DrummerEditorPreview(hasSections: false, bars: 89, size: CGSize(width: 1300, height: 240))
}

#Preview("Tall, Narrow Pane") {
  DrummerEditorPreview(hasSections: false, bars: 89, size: CGSize(width: 900, height: 720))
}

#Preview("No Sections, Big Pane") {
  DrummerEditorPreview(hasSections: false, size: CGSize(width: 1600, height: 480))
}
