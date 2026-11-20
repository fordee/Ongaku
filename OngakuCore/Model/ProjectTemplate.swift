//
//  ProjectTemplate.swift
//  OngakuCore
//

import Foundation

extension Project {
  /// The project as a template to start new songs from, as Logic's Save as Template: its
  /// setup without its music. Tracks keep their instruments, plug-ins (with their settings),
  /// sends, outputs, stacks, groups, VCAs, Smart Controls and controller assignments; tempo,
  /// time signature, key and cycle stay. Regions, recordings, automation, freeze files,
  /// markers, sections and chords go.
  public func template() -> Project {
    var template = Project(
      sampleRate: sampleRate, tempoMap: tempoMap, keySignature: keySignature, cycle: cycle, tracks: tracks)
    for index in template.tracks.indices {
      template.tracks[index].regions = []
      template.tracks[index].automation = []
      template.tracks[index].freezeFile = nil
      template.tracks[index].isRecordArmed = false
    }
    template.isMetronomeEnabled = isMetronomeEnabled
    template.punch = punch
    template.isReplaceRecording = isReplaceRecording
    template.masterVolume = masterVolume
    template.stereoOutInserts = stereoOutInserts
    template.groups = groups
    template.vcas = vcas
    template.controllerAssignments = controllerAssignments
    return template
  }

  /// A new song from a template: the same setup with new identities for its tracks,
  /// plug-ins and sends, so two songs made from one template never share them.
  public func fromTemplate() -> Project {
    var project = self
    var trackIDs: [Track.ID: Track.ID] = [:]
    for track in tracks { trackIDs[track.id] = UUID() }
    var pluginIDs: [PluginReference.ID: PluginReference.ID] = [:]
    var sendIDs: [Send.ID: Send.ID] = [:]
    func newPlugin(_ plugin: PluginReference) -> PluginReference {
      var plugin = plugin
      let id = UUID()
      pluginIDs[plugin.id] = id
      plugin.id = id
      plugin.sidechainSourceID = plugin.sidechainSourceID.flatMap { trackIDs[$0] }
      return plugin
    }
    for index in project.tracks.indices {
      var track = project.tracks[index]
      track.id = trackIDs[track.id] ?? UUID()
      track.stackID = track.stackID.flatMap { trackIDs[$0] }
      if case .track(let destination) = track.channel.output, let id = trackIDs[destination] { track.channel.output = .track(id) }
      track.channel.inserts = track.channel.inserts.map(newPlugin)
      if case .audioUnit(let instrument) = track.channel.instrument { track.channel.instrument = .audioUnit(newPlugin(instrument)) }
      for effect in track.channel.midiEffects.indices {
        if case .audioUnit(let plugin) = track.channel.midiEffects[effect].settings {
          track.channel.midiEffects[effect].settings = .audioUnit(newPlugin(plugin))
        }
      }
      track.channel.sends = track.channel.sends.map { send in
        var send = send
        let id = UUID()
        sendIDs[send.id] = id
        send.id = id
        send.destinationTrackID = trackIDs[send.destinationTrackID] ?? send.destinationTrackID
        return send
      }
      project.tracks[index] = track
    }
    func moved(_ parameter: AutomationParameter) -> AutomationParameter? {
      switch parameter {
      case .volume, .pan: parameter
      case .sendLevel(let id): sendIDs[id].map(AutomationParameter.sendLevel)
      case .plugin(var plugin):
        pluginIDs[plugin.pluginID].map { id in
          plugin.pluginID = id
          return .plugin(plugin)
        }
      }
    }
    for index in project.tracks.indices {
      project.tracks[index].smartControls = project.tracks[index].smartControls.compactMap { control in
        moved(control.parameter).map { SmartControl(parameter: $0) }
      }
    }
    project.stereoOutInserts = stereoOutInserts.map(newPlugin)
    project.controllerAssignments = controllerAssignments.compactMap { assignment in
      guard let trackID = trackIDs[assignment.trackID], let parameter = moved(assignment.parameter) else { return nil }
      return ControllerAssignment(channel: assignment.channel, controller: assignment.controller, trackID: trackID, parameter: parameter)
    }
    return project
  }
}
