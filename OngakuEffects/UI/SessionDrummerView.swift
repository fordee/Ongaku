//
//  SessionDrummerView.swift
//  OngakuEffects
//

import AppKit
import OngakuCore
import SwiftUI
import UniformTypeIdentifiers

/// The Session Drummer's window: the song's sections across the top (with preview, and the
/// part to drag into the host as MIDI), then the selected section's drummer: style, the pad,
/// the kit and the groove; and at the bottom, how it sounds (its own kit, or MIDI out).
struct SessionDrummerView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters
  @State var model: SessionDrummerModel

  var body: some View {
    VStack(spacing: 0) {
      SongStrip(audioUnit: audioUnit, parameters: parameters, model: model)
      SectionBar(model: model)
      HStack(alignment: .top, spacing: 22) {
        StylePicker(model: model)
        VStack(spacing: 10) {
          DrummerPad(model: model)
          GrooveChart(audioUnit: audioUnit, model: model)
        }
        KitView(audioUnit: audioUnit, model: model)
        FeelControls(model: model)
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      SoundBar(parameters: parameters)
    }
    .background(EffectStyle.background)
  }
}

// MARK: - Styles

extension DrummerPerformance.Style {
  fileprivate var shortDescription: String {
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

  fileprivate var color: Color {
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

  fileprivate var symbol: String {
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

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
  }
}

/// A section's colour, by name, as on an arrangement track.
private func sectionColor(_ name: String) -> Color {
  switch name.lowercased() {
  case "intro": Color(hex: 0x2FB7A6)
  case "verse": Color(hex: 0x4C8FE8)
  case "pre-chorus": Color(hex: 0x9B6BF0)
  case "chorus": Color(hex: 0xE58A3A)
  case "bridge": Color(hex: 0xE45C9A)
  case "solo": Color(hex: 0xD9BC3A)
  case "breakdown": Color(hex: 0x6C8A9E)
  case "outro": Color(hex: 0xDC5148)
  default: Color(white: 0.45)
  }
}

private struct StyleBadge: View {
  let style: DrummerPerformance.Style
  var size: CGFloat = 30

  var body: some View {
    Circle()
      .fill(LinearGradient(colors: [style.color, style.color.mix(with: .black, by: 0.45)], startPoint: .top, endPoint: .bottom))
      .overlay(Image(systemName: style.symbol).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white))
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

private struct Title: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text.uppercased())
      .font(.system(size: 10, weight: .bold))
      .tracking(0.8)
      .foregroundStyle(EffectStyle.label)
  }
}

// MARK: - The song

/// The song's sections in order, the part's place in them as it plays, and the part to take
/// away: preview it, drag it into the host as MIDI, or save it.
private struct SongStrip: View {
  let audioUnit: OngakuEffectsAudioUnit
  let parameters: EffectParameters
  let model: SessionDrummerModel

  var body: some View {
    HStack(spacing: 10) {
      Title("Song")
      TimelineView(.animation(minimumInterval: 1 / 15)) { _ in
        let playing = playingSectionIndex()
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(Array(model.song.sections.enumerated()), id: \.element.id) { index, section in
              SectionChip(
                section: section, isSelected: section.id == model.selectedSectionID, isPlaying: playing == index
              ) { model.selectedSectionID = section.id }
            }
            Menu {
              ForEach(SessionDrummerModel.sectionNames, id: \.self) { name in
                Button(name) { model.addSection(named: name) }
              }
            } label: {
              Image(systemName: "plus").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
                .background(Circle().fill(Color(white: 0.2)))
                .foregroundStyle(EffectStyle.value)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a section after the selected one")
            .accessibilityLabel("Add Section")
          }
          .padding(.vertical, 2)
        }
      }
      Toggle("Repeat", isOn: Binding(get: { model.song.repeats }, set: { model.setRepeats($0) }))
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .fixedSize()
        .help("After the last section, start again from the first (otherwise the last one carries on)")
      Spacer(minLength: 8)
      if let preview = parameters["preview"] {
        Button {
          preview.boolValue.toggle()
        } label: {
          Label(preview.boolValue ? "Stop" : "Preview", systemImage: preview.boolValue ? "stop.fill" : "play.fill")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(preview.boolValue ? Color(hex: 0xE5484D) : Color(hex: 0x3FCF62)))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help("Hear the drummer while your song is stopped (it follows your song when it plays)")
      }
      MIDIDragHandle(audioUnit: audioUnit, model: model)
      Button {
        exportMIDI()
      } label: {
        Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
          .frame(width: 26, height: 26)
          .background(Circle().fill(Color(white: 0.2)))
          .foregroundStyle(EffectStyle.value)
      }
      .buttonStyle(.plain)
      .help("Save the part as a MIDI file")
      .accessibilityLabel("Export MIDI")
    }
    .padding(.horizontal, 14)
    .frame(height: 48)
    .background(Color(white: 0.11))
    .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1) }
  }

  /// Which section is playing (from where the part is), or nil when stopped.
  private func playingSectionIndex() -> Int? {
    let position = Double(OngakuMeterValue(audioUnit.meters, .partPosition))
    guard position >= 0 else { return nil }
    let beatsPerBar = model.controller.signature.ticksPerBar.quarterNotes
    guard beatsPerBar > 0 else { return nil }
    return model.song.section(atBar: Int(position / beatsPerBar))?.index
  }

  private func exportMIDI() {
    let tempo = Double(OngakuMeterValue(audioUnit.meters, .tempo))
    guard let file = model.writeMIDIFile(tempo: tempo) else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType.midi]
    panel.nameFieldStringValue = file.lastPathComponent
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      try? FileManager.default.removeItem(at: url)
      try? FileManager.default.copyItem(at: file, to: url)
    }
  }
}

private struct SectionChip: View {
  let section: DrummerSong.Section
  let isSelected: Bool
  let isPlaying: Bool
  let action: () -> Void

  var body: some View {
    let color = sectionColor(section.name)
    Button(action: action) {
      HStack(spacing: 6) {
        if isPlaying {
          Image(systemName: "speaker.wave.2.fill").font(.system(size: 9, weight: .bold))
        }
        Text(section.name).font(.system(size: 11, weight: isSelected ? .semibold : .medium)).lineLimit(1)
        Text("\(section.bars)").font(.system(size: 10, weight: .bold).monospacedDigit())
          .padding(.horizontal, 5).padding(.vertical, 1)
          .background(Capsule().fill(Color.black.opacity(0.25)))
      }
      .padding(.horizontal, 10)
      .frame(height: 26)
      .foregroundStyle(isSelected ? Color.white : EffectStyle.value)
      .background(Capsule().fill(isSelected ? color : color.opacity(0.22)))
      .overlay(Capsule().strokeBorder(isPlaying ? Color.white : color.opacity(isSelected ? 0 : 0.6), lineWidth: isPlaying ? 2 : 1))
      .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .help("\(section.name): \(section.bars) bars")
    .accessibilityLabel("\(section.name), \(section.bars) bars")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// Drag this into the host's tracks to drop the part in as a MIDI region.
private struct MIDIDragHandle: View {
  let audioUnit: OngakuEffectsAudioUnit
  let model: SessionDrummerModel

  var body: some View {
    Label("Drag MIDI", systemImage: "hand.draw.fill")
      .font(.system(size: 11, weight: .semibold))
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(Capsule().fill(Color(white: 0.2)))
      .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
      .foregroundStyle(EffectStyle.value)
      .contentShape(.capsule)
      .onDrag {
        let tempo = Double(OngakuMeterValue(audioUnit.meters, .tempo))
        guard let url = model.writeMIDIFile(tempo: tempo), let provider = NSItemProvider(contentsOf: url) else {
          return NSItemProvider()
        }
        provider.suggestedName = url.lastPathComponent
        return provider
      }
      .help("Drag the whole part into your song as a MIDI region, to play with your own drum instrument or edit")
      .accessibilityLabel("Drag MIDI")
  }
}

/// The selected section: its name, length and place in the song, and a new take.
private struct SectionBar: View {
  let model: SessionDrummerModel

  @State private var diceTurns = 0.0

  var body: some View {
    HStack(spacing: 10) {
      if let section = model.selectedSection {
        Menu {
          ForEach(SessionDrummerModel.sectionNames, id: \.self) { name in
            Button(name) { model.renameSelected(name) }
          }
        } label: {
          HStack(spacing: 4) {
            Text(section.name).font(.system(size: 13, weight: .bold))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(EffectStyle.label)
          }
          .foregroundStyle(sectionColor(section.name))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rename the section; it's played to suit its new name")
        Text("bars \(model.selectedStartBar + 1)–\(model.selectedStartBar + section.bars)")
          .font(.system(size: 11).monospacedDigit())
          .foregroundStyle(EffectStyle.label)
        Stepper(
          "\(section.bars) bars", value: Binding(get: { section.bars }, set: { model.setBars($0) }), in: DrummerSong.barsRange
        )
        .font(.system(size: 11))
        .controlSize(.small)
        .fixedSize()
        Spacer()
        Button {
          withAnimation(.spring(duration: 0.5)) { diceTurns += 1 }
          model.newTake()
        } label: {
          Label("New Take", systemImage: "dice.fill")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color(white: 0.2)))
            .foregroundStyle(EffectStyle.value)
            .rotationEffect(.degrees(diceTurns * 360))
        }
        .buttonStyle(.plain)
        .help("The same settings, played a different way")
        Menu {
          Button("Move Earlier") { model.moveSelected(by: -1) }.disabled(model.selectedIndex == 0)
          Button("Move Later") { model.moveSelected(by: 1) }
            .disabled(model.selectedIndex == model.song.sections.count - 1)
          Button("Duplicate") { model.duplicateSelected() }
          Divider()
          Button("Delete", role: .destructive) { model.removeSelected() }.disabled(model.song.sections.count < 2)
        } label: {
          Image(systemName: "ellipsis.circle").font(.system(size: 14)).foregroundStyle(EffectStyle.label)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Section options")
      }
    }
    .padding(.horizontal, 18)
    .frame(height: 36)
    .background(Color(white: 0.12))
  }
}

// MARK: - Style, pad and groove

private struct StylePicker: View {
  let model: SessionDrummerModel

  var body: some View {
    let selected = model.style
    VStack(alignment: .leading, spacing: 8) {
      Title("Style")
      LazyVGrid(columns: [GridItem(.fixed(136), spacing: 8), GridItem(.fixed(136), spacing: 8)], spacing: 6) {
        ForEach(DrummerPerformance.Style.allCases) { style in
          let isSelected = style == selected
          Button {
            model.setStyle(style)
          } label: {
            HStack(spacing: 8) {
              StyleBadge(style: style, size: isSelected ? 28 : 26)
              VStack(alignment: .leading, spacing: 1) {
                Text(style.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(EffectStyle.value).lineLimit(1)
                Text(style.shortDescription).font(.system(size: 10))
                  .foregroundStyle(isSelected ? style.color : EffectStyle.label).lineLimit(1).minimumScaleFactor(0.85)
              }
              Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .frame(width: 136, height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? style.color.opacity(0.16) : EffectStyle.panel))
            .overlay(RoundedRectangle(cornerRadius: 10)
              .strokeBorder(isSelected ? style.color : Color.white.opacity(0.05), lineWidth: isSelected ? 2 : 1))
            .shadow(color: isSelected ? style.color.opacity(0.45) : .clear, radius: 8)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .help("\(style.title): \(style.summary)")
          .accessibilityLabel(style.title)
          .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
      }
      .frame(width: 280, alignment: .leading)
      Text(selected.summary)
        .font(.system(size: 11))
        .foregroundStyle(EffectStyle.label)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 280, alignment: .leading)
    }
    .animation(.spring(duration: 0.3), value: selected)
  }
}

private struct DrummerPad: View {
  let model: SessionDrummerModel

  @State private var isDragging = false
  private let size = CGSize(width: 300, height: 150)

  var body: some View {
    if let shown = model.shownPerformance {
      let point = CGPoint(x: shown.complexity, y: shown.loudness)
      let color = shown.style.color
      VStack(alignment: .leading, spacing: 8) {
        Title("Loud or Soft, Busy or Simple")
        ZStack(alignment: .topLeading) {
          RoundedRectangle(cornerRadius: 12)
            .fill(LinearGradient(colors: [color.opacity(0.08), color.opacity(0.55)], startPoint: .bottomLeading, endPoint: .topTrailing))
          RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.3))
          Canvas { context, size in
            let puck = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
            for column in 0...13 {
              for row in 0...6 {
                let x = CGFloat(column) / 13 * (size.width - 24) + 12, y = CGFloat(row) / 6 * (size.height - 24) + 12
                let glow = max(0, 1 - hypot(x - puck.x, y - puck.y) / 120)
                context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)),
                  with: .color(Color.white.opacity(0.08 + 0.5 * glow)))
              }
            }
          }
          corner("Loud & Simple", .topLeading)
          corner("Loud & Busy", .topTrailing)
          corner("Soft & Simple", .bottomLeading)
          corner("Soft & Busy", .bottomTrailing)
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
              guard var moved = model.preview ?? model.selectedSection?.performance else { return }
              moved.complexity = Double(min(max(drag.location.x / size.width, 0), 1))
              moved.loudness = Double(min(max(1 - drag.location.y / size.height, 0), 1))
              model.preview = moved
            }
            .onEnded { _ in
              withAnimation(.spring(duration: 0.2)) { isDragging = false }
              guard let preview = model.preview else { return }
              model.preview = nil
              model.editSelected {
                $0.complexity = preview.complexity
                $0.loudness = preview.loudness
              }
            }
        )
        .accessibilityElement()
        .accessibilityLabel("Loudness and busyness")
        .accessibilityValue("\(Int(point.y * 100)) % loud, \(Int(point.x * 100)) % busy")
        .accessibilityAdjustableAction { direction in
          model.editSelected { $0.loudness += direction == .increment ? 0.1 : -0.1 }
        }
        .help("Drag the dot: right for a busier part, up for a louder one")
      }
    }
  }

  private func corner(_ text: String, _ alignment: Alignment) -> some View {
    Text(text)
      .font(.system(size: 9, weight: .semibold))
      .foregroundStyle(Color.white.opacity(0.55))
      .padding(8)
      .frame(width: size.width, height: size.height, alignment: alignment)
      .allowsHitTesting(false)
  }
}

/// The selected section's first two bars as a drum chart (following the pad while it's
/// dragged), with the song's position across it while that section plays.
private struct GrooveChart: View {
  let audioUnit: OngakuEffectsAudioUnit
  let model: SessionDrummerModel

  static let rows: [(name: String, pitches: Set<Int>)] = [
    ("Cymbals", [49, 51]), ("Hi-Hat", [42, 44, 46]), ("Toms", [45, 47, 50]), ("Snare", [37, 38, 39]), ("Kick", [36]),
    ("Perc", [56, 70]),
  ]
  private let size = CGSize(width: 256, height: 70)

  var body: some View {
    if let performance = model.shownPerformance, let section = model.selectedSection {
      let signature = model.controller.signature
      let bars = min(2, section.bars)
      let span = signature.ticksPerBar * Int64(bars)
      let start = signature.ticksPerBar * Int64(model.selectedStartBar)
      let notes = performance.notes(from: start, length: span, tempoMap: TempoMap(bpm: 120, timeSignature: signature))
      let color = performance.style.color
      HStack(spacing: 6) {
        VStack(alignment: .trailing, spacing: 0) {
          ForEach(Self.rows, id: \.name) { row in
            Text(row.name).font(.system(size: 8, weight: .medium)).foregroundStyle(EffectStyle.label.opacity(0.7))
              .frame(width: 38, height: size.height / CGFloat(Self.rows.count), alignment: .trailing)
          }
        }
        Canvas { context, size in
          let rowHeight = size.height / CGFloat(Self.rows.count)
          var beat = Tick.zero
          while beat < span {
            let x = CGFloat(beat.rawValue) / CGFloat(span.rawValue) * size.width
            let isBar = beat.rawValue % signature.ticksPerBar.rawValue == 0
            context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Color.white.opacity(isBar ? 0.18 : 0.06)))
            beat += signature.pulse
          }
          for note in notes {
            guard let row = Self.rows.firstIndex(where: { $0.pitches.contains(note.pitch) }) else { continue }
            let x = CGFloat(note.start.rawValue) / CGFloat(span.rawValue) * size.width
            let strength = Double(note.velocity) / 127
            let diameter = 3 + 6 * strength
            context.fill(
              Path(ellipseIn: CGRect(x: x - diameter / 2 + 3, y: CGFloat(row) * rowHeight + (rowHeight - diameter) / 2, width: diameter, height: diameter)),
              with: .color(color.opacity(0.35 + 0.65 * strength)))
          }
        }
        .frame(width: size.width, height: size.height)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(EffectStyle.panel))
        .overlay {
          TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let position = Double(OngakuMeterValue(audioUnit.meters, .partPosition))
            let sectionStart = start.quarterNotes, length = span.quarterNotes
            let sectionEnd = sectionStart + (signature.ticksPerBar * Int64(section.bars)).quarterNotes
            if position >= sectionStart, position < sectionEnd, length > 0 {
              let within = (position - sectionStart).truncatingRemainder(dividingBy: length)
              Rectangle()
                .fill(Color.white.opacity(0.8))
                .frame(width: 1.5)
                .offset(x: CGFloat(within / length) * size.width - size.width / 2)
            }
          }
          .allowsHitTesting(false)
        }
      }
      .accessibilityElement()
      .accessibilityLabel("Groove")
      .accessibilityValue("\(notes.count) hits in the section's first \(bars) bars")
    }
  }
}

// MARK: - The kit

private struct KitView: View {
  let audioUnit: OngakuEffectsAudioUnit
  let model: SessionDrummerModel

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

    /// The Drum Machine pads that light it (kick, snare, clap, rim, closed hat, open hat,
    /// low, mid, high tom, cowbell, crash, shaker).
    var pads: [Int] {
      switch self {
      case .crash: [10]
      case .hiHat: [4, 5]
      case .ride: [5]
      case .highTom: [8]
      case .midTom: [7]
      case .floorTom: [6]
      case .snare: [1, 2, 3]
      case .kick: [0]
      case .shaker: [9, 11]
      }
    }

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

  var body: some View {
    if let performance = model.selectedSection?.performance {
      VStack(alignment: .leading, spacing: 8) {
        Title("The Kit")
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
          ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12).fill(EffectStyle.panel)
            Ellipse().fill(performance.style.color.opacity(0.1)).frame(width: 250, height: 150).offset(x: 25, y: 12)
            ForEach(Piece.allCases, id: \.self) { piece in
              PieceView(
                piece: piece, isOn: isOn(piece, performance), isLit: isLit(piece), color: performance.style.color
              ) { toggle(piece, performance) }
              .offset(x: piece.frame.minX, y: piece.frame.minY)
            }
          }
          .frame(width: 300, height: 170)
        }
        Picker("Time on", selection: Binding(get: { performance.timekeeper }, set: { value in
          model.editSelected { $0.timekeeper = value }
        })) {
          Text("Hi-Hat").tag(DrummerPerformance.Timekeeper.hiHat)
          Text("Auto").tag(DrummerPerformance.Timekeeper.automatic)
          Text("Ride").tag(DrummerPerformance.Timekeeper.ride)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 300)
        .help("What keeps time. Auto opens up to the ride when the part gets loud.")
      }
    }
  }

  private func isOn(_ piece: Piece, _ performance: DrummerPerformance) -> Bool {
    switch piece {
    case .crash, .hiHat, .ride: performance.playsCymbals
    case .highTom, .midTom, .floorTom: performance.playsToms
    case .snare, .kick: performance.playsKickAndSnare
    case .shaker: performance.playsPercussion
    }
  }

  private func toggle(_ piece: Piece, _ performance: DrummerPerformance) {
    let on = !isOn(piece, performance)
    model.editSelected { performance in
      switch piece {
      case .crash, .hiHat, .ride: performance.playsCymbals = on
      case .highTom, .midTom, .floorTom: performance.playsToms = on
      case .snare, .kick: performance.playsKickAndSnare = on
      case .shaker: performance.playsPercussion = on
      }
    }
  }

  private func isLit(_ piece: Piece) -> Bool {
    piece.pads.contains { pad in
      OngakuMeterValue(audioUnit.meters, OngakuMeter(rawValue: OngakuMeter.firstPad.rawValue + Int32(pad)) ?? .firstPad) > 0.35
    }
  }
}

private struct PieceView: View {
  let piece: KitView.Piece
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
          Circle().fill(color.mix(with: .black, by: 0.35))
          Circle()
            .fill(RadialGradient(colors: [Color(hex: 0xF4F1EA), Color(hex: 0xCFCAC0)], center: .center, startRadius: 1, endRadius: size.width / 2))
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

private struct FeelControls: View {
  let model: SessionDrummerModel

  var body: some View {
    if let performance = model.shownPerformance {
      VStack(spacing: 10) {
        Title("Groove")
        HStack(alignment: .top, spacing: 12) {
          ValueKnob(
            name: "Fills", value: performance.fills, defaultValue: DrummerPerformance(style: performance.style).fills,
            words: ["None", "A few", "Some", "Lots"], tint: performance.style.color
          ) { value in
            preview { $0.fills = value }
          } commit: { value in
            model.preview = nil
            model.editSelected { $0.fills = value }
          }
          ValueKnob(
            // In the Purdie Shuffle the triplets are the swing, so the knob sets the ghost notes.
            name: performance.style == .shuffle ? "Ghosts" : "Swing", value: performance.swing,
            defaultValue: performance.style.defaultSwing,
            words: performance.style == .shuffle ? ["Whisper", "Soft", "Present", "Hard"] : ["Straight", "A little", "Swung", "Shuffle"],
            tint: performance.style.color
          ) { value in
            preview { $0.swing = value }
          } commit: { value in
            model.preview = nil
            model.editSelected { $0.swing = value }
          }
        }
        VStack(spacing: 6) {
          Text("Feel").font(.system(size: 10, weight: .semibold)).foregroundStyle(EffectStyle.label)
          HStack(spacing: 4) {
            feelButton(.halfTime, "tortoise.fill", performance)
            feelButton(.normal, "figure.walk", performance)
            feelButton(.doubleTime, "hare.fill", performance)
          }
          Text(performance.feel.title).font(.system(size: 10)).foregroundStyle(EffectStyle.value)
        }
      }
      .frame(width: 160)
    }
  }

  private func preview(_ change: (inout DrummerPerformance) -> Void) {
    guard var performance = model.preview ?? model.selectedSection?.performance else { return }
    change(&performance)
    model.preview = performance
  }

  private func feelButton(_ feel: DrummerPerformance.Feel, _ symbol: String, _ performance: DrummerPerformance) -> some View {
    let isSelected = performance.feel == feel
    return Button {
      model.editSelected { $0.feel = feel }
    } label: {
      Image(systemName: symbol)
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 34, height: 28)
        .foregroundStyle(isSelected ? Color.white : EffectStyle.label)
        .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? performance.style.color : Color(white: 0.22)))
    }
    .buttonStyle(.plain)
    .help(feel.title)
    .accessibilityLabel(feel.title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

/// A knob for a 0–1 value that isn't a parameter: drag up and down; double-click or
/// Option-click to reset it (to where a new part in the style starts).
private struct ValueKnob: View {
  let name: String
  let value: Double
  let defaultValue: Double
  let words: [String]
  var tint: Color
  let change: (Double) -> Void
  let commit: (Double) -> Void

  @State private var dragStart: Double?
  @State private var current: Double?

  var body: some View {
    let shown = current ?? value
    VStack(spacing: 4) {
      Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(EffectStyle.label)
      ZStack {
        Circle().trim(from: 0, to: 0.75)
          .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        Circle().trim(from: 0, to: 0.75 * shown)
          .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        Circle()
          .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.2)], startPoint: .top, endPoint: .bottom))
          .padding(7)
        Capsule().fill(Color(white: 0.9)).frame(width: 2, height: 11).offset(y: -10)
          .rotationEffect(.degrees(90 + 270 * shown))
      }
      .rotationEffect(.degrees(135))
      .frame(width: 48, height: 48)
      .contentShape(.circle)
      .gesture(
        DragGesture(minimumDistance: 1)
          .onChanged { drag in
            let start = dragStart ?? value
            dragStart = start
            let new = min(max(start - Double(drag.translation.height) / 150, 0), 1)
            current = new
            change(new)
          }
          .onEnded { _ in
            if let current { commit(current) }
            dragStart = nil
            current = nil
          }
      )
      .onTapGesture(count: 2) { commit(defaultValue) }
      .simultaneousGesture(TapGesture().modifiers(.option).onEnded { commit(defaultValue) })
      Text(words[min(words.count - 1, Int(shown * Double(words.count)))])
        .font(.system(size: 10))
        .foregroundStyle(EffectStyle.value)
        .frame(width: 70)
    }
    .accessibilityElement()
    .accessibilityLabel(name)
    .accessibilityValue("\(Int(shown * 100)) %")
    .accessibilityAdjustableAction { direction in
      commit(min(max(value + (direction == .increment ? 0.1 : -0.1), 0), 1))
    }
  }
}

// MARK: - Sound

/// How the drummer is heard: its own kit (choose kits from the preset menu), and/or MIDI to
/// another instrument.
private struct SoundBar: View {
  let parameters: EffectParameters

  var body: some View {
    HStack(spacing: 14) {
      Title("Sound")
      if let kit = parameters["kitSource"] {
        Picker("Kit", selection: Binding(get: { Int(kit.value.rounded()) }, set: { kit.value = AUValue($0) })) {
          ForEach(Array(SessionDrummerParameters.kitNames.enumerated()), id: \.offset) { index, name in
            if index == 1 { Divider() }
            Text(name).tag(index)
          }
        }
        .controlSize(.small)
        .font(.system(size: 11))
        .fixedSize()
        .help("What plays the part: Ongaku's Drum Machine (choose its kits from the preset menu above), or one of the General MIDI kits built into macOS")
      }
      if let playsKit = parameters["playsKit"] {
        Toggle("Play Own Kit", isOn: Binding(get: { playsKit.boolValue }, set: { playsKit.boolValue = $0 }))
          .toggleStyle(.switch)
          .controlSize(.mini)
          .font(.system(size: 11))
          .fixedSize()
          .help("Play the part on the kit chosen here (turn it off to hear only your own drums through MIDI)")
      }
      if let volume = parameters["volume"] {
        HStack(spacing: 6) {
          Text("Volume").font(.system(size: 11)).foregroundStyle(EffectStyle.label).fixedSize()
          Slider(value: Binding(get: { Double(volume.value) }, set: { volume.value = AUValue($0) }), in: Double(volume.min)...Double(volume.max)) {
            EmptyView()
          } onEditingChanged: { volume.onEditingChanged($0) }
          .frame(width: 120)
          .controlSize(.mini)
          DragValue(parameter: volume).frame(width: 60)
        }
      }
      Divider().frame(height: 18)
      if let sendsMIDI = parameters["sendsMIDI"] {
        Toggle("Send MIDI", isOn: Binding(get: { sendsMIDI.boolValue }, set: { sendsMIDI.boolValue = $0 }))
          .toggleStyle(.switch)
          .controlSize(.mini)
          .font(.system(size: 11))
          .fixedSize()
          .help("Send the part as MIDI from this plug-in, for hosts that can route it to another drum instrument")
      }
      Text("Your own drums: route this plug-in's MIDI to them, or drag the part out as MIDI.")
        .font(.system(size: 10))
        .foregroundStyle(EffectStyle.label)
        .lineLimit(1)
      Spacer()
    }
    .padding(.horizontal, 18)
    .frame(height: 40)
    .background(Color(white: 0.11))
    .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1) }
  }
}
