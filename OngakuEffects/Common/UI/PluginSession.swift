//
//  PluginSession.swift
//  OngakuEffects
//

import AudioToolbox
import Foundation
import Observation

/// What every Ongaku plug-in window shares, whichever effect it is: its presets (the
/// factory ones and the user's own), A/B comparison, and undo and redo of the changes made
/// in the window.
///
/// Only changes made in the window are undoable; the host's automation moves parameters
/// without adding to the history. A knob turn is one step: changes that follow each other
/// closely are gathered into one.
@MainActor
@Observable
final class PluginSession {
  /// Every parameter's value, and any settings a plug-in keeps outside its parameters (the
  /// Session Drummer's song).
  struct Snapshot {
    var values: [AUParameterAddress: AUValue]
    var custom: Data?
  }

  /// Settings a plug-in keeps outside its parameters, for undo and A/B.
  struct CustomState {
    var get: @MainActor () -> Data?
    var set: @MainActor (Data?) -> Void
  }

  /// Set by a plug-in with settings outside its parameters.
  @ObservationIgnored var customState: CustomState?

  enum Slot: String { case a = "A", b = "B" }

  @ObservationIgnored private weak var audioUnit: OngakuEffectsAudioUnit?

  // MARK: Presets

  private(set) var factoryPresets: [AUAudioUnitPreset] = []
  private(set) var userPresets: [AUAudioUnitPreset] = []
  /// The preset the settings came from, if any.
  private(set) var presetName: String?
  /// Whether the settings have changed since the preset was chosen.
  private(set) var isModified = false
  /// The settings the chosen preset gave, to tell when they've been changed.
  @ObservationIgnored private var presetSnapshot: Snapshot?

  // MARK: A/B

  private(set) var activeSlot = Slot.a
  /// The settings of the slot not being heard (nil until it's first used: it starts as a
  /// copy of the other).
  @ObservationIgnored private var otherSlot: Snapshot?

  // MARK: Undo

  private(set) var canUndo = false
  private(set) var canRedo = false
  @ObservationIgnored private var undoStack: [Snapshot] = []
  @ObservationIgnored private var redoStack: [Snapshot] = []
  /// The settings before the change being made now (a drag, a run of clicks).
  @ObservationIgnored private var pendingBefore: Snapshot?
  @ObservationIgnored private var commitTask: Task<Void, Never>?
  @ObservationIgnored private var observerToken: AUParameterObserverToken?
  @ObservationIgnored private var refreshQueued = false

  static let historyLimit = 100

  init(audioUnit: OngakuEffectsAudioUnit) {
    self.audioUnit = audioUnit
    factoryPresets = audioUnit.factoryPresets ?? []
    userPresets = audioUnit.userPresets
    if let preset = audioUnit.currentPreset {
      presetName = preset.name
      presetSnapshot = snapshot()
    }
    // Any change (the window's, the host's automation, a preset) may change whether the
    // settings still match the preset.
    observerToken = audioUnit.parameterTree?.token(byAddingParameterObserver: { [weak self] _, _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.queueRefresh() } }
    })
  }

  // MARK: - Settings

  /// Every parameter's value now.
  func parameterValues() -> [AUParameterAddress: AUValue] {
    var values: [AUParameterAddress: AUValue] = [:]
    for parameter in audioUnit?.parameterTree?.allParameters ?? [] {
      values[parameter.address] = parameter.value
    }
    return values
  }

  /// All the settings now.
  func snapshot() -> Snapshot {
    Snapshot(values: parameterValues(), custom: customState?.get())
  }

  /// Sets every parameter in `snapshot` (and the custom settings); the window follows.
  private func apply(_ snapshot: Snapshot) {
    guard let tree = audioUnit?.parameterTree else { return }
    for (address, value) in snapshot.values {
      tree.parameter(withAddress: address)?.setValue(value, originator: nil)
    }
    if let customState, let custom = snapshot.custom, custom != customState.get() {
      customState.set(custom)
    }
    queueRefresh()
  }

  private func queueRefresh() {
    guard !refreshQueued else { return }
    refreshQueued = true
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        self.refreshQueued = false
        self.isModified = self.presetSnapshot.map { !Self.same($0, self.snapshot()) } ?? false
      }
    }
  }

  /// Whether two sets of settings sound the same (allowing for float round-off).
  static func same(_ first: Snapshot, _ second: Snapshot) -> Bool {
    // Custom settings only count once both sides have them (a window may add them later).
    (first.custom == nil || second.custom == nil || first.custom == second.custom)
      && first.values.allSatisfy { address, value in
      guard let other = second.values[address] else { return true }
      return abs(other - value) <= max(abs(value), 1) * 1e-5
    }
  }

  // MARK: - Undo

  /// Called by the window's controls as they change a parameter, with its value before.
  func noteUserChange(address: AUParameterAddress, oldValue: AUValue) {
    if pendingBefore == nil {
      var before = snapshot()
      before.values[address] = oldValue
      pendingBefore = before
    }
    scheduleCommit()
  }

  /// Called when the window changes the custom settings, with them as they were before.
  func noteCustomChange(before custom: Data?) {
    if pendingBefore == nil {
      var before = snapshot()
      before.custom = custom
      pendingBefore = before
    }
    scheduleCommit()
    queueRefresh()
  }

  private func scheduleCommit() {
    // A knob turn is one step: commit once the changes stop for a moment.
    commitTask?.cancel()
    commitTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      self?.commitPendingChange()
    }
  }

  private func commitPendingChange() {
    commitTask?.cancel()
    commitTask = nil
    guard let before = pendingBefore else { return }
    pendingBefore = nil
    guard !Self.same(before, snapshot()) else { return }
    push(before)
  }

  /// Records `before` as a step to undo back to.
  private func push(_ before: Snapshot) {
    undoStack.append(before)
    if undoStack.count > Self.historyLimit { undoStack.removeFirst() }
    redoStack.removeAll()
    updateHistoryState()
  }

  func undo() {
    commitPendingChange()
    guard let previous = undoStack.popLast() else { return }
    redoStack.append(snapshot())
    apply(previous)
    updateHistoryState()
  }

  func redo() {
    commitPendingChange()
    guard let next = redoStack.popLast() else { return }
    undoStack.append(snapshot())
    apply(next)
    updateHistoryState()
  }

  /// Sets several parameters as one undoable change, as the window would (Mastering's
  /// listening sets the settings it chose for the song this way).
  func set(_ values: [AUParameterAddress: AUValue]) {
    guard let tree = audioUnit?.parameterTree else { return }
    commitPendingChange()
    let before = snapshot()
    for (address, value) in values {
      tree.parameter(withAddress: address)?.setValue(value, originator: nil)
    }
    queueRefresh()
    if !Self.same(before, snapshot()) { push(before) }
  }

  private func updateHistoryState() {
    canUndo = !undoStack.isEmpty
    canRedo = !redoStack.isEmpty
  }

  // MARK: - Presets

  func choose(_ preset: AUAudioUnitPreset) {
    guard let audioUnit else { return }
    commitPendingChange()
    let before = snapshot()
    audioUnit.currentPreset = preset
    presetName = preset.name
    presetSnapshot = snapshot()
    isModified = false
    if let after = presetSnapshot, !Self.same(before, after) { push(before) }
  }

  /// The factory presets, then the user's, in the order the arrows step through them.
  var allPresets: [AUAudioUnitPreset] { factoryPresets + userPresets }

  /// The next (or previous) preset, wrapping round.
  func step(by offset: Int) {
    let presets = allPresets
    guard !presets.isEmpty else { return }
    let current = presets.firstIndex { $0.name == presetName && !isModified } ?? presets.firstIndex { $0.name == presetName }
    let index = current.map { ($0 + offset + presets.count) % presets.count } ?? (offset > 0 ? 0 : presets.count - 1)
    choose(presets[index])
  }

  /// Saves the settings as one of the user's presets (replacing one with the same name).
  @discardableResult
  func saveUserPreset(named name: String) -> Bool {
    guard let audioUnit, audioUnit.supportsUserPresets else { return false }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let preset = AUAudioUnitPreset()
    preset.name = trimmed
    // User presets have negative numbers; reuse the number of one with the same name.
    if let existing = audioUnit.userPresets.first(where: { $0.name == trimmed }) {
      preset.number = existing.number
    } else {
      preset.number = (audioUnit.userPresets.map(\.number).min() ?? 0) - 1
    }
    do {
      try audioUnit.saveUserPreset(preset)
    } catch {
      return false
    }
    userPresets = audioUnit.userPresets
    audioUnit.currentPreset = preset
    presetName = trimmed
    presetSnapshot = snapshot()
    isModified = false
    return true
  }

  func deleteUserPreset(_ preset: AUAudioUnitPreset) {
    guard let audioUnit else { return }
    try? audioUnit.deleteUserPreset(preset)
    userPresets = audioUnit.userPresets
    if presetName == preset.name {
      presetName = nil
      presetSnapshot = nil
      isModified = false
    }
  }

  /// Renames one of the user's presets (saving its settings under the new name).
  func renameUserPreset(_ preset: AUAudioUnitPreset, to name: String) {
    guard let audioUnit else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != preset.name else { return }
    let current = snapshot()
    let wasChosen = presetName == preset.name
    audioUnit.currentPreset = preset
    try? audioUnit.deleteUserPreset(preset)
    saveUserPreset(named: trimmed)
    if !wasChosen {
      apply(current)
    }
  }

  // MARK: - A/B

  /// Switches to the other set of settings, keeping these to come back to.
  func switchSlot() {
    commitPendingChange()
    let current = snapshot()
    let other = otherSlot ?? current
    otherSlot = current
    activeSlot = activeSlot == .a ? .b : .a
    apply(other)
  }

  /// Makes the other slot the same as this one.
  func copyToOtherSlot() {
    otherSlot = snapshot()
  }

  /// The other slot's name, for "Copy A to B".
  var otherSlotName: String { (activeSlot == .a ? Slot.b : Slot.a).rawValue }
}
