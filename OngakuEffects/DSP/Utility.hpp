//
//  Utility.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <span>

#include "Dynamics.hpp"
#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

// MARK: - Gain

/// Logic's Gain: level, polarity, swapping and summing the sides, stereo width and balance.
class Gain {
public:
  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = channelCount;
    mGain = linear(std::clamp(mParameters[ginGain], -48.0f, 24.0f));
  }

  PeakMeters meters;

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(std::max(mChannelCount, 1))}));
    if (channels == 0) return;
    float target = linear(std::clamp(mParameters[ginGain], -48.0f, 24.0f));
    float smoothing = float(1 - std::exp(-1.0 / (0.02 * mSampleRate)));
    float invertLeft = mParameters[ginInvertLeft] >= 0.5f ? -1 : 1;
    float invertRight = mParameters[ginInvertRight] >= 0.5f ? -1 : 1;
    bool swap = mParameters[ginSwap] >= 0.5f, mono = mParameters[ginMono] >= 0.5f;
    float width = std::clamp(mParameters[ginWidth] / 100, 0.0f, 2.0f);
    float balance = std::clamp(mParameters[ginBalance] / 100, -1.0f, 1.0f);
    // Balance turns the other side down (constant at the centre).
    float leftBalance = balance > 0 ? 1 - balance : 1, rightBalance = balance < 0 ? 1 + balance : 1;
    for (int i = 0; i < frameCount; ++i) {
      mGain += (target - mGain) * smoothing;
      if (channels == 1) {
        outputs[0][i] = inputs[0][i] * mGain * invertLeft;
        continue;
      }
      float left = inputs[0][i] * invertLeft, right = inputs[1][i] * invertRight;
      if (swap) std::swap(left, right);
      float mid = (left + right) / 2, side = (left - right) / 2 * (mono ? 0 : width);
      outputs[0][i] = (mid + side) * mGain * leftBalance;
      outputs[1][i] = (mid - side) * mGain * rightBalance;
      for (int c = 2; c < channels; ++c) outputs[c][i] = inputs[c][i] * mGain;
    }
    meters.measure(inputs, outputs, channels, frameCount);
  }

private:
  ParameterBank<ginGain, ginBalance> mParameters;
  double mSampleRate = 44100;
  int mChannelCount = 0;
  float mGain = 1;
};

// MARK: - Tuner

/// A tuner: passes the sound through (or silences it) and finds its pitch with the YIN
/// method, on the sound mixed to mono and taken down to about 24 kHz, a few dozen times a
/// second. Notes from about 40 Hz (an E string an octave down) to 1.5 kHz.
class Tuner {
public:
  static constexpr int window = 1024;
  static constexpr int maximumLag = 640;

  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const {
    if (address == tunFrequency) return frequency();
    return mParameters.get(address);
  }

  void initialize(int channelCount, double sampleRate) {
    mChannelCount = channelCount;
    mDecimation = std::max(1, int(std::lround(sampleRate / 24000)));
    mAnalysisRate = sampleRate / mDecimation;
    mRing.fill(0);
    mWritten = 0;
    mSinceAnalysis = 0;
    mAccumulator = 0;
    mAccumulated = 0;
    publish(0, 0);
  }

  /// Read from other threads (the window, a host asking for the parameter).
  float frequency() const {
    float value;
    __atomic_load(&mFrequency, &value, __ATOMIC_RELAXED);
    return value;
  }
  float clarity() const {
    float value;
    __atomic_load(&mClarity, &value, __ATOMIC_RELAXED);
    return value;
  }

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min(inputs.size(), outputs.size()));
    if (channels == 0) return;
    bool mute = mParameters[tunMute] >= 0.5f;
    for (int i = 0; i < frameCount; ++i) {
      float mono = 0;
      for (int c = 0; c < channels; ++c) mono += inputs[c][i];
      mAccumulator += mono / float(channels);
      if (++mAccumulated == mDecimation) {
        push(mAccumulator / float(mDecimation));
        mAccumulator = 0;
        mAccumulated = 0;
      }
    }
    for (int c = 0; c < channels; ++c) {
      if (mute) {
        std::fill_n(outputs[c], frameCount, 0.0f);
      } else if (inputs[c] != outputs[c]) {
        std::copy_n(inputs[c], frameCount, outputs[c]);
      }
    }
  }

private:
  static constexpr int ringSize = 2048;

  void push(float sample) {
    mRing[size_t(mWritten % ringSize)] = sample;
    ++mWritten;
    // Half a window between looks: about 47 a second at 24 kHz.
    if (++mSinceAnalysis >= window / 2 && mWritten >= window + maximumLag) {
      mSinceAnalysis = 0;
      analyse();
    }
  }

  /// YIN: the lag at which the sound best matches itself, from the cumulative mean
  /// normalised difference, refined between samples.
  void analyse() {
    std::array<float, window + maximumLag> frame;
    int64_t start = mWritten - int64_t(frame.size());
    float energy = 0;
    for (size_t i = 0; i < frame.size(); ++i) {
      frame[i] = mRing[size_t((start + int64_t(i)) % ringSize)];
      energy += frame[i] * frame[i];
    }
    // Too quiet (about −60 dBFS) to call a note.
    if (energy / float(frame.size()) < 1e-6f) {
      publish(0, 0);
      return;
    }
    int minimumLag = std::max(2, int(mAnalysisRate / 1500));
    int lags = std::min(maximumLag, int(mAnalysisRate / 38));
    std::array<float, maximumLag + 1> difference {};
    float running = 0;
    difference[0] = 1;
    for (int lag = 1; lag <= lags; ++lag) {
      float sum = 0;
      for (int i = 0; i < window; ++i) {
        float delta = frame[size_t(i)] - frame[size_t(i + lag)];
        sum += delta * delta;
      }
      running += sum;
      difference[size_t(lag)] = running > 0 ? sum * float(lag) / running : 1;
    }
    int best = -1;
    for (int lag = minimumLag; lag < lags; ++lag) {
      if (difference[size_t(lag)] < 0.15f) {
        while (lag + 1 < lags && difference[size_t(lag + 1)] < difference[size_t(lag)]) ++lag;
        best = lag;
        break;
      }
    }
    if (best < 0) {
      publish(0, 0);
      return;
    }
    // A parabola through the lag and its neighbours.
    float a = difference[size_t(best - 1)], b = difference[size_t(best)], c = difference[size_t(best + 1)];
    float denominator = a - 2 * b + c;
    float refined = float(best) + (std::abs(denominator) > 1e-9f ? 0.5f * (a - c) / denominator : 0);
    publish(float(mAnalysisRate) / refined, std::clamp(1 - b, 0.0f, 1.0f));
  }

  void publish(float frequency, float clarity) {
    __atomic_store(&mFrequency, &frequency, __ATOMIC_RELAXED);
    __atomic_store(&mClarity, &clarity, __ATOMIC_RELAXED);
  }

  ParameterBank<tunReference, tunMute> mParameters;
  int mChannelCount = 0;
  int mDecimation = 2;
  double mAnalysisRate = 24000;
  std::array<float, ringSize> mRing {};
  int64_t mWritten = 0;
  int mSinceAnalysis = 0;
  float mAccumulator = 0;
  int mAccumulated = 0;
  float mFrequency = 0, mClarity = 0;
};

}  // namespace ongaku
