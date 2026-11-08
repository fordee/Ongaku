//
//  ProjectWindowModel+Loops.swift
//  Ongaku
//

import Foundation
import OngakuCore

/// Loops from the Loop Browser (or Finder) follow the song, as Apple Loops do in Logic: a
/// tagged loop is stretched to the song's tempo and moved to its key. Loops that carry MIDI
/// come in as notes on instrument tracks.
extension ProjectWindowModel {
  func toggleLoopBrowser() {
    isLoopBrowserVisible.toggle()
  }

  /// Reads a file's loop tags off the main thread.
  @concurrent
  nonisolated static func loopMetadata(of url: URL) async -> AudioFileMetadata {
    (try? AudioFileMetadata.read(url, includingMIDI: true)) ?? AudioFileMetadata()
  }

  /// Fits an audio region of a tagged loop to the song where it starts: its length becomes
  /// the loop's beats, its recording is stretched to fill them, and a tonal loop is
  /// transposed to the song's key. Untagged audio is left as it is.
  func conformToSong(_ region: inout Region, loop metadata: AudioFileMetadata, file: AudioFileReference) {
    guard metadata.isLoop, case .audio(var audio) = region.content, let quarterNotes = Self.quarterNotes(of: metadata) else { return }
    let tempoMap = project.tempoMap
    let length = Tick.quarterNotes(quarterNotes)
    let seconds = tempoMap.seconds(at: region.start + length) - tempoMap.seconds(at: region.start)
    guard seconds > 0, file.duration > 0 else { return }
    let stretch = file.duration / seconds
    // Far from the loop's own tempo it would sound wrong anyway: play it as recorded.
    guard (0.25...4).contains(stretch) else { return }
    if abs(stretch - 1) > 0.0001 { audio.stretch = stretch }
    region.content = .audio(audio)
    region.length = length
    if let tonic = metadata.keyTonic {
      region.transpose = project.key(at: region.start).semitones(fromTonic: tonic, mode: metadata.keyMode)
    }
  }

  /// How long a loop is in quarter notes: its beats in its meter's beat unit, or else its
  /// length at its tempo.
  static func quarterNotes(of metadata: AudioFileMetadata) -> Double? {
    let beatUnit = Double(metadata.timeSignature?.beatUnit ?? 4)
    if let beats = metadata.beats, beats > 0 { return Double(beats) * 4 / beatUnit }
    guard let tempo = metadata.tempo, let duration = metadata.duration else { return nil }
    return duration * tempo / 60
  }

  /// The commands that add a MIDI loop's notes at `position`: onto `track` if it's an
  /// instrument track, otherwise onto a new instrument track playing a sound that suits the
  /// loop. `nil` if the file has no notes.
  func midiLoopCommands(
    _ midi: Data, name: String, metadata: AudioFileMetadata, at position: Tick, onTrack track: Track?
  ) -> [any EditCommand]? {
    guard let contents = try? StandardMIDIFile.read(midi) else { return nil }
    var notes: [MIDINote] = []
    var controls: [MIDIControlEvent] = []
    for fileTrack in contents.tracks {
      for region in fileTrack.regions {
        guard case .midi(let sequence) = region.content else { continue }
        notes += sequence.notes.map { var note = $0; note.start += region.start; return note }
        controls += sequence.controls.map { var control = $0; control.position += region.start; return control }
      }
    }
    guard !notes.isEmpty else { return nil }
    // Without tags, the loop runs to the end of the bar its last note ends in.
    let length = Self.quarterNotes(of: metadata).map(Tick.quarterNotes) ?? {
      let tempoMap = project.tempoMap
      let bar = tempoMap.bar(containing: notes.map(\.end).max() ?? .zero)
      return bar.start + tempoMap.timeSignature(atBarIndex: bar.index).ticksPerBar
    }()
    var region = Region(name: name, start: position, length: length, content: .midi(MIDISequence(notes: notes, controls: controls)))
    if let tonic = metadata.keyTonic {
      region.transpose = project.key(at: position).semitones(fromTonic: tonic, mode: metadata.keyMode)
    }
    if let track, track.kind == .softwareInstrument {
      return [AddRegion(region, to: track.id)]
    }
    var newTrack = makeTrack(name: name, kind: .softwareInstrument)
    let category = SoundCategory.classify([metadata.category, metadata.subcategory].compactMap { $0 } + [name])
    newTrack.channel.instrument = Self.instrument(for: category)
    return [AddTrack(newTrack), AddRegion(region, to: newTrack.id)]
  }

  /// A General MIDI sound for a family of loops.
  static func instrument(for category: SoundCategory?) -> InstrumentSource {
    switch category {
    case .drums, .percussion: .generalMIDIPercussion(kit: 0)
    case .bass: .generalMIDI(program: 33)
    case .guitar: .generalMIDI(program: 25)
    case .keys: .generalMIDI(program: 4)
    case .synth: .generalMIDI(program: 81)
    case .strings: .generalMIDI(program: 48)
    case .brass: .generalMIDI(program: 61)
    case .woodwind: .generalMIDI(program: 65)
    case .mallets: .generalMIDI(program: 11)
    case .vocals: .generalMIDI(program: 52)
    case .fx: .generalMIDI(program: 99)
    case .piano, .other, nil: .generalMIDI(program: 0)
    }
  }
}
