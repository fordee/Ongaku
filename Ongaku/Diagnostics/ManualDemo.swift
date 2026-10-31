//
//  ManualDemo.swift
//  Ongaku
//

#if DEBUG
import AVFAudio
import AppKit
import OngakuCore

/// The song and window set-ups the manual's screenshots show (Docs/Manual; taken by
/// OngakuUITests/ManualScreenshotUITests). Launch with `-OngakuManualScene <scene>`: a new
/// project window opens a demo song, set up for that scene, and its window's accessibility
/// identifier becomes "manual-ready" once it is.
enum ManualDemo {
  enum Scene: String, CaseIterable {
    case overview, controlBar = "control-bar", trackHeader = "track-header", cycle
    case recordArmed = "record-armed", takeFolder = "take-folder"
    case pianoRoll = "piano-roll", pianoRollHeader = "piano-roll-header", stepSequencer = "step-sequencer"
    case pitchBend = "pitch-bend", sends, automation
    case drummerTrack = "drummer-track", chordTrack = "chord-track"
    case regions, toolMenu = "tool-menu", regionInspectorMIDI = "region-inspector-midi"
    case regionInspectorAudio = "region-inspector-audio", loop, arrangement
    case stackExpanded = "stack-expanded", stackCollapsed = "stack-collapsed"
    case flexMenu = "flex-menu", flexMarkers = "flex-markers", smartTempo = "smart-tempo", library
  }

  static var scene: Scene? {
    UserDefaults.standard.string(forKey: "OngakuManualScene").flatMap(Scene.init)
  }

  private static let bar = Tick.quarterNotes(4)
  private static func bars(_ count: Int) -> Tick { bar * Int64(count) }

  /// Builds the demo song in `model`'s document and sets the window up for `scene`.
  @MainActor
  static func setUp(_ model: ProjectWindowModel, for scene: Scene) async {
    do {
      let vocal = try await model.document.stageAudio(from: writeAudio(named: "Vocal Take", seconds: 16, vocal))
      let loop = try await model.document.stageAudio(from: writeAudio(named: "Drum Loop", seconds: 4.8, drumLoop))
      model.document.editor.load(song(vocal: vocal, loop: loop, for: scene))
      model.projectDidChange()
    } catch {
      model.errorMessage = "The manual's demo song couldn't be made: \(error.localizedDescription)"
      return
    }
    // Session players are made the way the menu makes them, so they follow the sections.
    select("Keys", in: model)
    model.addPlayerTrack(.bass)
    model.addDrummerTrack()
    model.bottomPane = nil
    model.editorRegionID = nil
    model.selectedRegionIDs = []
    await arrange(model, for: scene)
    model.projectDidChange()
    // Let the window draw what changed, and plug-ins and waveforms load.
    try? await Task.sleep(for: .seconds(2))
    model.hostWindow?.setAccessibilityIdentifier("manual-ready")
  }

  // MARK: - The song

  /// A short pop song: Intro, Verse, Chorus and Outro, with keys, a lead line, a sung
  /// vocal, a drum loop and a reverb aux (the bass and drums are added by session players).
  private static func song(vocal: AudioFileReference, loop: AudioFileReference, for scene: Scene) -> Project {
    var project = Project(tempoMap: TempoMap(bpm: 120), tracks: [], audioFiles: [vocal, loop])
    project.cycle = CycleRange(isEnabled: scene == .cycle, start: bars(4), end: bars(8))
    project.arrangement = [
      ArrangementSection(name: "Intro", start: .zero, length: bars(4)),
      ArrangementSection(name: "Verse", start: bars(4), length: bars(8)),
      ArrangementSection(name: "Chorus", start: bars(12), length: bars(8)),
      ArrangementSection(name: "Outro", start: bars(20), length: bars(4)),
    ]
    project.markers = [Marker(name: "Vocals in", position: bars(4))]
    let progression: [(Int, Chord.Quality)] = [(0, .major), (9, .minor), (5, .major), (7, .major)]
    project.chords = (0..<24).map { index in
      let (root, quality) = progression[index % 4]
      return ChordChange(position: bars(index), chord: Chord(root: root, quality: quality))
    }

    let reverb = makeReverb()
    var keys = Track(name: "Keys", kind: .softwareInstrument, color: .green)
    keys.channel.instrument = .generalMIDI(program: 4)
    keys.channel.sends = [Send(destinationTrackID: reverb.id, level: -10)]
    keys.regions = [
      midi("Keys Intro", at: 0, bars: 4, chords(bars: 4), muted: scene == .regions),
      midi("Chords", at: 4, bars: 8, chords(bars: 8)),
      midi("Chords", at: 12, bars: 8, chords(bars: 8)),
    ]

    var lead = Track(name: "Lead", kind: .softwareInstrument, color: .purple)
    lead.channel.instrument = .generalMIDI(program: 81)
    if scene == .takeFolder {
      lead.regions = [takeFolder(at: 4)]
    } else {
      var melody = midi("Melody", at: 4, bars: 8, melody(bars: 8))
      if case .midi(var sequence) = melody.content {
        sequence.controls = pitchBend(bars: 8)
        melody.content = .midi(sequence)
      }
      lead.regions = [melody]
    }

    var vocals = Track(name: "Vocals", kind: .audio, color: .blue)
    vocals.channel.sends = [Send(destinationTrackID: reverb.id, level: -6)]
    var take = Region.audio(for: vocal, at: bars(4), tempoMap: project.tempoMap)
    take.name = "Vocal Take"
    vocals.regions = [take]
    vocals.automation = [AutomationLane(parameter: .volume, points: [
      AutomationPoint(position: bars(4), value: -6), AutomationPoint(position: bars(6), value: -2),
      AutomationPoint(position: bars(8), value: -2), AutomationPoint(position: bars(10), value: -8),
      AutomationPoint(position: bars(12), value: 0),
    ])]

    var loopTrack = Track(name: "Drum Loop", kind: .audio, color: .yellow)
    var loopRegion = Region.audio(for: loop, at: .zero, tempoMap: project.tempoMap)
    loopRegion.name = "Drum Loop"
    if scene == .flexMarkers, case .audio(var content) = loopRegion.content {
      loopTrack.flexMode = .slicing
      // Two hits nudged later and one earlier.
      content.flexMarkers = [
        FlexMarker(source: 0.6, target: 0.68), FlexMarker(source: 1.8, target: 1.86), FlexMarker(source: 3.0, target: 2.94),
      ]
      loopRegion.content = .audio(content)
    }
    loopTrack.regions = [loopRegion]

    var tracks = [keys, lead, vocals, loopTrack]
    if scene == .loop {
      var riff = Track(name: "Riff", kind: .softwareInstrument, color: .red)
      riff.channel.instrument = .generalMIDI(program: 29)
      riff.regions = [Region(
        name: "Riff", start: .zero, length: bars(2), content: .midi(melody(bars: 2)), isLooped: true, loopedLength: bars(8))]
      tracks.insert(riff, at: 2)
    }
    if scene == .stepSequencer {
      var beat = Track(name: "Beat", kind: .softwareInstrument, color: .orange)
      beat.channel.instrument = .generalMIDIPercussion(kit: 0)
      var pattern = StepPattern.drums()
      // Accents, so the velocity view has something to show.
      for row in pattern.rows.indices where pattern.rows[row].pitch == 42 {
        for step in pattern.rows[row].steps.indices where pattern.rows[row].steps[step].isOn {
          pattern.rows[row].steps[step].velocity = [110, 60, 85, 50][(step / 2) % 4]
        }
      }
      var region = Region(name: "Pattern", start: .zero, length: bar, content: .midi(MIDISequence()), pattern: pattern)
      region.renderPattern()
      beat.regions = [region]
      tracks.insert(beat, at: 0)
    }
    if scene == .stackExpanded || scene == .stackCollapsed {
      for (name, pitch) in [("Kick", 36), ("Snare", 38), ("Hats", 42)] {
        var track = Track(name: name, kind: .softwareInstrument, color: .yellow)
        track.channel.instrument = .generalMIDIPercussion(kit: 0)
        track.regions = [midi(name, at: 0, bars: 8, hits(pitch, bars: 8))]
        tracks.insert(track, at: tracks.count - 1)
      }
    }
    project.tracks = tracks + [reverb]
    return project
  }

  private static func makeReverb() -> Track {
    var reverb = Track(name: "Reverb", kind: .aux, color: .purple)
    reverb.channel.inserts = [OngakuEffect.reverb.makeReference()]
    return reverb
  }

  private static func midi(_ name: String, at start: Int, bars count: Int, _ sequence: MIDISequence, muted: Bool = false) -> Region {
    Region(name: name, start: bars(start), length: bars(count), isMuted: muted, content: .midi(sequence))
  }

  /// The song's chords, a bar each, as held keyboard chords.
  private static func chords(bars count: Int) -> MIDISequence {
    let voicings = [[60, 64, 67], [57, 60, 64], [53, 57, 60], [55, 59, 62]]
    var notes: [MIDINote] = []
    for index in 0..<count {
      for (offset, pitch) in voicings[index % 4].enumerated() {
        notes.append(MIDINote(pitch: pitch, velocity: 80 + offset * 4, start: .quarterNotes(Double(index * 4)), length: .quarterNotes(3.8)))
      }
    }
    return MIDISequence(notes: notes)
  }

  /// A singable line over the chords.
  private static func melody(bars count: Int) -> MIDISequence {
    let phrase: [(pitch: Int, beat: Double, length: Double)] = [
      (72, 0, 1), (74, 1, 0.5), (76, 1.5, 1.5), (74, 3, 1), (72, 4, 1.5), (69, 5.5, 0.5), (71, 6, 1), (72, 7, 1),
    ]
    var notes: [MIDINote] = []
    for start in stride(from: 0, to: count * 4, by: 8) {
      for (index, note) in phrase.enumerated() where Double(start) + note.beat < Double(count * 4) {
        notes.append(MIDINote(
          pitch: note.pitch - (start / 8 % 2 == 1 ? 2 : 0), velocity: 70 + (index * 13) % 45,
          start: .quarterNotes(Double(start) + note.beat), length: .quarterNotes(note.length)))
      }
    }
    return MIDISequence(notes: notes)
  }

  /// Bends up into the first note of each phrase, as a singer would.
  private static func pitchBend(bars count: Int) -> [MIDIControlEvent] {
    var events: [MIDIControlEvent] = []
    for phrase in stride(from: 0, to: count * 4, by: 8) {
      for step in 0...8 {
        let value = Int(-3000 * (1 - Double(step) / 8))
        events.append(MIDIControlEvent(kind: .pitchBend, position: .quarterNotes(Double(phrase) + Double(step) * 0.0625), value: value))
      }
      events.append(MIDIControlEvent(kind: .pitchBend, position: .quarterNotes(Double(phrase) + 5.5), value: 1200))
      events.append(MIDIControlEvent(kind: .pitchBend, position: .quarterNotes(Double(phrase) + 6), value: 0))
    }
    return events
  }

  private static func hits(_ pitch: Int, bars count: Int) -> MIDISequence {
    let beats: [Double] = switch pitch {
    case 36: [0, 2.5]
    case 38: [1, 3]
    default: [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5]
    }
    let notes = (0..<count).flatMap { barIndex in
      beats.map { MIDINote(pitch: pitch, velocity: 100, start: .quarterNotes(Double(barIndex * 4) + $0), length: .quarterNotes(0.25)) }
    }
    return MIDISequence(notes: notes)
  }

  /// Three takes of the lead line, comped from Take 1 and Take 3.
  private static func takeFolder(at start: Int) -> Region {
    let takes = (0..<3).map { index in
      var notes = melody(bars: 8).notes
      for note in notes.indices { notes[note].pitch += [0, -2, 2][index] }
      return Take(name: "Take \(index + 1)", content: .midi(MIDISequence(notes: notes)))
    }
    var folder = TakeFolder(takes: takes, playing: takes[2].id, length: bars(8))
    folder.use(takes[0].id, over: bars(2)..<bars(4))
    return Region(name: "Lead", start: bars(start), length: bars(8), content: takes[2].content, takeFolder: folder)
  }

  // MARK: - The window

  @MainActor
  private static func arrange(_ model: ProjectWindowModel, for scene: Scene) async {
    let regions = model.project.tracks.flatMap(\.regions)
    func region(_ name: String) -> Region? { regions.first { $0.name == name } }
    model.isInspectorVisible = true
    switch scene {
    case .overview, .controlBar:
      select("Keys", in: model)
      model.selectedRegionIDs = Set(region("Chords").map { [$0.id] } ?? [])
      model.bottomPane = .mixer
      // Short enough to leave room for the tracks above it.
      model.paneHeights[.mixer] = 400
    case .trackHeader, .cycle, .drummerTrack:
      select(scene == .drummerTrack ? "Drummer" : "Keys", in: model)
    case .recordArmed:
      for name in ["Keys", "Vocals"] {
        if let track = model.project.tracks.first(where: { $0.name == name }) { model.setRecordArmed(track.id, true) }
      }
      select("Vocals", in: model)
    case .takeFolder:
      select("Lead", in: model)
      model.selectedRegionIDs = Set(region("Lead").map { [$0.id] } ?? [])
    case .pianoRoll, .pianoRollHeader, .pitchBend:
      guard let melody = region("Melody") else { return }
      select("Lead", in: model)
      model.selectedRegionIDs = [melody.id]
      model.openEditor(for: melody.id)
      model.pianoRoll.editorKind = .pianoRoll
      model.pianoRoll.isMIDIDrawVisible = true
      model.pianoRoll.midiDrawParameter = scene == .pitchBend ? .control(.pitchBend) : .velocity
      if scene == .pianoRoll, case .midi(let sequence) = melody.content {
        model.pianoRoll.selectedNoteIDs = Set(sequence.notes.prefix(8).map(\.id))
      }
    case .stepSequencer:
      guard let pattern = region("Pattern") else { return }
      select("Beat", in: model)
      model.selectedRegionIDs = [pattern.id]
      model.openEditor(for: pattern.id)
      model.pianoRoll.editorKind = .stepSequencer
      model.pianoRoll.stepEditMode = .velocity
    case .sends:
      select("Vocals", in: model)
      model.bottomPane = .mixer
    case .automation:
      select("Vocals", in: model)
      model.isAutomationVisible = true
      if let vocals = model.project.tracks.first(where: { $0.name == "Vocals" }) {
        model.automationParameters[vocals.id] = .volume
      }
    case .chordTrack, .arrangement:
      model.isGlobalTracksVisible = true
      select("Keys", in: model)
      if scene == .arrangement {
        model.selectedSectionID = model.project.arrangement.first { $0.name == "Verse" }?.id
      }
    case .regions:
      select("Keys", in: model)
      model.selectedRegionIDs = Set(region("Chords").map { [$0.id] } ?? [])
    case .toolMenu:
      select("Keys", in: model)
      model.isShowingToolMenu = true
    case .regionInspectorMIDI:
      select("Lead", in: model)
      model.selectedRegionIDs = Set(region("Melody").map { [$0.id] } ?? [])
    case .regionInspectorAudio:
      select("Vocals", in: model)
      model.selectedRegionIDs = Set(region("Vocal Take").map { [$0.id] } ?? [])
    case .loop:
      select("Riff", in: model)
      model.selectedRegionIDs = Set(region("Riff").map { [$0.id] } ?? [])
    case .stackExpanded, .stackCollapsed:
      model.selectedTrackIDs = Set(model.project.tracks.filter { ["Kick", "Snare", "Hats"].contains($0.name) }.map(\.id))
      model.createSummingStack()
      if scene == .stackCollapsed, let stack = model.selectedTrackID { model.collapsedStackIDs.insert(stack) }
    case .flexMenu, .flexMarkers, .smartTempo:
      select("Drum Loop", in: model)
      model.selectedRegionIDs = Set(region("Drum Loop").map { [$0.id] } ?? [])
      if scene == .smartTempo, let loop = region("Drum Loop") {
        model.detectTempo(of: loop.id)
        for _ in 0..<100 where model.detectedTempos[loop.id] == nil {
          try? await Task.sleep(for: .milliseconds(100))
        }
      }
    case .library:
      select("Keys", in: model)
      model.isLibraryVisible = true
    }
  }

  @MainActor
  private static func select(_ name: String, in model: ProjectWindowModel) {
    guard let track = model.project.tracks.first(where: { $0.name == name }) else { return }
    model.selectedTrackID = track.id
  }

  // MARK: - Audio

  /// Writes `seconds` of mono audio at 48 kHz, sample by sample from `signal`, to a file in
  /// the temporary folder.
  private static func writeAudio(named name: String, seconds: Double, _ signal: (Double) -> Float) throws -> URL {
    let rate = 48_000.0
    let frames = AVAudioFrameCount(seconds * rate)
    let url = FileManager.default.temporaryDirectory.appending(path: "\(name).caf")
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
    else { throw CocoaError(.fileWriteUnknown) }
    buffer.frameLength = frames
    for frame in 0..<Int(frames) {
      buffer.floatChannelData![0][frame] = signal(Double(frame) / rate)
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    file.close()
    return url
  }

  /// Sung phrases: a voice-like tone with vibrato on the melody's notes, with breaths
  /// between phrases.
  private static func vocal(_ time: Double) -> Float {
    let beat = time * 2
    let phrase = beat.truncatingRemainder(dividingBy: 8)
    guard phrase < 7.5 else { return 0 }
    let notes: [(beat: Double, pitch: Double)] = [(0, 72), (1, 74), (1.5, 76), (3, 74), (4, 72), (5.5, 69), (6, 71), (7, 72)]
    let pitch = notes.last { $0.beat <= phrase }?.pitch ?? 72
    let frequency = 440 * pow(2, (pitch - 12 - 69) / 12) * (1 + 0.006 * sin(2 * .pi * 5.5 * time))
    let start = notes.last { $0.beat <= phrase }?.beat ?? 0
    let envelope = min(1, (phrase - start) * 8) * (0.6 + 0.4 * sin(.pi * min(1, (phrase - start))))
    let phase = 2 * .pi * frequency * time
    let tone = sin(phase) + 0.5 * sin(2 * phase) + 0.3 * sin(3 * phase) + 0.15 * sin(4 * phase)
    return Float(0.2 * envelope * tone)
  }

  /// Two bars of drums at 100 BPM: kick, snare and hats.
  private static func drumLoop(_ time: Double) -> Float {
    let beatLength = 60.0 / 100
    let beat = time / beatLength
    let inBar = beat.truncatingRemainder(dividingBy: 4)
    let sinceEighth = (beat * 2).truncatingRemainder(dividingBy: 1) * beatLength / 2
    var sample = 0.15 * exp(-sinceEighth * 60) * sin(2 * .pi * 7_000 * time + 3 * sin(2 * .pi * 11_000 * time))
    let sinceBeat = beat.truncatingRemainder(dividingBy: 1) * beatLength
    let whole = Int(inBar)
    if whole == 0 || whole == 2 {
      sample += 0.8 * exp(-sinceBeat * 18) * sin(2 * .pi * (55 + 90 * exp(-sinceBeat * 30)) * sinceBeat)
    } else {
      sample += 0.5 * exp(-sinceBeat * 22) * (sin(2 * .pi * 190 * sinceBeat) + 0.6 * sin(2 * .pi * 3_100 * time * 1.3))
    }
    return Float(sample * 0.8)
  }
}
#endif
