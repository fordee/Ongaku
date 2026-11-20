//
//  ProjectWindowModel+SmartControls.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// A track's control, as a Smart Control knob or a MIDI controller plays it.
struct SmartControlTarget: Hashable {
  var trackID: Track.ID
  var parameter: AutomationParameter
}

/// Logic's Smart Controls (the B key) and controller assignments (MIDI Learn): knobs for a
/// track's most useful controls, and knobs on a MIDI controller that move them.
extension ProjectWindowModel {
  /// The controls a track's knobs play: its own Smart Controls, or until it has some,
  /// suggestions (see `suggestedSmartControls`).
  func smartControls(for track: Track) -> [AutomationParameter] {
    track.smartControls.isEmpty ? suggestedSmartControls(for: track) : track.smartControls.map(\.parameter)
  }

  /// What the panel offers a track with no Smart Controls, as Logic maps them for you: the
  /// first parameters of its instrument plug-in (or its first insert), otherwise its fader,
  /// pan and sends.
  func suggestedSmartControls(for track: Track) -> [AutomationParameter] {
    let instrument: PluginReference? = if case .audioUnit(let plugin) = track.channel.instrument { plugin } else { nil }
    for plugin in [instrument, track.channel.inserts.first].compactMap(\.self) {
      let parameters = engine.automatableParameters(ofPlugin: plugin.id, onTrack: track.id)
      if !parameters.isEmpty { return parameters.prefix(SmartControl.count).map(AutomationParameter.plugin) }
    }
    return Array((AutomationParameter.channelParameters + track.channel.sends.map { .sendLevel($0.id) }).prefix(SmartControl.count))
  }

  /// Every control a knob can be mapped to: the strip's, then each plug-in's parameters.
  func mappableControls(for track: Track) -> [(title: String, parameters: [AutomationParameter])] {
    var groups = [("Channel Strip", AutomationParameter.channelParameters + track.channel.sends.map { AutomationParameter.sendLevel($0.id) })]
    for plugin in track.channel.plugins {
      let parameters = engine.automatableParameters(ofPlugin: plugin.id, onTrack: track.id).map(AutomationParameter.plugin)
      if !parameters.isEmpty { groups.append((plugin.name, parameters)) }
    }
    return groups
  }

  /// A send's knob is named for where it goes.
  func controlName(_ parameter: AutomationParameter, on track: Track) -> String {
    guard case .sendLevel(let id) = parameter, let send = track.channel.sends.first(where: { $0.id == id }) else {
      return parameter.name
    }
    return "Send to \(project.track(withID: send.destinationTrackID)?.name ?? "Aux")"
  }

  /// Where a knob is: a plug-in parameter where the plug-in has it now, otherwise as the
  /// mixer shows it.
  func smartControlValue(_ parameter: AutomationParameter, on track: Track) -> Double {
    if case .plugin(let plugin) = parameter, let value = engine.currentValue(of: plugin, onTrack: track.id) { return value }
    return displayedValue(of: parameter, on: track)
  }

  /// Maps knob `index` to a control (or clears it with `nil`). The first change keeps the
  /// suggestions the panel was showing for the other knobs.
  func mapSmartControl(_ index: Int, on track: Track, to parameter: AutomationParameter?) {
    var controls = smartControls(for: track)
    if let parameter {
      controls.removeAll { $0 == parameter }
      controls.insert(parameter, at: min(index, controls.count))
      if controls.count > SmartControl.count { controls.removeLast() }
    } else if controls.indices.contains(index) {
      controls.remove(at: index)
    }
    perform(SetSmartControls(controls, on: track.id))
  }

  /// A knob, or a MIDI controller, moved a control: heard straight away, and recorded as
  /// automation in Touch and Latch, as moving it on the channel strip does.
  func smartControlChanged(_ target: SmartControlTarget, to value: Double) {
    controlChanged(target.parameter, to: value, on: target.trackID)
  }

  /// The knob was let go: a plug-in already has its new value (and saves it with its
  /// settings); the fader, pan and sends are stored on the channel strip.
  func smartControlReleased(_ target: SmartControlTarget, at value: Double) {
    guard !controlReleased(target.parameter, on: target.trackID), let track = project.track(withID: target.trackID) else { return }
    switch target.parameter {
    case .volume: setChannel(track.id, actionName: "Volume") { $0.volume = value }
    case .pan: setChannel(track.id, actionName: "Pan") { $0.pan = value }
    case .sendLevel(let id):
      guard var send = track.channel.sends.first(where: { $0.id == id }) else { return }
      send.level = value
      perform(UpdateSend(send, on: track.id))
    case .plugin: break
    }
  }

  // MARK: - MIDI Learn

  /// Waits for the next MIDI controller moved, to assign it to a control.
  func beginMIDILearn(_ target: SmartControlTarget) {
    midiLearnTarget = target
    connectControllers()
  }

  func cancelMIDILearn() {
    midiLearnTarget = nil
    connectControllers()
  }

  /// Gives the MIDI router this window's controller assignments (and MIDI Learn). Called
  /// with `connectMIDIInput`, when the window comes to the front, and when they change.
  func connectControllers() {
    connectedControllerAssignments = project.controllerAssignments
    let assigned = Set(project.controllerAssignments.map { MIDIInputRouter.Controller(channel: $0.channel, number: $0.controller) })
    let isLearning = midiLearnTarget != nil
    guard !assigned.isEmpty || isLearning else {
      MIDIInputRouter.shared?.setControllerTap(assigned: [], isLearning: false, handler: nil)
      return
    }
    MIDIInputRouter.shared?.setControllerTap(assigned: assigned, isLearning: isLearning) { [weak self] controller, value in
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self?.controllerMoved(controller, to: value) }
      }
    }
  }

  /// A MIDI controller moved: MIDI Learn takes it, or its assigned control follows.
  func controllerMoved(_ controller: MIDIInputRouter.Controller, to value: Int) {
    if let target = midiLearnTarget {
      midiLearnTarget = nil
      perform(AssignController(ControllerAssignment(
        channel: controller.channel, controller: controller.number, trackID: target.trackID, parameter: target.parameter)))
      connectControllers()
      return
    }
    for assignment in project.controllerAssignments
    where assignment.channel == controller.channel && assignment.controller == controller.number {
      let target = SmartControlTarget(trackID: assignment.trackID, parameter: assignment.parameter)
      let controlValue = Self.controlValue(ofController: value, for: assignment.parameter)
      smartControlChanged(target, to: controlValue)
      // A controller has no "let go": store the control once it stops moving.
      controllerCommits[target]?.cancel()
      controllerCommits[target] = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, let self else { return }
        self.controllerCommits[target] = nil
        self.smartControlReleased(target, at: controlValue)
      }
    }
  }

  /// A controller's 0–127 across a control's range; for the fader and sends along the
  /// fader's scale, so the middle of a knob is near 0 dB as on the mixer.
  static func controlValue(ofController value: Int, for parameter: AutomationParameter) -> Double {
    let fraction = Double(min(max(value, 0), 127)) / 127
    switch parameter {
    case .volume, .sendLevel: return FaderScale.decibels(atPosition: fraction)
    case .pan, .plugin:
      let range = parameter.range
      return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }
  }
}
