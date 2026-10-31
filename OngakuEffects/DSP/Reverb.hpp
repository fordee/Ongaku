//
//  Reverb.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <span>
#include <vector>

#include "Biquad.hpp"
#include "DelayLine.hpp"
#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

/// An algorithmic reverb in the spirit of ChromaVerb: a predelay, a chain of diffusing
/// all-pass filters, then an eight-line feedback delay network with a Hadamard mix,
/// slowly modulated lines, and damping in the loop so highs die away first. Its stereo
/// outputs take different blends of the lines, and the dry signal mixes back in.
class Reverb {
public:
  static constexpr AUParameterAddress firstAddress = verbPredelay;
  static constexpr int parameterCount = verbMix - verbPredelay + 1;
  static constexpr int lineCount = 8;
  static constexpr int toneSections = 3;

  Reverb() { mTargets.fill(0); }

  void setParameter(AUParameterAddress address, float value) {
    if (address >= firstAddress && address < firstAddress + parameterCount) mTargets[address - firstAddress] = value;
  }

  float parameter(AUParameterAddress address) const {
    return address >= firstAddress && address < firstAddress + parameterCount ? mTargets[address - firstAddress] : 0;
  }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = float(sampleRate);
    mChannelCount = channelCount;
    mPredelay.allocate(int(0.25f * mSampleRate) + 1);
    for (int i = 0; i < diffuserCount; ++i) {
      mDiffusers[i].allocate(int(diffuserMilliseconds[i] * 0.001f * maxSize * mSampleRate) + 2);
    }
    for (int i = 0; i < lineCount; ++i) {
      mLines[i].allocate(int((lineMilliseconds[i] * maxSize + maxModulationMilliseconds) * 0.001f * mSampleRate) + 4);
    }
    mSize = sizeScale();
    reset();
  }

  void reset() {
    mPredelay.clear();
    for (auto &diffuser : mDiffusers) diffuser.clear();
    for (auto &line : mLines) line.clear();
    mDamping.fill(0);
    for (auto &channel : mTone) for (auto &state : channel) state.reset();
    for (int l = 0; l < lineCount; ++l) {
      float step = 2 * float(M_PI) * modulationRates[l] / mSampleRate;
      mRotations[l] = {std::cos(step), std::sin(step)};
      mOscillators[l] = {std::cos(float(l)), std::sin(float(l))};
    }
  }

  /// How long the tail lasts (to silence, roughly), in seconds.
  float tailSeconds() const { return value(verbPredelay) * 0.001f + std::max(0.1f, value(verbDecay)) * 1.5f; }

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    if (channels == 0) return;

    float predelay = std::clamp(value(verbPredelay) * 0.001f * mSampleRate, 1.0f, 0.25f * mSampleRate);
    float decay = std::max(0.1f, value(verbDecay));
    float diffusion = 0.45f + 0.3f * std::clamp(value(verbDiffusion) / 100, 0.0f, 1.0f);
    float damping = std::exp(-2 * float(M_PI) * std::clamp(value(verbHighCut), 500.0f, 0.45f * mSampleRate) / mSampleRate);
    // The wet signal's tone: a 24 dB/octave low cut and a 12 dB/octave high cut (on top of
    // the damping in the loop, which makes the highs die away sooner).
    std::array<BiquadCoefficients, toneSections> tone = toneFilters();
    float modulation = std::clamp(value(verbModulation) / 100, 0.0f, 1.0f) * maxModulationMilliseconds * 0.001f * mSampleRate;
    float width = std::clamp(value(verbWidth) / 100, 0.0f, 1.0f);
    float mix = std::clamp(value(verbMix) / 100, 0.0f, 1.0f);
    float sizeTarget = sizeScale();
    // A size change glides over about 100 ms, so it bends rather than clicks.
    float sizeGlide = 1 - std::exp(-1 / (0.1f * mSampleRate));
    std::array<float, lineCount> gains;

    for (int i = 0; i < frameCount; ++i) {
      mSize += (sizeTarget - mSize) * sizeGlide;
      if (i % 32 == 0) {
        // Each line's feedback gain follows from its length, so every line decays at the
        // same rate (−60 dB after the decay time).
        for (int l = 0; l < lineCount; ++l) {
          float length = lineMilliseconds[l] * 0.001f * mSize * mSampleRate + modulation * 0.5f;
          gains[l] = std::pow(10.0f, -3 * length / (decay * mSampleRate));
        }
      }

      float input = 0;
      for (int c = 0; c < channels; ++c) input += inputs[c][i];
      input /= float(channels);

      mPredelay.write(input);
      float diffused = mPredelay.read(predelay);
      // The diffusers smear the sound into early reflections; the last two stages give the
      // two sides slightly different ones.
      float earlyLeft = 0;
      for (int d = 0; d < diffuserCount; ++d) {
        float delayed = mDiffusers[d].read(std::max(1.0f, diffuserMilliseconds[d] * 0.001f * mSize * mSampleRate));
        float feedback = diffused + diffusion * delayed;
        mDiffusers[d].write(feedback);
        diffused = delayed - diffusion * feedback;
        if (d == diffuserCount - 2) earlyLeft = diffused;
      }
      float earlyRight = diffused;

      // Read the lines (each wobbling slowly at its own rate) and damp them.
      std::array<float, lineCount> taps;
      for (int l = 0; l < lineCount; ++l) {
        // Each line's sine wobble turns as a phasor, which needs no trigonometry per sample.
        float cosine = mOscillators[l][0], sine = mOscillators[l][1];
        mOscillators[l][0] = cosine * mRotations[l][0] - sine * mRotations[l][1];
        mOscillators[l][1] = cosine * mRotations[l][1] + sine * mRotations[l][0];
        float length = lineMilliseconds[l] * 0.001f * mSize * mSampleRate;
        float wobble = modulation * 0.5f * (1 + sine);
        float tap = mLines[l].read(length + wobble + 1);
        mDamping[l] = (1 - damping) * tap + damping * mDamping[l];
        taps[l] = mDamping[l] * gains[l];
      }

      // Stereo outputs from different blends of the lines.
      float left = 0, right = 0;
      for (int l = 0; l < lineCount; ++l) {
        left += taps[l] * leftSigns[l];
        right += taps[l] * rightSigns[l];
      }
      left = left * 0.35f + earlyLeft * earlyLevel;
      right = right * 0.35f + earlyRight * earlyLevel;

      // Mix the lines (an 8-point Hadamard transform, scaled to keep energy) and feed
      // them back with the new input.
      hadamard(taps);
      for (int l = 0; l < lineCount; ++l) {
        mLines[l].write(taps[l] + diffused * inputSigns[l]);
      }

      // Narrow the stereo image toward the middle, and cut the lows from the wet signal.
      float mid = (left + right) / 2, side = (left - right) / 2 * width;
      std::array<float, 2> wet = {mid + side, mid - side};
      for (int c = 0; c < 2; ++c) {
        for (int t = 0; t < toneSections; ++t) wet[c] = mTone[c][t].process(wet[c], tone[t]);
      }

      if (channels == 1) {
        outputs[0][i] = inputs[0][i] * (1 - mix) + (wet[0] + wet[1]) / 2 * mix;
      } else {
        for (int c = 0; c < channels; ++c) {
          outputs[c][i] = inputs[c][i] * (1 - mix) + wet[c % 2] * mix;
        }
      }
    }

    // Keep the phasors on the unit circle as rounding errors build up.
    for (auto &oscillator : mOscillators) {
      float length = std::sqrt(oscillator[0] * oscillator[0] + oscillator[1] * oscillator[1]);
      oscillator[0] /= length;
      oscillator[1] /= length;
    }
    for (auto &state : mDamping) if (std::abs(state) < 1e-20f) state = 0;
    for (auto &channel : mTone) for (auto &state : channel) state.flushDenormals();
  }

private:
  static constexpr int diffuserCount = 4;
  static constexpr float maxSize = 2.0f;
  static constexpr float earlyLevel = 0.25f;
  static constexpr float maxModulationMilliseconds = 1.2f;
  static constexpr float diffuserMilliseconds[diffuserCount] = {4.77f, 3.59f, 12.73f, 9.31f};
  static constexpr float lineMilliseconds[lineCount] = {29.7f, 37.1f, 41.1f, 43.7f, 53.0f, 59.9f, 67.7f, 73.1f};
  static constexpr float modulationRates[lineCount] = {0.31f, 0.47f, 0.53f, 0.67f, 0.73f, 0.89f, 0.97f, 1.13f};
  static constexpr float inputSigns[lineCount] = {1, -1, 1, -1, 1, 1, -1, -1};
  static constexpr float leftSigns[lineCount] = {1, 1, -1, 1, -1, 1, 1, -1};
  static constexpr float rightSigns[lineCount] = {1, -1, 1, 1, 1, -1, 1, -1};

  static void hadamard(std::array<float, lineCount> &values) {
    for (int span = 1; span < lineCount; span *= 2) {
      for (int start = 0; start < lineCount; start += span * 2) {
        for (int i = start; i < start + span; ++i) {
          float a = values[i], b = values[i + span];
          values[i] = a + b;
          values[i + span] = a - b;
        }
      }
    }
    for (auto &value : values) value *= 0.35355339f;  // 1 / √8
  }

  float value(AUParameterAddress address) const { return mTargets[address - firstAddress]; }

  std::array<BiquadCoefficients, toneSections> toneFilters() const {
    return toneFilters(value(verbLowCut), value(verbHighCut), mSampleRate);
  }

public:
  /// The filters that shape the wet signal's tone.
  static std::array<BiquadCoefficients, toneSections> toneFilters(float lowCut, float highCut, double sampleRate) {
    double low = std::clamp(double(lowCut), 10.0, 2000.0);
    double high = std::clamp(double(highCut), 500.0, 0.45 * sampleRate);
    return {
      BiquadCoefficients::highPass(low, 0.5412, sampleRate), BiquadCoefficients::highPass(low, 1.3066, sampleRate),
      BiquadCoefficients::lowPass(high, M_SQRT1_2, sampleRate)};
  }

  /// The wet signal's gain in dB at a frequency, for drawing its tone.
  static float toneDecibels(float lowCut, float highCut, double sampleRate, float frequency) {
    double decibels = 0;
    for (auto const &section : toneFilters(lowCut, highCut, sampleRate)) decibels += section.magnitudeDB(frequency, sampleRate);
    return float(decibels);
  }

private:

  /// Size 0–100 % scales the room from 0.4 to 2 times its base dimensions.
  float sizeScale() const { return 0.4f + 1.6f * std::clamp(value(verbSize) / 100, 0.0f, 1.0f); }

  std::array<float, parameterCount> mTargets;
  float mSampleRate = 44100;
  int mChannelCount = 0;
  float mSize = 1;
  std::array<std::array<float, 2>, lineCount> mOscillators {}, mRotations {};
  DelayLine mPredelay;
  std::array<DelayLine, diffuserCount> mDiffusers;
  std::array<DelayLine, lineCount> mLines;
  std::array<float, lineCount> mDamping {};
  std::array<std::array<BiquadState, toneSections>, 2> mTone;
};

}  // namespace ongaku
