//
//  Flex.swift
//  OngakuCore
//

import Foundation

/// How a track's flexed audio is stretched, as Logic's Flex modes.
public enum FlexMode: String, Codable, Sendable, CaseIterable {
  /// Cuts the audio at each marker and moves the slices without stretching them: transients
  /// stay perfect, and gaps are left silent. Best for drums.
  case slicing
  /// Time-stretches between markers, keeping the pitch. For rhythmic and polyphonic parts.
  case rhythmic
  /// Flex Pitch: the notes of monophonic audio (a voice, a solo instrument) can be retuned
  /// one by one; flex markers time-stretch as in Rhythmic.
  case pitch

  public var displayName: String {
    switch self {
    case .slicing: "Slicing"
    case .rhythmic: "Rhythmic"
    case .pitch: "Flex Pitch"
    }
  }
}

/// A flex marker: the moment `source` seconds into the region's audio (as recorded) plays
/// `target` seconds into the region.
public struct FlexMarker: Identifiable, Codable, Sendable, Equatable, Hashable {
  public var id: UUID
  public var source: Double
  public var target: Double

  public init(id: UUID = UUID(), source: Double, target: Double) {
    self.id = id
    self.source = source
    self.target = target
  }
}

/// The time map flex markers make across a region: piecewise straight lines from the
/// region's start (0 → 0) through each marker to its end (sourceDuration → duration), so
/// the audio between markers is stretched or squeezed to fit. `sourceDuration` is how much
/// of the recording the region plays: the same as `duration` unless the whole region is
/// time-stretched (Smart Tempo's Match Project Tempo).
public struct FlexMap: Sendable, Equatable {
  /// The closest two markers may come, in seconds, in either timeline.
  public static let minimumGap = 0.005

  /// Sorted, including the region's start and end.
  public let anchors: [(source: Double, target: Double)]
  public let duration: Double

  public static func == (lhs: FlexMap, rhs: FlexMap) -> Bool {
    lhs.duration == rhs.duration && lhs.anchors.elementsEqual(rhs.anchors) { $0.source == $1.source && $0.target == $1.target }
  }

  public init(markers: [FlexMarker], duration: Double, sourceDuration: Double? = nil) {
    self.duration = duration
    let sourceEnd = sourceDuration ?? duration
    let inside = markers
      .filter { $0.source > 0 && $0.source < sourceEnd && $0.target > 0 && $0.target < duration }
      .sorted { $0.source < $1.source }
    anchors = [(0, 0)] + inside.map { ($0.source, $0.target) } + [(sourceEnd, duration)]
  }

  /// Whether markers are in order in both timelines, apart by at least `minimumGap`.
  public static func isValid(_ markers: [FlexMarker], duration: Double, sourceDuration: Double? = nil) -> Bool {
    let sourceEnd = sourceDuration ?? duration
    let sorted = markers.sorted { $0.source < $1.source }
    var previous = (source: 0.0, target: 0.0)
    for marker in sorted {
      guard marker.source - previous.source >= minimumGap, marker.target - previous.target >= minimumGap else { return false }
      previous = (marker.source, marker.target)
    }
    return sourceEnd - previous.source >= minimumGap && duration - previous.target >= minimumGap
  }

  /// The segments between anchors: where each comes from and where it plays.
  public var segments: [(source: Range<Double>, target: Range<Double>)] {
    zip(anchors, anchors.dropFirst()).map { ($0.source..<$1.source, $0.target..<$1.target) }
  }

  /// The source time playing at a target time.
  public func sourceTime(atTarget target: Double) -> Double {
    if target >= duration, let end = anchors.last { return end.source }
    for segment in segments where segment.target.contains(target) {
      let fraction = (target - segment.target.lowerBound) / (segment.target.upperBound - segment.target.lowerBound)
      return segment.source.lowerBound + fraction * (segment.source.upperBound - segment.source.lowerBound)
    }
    return min(max(target, 0), anchors.last?.source ?? duration)
  }

  /// The target time a source time plays at.
  public func targetTime(atSource source: Double) -> Double {
    for segment in segments where segment.source.contains(source) {
      let fraction = (source - segment.source.lowerBound) / (segment.source.upperBound - segment.source.lowerBound)
      return segment.target.lowerBound + fraction * (segment.target.upperBound - segment.target.lowerBound)
    }
    return min(max(source, 0), duration)
  }
}
