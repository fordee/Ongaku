//
//  ProjectWindowModel+TempoTrack.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// The global Signature and Tempo tracks: time signature and tempo changes along the
/// song, as in Logic.
extension ProjectWindowModel {
  /// The Tempo track is taller than the others, to show the tempo as a line.
  static let tempoTrackHeight: CGFloat = 48

  /// The tempos the Tempo track spans, top to bottom: the song's tempos with room around
  /// them, and at least 40 BPM.
  var tempoTrackRange: ClosedRange<Double> {
    let tempos = project.tempoMap.tempoChanges.map(\.bpm)
    let low = (tempos.min() ?? 120) - 10
    let high = (tempos.max() ?? 120) + 10
    let middle = (low + high) / 2
    let span = max(high - low, 40)
    let lower = max(TempoMap.bpmRange.lowerBound, middle - span / 2)
    return lower...(lower + span)
  }

  /// Double-clicking the Tempo track adds a tempo change there (snapped to the grid).
  func addTempoChange(at position: Tick, bpm: Double) {
    let snapped = max(Tick(1), snap(position))
    perform(SetTempo(Self.roundedTempo(bpm), at: snapped))
  }

  /// Dragging a tempo change moves it (except the first) and changes its tempo.
  func moveTempoChange(at oldPosition: Tick, to position: Tick, bpm: Double) {
    let destination = oldPosition == .zero ? .zero : snap(position)
    perform(UpdateTempoChange(at: oldPosition, to: destination, bpm: Self.roundedTempo(bpm)))
  }

  func removeTempoChange(at position: Tick) {
    perform(RemoveTempoChange(at: position))
  }

  /// Tempos dragged on the Tempo track land on whole BPM, within the allowed range.
  static func roundedTempo(_ bpm: Double) -> Double {
    min(max(bpm.rounded(), TempoMap.bpmRange.lowerBound), TempoMap.bpmRange.upperBound)
  }

  // MARK: - Time signatures

  /// The bar a position falls in, rounded to the nearest bar line (for placing meters).
  func nearestBarIndex(to position: Tick) -> Int {
    let tempoMap = project.tempoMap
    let bar = tempoMap.bar(containing: max(.zero, position))
    let next = tempoMap.tickPosition(ofBarIndex: bar.index + 1)
    return position - bar.start < next - position ? bar.index : bar.index + 1
  }

  /// The Signature track's +: a change at the bar after the playhead (or at the playhead's
  /// bar, if it's on a bar line past bar 1) in the meter already there, opened in its
  /// popover so the person sees it and can pick another.
  func addTimeSignatureAtPlayhead() {
    let barIndex = nextBarIndexAfterPlayhead
    if !project.tempoMap.meterChanges.contains(where: { $0.barIndex == barIndex }) {
      setTimeSignature(project.tempoMap.timeSignature(atBarIndex: barIndex), atBarIndex: barIndex)
    }
    isGlobalTracksVisible = true
    signatureEditBarIndex = barIndex
  }

  func setTimeSignature(_ signature: TimeSignature, atBarIndex barIndex: Int) {
    perform(SetTimeSignature(signature, atBarIndex: max(0, barIndex)))
  }

  func moveTimeSignature(fromBarIndex oldBarIndex: Int, to position: Tick) {
    let barIndex = nearestBarIndex(to: position)
    guard barIndex != oldBarIndex else { return }
    perform(MoveTimeSignatureChange(fromBarIndex: oldBarIndex, toBarIndex: barIndex))
  }

  func removeTimeSignature(atBarIndex barIndex: Int) {
    perform(RemoveTimeSignatureChange(atBarIndex: barIndex))
  }

  // MARK: - Key changes

  /// The bar after the playhead (or the playhead's bar, if it's on a bar line past bar 1),
  /// where the Signature track's + adds a change.
  private var nextBarIndexAfterPlayhead: Int {
    let playhead = max(.zero, engine.playheadPosition)
    let bar = project.tempoMap.bar(containing: playhead)
    return bar.start == playhead && bar.index > 0 ? bar.index : bar.index + 1
  }

  /// The Signature track's Add Key Change: opens the key popover at the next bar. Nothing is
  /// added until a key is chosen, as a change to the key already playing changes nothing.
  func addKeyChangeAtPlayhead() {
    addKeyChange(atBarIndex: nextBarIndexAfterPlayhead)
  }

  func addKeyChange(atBarIndex barIndex: Int) {
    isGlobalTracksVisible = true
    keyEditPosition = project.tempoMap.tickPosition(ofBarIndex: max(0, barIndex))
  }

  /// Sets the key from `position`: the song's key at the start, or a key change there.
  func setKey(_ key: KeySignature, at position: Tick) {
    guard key != project.key(at: position) || project.keyChanges.contains(where: { $0.position == position }) else { return }
    perform(SetKey(key, at: position))
  }

  /// Moves a key change to the bar nearest `position` (never bar 1, which has the song's key).
  func moveKeyChange(_ changeID: KeyChange.ID, to position: Tick) {
    let barIndex = max(1, nearestBarIndex(to: position))
    let target = project.tempoMap.tickPosition(ofBarIndex: barIndex)
    guard let change = project.keyChanges.first(where: { $0.id == changeID }), change.position != target else { return }
    perform(MoveKeyChange(changeID, to: target))
  }

  func removeKeyChange(_ changeID: KeyChange.ID) {
    perform(RemoveKeyChanges([changeID]))
  }
}
