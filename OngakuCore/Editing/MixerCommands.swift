//
//  MixerCommands.swift
//  OngakuCore
//

import Foundation

// MARK: - Inserts

// The insert commands take a track's ID, or `Project.stereoOutID` for Stereo Out.

public struct AddInsert: EditCommand {
  public var trackID: Track.ID
  public var plugin: PluginReference
  /// The slot to insert at; `nil` appends.
  public var index: Int?

  public init(_ plugin: PluginReference, to trackID: Track.ID, at index: Int? = nil) {
    self.trackID = trackID
    self.plugin = plugin
    self.index = index
  }

  public var actionName: String { "Add \(plugin.name)" }

  public func apply(to project: inout Project) throws {
    try project.modifyInserts(of: trackID) { inserts in
      guard inserts.count < ChannelStrip.maximumInserts else {
        throw EditError.invalidValue("A channel strip has at most \(ChannelStrip.maximumInserts) inserts.")
      }
      guard !inserts.contains(where: { $0.id == plugin.id }) else { throw EditError.duplicateID(plugin.id) }
      inserts.insert(plugin, at: min(max(index ?? inserts.count, 0), inserts.count))
    }
  }
}

public struct RemoveInsert: EditCommand {
  public var trackID: Track.ID
  public var pluginID: PluginReference.ID

  public init(_ pluginID: PluginReference.ID, from trackID: Track.ID) {
    self.trackID = trackID
    self.pluginID = pluginID
  }

  public var actionName: String { "Remove Plug-in" }

  public func apply(to project: inout Project) throws {
    try project.modifyInserts(of: trackID) { inserts in
      let before = inserts.count
      inserts.removeAll { $0.id == pluginID }
      guard inserts.count < before else {
        throw EditError.invalidValue("That plug-in isn’t on this channel strip.")
      }
    }
  }
}

public struct MoveInsert: EditCommand {
  public var trackID: Track.ID
  public var pluginID: PluginReference.ID
  public var destinationIndex: Int

  public init(_ pluginID: PluginReference.ID, in trackID: Track.ID, to destinationIndex: Int) {
    self.trackID = trackID
    self.pluginID = pluginID
    self.destinationIndex = destinationIndex
  }

  public var actionName: String { "Move Plug-in" }

  public func apply(to project: inout Project) throws {
    try project.modifyInserts(of: trackID) { inserts in
      guard let index = inserts.firstIndex(where: { $0.id == pluginID }) else {
        throw EditError.invalidValue("That plug-in isn’t on this channel strip.")
      }
      let plugin = inserts.remove(at: index)
      inserts.insert(plugin, at: min(max(destinationIndex, 0), inserts.count))
    }
  }
}

public struct SetInsertBypassed: EditCommand {
  public var trackID: Track.ID
  public var pluginID: PluginReference.ID
  public var isBypassed: Bool

  public init(_ pluginID: PluginReference.ID, in trackID: Track.ID, isBypassed: Bool) {
    self.trackID = trackID
    self.pluginID = pluginID
    self.isBypassed = isBypassed
  }

  public var actionName: String { isBypassed ? "Bypass Plug-in" : "Enable Plug-in" }

  public func apply(to project: inout Project) throws {
    try project.modifyInserts(of: trackID) { inserts in
      guard let index = inserts.firstIndex(where: { $0.id == pluginID }) else {
        throw EditError.invalidValue("That plug-in isn’t on this channel strip.")
      }
      inserts[index].isBypassed = isBypassed
    }
  }
}

/// Stores a plug-in's settings (an insert or the track's instrument) after the person
/// changed them in the plug-in's interface.
public struct SetPluginState: EditCommand {
  public var trackID: Track.ID
  public var pluginID: PluginReference.ID
  public var state: Data?

  public init(_ state: Data?, forPlugin pluginID: PluginReference.ID, on trackID: Track.ID) {
    self.trackID = trackID
    self.pluginID = pluginID
    self.state = state
  }

  public var actionName: String { "Plug-in Settings" }

  public func apply(to project: inout Project) throws {
    if trackID == Project.stereoOutID {
      try project.modifyInserts(of: trackID) { inserts in
        guard let index = inserts.firstIndex(where: { $0.id == pluginID }) else {
          throw EditError.invalidValue("That plug-in isn’t on this channel strip.")
        }
        inserts[index].state = state
      }
      return
    }
    let trackIndex = try project.requireTrackIndex(trackID)
    var channel = project.tracks[trackIndex].channel
    if case .audioUnit(var instrument) = channel.instrument, instrument.id == pluginID {
      instrument.state = state
      channel.instrument = .audioUnit(instrument)
    } else if let index = channel.inserts.firstIndex(where: { $0.id == pluginID }) {
      channel.inserts[index].state = state
    } else {
      throw EditError.invalidValue("That plug-in isn’t on this channel strip.")
    }
    project.tracks[trackIndex].channel = channel
  }
}

// MARK: - Sends

public struct AddSend: EditCommand {
  public var trackID: Track.ID
  public var send: Send

  public init(_ send: Send, from trackID: Track.ID) {
    self.trackID = trackID
    self.send = send
  }

  public var actionName: String { "Add Send" }

  public func apply(to project: inout Project) throws {
    let trackIndex = try project.requireTrackIndex(trackID)
    try validateSend(send, from: trackID, in: project)
    guard !project.tracks[trackIndex].channel.sends.contains(where: { $0.destinationTrackID == send.destinationTrackID })
    else {
      throw EditError.invalidValue("This track already sends to that aux.")
    }
    var clamped = send
    clamped.level = min(max(send.level, Send.levelRange.lowerBound), Send.levelRange.upperBound)
    project.tracks[trackIndex].channel.sends.append(clamped)
  }
}

/// Changes a send's level, pre/post setting or destination.
public struct UpdateSend: EditCommand {
  public var trackID: Track.ID
  public var send: Send

  public init(_ send: Send, on trackID: Track.ID) {
    self.trackID = trackID
    self.send = send
  }

  public var actionName: String { "Send Level" }

  public func apply(to project: inout Project) throws {
    let trackIndex = try project.requireTrackIndex(trackID)
    guard let index = project.tracks[trackIndex].channel.sends.firstIndex(where: { $0.id == send.id }) else {
      throw EditError.invalidValue("That send no longer exists.")
    }
    try validateSend(send, from: trackID, in: project)
    var clamped = send
    clamped.level = min(max(send.level, Send.levelRange.lowerBound), Send.levelRange.upperBound)
    project.tracks[trackIndex].channel.sends[index] = clamped
  }
}

public struct RemoveSend: EditCommand {
  public var trackID: Track.ID
  public var sendID: Send.ID

  public init(_ sendID: Send.ID, from trackID: Track.ID) {
    self.trackID = trackID
    self.sendID = sendID
  }

  public var actionName: String { "Remove Send" }

  public func apply(to project: inout Project) throws {
    let trackIndex = try project.requireTrackIndex(trackID)
    project.tracks[trackIndex].channel.sends.removeAll { $0.id == sendID }
  }
}

/// Sends must go to an aux track and must not loop back to the sending track.
func validateSend(_ send: Send, from trackID: Track.ID, in project: Project) throws {
  guard let destination = project.track(withID: send.destinationTrackID) else {
    throw EditError.trackNotFound(send.destinationTrackID)
  }
  guard destination.kind == .aux else {
    throw EditError.invalidValue("Sends can only go to aux tracks.")
  }
  guard project.track(withID: trackID)?.channel.output != .track(send.destinationTrackID) else {
    throw EditError.invalidValue("This track already outputs to “\(destination.name)”.")
  }
  // Ignore this track's existing send to the same destination when checking for loops.
  var withoutSend = project
  if let index = withoutSend.trackIndex(for: trackID) {
    withoutSend.tracks[index].channel.sends.removeAll { $0.id == send.id }
  }
  guard !withoutSend.sendWouldCreateFeedback(from: trackID, to: send.destinationTrackID) else {
    throw EditError.invalidValue("That send would feed “\(destination.name)” back into itself.")
  }
}

// MARK: - Master, recording and inputs

public struct SetMasterVolume: EditCommand {
  public var volume: Double

  public init(_ volume: Double) {
    self.volume = volume
  }

  public var actionName: String { "Stereo Out Volume" }

  public func apply(to project: inout Project) throws {
    project.masterVolume = min(max(volume, ChannelStrip.volumeRange.lowerBound), ChannelStrip.volumeRange.upperBound)
  }
}

public struct SetRecordArmed: EditCommand {
  public var trackID: Track.ID
  public var isArmed: Bool

  public init(_ trackID: Track.ID, isArmed: Bool) {
    self.trackID = trackID
    self.isArmed = isArmed
  }

  public var actionName: String { isArmed ? "Record Enable" : "Record Disable" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    guard project.tracks[index].kind.canRecord else {
      throw EditError.invalidValue("Aux tracks can’t record.")
    }
    project.tracks[index].isRecordArmed = isArmed
  }
}

/// Turns an audio track's input monitoring on or off.
public struct SetInputMonitoring: EditCommand {
  public var trackID: Track.ID
  public var isMonitored: Bool

  public init(_ trackID: Track.ID, isMonitored: Bool) {
    self.trackID = trackID
    self.isMonitored = isMonitored
  }

  public var actionName: String { isMonitored ? "Input Monitoring On" : "Input Monitoring Off" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    guard project.tracks[index].kind == .audio else {
      throw EditError.invalidValue("Only audio tracks have an input to monitor.")
    }
    project.tracks[index].isInputMonitored = isMonitored
  }
}

public struct SetAudioInput: EditCommand {
  public var trackID: Track.ID
  public var input: AudioInputSelection

  public init(_ input: AudioInputSelection, for trackID: Track.ID) {
    self.trackID = trackID
    self.input = input
  }

  public var actionName: String { "Change Input" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    guard project.tracks[index].kind == .audio else {
      throw EditError.trackKindMismatch(expected: .audio, found: project.tracks[index].kind)
    }
    project.tracks[index].channel.audioInput = input
  }
}

// MARK: - MIDI effects

/// Adds a MIDI effect to an instrument track's MIDI FX slots.
public struct AddMIDIEffect: EditCommand {
  public var trackID: Track.ID
  public var effect: MIDIEffect
  /// The slot to put it in; `nil` adds it last.
  public var index: Int?

  public init(_ effect: MIDIEffect, to trackID: Track.ID, at index: Int? = nil) {
    self.trackID = trackID
    self.effect = effect
    self.index = index
  }

  public var actionName: String { "Add \(effect.name)" }

  public func apply(to project: inout Project) throws {
    let trackIndex = try project.requireTrackIndex(trackID)
    guard project.tracks[trackIndex].kind == .softwareInstrument else {
      throw EditError.trackKindMismatch(expected: .softwareInstrument, found: project.tracks[trackIndex].kind)
    }
    var effects = project.tracks[trackIndex].channel.midiEffects
    guard effects.count < MIDIEffect.maximumCount else {
      throw EditError.invalidValue("A channel strip has at most \(MIDIEffect.maximumCount) MIDI effects.")
    }
    guard !effects.contains(where: { $0.id == effect.id }) else { throw EditError.duplicateID(effect.id) }
    effects.insert(effect, at: min(max(index ?? effects.count, 0), effects.count))
    project.tracks[trackIndex].channel.midiEffects = effects
  }
}

public struct RemoveMIDIEffect: EditCommand {
  public var trackID: Track.ID
  public var effectID: MIDIEffect.ID

  public init(_ effectID: MIDIEffect.ID, from trackID: Track.ID) {
    self.trackID = trackID
    self.effectID = effectID
  }

  public var actionName: String { "Remove MIDI Effect" }

  public func apply(to project: inout Project) throws {
    let trackIndex = try project.requireTrackIndex(trackID)
    guard project.tracks[trackIndex].channel.midiEffects.contains(where: { $0.id == effectID }) else {
      throw EditError.invalidValue("That MIDI effect isn’t on this channel strip.")
    }
    project.tracks[trackIndex].channel.midiEffects.removeAll { $0.id == effectID }
  }
}

/// Replaces a MIDI effect's settings or bypass (matched by identifier).
public struct UpdateMIDIEffect: EditCommand {
  public var trackID: Track.ID
  public var effect: MIDIEffect
  public var actionName: String

  public init(_ effect: MIDIEffect, in trackID: Track.ID, actionName: String? = nil) {
    self.trackID = trackID
    self.effect = effect
    self.actionName = actionName ?? "Change \(effect.name)"
  }

  public func apply(to project: inout Project) throws {
    let trackIndex = try project.requireTrackIndex(trackID)
    guard let index = project.tracks[trackIndex].channel.midiEffects.firstIndex(where: { $0.id == effect.id }) else {
      throw EditError.invalidValue("That MIDI effect isn’t on this channel strip.")
    }
    project.tracks[trackIndex].channel.midiEffects[index] = effect
  }
}

public struct MoveMIDIEffect: EditCommand {
  public var trackID: Track.ID
  public var effectID: MIDIEffect.ID
  public var destinationIndex: Int

  public init(_ effectID: MIDIEffect.ID, in trackID: Track.ID, to destinationIndex: Int) {
    self.trackID = trackID
    self.effectID = effectID
    self.destinationIndex = destinationIndex
  }

  public var actionName: String { "Move MIDI Effect" }

  public func apply(to project: inout Project) throws {
    let trackIndex = try project.requireTrackIndex(trackID)
    var effects = project.tracks[trackIndex].channel.midiEffects
    guard let index = effects.firstIndex(where: { $0.id == effectID }) else {
      throw EditError.invalidValue("That MIDI effect isn’t on this channel strip.")
    }
    let effect = effects.remove(at: index)
    effects.insert(effect, at: min(max(destinationIndex, 0), effects.count))
    project.tracks[trackIndex].channel.midiEffects = effects
  }
}
