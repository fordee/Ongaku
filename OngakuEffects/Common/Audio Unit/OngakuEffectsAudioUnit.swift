//
//  OngakuEffectsAudioUnit.swift
//  OngakuEffects
//

import AVFoundation

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

  // MARK: - The Sampler's sample

  /// What the Sampler's window shows about its sample.
  @MainActor lazy var samplerDisplay = SamplerDisplay()

  private let sampleLock = NSLock()
  private var sample: SamplerSampleBuffer?

  private static let sampleKey = "ongakuSample"

  /// Gives the Sampler a sample (or none). Callable from any thread.
  func setSample(_ newSample: SamplerSampleBuffer?) {
    sampleLock.lock()
    let old = sample
    sample = newSample
    kernel.pointee.setSample(newSample?.kernelSample)
    sampleLock.unlock()
    let overview = newSample?.overview(count: 900) ?? []
    let (name, duration, channelCount) = (newSample?.name, newSample?.duration ?? 0, newSample?.channels.count ?? 0)
    let notice = newSample?.notice
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        self.samplerDisplay.name = name
        self.samplerDisplay.duration = duration
        self.samplerDisplay.channelCount = channelCount
        self.samplerDisplay.overview = overview
        self.samplerDisplay.notice = notice
      }
    }
    // The render thread may still be reading the old sample for the rest of its buffer.
    if let old {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withExtendedLifetime(old) {} }
    }
  }

  /// Loads an audio file into the Sampler, with its markers back at its ends and its root
  /// note set to the pitch it plays (when it has a clear one).
  @MainActor
  func loadSample(from url: URL) {
    let isScoped = url.startAccessingSecurityScopedResource()
    defer { if isScoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let loaded = try SamplerSampleBuffer(contentsOf: url)
      let tree = parameterTree
      tree?.parameter(withAddress: OngakuEffectsParameterAddress.splStart.rawValue)?.value = 0
      tree?.parameter(withAddress: OngakuEffectsParameterAddress.splEnd.rawValue)?.value = 100
      tree?.parameter(withAddress: OngakuEffectsParameterAddress.splRoot.rawValue)?.value = AUValue(loaded.detectedRootNote() ?? 60)
      setSample(loaded)
      samplerDisplay.error = nil
    } catch {
      samplerDisplay.error = "“\(url.lastPathComponent)” couldn’t be loaded: \(error.localizedDescription)"
    }
  }

  /// The sample's audio (and a loaded impulse response) is saved with the rest of the
  /// settings.
  public override var fullState: [String: Any]? {
    get {
      var state = super.fullState ?? [:]
      if effect == .sampler {
        sampleLock.lock()
        state[Self.sampleKey] = sample?.state
        sampleLock.unlock()
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
        setSample((newValue?[Self.sampleKey] as? [String: Any]).flatMap(SamplerSampleBuffer.init(state:)))
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
    try super.allocateRenderResources()
  }

  public override func deallocateRenderResources() {
    kernel.pointee.deInitialize()
    inputBus.pointee.deallocateRenderResources()
    outputBuffer.pointee.deallocateRenderResources()
    super.deallocateRenderResources()
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
