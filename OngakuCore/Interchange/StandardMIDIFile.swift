//
//  StandardMIDIFile.swift
//  OngakuCore
//

import Foundation

/// Reads and writes Standard MIDI Files (`.mid`), the interchange format every DAW,
/// including Logic Pro, can import and export.
///
/// Reading supports formats 0 and 1 with tick-based timing: notes, controllers, pitch bend,
/// aftertouch, tempo changes, time signatures, track names and program changes. Each MIDI
/// channel in a file track that plays notes becomes its own instrument track with a single
/// region.
public enum StandardMIDIFile {
  public enum ReadError: Error, LocalizedError, Equatable {
    case notAMIDIFile
    case truncated
    case unsupportedFormat(Int)
    case unsupportedTiming

    public var errorDescription: String? {
      switch self {
      case .notAMIDIFile: "This isn’t a MIDI file."
      case .truncated: "The MIDI file is damaged or incomplete."
      case .unsupportedFormat(let format): "MIDI files of format \(format) aren’t supported."
      case .unsupportedTiming: "MIDI files with SMPTE timing aren’t supported."
      }
    }
  }

  /// The contents of a MIDI file, ready to add to a project.
  public struct Contents: Sendable, Equatable {
    public var tempoMap: TempoMap
    public var tracks: [Track]
    /// The file's key at the start, if it says, and its key changes after that.
    public var keySignature: KeySignature?
    public var keyChanges: [KeyChange] = []
  }

  // MARK: - Reading

  public static func read(_ data: Data) throws -> Contents {
    var reader = ByteReader(bytes: [UInt8](data))
    guard try reader.readTag() == "MThd" else { throw ReadError.notAMIDIFile }
    let headerLength = Int(try reader.readUInt32())
    let format = Int(try reader.readUInt16())
    let trackCount = Int(try reader.readUInt16())
    let division = try reader.readUInt16()
    try reader.skip(headerLength - 6)

    guard format == 0 || format == 1 else { throw ReadError.unsupportedFormat(format) }
    guard division & 0x8000 == 0, division > 0 else { throw ReadError.unsupportedTiming }
    let ticksPerQuarterNote = Int64(division)
    func convert(_ fileTicks: Int64) -> Tick {
      Tick((fileTicks * Tick.perQuarterNote + ticksPerQuarterNote / 2) / ticksPerQuarterNote)
    }

    var fileTracks: [FileTrack] = []
    while fileTracks.count < trackCount, !reader.isAtEnd {
      let tag = try reader.readTag()
      let length = Int(try reader.readUInt32())
      let body = try reader.readBytes(length)
      // Skip unknown chunk types, as the specification requires.
      guard tag == "MTrk" else { continue }
      fileTracks.append(try parseTrack(body))
    }

    // Tempo and meter usually live in the first track, but are allowed anywhere.
    var tempoMap = TempoMap()
    for change in fileTracks.flatMap(\.tempoChanges).sorted(by: { $0.tick < $1.tick }) {
      // Files store whole microseconds per beat, so 132 BPM reads back as 132.000132.
      // Rounding to a thousandth of a BPM recovers the tempo that was written.
      let bpm = (60_000_000 / Double(change.microsecondsPerQuarterNote) * 1000).rounded() / 1000
      try? tempoMap.setTempo(bpm, at: convert(change.tick))
    }
    for change in fileTracks.flatMap(\.meterChanges).sorted(by: { $0.tick < $1.tick }) {
      let position = convert(change.tick)
      let (barIndex, barStart) = tempoMap.bar(containing: position)
      // A meter change between bar lines takes effect at the next bar.
      let index = position == barStart ? barIndex : barIndex + 1
      try? tempoMap.setTimeSignature(change.signature, atBarIndex: max(0, index))
    }

    var tracks: [Track] = []
    for (fileIndex, fileTrack) in fileTracks.enumerated() {
      // Channels that only carry controllers (no notes) don't make a track.
      let channels = Set(fileTrack.notes.map(\.channel)).sorted()
      for channel in channels {
        let notes = fileTrack.notes.filter { $0.channel == channel }
        let controls = fileTrack.controls.filter { $0.event.channel == channel }
        let baseName = fileTrack.name ?? "Track \(fileIndex + 1)"
        let name = channels.count > 1 ? "\(baseName) (Ch \(channel + 1))" : baseName
        let instrument: InstrumentSource = channel == GeneralMIDI.percussionChannel
          ? .generalMIDIPercussion(kit: fileTrack.programs[channel] ?? 0)
          : .generalMIDI(program: fileTrack.programs[channel] ?? 0)
        tracks.append(makeTrack(
          name: name, notes: notes, controls: controls, instrument: instrument, tempoMap: tempoMap, convert: convert))
      }
    }
    var contents = Contents(tempoMap: tempoMap, tracks: tracks)
    for change in fileTracks.flatMap(\.keyChanges).sorted(by: { $0.tick < $1.tick }) {
      let position = convert(change.tick)
      if position <= .zero {
        contents.keySignature = change.key
      } else {
        contents.keyChanges.removeAll { $0.position == position }
        contents.keyChanges.append(KeyChange(position: position, key: change.key))
      }
    }
    return contents
  }

  private struct FileNote {
    var channel: Int
    var pitch: Int
    var velocity: Int
    var start: Int64
    var end: Int64
  }

  /// A controller, pitch bend or aftertouch event, at a file tick (its position is unused).
  private struct FileControl {
    var tick: Int64
    var event: MIDIControlEvent
  }

  private struct FileTrack {
    var name: String?
    var notes: [FileNote] = []
    var controls: [FileControl] = []
    var tempoChanges: [(tick: Int64, microsecondsPerQuarterNote: Int)] = []
    var meterChanges: [(tick: Int64, signature: TimeSignature)] = []
    var keyChanges: [(tick: Int64, key: KeySignature)] = []
    /// The first program change on each channel.
    var programs: [Int: Int] = [:]
  }

  private static func parseTrack(_ bytes: [UInt8]) throws -> FileTrack {
    var reader = ByteReader(bytes: bytes)
    var track = FileTrack()
    var tick: Int64 = 0
    var runningStatus: UInt8?
    /// Sounding notes by channel and pitch, oldest first.
    var open: [Int: [(start: Int64, velocity: Int)]] = [:]

    func closeNote(channel: Int, pitch: Int, at end: Int64) {
      let key = channel << 8 | pitch
      guard var starts = open[key], !starts.isEmpty else { return }
      let started = starts.removeFirst()
      open[key] = starts
      track.notes.append(FileNote(channel: channel, pitch: pitch, velocity: started.velocity, start: started.start, end: end))
    }

    while !reader.isAtEnd {
      tick += Int64(try reader.readVariableLength())
      var status = try reader.peek()
      if status < 0x80 {
        // Running status: reuse the previous channel message's status byte.
        guard let running = runningStatus else { throw ReadError.truncated }
        status = running
      } else {
        try reader.skip(1)
      }

      switch status {
      case 0xFF:
        let type = try reader.readByte()
        let data = try reader.readBytes(Int(try reader.readVariableLength()))
        switch type {
        case 0x03 where track.name == nil:
          let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
          track.name = name.isEmpty ? nil : name
        case 0x51 where data.count == 3:
          let microseconds = Int(data[0]) << 16 | Int(data[1]) << 8 | Int(data[2])
          if microseconds > 0 { track.tempoChanges.append((tick, microseconds)) }
        case 0x58 where data.count >= 2:
          let signature = TimeSignature(beatsPerBar: Int(data[0]), beatUnit: 1 << Int(min(data[1], 6)))
          if signature.isValid { track.meterChanges.append((tick, signature)) }
        case 0x59 where data.count >= 2:
          track.keyChanges.append((tick, KeySignature(sharpsOrFlats: Int(Int8(bitPattern: data[0])), isMinor: data[1] == 1)))
        case 0x2F:
          reader.skipToEnd()
        default:
          break
        }
      case 0xF0, 0xF7:
        try reader.skip(Int(try reader.readVariableLength()))
      default:
        runningStatus = status
        let channel = Int(status & 0x0F)
        switch status & 0xF0 {
        case 0x80:
          let pitch = Int(try reader.readByte())
          _ = try reader.readByte()
          closeNote(channel: channel, pitch: pitch, at: tick)
        case 0x90:
          let pitch = Int(try reader.readByte())
          let velocity = Int(try reader.readByte())
          if velocity == 0 {
            closeNote(channel: channel, pitch: pitch, at: tick)
          } else {
            open[channel << 8 | pitch, default: []].append((tick, velocity))
          }
        case 0xC0:
          let program = Int(try reader.readByte())
          if track.programs[channel] == nil { track.programs[channel] = program }
        case 0xD0:
          let bytes = [status, try reader.readByte()]
          if let event = MIDIControlEvent.parse(bytes, at: .zero) {
            track.controls.append(FileControl(tick: tick, event: event))
          }
        default:
          // Poly aftertouch, control change and pitch bend: two data bytes.
          let bytes = [status, try reader.readByte(), try reader.readByte()]
          if let event = MIDIControlEvent.parse(bytes, at: .zero) {
            track.controls.append(FileControl(tick: tick, event: event))
          }
        }
      }
    }

    // Notes never switched off end at the end of the track.
    for (key, starts) in open {
      for started in starts {
        track.notes.append(FileNote(
          channel: key >> 8, pitch: key & 0xFF, velocity: started.velocity, start: started.start, end: tick))
      }
    }
    return track
  }

  /// One region per track, from the bar containing the first note or controller (files
  /// often set volume and pan at the very start) to the end of the bar containing the last
  /// note or controller.
  private static func makeTrack(
    name: String, notes fileNotes: [FileNote], controls fileControls: [FileControl], instrument: InstrumentSource,
    tempoMap: TempoMap, convert: (Int64) -> Tick
  ) -> Track {
    let controlPositions = fileControls.map { convert($0.tick) }
    let firstStart = (fileNotes.map { convert($0.start) } + controlPositions).min() ?? .zero
    let lastEnd = (fileNotes.map { convert($0.end) } + controlPositions.map { $0 + Tick(1) }).max() ?? .zero
    let regionStart = tempoMap.bar(containing: firstStart).start
    let lastBar = tempoMap.bar(containing: max(lastEnd - Tick(1), regionStart))
    let regionEnd = tempoMap.tickPosition(ofBarIndex: lastBar.index + 1)

    let notes = fileNotes.map { note in
      let start = convert(note.start)
      return MIDINote(
        pitch: note.pitch, velocity: max(1, min(note.velocity, 127)), channel: note.channel,
        start: start - regionStart, length: max(convert(note.end) - start, Tick(1)))
    }
    let controls = fileControls.map { control in
      var event = control.event
      event.position = convert(control.tick) - regionStart
      return event
    }
    let region = Region(
      name: name, start: regionStart, length: regionEnd - regionStart,
      content: .midi(MIDISequence(notes: notes, controls: controls)))
    return Track(
      name: name, kind: .softwareInstrument, channel: ChannelStrip(instrument: instrument), regions: [region])
  }

  // MARK: - Writing

  /// Writes a format 1 file at 960 ticks per quarter note: a conductor track with tempo and
  /// meter, then one track per instrument track. It has what plays: looped regions' repeats
  /// (up to the project end) and take folders' comps, without muted regions, and with notes
  /// cut at their region's end.
  public static func write(_ project: Project) -> Data {
    var conductor: [(tick: Int64, bytes: [UInt8])] = [(0, metaEvent(0x03, Array("Ongaku Studio".utf8)))]
    for change in project.tempoMap.tempoChanges {
      let microseconds = Int((60_000_000 / change.bpm).rounded())
      conductor.append((change.position.rawValue, metaEvent(0x51, [
        UInt8((microseconds >> 16) & 0xFF), UInt8((microseconds >> 8) & 0xFF), UInt8(microseconds & 0xFF),
      ])))
    }
    for change in project.tempoMap.meterChanges {
      let position = project.tempoMap.tickPosition(ofBarIndex: change.barIndex)
      let power = UInt8(change.signature.beatUnit.trailingZeroBitCount)
      conductor.append((position.rawValue, metaEvent(0x58, [UInt8(change.signature.beatsPerBar), power, 24, 8])))
    }
    for change in project.keyTimeline {
      let sharpsOrFlats = UInt8(bitPattern: Int8(change.key.sharpsOrFlats))
      conductor.append((change.position.rawValue, metaEvent(0x59, [sharpsOrFlats, change.key.mode == .minor ? 1 : 0])))
    }

    var chunks = [trackChunk(conductor)]
    for track in project.tracks where track.kind == .softwareInstrument {
      var events: [(tick: Int64, bytes: [UInt8])] = [(0, metaEvent(0x03, Array(track.name.utf8)))]
      var notes: [(start: Int64, end: Int64, note: MIDINote)] = []
      var controls: [(tick: Int64, bytes: [UInt8])] = []
      for region in project.playedRegions(of: track) where !region.isMuted {
        guard case .midi(let sequence) = region.content else { continue }
        // Muted notes stay in Ongaku: a MIDI file can't say a note is muted.
        for note in sequence.notes where !note.isMuted && note.start >= .zero && note.start < region.length {
          let start = region.start + note.start
          let end = min(region.start + note.end, region.end)
          notes.append((start.rawValue, end.rawValue, note))
        }
        for event in sequence.controls where event.position >= .zero && event.position < region.length {
          controls.append(((region.start + event.position).rawValue, event.bytes))
        }
      }
      for channel in Set(notes.map(\.note.channel)).sorted() {
        switch track.channel.instrument {
        case .generalMIDI(let program):
          events.append((0, [0xC0 | UInt8(channel), UInt8(clamping: program)]))
        case .generalMIDIPercussion(let kit):
          events.append((0, [0xC0 | UInt8(channel), UInt8(clamping: kit)]))
        case .audioUnit, nil:
          break
        }
      }
      // Before the notes, so a controller and a note at the same tick arrive in that order.
      events += controls
      for (start, end, note) in notes {
        let channel = UInt8(note.channel & 0x0F)
        events.append((start, [0x90 | channel, UInt8(note.pitch), UInt8(note.velocity)]))
        events.append((end, [0x80 | channel, UInt8(note.pitch), 0]))
      }
      chunks.append(trackChunk(events))
    }

    var data = Data("MThd".utf8)
    data.append(bigEndian: UInt32(6))
    data.append(bigEndian: UInt16(1))
    data.append(bigEndian: UInt16(chunks.count))
    data.append(bigEndian: UInt16(Tick.perQuarterNote))
    for chunk in chunks {
      data.append(chunk)
    }
    return data
  }

  private static func metaEvent(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
    [0xFF, type] + variableLength(payload.count) + payload
  }

  /// Sorts events (note-offs before other events at the same tick) and encodes the chunk.
  private static func trackChunk(_ events: [(tick: Int64, bytes: [UInt8])]) -> Data {
    let sorted = events.enumerated().sorted { lhs, rhs in
      if lhs.element.tick != rhs.element.tick { return lhs.element.tick < rhs.element.tick }
      let lhsIsOff = lhs.element.bytes.first.map { $0 & 0xF0 == 0x80 } ?? false
      let rhsIsOff = rhs.element.bytes.first.map { $0 & 0xF0 == 0x80 } ?? false
      if lhsIsOff != rhsIsOff { return lhsIsOff }
      return lhs.offset < rhs.offset
    }.map(\.element)

    var body: [UInt8] = []
    var previousTick: Int64 = 0
    for event in sorted {
      body += variableLength(Int(event.tick - previousTick))
      body += event.bytes
      previousTick = event.tick
    }
    body += [0x00, 0xFF, 0x2F, 0x00]

    var chunk = Data("MTrk".utf8)
    chunk.append(bigEndian: UInt32(body.count))
    chunk.append(contentsOf: body)
    return chunk
  }

  static func variableLength(_ value: Int) -> [UInt8] {
    var value = max(0, value)
    var bytes = [UInt8(value & 0x7F)]
    value >>= 7
    while value > 0 {
      bytes.insert(UInt8(value & 0x7F) | 0x80, at: 0)
      value >>= 7
    }
    return bytes
  }
}

/// Big-endian reading with bounds checks; every read past the end throws `.truncated`.
private struct ByteReader {
  let bytes: [UInt8]
  private(set) var position = 0

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  var isAtEnd: Bool { position >= bytes.count }

  func peek() throws -> UInt8 {
    guard position < bytes.count else { throw StandardMIDIFile.ReadError.truncated }
    return bytes[position]
  }

  mutating func readByte() throws -> UInt8 {
    let byte = try peek()
    position += 1
    return byte
  }

  mutating func readBytes(_ count: Int) throws -> [UInt8] {
    guard count >= 0, position + count <= bytes.count else { throw StandardMIDIFile.ReadError.truncated }
    defer { position += count }
    return Array(bytes[position..<(position + count)])
  }

  mutating func skip(_ count: Int) throws {
    _ = try readBytes(count)
  }

  mutating func skipToEnd() {
    position = bytes.count
  }

  mutating func readUInt16() throws -> UInt16 {
    let bytes = try readBytes(2)
    return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
  }

  mutating func readUInt32() throws -> UInt32 {
    let bytes = try readBytes(4)
    return bytes.reduce(0) { $0 << 8 | UInt32($1) }
  }

  mutating func readTag() throws -> String {
    String(decoding: try readBytes(4), as: UTF8.self)
  }

  /// A MIDI variable-length quantity (at most four bytes).
  mutating func readVariableLength() throws -> UInt32 {
    var value: UInt32 = 0
    for _ in 0..<4 {
      let byte = try readByte()
      value = value << 7 | UInt32(byte & 0x7F)
      if byte & 0x80 == 0 { return value }
    }
    throw StandardMIDIFile.ReadError.truncated
  }
}

extension Data {
  fileprivate mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}
