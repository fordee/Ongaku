//
//  AudioTrackSource.swift
//  OngakuEngine
//

import AVFAudio
import Foundation
import OngakuCore
import Synchronization

/// What feeds an audio track's channel during live playback: a source node that renders the
/// track's `SampleChunkRing`, filled ahead of time by a background `AudioRegionReader`.
///
///     reader (background queue) ─▶ ring ─▶ source node (render thread) ─▶ channel input
///
/// Nothing here blocks the main thread: starting, stopping and moving the playhead only
/// store atomics and queue work for the reader.
@MainActor
final class AudioTrackSource {
  /// About 170 ms per chunk at 48 kHz.
  nonisolated static let chunkFrames = 8192
  /// Room for the look-ahead twice over, so a new run never waits for the old run's chunks
  /// to be dropped.
  nonisolated static let chunkCount = 24
  /// How far ahead of the render thread the reader keeps the ring filled.
  static let readAhead = 1.5

  let node: AVAudioSourceNode
  let ring: SampleChunkRing
  private let reader: AudioRegionReader
  private unowned let engine: AVAudioEngine

  init(engine: AVAudioEngine, destination: AVAudioMixerNode, format: AVAudioFormat, onError: @escaping @Sendable (String) -> Void) throws {
    self.engine = engine
    let ring = SampleChunkRing(slotCount: Self.chunkCount, slotFrames: Self.chunkFrames, sampleRate: format.sampleRate)
    self.ring = ring
    node = SampleChunkRing.makeSourceNode(rendering: ring, format: format)
    reader = AudioRegionReader(
      ring: ring, outputRate: format.sampleRate, readAheadFrames: Int64(Self.readAhead * format.sampleRate), onError: onError)
    engine.attach(node)
    do {
      try engine.connectNode(node, to: destination, fromBus: 0, toBus: engine.freeInputBus(on: destination, for: node), format: format)
    } catch {
      engine.detach(node)
      throw error
    }
  }

  /// Gets ready for a new run of the transport: the reader starts reading for it, before
  /// its start time is known.
  func prepare(session: Int) {
    reader.begin(session: session)
  }

  /// Starts the run whose first frame plays at `startHostTime` (see `SampleChunkRing.begin`).
  func start(session: Int, startHostTime: UInt64) {
    ring.begin(session: session, startHostTime: startHostTime)
  }

  func end() {
    ring.end()
    reader.end()
  }

  /// Queues regions to read for the current run. With `primed`, the reader leaves the group
  /// once the first chunk of every region starting at the very beginning has been read.
  func schedule(_ jobs: [AudioRegionReader.Job], primed: DispatchGroup? = nil) {
    guard !jobs.isEmpty else { return }
    reader.add(jobs, primed: primed)
  }

  /// Asks the reader to top up the ring. Called regularly during playback.
  func pump() {
    reader.pump()
  }

  func detach() {
    end()
    engine.detach(node)
  }
}

extension SampleChunkRing {
  /// A source node that plays this ring. Made outside the main actor: the render block runs
  /// on the audio thread and mustn't carry main-actor isolation.
  static func makeSourceNode(rendering ring: SampleChunkRing, format: AVAudioFormat) -> AVAudioSourceNode {
    AVAudioSourceNode(format: format) { isSilence, timestamp, frameCount, bufferList in
      if !ring.render(timestamp: timestamp, frameCount: Int(frameCount), into: bufferList) {
        isSilence.pointee = true
      }
      return noErr
    }
  }
}

/// Reads an audio track's regions from their files into its `SampleChunkRing`, keeping
/// the ring filled a little ahead of what the render thread is playing.
///
/// All of its state lives on its own serial queue, so tracks read in parallel and the main
/// thread never waits for the disk. Files at another sample rate are converted to the output
/// rate here, and mono files are played on both sides.
final class AudioRegionReader: @unchecked Sendable {
  /// One region (or the rest of one) to play in a run of the transport.
  struct Job: Sendable {
    var session: Int
    var url: URL
    var fileStartFrame: Int64
    var fileFrameCount: Int64
    /// Where it starts, in output frames from the start of the run.
    var startFrame: Int64
    /// The region's gain and fades.
    var envelope = AudioEnvelope()
  }

  /// A job being read.
  private final class Reading {
    let job: Job
    let file: AVAudioFile
    let frameCount: Int64
    /// Output frames read so far.
    var produced: Int64 = 0
    /// File frames read so far.
    var consumed: Int64 = 0
    let converter: AVAudioConverter?
    let fileBuffer: AVAudioPCMBuffer
    let convertedBuffer: AVAudioPCMBuffer?

    init(job: Job, file: AVAudioFile, frameCount: Int64, converter: AVAudioConverter?, fileBuffer: AVAudioPCMBuffer, convertedBuffer: AVAudioPCMBuffer?) {
      self.job = job
      self.file = file
      self.frameCount = frameCount
      self.converter = converter
      self.fileBuffer = fileBuffer
      self.convertedBuffer = convertedBuffer
    }

    var nextFrame: Int64 { job.startFrame + produced }
    var isFinished: Bool { produced >= frameCount }
  }

  private let queue = DispatchQueue(label: "Ongaku.AudioRegionReader", qos: .userInteractive)
  private let ring: SampleChunkRing
  private let outputRate: Double
  private let readAheadFrames: Int64
  private let onError: @Sendable (String) -> Void
  private let isPumpQueued = Atomic<Bool>(false)

  // Only touched on `queue`.
  private var session = 0
  private var readings: [Reading] = []
  private var files: [URL: AVAudioFile] = [:]

  init(ring: SampleChunkRing, outputRate: Double, readAheadFrames: Int64, onError: @escaping @Sendable (String) -> Void) {
    self.ring = ring
    self.outputRate = outputRate
    self.readAheadFrames = readAheadFrames
    self.onError = onError
  }

  func begin(session id: Int) {
    queue.async { [self] in
      session = id
      readings.removeAll()
    }
  }

  func end() {
    queue.async { [self] in
      session = 0
      readings.removeAll()
    }
  }

  func add(_ jobs: [Job], primed: DispatchGroup? = nil) {
    primed?.enter()
    queue.async { [self] in
      for job in jobs where job.session == session {
        if let reading = makeReading(job) {
          readings.append(reading)
        }
      }
      if let primed {
        // Just the first chunk of what starts straight away, so the transport can start as
        // soon as possible; the rest follows.
        fill(limit: Int64(ring.slotFrames))
        primed.leave()
      }
      fill()
    }
  }

  func pump() {
    // At most one pump waiting: if the reader is behind, piling up more doesn't help.
    guard !isPumpQueued.exchange(true, ordering: .acquiringAndReleasing) else { return }
    queue.async { [self] in
      isPumpQueued.store(false, ordering: .releasing)
      fill()
    }
  }

  // MARK: - On the queue

  private func makeReading(_ job: Job) -> Reading? {
    do {
      let file = try files[job.url] ?? AVAudioFile(forReading: job.url)
      files[job.url] = file
      let fileFormat = file.processingFormat
      let fileRate = fileFormat.sampleRate
      let frameCount = Int64((Double(job.fileFrameCount) * outputRate / fileRate).rounded())
      let chunk = AVAudioFrameCount(AudioTrackSource.chunkFrames)
      var converter: AVAudioConverter?
      var convertedBuffer: AVAudioPCMBuffer?
      if fileRate != outputRate {
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: fileFormat.channelCount),
          let made = AVAudioConverter(from: fileFormat, to: outputFormat),
          let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: chunk)
        else { throw CocoaError(.fileReadCorruptFile) }
        converter = made
        convertedBuffer = buffer
      }
      // Enough file frames for a chunk of output at any supported rate.
      let fileCapacity = AVAudioFrameCount((Double(chunk) * max(1, fileRate / outputRate)).rounded(.up)) + 16
      guard let fileBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: fileCapacity) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      return Reading(job: job, file: file, frameCount: frameCount, converter: converter, fileBuffer: fileBuffer, convertedBuffer: convertedBuffer)
    } catch {
      onError("“\(job.url.lastPathComponent)” couldn’t be read: \(error.localizedDescription)")
      return nil
    }
  }

  /// Reads chunks, earliest first, until the ring holds `readAheadFrames` beyond what has
  /// played or has no free slots.
  private func fill(limit fixedLimit: Int64? = nil) {
    guard session != 0 else { return }
    let played = ring.playedUntil(session: session) ?? 0
    let limit = fixedLimit ?? played + readAheadFrames
    while let reading = readings.filter({ !$0.isFinished }).min(by: { $0.nextFrame < $1.nextFrame }), reading.nextFrame < limit {
      if reading.nextFrame + Int64(ring.slotFrames) <= played {
        // Far behind (the disk was slow): skip to what's playing now rather than read audio
        // that would only be dropped.
        skip(reading, to: played)
        continue
      }
      let enqueued = ring.enqueue(session: session, start: reading.nextFrame) { left, right in
        read(reading, left: left, right: right)
      }
      guard enqueued else {
        // The ring is full of chunks still to play (or of a run that just ended, which the
        // render thread drops at its next render). Try again shortly.
        if fixedLimit == nil {
          queue.asyncAfter(deadline: .now() + .milliseconds(5)) { [self] in fill() }
        }
        break
      }
    }
    readings.removeAll(where: \.isFinished)
  }

  private func skip(_ reading: Reading, to frame: Int64) {
    let skipped = min(frame - reading.nextFrame, reading.frameCount - reading.produced)
    ring.recordMissed(Int(skipped))
    reading.produced += skipped
    reading.consumed = Int64((Double(reading.produced) * reading.file.processingFormat.sampleRate / outputRate).rounded())
    reading.converter?.reset()
  }

  /// Reads the next chunk of a reading into the slot's buffers; returns the frames written.
  private func read(_ reading: Reading, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Int {
    let wanted = Int(min(Int64(ring.slotFrames), reading.frameCount - reading.produced))
    guard wanted > 0 else { return 0 }
    let output: AVAudioPCMBuffer
    if let converter = reading.converter, let converted = reading.convertedBuffer {
      converted.frameLength = 0
      var conversionError: NSError?
      let status = converter.convert(to: converted, error: &conversionError) { packets, inputStatus in
        guard readFile(reading, frames: Int64(packets)) > 0 else {
          inputStatus.pointee = .endOfStream
          return nil
        }
        inputStatus.pointee = .haveData
        return reading.fileBuffer
      }
      guard status != .error else {
        finish(reading, error: conversionError)
        return 0
      }
      output = converted
    } else {
      guard readFile(reading, frames: Int64(wanted)) > 0 else {
        finish(reading, error: nil)
        return 0
      }
      output = reading.fileBuffer
    }

    let frames = min(Int(output.frameLength), wanted)
    guard frames > 0, let channels = output.floatChannelData else {
      finish(reading, error: nil)
      return 0
    }
    left.update(from: channels[0], count: frames)
    right.update(from: channels[output.format.channelCount > 1 ? 1 : 0], count: frames)
    reading.job.envelope.apply(to: [left, right], frameCount: frames, firstFrame: reading.produced, sampleRate: outputRate)
    reading.produced += Int64(frames)
    return frames
  }

  /// Reads up to `frames` of the region's file frames into its file buffer.
  private func readFile(_ reading: Reading, frames: Int64) -> AVAudioFrameCount {
    let remaining = reading.job.fileFrameCount - reading.consumed
    let count = AVAudioFrameCount(clamping: min(frames, remaining, Int64(reading.fileBuffer.frameCapacity)))
    guard count > 0 else { return 0 }
    do {
      reading.file.framePosition = reading.job.fileStartFrame + reading.consumed
      try reading.file.read(into: reading.fileBuffer, frameCount: count)
    } catch {
      finish(reading, error: error)
      return 0
    }
    reading.consumed += Int64(reading.fileBuffer.frameLength)
    return reading.fileBuffer.frameLength
  }

  private func finish(_ reading: Reading, error: (any Error)?) {
    reading.produced = reading.frameCount
    if let error {
      onError("“\(reading.job.url.lastPathComponent)” couldn’t be read: \(error.localizedDescription)")
    }
  }
}
