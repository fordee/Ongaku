//
//  PlaybackEngine.swift
//  OngakuEngine
//

import AVFAudio
import Foundation
import Observation
import OngakuCore

/// Finds the file on disk for an audio file in the project.
public typealias AudioFileLocator = @MainActor (AudioFileReference) -> URL?

/// Plays a project through `AVAudioEngine`: the transport, audio and instrument track
/// playback, the metronome, live MIDI and mixer updates.
///
/// Scheduling uses a look-ahead window. When playback starts, everything due in the next
/// couple of seconds is scheduled at exact sample times; a timer then keeps topping the
/// window up. What to schedule comes from `PlaybackPlan`, so this class only deals with
/// nodes and clocks. Audio regions are read ahead into each audio track's
/// `SampleChunkRing` (see `AudioTrackSource`); MIDI goes into each instrument's
/// `MIDIEventQueue`. Both hand things to the render thread only when they're due, so Stop
/// can drop whatever is queued, and nothing on the main thread waits for the audio thread.
///
/// The engine runs for as long as the window is open, so MIDI keyboards can play
/// instruments while the transport is stopped.
@MainActor
@Observable
public final class PlaybackEngine {
  public private(set) var isPlaying = false
  /// Whether the transport is recording onto record-enabled tracks.
  public internal(set) var isRecording = false
  /// Where the transport is. Updated about 30 times a second during playback.
  public private(set) var playheadPosition: Tick = .zero

  /// The song's tempo and position, for plug-ins that follow them.
  public let musicalContext = HostMusicalContext()
  public var isMetronomeEnabled = false {
    didSet { updateMetronomeVolume() }
  }
  /// Count-in, click and file format for recordings.
  @ObservationIgnored public var recordingOptions = RecordingOptions()
  /// The metronome's sound and level.
  @ObservationIgnored public var metronomeSettings = MetronomeSettings() {
    didSet {
      metronome?.configure(metronomeSettings)
      updateMetronomeVolume()
    }
  }
  /// The output device and buffer size last applied with `apply(_:)`.
  @ObservationIgnored public internal(set) var outputSettings = AudioOutputSettings()
  /// The most recent problem, for the UI to show.
  public private(set) var lastError: String?

  /// How far ahead of the playhead audio is scheduled, in seconds.
  private static let lookAhead = 2.0
  /// When the scheduled audio runs this short, the next window is scheduled.
  private static let refillThreshold = 1.0
  /// Delay between fixing the start time and the first sample: time for every instrument to
  /// have its first MIDI queued and every source to render once, so everything starts together.
  private static let startDelay = 0.05
  /// The longest Play waits for each track's first audio to be read.
  private static let primingLimit = DispatchTimeInterval.milliseconds(100)

  @ObservationIgnored let engine = AVAudioEngine()
  @ObservationIgnored private(set) var project: Project
  @ObservationIgnored private let locateAudioFile: AudioFileLocator
  /// Every track's mixer path, by track.
  @ObservationIgnored private var mixerChannels: [Track.ID: ChannelNodes] = [:]
  /// Stereo Out: every track's fader feeds its input; its plug-ins and fader are the last
  /// thing before the output. `nil` only if it couldn't be connected, when tracks feed the
  /// main mixer directly.
  @ObservationIgnored private var stereoOut: ChannelNodes?
  /// Plays audio input through the tracks that monitor it, while any do.
  @ObservationIgnored private var inputMonitor: InputMonitor?
  @ObservationIgnored private var isStartingInputMonitor = false
  /// Set when monitoring couldn't start, so it isn't retried on every edit; cleared when no
  /// track is monitoring.
  @ObservationIgnored private var inputMonitorFailed = false
  /// What plays audio tracks' regions, by track.
  @ObservationIgnored private var audioSources: [Track.ID: AudioTrackSource] = [:]
  /// Numbers runs of the transport, so sources can tell a new run's audio from an old one's.
  @ObservationIgnored private var sessionCount = 0
  /// How many nodes were attached after the last graph check. On a running engine, nodes
  /// connected below the main mixer's direct inputs stay uninitialized (a player then fails
  /// with error -10867) until the engine restarts, so a growing graph triggers a restart.
  @ObservationIgnored private var attachedNodeCount = 0
  /// Peak levels for the mixer's meters.
  @ObservationIgnored public let meters = LevelMeters()
  @ObservationIgnored private(set) var instruments: [Track.ID: InstrumentChannel] = [:]
  @ObservationIgnored private var instrumentLoads: [Track.ID: Task<Void, Never>] = [:]
  /// The tracks MIDI keyboards play, layered, while this engine's window is frontmost.
  @ObservationIgnored private(set) var midiInputTrackIDs: [Track.ID] = []
  /// The MIDI effects of those tracks that have any, each playing the keyboard live on its
  /// own track.
  @ObservationIgnored private(set) var liveEffects: [Track.ID: LiveMIDIEffects] = [:]
  @ObservationIgnored private(set) var metronome: Metronome?
  @ObservationIgnored private var openFiles: [AudioFileReference.ID: AVAudioFile] = [:]
  @ObservationIgnored private(set) var session: Session?
  @ObservationIgnored private var tickerTask: Task<Void, Never>?
  /// The takes being written while recording.
  @ObservationIgnored var recordingSession: RecordingSession?
  /// Where recorded audio files are written; the app points this at the document's
  /// staging folder.
  @ObservationIgnored public var recordingDirectory: URL?
  /// Called on the main actor with each finished recording, for the app to add to the project.
  @ObservationIgnored public var onRecordingFinished: (@MainActor (RecordingResult) -> Void)?
  @ObservationIgnored private var configurationTask: Task<Void, Never>?
  /// Plug-in delay compensation for the current routing and plug-ins (see `DelayCompensation`).
  @ObservationIgnored private(set) var compensation = DelayCompensation()

  /// How late the whole mix is because of plug-in latency, in seconds: what's heard lags
  /// what's scheduled by this much.
  var compensationSeconds: Double {
    Double(compensation.mixLatency) / instrumentFormat.sampleRate
  }

  /// State for one run of the transport.
  struct Session {
    var id: Int
    var plan: PlaybackPlan
    var startHostTime: UInt64
    /// Playback time up to which audio has been scheduled.
    var scheduledUntil: Double
    /// Whether this run records (it may begin with a count-in).
    var isRecording = false
    /// The plug-in delay compensation latency when the run started, in seconds.
    var latency: Double = 0
  }

  public init(project: Project, locateAudioFile: @escaping AudioFileLocator) {
    self.project = project.playingFreezeFiles { Self.exists($0, locateAudioFile) }
    self.locateAudioFile = locateAudioFile
    isMetronomeEnabled = project.isMetronomeEnabled

    if let metronome = Metronome(format: instrumentFormat) {
      engine.attach(metronome.node)
      do {
        try engine.connectNode(metronome.node, to: engine.mainMixerNode, format: metronome.format)
        metronome.volume = 0
        self.metronome = metronome
      } catch {
        engine.detach(metronome.node)
        lastError = "The metronome couldn’t be connected: \(error.localizedDescription)"
      }
    }
    do {
      stereoOut = try ChannelNodes(engine: engine, format: instrumentFormat, musicalContext: musicalContext)
    } catch {
      lastError = "Stereo Out couldn’t be connected: \(error.localizedDescription)"
    }
    syncChannels()
    // Observers don't run in the initializer: a song saved with the metronome on clicks.
    updateMetronomeVolume()
    meters.meter(stereoOut?.fader ?? engine.mainMixerNode, as: LevelMeters.masterID)
    observeConfigurationChanges()
    startEngineIfNeeded()
  }

  /// The output device's sample rate, which freeze files are rendered at.
  public var outputSampleRate: Double { instrumentFormat.sampleRate }

  /// The format instruments render in: stereo at the output device's sample rate.
  private var instrumentFormat: AVAudioFormat {
    let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
    return AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 2)
      ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
  }

  @discardableResult
  func startEngineIfNeeded() -> Bool {
    guard !engine.isRunning else { return true }
    do {
      engine.prepare()
      try engine.start()
      return true
    } catch {
      lastError = "The audio output couldn’t start: \(error.localizedDescription)"
      return false
    }
  }

  /// Stops and starts the engine, for graph changes that need it. The samplers lose their
  /// General MIDI sounds when the engine restarts, so they're loaded again afterwards.
  /// `whileStopped` runs between stopping and starting.
  func restartEngine(whileStopped: () -> Void = {}) {
    engine.stop()
    whileStopped()
    startEngineIfNeeded()
    for (trackID, instrument) in instruments {
      do {
        try instrument.reloadSoundBank()
      } catch {
        let name = project.track(withID: trackID)?.name ?? "A track"
        lastError = "The instrument on “\(name)” couldn’t be reloaded: \(error.localizedDescription)"
      }
    }
  }

  /// Stops playback and releases the audio hardware. Call when the document window closes.
  public func shutDown() {
    stop()
    configurationTask?.cancel()
    if !midiInputTrackIDs.isEmpty {
      connectMIDIInput(toTracks: [])
    }
    for load in instrumentLoads.values {
      load.cancel()
    }
    engine.stop()
  }

  // MARK: - Transport

  /// Audio frames, across every audio track, that were due before they had been read and
  /// so weren't heard. Should stay 0; for tests and diagnostics.
  var missedAudioFrames: Int {
    audioSources.values.reduce(0) { $0 + $1.ring.missedFrames }
  }

  public func togglePlayback() {
    isPlaying ? stop() : play()
  }

  public func play() {
    startPlayback(from: playheadPosition)
  }

  public func stop() {
    tickerTask?.cancel()
    tickerTask = nil
    if recordingSession != nil {
      finishRecording()
    }
    session = nil
    for source in audioSources.values {
      source.end()
    }
    for channel in mixerChannels.values {
      channel.flushAutomation()
    }
    applyAutomation(at: playheadPosition)
    for instrument in instruments.values {
      instrument.stopAllNotes()
    }
    metronome?.end()
    isPlaying = false
    updateMetronomeVolume()
  }

  /// Moves the playhead. During playback, playback continues from the new position.
  public func locate(to position: Tick) {
    let clamped = max(.zero, position)
    if isRecording {
      // Moving the playhead ends the take rather than splicing two positions into one file.
      stop()
      playheadPosition = clamped
    } else if isPlaying {
      startPlayback(from: clamped)
    } else {
      playheadPosition = clamped
      applyAutomation(at: clamped)
    }
  }

  // MARK: - Project updates

  /// Whether a freeze file can be found; a frozen track whose file is missing plays as if
  /// it weren't frozen.
  static func exists(_ file: AudioFileReference, _ locate: AudioFileLocator) -> Bool {
    locate(file).map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
  }

  /// Applies an edited project. Mixer changes take effect immediately; arrangement changes
  /// during playback restart playback from the current position so the change is heard.
  /// Frozen tracks play their freeze files (see `Project.playingFreezeFiles`).
  public func update(project edited: Project) {
    let newProject = edited.playingFreezeFiles { Self.exists($0, locateAudioFile) }
    let arrangementChanged = Arrangement(newProject) != Arrangement(project)
    let automationChanged = newProject.tracks.map(\.automation) != project.tracks.map(\.automation)
      || newProject.tracks.map(\.automationMode) != project.tracks.map(\.automationMode)
    project = newProject
    if isMetronomeEnabled != newProject.isMetronomeEnabled {
      isMetronomeEnabled = newProject.isMetronomeEnabled
    }
    let latencyChanged = syncChannels()
    if latencyChanged, !arrangementChanged, isPlaying, !isRecording {
      // The mix's delay changed (a plug-in was added, say): restart so everything lines up.
      startPlayback(from: playheadPosition)
    } else if automationChanged, !arrangementChanged, isPlaying {
      // Automation edits (including what Touch and Latch just wrote) take effect from the
      // playhead without restarting playback.
      rescheduleAutomation()
    }
    if arrangementChanged {
      // Files may have been added or replaced; reopen them on demand.
      openFiles = openFiles.filter { id, _ in newProject.audioFile(withID: id) != nil }
      // Restarting would cut a take short, so edits made while recording are heard once
      // recording stops.
      if isPlaying, !isRecording {
        startPlayback(from: playheadPosition)
      }
    }
  }

  /// The parts of a project that affect what is scheduled (as opposed to how it is mixed).
  private struct Arrangement: Equatable {
    var tracks: [[Region]]
    var trackKinds: [TrackKind]
    /// MIDI effects change which notes play, so changing them plans playback again.
    var midiEffects: [[MIDIEffect]]
    var tempoMap: TempoMap
    var cycle: CycleRange
    var endPosition: Tick
    var audioFiles: [AudioFileReference]

    init(_ project: Project) {
      tracks = project.tracks.map(\.regions)
      trackKinds = project.tracks.map(\.kind)
      midiEffects = project.tracks.map(\.channel.midiEffects)
      tempoMap = project.tempoMap
      cycle = project.cycle
      endPosition = project.endPosition
      audioFiles = project.audioFiles
    }
  }

  /// Creates and removes nodes to match the project's tracks, then applies mix settings,
  /// inserts and sends. Returns whether the plug-in delay compensation latency changed.
  @discardableResult
  private func syncChannels() -> Bool {
    let trackIDs = Set(project.tracks.map(\.id))
    for (trackID, channel) in mixerChannels where !trackIDs.contains(trackID) {
      audioSources[trackID]?.detach()
      audioSources[trackID] = nil
      instrumentLoads[trackID]?.cancel()
      instrumentLoads[trackID] = nil
      instruments[trackID]?.detach()
      instruments[trackID] = nil
      meters.stopMetering(channel.fader, as: trackID)
      channel.detach()
      mixerChannels[trackID] = nil
    }

    for track in project.tracks {
      do {
        let channel: ChannelNodes
        if let existing = mixerChannels[track.id] {
          channel = existing
        } else {
          channel = try ChannelNodes(
            engine: engine, format: instrumentFormat, musicalContext: musicalContext, mainOutput: stereoOut?.input)
          mixerChannels[track.id] = channel
          meters.meter(channel.fader, as: track.id)
        }
        channel.applyMix(
          track.channel, isAudible: project.isTrackAudible(track.id),
          automated: Set(track.automatedParameters.filter(track.isAutomated)))
        let trackName = track.name
        channel.setInserts(track.channel.inserts) { [weak self] plugin, error in
          self?.lastError = "“\(plugin.name)” on “\(trackName)” couldn’t be loaded: \(error.localizedDescription)"
        } onInstalled: { [weak self] in
          // The plug-in's latency is known now.
          self?.latencyMayHaveChanged()
          self?.initializeNewNodes()
        }
        syncSource(of: track, into: channel)
      } catch {
        lastError = "“\(track.name)” couldn’t be connected to the mixer: \(error.localizedDescription)"
      }
    }

    stereoOut?.setInserts(project.stereoOutInserts) { [weak self] plugin, error in
      self?.lastError = "“\(plugin.name)” on Stereo Out couldn’t be loaded: \(error.localizedDescription)"
    } onInstalled: { [weak self] in
      self?.latencyMayHaveChanged()
      self?.initializeNewNodes()
    }

    musicalContext.update(at: playheadPosition, in: project.tempoMap)
    let latencyChanged = applyRouting()
    masterFader.outputVolume = Float(project.masterLinearGain)
    if !isPlaying {
      applyAutomation(at: playheadPosition)
    }
    refreshMIDIInput()
    syncInputMonitoring()
    initializeNewNodes()
    return latencyChanged
  }

  /// Disconnects input monitoring and connects it again from scratch, after a device change.
  func resetInputMonitoring() {
    inputMonitor?.detach()
    inputMonitor = nil
    inputMonitorFailed = false
    syncInputMonitoring()
  }

  /// Connects audio input to the tracks that monitor it. The first time, this asks for
  /// permission to use the input and turns it on, which restarts the engine. With no track
  /// monitoring, the input is let go.
  private func syncInputMonitoring() {
    let monitored = project.tracks.compactMap { track -> (id: Track.ID, input: AudioInputSelection, destination: AVAudioMixerNode)? in
      guard track.kind == .audio, track.isInputMonitored, !track.isFrozen, let channel = mixerChannels[track.id] else { return nil }
      return (track.id, track.channel.audioInput ?? .defaultInput, channel.input)
    }
    guard !monitored.isEmpty else {
      inputMonitor?.detach()
      inputMonitor = nil
      inputMonitorFailed = false
      return
    }
    if let inputMonitor {
      inputMonitor.monitor(monitored)
      return
    }
    guard !isStartingInputMonitor, !inputMonitorFailed else { return }
    isStartingInputMonitor = true
    Task { [weak self] in
      let isAllowed = await AVAudioApplication.requestRecordPermission()
      guard let self else { return }
      isStartingInputMonitor = false
      guard isAllowed else {
        inputMonitorFailed = true
        lastError = RecordingError.microphoneAccessDenied.localizedDescription
        return
      }
      _ = prepareInput()
      do {
        inputMonitor = try InputMonitor(engine: engine, format: instrumentFormat)
      } catch {
        inputMonitorFailed = true
        lastError = "Input monitoring couldn’t start: \(error.localizedDescription)"
        return
      }
      syncInputMonitoring()
      initializeNewNodes()
    }
  }

  /// Works out plug-in delay compensation from the instruments' and inserts' latency and
  /// wires every channel's output and sends with it, once every channel exists (a send may
  /// target a track added later). Returns whether the mix's overall delay changed.
  private func applyRouting() -> Bool {
    let rate = instrumentFormat.sampleRate
    var latencies: [Track.ID: DelayCompensation.Latency] = [:]
    for track in project.tracks {
      latencies[track.id] = DelayCompensation.Latency(
        source: instruments[track.id]?.latency(atSampleRate: rate) ?? 0, inserts: mixerChannels[track.id]?.insertLatency ?? 0)
    }
    var plan = DelayCompensation(project: project, latencies: latencies)
    plan.stereoOutLatency = stereoOut?.insertLatency ?? 0
    let changed = plan.mixLatency != compensation.mixLatency
    compensation = plan

    let auxInputs = mixerChannels.filter { id, _ in project.track(withID: id)?.kind == .aux }.mapValues(\.input)
    for track in project.tracks {
      guard let channel = mixerChannels[track.id] else { continue }
      do {
        let routing = ChannelNodes.Routing(
          sends: track.channel.sends, output: track.channel.output, automatedSends: track.automatedSends)
        try channel.applyRouting(routing.compensated(by: plan, for: track.id), auxInputs: auxInputs)
        // Send and plug-in automation needs its nodes' timelines before playback starts.
        channel.prepareAutomation(for: Set(track.automatedParameters.filter(track.isAutomated)))
      } catch {
        lastError = "The sends on “\(track.name)” couldn’t be connected: \(error.localizedDescription)"
      }
    }
    return changed
  }

  /// A plug-in finished loading, so its latency is known: compensate for it, restarting
  /// playback if the mix's delay changed.
  private func latencyMayHaveChanged() {
    if applyRouting(), isPlaying, !isRecording {
      startPlayback(from: playheadPosition)
    }
  }

  /// Sets automated parameters to their values at a position, for when the transport is
  /// stopped (playback schedules them as it goes).
  private func applyAutomation(at position: Tick) {
    for track in project.tracks {
      guard let channel = mixerChannels[track.id] else { continue }
      for parameter in track.automatedParameters where track.isAutomated(parameter) {
        channel.setAutomatedValue(parameter, to: track.automatedValue(of: parameter, at: position))
      }
    }
  }

  /// Restarts the engine if nodes were attached since the last check, so they render. Done
  /// as soon as the graph changes (rather than when Play is pressed) so instruments have
  /// valid render times again before any MIDI is scheduled. If the transport was running,
  /// playback resumes from the same place a moment later.
  private func initializeNewNodes() {
    let count = engine.attachedNodes.count
    defer { attachedNodeCount = engine.attachedNodes.count }
    guard count > attachedNodeCount, engine.isRunning, attachedNodeCount > 0 else { return }
    let resumePosition = isPlaying && !isRecording ? playheadPosition : nil
    if resumePosition != nil {
      stop()
    }
    restartEngine()
    if let resumePosition {
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(100))
        self?.startPlayback(from: resumePosition)
      }
    }
  }

  /// Sets up what feeds a channel: a sample source for audio tracks, the instrument for
  /// instrument tracks, nothing extra for aux tracks (their sends arrive at the input).
  /// A track's kind changes when it's frozen (it plays its freeze file as audio) or
  /// unfrozen, so a source of the wrong kind is removed first.
  private func syncSource(of track: Track, into channel: ChannelNodes) {
    if track.kind != .audio, let source = audioSources.removeValue(forKey: track.id) {
      source.detach()
    }
    if track.kind != .softwareInstrument, let instrument = instruments.removeValue(forKey: track.id) {
      instrumentLoads.removeValue(forKey: track.id)?.cancel()
      instrument.detach()
    }
    switch track.kind {
    case .audio:
      if audioSources[track.id] == nil {
        do {
          audioSources[track.id] = try AudioTrackSource(
            engine: engine, destination: channel.input, format: instrumentFormat
          ) { [weak self] message in
            // Reported from the reader's queue.
            let engine = self
            Task { @MainActor in engine?.lastError = message }
          }
        } catch {
          lastError = "“\(track.name)” couldn’t be connected to the mixer: \(error.localizedDescription)"
        }
      }
    case .softwareInstrument:
      let instrument = instruments[track.id] ?? InstrumentChannel(engine: engine, destination: channel.input)
      instruments[track.id] = instrument
      let wanted = track.channel.instrument
      // Reload when the instrument changed, or when it's missing and not already loading
      // (an Audio Unit has no node until it finishes loading).
      let isMissing = instrument.instrument == nil && wanted != nil && instrumentLoads[track.id] == nil
      if !InstrumentChannel.isSameInstrument(instrument.source, wanted) || isMissing {
        loadInstrument(wanted, into: instrument, for: track)
      }
    case .aux:
      break
    }
  }

  // MARK: - Live mixer changes

  /// Moves a fader without changing the project, while it's being dragged. The final value
  /// is committed with an edit command.
  public func setLiveVolume(_ decibels: Double, forTrack trackID: Track.ID) {
    guard project.isTrackAudible(trackID) else { return }
    mixerChannels[trackID]?.setLiveVolume(decibels)
  }

  /// Moves a control by hand: an automated one is set directly (and should be overriding
  /// its automation, see `setAutomationOverride`), any other one like `setLiveVolume`.
  public func setLiveValue(_ parameter: AutomationParameter, _ value: Double, onTrack trackID: Track.ID) {
    guard let track = project.track(withID: trackID), let channel = mixerChannels[trackID] else { return }
    if track.isAutomated(parameter) {
      channel.setAutomatedValue(parameter, to: value)
    } else {
      switch parameter {
      case .volume: setLiveVolume(value, forTrack: trackID)
      case .pan: channel.fader.pan = Float(value)
      case .sendLevel, .plugin: channel.setAutomatedValue(parameter, to: value)
      }
    }
  }

  /// While a control is held during Touch or Latch, its automation stops playing so the
  /// hand wins; afterwards playback follows the automation again.
  public func setAutomationOverride(_ isOverriding: Bool, for parameter: AutomationParameter, onTrack trackID: Track.ID) {
    mixerChannels[trackID]?.automation(for: parameter)?.isSuspended = isOverriding
  }

  public func setLiveMasterVolume(_ decibels: Double) {
    masterFader.outputVolume = decibels <= ChannelStrip.volumeRange.lowerBound ? 0 : Float(pow(10, decibels / 20))
  }

  /// The Stereo Out fader.
  private var masterFader: AVAudioMixerNode { stereoOut?.fader ?? engine.mainMixerNode }

  /// A channel strip's nodes: a track's, or Stereo Out's for `Project.stereoOutID`.
  private func channel(for channelID: Track.ID) -> ChannelNodes? {
    channelID == Project.stereoOutID ? stereoOut : mixerChannels[channelID]
  }

  // MARK: - Plug-ins on channel strips

  /// Scoped access to a track's insert plug-in, for its interface.
  public func withInsertAudioUnit<Result>(
    _ pluginID: PluginReference.ID, onTrack trackID: Track.ID, _ body: (borrowing AUAudioUnit) -> Result
  ) -> Result? {
    channel(for: trackID)?.withInsertAudioUnit(pluginID, body)
  }

  /// The parameters of an insert that automation can drive, with where each is now (0…1),
  /// for the automation lane's menu.
  public func automatableParameters(ofInsert pluginID: PluginReference.ID, onTrack trackID: Track.ID) -> [PluginParameter] {
    withInsertAudioUnit(pluginID, onTrack: trackID) { unit in
      (unit.parameterTree?.allParameters ?? []).compactMap { parameter -> PluginParameter? in
        guard parameter.flags.contains(.flag_IsWritable), parameter.maxValue > parameter.minValue else { return nil }
        let fraction = Double((parameter.value - parameter.minValue) / (parameter.maxValue - parameter.minValue))
        return PluginParameter(pluginID: pluginID, address: parameter.address, name: parameter.displayName, initialValue: fraction)
      }
    } ?? []
  }

  /// How one of an insert's parameters reads, for showing its automation in real units;
  /// `nil` while the plug-in isn't loaded.
  public func valueFormat(of parameter: PluginParameter, onTrack trackID: Track.ID) -> PluginValueFormat? {
    withInsertAudioUnit(parameter.pluginID, onTrack: trackID) { unit in
      unit.parameterTree?.parameter(withAddress: parameter.address).map(PluginValueFormat.init)
    } ?? nil
  }

  public func isLoadingInsert(_ pluginID: PluginReference.ID, onTrack trackID: Track.ID) -> Bool {
    channel(for: trackID)?.isLoadingInsert(pluginID) ?? false
  }

  /// An insert's current settings, to store after the person changes them.
  public func insertState(_ pluginID: PluginReference.ID, onTrack trackID: Track.ID) -> Data? {
    channel(for: trackID)?.insertState(pluginID)
  }

  func loadInstrument(_ source: InstrumentSource?, into instrument: InstrumentChannel, for track: Track) {
    instrumentLoads[track.id]?.cancel()
    instrumentLoads[track.id] = nil
    let trackID = track.id
    let trackName = track.name

    guard let source, InstrumentChannel.loadsAsynchronously(source) else {
      do {
        try instrument.loadBuiltIn(source, format: instrumentFormat)
      } catch {
        reportLoadFailure(error, source: source, trackName: trackName)
      }
      return
    }

    let format = instrumentFormat
    instrumentLoads[trackID] = Task { [weak self] in
      do {
        try await instrument.load(source, format: format)
        guard let self, !Task.isCancelled else { return }
        self.instrumentLoads[trackID] = nil
        self.refreshMIDIInput()
        // The instrument's latency is known now.
        _ = self.applyRouting()
        self.initializeNewNodes()
        // The old instrument's queued notes were dropped, so reschedule from here.
        if self.isPlaying {
          self.startPlayback(from: self.playheadPosition)
        }
      } catch {
        guard let self, !Task.isCancelled else { return }
        self.instrumentLoads[trackID] = nil
        self.reportLoadFailure(error, source: source, trackName: trackName)
      }
    }
  }

  /// Reports a problem for the interface to show.
  func lastErrorMessage(_ message: String) {
    lastError = message
  }

  private func reportLoadFailure(_ error: any Error, source: InstrumentSource?, trackName: String) {
    lastError = "“\(source?.displayName ?? "The instrument")” on “\(trackName)” couldn’t be loaded: \(error.localizedDescription)"
  }

  // MARK: - Scheduling

  /// The project to plan playback from. Recording doesn't stop at the end of the song: the
  /// song grows to fit the recording once it stops, so until then the end is far away.
  private func plannedProject(isRecording: Bool) -> Project {
    guard isRecording else { return project }
    var planned = project
    let tempoMap = planned.tempoMap
    planned.endPosition = tempoMap.tickPosition(ofBarIndex: tempoMap.bar(containing: planned.endPosition).index + 10_000)
    return planned
  }

  func startPlayback(from position: Tick, recording: RecordingSession? = nil) {
    stop()
    lastError = nil
    playheadPosition = position

    guard startEngineIfNeeded() else { return }

    // With the cycle on, recording loops it and each pass becomes a take.
    let playedProject = plannedProject(isRecording: recording != nil)
    let plan = PlaybackPlan(project: playedProject, startPosition: position)
    if let duration = plan.duration, duration <= 0 {
      return
    }

    // Read the first audio of every track before fixing the start time, so a busy Mac
    // can't make it late: the wait is normally a millisecond or two, and never more than
    // `primingLimit`. Audio positions count from the start of the run, so they don't need
    // the start time.
    sessionCount += 1
    let id = sessionCount
    for source in audioSources.values {
      source.prepare(session: id)
    }
    let primed = DispatchGroup()
    scheduleAudio(of: plan, session: id, in: 0..<PlaybackEngine.lookAhead, primed: primed)
    _ = primed.wait(timeout: .now() + PlaybackEngine.primingLimit)

    // Now fix the start time and start the run on every source (each lines its first sample
    // up with it on its first render), then schedule what's placed by host time. A count-in
    // runs the metronome first; everything else starts when it ends.
    let countIn = PlaybackPlan.countIn(
      bars: recording == nil ? 0 : recordingOptions.countInBars, before: position, in: playedProject.tempoMap)
    let clickStartHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: PlaybackEngine.startDelay)
    let startHostTime = clickStartHostTime + AVAudioTime.hostTime(forSeconds: countIn.duration)
    for source in audioSources.values {
      source.start(session: id, startHostTime: startHostTime)
    }
    // The faders (and send and plug-in nodes) hear their track late by the latency before
    // them, so automation waits too.
    for (trackID, channel) in mixerChannels {
      channel.beginAutomation(anchor: .hostTime(startHostTime), faderLatency: compensation.faderLatency[trackID] ?? 0)
    }
    // Clicks don't pass through the delayed mix, so they're scheduled that much later.
    let latency = compensationSeconds
    metronome?.begin(session: id, startHostTime: clickStartHostTime, lead: countIn.duration + latency)
    metronome?.schedule(countIn.clicks)
    var session = Session(
      id: id, plan: plan, startHostTime: startHostTime, scheduledUntil: 0, isRecording: recording != nil, latency: latency)
    self.session = session
    scheduleEvents(&session, in: 0..<PlaybackEngine.lookAhead)
    session.scheduledUntil = PlaybackEngine.lookAhead

    self.session = session
    isPlaying = true
    updateMetronomeVolume()
    if let recording {
      beginRecording(recording, startHostTime: startHostTime)
    }

    tickerTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.tick()
        try? await Task.sleep(for: .milliseconds(33))
      }
    }
  }

  private func schedule(_ session: inout Session, until playbackTime: Double) {
    let window = session.scheduledUntil..<playbackTime
    guard !window.isEmpty else { return }
    scheduleAudio(of: session.plan, session: session.id, in: window)
    scheduleEvents(&session, in: window)
    session.scheduledUntil = playbackTime
  }

  /// Queues the audio regions starting in a window of playback time for reading.
  private func scheduleAudio(of plan: PlaybackPlan, session id: Int, in window: Range<Double>, primed: DispatchGroup? = nil) {
    let outputRate = instrumentFormat.sampleRate
    var jobs: [Track.ID: [AudioRegionReader.Job]] = [:]
    for segment in plan.audioSegments(startingIn: window) {
      // Opening the file here (once) reports a missing or unreadable file straight away.
      guard audioSources[segment.trackID] != nil, audioFile(for: segment.fileID) != nil,
        let reference = project.audioFile(withID: segment.fileID), let url = locateAudioFile(reference)
      else { continue }
      jobs[segment.trackID, default: []].append(AudioRegionReader.Job(
        session: id, url: url, fileStartFrame: segment.fileStartFrame, fileFrameCount: segment.frameCount,
        startFrame: Int64((segment.playbackTime * outputRate).rounded()), envelope: segment.envelope))
    }
    for (trackID, trackJobs) in jobs {
      audioSources[trackID]?.schedule(trackJobs, primed: primed)
    }
  }

  /// Schedules what's placed by host time in a window: MIDI, automation and clicks.
  private func scheduleEvents(_ session: inout Session, in window: Range<Double>) {
    for event in session.plan.midiEvents(in: window) {
      guard let instrument = instruments[event.trackID] else { continue }
      let hostTime = session.startHostTime + AVAudioTime.hostTime(forSeconds: event.playbackTime)
      instrument.schedule(event.bytes, atHostTime: hostTime)
    }

    scheduleAutomation(&session, in: window)

    if schedulesPlanClicks {
      metronome?.schedule(session.plan.clicks(in: window))
    }
  }

  /// Each channel places automation in its nodes' timelines, from the run's start time (see
  /// `ChannelNodes.beginAutomation`).
  private func scheduleAutomation(_ session: inout Session, in window: Range<Double>) {
    for ramp in session.plan.automationRamps(in: window) {
      mixerChannels[ramp.trackID]?.schedule(
        ramp.parameter, from: ramp.startTime, to: ramp.endTime, startValue: ramp.startValue, endValue: ramp.endValue)
    }
  }

  /// Replaces the queued automation with the project's current automation, from a moment
  /// from now (so nothing scheduled can arrive late) to the end of the scheduled window.
  private func rescheduleAutomation() {
    guard var session else { return }
    session.plan = PlaybackPlan(project: plannedProject(isRecording: session.isRecording), startPosition: session.plan.startPosition)
    for channel in mixerChannels.values {
      channel.flushAutomation()
    }
    let now = mach_absolute_time()
    let elapsed = now > session.startHostTime ? AVAudioTime.seconds(forHostTime: now - session.startHostTime) : 0
    let from = elapsed + Self.startDelay
    if from < session.scheduledUntil {
      scheduleAutomation(&session, in: from..<session.scheduledUntil)
    }
    self.session = session
  }

  /// Advances the playhead and keeps the look-ahead window filled.
  private func tick() {
    guard var session else { return }
    let now = mach_absolute_time()
    let elapsed = now > session.startHostTime ? AVAudioTime.seconds(forHostTime: now - session.startHostTime) : 0
    // What's heard lags what's scheduled by the plug-in delay compensation latency.
    let heard = max(0, elapsed - session.latency)

    if let duration = session.plan.duration, heard >= duration {
      stop()
      playheadPosition = session.plan.timelinePosition(atPlaybackTime: duration)
      return
    }

    playheadPosition = session.plan.timelinePosition(atPlaybackTime: heard)
    musicalContext.update(at: playheadPosition, in: project.tempoMap)
    for source in audioSources.values {
      source.pump()
    }
    if session.scheduledUntil - elapsed < PlaybackEngine.refillThreshold {
      schedule(&session, until: session.scheduledUntil + PlaybackEngine.lookAhead)
      self.session = session
    }
  }

  // MARK: - Live MIDI and instruments

  /// Plays MIDI on a track's instrument straight away (from a MIDI keyboard, for example).
  public func playLive(_ bytes: [UInt8], onTrack trackID: Track.ID) {
    instruments[trackID]?.playNow(bytes)
  }

  /// Sends MIDI keyboards to tracks' instruments, all playing together, or disconnects them
  /// with none. Call when the window becomes frontmost and when the tracks that should play
  /// change.
  public func connectMIDIInput(toTracks trackIDs: [Track.ID]) {
    midiInputTrackIDs = trackIDs
    if trackIDs.isEmpty {
      MIDIInputRouter.shared?.setTargets(instruments: [], handler: nil)
      stopLiveEffects()
    } else {
      refreshMIDIInput()
    }
  }

  /// Points the router at the current instruments (a reloaded instrument has a new MIDI
  /// block), and, for tracks with MIDI effects, at their effects, so each track's effects
  /// play its own copy of what's played.
  private func refreshMIDIInput() {
    guard !midiInputTrackIDs.isEmpty else { return }
    var direct: [AUScheduleMIDIEventBlock] = []
    var live: [Track.ID: LiveMIDIEffects] = [:]
    for trackID in midiInputTrackIDs {
      guard let instrument = instruments[trackID] else { continue }
      let effects = project.track(withID: trackID)?.channel.midiEffects ?? []
      if LiveMIDIEffects.isActive(effects) {
        if let existing = liveEffects.removeValue(forKey: trackID) {
          existing.effects = effects
          live[trackID] = existing
        } else {
          live[trackID] = makeLiveEffects(effects, playing: instrument)
        }
      } else if let schedule = instrument.scheduleMIDIEvent {
        direct.append(schedule)
      }
    }
    // Tracks no longer played, or whose effects were all bypassed.
    stopLiveEffects()
    liveEffects = live
    var handler: (@Sendable ([UInt8], UInt64) -> Void)?
    if !live.isEmpty {
      handler = { [weak self] bytes, hostTime in
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            self?.playLiveEffects(bytes, at: hostTime)
          }
        }
      }
    }
    MIDIInputRouter.shared?.setTargets(instruments: direct, handler: handler)
  }

  /// Plays a message from a MIDI keyboard through each played track's MIDI effects.
  private func playLiveEffects(_ bytes: [UInt8], at hostTime: UInt64) {
    for effects in liveEffects.values {
      effects.receive(bytes, at: hostTime)
    }
  }

  private func makeLiveEffects(_ effects: [MIDIEffect], playing instrument: InstrumentChannel) -> LiveMIDIEffects {
    let musicalContext = musicalContext
    return LiveMIDIEffects(
      effects: effects,
      play: { [weak instrument] bytes, hostTime in
        if let hostTime { instrument?.schedule(bytes, atHostTime: hostTime) } else { instrument?.playNow(bytes) }
      },
      songPosition: { [weak self] hostTime in self?.songPosition(atHostTime: hostTime) },
      tempo: { musicalContext.currentTempo })
  }

  private func stopLiveEffects() {
    for effects in liveEffects.values {
      effects.stopAll()
    }
    liveEffects = [:]
  }

  /// Where the song is at a host time, while it plays (for MIDI effects played live).
  func songPosition(atHostTime hostTime: UInt64) -> Tick? {
    guard let session, isPlaying else { return nil }
    let elapsed = hostTime > session.startHostTime ? AVAudioTime.seconds(forHostTime: hostTime - session.startHostTime) : 0
    return session.plan.timelinePosition(atPlaybackTime: elapsed)
  }

  /// Plays a short note, for auditioning notes while editing.
  public func previewNote(pitch: Int, velocity: Int = 100, channel: Int = 0, onTrack trackID: Track.ID) {
    guard let instrument = instruments[trackID] else { return }
    let status = UInt8(channel & 0x0F)
    instrument.playNow([0x90 | status, UInt8(clamping: pitch), UInt8(clamping: velocity)])
    Task {
      try? await Task.sleep(for: .milliseconds(300))
      instrument.playNow([0x80 | status, UInt8(clamping: pitch), 0])
    }
  }

  /// Scoped access to a track's loaded instrument, for example to request its interface.
  /// The audio unit must not be kept after `body` returns.
  public func withInstrumentAudioUnit<Result>(
    forTrack trackID: Track.ID, _ body: (borrowing AUAudioUnit) -> Result
  ) -> Result? {
    instruments[trackID]?.instrument?.withAUAudioUnit(body)
  }

  /// An instrument's current settings, to store in the project after the person changes
  /// them in the plug-in's interface.
  public func instrumentState(forTrack trackID: Track.ID) -> Data? {
    instruments[trackID]?.capturedState()
  }

  /// Whether a track's instrument is still loading.
  public func isLoadingInstrument(forTrack trackID: Track.ID) -> Bool {
    instrumentLoads[trackID] != nil
  }

  private func audioFile(for fileID: AudioFileReference.ID) -> AVAudioFile? {
    if let file = openFiles[fileID] {
      return file
    }
    guard let reference = project.audioFile(withID: fileID), let url = locateAudioFile(reference) else {
      lastError = "An audio file is missing from the project."
      return nil
    }
    do {
      let file = try AVAudioFile(forReading: url)
      openFiles[fileID] = file
      return file
    } catch {
      lastError = "“\(reference.fileName)” couldn’t be opened: \(error.localizedDescription)"
      return nil
    }
  }

  // MARK: - Device changes

  /// When the output device or its format changes, AVAudioEngine stops itself. Restart
  /// playback where it was so switching headphones doesn't stop the song.
  private func observeConfigurationChanges() {
    configurationTask = Task { [weak self, engine] in
      for await _ in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange, object: engine) {
        guard let self else { return }
        // A device change ends a recording; keep what was captured so far.
        if self.isRecording {
          self.stop()
        }
        // The device's sample rate may have changed; instruments must render at it.
        self.outputDidChange()
        if self.isPlaying {
          self.startPlayback(from: self.playheadPosition)
        }
      }
    }
  }
}

// MARK: - Plug-in parameter values

/// How a plug-in parameter's values read: its range and unit, copied from the Audio Unit so
/// values can be shown without asking the plug-in (which may run in another process) each
/// time. Automation stores 0…1 across the range, as the engine plays it.
public struct PluginValueFormat: Sendable, Equatable {
  public var minimum: Double
  public var maximum: Double
  public var unit: AudioUnitParameterUnit
  /// A custom unit's name ("bars", say).
  public var unitName: String?
  /// The choices of an indexed parameter, from the minimum up.
  public var valueStrings: [String]?

  public init(
    minimum: Double, maximum: Double, unit: AudioUnitParameterUnit, unitName: String? = nil, valueStrings: [String]? = nil
  ) {
    self.minimum = minimum
    self.maximum = maximum
    self.unit = unit
    self.unitName = unitName
    self.valueStrings = valueStrings
  }

  init(_ parameter: AUParameter) {
    self.init(
      minimum: Double(parameter.minValue), maximum: Double(parameter.maxValue), unit: parameter.unit,
      unitName: parameter.unitName, valueStrings: parameter.valueStrings)
  }

  /// The value at `fraction` of the range, with its unit ("−12.0 dB", "1.50 kHz", "Saw").
  public func label(forFraction fraction: Double) -> String {
    let value = minimum + min(max(fraction, 0), 1) * (maximum - minimum)
    switch unit {
    case .indexed:
      let index = Int((value - minimum).rounded())
      return valueStrings.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? "\(Int(value.rounded()))"
    case .boolean:
      return value >= 0.5 ? "On" : "Off"
    case .hertz:
      if value >= 1_000 { return String(format: "%.2f kHz", value / 1_000) }
      return value < 10 ? String(format: "%.2f Hz", value) : String(format: "%.0f Hz", value)
    case .decibels:
      return String(format: "%+.1f dB", value)
    case .milliseconds:
      return value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
    case .seconds:
      return String(format: "%.2f s", value)
    case .percent:
      return String(format: "%.0f%%", value)
    case .cents:
      return String(format: "%+.0f ct", value)
    case .relativeSemiTones:
      return String(format: "%+.0f st", value)
    case .ratio:
      return String(format: "%.1f : 1", value)
    case .midiNoteNumber:
      return Self.noteName(Int(value.rounded()))
    case .pan:
      // Plug-in pans run −100…100 (or −1…1); centre is the middle of the range.
      let amount = Int((abs(value) / max(abs(minimum), abs(maximum)) * 100).rounded())
      return amount == 0 ? "C" : "\(value < 0 ? "L" : "R") \(amount)"
    case .customUnit:
      return String(format: "%.2f", value) + (unitName.map { " \($0)" } ?? "")
    default:
      return String(format: "%.2f", value)
    }
  }

  /// Logic's octave numbering, as in the Piano Roll: middle C (MIDI 60) is C3.
  static func noteName(_ note: Int) -> String {
    let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    return "\(names[((note % 12) + 12) % 12])\(Int((Double(note) / 12).rounded(.down)) - 2)"
  }
}
