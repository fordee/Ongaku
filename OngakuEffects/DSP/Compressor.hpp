//
//  Compressor.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <span>

#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

/// A feed-forward compressor in the style of Logic's: a stereo-linked peak or RMS
/// detector, a soft-knee gain curve, attack and release smoothing in decibels, then
/// make-up gain (or automatic make-up) and a dry/wet mix.
class Compressor {
public:
  static constexpr AUParameterAddress firstAddress = compThreshold;
  static constexpr int parameterCount = compDetection - compThreshold + 1;

  /// What the static curve does to a level: the output level for an input level, both in
  /// dB, with the knee smoothing the corner (Giannoulis, Massberg and Reiss).
  static float curve(float input, float threshold, float ratio, float knee) {
    float over = input - threshold;
    if (2 * over < -knee) return input;
    if (knee > 0 && 2 * std::abs(over) <= knee) {
      float into = over + knee / 2;
      return input + (1 / ratio - 1) * into * into / (2 * knee);
    }
    return threshold + over / ratio;
  }

  /// The gain automatic make-up adds: half of what a full-scale signal loses, so typical
  /// material comes back to about its original loudness.
  static float autoMakeUp(float threshold, float ratio, float knee) {
    return -curve(0, threshold, ratio, knee) / 2;
  }

  Compressor() {
    mTargets.fill(0);
  }

  void setParameter(AUParameterAddress address, float value) {
    if (address >= firstAddress && address < firstAddress + parameterCount) mTargets[address - firstAddress] = value;
  }

  float parameter(AUParameterAddress address) const {
    return address >= firstAddress && address < firstAddress + parameterCount ? mTargets[address - firstAddress] : 0;
  }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = channelCount;
    reset();
  }

  void reset() {
    mReduction = 0;
    mMeanSquare = 0;
    mPeak = 0;
    mOutputGain = outputGainTarget();
  }

  /// The most gain reduction in the last block (dB, zero or less), and the input and
  /// output peaks (dB), for meters.
  float lastReduction = 0, lastInputPeak = -120, lastOutputPeak = -120;

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    float threshold = value(compThreshold);
    float ratio = std::max(1.0f, value(compRatio));
    float knee = std::max(0.0f, value(compKnee));
    float attack = coefficient(std::max(0.05f, value(compAttack)));
    float release = coefficient(std::max(1.0f, value(compRelease)));
    bool rms = value(compDetection) >= 0.5f;
    float rmsCoefficient = coefficient(10);
    float peakDecay = coefficient(20);
    float mix = std::clamp(value(compMix) / 100, 0.0f, 1.0f);

    float gainStart = mOutputGain;
    float gainEnd = outputGainTarget();
    mOutputGain = gainEnd;

    float mostReduction = 0, inputPeak = 0, outputPeak = 0;
    for (int i = 0; i < frameCount; ++i) {
      // Stereo-linked detection: the loudest channel drives every channel's gain.
      float peak = 0, square = 0;
      for (int c = 0; c < channels; ++c) {
        float sample = inputs[c][i];
        peak = std::max(peak, std::abs(sample));
        square = std::max(square, sample * sample);
      }
      inputPeak = std::max(inputPeak, peak);
      float level;
      if (rms) {
        mMeanSquare = rmsCoefficient * mMeanSquare + (1 - rmsCoefficient) * square;
        // A sine's RMS is 3 dB under its peak; doubling the mean square reads a sine at its
        // peak level, so the threshold means the same in both modes.
        level = 10 * std::log10(std::max(2 * mMeanSquare, 1e-12f));
      } else {
        // Peaks are held and fall away over 20 ms, so the detector follows the waveform's
        // peaks rather than dropping at every zero crossing.
        mPeak = std::max(peak, peakDecay * mPeak);
        level = 20 * std::log10(std::max(mPeak, 1e-6f));
      }

      float wanted = curve(level, threshold, ratio, knee) - level;
      float smoothing = wanted < mReduction ? attack : release;
      mReduction = smoothing * mReduction + (1 - smoothing) * wanted;
      mostReduction = std::min(mostReduction, mReduction);

      float makeUp = gainStart + (gainEnd - gainStart) * float(i + 1) / float(frameCount);
      float gain = std::pow(10.0f, mReduction / 20) * makeUp;
      for (int c = 0; c < channels; ++c) {
        float dry = inputs[c][i];
        float out = dry * (mix * gain + (1 - mix));
        outputs[c][i] = out;
        outputPeak = std::max(outputPeak, std::abs(out));
      }
    }
    if (std::abs(mReduction) < 1e-6f) mReduction = 0;
    if (mMeanSquare < 1e-20f) mMeanSquare = 0;
    if (mPeak < 1e-10f) mPeak = 0;
    lastReduction = mostReduction;
    lastInputPeak = 20 * std::log10(std::max(inputPeak, 1e-6f));
    lastOutputPeak = 20 * std::log10(std::max(outputPeak, 1e-6f));
  }

private:
  float value(AUParameterAddress address) const { return mTargets[address - firstAddress]; }

  /// A one-pole smoothing coefficient for a time in milliseconds.
  float coefficient(float milliseconds) const {
    return std::exp(-1.0f / (milliseconds * 0.001f * float(mSampleRate)));
  }

  float outputGainTarget() const {
    float makeUp = value(compMakeUp);
    if (value(compAutoGain) >= 0.5f) {
      makeUp += autoMakeUp(value(compThreshold), std::max(1.0f, value(compRatio)), std::max(0.0f, value(compKnee)));
    }
    return std::pow(10.0f, makeUp / 20);
  }

  std::array<float, parameterCount> mTargets;
  double mSampleRate = 44100;
  int mChannelCount = 0;
  float mReduction = 0;
  float mMeanSquare = 0;
  float mPeak = 0;
  float mOutputGain = 1;
};

}  // namespace ongaku
