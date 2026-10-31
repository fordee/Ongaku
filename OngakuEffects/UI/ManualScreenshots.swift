//
//  ManualScreenshots.swift
//  OngakuEffects
//

import AudioToolbox
import SwiftUI

// The plug-in windows as the manual shows them (Docs/Manual, chapter 8). Render these with
// the OngakuEffectsPreviews scheme active.

#Preview("Manual: Vocal Strip") {
  // Header, hint line and knobs, as every Ongaku effect has.
  PluginPreview(effect: .vocalStrip) { audioUnit in
    let readings: [(OngakuMeter, Float)] = [(.inputPeak, -9), (.outputPeak, -7), (.gainReduction, -3)]
    for (meter, value) in readings {
      audioUnit.meters[Int(meter.rawValue)] = value
    }
  }
}

#Preview("Manual: Retro Synth") {
  PluginPreview(effect: .retroSynth)
}

#Preview("Manual: Drum Machine") {
  PluginPreview(effect: .drumMachine)
}

#Preview("Manual: Sampler") {
  PluginPreview(effect: .sampler) { audioUnit in
    // A plucked note: a bright attack dying away over two seconds.
    let rate = 48_000.0
    let samples = (0..<Int(rate * 2)).map { frame -> Float in
      let time = Double(frame) / rate
      let tone = sin(2 * .pi * 110 * time) + 0.5 * sin(2 * .pi * 220 * time) + 0.25 * sin(2 * .pi * 330 * time)
      return Float(0.5 * tone * exp(-2.5 * time))
    }
    let sample = SamplerSampleBuffer(name: "Plucked Bass.wav", sampleRate: rate, channels: [samples])
    audioUnit.setSample(sample)
    // The window would hear about it a moment later; a preview is drawn straight away.
    audioUnit.samplerDisplay.name = sample.name
    audioUnit.samplerDisplay.duration = sample.duration
    audioUnit.samplerDisplay.channelCount = 1
    audioUnit.samplerDisplay.overview = sample.overview(count: 900)
  }
}

#Preview("Manual: Session Drummer") {
  PluginPreview(effect: .sessionDrummer)
}
