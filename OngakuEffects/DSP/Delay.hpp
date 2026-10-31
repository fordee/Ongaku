//
//  Delay.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <span>

#include "Biquad.hpp"
#include "DelayLine.hpp"
#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

/// A tape-style stereo delay: echoes timed in milliseconds or in notes at the song's tempo,
/// each repeat filtered and gently saturated like tape, with wow and flutter wobbling the
/// time. Changing the time glides (the echoes bend in pitch, as on tape) rather than
/// clicking. In ping-pong mode the echoes bounce between the sides.
class Delay {
public:
  static constexpr AUParameterAddress firstAddress = dlySync;
  static constexpr int parameterCount = dlyMix - dlySync + 1;

  /// Note values for synced times, in quarter notes: 1/32, 1/16T, 1/16, 1/16., 1/8T, 1/8,
  /// 1/8., 1/4T, 1/4, 1/4., 1/2.
  static constexpr int noteCount = 11;
  static constexpr double noteBeats[noteCount] = {
    0.125, 1.0 / 6, 0.25, 0.375, 1.0 / 3, 0.5, 0.75, 2.0 / 3, 1, 1.5, 2};

  Delay() { mTargets.fill(0); }

  void setParameter(AUParameterAddress address, float value) {
    if (address >= firstAddress && address < firstAddress + parameterCount) mTargets[address - firstAddress] = value;
  }

  float parameter(AUParameterAddress address) const {
    return address >= firstAddress && address < firstAddress + parameterCount ? mTargets[address - firstAddress] : 0;
  }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = float(sampleRate);
    mChannelCount = channelCount;
    for (auto &line : mLines) line.allocate(int(maxSeconds * mSampleRate) + int(0.01f * mSampleRate));
    mDelay = targetDelay(120);
    reset();
  }

  void reset() {
    for (auto &line : mLines) line.clear();
    for (auto &channel : mFilters) for (auto &state : channel) state.reset();
    mWow = 0;
    mFlutter = 0;
  }

  /// The delay time in seconds, at `tempo` if it's synced.
  float delaySeconds(double tempo) const {
    if (value(dlySync) >= 0.5f) {
      int note = std::clamp(int(std::lround(value(dlyNote))), 0, noteCount - 1);
      return float(noteBeats[note] * 60 / std::max(20.0, tempo));
    }
    return std::max(1.0f, value(dlyTime)) / 1000;
  }

  /// How long the echoes keep sounding after the input stops, in seconds.
  float tailSeconds(double tempo) const {
    float feedback = std::clamp(value(dlyFeedback) / 100, 0.0f, 0.99f);
    // Echoes until they're 60 dB down.
    float repeats = feedback > 0.001f ? std::min(200.0f, -3 / std::log10(feedback)) : 1;
    return delaySeconds(tempo) * (repeats + 1);
  }

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount, double tempo) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    if (channels == 0) return;

    float target = targetDelay(tempo);
    // Time changes glide over about 150 ms, like a tape machine changing speed.
    float glide = 1 - std::exp(-1 / (0.15f * mSampleRate));
    float feedback = std::clamp(value(dlyFeedback) / 100, 0.0f, 1.0f);
    bool pingPong = value(dlyPingPong) >= 0.5f;
    float flutter = std::clamp(value(dlyFlutter) / 100, 0.0f, 1.0f);
    // Wow: a slow drift of up to 3 ms; flutter: a fast shimmer of up to 0.25 ms.
    float wowDepth = flutter * 0.003f * mSampleRate;
    float flutterDepth = flutter * 0.00025f * mSampleRate;
    float wowStep = 2 * float(M_PI) * 0.7f / mSampleRate;
    float flutterStep = 2 * float(M_PI) * 6.3f / mSampleRate;
    // Drive pushes the echoes into soft saturation; at zero they stay clean.
    float drive = 5 * std::clamp(value(dlyDrive) / 100, 0.0f, 1.0f);
    float mix = std::clamp(value(dlyMix) / 100, 0.0f, 1.0f);
    std::array<BiquadCoefficients, 2> tone = {
      BiquadCoefficients::highPass(std::clamp(double(value(dlyLowCut)), 10.0, 2000.0), M_SQRT1_2, mSampleRate),
      BiquadCoefficients::lowPass(std::clamp(double(value(dlyHighCut)), 200.0, 0.45 * mSampleRate), M_SQRT1_2, mSampleRate)};
    float maxDelay = maxSeconds * mSampleRate;

    for (int i = 0; i < frameCount; ++i) {
      mDelay += (target - mDelay) * glide;
      mWow += wowStep;
      mFlutter += flutterStep;
      if (mWow > 2 * float(M_PI)) mWow -= 2 * float(M_PI);
      if (mFlutter > 2 * float(M_PI)) mFlutter -= 2 * float(M_PI);
      float wobble = wowDepth * (1 + std::sin(mWow)) / 2 + flutterDepth * (1 + std::sin(mFlutter)) / 2;

      // Read each side's echo (the right side wobbles a little differently), then shape it
      // like tape: filtered, and saturated as it gets loud.
      std::array<float, 2> echoes;
      for (int c = 0; c < 2; ++c) {
        float delay = std::clamp(mDelay + wobble * (c == 0 ? 1.0f : 0.85f), 1.0f, maxDelay);
        float echo = mLines[c].read(delay);
        for (int t = 0; t < 2; ++t) echo = mFilters[c][t].process(echo, tone[t]);
        echoes[c] = drive > 0.01f ? std::tanh(drive * echo) / drive : echo;
      }

      float left = inputs[0][i];
      float right = channels > 1 ? inputs[1][i] : left;
      if (pingPong) {
        // Everything starts on the left, then each echo crosses to the other side.
        mLines[0].write((left + right) / 2 + echoes[1] * feedback);
        mLines[1].write(echoes[0] * feedback);
      } else {
        mLines[0].write(left + echoes[0] * feedback);
        mLines[1].write(right + echoes[1] * feedback);
      }

      if (channels == 1) {
        outputs[0][i] = left * (1 - mix) + (echoes[0] + echoes[1]) / 2 * mix;
      } else {
        for (int c = 0; c < channels; ++c) {
          outputs[c][i] = inputs[c][i] * (1 - mix) + echoes[c % 2] * mix;
        }
      }
    }
    for (auto &channel : mFilters) for (auto &state : channel) state.flushDenormals();
  }

private:
  /// The longest delay: two seconds, or half a note at 30 BPM.
  static constexpr float maxSeconds = 4.1f;

  float value(AUParameterAddress address) const { return mTargets[address - firstAddress]; }

  float targetDelay(double tempo) const { return delaySeconds(tempo) * mSampleRate; }

  std::array<float, parameterCount> mTargets;
  float mSampleRate = 44100;
  int mChannelCount = 0;
  float mDelay = 1;
  float mWow = 0, mFlutter = 0;
  std::array<DelayLine, 2> mLines;
  std::array<std::array<BiquadState, 2>, 2> mFilters;
};

}  // namespace ongaku
