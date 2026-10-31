//
//  TakesEditorView.swift
//  Ongaku
//

import OngakuCore
import SwiftUI

/// A take folder opened in the editor pane: a row per take, lit where the take plays in
/// the comp. Drag across a take to make it play there (Logic's quick-swipe comping); click a
/// take's name to play it throughout. Right-click a take to rename or delete it.
struct TakesEditorView: View {
  let model: PianoRollModel
  let region: Region

  static let rowHeight = ProjectWindowModel.Layout.trackHeight
  static let nameWidth: CGFloat = 120

  /// The take being renamed, and the name being typed.
  @State private var renamingTakeID: Take.ID?
  @State private var name = ""

  var body: some View {
    if let folder = region.takeFolder {
      ScrollView([.horizontal, .vertical]) {
        VStack(spacing: 0) {
          ForEach(folder.takes.reversed()) { take in
            TakeRow(model: model, region: region, take: take, comp: folder.comp) {
              name = take.name
              renamingTakeID = take.id
            }
          }
        }
      }
      .background(Theme.lanes)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Takes")
      .alert("Rename Take", isPresented: Binding(get: { renamingTakeID != nil }, set: { if !$0 { renamingTakeID = nil } })) {
        TextField("Name", text: $name)
        Button("Rename") {
          if let renamingTakeID, name != folder.take(withID: renamingTakeID)?.name {
            model.window.perform(RenameTake(renamingTakeID, in: region.id, to: name))
          }
          renamingTakeID = nil
        }
        Button("Cancel", role: .cancel) { renamingTakeID = nil }
      }
    }
  }
}

private struct TakeRow: View {
  let model: PianoRollModel
  let region: Region
  let take: Take
  let comp: [CompSection]
  let rename: () -> Void

  /// While swiping: the range (relative to the folder) this take would take over.
  @State private var swipe: Range<Tick>?

  var body: some View {
    let timeline = TimelineScale(pointsPerQuarterNote: model.pointsPerQuarterNote, tempoMap: model.window.project.tempoMap)
    let width = max(model.x(for: region.length), 1)
    let height = TakesEditorView.rowHeight
    let isLead = take.id == region.leadTakeID
    let color = model.track?.color.color ?? Theme.accent
    let waveforms = model.window.waveforms.waveforms
    let sections = comp.filter { $0.takeID == take.id }.map(\.range)

    HStack(spacing: 0) {
      Button {
        model.window.perform(SelectTake(take.id, in: region.id))
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isLead ? "star.fill" : "star")
            .foregroundStyle(isLead ? Theme.solo : Theme.tertiaryText)
          Text(take.name)
            .foregroundStyle(sections.isEmpty ? Theme.secondaryText : Theme.text)
        }
        .font(Theme.font(11, weight: .medium))
        .padding(.horizontal, 8)
        .frame(width: TakesEditorView.nameWidth, height: height, alignment: .leading)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .background(Theme.panel)
      .overlay(alignment: .trailing) { Rectangle().fill(Theme.separator).frame(width: 1) }
      .help(isLead
        ? "\(take.name) starts the comp (the star)\(isMIDI ? ", so it’s the take the Piano Roll edits" : ""). Click to play it throughout the folder."
        : "Play \(take.name) throughout the folder")

      Canvas { context, size in
        // The take, drawn like a region.
        var takeRegion = region
        takeRegion.takeFolder = nil
        takeRegion.content = take.content
        takeRegion.name = take.name
        let originX = timeline.x(for: region.start)
        RegionDrawing.draw(
          takeRegion, from: region.start, to: region.end, color: color, isSelected: false, originX: originX,
          visibleWidth: size.width, timeline: timeline, waveforms: waveforms, in: &context)
        // Dim what this take doesn't play, as Logic does.
        var unused = Path(CGRect(origin: .zero, size: size))
        for section in sections {
          let x = model.x(for: section.lowerBound)
          unused = unused.subtracting(Path(CGRect(x: x, y: 0, width: model.x(for: section.upperBound) - x, height: size.height)))
        }
        context.fill(unused, with: .color(.black.opacity(0.5)))
        if let swipe {
          let x = model.x(for: swipe.lowerBound)
          let rect = CGRect(x: x, y: 2, width: model.x(for: swipe.upperBound) - x, height: size.height - 4)
          context.stroke(Path(rect), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
      }
      .frame(width: width, height: height)
      .contentShape(.rect)
      .gesture(swipeGesture)
    }
    .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    .contextMenu {
      Button("Rename…", action: rename)
      // Deleting one of two takes leaves a plain region playing the other.
      Button("Delete Take", role: .destructive) { model.window.perform(DeleteTake(take.id, from: region.id)) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(take.name)
    .accessibilityValue(usage(sections, isLead: isLead))
    .accessibilityIdentifier("take-row")
  }

  private var isMIDI: Bool {
    if case .midi = take.content { true } else { false }
  }

  /// How much of the comp the take plays, and whether it starts the comp (which the star
  /// marks: it's the take the region shows, and the one the Piano Roll edits).
  private func usage(_ sections: [Range<Tick>], isLead: Bool) -> String {
    let used = sections.reduce(Tick.zero) { $0 + ($1.upperBound - $1.lowerBound) }
    let amount = sections.isEmpty ? "Not used" : used >= region.length ? "Used throughout" : "Partly used"
    return isLead ? "\(amount), starts the comp" : amount
  }

  /// Drag across the take to comp it in there, snapped to the grid.
  private var swipeGesture: some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { drag in
        let from = model.snap(model.position(forX: min(drag.startLocation.x, drag.location.x)))
        let to = model.snap(model.position(forX: max(drag.startLocation.x, drag.location.x)))
        let clamped = max(.zero, from)..<min(region.length, max(to, from))
        swipe = clamped.isEmpty ? nil : clamped
      }
      .onEnded { _ in
        if let swipe {
          model.window.perform(CompTake(take.id, over: swipe, in: region.id))
        }
        swipe = nil
      }
  }
}

#Preview {
  TakesEditorPreview()
    .frame(width: 760, height: 300)
}

/// Keeps the window model alive: the editor's model refers to it without owning it.
private struct TakesEditorPreview: View {
  @State private var window: ProjectWindowModel = {
    let bar = Tick.quarterNotes(4)
    let takes = (0..<3).map { index in
      Take(name: "Take \(index + 1)", content: .midi(MIDISequence(notes: (0..<8).map { step in
        MIDINote(pitch: 60 + (step * (index + 2)) % 12, start: .quarterNotes(Double(step)), length: .quarterNotes(0.5))
      })))
    }
    var folder = TakeFolder(takes: takes, playing: takes[2].id, length: bar * 2)
    folder.use(takes[0].id, over: bar..<(bar + .quarterNotes(2)))
    let region = Region(name: "Keys", start: .zero, length: bar * 2, content: takes[2].content, takeFolder: folder)
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [
      Track(name: "Keys", kind: .softwareInstrument, regions: [region])
    ])))
    window.editorRegionID = region.id
    window.pianoRoll.editorKind = .takes
    window.pianoRoll.pointsPerQuarterNote = 80
    return window
  }()

  var body: some View {
    PianoRollView(model: window.pianoRoll)
  }
}
