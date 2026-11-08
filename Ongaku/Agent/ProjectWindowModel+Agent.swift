//
//  ProjectWindowModel+Agent.swift
//  Ongaku
//

import AVFAudio
import AppKit
import OngakuCore
import OngakuEngine

/// A project window is what an agent's tools work on: its song, undo, transport and saving.
extension ProjectWindowModel: AgentSession {
  var songName: String {
    (hostWindow?.windowController?.document as? NSDocument)?.displayName ?? hostWindow?.title ?? "Untitled"
  }

  /// Applies an agent's change as one undo step, named so the Edit menu shows who made it
  /// ("Undo Agent: Add Notes"). Unlike `perform(_:named:)`, a failure goes back to the
  /// agent rather than to an alert in the window.
  func performEdit(_ command: any EditCommand, named actionName: String) throws {
    try document.editor.perform(CompositeCommand("Agent: \(actionName)", commands: [command]), undoManager: undoManager)
    // The engine follows straight away (the window's view would also tell it, a moment
    // later), so a plug-in an agent adds starts loading and playback hears the change.
    projectDidChange()
  }

  var isPlaying: Bool { engine.isPlaying }
  var playheadPosition: Tick { engine.playheadPosition }

  func play(from position: Tick?) {
    if let position { engine.locate(to: position) }
    if !engine.isPlaying { engine.play() }
  }

  func stop() {
    engine.stop()
  }

  func undo() -> String? {
    guard let undoManager, undoManager.canUndo else { return nil }
    let name = undoManager.undoActionName
    undoManager.undo()
    projectDidChange()
    return name
  }

  func redo() -> String? {
    guard let undoManager, undoManager.canRedo else { return nil }
    let name = undoManager.redoActionName
    undoManager.redo()
    projectDidChange()
    return name
  }

  /// Saves as File › Save does, waiting for the save without holding up the main thread.
  ///
  /// A song that's never been saved isn't saved here: only the person can choose where it
  /// goes, and opening the Save panel from an agent's call ran it modally on the main thread,
  /// where the document's own saving then waited on it forever.
  func save() async throws {
    guard let document = hostWindow?.windowController?.document as? NSDocument else {
      throw AgentError.notPossible("This song can't be saved from here; ask the person to choose File › Save.")
    }
    guard let url = document.fileURL, let type = document.fileType else {
      throw AgentError.notPossible(
        "This song hasn't been saved yet, so it has no place on disk. Ask the person to choose File › Save and pick where it goes; after that you can save it.")
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      document.save(to: url, ofType: type, for: .saveOperation) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  var installedAudioUnits: [AgentAudioUnit] {
    audioUnitInstruments.map { AgentAudioUnit(name: $0.name, manufacturer: $0.manufacturer, reference: $0.makeReference()) }
  }

  // MARK: - Sound libraries

  var soundLibraries: [AgentSoundLibrary] {
    soundLibraryStore.libraries.map { AgentSoundLibrary(id: $0.id, name: $0.name, items: $0.items, searchTexts: $0.searchTexts) }
  }

  /// Adds a library loop or sample as dropping it from the Loop Browser does, so it follows
  /// the song's tempo and key the same way.
  func addLibrarySound(_ sound: AgentLibrarySound, at position: Tick, onTrack trackID: Track.ID?) async throws -> AgentLibraryPlacement {
    guard let url = soundLibraryStore.library(withID: sound.libraryID)?.url(for: sound.item) else {
      throw AgentError.notFound("The “\(sound.libraryName)” library can't be found right now.")
    }
    let before = Set(project.tracks.flatMap(\.regions).map(\.id))
    errorMessage = nil
    await importAudio([url], at: position, onTrack: trackID, actionName: "Agent: Add \(sound.name)")
    if let message = errorMessage {
      // Back to the agent rather than an alert in the window.
      errorMessage = nil
      throw AgentError.notPossible(message)
    }
    projectDidChange()
    return AgentLibraryPlacement(regionIDs: project.tracks.flatMap(\.regions).map(\.id).filter { !before.contains($0) })
  }

  func setImpulseResponse(_ sound: AgentLibrarySound, forPlugin pluginID: PluginReference.ID, on channelID: Track.ID) throws {
    guard let url = soundLibraryStore.library(withID: sound.libraryID)?.url(for: sound.item) else {
      throw AgentError.notFound("The “\(sound.libraryName)” library can't be found right now.")
    }
    try useImpulseResponse(at: url, forInsert: pluginID, on: channelID)
    projectDidChange()
  }

  var installedEffects: [AgentAudioUnit] {
    InstrumentLibrary.audioUnitEffects().map { AgentAudioUnit(name: $0.name, manufacturer: $0.manufacturer, reference: $0.makeReference()) }
  }

  // MARK: - Plug-ins

  /// Plug-ins load in the background (out of process), so this waits up to ten seconds.
  func waitForPlugin(_ pluginID: PluginReference.ID, on channelID: Track.ID) async -> Bool {
    for _ in 0..<200 {
      guard (try? project.inserts(of: channelID))?.contains(where: { $0.id == pluginID }) == true else { return false }
      if engine.withInsertAudioUnit(pluginID, onTrack: channelID, { _ in }) != nil { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return false
  }

  func parameters(ofPlugin pluginID: PluginReference.ID, on channelID: Track.ID) -> [AgentPluginParameter]? {
    engine.withInsertAudioUnit(pluginID, onTrack: channelID) { unit in
      (unit.parameterTree?.allParameters ?? []).compactMap { parameter -> AgentPluginParameter? in
        guard parameter.flags.contains(.flag_IsWritable), parameter.maxValue > parameter.minValue else { return nil }
        return AgentPluginParameter(
          address: parameter.address, name: parameter.displayName, value: Double(parameter.value),
          minimum: Double(parameter.minValue), maximum: Double(parameter.maxValue), unit: Self.unitName(of: parameter),
          choices: parameter.unit == .indexed ? parameter.valueStrings : nil)
      }
    }
  }

  func presets(ofPlugin pluginID: PluginReference.ID, on channelID: Track.ID) -> [String] {
    engine.withInsertAudioUnit(pluginID, onTrack: channelID) { unit in (unit.factoryPresets ?? []).map(\.name) } ?? []
  }

  /// Changes a loaded plug-in, then stores its new settings in the song as one undo step.
  func setPlugin(
    _ pluginID: PluginReference.ID, on channelID: Track.ID, preset: String?, values: [UInt64: Double], named actionName: String
  ) async throws {
    // Undo goes back to the settings it has now. Changes made in its window only reach the
    // song when the window closes, so store them first, as saving does.
    if let current = engine.insertState(pluginID, onTrack: channelID) {
      var settled = project
      try? SetPluginState(current, forPlugin: pluginID, on: channelID).apply(to: &settled)
      document.editor.load(settled)
    }
    let found: Bool? = engine.withInsertAudioUnit(pluginID, onTrack: channelID) { unit in
      if let preset, let match = unit.factoryPresets?.first(where: { $0.name.compare(preset, options: .caseInsensitive) == .orderedSame }) {
        unit.currentPreset = match
      }
      for (address, value) in values {
        unit.parameterTree?.parameter(withAddress: address)?.value = AUValue(value)
      }
      return true
    }
    guard found == true else { throw AgentError.notPossible("The plug-in isn't loaded.") }
    // An out-of-process plug-in takes a moment to take the changes in.
    try? await Task.sleep(for: .milliseconds(100))
    guard let state = engine.insertState(pluginID, onTrack: channelID) else {
      throw AgentError.notPossible("The plug-in's settings couldn't be read back.")
    }
    try performEdit(SetPluginState(state, forPlugin: pluginID, on: channelID), named: actionName)
  }

  private static func unitName(of parameter: AUParameter) -> String {
    switch parameter.unit {
    case .decibels: "dB"
    case .hertz: "Hz"
    case .milliseconds: "ms"
    case .seconds: "s"
    case .percent: "%"
    case .cents: "cents"
    case .relativeSemiTones: "semitones"
    case .midiNoteNumber: "MIDI note"
    case .degrees: "°"
    case .BPM: "BPM"
    case .beats: "beats"
    case .ratio: ":1"
    case .customUnit: parameter.unitName ?? ""
    default: ""
    }
  }

  // MARK: - Rendering

  /// Renders to a temporary 32-bit float file and reads it back, as analysis needs samples.
  func renderMix(_ range: Range<Tick>) async throws -> AgentAudio {
    let folder = FileManager.default.temporaryDirectory.appending(path: "Agent Renders/\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appending(path: "Mix.wav")
    let settings = BounceSettings(format: .wav, bitDepth: .thirtyTwoFloat, sampleRate: 48_000, normalize: false, includeTail: false)
    _ = try await render(range, settings: settings, to: url)
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
      throw AgentError.notPossible("The mix couldn't be read back.")
    }
    try file.read(into: buffer)
    guard let channels = buffer.floatChannelData else { throw AgentError.notPossible("The mix couldn't be read back.") }
    let frames = Int(buffer.frameLength)
    let left = Array(UnsafeBufferPointer(start: channels[0], count: frames))
    let right = buffer.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: channels[1], count: frames)) : left
    return AgentAudio(left: left, right: right, sampleRate: file.processingFormat.sampleRate)
  }

  /// Bounces to Music › Ongaku Studio › Bounces, named after the song and the time.
  func bounce(_ range: Range<Tick>, settings: BounceSettings) async throws -> AgentBounce {
    guard let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first else {
      throw AgentError.notPossible("The Music folder couldn't be found.")
    }
    let folder = music.appending(path: "Ongaku Studio/Bounces", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)", timeZone: .current, calendar: .current))
    let url = folder.appending(path: "\(exportFileName) \(stamp).\(settings.format.fileExtension)")
    let result = try await render(range, settings: settings, to: url)
    return AgentBounce(path: url.path, seconds: result.duration, peakDecibels: result.peakDecibels, isClipped: result.isClipped)
  }

  /// The song as it plays, rendered as the Bounce dialog renders it.
  private func render(_ range: Range<Tick>, settings: BounceSettings, to url: URL) async throws -> BounceResult {
    engine.stop()
    // Flexed regions bounce as they'll play, so their renders have to be ready first.
    await finishFlexRenders()
    let bouncer = ProjectBouncer(project: projectWithCurrentPluginStates()) { [weak document] file in document?.url(for: file) }
    return try await bouncer.bounce(range, settings: settings, to: url)
  }

  /// Analyze Whole Song, for an agent: the findings, or `nil` if it heard too little.
  func masterSong() async throws -> MasteringAnalysis.Result? {
    var whole = project
    whole.cycle.isEnabled = false
    guard let range = whole.bounceRange else { throw AgentError.notPossible("The song is empty, so there's nothing to master.") }
    engine.stop()
    if stereoOutMastering == nil, project.stereoOutInserts.count < ChannelStrip.maximumInserts {
      try performEdit(AddInsert(OngakuEffect.mastering.makeReference(), to: Project.stereoOutID), named: "Add Mastering")
    }
    guard let mastering = await masteringOnStereoOut() else {
      throw AgentError.notPossible("Ongaku Mastering couldn't be put on Stereo Out (it may have no free slot).")
    }
    guard let state = try await masteringState(for: mastering, over: range, analysis: nil) else { return nil }
    try adoptMasteringState(state, for: mastering) { try performEdit($0, named: "Master Song") }
    return Self.masteringAnalysis(in: state)
  }

  /// The findings Mastering keeps in its settings ("ongakuMasteringAnalysis").
  private static func masteringAnalysis(in state: Data) -> MasteringAnalysis.Result? {
    guard let settings = try? PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any],
      let data = settings["ongakuMasteringAnalysis"] as? Data
    else { return nil }
    return try? JSONDecoder().decode(MasteringAnalysis.Result.self, from: data)
  }
}
