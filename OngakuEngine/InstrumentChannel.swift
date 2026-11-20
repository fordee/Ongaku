//
//  InstrumentChannel.swift
//  OngakuEngine
//

import AVFAudio
import AudioToolbox
import OngakuCore

/// The instrument of a software instrument track, its MIDI effect plug-ins, and the queue
/// that feeds them MIDI:
///
///     MIDIEventQueue ─▶ MIDI effect plug-ins ─▶ instrument (sampler or Audio Unit) ─▶ channel input
///
/// (see `ChannelNodes` for the channel). Ongaku's own MIDI effects have already changed the
/// notes by then (see `PlaybackPlan` and `LiveMIDIEffects`).
@MainActor
final class InstrumentChannel {
  /// Apple's General MIDI sound bank, which the built-in sampler plays from.
  static let generalMIDIBankURL = URL(
    fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

  let queue = MIDIEventQueue()
  private(set) var instrument: AVAudioUnit?
  private(set) var source: InstrumentSource?
  /// Plays MIDI into the first MIDI effect plug-in, or the instrument if there are none.
  private(set) var scheduleMIDIEvent: AUScheduleMIDIEventBlock?
  /// The instrument's own, to silence it directly.
  private var instrumentScheduleMIDIEvent: AUScheduleMIDIEventBlock?
  /// The library file the sampler last loaded, to load again after the engine restarts.
  private var loadedSamplerFile: (url: URL, preset: SoundBankPreset?)?
  /// The instrument's render observer, and when it last rendered (recorded by the observer,
  /// as an instrument's `lastRenderTime` isn't always valid).
  private var observer: (token: Int, clock: RenderClock)?
  /// The instrument's format, which its MIDI effect plug-ins render at too.
  private var format: AVAudioFormat?

  /// MIDI effect plug-ins: those loaded, those wanted (in slot order, with their bypass),
  /// those still loading, and those the instrument's observer renders, in order.
  private var midiEffects: [(reference: PluginReference, renderer: MIDIEffectRenderer)] = []
  private var wantedMIDIEffects: [PluginReference] = []
  private var pendingMIDIEffects: [PluginReference.ID: Task<Void, Never>] = [:]
  private var renderedMIDIEffects: [MIDIEffectRenderer] = []
  private unowned let engine: AVAudioEngine
  private unowned let destination: AVAudioMixerNode
  /// What instruments are told about the song's tempo, position and transport.
  private let musicalContext: HostMusicalContext?

  init(engine: AVAudioEngine, destination: AVAudioMixerNode, musicalContext: HostMusicalContext? = nil) {
    self.engine = engine
    self.destination = destination
    self.musicalContext = musicalContext
  }

  // MARK: - Instrument

  /// Whether loading `source` needs to wait for a plug-in to start up.
  static func loadsAsynchronously(_ source: InstrumentSource?) -> Bool {
    switch source {
    case .audioUnit, .sampler: true
    default: false
    }
  }

  /// Loads a built-in instrument (or none), replacing the current one. This is quick, so it
  /// happens straight away and new tracks can play immediately.
  func loadBuiltIn(_ newSource: InstrumentSource?, format: AVAudioFormat) throws {
    precondition(!Self.loadsAsynchronously(newSource), "Audio Units load with load(_:format:)")
    guard !Self.isSameInstrument(newSource, source) || (instrument == nil && newSource != nil) else { return }
    source = newSource

    loadedSamplerFile = nil
    switch newSource {
    case .generalMIDI, .generalMIDIPercussion:
      try loadSoundBank(newSource, into: reuseOrCreateSampler(format: format))
    case nil, .audioUnit, .sampler:
      removeInstrument()
    }
  }

  /// Loads the General MIDI sound again. `AVAudioUnitSampler` forgets its sound bank
  /// instrument whenever the engine is stopped and restarted, and falls back to its default
  /// tone, so call this after every restart.
  func reloadSoundBank() throws {
    guard let sampler = instrument as? AVAudioUnitSampler else { return }
    if let file = loadedSamplerFile {
      // Library instruments can be large: load them again off the main thread.
      let unit = sampler
      Task.detached { try? Self.loadFile(file.url, preset: file.preset, into: unit) }
      return
    }
    try loadSoundBank(source, into: sampler)
  }

  /// Loads a library file into Apple's sampler: a SoundFont or DLS bank's preset, or a whole
  /// EXS instrument or Audio Unit preset.
  nonisolated private static func loadFile(_ url: URL, preset: SoundBankPreset?, into sampler: AVAudioUnitSampler) throws {
    if let preset {
      let bankMSB = preset.isPercussion ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB
      // SoundFont kits are bank 128; the bank's low 7 bits select among melodic banks.
      let bankLSB = preset.isPercussion ? 0 : preset.bank & 0x7F
      try sampler.loadSoundBankInstrument(
        at: url, program: UInt8(clamping: preset.program), bankMSB: UInt8(bankMSB), bankLSB: UInt8(clamping: bankLSB))
    } else {
      try sampler.loadInstrument(at: url)
    }
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
    case nil, .audioUnit, .sampler:
      break
    }
  }

  /// Loads an Audio Unit instrument, replacing the current one. Plug-ins load out of
  /// process, so a misbehaving plug-in can't take the app down with it.
  func load(_ newSource: InstrumentSource, format: AVAudioFormat) async throws {
    if case .sampler(let library) = newSource {
      try await loadSampler(library, as: newSource, format: format)
      return
    }
    guard case .audioUnit(let plugin) = newSource else {
      try loadBuiltIn(newSource, format: format)
      return
    }
    guard !Self.isSameInstrument(newSource, source) || instrument == nil else { return }
    source = newSource

    let unit = try await ChannelNodes.instantiate(plugin)
    // The source may have changed again while the plug-in was loading.
    guard Self.isSameInstrument(source, newSource) else { return }
    if let state = plugin.state,
      let fullState = try? PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any]
    {
      unit.withAUAudioUnit { $0.fullState = fullState }
    }
    try install(unit, format: format)
  }

  /// Loads a sound library's instrument into Apple's sampler. The file is found by
  /// `SamplerInstrumentResolver` (the app knows where the libraries are), and read off the
  /// main thread, as big instruments take a while.
  private func loadSampler(_ library: SamplerInstrument, as newSource: InstrumentSource, format: AVAudioFormat) async throws {
    guard !Self.isSameInstrument(newSource, source) || instrument == nil else { return }
    source = newSource
    loadedSamplerFile = nil
    guard let resolve = SamplerInstrumentResolver.resolve else { throw EngineError.missingSamplerInstrument(library) }
    let url = try await resolve(library)
    guard Self.isSameInstrument(source, newSource) else { return }
    let sampler = try reuseOrCreateSampler(format: format)
    let unit = sampler
    let preset = library.preset
    do {
      try await Task.detached { try Self.loadFile(url, preset: preset, into: unit) }.value
    } catch {
      throw EngineError.samplerInstrumentFailed(library, error)
    }
    guard Self.isSameInstrument(source, newSource) else { return }
    loadedSamplerFile = (url, preset)
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
    // The sampler plays big instruments (Logic's orchestral ones, say) from disk through a
    // request queue of fixed size, and Core Audio aborts the app when that overflows: many
    // voices at once did, even rendered at real-time speed. Loading the samples into memory
    // avoids it. This can only be set before the sampler is initialized, and it lasts.
    var streams: UInt32 = 0
    let status = sampler.withAudioUnit { (unit: borrowing AudioUnit) in
      AudioUnitSetProperty(unit, kMusicDeviceProperty_StreamFromDisk, kAudioUnitScope_Global, 0, &streams, UInt32(MemoryLayout<UInt32>.size))
    }
    if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    try install(sampler, format: format)
    return sampler
  }

  /// Connects an instrument at the output sample rate. Event sample times are counted in
  /// the instrument's own timeline, so a sampler left at its default 44.1 kHz on a 48 kHz
  /// device would drift late by about 4 ms per second.
  private func install(_ unit: AVAudioUnit, format: AVAudioFormat) throws {
    removeInstrument()
    if let musicalContext {
      unit.withAUAudioUnit { musicalContext.attach(to: $0) }
    }
    engine.attach(unit)
    do {
      try engine.connectNode(unit, to: destination, fromBus: 0, toBus: engine.freeInputBus(on: destination, for: unit), format: format)
    } catch {
      engine.detach(unit)
      throw error
    }
    guard let schedule = unit.withAUAudioUnit({ $0.scheduleMIDIEventBlock }) else {
      let name = unit.withAUAudioUnit { $0.audioUnitName } ?? "The plug-in"
      engine.detach(unit)
      throw EngineError.notAnInstrument(name)
    }
    instrumentScheduleMIDIEvent = schedule
    instrument = unit
    self.format = format
    renderedMIDIEffects = []
    connectMIDIEffects()
  }

  private func removeInstrument() {
    guard let instrument else { return }
    queue.flush()
    stopObserving(instrument)
    engine.detach(instrument)
    self.instrument = nil
    instrumentScheduleMIDIEvent = nil
    scheduleMIDIEvent = nil
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
    guard let observer, let format else { return nil }
    return observer.clock.sampleTime(atHostTime: hostTime, sampleRate: format.sampleRate)
  }

  /// When the instrument last rendered, in its sample timeline.
  var lastRenderSampleTime: Int64? {
    observer?.clock.lastRender()?.sampleTime
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
    // Through the MIDI effects (an arpeggiator lets go of its notes), and straight to the
    // instrument, in case an effect doesn't pass them on.
    var targets = [scheduleMIDIEvent]
    if !renderedMIDIEffects.isEmpty { targets.append(instrumentScheduleMIDIEvent) }
    for case let schedule? in targets {
      for channel: UInt8 in 0..<16 {
        for message: [UInt8] in [[0xB0 | channel, 64, 0], [0xB0 | channel, 123, 0], [0xE0 | channel, 0x00, 0x40]] {
          var bytes = message
          schedule(AUEventSampleTimeImmediate, 0, bytes.count, &bytes)
        }
      }
    }
  }

  func detach() {
    for task in pendingMIDIEffects.values {
      task.cancel()
    }
    pendingMIDIEffects = [:]
    removeInstrument()
    Self.retire(midiEffects.map(\.renderer))
    midiEffects = []
    renderedMIDIEffects = []
  }

  // MARK: - MIDI effect plug-ins

  /// The MIDI effect plug-ins playing into the instrument (those loaded and not bypassed).
  var playingMIDIEffectCount: Int { renderedMIDIEffects.count }

  /// Brings the MIDI effect plug-ins in line with the channel strip's (in slot order, each
  /// with its bypass): reuses loaded ones, loads new ones out of process, and plays those
  /// that aren't bypassed into the instrument, rendering at `format` in blocks of up to
  /// `maximumFrames`. Returns whether what plays changed now; it changes again as new ones
  /// finish loading, when `onInstalled` is called.
  @discardableResult
  func setMIDIEffects(
    _ references: [PluginReference], format: AVAudioFormat, maximumFrames: AUAudioFrameCount,
    onLoadFailure: @escaping (PluginReference, any Error) -> Void, onInstalled: @escaping () -> Void
  ) -> Bool {
    wantedMIDIEffects = references
    let wantedIDs = Set(references.map(\.id))
    for (id, task) in pendingMIDIEffects where !wantedIDs.contains(id) {
      task.cancel()
      pendingMIDIEffects[id] = nil
    }
    // Loaded at another rate (the output device changed): load again.
    let stale = midiEffects.filter { !wantedIDs.contains($0.reference.id) || $0.renderer.sampleRate != format.sampleRate }
    midiEffects.removeAll { effect in stale.contains { $0.renderer === effect.renderer } }
    for index in midiEffects.indices {
      guard let wanted = references.first(where: { $0.id == midiEffects[index].reference.id }) else { continue }
      if wanted.state != midiEffects[index].reference.state {
        Self.apply(wanted.state, to: midiEffects[index].renderer.unit)
      }
      midiEffects[index].reference = wanted
    }
    for reference in references where !midiEffects.contains(where: { $0.reference.id == reference.id }) {
      guard pendingMIDIEffects[reference.id] == nil else { continue }
      pendingMIDIEffects[reference.id] = Task { [weak self] in
        do {
          let unit = try await ChannelNodes.instantiate(reference)
          guard let self, !Task.isCancelled else { return }
          self.pendingMIDIEffects[reference.id] = nil
          try self.installMIDIEffect(unit, for: reference, format: format, maximumFrames: maximumFrames)
          if self.connectMIDIEffects() { onInstalled() }
        } catch {
          self?.pendingMIDIEffects[reference.id] = nil
          onLoadFailure(reference, error)
        }
      }
    }
    let changed = connectMIDIEffects()
    Self.retire(stale.map(\.renderer))
    return changed
  }

  private func installMIDIEffect(
    _ unit: AVAudioUnit, for reference: PluginReference, format: AVAudioFormat, maximumFrames: AUAudioFrameCount
  ) throws {
    if let musicalContext {
      unit.withAUAudioUnit { musicalContext.attach(to: $0) }
    }
    Self.apply(reference.state, to: unit)
    midiEffects.append((reference, try MIDIEffectRenderer(unit: unit, format: format, maximumFrames: maximumFrames)))
  }

  /// Plays the loaded MIDI effect plug-ins that aren't bypassed, in slot order, into the
  /// instrument: each one's MIDI goes to the next, and the queue's into the first. Returns
  /// whether that changed.
  @discardableResult
  private func connectMIDIEffects() -> Bool {
    guard let instrument else { return false }
    let playing = wantedMIDIEffects.filter { !$0.isBypassed }.compactMap { wanted in
      midiEffects.first { $0.reference.id == wanted.id }?.renderer
    }
    guard playing.map(ObjectIdentifier.init) != renderedMIDIEffects.map(ObjectIdentifier.init) || observer == nil else {
      return false
    }
    let instrumentList = instrument.withAUAudioUnit { $0.scheduleMIDIEventListBlock }
    for (index, effect) in playing.enumerated() {
      let next = playing.indices.contains(index + 1) ? playing[index + 1] : nil
      effect.sendOutput(
        toEvents: next.map(\.scheduleMIDIEvent) ?? instrumentScheduleMIDIEvent,
        eventLists: next.map(\.scheduleMIDIEventList) ?? instrumentList)
    }
    renderedMIDIEffects = playing
    observe(instrument, rendering: playing)
    return true
  }

  /// Before each render of the instrument: delivers the queue's events that are due, and
  /// renders the MIDI effect plug-ins, so the MIDI they play reaches it in the same cycle.
  private func observe(_ instrument: AVAudioUnit, rendering effects: [MIDIEffectRenderer]) {
    stopObserving(instrument)
    guard let first = instrumentScheduleMIDIEvent else { return }
    let schedule = effects.first?.scheduleMIDIEvent ?? first
    let queue = queue
    let clock = RenderClock()
    let token = instrument.withAUAudioUnit { audioUnit in
      audioUnit.token(byAddingRenderObserver: { flags, timestamp, frameCount, _ in
        guard flags.contains(.unitRenderAction_PreRender) else { return }
        clock.record(timestamp.pointee)
        queue.deliver(before: Int64(timestamp.pointee.mSampleTime) + Int64(frameCount), to: schedule)
        for effect in effects {
          effect.render(at: timestamp, frameCount: frameCount)
        }
      })
    }
    observer = (token, clock)
    scheduleMIDIEvent = schedule
  }

  private func stopObserving(_ instrument: AVAudioUnit) {
    if let observer {
      instrument.withAUAudioUnit { $0.removeRenderObserver(observer.token) }
    }
    observer = nil
  }

  /// Keeps plug-ins that stopped playing for a moment before letting them go: a render
  /// cycle that began before their observer was replaced may still be rendering them.
  private static func retire(_ renderers: [MIDIEffectRenderer]) {
    guard !renderers.isEmpty else { return }
    Task {
      try? await Task.sleep(for: .seconds(1))
      withExtendedLifetime(renderers) {}
    }
  }

  /// Gives a plug-in saved settings, unless it has them already (as it does when they came
  /// from its own window as it closed).
  private static func apply(_ state: Data?, to unit: AVAudioUnit) {
    guard let state, let fullState = try? PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any]
    else { return }
    let current = unit.withAUAudioUnit { $0.fullState }
    if let current, NSDictionary(dictionary: current).isEqual(to: fullState) { return }
    unit.withAUAudioUnit { $0.fullState = fullState }
  }

  /// Takes out the plug-in `matches` finds (its process quit), the instrument or a MIDI
  /// effect, so the next load puts it back. Returns it, if it's on this track.
  func removeQuitPlugin(where matches: (AVAudioUnit) -> Bool) -> PluginReference? {
    if let instrument, matches(instrument), case .audioUnit(let plugin) = source {
      invalidate()
      return plugin
    }
    guard let index = midiEffects.firstIndex(where: { matches($0.renderer.unit) }) else { return nil }
    let removed = midiEffects.remove(at: index)
    connectMIDIEffects()
    Self.retire([removed.renderer])
    return removed.reference
  }

  /// The node of a plug-in in the instrument's chain: the instrument itself, if it's that
  /// plug-in, or a loaded MIDI effect plug-in. For automation.
  func pluginNode(_ pluginID: PluginReference.ID) -> AVAudioNode? {
    if case .audioUnit(let plugin) = source, plugin.id == pluginID { return instrument }
    return midiEffects.first { $0.reference.id == pluginID }?.renderer.unit
  }

  /// Scoped access to a loaded MIDI effect plug-in, for its interface and saved settings.
  func withMIDIEffectAudioUnit<Result>(_ pluginID: PluginReference.ID, _ body: (borrowing AUAudioUnit) -> Result) -> Result? {
    midiEffects.first { $0.reference.id == pluginID }?.renderer.unit.withAUAudioUnit(body)
  }

  func midiEffectState(_ pluginID: PluginReference.ID) -> Data? {
    guard let fullState = withMIDIEffectAudioUnit(pluginID, { $0.fullState }) ?? nil else { return nil }
    return try? PropertyListSerialization.data(fromPropertyList: fullState, format: .binary, options: 0)
  }

  func isLoadingMIDIEffect(_ pluginID: PluginReference.ID) -> Bool {
    pendingMIDIEffects[pluginID] != nil
  }

  /// Waits until every MIDI effect plug-in that is loading has been installed (or has failed).
  func waitForPendingMIDIEffects() async {
    while let task = pendingMIDIEffects.values.first {
      await task.value
    }
  }
}

public enum EngineError: Error, LocalizedError {
  case notAnInstrument(String)
  /// A library instrument whose library (or file in it) can't be found.
  case missingSamplerInstrument(SamplerInstrument)
  case samplerInstrumentFailed(SamplerInstrument, any Error)
  /// A plug-in whose type, subtype or maker is missing (a damaged project, say).
  case incompletePlugin(String)

  public var errorDescription: String? {
    switch self {
    case .incompletePlugin(let name): "“\(name)” can’t be loaded: the project doesn’t say which plug-in it is."
    case .notAnInstrument(let name): "\(name) isn’t an instrument."
    case .missingSamplerInstrument(let instrument):
      "“\(instrument.path)” isn’t in your libraries. Add the “\(instrument.libraryName)” library in Settings › Libraries."
    case .samplerInstrumentFailed(_, let error):
      switch (error as NSError).code {
      // kAudioFileFileNotFoundError / fnfErr: samples the instrument needs weren't found.
      case -43:
        "Some of its samples weren’t found. Add the folder with its samples as a library in Settings › Libraries."
      // kAudioUnitErr_FormatNotSupported.
      case -10868:
        "Apple’s sampler can’t read this instrument: it may use something only Logic’s Sampler supports."
      default:
        error.localizedDescription
      }
    }
  }
}

/// Finds sound library instruments' files, for the engine to load. Set by the app, which
/// knows where the libraries are; it may also make a copy of an instrument pointing at
/// where its samples are now.
@MainActor
public enum SamplerInstrumentResolver {
  public static var resolve: ((SamplerInstrument) async throws -> URL)?
}

extension [MIDIEffect] {
  /// The MIDI effect plug-ins, in slot order, each with its slot's bypass: the instrument's
  /// MIDI chain.
  var pluginChain: [PluginReference] {
    compactMap { effect in
      guard var plugin = effect.plugin else { return nil }
      plugin.isBypassed = effect.isBypassed
      return plugin
    }
  }
}
