//
//  AudioEnvelope+Apply.swift
//  OngakuEngine
//

import Accelerate
import OngakuCore

extension AudioEnvelope {
  /// Scales samples by the envelope. `firstFrame` is how far into the segment the first
  /// sample is, at `sampleRate`. Called on reading queues, not the render thread.
  func apply(to channels: [UnsafeMutablePointer<Float>], frameCount: Int, firstFrame: Int64, sampleRate: Double) {
    guard frameCount > 0 else { return }
    if isConstant {
      guard gain != 1 else { return }
      var scale = Float(gain)
      for samples in channels {
        vDSP_vsmul(samples, 1, &scale, samples, 1, vDSP_Length(frameCount))
      }
      return
    }
    for index in 0..<frameCount {
      let level = Float(level(atSecondsIntoSegment: Double(firstFrame + Int64(index)) / sampleRate))
      for samples in channels {
        samples[index] *= level
      }
    }
  }
}
