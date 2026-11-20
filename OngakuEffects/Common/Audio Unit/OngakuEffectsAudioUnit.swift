//
//  OngakuEffectsAudioUnit.swift
//  OngakuEffects
//

import AVFoundation
import OngakuCore

/// One of Ongaku's effects or instruments (which one depends on the subtype it was created
/// with), rendering through the C++ kernel. Instruments have no input; they play MIDI.
public class OngakuEffectsAudioUnit: AUAudioUnit, @unchecked Sendable {
  let effect: OngakuEffect

  // The C++ objects live at fixed addresses, because the render block holds references to
  // them.
  let kernel: UnsafeMutablePointer<OngakuEffectsDSPKernel>
  private let inputBus: UnsafeMutablePointer<BufferedInputBus>
  /// Where an instrument renders when the host gives it no buffers.
  private let outputBuffer: UnsafeMutablePointer<BufferedOutputBus>
  private var processHelper: AUProcessHelper?

  /// The output, mixed to mono, for analysers: a ring of samples and a running count of
  /// samples written (read it with `OngakuAnalyserWritten`).
  static let analyserCapacity = 16_384
  let analyserSamples: UnsafeMutablePointer<Float>
  let analyserWritten: UnsafeMutablePointer<UInt32>
  /// Levels for meters (see `OngakuMeter`; read them with `OngakuMeterValue`).
  let meters: UnsafeMutablePointer<Float>

  private var outputBus: AUAudioUnitBus
  /// The Session Drummer's song and part (nil for every other effect).
  private(set) var drummer: SessionDrummerController?
  private var _inputBusses: AUAudioUnitBusArray!
  private var _outputBusses: AUAudioUnitBusArray!

  @objc override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
    guard let effect = OngakuEffect(subType: componentDescription.componentSubType) else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioComponentErr_InstanceInvalidated))
    }
    self.effect = effect
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    outputBuffer = .allocate(capacity: 1)
    outputBuffer.initialize(to: BufferedOutputBus())
    outputBuffer.pointee.initialize(format, 8)
    outputBus = outputBuffer.pointee.bus!

    kernel = .allocate(capacity: 1)
    kernel.initialize(to: OngakuEffectsDSPKernel())
    kernel.pointee.setKind(effect.kind)
    inputBus = .allocate(capacity: 1)
    inputBus.initialize(to: BufferedInputBus())
    analyserSamples = .allocate(capacity: Self.analyserCapacity)
    analyserSamples.initialize(repeating: 0, count: Self.analyserCapacity)
    analyserWritten = .allocate(capacity: 1)
    analyserWritten.initialize(to: 0)
    kernel.pointee.setAnalyserTap(analyserSamples, UInt32(Self.analyserCapacity), analyserWritten)
    meters = .allocate(capacity: Int(OngakuMeter.count.rawValue))
    meters.initialize(repeating: 0, count: Int(OngakuMeter.count.rawValue))
    kernel.pointee.setMeters(meters)

    try super.init(componentDescription: componentDescription, options: options)

    inputBus.pointee.initialize(format, 8)
    _inputBusses = AUAudioUnitBusArray(
      audioUnit: self, busType: .input, busses: effect.isInstrument ? [] : [inputBus.pointee.bus!])
    _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
    processHelper = AUProcessHelper(&kernel.pointee, effect.isInstrument ? nil : inputBus, outputBuffer)
    setupParameterTree(effect.parameters.createAUParameterTree())
    if effect == .sessionDrummer {
      drummer = SessionDrummerController(kernel: kernel, meters: meters)
      loadDrummerKit()
    }
    // Its parameters start as its default preset.
    if let index = effect.defaultPreset {
      chosenPreset = factoryPresetList[index]
    }
  }

  deinit {
    drummer = nil
    if let impulse { ongaku.OngakuFreeImpulse(impulse) }
    kernel.deinitialize(count: 1)
    kernel.deallocate()
    inputBus.deinitialize(count: 1)
    inputBus.deallocate()
    outputBuffer.deinitialize(count: 1)
    outputBuffer.deallocate()
    analyserSamples.deallocate()
    analyserWritten.deallocate()
    meters.deallocate()
  }

  public override var inputBusses: AUAudioUnitBusArray { _inputBusses }

  public override var outputBusses: AUAudioUnitBusArray { _outputBusses }

  /// Effects: any number of channels in, the same number out. Instruments: none in, mono or
  /// stereo out (hosts expect a known layout from an instrument).
  public override var channelCapabilities: [NSNumber] { effect.isInstrument ? [0, 1, 0, 2] : [-1, -1] }

  public override var maximumFramesToRender: AUAudioFrameCount {
    get { kernel.pointee.maximumFramesToRender() }
    set { kernel.pointee.setMaximumFramesToRender(newValue) }
  }

  public override var shouldBypassEffect: Bool {
    get { kernel.pointee.isBypassed() }
    set { kernel.pointee.setBypass(newValue) }
  }

  public override var canProcessInPlace: Bool { !effect.isInstrument }

  /// The Session Drummer sends its part out as MIDI too, for hosts that route a plug-in's
  /// MIDI to another instrument.
  public override var midiOutputNames: [String] { effect == .sessionDrummer ? ["Drums"] : [] }

  public override var tailTime: TimeInterval { kernel.pointee.tailSeconds() }

  /// The Maximizer's look-ahead and the Convolution Reverb's block, for delay compensation.
  public override var latency: TimeInterval {
    let rate = outputBus.format.sampleRate
    return rate > 0 ? Double(kernel.pointee.latencySamples(rate)) / rate : 0
  }

  // MARK: - Playing from the interface

  /// Plays a note from the instrument's own keyboard (velocity 0 stops it).
  func playNote(_ note: Int, velocity: Int) {
    let note = UInt8(clamping: note), velocity = UInt8(clamping: velocity)
    kernel.pointee.queueInterfaceMIDI(velocity > 0 ? 0x90 : 0x80, note, velocity)
  }

  /// Every parameter's default by address, for resetting them.
  var parameterDefaults: [AUParameterAddress: AUValue] {
    defaults
  }

  // MARK: - The Sampler's zones

  /// What the Sampler's window shows about its zones and the selected one's sample.
  @MainActor lazy var samplerDisplay = SamplerDisplay()

  private let sampleLock = NSLock()
  private var zones: [SamplerZone] = []
  private var keymap: SamplerKeymapBuffer?
  /// Every sample a zone has had while the plug-in is open, so undo can bring back a zone
  /// that was removed or replaced.
  private var zoneLibrary: [UUID: SamplerSampleBuffer] = [:]

  /// A single sample (saved this way, as before zones, when it's the only zone and plays
  /// everywhere), and several zones.
  private static let sampleKey = "ongakuSample"
  private static let zonesKey = "ongakuZones"

  /// The Sampler's zones now.
  var samplerZones: [SamplerZone] {
    sampleLock.lock()
    defer { sampleLock.unlock() }
    return zones
  }

  /// Gives the Sampler a single sample over the whole keyboard (or none). Callable from any
  /// thread.
  func setSample(_ newSample: SamplerSampleBuffer?) {
    setZones(newSample.map { [SamplerZone(buffer: $0)] } ?? [])
  }

  /// Gives the Sampler its zones. Callable from any thread; notes playing a sample that's
  /// still in a zone play on.
  func setZones(_ newZones: [SamplerZone]) {
    let newKeymap = newZones.isEmpty ? nil : SamplerKeymapBuffer(zones: newZones)
    sampleLock.lock()
    let old = keymap
    zones = newZones
    keymap = newKeymap
    for zone in newZones { zoneLibrary[zone.id] = zone.buffer }
    kernel.pointee.setKeymap(newKeymap?.keymap)
    sampleLock.unlock()
    let infos = newZones.map { zone in
      SamplerZoneInfo(
        id: zone.id, name: zone.name, settings: zone.settings, duration: zone.buffer.duration,
        channelCount: zone.buffer.channels.count, overview: zone.buffer.preview, notice: zone.buffer.notice)
    }
    if Thread.isMainThread {
      MainActor.assumeIsolated { showZones(infos) }
    } else {
      DispatchQueue.main.async { MainActor.assumeIsolated { self.showZones(infos) } }
    }
    // The render thread may still be reading the old zones for the rest of its buffer.
    if let old {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withExtendedLifetime(old) {} }
    }
  }

  @MainActor
  private func showZones(_ infos: [SamplerZoneInfo]) {
    samplerDisplay.zones = infos
    if !infos.contains(where: { $0.id == samplerDisplay.selectedZoneID }) {
      samplerDisplay.selectedZoneID = infos.first?.id
    }
    showSelectedZone()
  }

  /// Shows a zone's sample on the waveform (and its playheads).
  @MainActor
  func selectZone(_ id: UUID?) {
    samplerDisplay.selectedZoneID = id
    showSelectedZone()
  }

  @MainActor
  private func showSelectedZone() {
    let selected = samplerDisplay.zones.first { $0.id == samplerDisplay.selectedZoneID }
    samplerDisplay.name = selected?.name
    samplerDisplay.duration = selected?.duration ?? 0
    samplerDisplay.channelCount = selected?.channelCount ?? 0
    samplerDisplay.overview = selected?.overview ?? []
    samplerDisplay.notice = selected?.notice
    sampleLock.lock()
    let shown = zones.first { $0.id == selected?.id }?.buffer.channels.first
    sampleLock.unlock()
    kernel.pointee.setShownSample(shown.map { UnsafePointer($0) })
  }

  /// Changes one zone's settings.
  func updateZone(_ id: UUID, _ change: (inout SamplerZoneSettings) -> Void) {
    var changed = samplerZones
    guard let index = changed.firstIndex(where: { $0.id == id }) else { return }
    var settings = changed[index].settings
    change(&settings)
    settings = settings.clamped()
    guard settings != changed[index].settings else { return }
    changed[index].settings = settings
    setZones(changed)
  }

  func removeZone(_ id: UUID) {
    setZones(samplerZones.filter { $0.id != id })
  }

  /// Spreads every zone across the keyboard from its root (see `SamplerZoneLayout.map`).
  func autoMapZones() {
    let current = samplerZones
    let knob = rootKnob
    let layout = SamplerZoneLayout.map(current.map { .init(root: $0.root(knob: knob), level: $0.buffer.peak) })
    setZones(zip(current, layout).map { zone, settings in
      var zone = zone
      var settings = settings
      (settings.tune, settings.gain, settings.pan) = (zone.settings.tune, zone.settings.gain, zone.settings.pan)
      zone.settings = settings
      return zone
    })
  }

  private var rootKnob: Int {
    Int((parameterTree?.parameter(withAddress: OngakuEffectsParameterAddress.splRoot.rawValue)?.value ?? 60).rounded())
  }

  // MARK: Loading samples

  /// Loads an audio file into the Sampler as its only sample, with its markers back at its
  /// ends and its root note set to the pitch it plays (when it has a clear one).
  @MainActor
  func loadSample(from url: URL) {
    loadSamples(from: [url], adding: false)
  }

  /// Loads audio files into the Sampler, reading them in the background.
  /// - One file, replacing: it plays over the whole keyboard, as a single sample always has.
  /// - Several, replacing: they're laid out across the keyboard by their pitch (see
  ///   `SamplerZoneLayout.map`), the markers back at their ends.
  /// - Adding: they're laid out among themselves, then fitted around the zones there.
  @MainActor
  func loadSamples(from urls: [URL], adding: Bool, completion: @escaping @MainActor () -> Void = {}) {
    guard !urls.isEmpty else { return }
    Task { @MainActor in
      let loaded = await Task.detached { Self.read(urls) }.value
      let buffers = loaded.compactMap(\.buffer)
      let failed = loaded.filter { $0.buffer == nil }.map(\.name)
      samplerDisplay.error = failed.isEmpty ? nil : failed.count == 1
        ? "“\(failed[0])” couldn’t be loaded." : "\(failed.count) files couldn’t be loaded: \(failed.joined(separator: ", "))."
      guard !buffers.isEmpty else { return }
      let tree = parameterTree
      if !adding {
        tree?.parameter(withAddress: OngakuEffectsParameterAddress.splStart.rawValue)?.value = 0
        tree?.parameter(withAddress: OngakuEffectsParameterAddress.splEnd.rawValue)?.value = 100
      }
      let roots = loaded.compactMap { $0.buffer == nil ? nil : $0.root }
      if !adding && buffers.count == 1 {
        tree?.parameter(withAddress: OngakuEffectsParameterAddress.splRoot.rawValue)?.value = AUValue(roots[0] ?? 60)
        setZones([SamplerZone(buffer: buffers[0])])
      } else {
        let existing = adding ? samplerZones : []
        var layout = SamplerZoneLayout.map(zip(buffers, roots).map { .init(root: $1, level: $0.peak) })
        if !existing.isEmpty { layout = SamplerZoneLayout.fit(layout, around: existing.map(\.settings)) }
        let added = zip(buffers, layout).map { SamplerZone(buffer: $0, settings: $1) }
        setZones(existing + added)
        if let first = added.first { selectZone(first.id) }
      }
      completion()
    }
  }

  private struct LoadedFile: @unchecked Sendable {
    let name: String
    let buffer: SamplerSampleBuffer?
    let root: Int?
  }

  /// Reads the files and finds the note each plays: by its pitch, else by its name.
  nonisolated private static func read(_ urls: [URL]) -> [LoadedFile] {
    urls.map { url in
      let isScoped = url.startAccessingSecurityScopedResource()
      defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
      guard let buffer = try? SamplerSampleBuffer(contentsOf: url) else {
        return LoadedFile(name: url.lastPathComponent, buffer: nil, root: nil)
      }
      return LoadedFile(
        name: url.lastPathComponent, buffer: buffer, root: buffer.detectedRootNote() ?? SamplerZoneLayout.root(fromName: buffer.name))
    }
  }

  /// Plays a zone's sample from another file, keeping where it plays.
  @MainActor
  func replaceSample(of id: UUID, from url: URL) {
    Task { @MainActor in
      let loaded = await Task.detached { Self.read([url]) }.value
      guard let buffer = loaded.first?.buffer else {
        samplerDisplay.error = "“\(url.lastPathComponent)” couldn’t be loaded."
        return
      }
      samplerDisplay.error = nil
      var changed = samplerZones
      guard let index = changed.firstIndex(where: { $0.id == id }) else { return }
      let replacement = SamplerZone(buffer: buffer, settings: changed[index].settings)
      changed[index] = replacement
      setZones(changed)
      selectZone(replacement.id)
    }
  }

  // MARK: Undo

  private struct ZoneRecord: Codable {
    var id: UUID
    var settings: SamplerZoneSettings
  }

  /// The zones (which samples, where) for the window's undo and A/B: the samples stay in
  /// `zoneLibrary`, so going back brings them back.
  var zoneMapping: Data {
    (try? JSONEncoder().encode(samplerZones.map { ZoneRecord(id: $0.id, settings: $0.settings) })) ?? Data()
  }

  func restoreZoneMapping(_ data: Data) {
    guard let records = try? JSONDecoder().decode([ZoneRecord].self, from: data) else { return }
    sampleLock.lock()
    let library = zoneLibrary
    sampleLock.unlock()
    setZones(records.compactMap { record in library[record.id].map { SamplerZone(id: record.id, buffer: $0, settings: record.settings) } })
  }

  /// The sample's audio (and a loaded impulse response) is saved with the rest of the
  /// settings.
  public override var fullState: [String: Any]? {
    get {
      var state = super.fullState ?? [:]
      if effect == .sampler {
        let zones = samplerZones
        // A single sample over the whole keyboard is saved as it was before zones, so
        // earlier versions still play it.
        if zones.count == 1, zones[0].settings.isWholeKeyboard {
          state[Self.sampleKey] = zones[0].buffer.state
        } else if !zones.isEmpty {
          state[Self.zonesKey] = zones.map(\.state)
        }
      }
      if effect == .convolutionReverb {
        sampleLock.lock()
        state[Self.impulseKey] = loadedImpulse?.state
        sampleLock.unlock()
      }
      if let drummer {
        state[SessionDrummerController.stateKey] = drummer.state
      }
      if effect == .mastering {
        state[Self.masteringAnalysisKey] = masteringAnalysisState
      }
      return state
    }
    set {
      super.fullState = newValue
      if effect == .sampler {
        if let saved = newValue?[Self.zonesKey] as? [[String: Any]] {
          setZones(saved.compactMap(SamplerZone.init(state:)))
        } else {
          setSample((newValue?[Self.sampleKey] as? [String: Any]).flatMap(SamplerSampleBuffer.init(state:)))
        }
      }
      if effect == .convolutionReverb {
        setLoadedImpulse((newValue?[Self.impulseKey] as? [String: Any]).flatMap(SamplerSampleBuffer.init(state:)))
      }
      if let drummer, let song = newValue?[SessionDrummerController.stateKey] as? Data {
        drummer.restore(song)
      }
      // Restored settings never start Mastering listening, and stopping here doesn't analyse
      // (that would put an earlier listen's settings over the ones restored).
      if effect == .mastering {
        kernel.pointee.setParameter(OngakuEffectsParameterAddress.mstListen.rawValue, 0)
        restoreMasteringAnalysis(newValue?[Self.masteringAnalysisKey] as? Data)
      }
    }
  }

  // MARK: - The Convolution Reverb's impulse response

  private static let impulseKey = "ongakuImpulse"
  /// Impulse responses are kept to 8 seconds: longer tails cost a lot to convolve and are
  /// rarely heard.
  static let maximumImpulseSeconds = 8.0
  /// An impulse response loaded from a file, played instead of the synthesized one.
  private var loadedImpulse: SamplerSampleBuffer?
  private var impulse: UnsafeMutablePointer<ongaku.ConvolutionImpulse>?
  private let impulseQueue = DispatchQueue(label: "net.4dware.Ongaku.OngakuEffects.impulse")
  private var impulseGeneration = 0

  /// What the Convolution Reverb's window shows about its impulse response.
  @MainActor lazy var impulseDisplay = SamplerDisplay()

  /// Uses an impulse response from a file (or the synthesized one again, with nil).
  func setLoadedImpulse(_ buffer: SamplerSampleBuffer?) {
    sampleLock.lock()
    loadedImpulse = buffer
    sampleLock.unlock()
    let overview = buffer?.overview(count: 600) ?? []
    let (name, duration, channelCount) = (buffer?.name, buffer?.duration ?? 0, buffer?.channels.count ?? 0)
    let notice = buffer?.notice
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        self.impulseDisplay.name = name
        self.impulseDisplay.duration = duration
        self.impulseDisplay.channelCount = channelCount
        self.impulseDisplay.overview = overview
        self.impulseDisplay.notice = notice
      }
    }
    rebuildImpulse(after: 0)
  }

  /// Loads an impulse response from an audio file.
  @MainActor
  func loadImpulse(from url: URL) {
    let isScoped = url.startAccessingSecurityScopedResource()
    defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
    do {
      setLoadedImpulse(try SamplerSampleBuffer(contentsOf: url, maximumSeconds: Self.maximumImpulseSeconds))
      impulseDisplay.error = nil
    } catch {
      impulseDisplay.error = "“\(url.lastPathComponent)” couldn’t be loaded: \(error.localizedDescription)"
    }
  }

  /// Builds the impulse response again (from the file, or from Decay, Size and Damping) on
  /// a background queue, after `delay` seconds so a knob being turned builds it once it
  /// settles, then hands it to the render thread.
  func rebuildImpulse(after delay: Double, waiting: Bool = false) {
    guard effect == .convolutionReverb else { return }
    sampleLock.lock()
    impulseGeneration += 1
    let generation = impulseGeneration
    sampleLock.unlock()
    if waiting {
      impulseQueue.sync { installImpulse(generation: generation) }
    } else {
      impulseQueue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.installImpulse(generation: generation) }
    }
  }

  /// Builds the impulse response and hands it to the render thread, unless a newer one has
  /// been asked for. On the impulse queue.
  private func installImpulse(generation: Int) {
    sampleLock.lock()
    let isCurrent = generation == impulseGeneration
    let file = loadedImpulse
    sampleLock.unlock()
    guard isCurrent else { return }
    let rate = outputBus.format.sampleRate > 0 ? outputBus.format.sampleRate : 44_100
    let built: UnsafeMutablePointer<ongaku.ConvolutionImpulse>?
    if let file {
      built = ongaku.OngakuMakeImpulse(
        file.channels[0], file.channels.count > 1 ? file.channels[1] : nil, Int64(file.frameCount), file.sampleRate, rate)
    } else {
      let value = { (address: OngakuEffectsParameterAddress) in self.kernel.pointee.getParameter(address.rawValue) }
      built = ongaku.OngakuSynthesizeImpulse(rate, value(.cnvDecay), value(.cnvSize), value(.cnvDamping))
    }
    sampleLock.lock()
    let old = impulse
    impulse = built
    kernel.pointee.setImpulse(built)
    sampleLock.unlock()
    // The render thread may still be convolving with the old one for a moment.
    if let old {
      impulseQueue.asyncAfter(deadline: .now() + 2) { ongaku.OngakuFreeImpulse(old) }
    }
  }

  // MARK: - The Session Drummer's kit

  /// Loads the Apple kit the Kit parameter chooses (or lets the Drum Machine play).
  private func loadDrummerKit(waiting: Bool = false) {
    guard let drummer else { return }
    let kit = Int(kernel.pointee.getParameter(OngakuEffectsParameterAddress.sdrKit.rawValue).rounded())
    let rate = outputBus.format.sampleRate > 0 ? outputBus.format.sampleRate : 44_100
    drummer.setKit(kit, sampleRate: rate, maximumFrames: maximumFramesToRender, waiting: waiting)
  }

  // MARK: - Mastering's Listen

  /// Set by Mastering's window while it's open, to apply a listen's settings as one
  /// undoable change (and say what was found); without it they're set directly.
  @MainActor var masteringListenFinished: ((MasteringAnalysisResult?) -> Void)?
  /// What Mastering's last listen found, for the window to show (saved with the settings).
  /// Hosts may save the settings from any thread, hence the lock.
  var masteringAnalysis: MasteringAnalysisResult? {
    get {
      analysisLock.lock()
      defer { analysisLock.unlock() }
      return storedAnalysis
    }
    set {
      analysisLock.lock()
      storedAnalysis = newValue
      analysisLock.unlock()
    }
  }
  private let analysisLock = NSLock()
  private var storedAnalysis: MasteringAnalysisResult?
  /// Whether Mastering's window shows its fine-tuning knobs, so it reopens as it was left.
  @MainActor var masteringShowsFineTune = false

  // MARK: - The Maximizer's loudness

  /// Starts the integrated loudness and true peak again.
  func resetLoudness() {
    kernel.pointee.resetLoudness()
  }

  // MARK: - Presets

  private lazy var factoryPresetList: [AUAudioUnitPreset] = effect.presets.enumerated().map { index, preset in
    let auPreset = AUAudioUnitPreset()
    auPreset.number = index
    auPreset.name = preset.name
    return auPreset
  }

  /// Every parameter's default, for presets that reset what they don't set.
  private lazy var defaults: [AUParameterAddress: AUValue] = {
    var values: [AUParameterAddress: AUValue] = [:]
    func collect(_ nodes: [NodeSpec]) {
      for node in nodes {
        if let parameter = node as? ParameterSpec { values[parameter.address] = parameter.defaultValue }
        if let group = node as? ParameterGroupSpec { collect(group.children) }
      }
    }
    collect(effect.parameters.children)
    return values
  }()

  private var chosenPreset: AUAudioUnitPreset?

  public override var factoryPresets: [AUAudioUnitPreset]? { factoryPresetList }

  /// The user's own presets, kept by the system and offered by hosts as well as in the
  /// plug-in's window.
  public override var supportsUserPresets: Bool { true }

  public override var currentPreset: AUAudioUnitPreset? {
    get { chosenPreset }
    set {
      guard let preset = newValue else {
        chosenPreset = nil
        return
      }
      if preset.number >= 0 {
        guard effect.presets.indices.contains(preset.number) else { return }
        let factory = effect.presets[preset.number]
        var values = factory.resetsOthers ? defaults : [:]
        values.merge(factory.values) { _, new in new }
        for (address, value) in values {
          parameterTree?.parameter(withAddress: address)?.value = value
        }
      } else {
        // One of the user's presets: the system keeps its saved state; apply it.
        if let state = try? presetState(for: preset) {
          fullStateForDocument = state
        }
        super.currentPreset = preset
      }
      chosenPreset = preset
    }
  }

  // MARK: - Rendering

  public override var internalRenderBlock: AUInternalRenderBlock {
    processHelper!.internalRenderBlock()
  }

  public override func allocateRenderResources() throws {
    let inputChannelCount = effect.isInstrument ? 0 : inputBusses[0].format.channelCount
    let outputChannelCount = outputBusses[0].format.channelCount
    // Effects keep the channel count they're given; instruments play mono or stereo only.
    if (!effect.isInstrument && outputChannelCount != inputChannelCount) || (effect.isInstrument && outputChannelCount > 2) {
      setRenderResourcesAllocated(false)
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FailedInitialization), userInfo: nil)
    }

    if effect.isInstrument {
      outputBuffer.pointee.allocateRenderResources(maximumFramesToRender)
    } else {
      inputBus.pointee.allocateRenderResources(maximumFramesToRender)
    }
    kernel.pointee.setMusicalContextBlock(musicalContextBlock)
    kernel.pointee.setTransportStateBlock(transportStateBlock)
    kernel.pointee.setMIDIOutput(effect == .sessionDrummer ? midiOutputEventBlock : nil)
    kernel.pointee.initialize(Int32(inputChannelCount), Int32(outputChannelCount), outputBus.format.sampleRate)
    processHelper?.setChannelCount(inputChannelCount, outputChannelCount)
    // The impulse response is built for the rate the reverb runs at, before it plays, and
    // the drummer's Apple kit is ready at this rate.
    rebuildImpulse(after: 0, waiting: true)
    loadDrummerKit(waiting: true)
    if effect == .tuner { startReportingPitch() }
    try super.allocateRenderResources()
  }

  public override func deallocateRenderResources() {
    pitchReporter?.cancel()
    pitchReporter = nil
    kernel.pointee.deInitialize()
    inputBus.pointee.deallocateRenderResources()
    outputBuffer.pointee.deallocateRenderResources()
    super.deallocateRenderResources()
  }

  // MARK: - Tuner

  private var pitchReporter: DispatchSourceTimer?

  /// The Tuner's pitch is found while it renders; a host (in another process) only learns a
  /// parameter has changed when the plug-in says so, so ten times a second it sets its
  /// read-only Frequency parameter to what the kernel heard.
  private func startReportingPitch() {
    pitchReporter?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: 0.1)
    timer.setEventHandler { [weak self] in
      guard let self, let parameter = parameterTree?.parameter(withAddress: OngakuEffectsParameterAddress.tunFrequency.rawValue)
      else { return }
      let heard = kernel.pointee.getParameter(parameter.address)
      if abs(heard - parameter.value) > 0.01 { parameter.setValue(heard, originator: nil) }
    }
    timer.resume()
    pitchReporter = timer
  }

  // MARK: - Parameters

  private func setupParameterTree(_ parameterTree: AUParameterTree) {
    self.parameterTree = parameterTree

    // The kernel starts with the defaults.
    for parameter in parameterTree.allParameters {
      kernel.pointee.setParameter(parameter.address, parameter.value)
    }

    let shapesImpulse = effect == .convolutionReverb
    let choosesKit = effect == .sessionDrummer
    let listens = effect == .mastering
    parameterTree.implementorValueObserver = { [kernel, weak self] parameter, value in
      kernel.pointee.setParameter(parameter.address, value)
      if listens, parameter.address == OngakuEffectsParameterAddress.mstListen.rawValue, value < 0.5 {
        DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishListening() } }
      }
      if shapesImpulse, ConvolutionReverbParameters.shapingAddresses.contains(parameter.address) {
        self?.rebuildImpulse(after: 0.15)
      }
      if choosesKit, parameter.address == OngakuEffectsParameterAddress.sdrKit.rawValue {
        self?.loadDrummerKit()
      }
    }
    parameterTree.implementorValueProvider = { [kernel] parameter in
      kernel.pointee.getParameter(parameter.address)
    }
    parameterTree.implementorStringFromValueCallback = { parameter, valuePointer in
      Self.string(
        for: valuePointer?.pointee ?? parameter.value, of: parameter.unit, valueStrings: parameter.valueStrings,
        unitName: parameter.unitName, address: parameter.address)
    }
  }

  /// A parameter's value as text ("−12.0 dB", "4.0 : 1", "1.50 kHz"). Custom units are
  /// named by `unitName` ("LUFS"); a few parameters (by `address`) have words for some values.
  static func string(
    for value: AUValue, of unit: AudioUnitParameterUnit, valueStrings: [String]?, unitName: String? = nil,
    address: AUParameterAddress? = nil
  ) -> String {
    if address == OngakuEffectsParameterAddress.mstLowEndMono.rawValue, value < MasteringParameters.lowEndMonoOff {
      return "Off"
    }
    if address == OngakuEffectsParameterAddress.mstMeasuredLoudness.rawValue, value <= MasteringParameters.notMeasured {
      // Short, so it fits the window's value field; the label says "Measured".
      return "Not yet"
    }
    switch unit {
    case .indexed:
      let strings = valueStrings ?? []
      let index = Int(value.rounded())
      return strings.indices.contains(index) ? strings[index] : "\(index)"
    case .boolean:
      return value >= 0.5 ? "On" : "Off"
    case .hertz:
      if value >= 1_000 { return String(format: "%.2f kHz", value / 1_000) }
      return value < 10 ? String(format: "%.2f Hz", value) : String(format: "%.0f Hz", value)
    case .cents:
      return String(format: "%+.0f ct", value)
    case .relativeSemiTones:
      return String(format: "%+.0f st", value)
    case .decibels:
      return String(format: "%+.1f dB", value)
    case .milliseconds:
      return value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    case .ratio:
      return String(format: "%.1f : 1", value)
    case .percent:
      return String(format: "%.0f %%", value)
    case .seconds:
      return String(format: "%.2f s", value)
    case .customUnit:
      return String(format: "%.1f ", value) + (unitName ?? "")
    case .midiNoteNumber:
      // Logic's octave numbering, as in Ongaku's Piano Roll: middle C (MIDI 60) is C3.
      let note = Int(value.rounded())
      let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
      return "\(names[((note % 12) + 12) % 12])\(note / 12 - 2)"
    default:
      return String(format: "%.2f", value)
    }
  }
}
