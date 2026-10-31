//
//  PlaybackEngine+Settings.swift
//  OngakuEngine
//

import AVFAudio
import CoreAudio
import Foundation
import OngakuCore

/// Where the engine plays and how big its I/O buffers are (the app's Audio settings).
public struct AudioOutputSettings: Equatable, Sendable {
  /// The output device's unique ID; `nil` plays through the system's default output.
  public var deviceUID: String?
  /// The I/O buffer size in frames; `nil` leaves the device's own setting.
  public var bufferFrames: Int?

  public init(deviceUID: String? = nil, bufferFrames: Int? = nil) {
    self.deviceUID = deviceUID
    self.bufferFrames = bufferFrames
  }
}

/// The file type recorded audio is written in.
public enum RecordingFileType: String, CaseIterable, Sendable {
  case caf, wav, aiff

  public var pathExtension: String {
    switch self {
    case .caf: "caf"
    case .wav: "wav"
    case .aiff: "aif"
    }
  }
}

/// The sample format recorded audio is written in.
public enum RecordingBitDepth: Int, CaseIterable, Sendable {
  case int16 = 16
  case int24 = 24
  case float32 = 32
}

/// How recording behaves (the app's Recording settings).
public struct RecordingOptions: Equatable, Sendable {
  /// Bars of clicks before recording starts; 0 starts straight away.
  public var countInBars: Int
  /// Whether the metronome clicks while recording even when it's switched off.
  public var clickWhileRecording: Bool
  public var fileType: RecordingFileType
  public var bitDepth: RecordingBitDepth

  public init(
    countInBars: Int = 0, clickWhileRecording: Bool = false, fileType: RecordingFileType = .caf,
    bitDepth: RecordingBitDepth = .int24
  ) {
    self.countInBars = countInBars
    self.clickWhileRecording = clickWhileRecording
    self.fileType = fileType
    self.bitDepth = bitDepth
  }
}

extension PlaybackEngine {
  /// Switches the output device and buffer size. Does nothing if they're unchanged, so it
  /// can be called whenever settings might have changed.
  public func apply(_ settings: AudioOutputSettings) {
    guard settings != outputSettings else { return }
    let deviceChanged = settings.deviceUID != outputSettings.deviceUID
    outputSettings = settings
    if deviceChanged {
      switchOutputDevice()
    } else {
      applyBufferSize()
    }
  }

  /// The device the engine is set to play through: the chosen one, or the system default if
  /// none was chosen or it isn't connected.
  private var wantedOutputDevice: AudioHardwareDevice? {
    outputSettings.deviceUID.flatMap(AudioOutputDevice.hardwareDevice(uid:))
      ?? (try? AudioHardwareSystem.shared.defaultOutputDevice) ?? nil
  }

  private func switchOutputDevice() {
    let currentID = engine.outputNode.withAUAudioUnit { $0.deviceID }
    guard let device = wantedOutputDevice, currentID != device.id else {
      applyBufferSize()
      return
    }
    let resumePosition = isPlaying && !isRecording ? playheadPosition : nil
    if isPlaying {
      stop()
    }
    engine.stop()
    let failure = engine.outputNode.withAUAudioUnit { unit -> (any Error)? in
      do {
        try unit.setDeviceID(device.id)
        return nil
      } catch {
        return error
      }
    }
    if let failure {
      let name = (try? device.name) ?? "The output device"
      lastErrorMessage("Ongaku Studio couldn’t switch to “\(name)”: \(failure.localizedDescription)")
    }
    // The new device may run at another sample rate, which instruments must render at.
    outputDidChange()
    if let resumePosition {
      startPlayback(from: resumePosition)
    }
  }

  /// Sets the I/O buffer size of the device being played through, within what it accepts.
  /// The size applies to Ongaku only; other apps keep their own.
  func applyBufferSize() {
    guard let frames = outputSettings.bufferFrames, let device = wantedOutputDevice else { return }
    let range = (try? device.bufferFrameSizeRange).map { Int($0.mMinimum)...Int($0.mMaximum) }
    let size = range.map { min(max(frames, $0.lowerBound), $0.upperBound) } ?? frames
    guard (try? device.bufferFrameSize) != size else { return }
    do {
      try device.setBufferFrameSize(size)
    } catch {
      lastErrorMessage("The buffer size couldn’t be set to \(size): \(error.localizedDescription)")
    }
  }

  /// Rebuilds the instruments at the output's (possibly new) sample rate and starts the
  /// engine again, after the output device changed.
  func outputDidChange() {
    // The input's format may have changed too: connect monitoring again.
    resetInputMonitoring()
    for track in project.tracks where track.kind == .softwareInstrument {
      if let instrument = instruments[track.id] {
        instrument.invalidate()
        loadInstrument(track.channel.instrument, into: instrument, for: track)
      }
    }
    startEngineIfNeeded()
    applyBufferSize()
  }

  /// Whether the metronome should be heard: when it's switched on, and while recording with
  /// a count-in or with Click While Recording.
  func updateMetronomeVolume() {
    let recordingClicks = session?.isRecording == true
      && (recordingOptions.clickWhileRecording || recordingOptions.countInBars > 0)
    metronome?.volume = isMetronomeEnabled || recordingClicks ? Float(min(max(metronomeSettings.level, 0), 1)) : 0
  }

  /// Whether the plan's clicks are scheduled: always outside recording (the volume decides
  /// whether they're heard, so switching the metronome on mid-song works), and while
  /// recording only if the metronome is on or should click while recording, so a count-in
  /// on its own stops clicking when recording starts.
  var schedulesPlanClicks: Bool {
    session?.isRecording != true || isMetronomeEnabled || recordingOptions.clickWhileRecording
  }
}
