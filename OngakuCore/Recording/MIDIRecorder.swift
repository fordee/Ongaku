//
//  MIDIRecorder.swift
//  OngakuCore
//

import Foundation

/// Collects incoming MIDI during a recording and turns it into a region.
///
/// The engine feeds it events with their timeline positions as they arrive. Note-ons are
/// paired with the next note-off for the same channel and pitch (a note-on with velocity 0
/// counts as a note-off); notes still held when recording stops end at the stop position.
/// Controllers (such as the sustain pedal and mod wheel), pitch bend and aftertouch are kept
/// as they arrive.
public struct MIDIRecorder: Sendable {
  private struct HeldNote: Sendable {
    var start: Tick
    var velocity: Int
  }

  public private(set) var notes: [MIDINote] = []
  /// Positions are on the timeline, like the notes' until `makeRegion`.
  public private(set) var controls: [MIDIControlEvent] = []
  private var held: [Int: [HeldNote]] = [:]

  public init() {}

  public var isEmpty: Bool { notes.isEmpty && held.isEmpty && controls.isEmpty }

  /// Adds one MIDI 1.0 message heard at `position`. Program changes and system messages are
  /// ignored.
  public mutating func add(_ bytes: [UInt8], at position: Tick) {
    if let control = MIDIControlEvent.parse(bytes, at: position) {
      controls.append(control)
      return
    }
    guard bytes.count >= 3 else { return }
    let status = bytes[0] & 0xF0
    let channel = Int(bytes[0] & 0x0F)
    let pitch = Int(bytes[1] & 0x7F)
    let velocity = Int(bytes[2] & 0x7F)
    let key = channel << 8 | pitch

    if status == 0x90, velocity > 0 {
      held[key, default: []].append(HeldNote(start: position, velocity: velocity))
    } else if status == 0x80 || status == 0x90 {
      guard var starts = held[key], !starts.isEmpty else { return }
      let note = starts.removeFirst()
      held[key] = starts.isEmpty ? nil : starts
      notes.append(MIDINote(
        pitch: pitch, velocity: note.velocity, channel: channel,
        start: note.start, length: max(position - note.start, Tick(1))))
    }
  }

  /// Ends any held notes at `position`.
  public mutating func finish(at position: Tick) {
    for (key, starts) in held {
      for note in starts {
        notes.append(MIDINote(
          pitch: key & 0xFF, velocity: note.velocity, channel: key >> 8,
          start: note.start, length: max(position - note.start, Tick(1))))
      }
    }
    held = [:]
  }

  /// The recorded notes and controllers with positions counted from `start` (a cycle pass's
  /// take), or `nil` if nothing was played.
  public func makeSequence(relativeTo start: Tick) -> MIDISequence? {
    guard !notes.isEmpty || !controls.isEmpty else { return nil }
    return MIDISequence(
      notes: notes.map { var note = $0; note.start = note.start - start; return note },
      controls: controls.map { var event = $0; event.position = event.position - start; return event })
  }

  /// A region from the start of the bar where recording began to the end of the bar where
  /// it stopped (or where the last note ends), holding the recorded notes and controllers.
  /// `nil` if nothing was played.
  public func makeRegion(name: String, recordedFrom start: Tick, to stop: Tick, tempoMap: TempoMap) -> Region? {
    guard !notes.isEmpty || !controls.isEmpty else { return nil }
    let firstNote = (notes.map(\.start) + controls.map(\.position)).min() ?? start
    let lastEnd = max(notes.map(\.end).max() ?? stop, stop)
    let regionStart = tempoMap.bar(containing: max(.zero, min(start, firstNote))).start
    let lastBar = tempoMap.bar(containing: max(lastEnd - Tick(1), regionStart))
    let regionEnd = tempoMap.tickPosition(ofBarIndex: lastBar.index + 1)
    let relative = notes.map { note in
      var copy = note
      copy.start = note.start - regionStart
      return copy
    }
    let relativeControls = controls.map { control in
      var copy = control
      copy.position = control.position - regionStart
      return copy
    }
    return Region(
      name: name, start: regionStart, length: regionEnd - regionStart,
      content: .midi(MIDISequence(notes: relative, controls: relativeControls)))
  }
}
