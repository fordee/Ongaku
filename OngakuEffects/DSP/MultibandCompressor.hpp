//
//  MultibandCompressor.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <span>

#include "Biquad.hpp"
#include "Compressor.hpp"
#include "Dynamics.hpp"
#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

/// A three-band compressor, like Logic's Multipressor: the sound split into lows, mids and
/// highs at two crossovers, each band compressed on its own (both sides linked), then put
/// back together. The crossovers are Linkwitz–Riley (24 dB an octave), and the lows also go
/// through the high crossover's all-pass, so with no compression the bands add back up to
/// the original's level at every frequency.
class MultibandCompressor {
public:
  static constexpr int bandCount = 3;
  static constexpr float knee = 6;

  static AUParameterAddress address(int band, OngakuBandField field) {
    return mbcFirstBand + 10 * band + field;
  }

  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::min(channelCount, maximumChannels);
    for (auto &channel : mChannels) channel = Channel();
    mReductions.fill(0);
    mGainDB.fill(0);
    mLowCrossover = mHighCrossover = -1;
  }

  PeakMeters meters;
  float reduction(int band) const { return mReductions[size_t(std::clamp(band, 0, bandCount - 1))]; }

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    if (channels == 0) return;
    updateCrossovers();
    float attack = smoothingCoefficient(std::clamp(mParameters[mbcAttack], 0.5f, 200.0f), mSampleRate);
    float release = smoothingCoefficient(std::clamp(mParameters[mbcRelease], 10.0f, 2000.0f), mSampleRate);
    float output = linear(std::clamp(mParameters[mbcOutput], -24.0f, 24.0f));
    std::array<float, bandCount> threshold, ratio, makeUp;
    for (int band = 0; band < bandCount; ++band) {
      threshold[size_t(band)] = std::clamp(mParameters[address(band, OngakuBandFieldThreshold)], -60.0f, 0.0f);
      ratio[size_t(band)] = std::clamp(mParameters[address(band, OngakuBandFieldRatio)], 1.0f, 20.0f);
      makeUp[size_t(band)] = linear(std::clamp(mParameters[address(band, OngakuBandFieldMakeUp)], -24.0f, 24.0f));
    }
    std::array<float, bandCount> deepest {};
    for (int i = 0; i < frameCount; ++i) {
      // Split each side into its three bands.
      std::array<std::array<float, bandCount>, maximumChannels> bands {};
      std::array<float, bandCount> peaks {};
      for (int c = 0; c < channels; ++c) {
        Channel &state = mChannels[size_t(c)];
        float x = inputs[c][i];
        float low = state.low2.process(state.low1.process(x, mLowPass), mLowPass);
        float rest = state.rest2.process(state.rest1.process(x, mLowHighPass), mLowHighPass);
        float mid = state.mid2.process(state.mid1.process(rest, mHighLowPass), mHighLowPass);
        float high = state.high2.process(state.high1.process(rest, mHighPass), mHighPass);
        // The lows through the high crossover too (its low and high parts added: an all-pass),
        // so they stay in phase with the mids and highs.
        float lowLow = state.allLow2.process(state.allLow1.process(low, mHighLowPass), mHighLowPass);
        float lowHigh = state.allHigh2.process(state.allHigh1.process(low, mHighPass), mHighPass);
        bands[size_t(c)] = {lowLow + lowHigh, mid, high};
        for (int band = 0; band < bandCount; ++band) {
          peaks[size_t(band)] = std::max(peaks[size_t(band)], std::abs(bands[size_t(c)][size_t(band)]));
        }
      }
      // Each band's gain, the sides linked so the image doesn't shift.
      std::array<float, bandCount> gains;
      for (int band = 0; band < bandCount; ++band) {
        float level = decibels(peaks[size_t(band)]);
        float target = Compressor::curve(level, threshold[size_t(band)], ratio[size_t(band)], knee) - level;
        float &current = mGainDB[size_t(band)];
        float coefficient = target < current ? attack : release;
        current = target + (current - target) * coefficient;
        gains[size_t(band)] = linear(current) * makeUp[size_t(band)];
        deepest[size_t(band)] = std::min(deepest[size_t(band)], current);
      }
      for (int c = 0; c < channels; ++c) {
        float sum = 0;
        for (int band = 0; band < bandCount; ++band) sum += bands[size_t(c)][size_t(band)] * gains[size_t(band)];
        outputs[c][i] = sum * output;
      }
    }
    for (auto &channel : mChannels) channel.flushDenormals();
    mReductions = deepest;
    meters.measure(inputs, outputs, channels, frameCount);
  }

private:
  static constexpr int maximumChannels = 2;

  struct Channel {
    BiquadState low1, low2, rest1, rest2, mid1, mid2, high1, high2, allLow1, allLow2, allHigh1, allHigh2;

    void flushDenormals() {
      for (BiquadState *state : {&low1, &low2, &rest1, &rest2, &mid1, &mid2, &high1, &high2, &allLow1, &allLow2, &allHigh1, &allHigh2}) {
        state->flushDenormals();
      }
    }
  };

  /// The crossovers' filters: each a pair of Butterworth sections (Linkwitz–Riley).
  void updateCrossovers() {
    float low = std::clamp(mParameters[mbcLowCrossover], 40.0f, 2000.0f);
    // The high crossover stays an octave above the low one.
    float high = std::clamp(mParameters[mbcHighCrossover], low * 2, 16000.0f);
    if (low == mLowCrossover && high == mHighCrossover) return;
    mLowCrossover = low;
    mHighCrossover = high;
    double q = 1 / std::sqrt(2.0);
    mLowPass = BiquadCoefficients::lowPass(low, q, mSampleRate);
    mLowHighPass = BiquadCoefficients::highPass(low, q, mSampleRate);
    mHighLowPass = BiquadCoefficients::lowPass(high, q, mSampleRate);
    mHighPass = BiquadCoefficients::highPass(high, q, mSampleRate);
  }

  ParameterBank<mbcLowCrossover, mbcLastBand> mParameters;
  std::array<Channel, maximumChannels> mChannels;
  BiquadCoefficients mLowPass, mLowHighPass, mHighLowPass, mHighPass;
  float mLowCrossover = -1, mHighCrossover = -1;
  std::array<float, bandCount> mGainDB {};
  std::array<float, bandCount> mReductions {};
  double mSampleRate = 44100;
  int mChannelCount = 0;
};

}  // namespace ongaku
