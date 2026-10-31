//
//  AutomationCommands.swift
//  OngakuCore
//

import Foundation

extension Project {
  /// Edits a track's lane for a parameter, creating it if needed and removing it if it ends
  /// up empty.
  mutating func editAutomation(
    of trackID: Track.ID, _ parameter: AutomationParameter, _ edit: (inout AutomationLane) throws -> Void
  ) throws {
    let trackIndex = try requireTrackIndex(trackID)
    var lanes = tracks[trackIndex].automation
    let laneIndex = lanes.firstIndex { $0.parameter == parameter }
    var lane = laneIndex.map { lanes[$0] } ?? AutomationLane(parameter: parameter)
    try edit(&lane)
    switch (laneIndex, lane.points.isEmpty) {
    case (let index?, true): lanes.remove(at: index)
    case (let index?, false): lanes[index] = lane
    case (nil, false): lanes.append(lane)
    case (nil, true): break
    }
    tracks[trackIndex].automation = lanes
  }
}

/// Adds points to a lane (the lane is created for the first point).
public struct AddAutomationPoints: EditCommand {
  public var trackID: Track.ID
  public var parameter: AutomationParameter
  public var points: [AutomationPoint]

  public init(_ points: [AutomationPoint], to parameter: AutomationParameter, on trackID: Track.ID) {
    self.trackID = trackID
    self.parameter = parameter
    self.points = points
  }

  public var actionName: String { "Add Automation Point" }

  public func apply(to project: inout Project) throws {
    try project.editAutomation(of: trackID, parameter) { lane in
      for point in points where lane.points.contains(where: { $0.id == point.id }) {
        throw EditError.duplicateID(point.id)
      }
      lane.setPoints(lane.points + points)
    }
  }
}

/// Moves points to new positions and values, by ID.
public struct UpdateAutomationPoints: EditCommand {
  public var trackID: Track.ID
  public var parameter: AutomationParameter
  public var points: [AutomationPoint]

  public init(_ points: [AutomationPoint], in parameter: AutomationParameter, on trackID: Track.ID) {
    self.trackID = trackID
    self.parameter = parameter
    self.points = points
  }

  public var actionName: String { points.count == 1 ? "Move Automation Point" : "Move Automation Points" }

  public func apply(to project: inout Project) throws {
    try project.editAutomation(of: trackID, parameter) { lane in
      var updated = lane.points
      for point in points {
        guard let index = updated.firstIndex(where: { $0.id == point.id }) else {
          throw EditError.invalidValue("That automation point no longer exists.")
        }
        updated[index] = point
      }
      lane.setPoints(updated)
    }
  }
}

public struct DeleteAutomationPoints: EditCommand {
  public var trackID: Track.ID
  public var parameter: AutomationParameter
  public var pointIDs: Set<AutomationPoint.ID>

  public init(_ pointIDs: Set<AutomationPoint.ID>, from parameter: AutomationParameter, on trackID: Track.ID) {
    self.trackID = trackID
    self.parameter = parameter
    self.pointIDs = pointIDs
  }

  public var actionName: String { pointIDs.count == 1 ? "Delete Automation Point" : "Delete Automation Points" }

  public func apply(to project: inout Project) throws {
    try project.editAutomation(of: trackID, parameter) { lane in
      lane.setPoints(lane.points.filter { !pointIDs.contains($0.id) })
    }
  }
}

/// Records over part of a lane: what Touch and Latch write while a control is moved.
public struct WriteAutomation: EditCommand {
  public var trackID: Track.ID
  public var parameter: AutomationParameter
  public var points: [AutomationPoint]
  public var range: ClosedRange<Tick>

  public init(_ points: [AutomationPoint], over range: ClosedRange<Tick>, to parameter: AutomationParameter, on trackID: Track.ID) {
    self.trackID = trackID
    self.parameter = parameter
    self.points = points
    self.range = range
  }

  public var actionName: String { "Write \(parameter.name) Automation" }

  public func apply(to project: inout Project) throws {
    try project.editAutomation(of: trackID, parameter) { lane in
      lane.write(points, over: range)
    }
  }
}

public struct ClearAutomation: EditCommand {
  public var trackID: Track.ID
  public var parameter: AutomationParameter

  public init(_ parameter: AutomationParameter, on trackID: Track.ID) {
    self.trackID = trackID
    self.parameter = parameter
  }

  public var actionName: String { "Delete \(parameter.name) Automation" }

  public func apply(to project: inout Project) throws {
    try project.editAutomation(of: trackID, parameter) { lane in
      lane.setPoints([])
    }
  }
}

public struct SetAutomationMode: EditCommand {
  public var trackID: Track.ID
  public var mode: AutomationMode

  public init(_ mode: AutomationMode, for trackID: Track.ID) {
    self.trackID = trackID
    self.mode = mode
  }

  public var actionName: String { "Set Automation Mode" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    project.tracks[index].automationMode = mode
  }
}
