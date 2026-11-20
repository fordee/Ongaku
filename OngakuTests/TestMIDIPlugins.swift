//
//  TestMIDIPlugins.swift
//  OngakuTests
//

import AudioToolbox
import AVFAudio
import CoreMIDI
import OngakuCore
import Synchronization

/// Tiny Audio Units for testing how other makers' plug-ins are hosted, registered in
/// process: a MIDI effect that plays every note an octave up, an instrument that only writes
/// down the notes it's given, and an effect that plays only what reaches its side chain.
enum TestMIDIPlugins {
  static let manufacturer: UInt32 = 0x5465_7374  // 'Test'

  static let transposer = AudioComponentDescription(
    componentType: kAudioUnitType_MIDIProcessor, componentSubType: 0x6F63_7476,  // 'octv'
    componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)

  static let recorder = AudioComponentDescription(
    componentType: kAudioUnitType_MusicDevice, componentSubType: 0x7265_6364,  // 'recd'
    componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)

  static let sidechainListener = AudioComponentDescription(
    componentType: kAudioUnitType_Effect, componentSubType: 0x7364_6368,  // 'sdch'
    componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)

  static let twoOutputInstrument = AudioComponentDescription(
    componentType: kAudioUnitType_MusicDevice, componentSubType: 0x6D6F_7574,  // 'mout'
    componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)

  /// Registers them, once. The app is sandboxed, so only sandbox-safe components are found.
  static let register: Void = {
    for (subclass, description, name) in [
      (TestTransposer.self as AUAudioUnit.Type, transposer, "Test: Octave Up"),
      (TestNoteRecorder.self, recorder, "Test: Note Recorder"),
      (TestSidechainListener.self, sidechainListener, "Test: Side Chain Listener"),
      (TestTwoOutputInstrument.self, twoOutputInstrument, "Test: Two Outputs"),
    ] {
      var registered = description
      registered.componentFlags = AudioComponentFlags.sandboxSafe.rawValue
      AUAudioUnit.registerSubclass(subclass, as: registered, name: name, version: 1)
    }
  }()
}

/// The MIDI 1.0 messages in a render event list: the old byte events, and UMP event lists
/// (MIDI 1.0 channel voice messages only, which is all these tests send).
private func forEachMessage(in head: UnsafePointer<AURenderEvent>?, _ body: (AUEventSampleTime, [UInt8]) -> Void) {
  var event = head
  while let current = event {
    switch current.pointee.head.eventType {
    case .MIDI:
      let midi = current.pointee.MIDI
      let bytes = withUnsafeBytes(of: midi.data) { Array($0.prefix(Int(midi.length))) }
      body(midi.eventSampleTime, bytes)
    case .midiEventList:
      let list = current.pointee.MIDIEventsList
      var eventList = list.eventList
      withUnsafePointer(to: &eventList) { pointer in
        for packet in pointer.unsafeSequence() {
          let words = packet.words()
          guard let word = words.first, word >> 28 == 0x2 else { continue }
          body(list.eventSampleTime, [UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F)])
        }
      }
    default:
      break
    }
    event = UnsafePointer(current.pointee.head.next)
  }
}

private class TestAudioUnit: AUAudioUnit {
  private var outputs: AUAudioUnitBusArray!

  override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
    try super.init(componentDescription: componentDescription, options: options)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
  }

  override var outputBusses: AUAudioUnitBusArray { outputs }

  /// Where it renders when the host doesn't give it buffers of its own (as for a MIDI
  /// effect, whose audio output isn't connected).
  private var ownBuffer: AVAudioPCMBuffer?

  override func allocateRenderResources() throws {
    try super.allocateRenderResources()
    ownBuffer = AVAudioPCMBuffer(pcmFormat: outputs[0].format, frameCapacity: maximumFramesToRender)
  }

  override func deallocateRenderResources() {
    ownBuffer = nil
    super.deallocateRenderResources()
  }

  /// Silence, which is all either of them plays, into the host's buffers or its own.
  func silence(_ frameCount: AUAudioFrameCount, into data: UnsafeMutablePointer<AudioBufferList>) {
    let own = ownBuffer.map { UnsafeMutableAudioBufferListPointer($0.mutableAudioBufferList) }
    for (index, var buffer) in UnsafeMutableAudioBufferListPointer(data).enumerated() {
      if buffer.mData == nil, let own, index < own.count {
        buffer.mData = own[index].mData
      }
      buffer.mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
      if let pointer = buffer.mData { memset(pointer, 0, Int(buffer.mDataByteSize)) }
      UnsafeMutableAudioBufferListPointer(data)[index] = buffer
    }
  }
}

private final class TestTransposer: TestAudioUnit {
  /// The sample time of each render, for tests.
  static let renders = Mutex<[Double]>([])

  override var midiOutputNames: [String] { ["MIDI Out"] }

  override var internalRenderBlock: AUInternalRenderBlock {
    { [unowned self] _, timestamp, frameCount, _, data, events, _ in
      TestTransposer.renders.withLock { $0.append(timestamp.pointee.mSampleTime) }
      self.silence(frameCount, into: data)
      forEachMessage(in: events) { sampleTime, bytes in
        var moved = bytes
        if bytes.count == 3, (0x80...0x9F).contains(bytes[0]) { moved[1] = min(127, bytes[1] + 12) }
        self.send(moved, at: sampleTime)
      }
      return noErr
    }
  }

  private func send(_ bytes: [UInt8], at sampleTime: AUEventSampleTime) {
    if let output = midiOutputEventListBlock {
      var list = MIDIEventList()
      let packet = MIDIEventListInit(&list, ._1_0)
      var word = UInt32(0x2000_0000) | UInt32(bytes[0]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes.count > 2 ? bytes[2] : 0)
      _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, 0, 1, &word)
      _ = output(sampleTime, 0, &list)
    } else if let output = midiOutputEventBlock {
      var bytes = bytes
      _ = output(sampleTime, 0, bytes.count, &bytes)
    }
  }
}

private final class TestNoteRecorder: TestAudioUnit {
  /// Every note-on any recorder has been given: pitch, and the sample time it came at.
  static let noteOns = Mutex<[(pitch: Int, sampleTime: AUEventSampleTime)]>([])

  override var internalRenderBlock: AUInternalRenderBlock {
    { [unowned self] _, _, frameCount, _, data, events, _ in
      self.silence(frameCount, into: data)
      forEachMessage(in: events) { sampleTime, bytes in
        guard bytes.count == 3, bytes[0] & 0xF0 == 0x90, bytes[2] > 0 else { return }
        TestNoteRecorder.noteOns.withLock { $0.append((Int(bytes[1]), sampleTime)) }
      }
      return noErr
    }
  }
}

/// An effect with a main input and a side chain input that plays only its side chain.
private final class TestSidechainListener: AUAudioUnit {
  private var inputs: AUAudioUnitBusArray!
  private var outputs: AUAudioUnitBusArray!

  override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
    try super.init(componentDescription: componentDescription, options: options)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let main = try AUAudioUnitBus(format: format)
    let sidechain = try AUAudioUnitBus(format: format)
    sidechain.name = "Side Chain"
    inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [main, sidechain])
    outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
  }

  override var inputBusses: AUAudioUnitBusArray { inputs }
  override var outputBusses: AUAudioUnitBusArray { outputs }

  override var internalRenderBlock: AUInternalRenderBlock {
    { flags, timestamp, frameCount, _, data, _, pullInput in
      // Render the side chain straight into the output: with no buffers from the host, the
      // side chain's own are passed on.
      guard let pullInput else { return kAudioUnitErr_NoConnection }
      var pullFlags = AudioUnitRenderActionFlags()
      return pullInput(&pullFlags, timestamp, frameCount, 1, data)
    }
  }
}

/// An instrument with two outputs: its first is silent, and its second ("Rim") plays a
/// 1 kHz tone at half level all the time.
private final class TestTwoOutputInstrument: AUAudioUnit {
  private var outputs: AUAudioUnitBusArray!
  private var phase = 0.0
  private var ownBuffers: [AVAudioPCMBuffer] = []

  override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
    try super.init(componentDescription: componentDescription, options: options)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let main = try AUAudioUnitBus(format: format)
    main.name = "Main"
    let rim = try AUAudioUnitBus(format: format)
    rim.name = "Rim"
    outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [main, rim])
  }

  override var outputBusses: AUAudioUnitBusArray { outputs }

  override func allocateRenderResources() throws {
    try super.allocateRenderResources()
    ownBuffers = (0..<2).compactMap { AVAudioPCMBuffer(pcmFormat: outputs[$0].format, frameCapacity: maximumFramesToRender) }
  }

  override var internalRenderBlock: AUInternalRenderBlock {
    { [unowned self] _, timestamp, frameCount, bus, data, _, _ in
      let list = UnsafeMutableAudioBufferListPointer(data)
      for index in list.indices {
        if list[index].mData == nil, bus < ownBuffers.count {
          list[index].mData = UnsafeMutableRawPointer(ownBuffers[bus].floatChannelData![min(index, 1)])
        }
        list[index].mDataByteSize = frameCount * 4
      }
      // Each render of a bus starts at the timestamp's sample, so both buses keep time.
      let start = timestamp.pointee.mSampleTime
      for index in list.indices {
        guard let samples = list[index].mData?.assumingMemoryBound(to: Float.self) else { continue }
        for frame in 0..<Int(frameCount) {
          samples[frame] = bus == 1 ? Float(0.5 * sin(2 * .pi * 1_000 * (start + Double(frame)) / 48_000)) : 0
        }
      }
      return noErr
    }
  }
}

extension TestMIDIPlugins {
  static var recordedNoteOns: [(pitch: Int, sampleTime: AUEventSampleTime)] {
    TestNoteRecorder.noteOns.withLock { $0 }
  }

  static func clearRecordedNotes() {
    TestNoteRecorder.noteOns.withLock { $0.removeAll() }
  }

  static var transposerRenders: [Double] { TestTransposer.renders.withLock { $0 } }
}

extension PluginReference {
  init(description: AudioComponentDescription, name: String) {
    self.init(
      componentType: description.componentType, componentSubType: description.componentSubType,
      componentManufacturer: description.componentManufacturer, name: name)
  }
}
