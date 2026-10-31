//
//  InstrumentChannel.swift
//  OngakuEngine
//

import AVFAudio
import AudioToolbox
import OngakuCore

/// The instrument of a software instrument track and the queue that feeds it MIDI:
///
///     MIDIEventQueue ─▶ instrument (sampler or Audio Unit) ─▶ channel input (see `ChannelNodes`)
@MainActor
final class InstrumentChannel {
  /// Apple's General MIDI sound bank, which the built-in sampler plays from.
  static let generalMIDIBankURL = URL(
    fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

  let queue = MIDIEventQueue()
  private(set) var instrument: AVAudioUnit?
  private(set) var source: InstrumentSource?
  private(set) var scheduleMIDIEvent: AUScheduleMIDIEventBlock?
  private var observerToken: Int?
  private unowned let engine: AVAudioEngine
  private unowned let destination: AVAudioMixerNode

  init(engine: AVAudioEngine, destination: AVAudioMixerNode) {
    self.engine = engine
    self.destination = destination
  }

  // MARK: - Instrument

  /// Whether loading `source` needs to wait for a plug-in to start up.
  static func loadsAsynchronously(_ source: InstrumentSource?) -> Bool {
    if case .audioUnit = source { return true }
    return false
  }

  /// Loads a built-in instrument (or none), replacing the current one. This is quick, so it
  /// happens straight away and new tracks can play immediately.
  func loadBuiltIn(_ newSource: InstrumentSource?, format: AVAudioFormat) throws {
    precondition(!Self.loadsAsynchronously(newSource), "Audio Units load with load(_:format:)")
    guard !Self.isSameInstrument(newSource, source) || (instrument == nil && newSource != nil) else { return }
    source = newSource

    switch newSource {
    case .generalMIDI, .generalMIDIPercussion:
      try loadSoundBank(newSource, into: reuseOrCreateSampler(format: format))
    case nil, .audioUnit:
      removeInstrument()
    }
  }

  /// Loads the General MIDI sound again. `AVAudioUnitSampler` forgets its sound bank
  /// instrument whenever the engine is stopped and restarted, and falls back to its default
  /// tone, so call this after every restart.
  func reloadSoundBank() throws {
    guard let sampler = instrument as? AVAudioUnitSampler else { return }
    try loadSoundBank(source, into: sampler)
  }

  private func loadSoundBank(_ source: InstrumentSource?, into sampler: AVAudioUnitSampler) throws {
    switch source {
    case .generalMIDI(let program):
      try sampler.loadSoundBankInstrument(
        at: Self.generalMIDIBankURL, program: UInt8(clamping: program),
        bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
    case .generalMIDIPercussion(let kit):
      try sampler.loadSoundBankInstrument(
        at: Self.generalMIDIBankURL, program: UInt8(clamping: kit),
        bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB))
    case nil, .audioUnit:
      break
    }
  }

  /// Loads an Audio Unit instrument, replacing the current one. Plug-ins load out of
  /// process, so a misbehaving plug-in can't take the app down with it.
  func load(_ newSource: InstrumentSource, format: AVAudioFormat) async throws {
    guard case .audioUnit(let plugin) = newSource else {
      try loadBuiltIn(newSource, format: format)
      return
    }
    guard !Self.isSameInstrument(newSource, source) || instrument == nil else { return }
    source = newSource

    let description = AudioComponentDescription(
      componentType: plugin.componentType, componentSubType: plugin.componentSubType,
      componentManufacturer: plugin.componentManufacturer, componentFlags: 0, componentFlagsMask: 0)
    let unit = try await AVAudioUnit.instantiate(with: description, options: [.loadOutOfProcess])
    // The source may have changed again while the plug-in was loading.
    guard Self.isSameInstrument(source, newSource) else { return }
    if let state = plugin.state,
      let fullState = try? PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any]
    {
      unit.withAUAudioUnit { $0.fullState = fullState }
    }
    try install(unit, format: format)
  }

  /// Whether two sources are the same instrument. A plug-in whose saved settings changed is
  /// still the same instrument: those changes came from the loaded plug-in itself, so it
  /// must not be reloaded.
  static func isSameInstrument(_ lhs: InstrumentSource?, _ rhs: InstrumentSource?) -> Bool {
    switch (lhs, rhs) {
    case (.audioUnit(let left), .audioUnit(let right)):
      left.id == right.id && left.componentType == right.componentType
        && left.componentSubType == right.componentSubType
        && left.componentManufacturer == right.componentManufacturer
    default:
      lhs == rhs
    }
  }

  /// Removes the instrument so the next `load` rebuilds it, for example after the output
  /// device's sample rate changed.
  func invalidate() {
    removeInstrument()
    source = nil
  }

  private func reuseOrCreateSampler(format: AVAudioFormat) throws -> AVAudioUnitSampler {
    if let sampler = instrument as? AVAudioUnitSampler {
      return sampler
    }
    let sampler = AVAudioUnitSampler()
    try install(sampler, format: format)
    return sampler
  }

  /// Connects an instrument at the output sample rate. Event sample times are counted in
  /// the instrument's own timeline, so a sampler left at its default 44.1 kHz on a 48 kHz
  /// device would drift late by about 4 ms per second.
  private func install(_ unit: AVAudioUnit, format: AVAudioFormat) throws {
    removeInstrument()
    engine.attach(unit)
    do {
      try engine.connectNode(unit, to: destination, fromBus: 0, toBus: engine.freeInputBus(on: destination, for: unit), format: format)
    } catch {
      engine.detach(unit)
      throw error
    }
    let queue = queue
    let connection = unit.withAUAudioUnit { audioUnit -> (AUScheduleMIDIEventBlock, Int)? in
      guard let schedule = audioUnit.scheduleMIDIEventBlock else { return nil }
      let token = audioUnit.token(
        byAddingRenderObserver: MIDIEventQueue.makeRenderObserver(queue: queue, schedule: schedule))
      return (schedule, token)
    }
    guard let (schedule, token) = connection else {
      let name = unit.withAUAudioUnit { $0.audioUnitName } ?? "The plug-in"
      engine.detach(unit)
      throw EngineError.notAnInstrument(name)
    }
    scheduleMIDIEvent = schedule
    observerToken = token
    instrument = unit
  }

  private func removeInstrument() {
    guard let instrument else { return }
    queue.flush()
    if let observerToken {
      instrument.withAUAudioUnit { $0.removeRenderObserver(observerToken) }
    }
    engine.detach(instrument)
    self.instrument = nil
    scheduleMIDIEvent = nil
    observerToken = nil
  }

  /// The instrument's saved state as a property list, for storing in the project.
  func capturedState() -> Data? {
    guard let fullState = instrument?.withAUAudioUnit({ $0.fullState }) else { return nil }
    return try? PropertyListSerialization.data(fromPropertyList: fullState, format: .binary, options: 0)
  }

  // MARK: - MIDI

  /// How much the instrument delays its sound, in samples at `sampleRate` (some plug-in
  /// instruments look ahead; Apple's sampler doesn't).
  func latency(atSampleRate sampleRate: Double) -> Int {
    guard let instrument else { return 0 }
    return Int((instrument.withAUAudioUnit { $0.latency } * sampleRate).rounded())
  }

  /// The instrument's sample time at a host time, from its most recent render.
  func sampleTime(atHostTime hostTime: UInt64) -> Int64? {
    instrument?.sampleTime(atHostTime: hostTime)
  }

  /// Queues an event to play at a host time.
  func schedule(_ bytes: [UInt8], atHostTime hostTime: UInt64) {
    guard let sampleTime = sampleTime(atHostTime: hostTime) else { return }
    queue.push(sampleTime: sampleTime, bytes: bytes)
  }

  /// Plays an event straight away, for MIDI keyboards and note previews.
  func playNow(_ bytes: [UInt8]) {
    guard let scheduleMIDIEvent, !bytes.isEmpty else { return }
    var bytes = bytes
    scheduleMIDIEvent(AUEventSampleTimeImmediate, 0, bytes.count, &bytes)
  }

  /// Drops queued events and silences sounding notes (all notes off and sustain off on
  /// every channel), and centres the pitch bend so notes played while stopped aren't bent.
  /// Other controllers are set again when playback next starts (see `PlaybackPlan`).
  func stopAllNotes() {
    queue.flush()
    for channel: UInt8 in 0..<16 {
      playNow([0xB0 | channel, 64, 0])
      playNow([0xB0 | channel, 123, 0])
      playNow([0xE0 | channel, 0x00, 0x40])
    }
  }

  func detach() {
    removeInstrument()
  }
}

public enum EngineError: Error, LocalizedError {
  case notAnInstrument(String)

  public var errorDescription: String? {
    switch self {
    case .notAnInstrument(let name): "\(name) isn’t an instrument."
    }
  }
}
