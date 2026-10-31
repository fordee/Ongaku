//
//  Dynamics.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <span>
#include <vector>

#include "Biquad.hpp"
#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

/// The most channels the effects keep separate state for (more are left untouched).
constexpr int maximumChannels = 8;

/// Settings by address, for an effect whose parameters are `first … last`.
template <AUParameterAddress first, AUParameterAddress last>
struct ParameterBank {
  std::array<float, last - first + 1> values {};

  void set(AUParameterAddress address, float value) {
    if (address >= first && address <= last) values[address - first] = value;
  }
  float get(AUParameterAddress address) const { return address >= first && address <= last ? values[address - first] : 0; }
  float operator[](AUParameterAddress address) const { return values[address - first]; }
};

/// A one-pole smoothing coefficient for a time in milliseconds.
inline float smoothingCoefficient(float milliseconds, double sampleRate) {
  return std::exp(-1.0f / (std::max(0.01f, milliseconds) * 0.001f * float(sampleRate)));
}

inline float decibels(float linear) { return 20 * std::log10(std::max(linear, 1e-6f)); }
inline float linear(float decibels) { return std::pow(10.0f, decibels / 20); }

/// Peak levels in and out, for meters.
struct PeakMeters {
  float input = -120, output = -120;

  template <typename In, typename Out>
  void measure(In const &inputs, Out const &outputs, int channels, int frameCount) {
    float in = 0, out = 0;
    for (int c = 0; c < channels; ++c) {
      for (int i = 0; i < frameCount; ++i) {
        in = std::max(in, std::abs(inputs[c][i]));
        out = std::max(out, std::abs(outputs[c][i]));
      }
    }
    input = decibels(in);
    output = decibels(out);
  }
};

// MARK: - Noise Gate

/// A noise gate like Logic's: it opens when the level (through the key's low cut) rises
/// above the threshold, holds, then closes once it falls below the threshold less the
/// hysteresis, turning the sound down by the reduction.
class NoiseGate {
public:
  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::min(channelCount, maximumChannels);
    for (auto &key : mKeys) key.reset();
    mEnvelope = 0;
    mGain = 0;
    mIsOpen = false;
    mHoldLeft = 0;
  }

  PeakMeters meters;
  float lastReduction = 0;
  bool isOpen() const { return mIsOpen; }

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    float threshold = mParameters[gateThreshold];
    float closeBelow = threshold - std::max(0.0f, mParameters[gateHysteresis]);
    float closed = linear(std::min(0.0f, mParameters[gateReduction]));
    if (mParameters[gateReduction] <= -99.5f) closed = 0;
    float attack = smoothingCoefficient(mParameters[gateAttack], mSampleRate);
    float release = smoothingCoefficient(mParameters[gateRelease], mSampleRate);
    int hold = int(mParameters[gateHold] * 0.001f * float(mSampleRate));
    float envelopeFall = smoothingCoefficient(5, mSampleRate);
    BiquadCoefficients key = BiquadCoefficients::highPass(std::max(10.0f, mParameters[gateKeyLowCut]), 0.707, mSampleRate);

    float least = 1;
    for (int i = 0; i < frameCount; ++i) {
      // The key: the loudest channel after its low cut, held at its peaks.
      float peak = 0;
      for (int c = 0; c < channels; ++c) peak = std::max(peak, std::abs(mKeys[c].process(inputs[c][i], key)));
      mEnvelope = std::max(peak, mEnvelope * envelopeFall);
      float level = decibels(mEnvelope);

      if (level >= threshold) {
        mIsOpen = true;
        mHoldLeft = hold;
      } else if (mIsOpen && level < closeBelow) {
        if (mHoldLeft > 0) { --mHoldLeft; } else { mIsOpen = false; }
      }
      float target = mIsOpen ? 1 : closed;
      float smoothing = target > mGain ? attack : release;
      mGain = smoothing * mGain + (1 - smoothing) * target;
      least = std::min(least, mGain);
      for (int c = 0; c < channels; ++c) outputs[c][i] = inputs[c][i] * mGain;
    }
    for (auto &state : mKeys) state.flushDenormals();
    if (mEnvelope < 1e-10f) mEnvelope = 0;
    lastReduction = decibels(least);
    meters.measure(inputs, outputs, channels, frameCount);
  }

private:
  ParameterBank<gateThreshold, gateKeyLowCut> mParameters;
  std::array<BiquadState, maximumChannels> mKeys;
  double mSampleRate = 44100;
  int mChannelCount = 0;
  float mEnvelope = 0, mGain = 0;
  bool mIsOpen = false;
  int mHoldLeft = 0;
};

// MARK: - Transient Shaper

/// Shapes the attack and sustain of each hit without a threshold (like Logic's Enveloper
/// or SPL's Transient Designer): a fast envelope rising ahead of a slow one is an attack,
/// a slow-falling envelope above a fast-falling one is the sustain; each is turned up or
/// down by its knob.
class TransientShaper {
public:
  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::min(channelCount, maximumChannels);
    mFast = mSlow = mHeld = mQuick = 0;
    mGainDB = 0;
  }

  PeakMeters meters;
  /// The gain it's applying now (dB), for its display.
  float lastGain = 0;

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    float attackAmount = std::clamp(mParameters[trnAttack] / 100, -1.0f, 1.0f);
    float sustainAmount = std::clamp(mParameters[trnSustain] / 100, -1.0f, 1.0f);
    float output = linear(mParameters[trnOutput]);
    float mix = std::clamp(mParameters[trnMix] / 100, 0.0f, 1.0f);

    // Attack: a fast and a slow follower with the same release.
    float fastAttack = smoothingCoefficient(0.3f, mSampleRate), slowAttack = smoothingCoefficient(20, mSampleRate);
    float sharedRelease = smoothingCoefficient(60, mSampleRate);
    // Sustain: a quick and a slow release with the same attack.
    float sharedAttack = smoothingCoefficient(1, mSampleRate);
    float quickRelease = smoothingCoefficient(25, mSampleRate), slowRelease = smoothingCoefficient(350, mSampleRate);
    float gainSmoothing = smoothingCoefficient(0.5f, mSampleRate);

    float loudest = -100;
    for (int i = 0; i < frameCount; ++i) {
      float level = 0;
      for (int c = 0; c < channels; ++c) level = std::max(level, std::abs(inputs[c][i]));
      auto follow = [](float &envelope, float input, float attack, float release) {
        float coefficient = input > envelope ? attack : release;
        envelope = coefficient * envelope + (1 - coefficient) * input;
      };
      follow(mFast, level, fastAttack, sharedRelease);
      follow(mSlow, level, slowAttack, sharedRelease);
      follow(mQuick, level, sharedAttack, quickRelease);
      follow(mHeld, level, sharedAttack, slowRelease);

      float attack = mFast > mSlow ? decibels(mFast) - decibels(std::max(mSlow, 1e-6f)) : 0;
      float sustain = mHeld > mQuick ? decibels(mHeld) - decibels(std::max(mQuick, 1e-6f)) : 0;
      float wanted = std::clamp(attackAmount * attack * 1.5f + sustainAmount * sustain * 1.2f, -24.0f, 18.0f);
      mGainDB = gainSmoothing * mGainDB + (1 - gainSmoothing) * wanted;
      loudest = std::max(loudest, mGainDB);
      float gain = linear(mGainDB) * mix + (1 - mix);
      for (int c = 0; c < channels; ++c) outputs[c][i] = inputs[c][i] * gain * output;
    }
    lastGain = loudest;
    meters.measure(inputs, outputs, channels, frameCount);
  }

private:
  ParameterBank<trnAttack, trnMix> mParameters;
  double mSampleRate = 44100;
  int mChannelCount = 0;
  float mFast = 0, mSlow = 0, mQuick = 0, mHeld = 0, mGainDB = 0;
};

// MARK: - Loudness

/// Loudness by ITU-R BS.1770 / EBU R128: K-weighted, momentary (400 ms), short-term (3 s)
/// and integrated (gated, since the last reset) loudness in LUFS, and the true peak.
class LoudnessMeter {
public:
  void initialize(double sampleRate) {
    mSampleRate = sampleRate;
    // The K-weighting: a high shelf for the head, then a high-pass, exactly as BS.1770
    // defines them at 48 kHz, designed again for this rate.
    {
      double f0 = 1681.974450955533, gain = 3.999843853973347, q = 0.7071752369554196;
      double k = std::tan(M_PI * f0 / sampleRate);
      double vh = std::pow(10.0, gain / 20), vb = std::pow(vh, 0.4996667741545416);
      double a0 = 1 + k / q + k * k;
      mShelf = {(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0};
    }
    {
      double f0 = 38.13547087602444, q = 0.5003270373238773;
      double k = std::tan(M_PI * f0 / sampleRate);
      double a0 = 1 + k / q + k * k;
      mHighPass = {1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0};
    }
    mBlockLength = std::max(1, int(sampleRate / 10));
    reset();
  }

  void reset() {
    for (auto &state : mShelfStates) state.reset();
    for (auto &state : mHighPassStates) state.reset();
    mBlocks.fill(0);
    mBlockCount = 0;
    mBlockSum = 0;
    mBlockFill = 0;
    mHistogram.fill(0);
    mHistogramEnergy.fill(0);
    mGatedBlocks = 0;
    mTruePeak = 0;
    momentary = shortTerm = integrated = -120;
  }

  float momentary = -120, shortTerm = -120, integrated = -120;
  float truePeak() const { return decibels(mTruePeak); }
  /// How many 100 ms steps have been measured, and how many of them counted towards the
  /// integrated loudness (louder than −70 LUFS), since the last reset.
  uint64_t blocks() const { return mBlockCount; }
  uint64_t gatedBlocks() const { return mGatedBlocks; }

  /// Measures what the effect puts out (any per-channel buffers: pointers to the samples).
  template <typename Buffers>
  void measure(Buffers const &outputs, int channels, int frameCount) {
    channels = std::min(channels, 2);
    for (int i = 0; i < frameCount; ++i) {
      float sum = 0;
      for (int c = 0; c < channels; ++c) {
        float weighted = mHighPassStates[c].process(mShelfStates[c].process(outputs[c][i], mShelf), mHighPass);
        sum += weighted * weighted;
        // The true peak: the samples, and points between them (4× by cubic interpolation).
        float *history = mHistory[c].data();
        history[0] = history[1]; history[1] = history[2]; history[2] = history[3]; history[3] = outputs[c][i];
        mTruePeak = std::max(mTruePeak, std::abs(history[3]));
        for (float t : {0.25f, 0.5f, 0.75f}) mTruePeak = std::max(mTruePeak, std::abs(between(history, t)));
      }
      // A mono signal counts in both channels, as it would be heard.
      if (channels == 1) sum *= 2;
      mBlockSum += sum;
      if (++mBlockFill == mBlockLength) finishBlock();
    }
  }

private:
  static float between(float const *y, float t) {
    float c1 = 0.5f * (y[2] - y[0]);
    float c2 = y[0] - 2.5f * y[1] + 2 * y[2] - 0.5f * y[3];
    float c3 = 0.5f * (y[3] - y[0]) + 1.5f * (y[1] - y[2]);
    return ((c3 * t + c2) * t + c1) * t + y[1];
  }

  static float lufs(double meanSquare) { return float(-0.691 + 10 * std::log10(std::max(meanSquare, 1e-12))); }

  /// Every 100 ms: the momentary and short-term windows end here, and the 400 ms block
  /// joins the integrated measurement's histogram.
  void finishBlock() {
    mBlocks[mBlockCount % mBlocks.size()] = mBlockSum / double(mBlockLength);
    ++mBlockCount;
    mBlockSum = 0;
    mBlockFill = 0;
    auto mean = [&](int count) {
      int available = int(std::min<uint64_t>(mBlockCount, uint64_t(count)));
      double total = 0;
      for (int k = 0; k < available; ++k) total += mBlocks[(mBlockCount - 1 - uint64_t(k)) % mBlocks.size()];
      return available > 0 ? total / double(count) : 0;
    };
    double block = mean(4);
    momentary = lufs(block);
    shortTerm = lufs(mean(30));
    if (mBlockCount >= 4 && momentary > -70) {
      int bin = std::clamp(int((momentary + 70) * 10), 0, int(mHistogram.size()) - 1);
      mHistogram[size_t(bin)] += 1;
      mHistogramEnergy[size_t(bin)] += block;
      ++mGatedBlocks;
    }
    updateIntegrated();
  }

  /// The gated mean: blocks above −70 LUFS, then above 10 LU under their own mean.
  void updateIntegrated() {
    double energy = 0, count = 0;
    for (size_t bin = 0; bin < mHistogram.size(); ++bin) { energy += mHistogramEnergy[bin]; count += mHistogram[bin]; }
    if (count == 0) { integrated = -120; return; }
    float relativeGate = lufs(energy / count) - 10;
    energy = 0;
    count = 0;
    for (size_t bin = 0; bin < mHistogram.size(); ++bin) {
      if (float(bin) / 10 - 70 < relativeGate) continue;
      energy += mHistogramEnergy[bin];
      count += mHistogram[bin];
    }
    integrated = count > 0 ? lufs(energy / count) : -120;
  }

  double mSampleRate = 44100;
  BiquadCoefficients mShelf, mHighPass;
  std::array<BiquadState, 2> mShelfStates, mHighPassStates;
  std::array<std::array<float, 4>, 2> mHistory {};
  std::array<double, 30> mBlocks {};
  uint64_t mBlockCount = 0, mGatedBlocks = 0;
  double mBlockSum = 0;
  int mBlockFill = 0, mBlockLength = 4410;
  /// 0.1 LU bins from −70 to +5 LUFS: how many blocks, and their energy.
  std::array<double, 751> mHistogram {}, mHistogramEnergy {};
  float mTruePeak = 0;
};

// MARK: - Maximizer

/// A look-ahead brickwall limiter like Logic's Adaptive Limiter: the input gain pushes the
/// level up, and the gain comes down just before each peak (2 ms ahead) so nothing passes
/// the ceiling, then recovers over the release. It reports its look-ahead as latency.
class Maximizer {
public:
  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  static int lookAhead(double sampleRate) { return int(std::lround(0.002 * sampleRate)); }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::min(channelCount, maximumChannels);
    mLookAhead = lookAhead(sampleRate);
    for (auto &line : mDelay) line.assign(size_t(mLookAhead + 1), 0.0f);
    mWanted.assign(size_t(mLookAhead + 1), 1.0f);
    mWrite = 0;
    mGain = 1;
    for (auto &history : mHistory) history.fill(0);
    loudness.initialize(sampleRate);
  }

  PeakMeters meters;
  LoudnessMeter loudness;
  float lastReduction = 0;

  /// Starts the integrated loudness and true peak again (from the interface).
  void resetLoudness() { __atomic_store_n(&mResetRequested, true, __ATOMIC_RELEASE); }

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    if (__atomic_exchange_n(&mResetRequested, false, __ATOMIC_ACQ_REL)) loudness.reset();
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    float inputGain = linear(mParameters[maxGain]);
    float ceiling = linear(std::min(0.0f, mParameters[maxCeiling]));
    float release = smoothingCoefficient(std::max(1.0f, mParameters[maxRelease]), mSampleRate);
    bool truePeak = mParameters[maxTruePeak] >= 0.5f;
    int size = mLookAhead + 1;
    // Reaching each peak's gain within the look-ahead.
    float attack = smoothingCoefficient(float(mLookAhead) / float(mSampleRate) * 1000 / 5, mSampleRate);

    float least = 1;
    for (int i = 0; i < frameCount; ++i) {
      // How far the incoming sample needs turning down.
      float peak = 0;
      for (int c = 0; c < channels; ++c) {
        float sample = inputs[c][i] * inputGain;
        peak = std::max(peak, std::abs(sample));
        if (truePeak) {
          auto &h = mHistory[c];
          h[0] = h[1]; h[1] = h[2]; h[2] = h[3]; h[3] = sample;
          for (float t : {0.25f, 0.5f, 0.75f}) {
            float c1 = 0.5f * (h[2] - h[0]), c2 = h[0] - 2.5f * h[1] + 2 * h[2] - 0.5f * h[3];
            float c3 = 0.5f * (h[3] - h[0]) + 1.5f * (h[1] - h[2]);
            peak = std::max(peak, std::abs(((c3 * t + c2) * t + c1) * t + h[1]));
          }
        }
        mDelay[c][size_t(mWrite)] = sample;
      }
      mWanted[size_t(mWrite)] = peak > ceiling ? ceiling / peak : 1;
      // The least gain anything in the look-ahead window needs.
      float target = 1;
      for (float wanted : mWanted) target = std::min(target, wanted);
      float smoothing = target < mGain ? attack : release;
      mGain = smoothing * mGain + (1 - smoothing) * target;
      // The gain can't be above what the sample leaving now needs.
      int leaving = (mWrite + 1) % size;
      float gain = std::min(mGain, mWanted[size_t(leaving)]);
      least = std::min(least, gain);
      for (int c = 0; c < channels; ++c) {
        float out = mDelay[c][size_t(leaving)] * gain;
        outputs[c][i] = std::clamp(out, -ceiling, ceiling);
      }
      mWrite = (mWrite + 1) % size;
    }
    lastReduction = decibels(least);
    meters.measure(inputs, outputs, channels, frameCount);
    loudness.measure(outputs, channels, frameCount);
  }

private:
  ParameterBank<maxGain, maxTruePeak> mParameters;
  double mSampleRate = 44100;
  int mChannelCount = 0, mLookAhead = 88, mWrite = 0;
  std::array<std::vector<float>, maximumChannels> mDelay;
  std::vector<float> mWanted;
  std::array<std::array<float, 4>, maximumChannels> mHistory {};
  float mGain = 1;
  bool mResetRequested = false;
};

// MARK: - De-Esser

/// Tames sibilance ("ss", "sh") like Logic's DeEsser 2: a detector listening above the
/// frequency turns down only the band above it (a split that adds back up exactly), by up
/// to the range.
class DeEsser {
public:
  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::min(channelCount, maximumChannels);
    for (auto &state : mSplit) state.reset();
    for (auto &state : mDetector) state.reset();
    mEnvelope = 0;
    mReduction = 0;
  }

  PeakMeters meters;
  float lastReduction = 0;

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    double frequency = std::clamp(double(mParameters[desFrequency]), 1000.0, mSampleRate * 0.45);
    BiquadCoefficients split = BiquadCoefficients::firstOrderLowPass(frequency, mSampleRate);
    BiquadCoefficients detector = BiquadCoefficients::highPass(frequency, 0.707, mSampleRate);
    float threshold = mParameters[desThreshold];
    float range = std::max(0.0f, mParameters[desRange]);
    bool listen = mParameters[desListen] >= 0.5f;
    float attack = smoothingCoefficient(0.5f, mSampleRate), release = smoothingCoefficient(60, mSampleRate);
    float envelopeFall = smoothingCoefficient(10, mSampleRate);

    float most = 0;
    for (int i = 0; i < frameCount; ++i) {
      float level = 0;
      for (int c = 0; c < channels; ++c) level = std::max(level, std::abs(mDetector[c].process(inputs[c][i], detector)));
      mEnvelope = std::max(level, mEnvelope * envelopeFall);
      float over = decibels(mEnvelope) - threshold;
      float wanted = over > 0 ? -std::min(range, over * 0.8f) : 0;
      float smoothing = wanted < mReduction ? attack : release;
      mReduction = smoothing * mReduction + (1 - smoothing) * wanted;
      most = std::min(most, mReduction);
      float gain = linear(mReduction);
      for (int c = 0; c < channels; ++c) {
        float low = mSplit[c].process(inputs[c][i], split);
        float high = inputs[c][i] - low;
        outputs[c][i] = listen ? high * (1 - gain) : low + high * gain;
      }
    }
    for (auto &state : mSplit) state.flushDenormals();
    for (auto &state : mDetector) state.flushDenormals();
    lastReduction = most;
    meters.measure(inputs, outputs, channels, frameCount);
  }

private:
  ParameterBank<desFrequency, desListen> mParameters;
  double mSampleRate = 44100;
  int mChannelCount = 0;
  std::array<BiquadState, maximumChannels> mSplit, mDetector;
  float mEnvelope = 0, mReduction = 0;
};

}  // namespace ongaku
