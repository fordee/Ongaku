//
//  PluginCheck.swift
//  OngakuEngine
//

import AVFAudio
import AudioToolbox
import OngakuCore

/// Tries an installed plug-in the way a song would use it, as Logic's Plug-in Manager
/// validates plug-ins: it loads out of process, takes the song's format and gets ready to
/// render. Apple's `auval` can't run from a sandboxed app, and asking for a component's
/// `passesAUVal` can hang, so this is Ongaku's own check.
public enum PluginCheck {
  public enum Result: Sendable, Equatable {
    /// It loaded and is ready to play, after this many seconds.
    case passed(seconds: Double)
    case failed(String)

    public var passed: Bool {
      if case .passed = self { return true }
      return false
    }
  }

  /// How long a plug-in may take to start before it counts as failed.
  public static let timeLimit: Duration = .seconds(15)

  /// Checks one plug-in. A plug-in that takes too long is left to finish starting on its
  /// own (loading can't be cancelled); it fails the check either way.
  @MainActor
  public static func check(_ entry: InstrumentLibrary.Entry, timeLimit: Duration = timeLimit) async -> Result {
    let started = ContinuousClock.now
    let description = AudioComponentDescription(
      componentType: entry.componentType, componentSubType: entry.componentSubType,
      componentManufacturer: entry.componentManufacturer, componentFlags: 0, componentFlagsMask: 0)
    let unit: AVAudioUnit
    switch await load(description, timeLimit: timeLimit) {
    case .loaded(let loaded): unit = loaded
    case .failed(let error): return .failed("It couldn’t be loaded: \(error.localizedDescription)")
    case .timedOut: return .failed("It didn’t start within \(timeLimit.components.seconds) seconds.")
    }
    if let problem = problem(with: unit, kind: entry.componentType) {
      return .failed(problem)
    }
    return .passed(seconds: (ContinuousClock.now - started) / .seconds(1))
  }

  /// What stops a loaded plug-in from playing in a song, if anything: it must take the
  /// song's format (stereo at 48 kHz), get ready to render, and take MIDI if it's played
  /// with notes.
  @MainActor
  private static func problem(with unit: AVAudioUnit, kind componentType: UInt32) -> String? {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else { return nil }
    return unit.withAUAudioUnit { audioUnit -> String? in
      let takesMIDI = [kAudioUnitType_MusicDevice, kAudioUnitType_MusicEffect, kAudioUnitType_MIDIProcessor].contains(componentType)
      if takesMIDI, audioUnit.scheduleMIDIEventBlock == nil {
        return "It doesn’t take MIDI notes."
      }
      if componentType != kAudioUnitType_MIDIProcessor {
        guard audioUnit.outputBusses.count > 0 else { return "It has no audio output." }
        do {
          try audioUnit.outputBusses[0].setFormat(format)
          if audioUnit.inputBusses.count > 0 {
            try audioUnit.inputBusses[0].setFormat(format)
          }
        } catch {
          return "It doesn’t work in stereo at 48 kHz."
        }
      }
      do {
        try audioUnit.allocateRenderResources()
      } catch {
        return "It couldn’t get ready to play: \(error.localizedDescription)"
      }
      audioUnit.deallocateRenderResources()
      return nil
    }
  }

  private enum Loading {
    case loaded(AVAudioUnit)
    case failed(any Error)
    case timedOut
  }

  /// Loads a plug-in out of process, or gives up after `timeLimit`, whichever comes first.
  @MainActor
  private static func load(_ description: AudioComponentDescription, timeLimit: Duration) async -> Loading {
    await withCheckedContinuation { (continuation: CheckedContinuation<Loading, Never>) in
      var isFinished = false
      func finish(_ outcome: Loading) {
        guard !isFinished else { return }
        isFinished = true
        continuation.resume(returning: outcome)
      }
      Task { @MainActor in
        do {
          finish(.loaded(try await AVAudioUnit.instantiate(with: description, options: [.loadOutOfProcess])))
        } catch {
          finish(.failed(error))
        }
      }
      Task { @MainActor in
        try? await Task.sleep(for: timeLimit)
        finish(.timedOut)
      }
    }
  }
}
