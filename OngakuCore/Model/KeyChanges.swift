//
//  KeyChanges.swift
//  OngakuCore
//

import Foundation

/// A change of key partway through the song, shown on the Signature track beside the time
/// signatures, as in Logic. The key at the start is the project's `keySignature`.
///
/// A key change doesn't transpose anything: it's what the song is in from there on, for the
/// Chord track's suggestions and progressions, and for the session players where there are
/// no chords.
public struct KeyChange: Identifiable, Codable, Sendable, Equatable {
  public var id: UUID
  /// Where the new key starts (after the start of the song).
  public var position: Tick
  public var key: KeySignature

  public init(id: UUID = UUID(), position: Tick, key: KeySignature) {
    self.id = id
    self.position = position
    self.key = key
  }
}

extension Project {
  /// The key in effect at `position`.
  public func key(at position: Tick) -> KeySignature {
    keyChanges.last { $0.position <= position }?.key ?? keySignature
  }

  /// Where the key in effect at `position` starts: the song's start, or a key change.
  public func keyStart(at position: Tick) -> Tick {
    keyChanges.last { $0.position <= position }?.position ?? .zero
  }

  /// The key at the start and every change after it, in order.
  public var keyTimeline: [(position: Tick, key: KeySignature)] {
    [(Tick.zero, keySignature)] + keyChanges.map { ($0.position, $0.key) }
  }

  mutating func sortKeyChanges() {
    keyChanges.sort { $0.position < $1.position }
  }
}

extension KeySignature {
  /// The key a MIDI file's key signature names: sharps (positive) or flats (negative) and
  /// major or minor.
  public init(sharpsOrFlats: Int, isMinor: Bool) {
    let major = ((sharpsOrFlats * 7) % 12 + 12) % 12
    self.init(tonic: isMinor ? major + 9 : major, mode: isMinor ? .minor : .major)
  }

  /// Sharps (positive) or flats (negative) in the key signature, as MIDI files store it:
  /// the fewest that spell the key (F♯ major is six sharps).
  public var sharpsOrFlats: Int {
    let major = mode == .minor ? (tonic + 3) % 12 : tonic
    return (-5...6).first { (($0 * 7) % 12 + 12) % 12 == major } ?? 0
  }
}
