//
//  ChannelEQ.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <span>
#include <vector>

#include "Biquad.hpp"
#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

/// Logic's Channel EQ: a low cut, a low shelf, four bells, a high shelf and a high cut,
/// then an output gain. Settings glide (every 32 samples) so sweeps don't zipper.
class ChannelEQ {
public:
  static constexpr int parameterCount = eqFirstBand + OngakuEQBandStride * OngakuEQBandCount;
  static constexpr int maxSections = 4;

  /// One band's settings.
  struct Band {
    bool on = false;
    double frequency = 1000;
    double gainDB = 0;
    double q = 0.71;
    int slope = 1;
  };

  static bool isCut(int band) { return band == OngakuEQBandLowCut || band == OngakuEQBandHighCut; }

  static Band band(float const *parameters, int band) {
    float const *fields = parameters + eqFirstBand + OngakuEQBandStride * band;
    return {
      fields[OngakuEQBandFieldOn] >= 0.5f, std::max(10.0f, fields[OngakuEQBandFieldFrequency]), fields[OngakuEQBandFieldGain],
      std::max(0.1f, fields[OngakuEQBandFieldQ]), int(std::lround(fields[OngakuEQBandFieldSlope]))};
  }

  /// The filter sections (in series) for a band; returns how many there are. A bell or
  /// shelf that's off, or at 0 dB, needs none.
  static int sections(int band, Band const &settings, double sampleRate, BiquadCoefficients *out) {
    double frequency = std::clamp(settings.frequency, 10.0, sampleRate * 0.49);
    if (!isCut(band)) {
      double gain = settings.on ? settings.gainDB : 0;
      if (std::abs(gain) < 1e-3) return 0;
      switch (band) {
        case OngakuEQBandLowShelf: out[0] = BiquadCoefficients::lowShelf(frequency, gain, settings.q, sampleRate); break;
        case OngakuEQBandHighShelf: out[0] = BiquadCoefficients::highShelf(frequency, gain, settings.q, sampleRate); break;
        default: out[0] = BiquadCoefficients::bell(frequency, gain, settings.q, sampleRate); break;
      }
      return 1;
    }
    if (!settings.on) return 0;

    // A Butterworth filter of the slope's order; the band's Q (relative to Butterworth's
    // 0.71) sharpens or softens its most resonant pole pair.
    bool highPass = band == OngakuEQBandLowCut;
    static constexpr int orders[] = {1, 2, 3, 4, 6, 8};
    int order = orders[std::clamp(settings.slope, 0, 5)];
    int count = 0;
    if (order % 2 == 1) {
      out[count++] = highPass ? BiquadCoefficients::firstOrderHighPass(frequency, sampleRate)
                              : BiquadCoefficients::firstOrderLowPass(frequency, sampleRate);
    }
    int pairs = order / 2;
    for (int k = 1; k <= pairs; ++k) {
      double angle = order % 2 == 1 ? k * M_PI / order : (2 * k - 1) * M_PI / (2 * order);
      double q = 1 / (2 * std::cos(angle));
      if (k == pairs) q *= settings.q / M_SQRT1_2;
      out[count++] = highPass ? BiquadCoefficients::highPass(frequency, q, sampleRate)
                              : BiquadCoefficients::lowPass(frequency, q, sampleRate);
    }
    return count;
  }

  /// The whole EQ's gain in decibels at each frequency, for drawing its curve.
  static void response(float const *parameters, double sampleRate, float const *frequencies, float *decibels, int count) {
    std::fill(decibels, decibels + count, parameters[eqOutputGain]);
    BiquadCoefficients coefficients[maxSections];
    for (int b = 0; b < OngakuEQBandCount; ++b) {
      int sectionCount = sections(b, band(parameters, b), sampleRate, coefficients);
      for (int s = 0; s < sectionCount; ++s) {
        for (int i = 0; i < count; ++i) {
          decibels[i] += float(coefficients[s].magnitudeDB(frequencies[i], sampleRate));
        }
      }
    }
  }

  ChannelEQ() { mTargets.fill(0); }

  void setParameter(AUParameterAddress address, float value) {
    if (address < parameterCount) mTargets[address] = value;
  }

  float parameter(AUParameterAddress address) const { return address < parameterCount ? mTargets[address] : 0; }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = channelCount;
    mStates.assign(size_t(channelCount) * OngakuEQBandCount * maxSections, {});
    mGlide = 1 - std::exp(-glideInterval / (0.015 * sampleRate));
    for (int b = 0; b < OngakuEQBandCount; ++b) {
      mCurrent[b] = target(b);
      mSectionCounts[b] = sections(b, mCurrent[b], mSampleRate, mCoefficients[b].data());
    }
    mGain = std::pow(10.0f, mTargets[eqOutputGain] / 20);
  }

  void reset() {
    for (auto &state : mStates) state.reset();
  }

  /// Filters the input into the output (which may be the same memory).
  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    for (int start = 0; start < frameCount; start += glideInterval) {
      int frames = std::min(glideInterval, frameCount - start);
      glide();
      float gainTarget = std::pow(10.0f, mTargets[eqOutputGain] / 20);
      float gainStart = mGain;
      float gainEnd = std::abs(gainTarget - mGain) < 1e-5f ? gainTarget : mGain + (gainTarget - mGain) * float(mGlide);
      mGain = gainEnd;

      for (int c = 0; c < channels; ++c) {
        float *out = outputs[c] + start;
        if (inputs[c] + start != out) std::copy_n(inputs[c] + start, frames, out);
        BiquadState *states = &mStates[size_t(c) * OngakuEQBandCount * maxSections];
        for (int b = 0; b < OngakuEQBandCount; ++b) {
          for (int s = 0; s < mSectionCounts[b]; ++s) {
            BiquadState &state = states[b * maxSections + s];
            BiquadCoefficients const &coefficients = mCoefficients[b][s];
            for (int i = 0; i < frames; ++i) out[i] = state.process(out[i], coefficients);
          }
        }
        float step = (gainEnd - gainStart) / float(frames);
        for (int i = 0; i < frames; ++i) out[i] *= gainStart + step * float(i + 1);
      }
    }
    for (auto &state : mStates) state.flushDenormals();
  }

private:
  static constexpr int glideInterval = 32;

  /// Where a band is heading: bells and shelves that are off glide to 0 dB rather than
  /// switching out with a click.
  Band target(int b) const {
    Band wanted = band(mTargets.data(), b);
    if (!isCut(b)) {
      if (!wanted.on) wanted.gainDB = 0;
      wanted.on = true;
    }
    return wanted;
  }

  /// Moves every band a step toward its settings, recomputing the filters that moved.
  void glide() {
    for (int b = 0; b < OngakuEQBandCount; ++b) {
      Band wanted = target(b);
      Band &current = mCurrent[b];
      bool moved = false;
      if (current.on != wanted.on || current.slope != wanted.slope) {
        current.on = wanted.on;
        current.slope = wanted.slope;
        moved = true;
      }
      // Frequency glides in octaves, so a sweep sounds even.
      double octaves = std::log2(wanted.frequency / current.frequency);
      if (octaves != 0) {
        current.frequency = std::abs(octaves) < 0.001 ? wanted.frequency : current.frequency * std::exp2(octaves * mGlide);
        moved = true;
      }
      moved |= approach(current.gainDB, wanted.gainDB, 0.001);
      moved |= approach(current.q, wanted.q, 0.0005);
      if (!moved) continue;

      int count = sections(b, current, mSampleRate, mCoefficients[b].data());
      if (count != mSectionCounts[b]) {
        for (int c = 0; c < mChannelCount; ++c) {
          for (int s = 0; s < maxSections; ++s) mStates[(size_t(c) * OngakuEQBandCount + b) * maxSections + s].reset();
        }
      }
      mSectionCounts[b] = count;
    }
  }

  bool approach(double &value, double wanted, double snap) {
    if (value == wanted) return false;
    value = std::abs(wanted - value) < snap ? wanted : value + (wanted - value) * mGlide;
    return true;
  }

  std::array<float, parameterCount> mTargets;
  std::array<Band, OngakuEQBandCount> mCurrent;
  std::array<std::array<BiquadCoefficients, maxSections>, OngakuEQBandCount> mCoefficients;
  std::array<int, OngakuEQBandCount> mSectionCounts {};
  std::vector<BiquadState> mStates;
  double mSampleRate = 44100;
  double mGlide = 0.05;
  int mChannelCount = 0;
  float mGain = 1;
};

}  // namespace ongaku
