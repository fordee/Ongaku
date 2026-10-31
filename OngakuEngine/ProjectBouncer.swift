//
//  ProjectBouncer.swift
//  OngakuEngine
//

import AVFAudio
import Accelerate
import Foundation
import OngakuCore

/// What a bounce produced.
public struct BounceResult: Sendable {
  public var url: URL
  /// Length of the file, in seconds, including any tail.
  public var duration: Double
  /// The loudest sample of the mix before normalizing, in dBFS.
  public var peakDecibels: Double
  /// The mix went over full scale and the file was not normalized, so it has clipped.
  public var isClipped: Bool
}

public enum BounceError: Error, LocalizedError {
  case nothingToBounce
  case nothingToFreeze
  case pluginFailed(String)
  case renderFailed

  public var errorDescription: String? {
    switch self {
    case .nothingToBounce: "There’s nothing to bounce: the project has no regions."
    case .nothingToFreeze: "There’s nothing to freeze: the track has no regions."
    case .pluginFailed(let message): message
    case .renderFailed: "The mix couldn’t be rendered."
    }
  }
}

/// Renders a project's mix to an audio file faster than real time.
///
/// The bounce builds its own `AVAudioEngine` in offline manual-rendering mode, out of the
/// same channel classes as live playback (`ChannelNodes`, `InstrumentChannel`), so it
/// sounds the same: inserts, sends, auxes, mute and solo all apply. Audio regions play
/// through player nodes (`TrackChannel`) rather than live playback's sample sources:
/// offline, starting players can't hold anything up. Because the bouncer drives the render clock itself, audio and MIDI are placed by
/// sample time rather than host time and nothing depends on how busy the Mac is.
///
/// The mix is first rendered to a 32-bit float file; the requested file is then written
/// from that, so normalizing can use the peak of the whole mix.
@MainActor
public final class ProjectBouncer {
  public typealias ProgressHandler = @MainActor (Double) -> Void

  static let blockSize: AVAudioFrameCount = 4096
  /// Rendered and thrown away before the music starts, so every instrument has rendered
  /// once and its sample timeline is known.
  static let preroll: AVAudioFrameCount = 512
  /// How far ahead audio and MIDI are scheduled while rendering, in seconds.
  private static let lookAhead = 2.0
  /// The tail ends once the mix stays below this level (about -94 dBFS) for `silentTail`.
  private static let silenceThreshold: Float = 0.00002
  private static let silentTail = 0.5
  /// The longest tail rendered, in seconds, in case a delay keeps feeding back.
  private static let maximumTail = 20.0

  private let project: Project
  private let locateAudioFile: AudioFileLocator

  /// Frozen tracks play their freeze files, as they do live.
  public init(project: Project, locateAudioFile: @escaping AudioFileLocator) {
    self.project = project.playingFreezeFiles { PlaybackEngine.exists($0, locateAudioFile) }
    self.locateAudioFile = locateAudioFile
  }

  // MARK: - Freezing

  /// Renders the freeze file for a track, as Logic's Freeze does: the track on its own, from
  /// the start of the project to the end of its last region and on until it has faded out,
  /// through its instrument and, in Pre Fader mode, its inserts. The fader, pan, sends and
  /// automation are left out: they still work on the frozen track. Plug-in latency is
  /// taken off, so the file lines up with the timeline.
  ///
  /// The file is written to `url` as 32-bit float CAF at `sampleRate`.
  public static func freeze(
    _ trackID: Track.ID, in project: Project, sampleRate: Double, to url: URL,
    locateAudioFile: @escaping AudioFileLocator, progress: ProgressHandler = { _ in }
  ) async throws -> AudioFileReference {
    guard var track = project.track(withID: trackID), track.canFreeze else { throw BounceError.nothingToFreeze }
    let end = track.playedRegions(until: project.endPosition).filter { !$0.isMuted }.map(\.end).max() ?? .zero
    guard end > .zero else { throw BounceError.nothingToFreeze }

    track.freezeFile = nil
    track.channel.volume = 0
    track.channel.pan = 0
    track.channel.isMuted = false
    track.channel.isSoloed = false
    track.channel.sends = []
    track.channel.output = .stereoOut
    if !track.freezesInserts {
      track.channel.inserts = []
    }
    track.automation = []
    track.stackID = nil
    track.isRecordArmed = false
    var alone = project
    alone.tracks = [track]
    alone.masterVolume = 0
    alone.stereoOutInserts = []

    let bouncer = ProjectBouncer(project: alone, locateAudioFile: locateAudioFile)
    let mix = try await bouncer.renderMix(.zero..<end, sampleRate: sampleRate, includeTail: true, to: url, progress: progress)
    return AudioFileReference(
      fileName: url.lastPathComponent, sampleRate: sampleRate, channelCount: 2, frameCount: Int64(mix.frameCount))
  }

  /// Bounces the mix of `range` to `url`. Progress runs from 0 to 1. Cancelling the calling
  /// task stops the bounce and throws `CancellationError`.
  public func bounce(
    _ range: Range<Tick>, settings: BounceSettings, to url: URL, progress: ProgressHandler = { _ in }
  ) async throws -> BounceResult {
    guard !range.isEmpty else { throw BounceError.nothingToBounce }
    let mixURL = FileManager.default.temporaryDirectory.appending(path: "Ongaku Bounce \(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: mixURL) }

    let mix = try await renderMix(range, sampleRate: settings.effectiveSampleRate, includeTail: settings.includeTail, to: mixURL) {
      progress($0 * 0.9)
    }
    let gain = settings.normalize ? settings.normalizationGain(forPeak: mix.peak) : 1
    try await Self.writeFile(from: mixURL, to: url, settings: settings, gain: gain) { progress(0.9 + $0 * 0.1) }
    progress(1)
    return BounceResult(
      url: url,
      duration: Double(mix.frameCount) / settings.effectiveSampleRate,
      peakDecibels: mix.peak > 0 ? Double(20 * log10(mix.peak)) : -.infinity,
      isClipped: !settings.normalize && mix.peak > 1)
  }

  // MARK: - Mastering

  /// Analyze Whole Song: plays `range` through Ongaku Mastering's Listen, faster than real
  /// time. The bounce's own copy of the Mastering on Stereo Out (`pluginID`) hears the whole
  /// song and sets itself up for it, as Listen does live; its settings afterwards are
  /// returned, for the song's Mastering to take. `nil` if it heard too little music.
  public func listenForMastering(
    _ pluginID: PluginReference.ID, range: Range<Tick>, sampleRate: Double, progress: ProgressHandler = { _ in }
  ) async throws -> Data? {
    guard !range.isEmpty else { throw BounceError.nothingToBounce }
    typealias Mastering = OngakuEffect.MasteringParameter
    func parameter(_ address: UInt64, in graph: Graph) -> AUParameter? {
      graph.stereoOut?.withInsertAudioUnit(pluginID) { $0.parameterTree?.parameter(withAddress: address) } ?? nil
    }
    var state: Data?
    _ = try await renderMix(range, sampleRate: sampleRate, includeTail: false, to: nil, progress: progress) { graph in
      // Cleared first, so it's plain when the analysis is done.
      parameter(Mastering.measuredLoudness, in: graph)?.value = Mastering.notMeasured
      parameter(Mastering.listen, in: graph)?.value = 1
    } finish: { graph in
      guard let measured = parameter(Mastering.measuredLoudness, in: graph) else {
        throw BounceError.pluginFailed("Mastering isn’t on Stereo Out.")
      }
      parameter(Mastering.listen, in: graph)?.value = 0
      // The plug-in analyses on its own main thread, in its own process, and then sets the
      // song's settings; too little music sets nothing.
      for _ in 0..<60 where measured.value <= Mastering.notMeasured + 0.05 {
        try await Task.sleep(for: .milliseconds(50))
      }
      guard measured.value > Mastering.notMeasured + 0.05 else { return }
      // The measured loudness may arrive before the rest of the settings.
      try await Task.sleep(for: .milliseconds(200))
      state = graph.stereoOut?.insertState(pluginID)
    }
    return state
  }

  // MARK: - Rendering

  private struct Mix {
    var frameCount: AVAudioFramePosition
    var peak: Float
  }

  /// The engine and the nodes built for one bounce.
  private struct Graph {
    var engine: AVAudioEngine
    var channels: [Track.ID: ChannelNodes] = [:]
    /// Stereo Out, which every track's fader feeds.
    var stereoOut: ChannelNodes?
    var players: [Track.ID: TrackChannel] = [:]
    var instruments: [Track.ID: InstrumentChannel] = [:]
    var files: [AudioFileReference.ID: AVAudioFile] = [:]
    /// Plug-in delay compensation, at the bounce's sample rate.
    var compensation = DelayCompensation()
    /// The song's tempo and position, for plug-ins that follow them.
    let musicalContext = HostMusicalContext()
  }

  /// Audio still to be handed to a player. Bounces read files themselves and give players
  /// buffers: a player reading a file in the background can fall behind a render running
  /// faster than real time, which left the start of a bounce silent.
  private struct PendingAudio {
    var player: AVAudioPlayerNode
    var file: AVAudioFile
    var fileFrame: AVAudioFramePosition
    var remainingFrames: AVAudioFramePosition
    /// Where the next buffer plays, in the player's timeline (at the file's rate).
    var playerSampleTime: AVAudioFramePosition
    /// The region's gain and fades, and how many frames of the segment have been read.
    var envelope: AudioEnvelope
    var segmentFrame: Int64 = 0
  }

  /// Audio is read in pieces of at most this many seconds.
  private static let readChunk = 1.0

  /// Renders `range` to `url` (or nowhere, when only a plug-in needs to hear it). `prepare`
  /// runs once the graph is built, and `finish` once the music has been heard, before the
  /// graph is taken down.
  private func renderMix(
    _ range: Range<Tick>, sampleRate: Double, includeTail: Bool, to url: URL?, progress: ProgressHandler,
    prepare: (Graph) -> Void = { _ in }, finish: (Graph) async throws -> Void = { _ in }
  ) async throws -> Mix {
    let played = project.playingOnce(range)
    let plan = PlaybackPlan(project: played, startPosition: range.lowerBound)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
      throw BounceError.renderFailed
    }
    let graph = try await buildGraph(for: played, format: format, startPosition: range.lowerBound)
    graph.musicalContext.update(at: range.lowerBound, in: played.tempoMap)
    prepare(graph)
    let engine = graph.engine
    defer {
      engine.stop()
      for channel in graph.channels.values {
        channel.detach()
      }
      graph.stereoOut?.detach()
    }

    engine.prepare()
    try engine.start()
    guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.blockSize) else {
      throw BounceError.renderFailed
    }
    try render(Self.preroll, with: engine, into: buffer)

    // The music starts at this engine sample time. Each instrument counts samples in its own
    // timeline, so work out where that is for each one from its first render.
    let musicStart = engine.manualRenderingSampleTime
    var instrumentStarts: [Track.ID: Int64] = [:]
    for (trackID, instrument) in graph.instruments {
      let offset: Int64
      if let last = instrument.instrument?.lastRenderTime, last.isSampleTimeValid {
        offset = last.sampleTime - (musicStart - AVAudioFramePosition(Self.preroll))
      } else {
        offset = 0
      }
      instrumentStarts[trackID] = musicStart + offset
    }
    // Every node counts samples in its own timeline, and first rendered during the preroll;
    // automation is placed in each from there (see `ChannelNodes.beginAutomation`).
    let prerollStart = musicStart - AVAudioFramePosition(Self.preroll)
    for (trackID, channel) in graph.channels {
      channel.beginAutomation(
        anchor: .offline(musicStart: musicStart, prerollStart: prerollStart),
        faderLatency: graph.compensation.faderLatency[trackID] ?? 0)
    }
    let startTime = AVAudioTime(sampleTime: musicStart, atRate: sampleRate)
    for players in graph.players.values {
      for player in players.allPlayers {
        try player.playAudio(at: startTime)
      }
    }

    let output = try url.map {
      try AVAudioFile(forWriting: $0, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    defer { output?.close() }

    let musicFrames = AVAudioFramePosition(((plan.duration ?? 0) * sampleRate).rounded())
    // With plug-in delay compensation the mix comes out late by its latency: that much is
    // left off the start of the file, and the music has been heard once that much more has
    // been rendered.
    let latency = AVAudioFramePosition(graph.compensation.mixLatency)
    let heardEnd = musicFrames + latency
    let maximumFrames = heardEnd + (includeTail ? AVAudioFramePosition(Self.maximumTail * sampleRate) : 0)
    let silentFramesNeeded = AVAudioFramePosition(Self.silentTail * sampleRate)
    var rendered: AVAudioFramePosition = 0
    var written: AVAudioFramePosition = 0
    var scheduledUntil = 0.0
    var pendingAudio: [PendingAudio] = []
    var peak: Float = 0
    var silentFrames: AVAudioFramePosition = 0

    while rendered < maximumFrames {
      try Task.checkCancellation()
      let seconds = Double(rendered) / sampleRate
      if rendered < musicFrames {
        graph.musicalContext.update(at: plan.timelinePosition(atPlaybackTime: seconds), in: played.tempoMap)
      }
      if rendered < musicFrames, scheduledUntil - seconds < Self.lookAhead / 2 {
        try schedule(plan, window: scheduledUntil..<(scheduledUntil + Self.lookAhead), in: graph, sampleRate: sampleRate,
          instrumentStarts: instrumentStarts, pendingAudio: &pendingAudio)
        scheduledUntil += Self.lookAhead
      }
      if rendered == musicFrames {
        // The end: stop the sources and let what's still in the mix (and effects) ring out.
        for players in graph.players.values {
          players.stopPlayers()
        }
        for instrument in graph.instruments.values {
          instrument.stopAllNotes()
        }
      }
      if rendered == heardEnd, !includeTail { break }

      // Blocks end exactly at the music's end, where the compensation's delay has passed,
      // and where the music has been heard, so each starts on a block boundary.
      let boundaries = [latency, musicFrames, heardEnd, maximumFrames].filter { $0 > rendered }
      let nextBoundary = boundaries.min() ?? maximumFrames
      try render(AVAudioFrameCount(min(AVAudioFramePosition(Self.blockSize), nextBoundary - rendered)), with: engine, into: buffer)
      let isHeard = rendered >= latency
      rendered += AVAudioFramePosition(buffer.frameLength)
      guard isHeard else { continue }

      let blockPeak = Self.peak(of: buffer)
      peak = max(peak, blockPeak)
      try output?.write(from: buffer)
      written += AVAudioFramePosition(buffer.frameLength)

      if rendered > heardEnd {
        silentFrames = blockPeak < Self.silenceThreshold ? silentFrames + AVAudioFramePosition(buffer.frameLength) : 0
        if silentFrames >= silentFramesNeeded { break }
      }
      if musicFrames > 0 {
        progress(min(1, Double(written) / Double(musicFrames)))
      }
      // Let the window stay responsive between blocks.
      await Task.yield()
    }
    try await finish(graph)
    return Mix(frameCount: written, peak: peak)
  }

  private func render(_ frameCount: AVAudioFrameCount, with engine: AVAudioEngine, into buffer: AVAudioPCMBuffer) throws {
    var attempts = 0
    while true {
      switch try engine.renderOffline(frameCount, to: buffer) {
      case .success:
        return
      case .cannotDoInCurrentContext where attempts < 100:
        attempts += 1
      case .insufficientDataFromInputNode:
        // There's no input node in a bounce; treat whatever rendered as the block.
        return
      default:
        throw BounceError.renderFailed
      }
    }
  }

  /// Builds the mixer graph for `project` in a new offline engine and waits for every
  /// plug-in to load.
  private func buildGraph(for project: Project, format: AVAudioFormat, startPosition: Tick) async throws -> Graph {
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: Self.blockSize)
    var graph = Graph(engine: engine)
    var failure: String?

    let stereoOut = try ChannelNodes(engine: engine, format: format, musicalContext: graph.musicalContext)
    graph.stereoOut = stereoOut
    stereoOut.setInserts(project.stereoOutInserts) { plugin, error in
      failure = "“\(plugin.name)” on Stereo Out couldn’t be loaded: \(error.localizedDescription)"
    } onInstalled: {}

    for track in project.tracks {
      let channel = try ChannelNodes(
        engine: engine, format: format, musicalContext: graph.musicalContext, mainOutput: stereoOut.input)
      graph.channels[track.id] = channel
      let automated = Set(track.automatedParameters.filter(track.isAutomated))
      channel.applyMix(track.channel, isAudible: project.isTrackAudible(track.id), automated: automated)
      let trackName = track.name
      channel.setInserts(track.channel.inserts) { plugin, error in
        failure = "“\(plugin.name)” on “\(trackName)” couldn’t be loaded: \(error.localizedDescription)"
      } onInstalled: {}

      switch track.kind {
      case .audio:
        let players = TrackChannel(engine: engine, destination: channel.input)
        graph.players[track.id] = players
        for region in track.regions where !region.isMuted {
          guard case .audio(let content) = region.content else { continue }
          let file = try audioFile(content.fileID, in: &graph)
          _ = try players.player(for: file.processingFormat)
        }
      case .softwareInstrument:
        let instrument = InstrumentChannel(engine: engine, destination: channel.input)
        graph.instruments[track.id] = instrument
        guard let source = track.channel.instrument else { continue }
        do {
          if InstrumentChannel.loadsAsynchronously(source) {
            try await instrument.load(source, format: format)
          } else {
            try instrument.loadBuiltIn(source, format: format)
          }
        } catch {
          throw BounceError.pluginFailed("“\(source.displayName)” on “\(track.name)” couldn’t be loaded: \(error.localizedDescription)")
        }
      case .aux:
        break
      }
    }
    for channel in graph.channels.values {
      await channel.waitForPendingInserts()
    }
    await stereoOut.waitForPendingInserts()
    if let failure {
      throw BounceError.pluginFailed(failure)
    }

    // Plug-in delay compensation, now every plug-in is loaded and its latency known.
    var latencies: [Track.ID: DelayCompensation.Latency] = [:]
    for track in project.tracks {
      latencies[track.id] = DelayCompensation.Latency(
        source: graph.instruments[track.id]?.latency(atSampleRate: format.sampleRate) ?? 0,
        inserts: graph.channels[track.id]?.insertLatency ?? 0)
    }
    graph.compensation = DelayCompensation(project: project, latencies: latencies)
    graph.compensation.stereoOutLatency = stereoOut.insertLatency

    let auxInputs = graph.channels.filter { id, _ in project.track(withID: id)?.kind == .aux }.mapValues(\.input)
    for track in project.tracks {
      let routing = ChannelNodes.Routing(
        sends: track.channel.sends, output: track.channel.output, automatedSends: track.automatedSends)
      guard let channel = graph.channels[track.id] else { continue }
      try channel.applyRouting(routing.compensated(by: graph.compensation, for: track.id), auxInputs: auxInputs)
      // Automated parameters start where the bounce does; their nodes exist now.
      let automated = Set(track.automatedParameters.filter(track.isAutomated))
      channel.prepareAutomation(for: automated)
      for parameter in automated {
        channel.setAutomatedValue(parameter, to: track.automatedValue(of: parameter, at: startPosition))
      }
    }
    stereoOut.fader.outputVolume = Float(project.masterLinearGain)
    return graph
  }

  private func audioFile(_ fileID: AudioFileReference.ID, in graph: inout Graph) throws -> AVAudioFile {
    if let file = graph.files[fileID] {
      return file
    }
    guard let reference = project.audioFile(withID: fileID), let url = locateAudioFile(reference) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let file = try AVAudioFile(forReading: url)
    graph.files[fileID] = file
    return file
  }

  /// Schedules the audio segments and MIDI events that start in `window` (seconds after
  /// the music starts), at exact sample times.
  private func schedule(
    _ plan: PlaybackPlan, window: Range<Double>, in graph: Graph, sampleRate: Double, instrumentStarts: [Track.ID: Int64],
    pendingAudio: inout [PendingAudio]
  ) throws {
    for segment in plan.audioSegments(startingIn: window) {
      guard let players = graph.players[segment.trackID], let file = graph.files[segment.fileID],
        let player = try? players.player(for: file.processingFormat)
      else { continue }
      pendingAudio.append(PendingAudio(
        player: player, file: file, fileFrame: segment.fileStartFrame, remainingFrames: segment.frameCount,
        playerSampleTime: AVAudioFramePosition((segment.playbackTime * file.processingFormat.sampleRate).rounded()),
        envelope: segment.envelope))
    }
    try feed(&pendingAudio, until: window.upperBound)
    for event in plan.midiEvents(in: window) {
      guard let instrument = graph.instruments[event.trackID], let start = instrumentStarts[event.trackID] else { continue }
      instrument.queue.push(sampleTime: start + Int64((event.playbackTime * sampleRate).rounded()), bytes: event.bytes)
    }
    for ramp in plan.automationRamps(in: window) {
      graph.channels[ramp.trackID]?.schedule(
        ramp.parameter, from: ramp.startTime, to: ramp.endTime, startValue: ramp.startValue, endValue: ramp.endValue)
    }
  }

  /// Reads and schedules the pending audio that plays before `seconds`, in buffers placed
  /// back to back at exact sample times.
  private func feed(_ pending: inout [PendingAudio], until seconds: Double) throws {
    for index in pending.indices {
      let rate = pending[index].file.processingFormat.sampleRate
      let until = AVAudioFramePosition((seconds * rate).rounded())
      while pending[index].remainingFrames > 0, pending[index].playerSampleTime < until {
        let file = pending[index].file
        let count = AVAudioFrameCount(min(pending[index].remainingFrames, AVAudioFramePosition(Self.readChunk * rate)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
          throw BounceError.renderFailed
        }
        file.framePosition = pending[index].fileFrame
        try file.read(into: buffer, frameCount: count)
        guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
          pending[index].remainingFrames = 0
          break
        }
        pending[index].envelope.apply(
          to: (0..<Int(buffer.format.channelCount)).map { channels[$0] }, frameCount: Int(buffer.frameLength),
          firstFrame: pending[index].segmentFrame, sampleRate: rate)
        pending[index].segmentFrame += Int64(buffer.frameLength)
        pending[index].player.scheduleBuffer(
          buffer, at: AVAudioTime(sampleTime: pending[index].playerSampleTime, atRate: rate), options: [], completionHandler: nil)
        let read = AVAudioFramePosition(buffer.frameLength)
        pending[index].fileFrame += read
        pending[index].remainingFrames -= read
        pending[index].playerSampleTime += read
      }
    }
    pending.removeAll { $0.remainingFrames <= 0 }
  }

  static func peak(of buffer: AVAudioPCMBuffer) -> Float {
    guard let channels = buffer.floatChannelData else { return 0 }
    var peak: Float = 0
    for channel in 0..<Int(buffer.format.channelCount) {
      var channelPeak: Float = 0
      vDSP_maxmgv(channels[channel], 1, &channelPeak, vDSP_Length(buffer.frameLength))
      peak = max(peak, channelPeak)
    }
    return peak
  }

  // MARK: - Writing the file

  /// File settings for the requested format.
  static func fileSettings(for settings: BounceSettings) -> [String: Any] {
    let sampleRate = settings.effectiveSampleRate
    guard let bitDepth = settings.effectiveBitDepth else {
      return [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: BounceSettings.aacBitRate,
      ]
    }
    return [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 2,
      AVLinearPCMBitDepthKey: bitDepth.rawValue,
      AVLinearPCMIsFloatKey: bitDepth == .thirtyTwoFloat,
      AVLinearPCMIsBigEndianKey: settings.format == .aiff,
      AVLinearPCMIsNonInterleaved: false,
    ]
  }

  /// Converts the rendered mix to the requested file, applying the normalizing gain and,
  /// for 16-bit files, dither.
  private static func writeFile(
    from mixURL: URL, to url: URL, settings: BounceSettings, gain: Float, progress: ProgressHandler
  ) async throws {
    let mix = try AVAudioFile(forReading: mixURL, commonFormat: .pcmFormatFloat32, interleaved: false)
    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(
      forWriting: url, settings: fileSettings(for: settings), commonFormat: .pcmFormatFloat32, interleaved: false)
    defer { file.close() }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: mix.processingFormat, frameCapacity: 65_536) else {
      throw BounceError.renderFailed
    }
    var dither = settings.usesDither ? TriangularDither(bitDepth: 16) : nil
    let length = max(mix.length, 1)
    while mix.framePosition < mix.length {
      try Task.checkCancellation()
      try mix.read(into: buffer)
      guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
      for channel in 0..<Int(buffer.format.channelCount) {
        let samples = channels[channel]
        if gain != 1 {
          var gain = gain
          vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(buffer.frameLength))
        }
        dither?.apply(to: samples, count: Int(buffer.frameLength))
      }
      try file.write(from: buffer)
      progress(Double(mix.framePosition) / Double(length))
      await Task.yield()
    }
  }
}

/// TPDF dither: adds triangular noise of ±1 least significant bit before samples are
/// rounded to a lower bit depth, which turns quantization distortion into a faint, steady hiss.
struct TriangularDither {
  private var state: UInt64 = 0x9E37_79B9_7F4A_7C15
  private let leastSignificantBit: Float

  init(bitDepth: Int) {
    leastSignificantBit = 1 / Float(1 << (bitDepth - 1))
  }

  mutating func apply(to samples: UnsafeMutablePointer<Float>, count: Int) {
    for index in 0..<count {
      samples[index] += (nextUnit() - nextUnit()) * leastSignificantBit
    }
  }

  /// A uniform random number in 0..<1 (xorshift64*: fast, and good enough for noise).
  private mutating func nextUnit() -> Float {
    state ^= state >> 12
    state ^= state << 25
    state ^= state >> 27
    return Float((state &* 0x2545_F491_4F6C_DD1D) >> 40) / Float(1 << 24)
  }
}
