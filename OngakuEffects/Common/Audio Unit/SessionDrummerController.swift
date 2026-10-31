//
//  SessionDrummerController.swift
//  OngakuEffects
//

import AudioToolbox
import Foundation
import OngakuCore

/// The Session Drummer's song, and the part it plays: the song's hits, laid out in the
/// host's meter and handed to the render thread. The song is saved with the plug-in's state.
/// Callable from any thread.
final class SessionDrummerController: @unchecked Sendable {
  static let stateKey = "ongakuDrummerSong"

  private let kernel: UnsafeMutablePointer<OngakuEffectsDSPKernel>
  private let meters: UnsafeMutablePointer<Float>
  private let lock = NSLock()
  private var storedSong: DrummerSong
  private var storedSignature = TimeSignature.fourFour
  /// The part the render thread has, and its hits (freed a while after being replaced).
  private var part: UnsafeMutablePointer<DrummerPart>?
  private var hits: UnsafeMutablePointer<DrummerHit>?
  private let queue = DispatchQueue(label: "net.4dware.Ongaku.OngakuEffects.drummer")
  private var watcher: DispatchSourceTimer?

  /// Told (on the main thread) when the song changes from outside the window: a restored
  /// state, a preset.
  var onSongReplaced: (@MainActor @Sendable (DrummerSong) -> Void)?

  init(kernel: UnsafeMutablePointer<OngakuEffectsDSPKernel>, meters: UnsafeMutablePointer<Float>) {
    self.kernel = kernel
    self.meters = meters
    storedSong = DrummerSong.starter(style: .rock, seed: 1)
    rebuild()
    // The host's meter isn't known until it plays: watch for it and lay the part out again
    // when it changes.
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
    timer.setEventHandler { [weak self] in self?.checkSignature() }
    timer.resume()
    watcher = timer
  }

  deinit {
    watcher?.cancel()
    kernel.pointee.setDrummerPart(nil)
    kernel.pointee.setAppleKit(nil)
    // The render thread has stopped with the Audio Unit; nothing else holds these.
    free(part: part, hits: hits)
    if let appleKit { Self.dispose(appleKit) }
  }

  // MARK: - Apple's kits

  /// The General MIDI drum kits built into macOS, by the Kit parameter (1–6): their
  /// programs in the system's sound bank.
  static let appleKitPrograms: [UInt8] = [0, 16, 24, 25, 40, 48]
  private static let soundBank = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

  /// Apple's sampler with the kit loaded, playing instead of the Drum Machine.
  private var appleKit: AudioUnit?
  private var loadedKit: (index: Int, sampleRate: Double, maximumFrames: UInt32) = (0, 0, 0)

  /// Plays one of Apple's kits (1–6), or the Drum Machine (0). `waiting` loads it before
  /// returning (before rendering starts); otherwise it loads in the background and takes
  /// over when ready.
  func setKit(_ index: Int, sampleRate: Double, maximumFrames: UInt32, waiting: Bool = false) {
    let load: @Sendable () -> Void = { [weak self] in self?.loadKit(index, sampleRate: sampleRate, maximumFrames: maximumFrames) }
    if waiting { queue.sync(execute: load) } else { queue.async(execute: load) }
  }

  /// On the queue.
  private func loadKit(_ index: Int, sampleRate: Double, maximumFrames: UInt32) {
    let wanted = (index, sampleRate, maximumFrames)
    guard wanted != loadedKit else { return }
    loadedKit = wanted
    let unit = index >= 1 && index <= Self.appleKitPrograms.count && sampleRate > 0
      ? Self.makeAppleKit(program: Self.appleKitPrograms[index - 1], sampleRate: sampleRate, maximumFrames: maximumFrames)
      : nil
    let old = appleKit
    appleKit = unit
    kernel.pointee.setAppleKit(unit)
    // The render thread may still be playing the old one for a moment.
    if let old { queue.asyncAfter(deadline: .now() + 2) { Self.dispose(old) } }
  }

  private static func makeAppleKit(program: UInt8, sampleRate: Double, maximumFrames: UInt32) -> AudioUnit? {
    var description = AudioComponentDescription(
      componentType: kAudioUnitType_MusicDevice, componentSubType: kAudioUnitSubType_Sampler,
      componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let component = AudioComponentFindNext(nil, &description) else { return nil }
    var instance: AudioUnit?
    guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else { return nil }
    var format = AudioStreamBasicDescription(
      mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved, mBytesPerPacket: 4,
      mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var frames = max(maximumFrames, 4_096)
    guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format,
        UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr,
      AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames,
        UInt32(MemoryLayout<UInt32>.size)) == noErr,
      AudioUnitInitialize(unit) == noErr
    else {
      AudioComponentInstanceDispose(unit)
      return nil
    }
    // The URL must stay alive while the sampler reads it.
    let bank = soundBank as CFURL
    let loaded = withExtendedLifetime(bank) {
      var instrument = AUSamplerInstrumentData(
        fileURL: Unmanaged.passUnretained(bank), instrumentType: UInt8(kInstrumentType_DLSPreset),
        bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB), bankLSB: UInt8(kAUSampler_DefaultBankLSB), presetID: program)
      return AudioUnitSetProperty(unit, kAUSamplerProperty_LoadInstrument, kAudioUnitScope_Global, 0, &instrument,
        UInt32(MemoryLayout<AUSamplerInstrumentData>.size))
    }
    guard loaded == noErr else {
      dispose(unit)
      return nil
    }
    return unit
  }

  private static func dispose(_ unit: AudioUnit) {
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
  }

  var song: DrummerSong {
    lock.lock()
    defer { lock.unlock() }
    return storedSong
  }

  var signature: TimeSignature {
    lock.lock()
    defer { lock.unlock() }
    return storedSignature
  }

  /// Plays a new song from the next render.
  func setSong(_ song: DrummerSong) {
    lock.lock()
    storedSong = song
    lock.unlock()
    rebuild()
  }

  // MARK: - State

  var state: Data? { try? JSONEncoder().encode(song) }

  func restore(_ data: Data?) {
    guard let data, let song = try? JSONDecoder().decode(DrummerSong.self, from: data) else { return }
    setSong(song)
    let notify = onSongReplaced
    DispatchQueue.main.async { MainActor.assumeIsolated { notify?(song) } }
  }

  // MARK: - The part

  private func checkSignature() {
    let encoded = Int(OngakuMeterValue(meters, .signature))
    let beats = encoded / 100, unit = encoded % 100
    let signature = TimeSignature(beatsPerBar: beats, beatUnit: unit)
    guard signature.isValid, signature != self.signature else { return }
    lock.lock()
    storedSignature = signature
    lock.unlock()
    rebuild()
  }

  /// Lays the song out as hits in quarter notes and hands them to the render thread.
  private func rebuild() {
    lock.lock()
    let song = storedSong
    let signature = storedSignature
    lock.unlock()

    let notes = song.notes(in: signature).sorted { $0.start < $1.start }
    let newHits = UnsafeMutablePointer<DrummerHit>.allocate(capacity: max(1, notes.count))
    for (index, note) in notes.enumerated() {
      newHits[index] = DrummerHit(
        beat: note.start.quarterNotes, note: UInt8(clamping: note.pitch), velocity: UInt8(clamping: note.velocity))
    }
    let length = song.lengthInQuarterNotes(in: signature)
    // A song that doesn't repeat carries on with its last section.
    let lastBars = song.sections.last.map { max(1, $0.bars) } ?? 0
    let loopStart = song.repeats ? 0 : length - (signature.ticksPerBar * Int64(lastBars)).quarterNotes
    let newPart = UnsafeMutablePointer<DrummerPart>.allocate(capacity: 1)
    newPart.initialize(to: DrummerPart(length: length, loopStart: loopStart, count: Int32(notes.count), hits: newHits))

    lock.lock()
    let oldPart = part, oldHits = hits
    part = newPart
    hits = newHits
    kernel.pointee.setDrummerPart(newPart)
    lock.unlock()
    // The render thread may still be reading the old one for a moment.
    queue.asyncAfter(deadline: .now() + 2) { Self.free(part: oldPart, hits: oldHits) }
  }

  private static func free(part: UnsafeMutablePointer<DrummerPart>?, hits: UnsafeMutablePointer<DrummerHit>?) {
    part?.deallocate()
    hits?.deallocate()
  }

  private func free(part: UnsafeMutablePointer<DrummerPart>?, hits: UnsafeMutablePointer<DrummerHit>?) {
    Self.free(part: part, hits: hits)
  }
}
