//
//  ProjectWindowModel+Automation.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// The automated volume, pan and send levels one track's controls show as the playhead
/// moves. Each track has its own, and a value only changes when it moves noticeably, so
/// during playback only the controls that are actually moving redraw (not every channel
/// strip on every tick).
@MainActor
@Observable
final class AutomatedControlValues {
  var volume: Double
  var pan: Double
  /// The automated sends' levels, in decibels like the volume.
  var sends: [Send.ID: Double]

  init(volume: Double, pan: Double, sends: [Send.ID: Double] = [:]) {
    self.volume = volume
    self.pan = pan
    self.sends = sends
  }

  /// Changes smaller than these don't redraw anything.
  static let volumeStep = 0.05
  static let panStep = 0.002
}

/// A control being recorded into automation during playback (Touch or Latch).
struct AutomationWrite {
  var trackID: Track.ID
  var parameter: AutomationParameter
  var points: [AutomationPoint]
  /// The grouped tracks moving with the control that are in Touch or Latch too: what each
  /// one writes, alongside it.
  var partnerPoints: [Track.ID: [AutomationPoint]] = [:]
  /// Where the control has moved the grouped tracks that aren't writing (they're heard
  /// there, but their controls don't show it), so they keep moving with it.
  var heldPartnerValues: [Track.ID: Double] = [:]
  /// In Latch mode, the control has been let go but its last value is still being written
  /// until playback stops.
  var isReleased = false

  /// What's being written on a track: the control's own points, or a grouped partner's.
  func points(on trackID: Track.ID) -> [AutomationPoint]? {
    trackID == self.trackID ? points : partnerPoints[trackID]
  }
}

extension ProjectWindowModel {
  func toggleAutomation() {
    isAutomationVisible.toggle()
  }

  /// The parameter a track shows in its automation lane.
  func displayedAutomationParameter(for trackID: Track.ID) -> AutomationParameter {
    automationParameters[trackID] ?? .volume
  }

  /// What a control shows: the value being written, the automation at the playhead, or the
  /// channel strip's setting.
  func displayedValue(of parameter: AutomationParameter, on track: Track) -> Double {
    // Only tracks in Touch or Latch write, so the others don't watch the write.
    if track.automationMode.writes, let automationWrite, automationWrite.parameter == parameter,
      let last = automationWrite.points(on: track.id)?.last
    {
      return last.value
    }
    guard track.isAutomated(parameter) else { return parameter.value(in: track.channel) }
    let values = automatedControls(for: track)
    switch parameter {
    case .volume: return values.volume
    case .pan: return values.pan
    case .sendLevel(let id): return values.sends[id] ?? parameter.value(in: track.channel)
    // No control shows a plug-in's automation; the plug-in's own window follows it.
    case .plugin: return parameter.value(in: track.channel)
    }
  }

  /// A track's automated control values, created on first use.
  func automatedControls(for track: Track) -> AutomatedControlValues {
    if let values = automatedControlValues[track.id] {
      return values
    }
    let position = engine.playheadPosition
    let values = AutomatedControlValues(
      volume: track.automatedValue(of: .volume, at: position), pan: track.automatedValue(of: .pan, at: position),
      sends: Dictionary(uniqueKeysWithValues: track.automatedSends.map { ($0, track.automatedValue(of: .sendLevel($0), at: position)) }))
    automatedControlValues[track.id] = values
    return values
  }

  /// Brings every track's automated control values up to the playhead. Called as the
  /// playhead moves and when the project changes.
  func refreshAutomatedControls() {
    guard !automatedControlValues.isEmpty else { return }
    let position = engine.playheadPosition
    for track in project.tracks {
      guard let values = automatedControlValues[track.id] else { continue }
      let volume = track.automatedValue(of: .volume, at: position)
      if abs(volume - values.volume) >= AutomatedControlValues.volumeStep { values.volume = volume }
      let pan = track.automatedValue(of: .pan, at: position)
      if abs(pan - values.pan) >= AutomatedControlValues.panStep { values.pan = pan }
      for sendID in track.automatedSends {
        let level = track.automatedValue(of: .sendLevel(sendID), at: position)
        if abs(level - (values.sends[sendID] ?? .infinity)) >= AutomatedControlValues.volumeStep { values.sends[sendID] = level }
      }
    }
  }

  // MARK: - Editing points

  func addAutomationPoint(at position: Tick, value: Double, to parameter: AutomationParameter, on trackID: Track.ID) {
    perform(AddAutomationPoints([AutomationPoint(position: max(.zero, position), value: value)], to: parameter, on: trackID))
  }

  func moveAutomationPoint(_ point: AutomationPoint, in parameter: AutomationParameter, on trackID: Track.ID) {
    perform(UpdateAutomationPoints([point], in: parameter, on: trackID))
  }

  func deleteAutomationPoint(_ pointID: AutomationPoint.ID, from parameter: AutomationParameter, on trackID: Track.ID) {
    perform(DeleteAutomationPoints([pointID], from: parameter, on: trackID))
  }

  func setAutomationMode(_ mode: AutomationMode, for trackID: Track.ID) {
    perform(SetAutomationMode(mode, for: trackID))
  }

  // MARK: - Moving controls by hand

  /// A fader, pan or send knob moved by hand. During playback in Touch or Latch this records
  /// automation (and the grouped tracks moving with it record theirs, if they're in Touch or
  /// Latch too); otherwise it only changes what's heard until the move is committed.
  func controlChanged(_ parameter: AutomationParameter, to value: Double, on trackID: Track.ID) {
    engine.setLiveValue(parameter, value, onTrack: trackID)
    let partners = moveGroupLive(parameter, of: trackID, to: value)
    guard let track = project.track(withID: trackID), engine.isPlaying, track.automationMode.writes else { return }
    let position = engine.playheadPosition
    let writingPartners = partners.filter { $0.track.automationMode.writes }.map { (trackID: $0.track.id, value: $0.value) }
    let heldPartners = partners.filter { !$0.track.automationMode.writes }.map { ($0.track.id, $0.value) }
    defer { automationWrite?.heldPartnerValues = Dictionary(uniqueKeysWithValues: heldPartners) }

    if var write = automationWrite, write.trackID == trackID, write.parameter == parameter {
      // A cycle jump sends the playhead back: keep what was written so far as its own take.
      if let last = write.points.last, position < last.position {
        commitAutomationWrite()
        beginAutomationWrite(parameter, on: trackID, at: position, value: value, partners: writingPartners)
        return
      }
      write.isReleased = false
      write.points.append(AutomationPoint(position: position, value: value))
      for partner in writingPartners {
        write.partnerPoints[partner.trackID]?.append(AutomationPoint(position: position, value: partner.value))
      }
      automationWrite = write
    } else {
      commitAutomationWrite()
      beginAutomationWrite(parameter, on: trackID, at: position, value: value, partners: writingPartners)
    }
  }

  /// The control was let go. Returns `true` if the move was recorded as automation, in
  /// which case the channel strip's own setting shouldn't change.
  @discardableResult
  func controlReleased(_ parameter: AutomationParameter, on trackID: Track.ID) -> Bool {
    guard var write = automationWrite, write.trackID == trackID, write.parameter == parameter else { return false }
    if project.track(withID: trackID)?.automationMode == .latch, engine.isPlaying {
      write.isReleased = true
      automationWrite = write
    } else {
      commitAutomationWrite()
    }
    return true
  }

  /// Ends a Latch write when the transport stops: the last value runs up to where it stopped.
  func transportDidStop(at position: Tick) {
    guard var write = automationWrite else { return }
    if let last = write.points.last, position > last.position {
      write.points.append(AutomationPoint(position: position, value: last.value))
    }
    for (partnerID, points) in write.partnerPoints {
      if let last = points.last, position > last.position {
        write.partnerPoints[partnerID]?.append(AutomationPoint(position: position, value: last.value))
      }
    }
    automationWrite = write
    commitAutomationWrite()
  }

  private func beginAutomationWrite(
    _ parameter: AutomationParameter, on trackID: Track.ID, at position: Tick, value: Double,
    partners: [(trackID: Track.ID, value: Double)]
  ) {
    engine.setAutomationOverride(true, for: parameter, onTrack: trackID)
    var write = AutomationWrite(
      trackID: trackID, parameter: parameter, points: [AutomationPoint(position: position, value: value)])
    for partner in partners {
      engine.setAutomationOverride(true, for: parameter, onTrack: partner.trackID)
      write.partnerPoints[partner.trackID] = [AutomationPoint(position: position, value: partner.value)]
    }
    automationWrite = write
  }

  /// Stores what was written (on the control's track and any grouped partners) as one
  /// undoable step, with just enough points to keep its shape.
  func commitAutomationWrite() {
    guard let write = automationWrite else { return }
    automationWrite = nil
    let writes = [(write.trackID, write.points)] + write.partnerPoints.map { ($0.key, $0.value) }
    let tolerance = (write.parameter.isDecibels ? 0.25 : 0.01) * AppSettings.automationThinning.toleranceScale
    var commands: [any EditCommand] = []
    for (trackID, points) in writes {
      engine.setAutomationOverride(false, for: write.parameter, onTrack: trackID)
      guard let first = points.first, let last = points.last else { continue }
      let thinned = AutomationLane.thinned(points, tolerance: tolerance)
      commands.append(WriteAutomation(thinned, over: first.position...last.position, to: write.parameter, on: trackID))
    }
    guard let command = commands.first else { return }
    perform(commands.count == 1 ? command : CompositeCommand(command.actionName, commands: commands))
  }

  /// How a plug-in parameter's values read (its unit and range), when the plug-in is loaded;
  /// `nil` for the mixer's own controls, or a plug-in that isn't loaded.
  func pluginValueFormat(for parameter: AutomationParameter, on trackID: Track.ID) -> PluginValueFormat? {
    guard case .plugin(let pluginParameter) = parameter else { return nil }
    return engine.valueFormat(of: pluginParameter, onTrack: trackID)
  }
}
