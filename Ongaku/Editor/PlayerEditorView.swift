//
//  PlayerEditorView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// The Player editor, for the Bass Player and Keyboard Player: the track's sections across
/// the top, then the style, the pad (busy or simple, loud or soft) with the part as a note
/// chart under the section's chords, the chords it's following, and swing and register.
struct PlayerEditorView: View {
  let model: PianoRollModel
  let region: Region

  /// While the pad or a knob is dragged: the performance it would make.
  @State private var preview: PlayerPerformance?

  var body: some View {
    if let player = region.player {
      let shown = preview ?? player
      VStack(spacing: 0) {
        PlayerSongStrip(model: model, region: region, player: player)
        ScrollView([.horizontal, .vertical]) {
          HStack(alignment: .top, spacing: 22) {
            PlayerStylePicker(model: model, player: player)
            VStack(alignment: .leading, spacing: 10) {
              PlayerPad(model: model, player: player, preview: $preview)
              NoteChart(model: model, region: region, player: shown, isPreview: preview != nil)
            }
            SectionChords(model: model, region: region, player: player)
            PlayerFeelControls(model: model, player: player, preview: $preview)
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
          .frame(maxWidth: .infinity, alignment: .top)
        }
      }
      .background(Theme.lanes)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Player Editor")
    }
  }
}

// MARK: - Styles

extension PlayerPerformance.Style {
  var color: Color {
    switch self {
    case .rootNotes: Color(hex: 0x4C8FE8)
    case .drivingEighths: Color(hex: 0xE5713A)
    case .walking: Color(hex: 0xB5835A)
    case .funkBass: Color(hex: 0x9B6BF0)
    case .motown: Color(hex: 0xE45C9A)
    case .pad: Color(hex: 0x2FB7A6)
    case .blockChords: Color(hex: 0x4C8FE8)
    case .popPulse: Color(hex: 0xE45C9A)
    case .balladArpeggio: Color(hex: 0xD9A73A)
    case .funkStabs: Color(hex: 0x9B6BF0)
    }
  }

  var symbol: String {
    switch self {
    case .rootNotes: "circle.fill"
    case .drivingEighths: "bolt.fill"
    case .walking: "figure.walk"
    case .funkBass: "waveform.path"
    case .motown: "music.note"
    case .pad: "cloud.fill"
    case .blockChords: "square.stack.3d.up.fill"
    case .popPulse: "sparkles"
    case .balladArpeggio: "water.waves"
    case .funkStabs: "staroflife.fill"
    }
  }

  var shortDescription: String {
    switch self {
    case .rootNotes: "Space and roots"
    case .drivingEighths: "Steady eighths"
    case .walking: "Quarter-note line"
    case .funkBass: "Syncopated"
    case .motown: "Melodic pickups"
    case .pad: "Held chords"
    case .blockChords: "Every beat"
    case .popPulse: "Eighth-note chords"
    case .balladArpeggio: "Broken chords"
    case .funkStabs: "Short stabs"
    }
  }
}

private struct PlayerBadge: View {
  let style: PlayerPerformance.Style
  var size: CGFloat = 28

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
      .font(Theme.font(10, weight: .bold))
      .tracking(0.8)
      .foregroundStyle(Theme.secondaryText)
  }
}

private struct PlayerStylePicker: View {
  let model: PianoRollModel
  let player: PlayerPerformance

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Title("Style")
      LazyVGrid(columns: [GridItem(.fixed(136), spacing: 8), GridItem(.fixed(136), spacing: 8)], spacing: 6) {
        ForEach(PlayerPerformance.Style.styles(for: player.instrument)) { style in
          let isSelected = style == player.style
          Button {
            model.editPlayer("Player Style") {
              $0.style = style
              $0.swing = style.defaultSwing
            }
          } label: {
            HStack(spacing: 8) {
              PlayerBadge(style: style, size: isSelected ? 28 : 26)
              VStack(alignment: .leading, spacing: 1) {
                Text(style.title).font(Theme.font(12, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                  .minimumScaleFactor(0.85)
                Text(style.shortDescription).font(Theme.font(10))
                  .foregroundStyle(isSelected ? style.color : Theme.secondaryText).lineLimit(1).minimumScaleFactor(0.85)
              }
              Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .frame(width: 136, height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? style.color.opacity(0.16) : Theme.panel))
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
      Text(player.style.summary)
        .font(Theme.font(11))
        .foregroundStyle(Theme.secondaryText)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 280, alignment: .leading)
    }
    .animation(.spring(duration: 0.3), value: player.style)
  }
}

// MARK: - The song strip

private struct PlayerSongStrip: View {
  let model: PianoRollModel
  let region: Region
  let player: PlayerPerformance

  @State private var diceTurns = 0.0

  private var sections: [Region] {
    (model.track?.regions ?? []).filter { $0.player != nil }.sorted { $0.start < $1.start }
  }

  var body: some View {
    HStack(spacing: 10) {
      PlayerBadge(style: player.style, size: 26)
      Text("\(player.style.title) \(player.instrument == .bass ? "bass" : "keys")")
        .font(Theme.font(12, weight: .semibold))
        .foregroundStyle(Theme.text)
        .fixedSize()
      Rectangle().fill(Theme.divider).frame(width: 1, height: 20)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(sections) { section in
            let isSelected = section.id == region.id
            let color = model.window.project.arrangement.first { $0.name == section.name }?.color.color ?? player.style.color
            Button {
              model.window.select(section.id, extending: false)
              model.window.openEditor(for: section.id)
            } label: {
              Text(section.name)
                .font(Theme.font(11, weight: isSelected ? .semibold : .medium))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .foregroundStyle(isSelected ? Color.white : Theme.text)
                .background(Capsule().fill(isSelected ? color : color.opacity(0.22)))
                .overlay(Capsule().strokeBorder(color.opacity(isSelected ? 0 : 0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
          }
        }
      }
      if model.window.project.chords.isEmpty {
        Text("Tip: the Chord track is empty, so it plays the key's chord. Add chords there (Track ▸ Show Global Tracks) or play a progression")
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
        model.newPlayerTake()
      } label: {
        Label("New Take", systemImage: "dice.fill")
          .font(Theme.font(11, weight: .semibold))
          .padding(.horizontal, 10)
          .frame(height: 26)
          .background(Capsule().fill(Theme.raised))
          .foregroundStyle(Theme.text)
          .rotationEffect(.degrees(diceTurns * 360))
      }
      .buttonStyle(.plain)
      .help("Same settings, played a different way")
      Menu {
        Toggle("Lead into the Next Section", isOn: Binding(get: { player.leadsIntoNext }, set: { value in
          model.editPlayer("Player Lead-In") { $0.leadsIntoNext = value }
        }))
        Divider()
        Button("Convert to MIDI Region") { model.convertPlayerToNotes() }
      } label: {
        Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(Theme.secondaryText)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("More player options")
    }
    .padding(.horizontal, 12)
    .frame(height: 42)
    .background(Theme.panel)
    .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
  }
}

// MARK: - The pad and the part

private struct PlayerPad: View {
  let model: PianoRollModel
  let player: PlayerPerformance
  @Binding var preview: PlayerPerformance?

  @State private var isDragging = false
  private let size = CGSize(width: 280, height: 118)

  var body: some View {
    let shown = preview ?? player
    let point = CGPoint(x: shown.complexity, y: shown.loudness)
    let color = player.style.color
    VStack(alignment: .leading, spacing: 8) {
      Title("Loud or Soft, Busy or Simple")
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
        .fill(LinearGradient(colors: [color.opacity(0.08), color.opacity(0.55)], startPoint: .bottomLeading, endPoint: .topTrailing))
      RoundedRectangle(cornerRadius: 12).fill(Theme.window.opacity(0.35))
      Canvas { context, size in
        let puck = CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
        for column in 0...12 {
          for row in 0...5 {
            let x = CGFloat(column) / 12 * (size.width - 24) + 12, y = CGFloat(row) / 5 * (size.height - 24) + 12
            let glow = max(0, 1 - hypot(x - puck.x, y - puck.y) / 120)
            context.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)),
              with: .color(Color.white.opacity(0.08 + 0.5 * glow)))
          }
        }
      }
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
          var moved = preview ?? player
          moved.complexity = Double(min(max(drag.location.x / size.width, 0), 1))
          moved.loudness = Double(min(max(1 - drag.location.y / size.height, 0), 1))
          preview = moved
        }
        .onEnded { _ in
          withAnimation(.spring(duration: 0.2)) { isDragging = false }
          guard let preview else { return }
          let complexity = preview.complexity, loudness = preview.loudness
          model.editPlayer("Player Pad") {
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
    model.editPlayer("Player Pad") {
      $0.loudness += loudness
      $0.complexity += complexity
    }
  }
}

/// The section's first two bars as a small piano roll under its chords (following the pad
/// while it's dragged).
private struct NoteChart: View {
  let model: PianoRollModel
  let region: Region
  let player: PlayerPerformance
  let isPreview: Bool

  private let size = CGSize(width: 280, height: 72)

  var body: some View {
    let project = model.window.project
    let tempoMap = project.tempoMap
    let firstBar = tempoMap.bar(containing: region.start)
    let span = min(region.length, tempoMap.tickPosition(ofBarIndex: firstBar.index + 2) - region.start)
    let notes = isPreview
      ? player.notes(from: region.start, length: span, tempoMap: tempoMap, chords: project.chordTimeline)
      : regionNotes(before: span)
    let pitches = notes.map(\.pitch)
    let low = (pitches.min() ?? 48) - 2, high = (pitches.max() ?? 72) + 2
    let chords = project.chordSpans(from: region.start, to: region.start + span)
    let color = player.style.color
    VStack(alignment: .leading, spacing: 2) {
      // The chords over the bars.
      ZStack(alignment: .topLeading) {
        ForEach(Array(chords.enumerated()), id: \.offset) { _, span2 in
          Text(span2.chord.description)
            .font(Theme.font(10, weight: .semibold))
            .foregroundStyle(Theme.text)
            .offset(x: CGFloat((span2.start - region.start).rawValue) / CGFloat(span.rawValue) * size.width)
        }
      }
      .frame(width: size.width, height: 14, alignment: .topLeading)
      Canvas { context, size in
        var beat = Tick.zero
        let pulse = tempoMap.timeSignature(atBarIndex: firstBar.index).pulse
        while beat < span {
          let x = CGFloat(beat.rawValue) / CGFloat(span.rawValue) * size.width
          let isBar = tempoMap.bar(containing: region.start + beat).start == region.start + beat
          context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Color.white.opacity(isBar ? 0.18 : 0.06)))
          beat += pulse
        }
        let rowHeight = size.height / CGFloat(max(1, high - low))
        for note in notes {
          let x = CGFloat(note.start.rawValue) / CGFloat(span.rawValue) * size.width
          let width = max(3, CGFloat(note.length.rawValue) / CGFloat(span.rawValue) * size.width - 1)
          let y = size.height - CGFloat(note.pitch - low) * rowHeight
          let strength = Double(note.velocity) / 127
          context.fill(Path(roundedRect: CGRect(x: x, y: y - max(2, rowHeight) / 2, width: width, height: max(2, rowHeight)), cornerRadius: 1),
            with: .color(color.opacity(0.4 + 0.6 * strength)))
        }
      }
      .frame(width: size.width, height: size.height)
      .padding(.vertical, 4)
      .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
    }
    .accessibilityElement()
    .accessibilityLabel("Part")
    .accessibilityValue("\(notes.count) notes in the section's first bars")
  }

  private func regionNotes(before span: Tick) -> [MIDINote] {
    guard case .midi(let sequence) = region.content else { return [] }
    return sequence.notes.filter { $0.start < span }
  }
}

/// The chords this section follows, from the Chord track: click one to go to it.
private struct SectionChords: View {
  let model: PianoRollModel
  let region: Region
  let player: PlayerPerformance

  var body: some View {
    let project = model.window.project
    let spans = project.chordSpans(from: region.start, to: region.end)
    let tempoMap = project.tempoMap
    VStack(alignment: .leading, spacing: 8) {
      Title("Chords")
      ScrollView(.vertical, showsIndicators: false) {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], alignment: .leading, spacing: 6) {
          ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
            let position = tempoMap.musicalPosition(at: span.start)
            Button {
              model.window.engine.locate(to: span.start)
            } label: {
              VStack(spacing: 1) {
                Text(span.chord.description).font(Theme.font(13, weight: .bold)).foregroundStyle(Theme.text)
                Text("bar \(position.bar)").font(Theme.font(9)).foregroundStyle(Theme.secondaryText)
              }
              .frame(width: 64, height: 40)
              .background(RoundedRectangle(cornerRadius: 8).fill(player.style.color.opacity(0.18)))
              .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(player.style.color.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("\(span.chord.description) at bar \(position.bar): click to go there")
          }
        }
      }
      .frame(width: 210, height: 150)
      Menu {
        ForEach(model.window.progressions(at: region.start)) { progression in
          Button("\(progression.name): \(model.window.chordNames(progression, at: region.start))") {
            model.window.fillChords(with: progression, from: region.start, to: region.end)
          }
        }
        Divider()
        Button("Write Chords for the Whole Song") { model.window.writeSongChords() }
      } label: {
        Label("Play a Progression", systemImage: "music.note.list")
          .font(Theme.font(11, weight: .semibold))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Put a progression on the Chord track over “\(region.name)”")
      Text(chordNote(in: project))
        .font(Theme.font(10))
        .foregroundStyle(Theme.tertiaryText)
        .frame(width: 210, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// What the player follows here. Before the first chord it plays that chord, and with no
  /// chords at all the key's (as `ChordTimeline.chord(at:)` does).
  private func chordNote(in project: Project) -> String {
    guard !project.chords.contains(where: { $0.position < region.end }) else {
      return "Change chords on the Chord track; the player follows."
    }
    let playing = project.chordTimeline.chord(at: region.start).description
    return project.chords.isEmpty
      ? "No chords yet: playing \(playing), the key's chord. Choose a progression."
      : "No chords here yet: playing \(playing), the Chord track's first chord. Choose a progression."
  }
}

// MARK: - Swing and register

private struct PlayerFeelControls: View {
  let model: PianoRollModel
  let player: PlayerPerformance
  @Binding var preview: PlayerPerformance?

  var body: some View {
    VStack(spacing: 12) {
      Title("Feel")
      VStack(spacing: 4) {
        Text("Swing").font(Theme.font(10, weight: .semibold)).foregroundStyle(Theme.secondaryText)
        Knob(
          value: (preview ?? player).swing, range: 0...1, defaultValue: 0, size: 46, tint: player.style.color, label: "Swing",
          valueText: { "\(Int($0 * 100)) %" },
          onChange: { value in
            var changed = preview ?? player
            changed.swing = value
            preview = changed
          },
          onCommit: { value in
            model.editPlayer("Player Swing") { $0.swing = value }
            preview = nil
          })
        let words = ["Straight", "A little", "Swung", "Shuffle"]
        Text(words[min(words.count - 1, Int((preview ?? player).swing * Double(words.count)))])
          .font(Theme.font(10))
          .foregroundStyle(Theme.text)
      }
      VStack(spacing: 6) {
        Text("Register").font(Theme.font(10, weight: .semibold)).foregroundStyle(Theme.secondaryText)
        Picker("Register", selection: Binding(get: { player.register }, set: { value in
          model.editPlayer("Player Register") { $0.register = value }
        })) {
          Text("Low").tag(-1)
          Text("Middle").tag(0)
          Text("High").tag(1)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 160)
        .help("Play an octave lower or higher than usual")
      }
    }
    .frame(width: 170)
  }
}

/// Holds the window model for the previews (the editor's model only keeps an unowned
/// reference to it).
private struct PlayerEditorPreview: View {
  @State private var window: ProjectWindowModel

  init(instrument: PlayerPerformance.Instrument = .bass) {
    _window = State(initialValue: Self.makeWindow(instrument))
  }

  var body: some View {
    Group {
      if let region = window.pianoRoll.region {
        PlayerEditorView(model: window.pianoRoll, region: region)
      }
    }
    .frame(width: 1200, height: 330)
  }

  static func makeWindow(_ instrument: PlayerPerformance.Instrument) -> ProjectWindowModel {
    var project = Project()
    project.arrangement = [
      ArrangementSection(name: "Intro", start: .zero, length: Tick(3840 * 4)),
      ArrangementSection(name: "Verse", start: Tick(3840 * 4), length: Tick(3840 * 8)),
      ArrangementSection(name: "Chorus", start: Tick(3840 * 12), length: Tick(3840 * 8)),
    ]
    project.chords = ["C", "Am", "F", "G", "C", "Am", "Dm7", "G7", "F", "G", "C/E", "Am"].enumerated().map { index, name in
      ChordChange(position: Tick(3840 * Int64(index + 4)), chord: Chord(name: name)!)
    }
    let window = ProjectWindowModel(document: OngakuDocument(project: project))
    window.addPlayerTrack(instrument, style: instrument == .bass ? .motown : .popPulse)
    if let verse = window.project.tracks.last?.regions.dropFirst().first {
      window.select(verse.id, extending: false)
      window.openEditor(for: verse.id)
    }
    return window
  }
}

#Preview("Bass Player") {
  PlayerEditorPreview()
}

#Preview("Keyboard Player") {
  PlayerEditorPreview(instrument: .keys)
}
