//
//  GlobalTracksView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// Logic's global tracks under the ruler: the Arrangement track (song sections, dragged to
/// reorder the song), the Chord track the session players follow, and the Marker,
/// Signature and Tempo tracks.
struct GlobalTrackLanes: View {
  let model: ProjectWindowModel

  private var rowHeight: CGFloat { ProjectWindowModel.globalTrackHeight }

  var body: some View {
    VStack(spacing: 0) {
      ArrangementLane(model: model)
        .frame(height: rowHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
      ChordLane(model: model)
        .frame(height: rowHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
      MarkerLane(model: model)
        .frame(height: rowHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
      SignatureLane(model: model)
        .frame(height: rowHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
      TempoLane(model: model)
        .frame(height: ProjectWindowModel.tempoTrackHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
    .frame(width: model.contentWidth, alignment: .topLeading)
    .background(Theme.panel)
  }
}

/// The global tracks' names, beside them in the corner above the track headers.
struct GlobalTrackHeaders: View {
  let model: ProjectWindowModel

  var body: some View {
    VStack(spacing: 0) {
      GlobalTrackHeader(title: "Arrangement", addHelp: "Add Arrangement Marker") { model.addArrangementSection() }
      GlobalTrackHeader(title: "Chord", addHelp: "Add a Chord at the Playhead") {
        model.chordEdit = ChordEdit(position: model.snapChord(model.engine.playheadPosition))
      }
      GlobalTrackHeader(title: "Marker", addHelp: "Create Marker at the Playhead") { model.createMarker() }
      GlobalTrackHeader(title: "Signature", addHelp: "Add a Time Signature or Key Change at the Next Bar") {
        model.addTimeSignatureAtPlayhead()
      } menu: {
        Button("Time Signature at the Next Bar") { model.addTimeSignatureAtPlayhead() }
        Button("Key Change at the Next Bar…") { model.addKeyChangeAtPlayhead() }
      }
      GlobalTrackHeader(title: "Tempo", addHelp: "Add a Tempo Change at the Playhead", height: ProjectWindowModel.tempoTrackHeight) {
        let playhead = model.engine.playheadPosition
        model.addTempoChange(at: playhead, bpm: model.project.tempoMap.tempo(at: playhead))
      }
    }
  }
}

/// One global track's name, with a + button that adds to it (or, with `menu`, offers what
/// to add).
private struct GlobalTrackHeader<Choices: View>: View {
  let title: String
  let addHelp: String
  var height = ProjectWindowModel.globalTrackHeight
  let add: () -> Void
  @ViewBuilder var menu: () -> Choices

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(Theme.font(10, weight: .semibold))
        .foregroundStyle(Theme.secondaryText)
      Spacer(minLength: 0)
      Group {
        if Choices.self == EmptyView.self {
          Button(action: add) {
            Label(addHelp, systemImage: "plus")
          }
          .buttonStyle(.plain)
        } else {
          Menu {
            menu()
          } label: {
            Label(addHelp, systemImage: "plus")
          }
          .menuStyle(.button)
          .buttonStyle(.plain)
          .menuIndicator(.hidden)
          .fixedSize()
        }
      }
      .labelStyle(.iconOnly)
      .font(Theme.font(10, weight: .bold))
      .foregroundStyle(Theme.secondaryText)
      .help(addHelp)
    }
    .padding(.horizontal, 8)
    .frame(height: height)
    .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
  }
}

extension GlobalTrackHeader where Choices == EmptyView {
  init(title: String, addHelp: String, height: CGFloat = ProjectWindowModel.globalTrackHeight, add: @escaping () -> Void) {
    self.init(title: title, addHelp: addHelp, height: height, add: add) { EmptyView() }
  }
}

// MARK: - Chords

/// The Chord track: the song's chords, which the session players follow. Double-click an
/// empty spot (or right-click it) to add one, click a chord to select it (Delete removes
/// it), double-click it to change it, drag it along the Snap grid, or right-click it for
/// more.
private struct ChordLane: View {
  let model: ProjectWindowModel
  @State private var hover = HoverPosition()

  var body: some View {
    let height = ProjectWindowModel.globalTrackHeight
    ZStack(alignment: .topLeading) {
      Color.clear
        .contentShape(.rect)
        .onContinuousHover { phase in
          if case .active(let location) = phase { hover.x = location.x }
        }
        .onTapGesture(count: 2) { location in
          model.chordEdit = ChordEdit(position: model.snapChord(model.position(forX: location.x)))
        }
        .contextMenu {
          let position = model.snapChord(model.position(forX: hover.x))
          Button("Add Chord Here…") { model.chordEdit = ChordEdit(position: position) }
          Menu("Add a Chord of the Key") {
            ForEach(model.diatonicChords(at: position), id: \.self) { chord in
              Button(chord.description) { model.setChord(named: chord.description, at: position) }
            }
          }
          Divider()
          let range = model.progressionRange(at: position)
          Menu("Fill \(range.name) with a Progression") {
            ForEach(model.progressions(at: range.start)) { progression in
              Button("\(progression.name): \(model.chordNames(progression, at: range.start))") {
                model.fillChords(with: progression, from: range.start, to: range.end)
              }
            }
          }
          Button("Write Chords for the Whole Song") { model.writeSongChords() }
        }
      ForEach(model.project.chords) { change in
        ChordLabel(model: model, change: change)
      }
    }
    .popover(
      item: Binding(get: { model.chordEdit }, set: { model.chordEdit = $0 }),
      attachmentAnchor: .rect(.rect(CGRect(x: model.x(for: model.chordEdit?.position ?? .zero), y: 0, width: 1, height: height))),
      arrowEdge: .bottom
    ) { edit in
      ChordEntry(model: model, edit: edit)
    }
    .onHover { model.isPointerOverChordTrack = $0 }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Chord Track")
  }
}

private struct ChordLabel: View {
  let model: ProjectWindowModel
  let change: ChordChange

  @State private var dragOffset: CGFloat = 0

  var body: some View {
    let x = model.x(for: change.position)
    let isSelected = model.selectedChordID == change.id
    Text(change.chord.description)
      .font(Theme.font(11, weight: .semibold))
      .foregroundStyle(isSelected ? Color.white : Theme.text)
      .padding(.horizontal, 6)
      .frame(height: ProjectWindowModel.globalTrackHeight - 4)
      .background(Theme.accent.opacity(isSelected ? 0.85 : 0.35), in: .rect(cornerRadius: 3))
      .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 2) }
      .overlay { if isSelected { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.8), lineWidth: 1) } }
      .fixedSize()
      .offset(x: x + dragOffset, y: 2)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { drag in
            if abs(drag.translation.width) > 3 { dragOffset = drag.translation.width }
          }
          .onEnded { drag in
            defer { dragOffset = 0 }
            model.selectChord(change.id)
            if abs(drag.translation.width) > 3 {
              model.moveChord(change.id, to: model.position(forX: x + drag.translation.width))
            } else {
              model.engine.locate(to: change.position)
            }
          }
      )
      .simultaneousGesture(TapGesture(count: 2).onEnded {
        model.chordEdit = ChordEdit(position: change.position, changeID: change.id)
      })
      .contextMenu {
        Button("Change Chord…") { model.chordEdit = ChordEdit(position: change.position, changeID: change.id) }
        Menu("Chords of the Key") {
          ForEach(model.diatonicChords(at: change.position), id: \.self) { chord in
            Button(chord.description) { model.changeChord(change.id, toName: chord.description) }
          }
        }
        Divider()
        Button("Delete", role: .destructive) { model.deleteChord(change.id) }
      }
      .help("\(change.chord.description): click to select it and go there (Delete removes it), drag to move it, double-click to change it")
      .accessibilityElement()
      .accessibilityLabel("Chord \(change.chord.description)")
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityIdentifier("chord")
  }
}

/// Types a chord's name, or picks one of the key's chords.
private struct ChordEntry: View {
  let model: ProjectWindowModel
  let edit: ChordEdit

  @State private var name = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    let isValid = Chord(name: name) != nil
    VStack(alignment: .leading, spacing: 10) {
      Text(edit.changeID == nil ? "Add a Chord" : "Change Chord").font(.headline)
      HStack {
        TextField("Am7, F♯m, G/B…", text: $name)
          .textFieldStyle(.roundedBorder)
          .frame(width: 150)
          .focused($isFocused)
          .onSubmit(commit)
        Button(edit.changeID == nil ? "Add" : "Change", action: commit)
          .keyboardShortcut(.defaultAction)
          .disabled(!isValid)
      }
      if !name.isEmpty, !isValid {
        Text("Not a chord name yet").font(Theme.font(10)).foregroundStyle(.secondary)
      }
      Text("In the key of \(model.project.key(at: edit.position).description)").font(Theme.font(10)).foregroundStyle(.secondary)
      HStack(spacing: 4) {
        ForEach(model.diatonicChords(at: edit.position), id: \.self) { chord in
          Button(chord.description) {
            name = chord.description
            commit()
          }
          .controlSize(.small)
        }
      }
    }
    .padding(14)
    .onAppear {
      name = edit.changeID.flatMap { id in model.project.chords.first { $0.id == id }?.chord.description } ?? ""
      isFocused = true
    }
  }

  private func commit() {
    guard Chord(name: name) != nil else { return }
    if let id = edit.changeID {
      model.changeChord(id, toName: name)
    } else {
      model.setChord(named: name, at: edit.position)
    }
    model.chordEdit = nil
  }
}

// MARK: - Arrangement

private struct ArrangementLane: View {
  let model: ProjectWindowModel

  var body: some View {
    ZStack(alignment: .topLeading) {
      Color.clear
      ForEach(model.project.arrangement) { section in
        SectionView(model: model, section: section, isSelected: model.selectedSectionID == section.id)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Arrangement Track")
  }
}

/// One section: drag it to move it in the song (everything in it moves too), drag its right
/// edge to resize it, click to select it with its regions, double-click to rename.
private struct SectionView: View {
  let model: ProjectWindowModel
  let section: ArrangementSection
  let isSelected: Bool

  @State private var dragOffset: CGFloat = 0
  @State private var resizeWidth: CGFloat?
  private static let edgeWidth: CGFloat = 6

  var body: some View {
    let x = model.x(for: section.start)
    let width = resizeWidth ?? max(model.x(for: section.end) - x, 4)
    let color = section.color.color
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 3)
        .fill(color.opacity(isSelected ? 0.9 : 0.65))
      RoundedRectangle(cornerRadius: 3)
        .strokeBorder(isSelected ? Color.white.opacity(0.9) : Color.black.opacity(0.45))
      Text(section.name)
        .font(Theme.font(10, weight: .semibold))
        .foregroundStyle(Color.black.opacity(0.82))
        .lineLimit(1)
        .padding(.horizontal, 5)
    }
    .frame(width: width, height: ProjectWindowModel.globalTrackHeight - 4)
    .offset(x: x + dragOffset, y: 2)
    .zIndex(dragOffset == 0 ? 0 : 1)
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { drag in
          guard abs(drag.translation.width) > 3 else { return }
          if drag.startLocation.x >= width - Self.edgeWidth {
            resizeWidth = max(4, model.x(for: section.end) - x + drag.translation.width)
          } else {
            dragOffset = drag.translation.width
          }
        }
        .onEnded { drag in
          defer {
            dragOffset = 0
            resizeWidth = nil
          }
          guard abs(drag.translation.width) > 3 else {
            model.selectSection(section.id)
            return
          }
          if drag.startLocation.x >= width - Self.edgeWidth {
            model.resizeSection(section.id, end: model.position(forX: model.x(for: section.end) + drag.translation.width))
          } else {
            model.moveSection(section.id, droppedAt: model.position(forX: x + drag.translation.width))
          }
        }
    )
    .simultaneousGesture(TapGesture(count: 2).onEnded { model.renameTarget = .section(section.id) })
    .contextMenu {
      Menu("Name") {
        ForEach(ArrangementSection.suggestedNames, id: \.self) { name in
          Button(name) { model.renameSection(section.id, to: name) }
        }
      }
      Button("Rename…") { model.renameTarget = .section(section.id) }
      Button("Duplicate") { model.duplicateSection(section.id) }
      Divider()
      Button("Delete with Contents", role: .destructive) { model.deleteSection(section.id) }
    }
    .help("Drag to move \(section.name) and everything in it")
    .accessibilityElement()
    .accessibilityLabel("Section \(section.name)")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("arrangement-section")
  }
}

// MARK: - Markers

private struct MarkerLane: View {
  let model: ProjectWindowModel

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Double-click an empty spot to add a marker there.
      Color.clear
        .contentShape(.rect)
        .gesture(SpatialTapGesture(count: 2).onEnded { tap in
          model.createMarker(at: model.snap(model.position(forX: tap.location.x)))
        })
      ForEach(model.project.markers) { marker in
        MarkerFlag(model: model, marker: marker)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Marker Track")
  }
}

/// A marker: click to move the playhead there, drag to move it, double-click to rename.
private struct MarkerFlag: View {
  let model: ProjectWindowModel
  let marker: Marker

  @State private var dragOffset: CGFloat = 0

  var body: some View {
    HStack(spacing: 4) {
      Rectangle().fill(Theme.text.opacity(0.8)).frame(width: 2)
      Text(marker.name)
        .font(Theme.font(10, weight: .medium))
        .foregroundStyle(Theme.text)
        .lineLimit(1)
    }
    .padding(.trailing, 6)
    .frame(height: ProjectWindowModel.globalTrackHeight - 4)
    .background(Theme.raised.opacity(0.9), in: .rect(cornerRadius: 2))
    .fixedSize()
    .offset(x: model.x(for: marker.position) + dragOffset, y: 2)
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { drag in
          if abs(drag.translation.width) > 3 { dragOffset = drag.translation.width }
        }
        .onEnded { drag in
          defer { dragOffset = 0 }
          if abs(drag.translation.width) > 3 {
            model.moveMarker(marker.id, to: model.position(forX: model.x(for: marker.position) + drag.translation.width))
          } else {
            model.engine.locate(to: marker.position)
          }
        }
    )
    .simultaneousGesture(TapGesture(count: 2).onEnded { model.renameTarget = .marker(marker.id) })
    .contextMenu {
      Button("Rename…") { model.renameTarget = .marker(marker.id) }
      Button("Delete", role: .destructive) { model.deleteMarker(marker.id) }
    }
    .help("Click to go to \(marker.name); drag to move it")
    .accessibilityElement()
    .accessibilityLabel("Marker \(marker.name)")
    .accessibilityIdentifier("marker")
  }
}

// MARK: - Signature

/// Time signature changes and key changes at their bars, as in Logic. Click a change to set
/// it, right-click it to set or delete it, or right-click an empty spot to add one at the
/// nearest bar; drag a change to another bar.
private struct SignatureLane: View {
  let model: ProjectWindowModel
  /// Where the pointer last was, for the context menu. A box, so hovering doesn't redraw.
  @State private var hover = HoverPosition()

  var body: some View {
    let tempoMap = model.project.tempoMap
    let editX = model.x(for: tempoMap.tickPosition(ofBarIndex: model.signatureEditBarIndex ?? 0))
    ZStack(alignment: .topLeading) {
      Color.clear
        .contentShape(.rect)
        .onContinuousHover { phase in
          if case .active(let location) = phase { hover.x = location.x }
        }
        .contextMenu {
          let bar = model.nearestBarIndex(to: model.position(forX: hover.x))
          Menu("Add Time Signature at Bar \(bar + 1)") {
            ForEach(TimeSignature.common, id: \.self) { signature in
              Button(signature.description) { model.setTimeSignature(signature, atBarIndex: bar) }
            }
          }
          if bar > 0 {
            Button("Add Key Change at Bar \(bar + 1)…") { model.addKeyChange(atBarIndex: bar) }
          }
        }
      // A bar's time signature and key sit side by side.
      ForEach(signaturePositions, id: \.self) { position in
        HStack(spacing: 3) {
          if let change = tempoMap.meterChanges.first(where: { tempoMap.tickPosition(ofBarIndex: $0.barIndex) == position }) {
            SignatureLabel(model: model, change: change)
          }
          if position == .zero {
            KeyLabel(model: model, key: model.project.keySignature, position: .zero, changeID: nil)
          } else if let change = model.project.keyChanges.first(where: { $0.position == position }) {
            KeyLabel(model: model, key: change.key, position: position, changeID: change.id)
          }
        }
        .offset(x: model.x(for: position), y: 3)
      }
    }
    .popover(
      isPresented: Binding(get: { model.keyEditPosition != nil }, set: { if !$0 { model.keyEditPosition = nil } }),
      attachmentAnchor: .rect(.rect(CGRect(
        x: model.x(for: model.keyEditPosition ?? .zero), y: 0, width: 1, height: ProjectWindowModel.globalTrackHeight))),
      arrowEdge: .bottom
    ) {
      if let position = model.keyEditPosition {
        KeyEntry(model: model, position: position)
      }
    }
    .popover(
      isPresented: Binding(
        get: { model.signatureEditBarIndex != nil }, set: { if !$0 { model.signatureEditBarIndex = nil } }),
      attachmentAnchor: .rect(.rect(CGRect(x: editX, y: 0, width: 1, height: ProjectWindowModel.globalTrackHeight))),
      arrowEdge: .bottom
    ) {
      if let barIndex = model.signatureEditBarIndex {
        SignatureEntry(model: model, barIndex: barIndex)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Signature Track")
  }

  /// Where the lane has something: every time signature change and key change.
  private var signaturePositions: [Tick] {
    let tempoMap = model.project.tempoMap
    let meters = tempoMap.meterChanges.map { tempoMap.tickPosition(ofBarIndex: $0.barIndex) }
    return Set(meters + model.project.keyTimeline.map(\.position)).sorted()
  }
}

/// Chooses the key from a bar: the song's key at bar 1, or a key change.
private struct KeyEntry: View {
  let model: ProjectWindowModel
  let position: Tick

  var body: some View {
    let key = model.project.key(at: position)
    let change = model.project.keyChanges.first { $0.position == position }
    let bar = model.project.tempoMap.bar(containing: position).index + 1
    VStack(alignment: .leading, spacing: 10) {
      Text(position == .zero ? "Key of the Song" : change == nil ? "Key Change at Bar \(bar)" : "Key at Bar \(bar)")
        .font(.headline)
      Picker("Mode", selection: Binding(get: { key.mode }, set: { set(KeySignature(tonic: key.tonic, mode: $0)) })) {
        Text("Major").tag(KeySignature.Mode.major)
        Text("Minor").tag(KeySignature.Mode.minor)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 200)
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(46), spacing: 4), count: 6), alignment: .leading, spacing: 4) {
        ForEach(0..<12, id: \.self) { tonic in
          let choice = KeySignature(tonic: tonic, mode: key.mode)
          // The key here is lit; for a new change, that's the key it changes from.
          let isChosen = choice == key && (change != nil || position == .zero)
          Button { set(choice) } label: {
            Text(choice.description)
              .font(Theme.font(11, weight: isChosen ? .semibold : .regular))
              .foregroundStyle(isChosen ? Color.white : Theme.text)
              .frame(width: 46, height: 22)
              .background(isChosen ? Theme.accent : Color.white.opacity(0.08), in: .rect(cornerRadius: 4))
              .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(isChosen ? .isSelected : [])
        }
      }
      if change == nil, position != .zero {
        Text("Now in \(key.description). Choose the key the song changes to.")
          .font(Theme.font(10))
          .foregroundStyle(.secondary)
      }
      if let change {
        Button("Delete", role: .destructive) {
          model.removeKeyChange(change.id)
          model.keyEditPosition = nil
        }
        .controlSize(.small)
      }
    }
    .padding(14)
  }

  private func set(_ key: KeySignature) {
    model.setKey(key, at: position)
  }
}

/// A key on the Signature track: the song's at bar 1, or a key change, which drags to
/// another bar.
private struct KeyLabel: View {
  let model: ProjectWindowModel
  let key: KeySignature
  let position: Tick
  let changeID: KeyChange.ID?

  @State private var dragOffset: CGFloat = 0

  var body: some View {
    Label(key.description, systemImage: "music.note")
      .labelStyle(.titleAndIcon)
      .font(Theme.font(10, weight: .medium))
      .foregroundStyle(Theme.text)
      .padding(.horizontal, 5)
      .frame(height: ProjectWindowModel.globalTrackHeight - 6)
      .background(Theme.accent.opacity(0.28), in: .rect(cornerRadius: 3))
      .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 2) }
      .fixedSize()
      .offset(x: dragOffset)
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { drag in
            if changeID != nil { dragOffset = drag.translation.width }
          }
          .onEnded { drag in
            defer { dragOffset = 0 }
            guard let changeID else { return }
            model.moveKeyChange(changeID, to: model.position(forX: model.x(for: position) + drag.translation.width))
          }
      )
      .simultaneousGesture(TapGesture().onEnded { model.keyEditPosition = position })
      .contextMenu {
        Button(changeID == nil ? "Change the Song's Key…" : "Change Key…") { model.keyEditPosition = position }
        if let changeID {
          Divider()
          Button("Delete", role: .destructive) { model.removeKeyChange(changeID) }
        }
      }
      .help(changeID == nil
        ? "The song's key. Click to change it"
        : "Key change. Click to change it, drag it to another bar; right-click to change or delete")
      .accessibilityElement()
      .accessibilityLabel(changeID == nil ? "Key \(key.description)" : "Key change to \(key.description) at bar \(model.project.tempoMap.bar(containing: position).index + 1)")
      .accessibilityIdentifier("key-signature")
  }
}

/// Sets the meter of the change at a bar: a common one, or any beats and beat unit.
private struct SignatureEntry: View {
  let model: ProjectWindowModel
  let barIndex: Int

  var body: some View {
    let signature = model.project.tempoMap.timeSignature(atBarIndex: barIndex)
    VStack(alignment: .leading, spacing: 10) {
      Text("Time Signature at Bar \(barIndex + 1)").font(.headline)
      HStack(spacing: 6) {
        Stepper(value: Binding(get: { signature.beatsPerBar }, set: { set(TimeSignature(beatsPerBar: $0, beatUnit: signature.beatUnit)) }),
          in: TimeSignature.beatsPerBarRange) {
          Text("\(signature.beatsPerBar)").font(Theme.monospaced(13)).frame(minWidth: 20, alignment: .trailing)
        }
        .accessibilityLabel("Beats per Bar")
        Text("/")
        Picker("Beat Unit", selection: Binding(get: { signature.beatUnit }, set: { set(TimeSignature(beatsPerBar: signature.beatsPerBar, beatUnit: $0)) })) {
          ForEach(TimeSignature.supportedBeatUnits.sorted(), id: \.self) { Text("\($0)").tag($0) }
        }
        .labelsHidden()
        .fixedSize()
      }
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(42), spacing: 4), count: 5), alignment: .leading, spacing: 4) {
        ForEach(TimeSignature.common, id: \.self) { common in
          Button(common.description) { set(common) }
            .controlSize(.small)
        }
      }
      if barIndex != 0 {
        Button("Delete", role: .destructive) {
          model.removeTimeSignature(atBarIndex: barIndex)
          model.signatureEditBarIndex = nil
        }
        .controlSize(.small)
      }
    }
    .padding(14)
  }

  private func set(_ signature: TimeSignature) {
    model.setTimeSignature(signature, atBarIndex: barIndex)
  }
}

private struct SignatureLabel: View {
  let model: ProjectWindowModel
  let change: TempoMap.MeterChange

  @State private var dragOffset: CGFloat = 0

  var body: some View {
    let x = model.x(for: model.project.tempoMap.tickPosition(ofBarIndex: change.barIndex))
    Text(change.signature.description)
      .font(Theme.monospaced(10))
      .foregroundStyle(Theme.text)
      .padding(.horizontal, 5)
      .frame(height: ProjectWindowModel.globalTrackHeight - 6)
      .background(Theme.raised, in: .rect(cornerRadius: 3))
      .overlay(alignment: .leading) { Rectangle().fill(Theme.text.opacity(0.8)).frame(width: 2) }
      .fixedSize()
      .offset(x: dragOffset)
      .gesture(
        DragGesture(minimumDistance: 3)
          .onChanged { drag in
            if change.barIndex != 0 { dragOffset = drag.translation.width }
          }
          .onEnded { drag in
            defer { dragOffset = 0 }
            guard change.barIndex != 0 else { return }
            model.moveTimeSignature(fromBarIndex: change.barIndex, to: model.position(forX: x + drag.translation.width))
          }
      )
      .simultaneousGesture(TapGesture().onEnded { model.signatureEditBarIndex = change.barIndex })
      .contextMenu {
        ForEach(TimeSignature.common, id: \.self) { signature in
          Button(signature.description) { model.setTimeSignature(signature, atBarIndex: change.barIndex) }
        }
        if change.barIndex != 0 {
          Divider()
          Button("Delete", role: .destructive) { model.removeTimeSignature(atBarIndex: change.barIndex) }
        }
      }
      .help(change.barIndex == 0 ? "Click to change the time signature" : "Click to change it, drag it to another bar; right-click to change or delete")
      .accessibilityElement()
      .accessibilityLabel("Time signature \(change.signature.description) at bar \(change.barIndex + 1)")
      .accessibilityIdentifier("time-signature")
  }
}

// MARK: - Tempo

/// The tempo as a line, stepping at each tempo change, with a handle on each change: drag
/// it up or down to change the tempo, sideways to move it. Double-click an empty spot to
/// add a change there at the tempo under the pointer.
private struct TempoLane: View {
  let model: ProjectWindowModel

  private var height: CGFloat { ProjectWindowModel.tempoTrackHeight }
  private static let inset: CGFloat = 6

  /// Where a tempo sits vertically.
  private func y(for bpm: Double, in range: ClosedRange<Double>) -> CGFloat {
    let fraction = (bpm - range.lowerBound) / (range.upperBound - range.lowerBound)
    return Self.inset + (height - Self.inset * 2) * CGFloat(1 - fraction)
  }

  private func bpm(atY y: CGFloat, in range: ClosedRange<Double>) -> Double {
    let fraction = 1 - Double((y - Self.inset) / (height - Self.inset * 2))
    return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
  }

  var body: some View {
    let range = model.tempoTrackRange
    let changes = model.project.tempoMap.tempoChanges
    let width = model.contentWidth
    // Like the ruler, the line is only drawn across the render range.
    let render = model.scroll.renderRange
    ZStack(alignment: .topLeading) {
      Canvas { context, _ in
        var line = Path()
        for (index, change) in changes.enumerated() {
          let x = model.x(for: change.position) - render.lowerBound
          let endX = (index + 1 < changes.count ? model.x(for: changes[index + 1].position) : width) - render.lowerBound
          let y = y(for: change.bpm, in: range)
          if index == 0 {
            line.move(to: CGPoint(x: x, y: y))
          } else {
            line.addLine(to: CGPoint(x: x, y: y))
          }
          line.addLine(to: CGPoint(x: endX, y: y))
        }
        context.stroke(line, with: .color(Theme.accent), lineWidth: 1.5)
      }
      .frame(width: render.upperBound - render.lowerBound, height: height)
      .contentShape(.rect)
      .gesture(SpatialTapGesture(count: 2).onEnded { tap in
        model.addTempoChange(
          at: model.position(forX: tap.location.x + render.lowerBound), bpm: bpm(atY: tap.location.y, in: range))
      })
      .offset(x: render.lowerBound)
      ForEach(changes, id: \.position) { change in
        TempoHandle(
          model: model, change: change, y: y(for: change.bpm, in: range),
          bpmPerPoint: (range.upperBound - range.lowerBound) / Double(height - Self.inset * 2))
      }
    }
    // Top-leading: the canvas is narrower than the lane and would otherwise be centred.
    .frame(width: width, height: height, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Tempo Track")
  }
}

private struct TempoHandle: View {
  let model: ProjectWindowModel
  let change: TempoMap.TempoChange
  let y: CGFloat
  let bpmPerPoint: Double

  @State private var drag: CGSize = .zero

  var body: some View {
    let x = model.x(for: change.position)
    let bpm = ProjectWindowModel.roundedTempo(change.bpm - Double(drag.height) * bpmPerPoint)
    let isFirst = change.position == .zero
    HStack(spacing: 3) {
      Circle()
        .fill(Theme.accent)
        .overlay(Circle().strokeBorder(Color.black.opacity(0.5)))
        .frame(width: 8, height: 8)
      Text(bpm.formatted(.number.precision(.fractionLength(0...2))))
        .font(Theme.monospaced(9))
        .foregroundStyle(Theme.text)
    }
    .fixedSize()
    .offset(x: x - 4 + (isFirst ? 0 : drag.width), y: y - 4 + drag.height)
    .gesture(
      DragGesture(minimumDistance: 2)
        .onChanged { drag = $0.translation }
        .onEnded { value in
          defer { drag = .zero }
          let newBPM = ProjectWindowModel.roundedTempo(change.bpm - Double(value.translation.height) * bpmPerPoint)
          let position = model.position(forX: x + value.translation.width)
          model.moveTempoChange(at: change.position, to: position, bpm: newBPM)
        }
    )
    .contextMenu {
      if !isFirst {
        Button("Delete", role: .destructive) { model.removeTempoChange(at: change.position) }
      }
    }
    .help(isFirst ? "Drag up or down to change the tempo" : "Drag to change the tempo or move it; right-click to delete")
    .accessibilityElement()
    .accessibilityLabel("Tempo \(Int(change.bpm)) at bar \(model.project.tempoMap.musicalPosition(at: change.position).bar)")
    .accessibilityIdentifier("tempo-change")
  }
}

/// Where the pointer last was over a lane. A plain reference so updating it doesn't redraw.
private final class HoverPosition {
  var x: CGFloat = 0
}

/// Renames the marker or section in `model.renameTarget`.
struct RenameModifier: ViewModifier {
  let model: ProjectWindowModel
  @State private var name = ""

  func body(content: Content) -> some View {
    content
      .alert(title, isPresented: Binding(get: { model.renameTarget != nil }, set: { if !$0 { model.renameTarget = nil } })) {
        TextField("Name", text: $name)
        Button("Rename") {
          switch model.renameTarget {
          case .marker(let id): model.renameMarker(id, to: name)
          case .section(let id): model.renameSection(id, to: name)
          case nil: break
          }
          model.renameTarget = nil
        }
        Button("Cancel", role: .cancel) { model.renameTarget = nil }
      }
      .onChange(of: model.renameTarget) { _, target in
        switch target {
        case .marker(let id): name = model.project.markers.first { $0.id == id }?.name ?? ""
        case .section(let id): name = model.project.arrangement.first { $0.id == id }?.name ?? ""
        case nil: break
        }
      }
  }

  private var title: String {
    if case .section = model.renameTarget { "Rename Arrangement Marker" } else { "Rename Marker" }
  }
}

#Preview {
  var project = Project.previewSong
  let bar = Tick.quarterNotes(4)
  project.arrangement = [
    ArrangementSection(name: "Intro", start: .zero, length: bar * 4),
    ArrangementSection(name: "Verse", start: bar * 4, length: bar * 8),
    ArrangementSection(name: "Chorus", start: bar * 12, length: bar * 8),
  ]
  project.markers = [Marker(name: "Vocals in", position: bar * 4), Marker(name: "Key change", position: bar * 14)]
  try? project.tempoMap.setTempo(132, at: bar * 4)
  try? project.tempoMap.setTempo(110, at: bar * 6)
  try? project.tempoMap.setTimeSignature(TimeSignature(beatsPerBar: 3, beatUnit: 4), atBarIndex: 5)
  // A key change up a tone for the second verse, and another on its own.
  project.keyChanges = [KeyChange(position: bar * 5, key: KeySignature(tonic: 2, mode: .major)), KeyChange(position: bar * 7, key: KeySignature(tonic: 9, mode: .minor))]
  let model = ProjectWindowModel(document: OngakuDocument(project: project))
  model.isGlobalTracksVisible = true
  return ArrangeView(model: model).frame(width: 1000, height: 360)
}

