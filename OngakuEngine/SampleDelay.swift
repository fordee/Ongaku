//
//  SampleDelay.swift
//  OngakuEngine
//

import AVFAudio
import AudioToolbox

/// Delays audio by an exact number of samples, for plug-in delay compensation: it goes on
/// the connections that would otherwise arrive early (see `DelayCompensation`).
///
/// It uses Apple's AUSampleDelay, which delays by whole samples without filtering or
/// changing the level (AVAudioEngine's delay effect does both). One unit delays by up to
/// `maximumPerUnit` samples; longer delays chain several.
@MainActor
enum SampleDelay {
  /// AUSampleDelay's longest delay, in samples (about 92 ms at 48 kHz).
  static let maximumPerUnit = 4_410

  private static let description = AudioComponentDescription(
    componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_SampleDelay,
    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)

  /// How many units a delay needs.
  static func unitCount(for frames: Int) -> Int {
    frames <= 0 ? 0 : (frames + maximumPerUnit - 1) / maximumPerUnit
  }

  static func makeUnit() -> AVAudioUnitEffect {
    AVAudioUnitEffect(audioComponentDescription: description)
  }

  /// Shares `frames` out over a chain of units made for it.
  static func set(_ units: [AVAudioUnitEffect], to frames: Int) {
    var remaining = max(0, frames)
    for unit in units {
      let share = min(remaining, maximumPerUnit)
      remaining -= share
      unit.withAUAudioUnit { audioUnit in
        audioUnit.parameterTree?.parameter(withAddress: AUParameterAddress(kSampleDelayParam_DelayFrames))?.value = AUValue(share)
      }
    }
  }
}
