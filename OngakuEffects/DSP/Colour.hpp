//
//  Colour.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <span>

#include "Biquad.hpp"
#include "DelayLine.hpp"
#include "Dynamics.hpp"
#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

// MARK: - Saturation

/// Saturation in three flavours, like the Tape, Tube and Transistor of Logic's
/// ChromaGlow: the signal is driven into a curve at four times the sample rate (so the
/// harmonics it adds don't fold back down as aliasing), then the level is matched to the
/// dry sound, the tone tilted, and the two mixed.
class Saturation {
public:
  static constexpr int oversampling = 4;

  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  /// The curve, for drawing it: the output for an input (−1…1) with a drive (linear) and
  /// a type, level-matched as it's heard.
  static float curve(float input, float drive, int type) {
    float reference = 0.25f;
    float matched = reference / std::max(1e-6f, std::abs(shape(reference * drive, type)));
    return shape(input * drive, type) * matched;
  }

  /// The three curves: tape (soft, a little asymmetric for even harmonics), tube (more
  /// asymmetric, rounder), transistor (harder, clipping sooner).
  static float shape(float x, int type) {
    switch (type) {
      case 0: {  // tape
        float bias = 0.12f;
        return (std::tanh(x + bias) - std::tanh(bias)) / (1 - std::tanh(bias) * std::tanh(bias) + 1e-6f) * 0.8f;
      }
      case 1:  // tube
        return x >= 0 ? 1 - std::exp(-x) : -(1 - std::exp(x * 1.25f)) / 1.25f;
      default:  // transistor
        return x / std::pow(1 + std::pow(std::abs(x), 4.0f), 0.25f);
    }
  }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::min(channelCount, maximumChannels);
    mAntiAlias = BiquadCoefficients::lowPass(sampleRate * 0.45, 0.54, sampleRate * oversampling);
    mAntiAlias2 = BiquadCoefficients::lowPass(sampleRate * 0.45, 1.31, sampleRate * oversampling);
    for (auto &channel : mChannels) channel = Channel();
  }

  PeakMeters meters;

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    float drive = linear(std::clamp(mParameters[satDrive], 0.0f, 36.0f));
    int type = std::clamp(int(std::lround(mParameters[satType])), 0, 2);
    float output = linear(mParameters[satOutput]);
    float mix = std::clamp(mParameters[satMix] / 100, 0.0f, 1.0f);
    float tone = std::clamp(mParameters[satTone] / 100, -1.0f, 1.0f);
    BiquadCoefficients tilt = BiquadCoefficients::highShelf(2500, tone * 6, 0.6, mSampleRate);
    // Tape's low "head bump" and its gentle high roll-off.
    BiquadCoefficients bump = BiquadCoefficients::bell(90, type == 0 ? 1.5 : 0, 0.8, mSampleRate);
    BiquadCoefficients rollOff = BiquadCoefficients::lowPass(type == 0 ? 16000 : mSampleRate * 0.49, 0.6, mSampleRate);
    float reference = 0.25f;
    float matched = reference / std::max(1e-6f, std::abs(shape(reference * drive, type)));

    for (int c = 0; c < channels; ++c) {
      Channel &state = mChannels[c];
      for (int i = 0; i < frameCount; ++i) {
        float dry = inputs[c][i];
        // Up to four times the rate by cubic interpolation, through the curve, filtered,
        // and back down.
        state.history[0] = state.history[1]; state.history[1] = state.history[2];
        state.history[2] = state.history[3]; state.history[3] = dry;
        float wet = 0;
        for (int k = 0; k < oversampling; ++k) {
          float t = float(k) / float(oversampling);
          float x = between(state.history.data(), t);
          float shaped = shape(x * drive, type) * matched;
          wet = state.filter2.process(state.filter.process(shaped, mAntiAlias), mAntiAlias2);
        }
        wet = state.rollOff.process(state.bump.process(state.tilt.process(wet, tilt), bump), rollOff);
        // The interpolation runs one sample behind; the dry path waits for it.
        float delayedDry = state.history[1];
        outputs[c][i] = (wet * mix + delayedDry * (1 - mix)) * output;
      }
      state.flushDenormals();
    }
    meters.measure(inputs, outputs, channels, frameCount);
  }

private:
  struct Channel {
    std::array<float, 4> history {};
    BiquadState filter, filter2, tilt, bump, rollOff;
    void flushDenormals() {
      for (BiquadState *state : {&filter, &filter2, &tilt, &bump, &rollOff}) state->flushDenormals();
    }
  };

  static float between(float const *y, float t) {
    float c1 = 0.5f * (y[2] - y[0]);
    float c2 = y[0] - 2.5f * y[1] + 2 * y[2] - 0.5f * y[3];
    float c3 = 0.5f * (y[3] - y[0]) + 1.5f * (y[1] - y[2]);
    return ((c3 * t + c2) * t + c1) * t + y[1];
  }

  ParameterBank<satDrive, satMix> mParameters;
  double mSampleRate = 44100;
  int mChannelCount = 0;
  BiquadCoefficients mAntiAlias, mAntiAlias2;
  std::array<Channel, maximumChannels> mChannels;
};

// MARK: - Doubler

/// Makes one part sound like two players, like the ADT of Abbey Road (and Logic's
/// Doubler): two copies, slightly late and slightly out of tune (one sharp, one flat),
/// drifting a little as a real second take would, spread left and right of the original.
class Doubler {
public:
  static constexpr float maximumDelay = 0.1f;  // seconds

  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::min(channelCount, maximumChannels);
    mLine.allocate(int(maximumDelay * sampleRate) + 8);
    mLine.clear();
    for (auto &voice : mVoices) voice = Voice();
    mVoices[1].shiftPhase = 0.5f;
    mVoices[1].driftState = 0x8E3779B9;
  }

  PeakMeters meters;

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    if (channels == 0) return;
    float rate = float(mSampleRate);
    float delay = std::clamp(mParameters[dblDelay], 5.0f, 60.0f) * 0.001f * rate;
    float cents = std::clamp(mParameters[dblDetune], 0.0f, 50.0f);
    float drift = std::clamp(mParameters[dblDrift] / 100, 0.0f, 1.0f);
    float width = std::clamp(mParameters[dblWidth] / 100, 0.0f, 1.0f);
    float mix = std::clamp(mParameters[dblMix] / 100, 0.0f, 1.0f);
    // A sweep through a 30 ms window shifts the pitch by its speed (the Doppler effect).
    float window = 0.03f * rate;

    for (int i = 0; i < frameCount; ++i) {
      float mono = 0;
      for (int c = 0; c < channels; ++c) mono += inputs[c][i];
      mono /= float(channels);
      mLine.write(mono);

      std::array<float, 2> copies {};
      for (int v = 0; v < 2; ++v) {
        Voice &voice = mVoices[size_t(v)];
        // The drift: a slowly wandering offset (smoothed random steps).
        if (--voice.driftCountdown <= 0) {
          voice.driftCountdown = int(rate * 0.35f);
          voice.driftTarget = random(voice.driftState);
        }
        voice.drift += (voice.driftTarget - voice.drift) * (1.0f / (rate * 0.2f));
        float base = delay * (v == 0 ? 1.0f : 1.37f) + voice.drift * drift * 0.004f * rate;
        // The pitch shift: two taps sweeping across the window half a cycle apart, faded
        // so neither is heard as it jumps back.
        float ratio = std::exp2((v == 0 ? cents : -cents) * (1 + voice.drift * drift * 0.3f) / 1200);
        voice.shiftPhase += (ratio - 1) * -1 / window;
        voice.shiftPhase -= std::floor(voice.shiftPhase);
        float sum = 0;
        for (float offset : {0.0f, 0.5f}) {
          float phase = voice.shiftPhase + offset;
          phase -= std::floor(phase);
          float fade = std::sin(float(M_PI) * phase);
          sum += mLine.read(base + phase * window) * fade * fade;
        }
        copies[size_t(v)] = sum;
      }
      // The copies either side of the original, the original as it was.
      float left = copies[0] * (1 + width) / 2 + copies[1] * (1 - width) / 2;
      float right = copies[1] * (1 + width) / 2 + copies[0] * (1 - width) / 2;
      float scale = 1 / (1 + mix * 0.6f);
      for (int c = 0; c < channels; ++c) {
        float copy = channels == 1 ? (left + right) / 2 : (c % 2 == 0 ? left : right);
        outputs[c][i] = (inputs[c][i] + copy * mix * 0.8f) * scale;
      }
    }
    meters.measure(inputs, outputs, channels, frameCount);
  }

private:
  struct Voice {
    float shiftPhase = 0;
    float drift = 0, driftTarget = 0;
    int driftCountdown = 0;
    uint32_t driftState = 0x2545F491;
  };

  static float random(uint32_t &state) {
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return float(state) / float(UINT32_MAX) * 2 - 1;
  }

  ParameterBank<dblDelay, dblMix> mParameters;
  double mSampleRate = 44100;
  int mChannelCount = 0;
  DelayLine mLine;
  std::array<Voice, 2> mVoices;
};

}  // namespace ongaku
