//
//  Automation.swift
//  OngakuCore
//

import Foundation

/// A channel-strip control that can change over time: the fader, pan, a send's level or a
/// plug-in parameter.
public enum AutomationParameter: Hashable, Codable, Sendable {
  /// The fader, in decibels.
  case volume
  /// Pan, from -1 (left) to 1 (right).
  case pan
  /// A send's level, in decibels.
  case sendLevel(Send.ID)
  /// An insert's parameter, from 0 to 1 across its range.
  case plugin(PluginParameter)

  /// The fader and pan, which every channel strip has.
  public static let channelParameters: [AutomationParameter] = [.volume, .pan]

  public var name: String {
    switch self {
    case .volume: "Volume"
    case .pan: "Pan"
    case .sendLevel: "Send Level"
    case .plugin(let parameter): parameter.name
    }
  }

  public var range: ClosedRange<Double> {
    switch self {
    case .volume: ChannelStrip.volumeRange
    case .pan: ChannelStrip.panRange
    case .sendLevel: Send.levelRange
    case .plugin: 0...1
    }
  }

  /// Whether values are decibels (shown and drawn like a fader).
  public var isDecibels: Bool {
    switch self {
    case .volume, .sendLevel: true
    case .pan, .plugin: false
    }
  }

  /// The control's static setting on a channel strip, used when there's no automation. A
  /// plug-in parameter's is where it was when its automation lane was made.
  public func value(in channel: ChannelStrip) -> Double {
    switch self {
    case .volume: channel.volume
    case .pan: channel.pan
    case .sendLevel(let id): channel.sends.first { $0.id == id }?.level ?? Send.levelRange.lowerBound
    case .plugin(let parameter): parameter.initialValue
    }
  }

  public func clamp(_ value: Double) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
  }

  // Volume and pan are stored as plain strings, as before sends and plug-ins could be
  // automated; the others as objects.
  private enum CodingKeys: String, CodingKey {
    case send, plugin
  }

  public init(from decoder: any Decoder) throws {
    if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
      switch name {
      case "volume": self = .volume
      case "pan": self = .pan
      default:
        throw DecodingError.dataCorruptedError(in: single, debugDescription: "Unknown automation parameter \(name)")
      }
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let send = try container.decodeIfPresent(Send.ID.self, forKey: .send) {
      self = .sendLevel(send)
    } else {
      self = .plugin(try container.decode(PluginParameter.self, forKey: .plugin))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .volume:
      var single = encoder.singleValueContainer()
      try single.encode("volume")
    case .pan:
      var single = encoder.singleValueContainer()
      try single.encode("pan")
    case .sendLevel(let id):
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(id, forKey: .send)
    case .plugin(let parameter):
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(parameter, forKey: .plugin)
    }
  }
}

/// A parameter of a plug-in on a channel strip. Two are the same parameter when they're on
/// the same plug-in at the same address; the name and initial value just describe it.
public struct PluginParameter: Hashable, Codable, Sendable {
  /// The insert's `PluginReference.ID`.
  public var pluginID: PluginReference.ID
  /// The Audio Unit parameter address.
  public var address: UInt64
  /// For lane menus, such as "Mix" or "Cutoff Frequency".
  public var name: String
  /// Where the parameter was (0…1) when its lane was made: its value without automation.
  public var initialValue: Double

  public init(pluginID: PluginReference.ID, address: UInt64, name: String, initialValue: Double = 0.5) {
    self.pluginID = pluginID
    self.address = address
    self.name = name
    self.initialValue = initialValue
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.pluginID == rhs.pluginID && lhs.address == rhs.address
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(pluginID)
    hasher.combine(address)
  }
}

/// How a track uses its automation, as in Logic:
/// - Off: automation is ignored and the controls stay where they're set.
/// - Read: the controls follow the automation.
/// - Touch: like Read, but moving a control during playback records over the automation
///   until you let go, when it returns to the existing curve.
/// - Latch: like Touch, but after you let go the last value keeps being written until
///   playback stops.
public enum AutomationMode: String, Codable, Sendable, CaseIterable {
  case off, read, touch, latch

  public var name: String { rawValue.capitalized }

  /// Whether playback follows the automation.
  public var plays: Bool { self != .off }

  /// Whether moving a control during playback records automation.
  public var writes: Bool { self == .touch || self == .latch }
}

public struct AutomationPoint: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  public var position: Tick
  /// In the parameter's units (decibels for volume).
  public var value: Double

  public init(id: UUID = UUID(), position: Tick, value: Double) {
    self.id = id
    self.position = position
    self.value = value
  }
}

/// One parameter's automation: points joined by straight lines. Before the first point the
/// value is the first point's, and after the last it's the last point's.
public struct AutomationLane: Codable, Sendable, Equatable {
  public var parameter: AutomationParameter
  /// Sorted by position.
  public private(set) var points: [AutomationPoint]

  public init(parameter: AutomationParameter, points: [AutomationPoint] = []) {
    self.parameter = parameter
    self.points = []
    setPoints(points)
  }

  /// Replaces the points, clamping values and sorting by position.
  public mutating func setPoints(_ newPoints: [AutomationPoint]) {
    points = newPoints.map { point in
      var point = point
      point.position = max(.zero, point.position)
      point.value = parameter.clamp(point.value)
      return point
    }
    // A stable sort, so points added at the same position keep their order (a step).
    points = points.enumerated().sorted { ($0.element.position, $0.offset) < ($1.element.position, $1.offset) }.map(\.element)
  }

  /// The value at a position, or `nil` when the lane has no points.
  public func value(at position: Tick) -> Double? {
    guard let first = points.first, let last = points.last else { return nil }
    if position <= first.position { return first.value }
    if position >= last.position { return last.value }
    // The last point at or before the position, then the next one.
    let index = firstIndex(after: position) - 1
    let before = points[index]
    let after = points[index + 1]
    let span = Double((after.position - before.position).rawValue)
    guard span > 0 else { return after.value }
    let fraction = Double((position - before.position).rawValue) / span
    return before.value + (after.value - before.value) * fraction
  }

  /// The positions where the line changes direction inside `range`, plus its ends: what a
  /// player needs to reproduce the curve there with straight ramps.
  public func breakpoints(in range: Range<Tick>) -> [Tick] {
    var positions = [range.lowerBound]
    var index = firstIndex(after: range.lowerBound)
    while index < points.count, points[index].position < range.upperBound {
      positions.append(points[index].position)
      index += 1
    }
    positions.append(range.upperBound)
    return positions
  }

  /// The index of the first point after `position`, by binary search (points are sorted).
  private func firstIndex(after position: Tick) -> Int {
    var low = 0
    var high = points.count
    while low < high {
      let middle = (low + high) / 2
      if points[middle].position <= position {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return low
  }

  /// Replaces the points inside `range` with `newPoints`, keeping the curve unchanged on
  /// either side: the values at the range's edges are pinned with points just outside the
  /// written ones, so the curve returns to what it was. This is how writing automation
  /// (Touch and Latch) records over an existing curve.
  public mutating func write(_ newPoints: [AutomationPoint], over range: ClosedRange<Tick>) {
    let edgeBefore = value(at: range.lowerBound)
    let edgeAfter = value(at: range.upperBound)
    var kept = points.filter { !range.contains($0.position) }
    if let edgeBefore, range.lowerBound > .zero, kept.contains(where: { $0.position < range.lowerBound }) {
      kept.append(AutomationPoint(position: range.lowerBound, value: edgeBefore))
    }
    if let edgeAfter, kept.contains(where: { $0.position > range.upperBound }) {
      kept.append(AutomationPoint(position: range.upperBound + Tick(1), value: edgeAfter))
    }
    setPoints(kept + newPoints)
  }

  /// Fewer points describing nearly the same line: drops points that lie within
  /// `tolerance` (in parameter units) of the straight line between their neighbours
  /// (Ramer–Douglas–Peucker). Recording a fader move produces a point per screen update;
  /// this keeps only the shape.
  public static func thinned(_ points: [AutomationPoint], tolerance: Double) -> [AutomationPoint] {
    guard points.count > 2 else { return points }
    var keep = [Bool](repeating: false, count: points.count)
    keep[0] = true
    keep[points.count - 1] = true
    var stack = [(0, points.count - 1)]
    while let (start, end) = stack.popLast() {
      guard end > start + 1 else { continue }
      let a = points[start]
      let b = points[end]
      let span = Double((b.position - a.position).rawValue)
      var farthest = start
      var distance = 0.0
      for index in (start + 1)..<end {
        let point = points[index]
        let fraction = span > 0 ? Double((point.position - a.position).rawValue) / span : 0
        let lineValue = a.value + (b.value - a.value) * fraction
        let offset = abs(point.value - lineValue)
        if offset > distance {
          distance = offset
          farthest = index
        }
      }
      if distance > tolerance {
        keep[farthest] = true
        stack.append((start, farthest))
        stack.append((farthest, end))
      }
    }
    return points.indices.filter { keep[$0] }.map { points[$0] }
  }
}

extension Track {
  /// The parameters with automation lanes, plus the fader and pan.
  public var automatedParameters: [AutomationParameter] {
    var parameters = AutomationParameter.channelParameters
    for lane in automation where !parameters.contains(lane.parameter) {
      parameters.append(lane.parameter)
    }
    return parameters
  }

  /// The sends whose level is automated (and played).
  public var automatedSends: Set<Send.ID> {
    Set(automation.compactMap { lane in
      if case .sendLevel(let id) = lane.parameter, isAutomated(lane.parameter) { id } else { nil }
    })
  }

  public func automationLane(for parameter: AutomationParameter) -> AutomationLane? {
    automation.first { $0.parameter == parameter }
  }

  /// The parameter's value at a position: the automation when the mode plays it and the
  /// lane has points, otherwise the channel strip's setting.
  public func automatedValue(of parameter: AutomationParameter, at position: Tick) -> Double {
    if automationMode.plays, let value = automationLane(for: parameter)?.value(at: position) {
      return value
    }
    return parameter.value(in: channel)
  }

  /// Whether playback follows automation for this parameter.
  public func isAutomated(_ parameter: AutomationParameter) -> Bool {
    automationMode.plays && !(automationLane(for: parameter)?.points.isEmpty ?? true)
  }
}

extension Project {
  /// Drops automation lanes for sends and plug-ins that are no longer on their channel strip.
  /// `ProjectEditor` does this after every command, so removing a send or an insert takes its
  /// automation with it (and undo brings both back).
  mutating func removeOrphanedAutomation() {
    for index in tracks.indices {
      let channel = tracks[index].channel
      let sendIDs = Set(channel.sends.map(\.id))
      let pluginIDs = Set(channel.inserts.map(\.id))
      tracks[index].automation.removeAll { lane in
        switch lane.parameter {
        case .volume, .pan: false
        case .sendLevel(let id): !sendIDs.contains(id)
        case .plugin(let parameter): !pluginIDs.contains(parameter.pluginID)
        }
      }
    }
  }
}
