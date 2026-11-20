//
//  SmartControls.swift
//  OngakuCore
//

import Foundation

/// One of a track's Smart Controls, as in Logic: a knob on the Smart Controls panel that
/// plays one of the track's controls (a plug-in parameter, the fader, pan or a send).
public struct SmartControl: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  public var parameter: AutomationParameter

  public init(id: UUID = UUID(), parameter: AutomationParameter) {
    self.id = id
    self.parameter = parameter
  }

  /// How many knobs the panel has.
  public static let count = 8
}

/// Logic's controller assignment, made with MIDI Learn: a knob, fader or wheel on a MIDI
/// controller (a control change number on a channel) that moves one track's control.
public struct ControllerAssignment: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  /// 0–15.
  public var channel: Int
  /// The control change number, 0–127.
  public var controller: Int
  public var trackID: Track.ID
  public var parameter: AutomationParameter

  public init(id: UUID = UUID(), channel: Int, controller: Int, trackID: Track.ID, parameter: AutomationParameter) {
    self.id = id
    self.channel = channel
    self.controller = controller
    self.trackID = trackID
    self.parameter = parameter
  }

  /// "CC 74, channel 1".
  public var description: String { "CC \(controller), channel \(channel + 1)" }
}

extension ChannelStrip {
  /// Whether the strip still has a control (its send or plug-in hasn't been removed).
  public func has(_ parameter: AutomationParameter) -> Bool {
    switch parameter {
    case .volume, .pan: true
    case .sendLevel(let id): sends.contains { $0.id == id }
    case .plugin(let parameter): plugins.contains { $0.id == parameter.pluginID }
    }
  }
}

extension Project {
  /// The controller assignment for a track's control, if it has one.
  public func controllerAssignment(for parameter: AutomationParameter, on trackID: Track.ID) -> ControllerAssignment? {
    controllerAssignments.first { $0.trackID == trackID && $0.parameter == parameter }
  }

  /// Smart Controls and controller assignments for controls that are gone (a plug-in or send
  /// removed, a track deleted) go too. Run after every edit, with orphaned automation.
  mutating func removeOrphanedControls() {
    for index in tracks.indices {
      let channel = tracks[index].channel
      tracks[index].smartControls.removeAll { !channel.has($0.parameter) }
    }
    let tracks = tracks
    controllerAssignments.removeAll { assignment in
      tracks.first { $0.id == assignment.trackID }.map { !$0.channel.has(assignment.parameter) } ?? true
    }
  }
}

/// Sets a track's Smart Controls: the controls its knobs play, in order (at most
/// `SmartControl.count`; none goes back to the panel's suggestions).
public struct SetSmartControls: EditCommand {
  public var trackID: Track.ID
  public var parameters: [AutomationParameter]

  public init(_ parameters: [AutomationParameter], on trackID: Track.ID) {
    self.trackID = trackID
    self.parameters = parameters
  }

  public var actionName: String { "Map Smart Controls" }

  public func apply(to project: inout Project) throws {
    let trackIndex = try project.requireTrackIndex(trackID)
    let track = project.tracks[trackIndex]
    guard parameters.count <= SmartControl.count else { throw EditError.invalidValue("There are \(SmartControl.count) Smart Controls.") }
    for parameter in parameters where !track.channel.has(parameter) {
      throw EditError.invalidValue("“\(track.name)” doesn’t have “\(parameter.name)”.")
    }
    // Knobs that stay keep their identity.
    project.tracks[trackIndex].smartControls = parameters.map { parameter in
      track.smartControls.first { $0.parameter == parameter } ?? SmartControl(parameter: parameter)
    }
  }
}

/// Assigns a MIDI controller to a control (MIDI Learn), replacing whatever else that
/// controller, or that control, had.
public struct AssignController: EditCommand {
  public var assignment: ControllerAssignment

  public init(_ assignment: ControllerAssignment) {
    self.assignment = assignment
  }

  public var actionName: String { "Learn MIDI Controller" }

  public func apply(to project: inout Project) throws {
    guard (0...15).contains(assignment.channel), (0...127).contains(assignment.controller) else {
      throw EditError.invalidValue("That isn’t a MIDI controller.")
    }
    let track = try project.tracks[project.requireTrackIndex(assignment.trackID)]
    guard track.channel.has(assignment.parameter) else { throw EditError.invalidValue("“\(track.name)” doesn’t have that control.") }
    project.controllerAssignments.removeAll { other in
      (other.channel == assignment.channel && other.controller == assignment.controller)
        || (other.trackID == assignment.trackID && other.parameter == assignment.parameter)
    }
    project.controllerAssignments.append(assignment)
  }
}

/// Forgets a controller assignment.
public struct RemoveControllerAssignment: EditCommand {
  public var assignmentID: ControllerAssignment.ID

  public init(_ assignmentID: ControllerAssignment.ID) {
    self.assignmentID = assignmentID
  }

  public var actionName: String { "Forget MIDI Controller" }

  public func apply(to project: inout Project) throws {
    project.controllerAssignments.removeAll { $0.id == assignmentID }
  }
}
