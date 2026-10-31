//
//  InputMonitor.swift
//  OngakuEngine
//

import AVFAudio
import AudioToolbox
import OngakuCore
import Synchronization

/// Plays audio input live through the channel strips of the tracks that monitor it (Logic's
/// Input Monitoring), so a singer hears themselves, and the track's plug-ins, as they sing.
///
///     input ─▶ sink ─▶ ring ─┬─▶ source (track A's channels) ─▶ track A's input
///                            └─▶ source (track B's channels) ─▶ track B's input
///
/// A tap would be simpler, but taps deliver large buffers late; here the sink node takes the
/// input in the same render cycles as the output, and each track's source node reads its
/// channels back out of the ring about a buffer later.
@MainActor
final class InputMonitor {
  private unowned let engine: AVAudioEngine
  private let ring: InputRing
  private let sink: AVAudioSinkNode
  private let format: AVAudioFormat
  private var sources: [Track.ID: (node: AVAudioSourceNode, input: AudioInputSelection)] = [:]

  /// Connects the engine's input to a new ring. `format` is what the tracks' sources play:
  /// stereo at the output's sample rate, which the input must match.
  init(engine: AVAudioEngine, format: AVAudioFormat) throws {
    let inputFormat = engine.inputNode.outputFormat(forBus: 0)
    guard inputFormat.channelCount > 0 else { throw MonitorError.noInput }
    guard inputFormat.sampleRate == format.sampleRate else {
      throw MonitorError.sampleRatesDiffer(input: inputFormat.sampleRate, output: format.sampleRate)
    }
    self.engine = engine
    self.format = format
    let ring = InputRing(channelCount: Int(inputFormat.channelCount))
    self.ring = ring
    sink = AVAudioSinkNode { _, frameCount, bufferList in
      ring.write(bufferList, frameCount: Int(frameCount))
      return noErr
    }
    engine.attach(sink)
    do {
      try engine.connectNode(engine.inputNode, to: sink, format: inputFormat)
    } catch {
      engine.detach(sink)
      throw error
    }
  }

  enum MonitorError: LocalizedError {
    case noInput
    case sampleRatesDiffer(input: Double, output: Double)

    var errorDescription: String? {
      switch self {
      case .noInput: "There’s no audio input to monitor."
      case .sampleRatesDiffer(let input, let output):
        "Input monitoring needs the input and output at the same sample rate (they’re \(Int(input)) and \(Int(output)) Hz). Set them to match in Audio MIDI Setup."
      }
    }
  }

  /// Monitors exactly these tracks: each plays its input channels into `destination`.
  func monitor(_ tracks: [(id: Track.ID, input: AudioInputSelection, destination: AVAudioMixerNode)]) {
    let wanted = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for (trackID, source) in sources where wanted[trackID]?.input != source.input {
      engine.detach(source.node)
      sources[trackID] = nil
    }
    for track in tracks where sources[track.id] == nil {
      let node = makeSource(for: track.input)
      engine.attach(node)
      let bus = engine.freeInputBus(on: track.destination, for: node)
      do {
        try engine.connectNode(node, to: track.destination, fromBus: 0, toBus: bus, format: format)
        sources[track.id] = (node, track.input)
      } catch {
        engine.detach(node)
      }
    }
  }

  /// Disconnects everything.
  func detach() {
    for source in sources.values {
      engine.detach(source.node)
    }
    sources = [:]
    engine.detach(sink)
  }

  private func makeSource(for input: AudioInputSelection) -> AVAudioSourceNode {
    let reader = InputRing.Reader(
      left: min(input.firstChannel, ring.channelCount - 1),
      right: min(input.firstChannel + (input.isStereo ? 1 : 0), ring.channelCount - 1))
    let ring = ring
    return AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList in
      if !ring.read(into: bufferList, frameCount: Int(frameCount), with: reader) {
        isSilence.pointee = true
      }
      return noErr
    }
  }
}

/// The input's recent samples, one ring per hardware channel. One writer (the sink, on the
/// input's render thread) and any number of readers (the sources, on the output's), each
/// with its own position. Real-time rules: no allocation, locks or reference counting while
/// rendering, only atomics and preallocated memory.
final class InputRing: @unchecked Sendable {
  let channelCount: Int
  /// Frames kept per channel: a power of two, far more than readers ever lag.
  private static let capacity = 16_384
  private let samples: UnsafeMutablePointer<Float>
  /// Frames written so far; the newest frame is `written - 1`.
  private let written = Atomic<Int64>(0)

  init(channelCount: Int) {
    self.channelCount = max(1, channelCount)
    samples = .allocate(capacity: self.channelCount * Self.capacity)
    samples.initialize(repeating: 0, count: self.channelCount * Self.capacity)
  }

  deinit {
    samples.deallocate()
  }

  func write(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: Int) {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
    let start = written.load(ordering: .relaxed)
    // The input's buffers are one per channel (the engine's standard, deinterleaved format).
    for channel in 0..<min(channelCount, buffers.count) {
      guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
      let destination = samples + channel * Self.capacity
      for frame in 0..<frameCount {
        destination[Int((start + Int64(frame)) & Int64(Self.capacity - 1))] = data[frame]
      }
    }
    written.store(start + Int64(frameCount), ordering: .releasing)
  }

  /// Where one source reads from: which channels, and how far it has read. Only the render
  /// thread touches `position`.
  final class Reader: @unchecked Sendable {
    let left: Int
    let right: Int
    var position: Int64 = -1

    init(left: Int, right: Int) {
      self.left = left
      self.right = right
    }
  }

  /// Copies the reader's channels into a stereo buffer list (a mono input goes to both
  /// sides). Returns `false`, writing silence, until there's input to play.
  func read(into bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int, with reader: Reader) -> Bool {
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    let newest = written.load(ordering: .acquiring)
    let lag = newest - reader.position
    // Keep between one and two buffers behind the input: start there, and go back there if
    // the input and output cycles have drifted apart.
    if reader.position < 0 || lag < Int64(frameCount) || lag > Int64(4 * frameCount) {
      reader.position = newest - Int64(2 * frameCount)
    }
    guard reader.position >= 0 else {
      for buffer in buffers {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
      }
      return false
    }
    for (index, buffer) in buffers.enumerated() {
      guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
      let source = samples + (index == 0 ? reader.left : reader.right) * Self.capacity
      for frame in 0..<frameCount {
        data[frame] = source[Int((reader.position + Int64(frame)) & Int64(Self.capacity - 1))]
      }
    }
    reader.position += Int64(frameCount)
    return true
  }
}
