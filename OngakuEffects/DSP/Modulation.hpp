//
//  Modulation.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <span>

#include "DelayLine.hpp"
#include "Dynamics.hpp"
#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

/// A slow wave for the modulation effects: a phase from 0 to 1 that turns at its rate.
struct LFO {
  double phase = 0;

  void advance(double hertz, double sampleRate) {
    phase += hertz / sampleRate;
    phase -= std::floor(phase);
  }

  /// A sine from −1 to 1 at the phase plus `offset` (of a cycle).
  float sine(double offset = 0) const { return float(std::sin(2 * M_PI * (phase + offset))); }
};

/// The parameters' values glide to new settings over about 20 ms, so a turned knob never
/// clicks.
inline float glide(float current, float target, double sampleRate) {
  return current + (target - current) * float(1 - std::exp(-1.0 / (0.02 * sampleRate)));
}

// MARK: - Chorus

/// A chorus like Logic's: each side two delayed copies whose delays sweep slowly (so their
/// pitch wavers), mixed with the original. Width sets the sides' waves apart for a wider sound.
class Chorus {
public:
  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::min(channelCount, maximumChannels);
    for (auto &line : mLines) {
      line.allocate(int(0.06 * sampleRate));
      line.clear();
    }
    mLFO = LFO();
    mDelay = std::clamp(mParameters[chrDelay], 5.0f, 30.0f);
  }

  PeakMeters meters;
  double phase() const { return mLFO.phase; }

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    if (channels == 0) return;
    float rate = std::clamp(mParameters[chrRate], 0.05f, 5.0f);
    float depth = std::clamp(mParameters[chrDepth] / 100, 0.0f, 1.0f);
    float width = std::clamp(mParameters[chrWidth] / 100, 0.0f, 1.0f);
    float mix = std::clamp(mParameters[chrMix] / 100, 0.0f, 1.0f);
    float samplesPerMillisecond = float(mSampleRate / 1000);
    float dryGain = std::cos(mix * float(M_PI) / 2);
    float wetGain = std::sin(mix * float(M_PI) / 2) / std::sqrt(2.0f);
    for (int i = 0; i < frameCount; ++i) {
      mDelay = glide(mDelay, std::clamp(mParameters[chrDelay], 5.0f, 30.0f), mSampleRate);
      // The sweep, either way of the delay: up to 4 ms at full depth.
      float sweep = std::min(4.0f, mDelay * 0.8f) * depth;
      for (int c = 0; c < channels; ++c) {
        mLines[size_t(c)].write(inputs[c][i]);
        // The right side's waves a quarter cycle on at full width.
        double offset = c == 1 ? 0.25 * width : 0;
        float wet = 0;
        for (int voice = 0; voice < 2; ++voice) {
          float delay = mDelay + sweep * mLFO.sine(offset + voice * 0.5) * (voice == 0 ? 1.0f : 0.8f);
          wet += mLines[size_t(c)].read(std::max(1.0f, delay * samplesPerMillisecond));
        }
        // An equal-power blend: the two copies wander apart, so together they're about
        // √2 as loud as one, and the mix keeps the level where it was.
        outputs[c][i] = inputs[c][i] * dryGain + wet * wetGain;
      }
      mLFO.advance(rate, mSampleRate);
    }
    meters.measure(inputs, outputs, channels, frameCount);
  }

private:
  static constexpr int maximumChannels = 2;
  ParameterBank<chrRate, chrMix> mParameters;
  std::array<DelayLine, maximumChannels> mLines;
  LFO mLFO;
  double mSampleRate = 44100;
  int mChannelCount = 0;
  float mDelay = 14;
};

// MARK: - Flanger

/// A flanger: a delay of a few milliseconds swept up and down and fed back into itself,
/// which sweeps a comb of notches through the sound (the jet-plane whoosh).
class Flanger {
public:
  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::min(channelCount, maximumChannels);
    for (auto &line : mLines) {
      line.allocate(int(0.03 * sampleRate));
      line.clear();
    }
    mLFO = LFO();
    mDelay = std::clamp(mParameters[flgDelay], 0.3f, 10.0f);
  }

  PeakMeters meters;
  double phase() const { return mLFO.phase; }

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    if (channels == 0) return;
    float rate = std::clamp(mParameters[flgRate], 0.02f, 5.0f);
    float depth = std::clamp(mParameters[flgDepth] / 100, 0.0f, 1.0f);
    float feedback = std::clamp(mParameters[flgFeedback] / 100, -0.95f, 0.95f);
    float width = std::clamp(mParameters[flgWidth] / 100, 0.0f, 1.0f);
    float mix = std::clamp(mParameters[flgMix] / 100, 0.0f, 1.0f);
    float samplesPerMillisecond = float(mSampleRate / 1000);
    for (int i = 0; i < frameCount; ++i) {
      mDelay = glide(mDelay, std::clamp(mParameters[flgDelay], 0.3f, 10.0f), mSampleRate);
      for (int c = 0; c < channels; ++c) {
        double offset = c == 1 ? 0.5 * width : 0;
        // From the delay up to five times it (and 8 ms more at most) at full depth.
        float swing = std::min(mDelay * 4, 8.0f) * depth;
        float delay = mDelay + swing * (mLFO.sine(offset) + 1) / 2;
        float wet = mLines[size_t(c)].read(std::max(1.0f, delay * samplesPerMillisecond));
        // Fed back softly limited, so a high setting rings without running away.
        mLines[size_t(c)].write(inputs[c][i] + std::tanh(wet * feedback));
        outputs[c][i] = inputs[c][i] * (1 - mix * 0.5f) + wet * mix * 0.5f;
      }
      mLFO.advance(rate, mSampleRate);
    }
    meters.measure(inputs, outputs, channels, frameCount);
  }

private:
  static constexpr int maximumChannels = 2;
  ParameterBank<flgRate, flgMix> mParameters;
  std::array<DelayLine, maximumChannels> mLines;
  LFO mLFO;
  double mSampleRate = 44100;
  int mChannelCount = 0;
  float mDelay = 2;
};

// MARK: - Phaser

/// A phaser: the sound through a chain of all-pass filters whose frequency sweeps, mixed
/// with the original so notches move up and down. More stages, more notches.
class Phaser {
public:
  static constexpr int stageChoices[] = {2, 4, 6, 8, 12};
  static constexpr int maximumStages = 12;

  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::min(channelCount, maximumChannels);
    for (auto &channel : mChannels) channel = Channel();
    mLFO = LFO();
  }

  PeakMeters meters;
  double phase() const { return mLFO.phase; }

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    if (channels == 0) return;
    float rate = std::clamp(mParameters[phsRate], 0.02f, 8.0f);
    float depth = std::clamp(mParameters[phsDepth] / 100, 0.0f, 1.0f);
    int stages = stageChoices[std::clamp(int(std::lround(mParameters[phsStages])), 0, 4)];
    float center = std::clamp(mParameters[phsCenter], 100.0f, 6000.0f);
    float feedback = std::clamp(mParameters[phsFeedback] / 100, -0.95f, 0.95f);
    float width = std::clamp(mParameters[phsWidth] / 100, 0.0f, 1.0f);
    float mix = std::clamp(mParameters[phsMix] / 100, 0.0f, 1.0f);
    float nyquistSafe = float(mSampleRate) * 0.45f;
    for (int i = 0; i < frameCount; ++i) {
      for (int c = 0; c < channels; ++c) {
        Channel &state = mChannels[size_t(c)];
        double offset = c == 1 ? 0.5 * width : 0;
        // Two octaves either way of the centre at full depth.
        float frequency = std::min(nyquistSafe, center * std::exp2(2 * depth * mLFO.sine(offset)));
        float t = std::tan(float(M_PI) * frequency / float(mSampleRate));
        float a = (t - 1) / (t + 1);
        float x = inputs[c][i] + std::tanh(state.last * feedback);
        for (int stage = 0; stage < stages; ++stage) {
          // A first-order all-pass: y = a·x + x[n−1] − a·y[n−1].
          float y = a * x + state.x1[size_t(stage)] - a * state.y1[size_t(stage)];
          state.x1[size_t(stage)] = x;
          state.y1[size_t(stage)] = y;
          x = y;
        }
        state.last = x;
        outputs[c][i] = inputs[c][i] * (1 - mix * 0.5f) + x * mix * 0.5f;
      }
      mLFO.advance(rate, mSampleRate);
    }
    meters.measure(inputs, outputs, channels, frameCount);
  }

private:
  static constexpr int maximumChannels = 2;
  struct Channel {
    std::array<float, maximumStages> x1 {}, y1 {};
    float last = 0;
  };
  ParameterBank<phsRate, phsMix> mParameters;
  std::array<Channel, maximumChannels> mChannels;
  LFO mLFO;
  double mSampleRate = 44100;
  int mChannelCount = 0;
};

// MARK: - Tremolo

/// A tremolo: the level rising and falling in a sine, triangle or square, at a rate in
/// hertz or in notes at the song's tempo. With the sides 180° apart it's an auto-pan.
class Tremolo {
public:
  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::min(channelCount, maximumChannels);
    mLFO = LFO();
    mGains = {1, 1};
  }

  /// Each note value in quarter notes, as the Delay's.
  static double noteBeats(int note) {
    static constexpr double beats[] = {0.125, 1.0 / 6, 0.25, 0.375, 1.0 / 3, 0.5, 0.75, 2.0 / 3, 1, 1.5, 2};
    return beats[std::clamp(note, 0, 10)];
  }

  /// The rate in hertz: the knob's, or a cycle per note at `tempo`.
  float rate(double tempo) const {
    if (mParameters[trmSync] >= 0.5f) return float(tempo / 60 / noteBeats(int(std::lround(mParameters[trmNote]))));
    return std::clamp(mParameters[trmRate], 0.1f, 20.0f);
  }

  PeakMeters meters;
  double phase() const { return mLFO.phase; }
  float gain(int channel) const { return mGains[size_t(std::clamp(channel, 0, 1))]; }

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount, double tempo) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    if (channels == 0) return;
    float hertz = rate(tempo);
    float depth = std::clamp(mParameters[trmDepth] / 100, 0.0f, 1.0f);
    int shape = std::clamp(int(std::lround(mParameters[trmShape])), 0, 2);
    double stereo = std::clamp(mParameters[trmStereo], 0.0f, 180.0f) / 360.0;
    for (int i = 0; i < frameCount; ++i) {
      for (int c = 0; c < channels; ++c) {
        double phase = mLFO.phase + (c == 1 ? stereo : 0);
        phase -= std::floor(phase);
        float wave = shaped(phase, shape);  // 0–1
        float target = 1 - depth * (1 - wave);
        // A square's edges are softened over a couple of milliseconds, so they don't click.
        mGains[size_t(c)] += (target - mGains[size_t(c)]) * (shape == 2 ? 0.02f : 1.0f);
        outputs[c][i] = inputs[c][i] * mGains[size_t(c)];
      }
      mLFO.advance(hertz, mSampleRate);
    }
    meters.measure(inputs, outputs, channels, frameCount);
  }

  /// The wave at a phase, from 0 (quietest) to 1 (loudest).
  static float shaped(double phase, int shape) {
    switch (shape) {
      case 1: return float(phase < 0.5 ? phase * 2 : 2 - phase * 2);
      case 2: return phase < 0.5 ? 1.0f : 0.0f;
      default: return float(0.5 + 0.5 * std::cos(2 * M_PI * phase));
    }
  }

private:
  static constexpr int maximumChannels = 2;
  ParameterBank<trmSync, trmStereo> mParameters;
  LFO mLFO;
  std::array<float, maximumChannels> mGains {1, 1};
  double mSampleRate = 44100;
  int mChannelCount = 0;
};

}  // namespace ongaku
