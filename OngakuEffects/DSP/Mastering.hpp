//
//  Mastering.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <memory>
#include <span>
#include <vector>

#include "Biquad.hpp"
#include "Colour.hpp"
#include "Compressor.hpp"
#include "Dynamics.hpp"
#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

// MARK: - Oversampler

/// Four times the sample rate and back, through a linear-phase windowed sinc cut at the
/// original Nyquist frequency (a Kaiser window: flat to about 0.46 of the rate, 60 dB down
/// from 0.54). It's long so the limiter's detector sees peaks made by the highest
/// frequencies too: at 0.41 of the rate it let noise-like material past the ceiling. Every
/// fourth point up is an original sample, so the delays are whole samples: `upDelay` going
/// up, `roundTripDelay` up and back down.
class Oversampler {
public:
  static constexpr int factor = 4;
  static constexpr int order = 48;
  static constexpr int length = factor * order + 1;
  static constexpr int upDelay = order / 2;
  static constexpr int roundTripDelay = order;

  /// Designs the filter and clears the history (it allocates: not on the render thread).
  void initialize(int channelCount) {
    auto bessel = [](double x) {
      double sum = 1, term = 1;
      for (int k = 1; k < 30; ++k) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
      }
      return sum;
    };
    double beta = 5.65;
    int middle = length / 2;
    for (int j = 0; j < length; ++j) {
      int offset = j - middle;
      // The sinc's zeros fall exactly on the original samples.
      double sinc = offset == 0 ? 1 : offset % factor == 0 ? 0 : std::sin(M_PI * offset / factor) / (M_PI * offset / factor);
      double position = double(offset) / middle;
      double window = bessel(beta * std::sqrt(std::max(0.0, 1 - position * position))) / bessel(beta);
      mTaps[size_t(j)] = float(sinc * window / factor);
    }
    for (int p = 0; p < factor; ++p) {
      for (int i = 0; i <= order; ++i) {
        int j = factor * i + p;
        mPhases[size_t(p)][size_t(i)] = j < length ? mTaps[size_t(j)] * factor : 0;
      }
    }
    mChannels.assign(size_t(std::clamp(channelCount, 1, maximumChannels)), Channel());
  }

  /// The four points from `upDelay` samples ago towards the next sample: that sample, then
  /// three in between.
  void up(int channel, float input, float *points) {
    Channel &state = mChannels[size_t(channel)];
    // The history is written twice, so the latest `order + 1` samples are always in a row.
    state.upWrite = (state.upWrite == 0 ? order + 1 : state.upWrite) - 1;
    state.upHistory[size_t(state.upWrite)] = state.upHistory[size_t(state.upWrite + order + 1)] = input;
    float const *recent = &state.upHistory[size_t(state.upWrite)];
    points[0] = recent[upDelay];
    for (int p = 1; p < factor; ++p) {
      float const *taps = mPhases[size_t(p)].data();
      float sum = 0;
      for (int i = 0; i <= order; ++i) sum += taps[i] * recent[i];
      points[p] = sum;
    }
  }

  /// One sample from four points made from `up`'s (`roundTripDelay` samples after the
  /// input they came from).
  float down(int channel, float const *points) {
    Channel &state = mChannels[size_t(channel)];
    push(state, points[0]);
    float const *recent = &state.downHistory[size_t(state.downWrite)];
    float sum = 0;
    for (int j = 0; j < length; ++j) sum += mTaps[size_t(j)] * recent[j];
    for (int p = 1; p < factor; ++p) push(state, points[p]);
    return sum;
  }

private:
  struct Channel {
    std::array<float, 2 * (order + 1)> upHistory {};
    std::array<float, 2 * length> downHistory {};
    int upWrite = 0, downWrite = 0;
  };

  static void push(Channel &state, float point) {
    state.downWrite = (state.downWrite == 0 ? length : state.downWrite) - 1;
    state.downHistory[size_t(state.downWrite)] = state.downHistory[size_t(state.downWrite + length)] = point;
  }

  std::array<float, length> mTaps {};
  std::array<std::array<float, order + 1>, factor> mPhases {};
  std::vector<Channel> mChannels;
};

// MARK: - True-peak limiter

/// A look-ahead brickwall limiter that keeps the true peak (the waveform between samples
/// too, found at four times the rate) under its ceiling: the gain comes down over the 2 ms
/// before each peak, then recovers over the release. Its latency is the look-ahead plus the
/// detector's filter.
class TruePeakLimiter {
public:
  static int lookAhead(double sampleRate) { return Maximizer::lookAhead(sampleRate); }
  static int latency(double sampleRate) { return lookAhead(sampleRate) + Oversampler::upDelay; }

  void initialize(int channelCount, double sampleRate) {
    mChannelCount = std::clamp(channelCount, 1, maximumChannels);
    mLookAhead = lookAhead(sampleRate);
    mDelaySize = latency(sampleRate) + 1;
    for (int c = 0; c < maximumChannels; ++c) mDelay[size_t(c)].assign(c < mChannelCount ? size_t(mDelaySize) : 0, 0.0f);
    // The peaks either side of the sample leaving, and every one in the look-ahead.
    mWanted.assign(size_t(mLookAhead + 2), 1.0f);
    mDetector.initialize(mChannelCount);
    mDelayWrite = mWantedWrite = 0;
    mGain = 1;
    mAttack = smoothingCoefficient(float(mLookAhead) / float(sampleRate) * 1000 / 5, sampleRate);
    mRelease = smoothingCoefficient(100, sampleRate);
  }

  /// The least gain in the last call (dB).
  float lastReduction = 0;

  /// Limits the buffers in place, to `ceiling` (linear).
  void process(float *const *buffers, int channels, int frameCount, float ceiling) {
    channels = std::min(channels, mChannelCount);
    int wantedSize = int(mWanted.size());
    float least = 1;
    // Aimed a little under the ceiling: the gain moving between samples can lift the peaks
    // between them a few hundredths of a dB over what the detector saw.
    float aim = ceiling * detectionMargin;
    for (int i = 0; i < frameCount; ++i) {
      float peak = 0;
      for (int c = 0; c < channels; ++c) {
        float points[Oversampler::factor];
        mDetector.up(c, buffers[c][i], points);
        for (float point : points) peak = std::max(peak, std::abs(point));
        mDelay[size_t(c)][size_t(mDelayWrite)] = buffers[c][i];
      }
      mWanted[size_t(mWantedWrite)] = peak > aim ? aim / peak : 1;
      float target = *std::min_element(mWanted.begin(), mWanted.end());
      float smoothing = target < mGain ? mAttack : mRelease;
      mGain = smoothing * mGain + (1 - smoothing) * target;
      // The sample leaving now can't have more gain than the peaks either side of it need.
      float gain = std::min({mGain, mWanted[size_t((mWantedWrite + 1) % wantedSize)], mWanted[size_t((mWantedWrite + 2) % wantedSize)]});
      least = std::min(least, gain);
      int leaving = (mDelayWrite + 1) % mDelaySize;
      for (int c = 0; c < channels; ++c) {
        buffers[c][i] = std::clamp(mDelay[size_t(c)][size_t(leaving)] * gain, -ceiling, ceiling);
      }
      mDelayWrite = leaving;
      mWantedWrite = (mWantedWrite + 1) % wantedSize;
    }
    lastReduction = decibels(least);
  }

private:
  /// −0.1 dB.
  static constexpr float detectionMargin = 0.98855f;

  Oversampler mDetector;
  std::array<std::vector<float>, maximumChannels> mDelay;
  std::vector<float> mWanted;
  int mChannelCount = 0, mLookAhead = 88, mDelaySize = 1, mDelayWrite = 0, mWantedWrite = 0;
  float mGain = 1, mAttack = 0, mRelease = 0;
};

// MARK: - Mastering

/// One 100 ms step of what Listen heard, for `MasteringAnalysis` in OngakuCore: the
/// momentary loudness (LUFS), the mid signal's energy in ten octave bands (31.5 Hz–16 kHz;
/// 0 past the rate's reach), the mid and side energy, and the highest true peak (linear).
struct MasteringListenBlock {
  float loudness = -120;
  float bands[10] = {};
  float mid = 0, side = 0, truePeak = 0;
};

/// A mastering chain on a few clear controls, like Logic's Mastering Assistant: EQ, a
/// gentle compressor, a character stage, stereo width (with the lows kept mono), then a
/// true-peak limiter whose make-up gain brings the song to the loudness asked for. Compare
/// plays the input instead, just as late and just as loud, to hear what the chain does.
class Mastering {
public:
  enum Character { clean = 0, valve = 1, punch = 2, transparent = 3 };

  /// How late the output is, whatever the character: the character stage's oversampling
  /// (the clean sound waits for it), then the limiter's detector and look-ahead.
  static int latency(double sampleRate) { return Oversampler::roundTripDelay + TruePeakLimiter::latency(sampleRate); }

  /// The measured loudness that means the song hasn't been listened to yet.
  static constexpr float notMeasured = -70;
  /// Low-End Mono below this is off.
  static constexpr float lowEndMonoOff = 60;

  void setParameter(AUParameterAddress address, float value) {
    mParameters.set(address, value);
    if (address == mstListen) listen(value >= 0.5f);
  }

  float parameter(AUParameterAddress address) const {
    // Listen reads as off once listening has stopped, by itself too.
    if (address == mstListen) return isListening() ? 1 : 0;
    return mParameters.get(address);
  }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::clamp(channelCount, 1, maximumChannels);
    mGlide = 1 - std::exp(-double(chunk) / (0.015 * sampleRate));
    mFade = float(1 / (0.02 * sampleRate));
    mMakeUpGlide = 1 - std::exp(-float(chunk) / (0.5f * float(sampleRate)));
    mCompareGlide = 1 - std::exp(-float(chunk) / float(sampleRate));
    for (auto &channel : mChannels) channel = Channel();
    mCharacterWrite = 0;
    mDCBlock = BiquadCoefficients::firstOrderHighPass(5, sampleRate);
    mValveMatched = 0.25f / std::abs(Saturation::shape(0.25f * valveDrive, tube));
    mSideHigh = mSideHigh2 = mMidPhase = mWidthState = BiquadState();

    mCompressor.initialize(mChannelCount, sampleRate);
    mCompressor.setParameter(compKnee, 6);
    mCompressor.setParameter(compMakeUp, 0);
    mCompressor.setParameter(compAutoGain, 0);
    mCompressor.setParameter(compMix, 100);
    mCompressor.setParameter(compDetection, 1);
    mCharacter.initialize(mChannelCount);
    mLimiter.initialize(mChannelCount, sampleRate);
    mOutputPeaks.initialize(mChannelCount);

    // Listening: room for 15 minutes of steps, and the octave bands it measures.
    mListened.assign(size_t(maximumListenedBlocks), MasteringListenBlock());
    __atomic_store_n(&mListenedCount, 0, __ATOMIC_RELEASE);
    for (int b = 0; b < listenBandCount; ++b) {
      double center = listenBandCenters[size_t(b)];
      mListenBandValid[size_t(b)] = center < sampleRate * 0.45;
      if (mListenBandValid[size_t(b)]) mListenBands[size_t(b)] = BiquadCoefficients::bandPass(center, 1.41, sampleRate);
    }
    mInputPeaks.initialize(mChannelCount);

    mCompareSize = latency(sampleRate) + 1;
    for (int c = 0; c < maximumChannels; ++c) mCompareDelay[size_t(c)].assign(c < mChannelCount ? size_t(mCompareSize) : 0, 0.0f);
    mCompareWrite = 0;

    mLoudness = std::make_unique<Loudness>();
    for (LoudnessMeter *meter : {&mLoudness->input, &mLoudness->output, &mLoudness->chainIn, &mLoudness->chainOut, &mLoudness->limited}) {
      meter->initialize(sampleRate);
    }
    mSeen = mParameters.values;
    mChainChange = mLimiterLoss = 0;
    mEstimatedBlock = 0;

    // Start where the settings are, rather than gliding there.
    Targets wanted = targets();
    for (int b = 0; b < bandCount; ++b) {
      mBandGains[size_t(b)] = wanted.bands[size_t(b)];
      mBands[size_t(b)] = band(b, wanted.bands[size_t(b)]);
    }
    configureCompressor(wanted);
    mValve = wanted.valve;
    mMono = wanted.mono;
    mMonoFrequency = wanted.monoFrequency;
    designLowEnd();
    mWidthDB = wanted.widthDB;
    mWidthShelf = BiquadCoefficients::highShelf(widthFrequency, mWidthDB, 0.71, mSampleRate);
    mCeilingDB = wanted.ceilingDB;
    mMakeUpDB = makeUpTarget();
    mCompareDB = mCompareTarget = 0;
    mCompareBlend = wanted.compare;
  }

  PeakMeters meters;
  /// For the window: what the compressor and the limiter take (dB), the loudness in and out
  /// (short-term, LUFS), the output's highest true peak in the last render (dBTP), and the
  /// make-up gain (dB).
  float lastCompression = 0, lastLimiting = 0, inputLoudness = -120, outputLoudness = -120, outputTruePeak = -120, makeUp = 0;

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    if (channels == 0 || !mLoudness) return;
    Loudness &loudness = *mLoudness;
    if (settingsChanged()) restartEstimate();
    int measured = std::min(channels, 2);
    float inputPeak = 0, outputPeak = 0, truePeak = 0, compression = 0, limiting = 0;

    // In short pieces, so the settings glide every 32 samples.
    for (int start = 0; start < frameCount; start += chunk) {
      int frames = std::min(chunk, frameCount - start);
      Targets wanted = targets();
      glide(wanted);

      // The input is copied first: the output may be the same memory.
      std::array<float *, maximumChannels> work {}, dry {};
      for (int c = 0; c < channels; ++c) {
        work[size_t(c)] = mWork[size_t(c)].data();
        dry[size_t(c)] = mDry[size_t(c)].data();
        std::copy_n(inputs[size_t(c)] + start, frames, dry[size_t(c)]);
        std::copy_n(dry[size_t(c)], frames, work[size_t(c)]);
        for (int i = 0; i < frames; ++i) inputPeak = std::max(inputPeak, std::abs(dry[size_t(c)][i]));
      }
      loudness.input.measure(dry, measured, frames);
      loudness.chainIn.measure(dry, measured, frames);
      if (__atomic_load_n(&mListening, __ATOMIC_ACQUIRE)) listen(dry, channels, frames, loudness.input);

      for (int c = 0; c < channels; ++c) {
        Channel &state = mChannels[size_t(c)];
        float *samples = work[size_t(c)];
        for (int b = 0; b < bandCount; ++b) {
          for (int i = 0; i < frames; ++i) samples[i] = state.eq[size_t(b)].process(samples[i], mBands[size_t(b)]);
        }
      }
      mCompressor.process(
        std::span<float const *>(const_cast<float const **>(work.data()), size_t(channels)),
        std::span<float *>(work.data(), size_t(channels)), frames);
      compression = std::min(compression, mCompressor.lastReduction);
      character(work, channels, frames, wanted.valve);
      if (channels == 2) stereo(work[0], work[1], frames, wanted.mono);
      loudness.chainOut.measure(work, measured, frames);

      // The make-up gain, then the limiter.
      float makeUpStart = linear(mMakeUpDB);
      mMakeUpDB += (makeUpTarget() - mMakeUpDB) * mMakeUpGlide;
      float makeUpEnd = linear(mMakeUpDB);
      for (int c = 0; c < channels; ++c) {
        float step = (makeUpEnd - makeUpStart) / float(frames);
        for (int i = 0; i < frames; ++i) work[size_t(c)][i] *= makeUpStart + step * float(i + 1);
      }
      mLimiter.process(work.data(), channels, frames, linear(float(mCeilingDB)));
      limiting = std::min(limiting, mLimiter.lastReduction);
      loudness.output.measure(work, measured, frames);
      // What the limiter costs in loudness: its output with the make-up taken out again.
      std::array<float *, 2> unmade {mScratch[0].data(), mScratch[1].data()};
      for (int c = 0; c < measured; ++c) {
        for (int i = 0; i < frames; ++i) unmade[size_t(c)][i] = work[size_t(c)][i] / makeUpEnd;
      }
      loudness.limited.measure(unmade, measured, frames);
      estimate();

      // Compare: the input as late as the processed sound, turned to its loudness.
      if (loudness.input.shortTerm > -70 && loudness.output.shortTerm > -70) {
        mCompareTarget = std::clamp(loudness.output.shortTerm - loudness.input.shortTerm, -24.0f, 24.0f);
      }
      float compareStart = linear(mCompareDB);
      mCompareDB += (mCompareTarget - mCompareDB) * mCompareGlide;
      float compareEnd = linear(mCompareDB);
      for (int i = 0; i < frames; ++i) {
        mCompareBlend += std::clamp(wanted.compare - mCompareBlend, -mFade, mFade);
        float matched = compareStart + (compareEnd - compareStart) * float(i + 1) / float(frames);
        int leaving = (mCompareWrite + 1) % mCompareSize;
        for (int c = 0; c < channels; ++c) {
          std::vector<float> &line = mCompareDelay[size_t(c)];
          line[size_t(mCompareWrite)] = dry[size_t(c)][i];
          float processed = work[size_t(c)][i];
          float out = processed + (line[size_t(leaving)] * matched - processed) * mCompareBlend;
          outputs[size_t(c)][start + i] = out;
          outputPeak = std::max(outputPeak, std::abs(out));
          float points[Oversampler::factor];
          mOutputPeaks.up(c, out, points);
          for (float point : points) truePeak = std::max(truePeak, std::abs(point));
        }
        mCompareWrite = leaving;
      }
    }

    for (auto &channel : mChannels) channel.flushDenormals();
    for (BiquadState *state : {&mSideHigh, &mSideHigh2, &mMidPhase, &mWidthState}) state->flushDenormals();
    meters.input = decibels(inputPeak);
    meters.output = decibels(outputPeak);
    lastCompression = compression;
    lastLimiting = limiting;
    inputLoudness = loudness.input.shortTerm;
    outputLoudness = loudness.output.shortTerm;
    outputTruePeak = decibels(truePeak);
    makeUp = mMakeUpDB;
  }

  // MARK: Listening (called from the main thread)

  static constexpr int maximumListenedBlocks = 9000;

  /// Starts listening afresh, or stops. Listening stops by itself when it's full.
  void listen(bool on) {
    if (on) __atomic_store_n(&mListenRestart, true, __ATOMIC_RELEASE);
    __atomic_store_n(&mListening, on, __ATOMIC_RELEASE);
  }

  bool isListening() const { return __atomic_load_n(&mListening, __ATOMIC_ACQUIRE); }

  /// How many steps have been heard; each of them can be read with `listenedBlock`.
  int listenedBlocks() const { return __atomic_load_n(&mListenedCount, __ATOMIC_ACQUIRE); }

  MasteringListenBlock listenedBlock(int index) const {
    return index >= 0 && index < listenedBlocks() ? mListened[size_t(index)] : MasteringListenBlock();
  }

private:
  static constexpr int chunk = 32;
  static constexpr int listenBandCount = 10;
  static constexpr std::array<double, listenBandCount> listenBandCenters {
    31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000};

  /// Measures a piece of the input while listening, and hands over a step each time the
  /// loudness meter completes one (every 100 ms), so each step has its momentary loudness.
  void listen(std::array<float *, maximumChannels> const &dry, int channels, int frames, LoudnessMeter const &meter) {
    if (__atomic_exchange_n(&mListenRestart, false, __ATOMIC_ACQ_REL)) {
      mListenSums = ListenSums();
      for (auto &state : mListenBandStates) state.reset();
      mListenStep = meter.blocks();
      __atomic_store_n(&mListenedCount, 0, __ATOMIC_RELEASE);
    }
    float const *left = dry[0];
    float const *right = channels > 1 ? dry[1] : dry[0];
    for (int i = 0; i < frames; ++i) {
      float mid = (left[i] + right[i]) / 2, side = (left[i] - right[i]) / 2;
      mListenSums.mid += double(mid) * mid;
      mListenSums.side += double(side) * side;
      for (int b = 0; b < listenBandCount; ++b) {
        if (!mListenBandValid[size_t(b)]) continue;
        float band = mListenBandStates[size_t(b)].process(mid, mListenBands[size_t(b)]);
        mListenSums.bands[size_t(b)] += double(band) * band;
      }
      for (int c = 0; c < std::min(channels, 2); ++c) {
        float points[Oversampler::factor];
        mInputPeaks.up(c, dry[size_t(c)][i], points);
        for (float point : points) mListenSums.truePeak = std::max(mListenSums.truePeak, std::abs(point));
      }
    }
    mListenSums.frames += frames;
    if (meter.blocks() == mListenStep) return;
    mListenStep = meter.blocks();

    int count = listenedBlocks();
    if (count >= maximumListenedBlocks) {
      __atomic_store_n(&mListening, false, __ATOMIC_RELEASE);
      return;
    }
    MasteringListenBlock &block = mListened[size_t(count)];
    double frameCount = double(std::max(mListenSums.frames, 1));
    block.loudness = meter.momentary;
    for (int b = 0; b < listenBandCount; ++b) block.bands[b] = float(mListenSums.bands[size_t(b)] / frameCount);
    block.mid = float(mListenSums.mid / frameCount);
    block.side = float(mListenSums.side / frameCount);
    block.truePeak = mListenSums.truePeak;
    mListenSums = ListenSums();
    for (auto &state : mListenBandStates) state.flushDenormals();
    __atomic_store_n(&mListenedCount, count + 1, __ATOMIC_RELEASE);
  }

  struct ListenSums {
    std::array<double, listenBandCount> bands {};
    double mid = 0, side = 0;
    float truePeak = 0;
    int frames = 0;
  };
  static constexpr int bandCount = 5;
  static constexpr int tube = 1;
  /// Valve: the tube curve, driven 3 dB under its level-matched point, half mixed in.
  static constexpr float valveDrive = 0.708f, valveMix = 0.5f;
  /// Width turns up the side above here (a shelf), leaving the lows alone.
  static constexpr double widthFrequency = 300;

  struct Channel {
    std::array<BiquadState, bandCount> eq;
    BiquadState dcBlock;
    /// The clean sound, waiting as long as the oversampled character takes.
    std::array<float, Oversampler::roundTripDelay> waiting {};
    void flushDenormals() {
      for (auto &state : eq) state.flushDenormals();
      dcBlock.flushDenormals();
    }
  };

  /// Where each stage is heading, from the parameters and the character.
  struct Targets {
    std::array<double, bandCount> bands {};
    float threshold = -18, ratio = 1, attack = 20, release = 200;
    float valve = 0, mono = 0, monoFrequency = 120, compare = 0;
    double widthDB = 0, ceilingDB = -1;
  };

  /// The loudness meters: the input and the processed output (for the window, and to match
  /// Compare's level), and three that start again whenever the settings change, to learn
  /// what the chain does to the loudness: before it, after it (before the make-up), and
  /// after the limiter with the make-up taken out.
  struct Loudness {
    LoudnessMeter input, output, chainIn, chainOut, limited;
  };

  Targets targets() const {
    Targets wanted;
    int character = std::clamp(int(std::lround(mParameters[mstCharacter])), 0, 3);
    bool isTransparent = character == transparent;
    std::array<float, bandCount> gains;
    for (int b = 0; b < bandCount; ++b) gains[size_t(b)] = mParameters[mstLowShelf + AUParameterAddress(b)];
    wanted.bands = effectiveBands(character, mParameters[mstEQAmount], gains.data());
    // Dynamics scales how much the compressor takes off above the threshold (1 − 1/ratio):
    // 50 % is the ratio as set, 0 none, 100 % twice as much (up to 5:1).
    float firmness = std::clamp(mParameters[mstDynamics] / 50, 0.0f, 2.0f) * (isTransparent ? 0.5f : 1.0f);
    float slope = std::clamp((1 - 1 / std::clamp(mParameters[mstRatio], 1.0f, 4.0f)) * firmness, 0.0f, 0.8f);
    wanted.ratio = 1 / (1 - slope);
    wanted.threshold = std::clamp(mParameters[mstThreshold], -40.0f, 0.0f);
    // Punch's slower attack lets the start of each hit through.
    wanted.attack = std::clamp(mParameters[mstAttack], 1.0f, 100.0f) * (character == punch ? 2.5f : 1.0f);
    wanted.release = std::clamp(mParameters[mstRelease], 20.0f, 1000.0f);
    wanted.valve = character == valve ? valveMix : 0;
    float width = isTransparent ? 0 : std::clamp(mParameters[mstWidth] / 100, 0.0f, 1.0f);
    wanted.widthDB = 20 * std::log10(1 + 0.5 * width);
    float lowEnd = mParameters[mstLowEndMono];
    wanted.mono = lowEnd >= lowEndMonoOff ? 1 : 0;
    wanted.monoFrequency = std::clamp(lowEnd, lowEndMonoOff, 200.0f);
    wanted.compare = mParameters[mstCompare] >= 0.5f ? 1 : 0;
    wanted.ceilingDB = std::clamp(mParameters[mstCeiling], -3.0f, 0.0f);
    return wanted;
  }

  BiquadCoefficients band(int b, double gain) const { return bandCoefficients(b, gain, mSampleRate); }

public:
  /// The EQ's bands: a low shelf, three bells and a high shelf.
  static BiquadCoefficients bandCoefficients(int b, double gain, double sampleRate) {
    switch (b) {
      case 0: return BiquadCoefficients::lowShelf(100, gain, 0.71, sampleRate);
      case 1: return BiquadCoefficients::bell(250, gain, 1.0, sampleRate);
      case 2: return BiquadCoefficients::bell(3000, gain, 0.9, sampleRate);
      case 3: return BiquadCoefficients::bell(std::min(7000.0, sampleRate * 0.45), gain, 0.9, sampleRate);
      default: return BiquadCoefficients::highShelf(std::min(10000.0, sampleRate * 0.45), gain, 0.71, sampleRate);
    }
  }

  /// What the EQ's five bands really boost or cut (dB): the song's settings scaled by EQ
  /// Amount (halved for Transparent), with the character's own touch.
  static std::array<double, 5> effectiveBands(int character, float eqAmount, float const *gains) {
    float amount = std::clamp(eqAmount / 100, 0.0f, 1.0f) * (character == transparent ? 0.5f : 1.0f);
    std::array<double, 5> bands {};
    for (int b = 0; b < 5; ++b) {
      double gain = std::clamp(gains[b], -6.0f, 6.0f) * amount;
      // Punch fills out the low end a touch; Valve rounds off the top.
      if (character == punch && b == 0) gain += 1;
      if (character == valve && b >= 3) gain -= 0.5;
      bands[size_t(b)] = gain;
    }
    return bands;
  }

  /// The EQ's response at each of `frequencies` (dB), for the window to draw.
  static void response(
    int character, float eqAmount, float const *gains, double sampleRate, float const *frequencies, float *decibels,
    int count) {
    auto bands = effectiveBands(character, eqAmount, gains);
    for (int i = 0; i < count; ++i) decibels[i] = 0;
    for (int b = 0; b < 5; ++b) {
      BiquadCoefficients coefficients = bandCoefficients(b, bands[size_t(b)], sampleRate);
      for (int i = 0; i < count; ++i) decibels[i] += float(coefficients.magnitudeDB(frequencies[i], sampleRate));
    }
  }

private:

  /// Moves every setting a step toward where it's heading, redesigning the filters that
  /// moved (so nothing zippers or clicks).
  void glide(Targets const &wanted) {
    for (int b = 0; b < bandCount; ++b) {
      if (approach(mBandGains[size_t(b)], wanted.bands[size_t(b)], 0.001)) mBands[size_t(b)] = band(b, mBandGains[size_t(b)]);
    }
    configureCompressor(wanted);
    // Off keeps the last frequency, so turning it back on fades in where it was.
    if (wanted.mono > 0) {
      double octaves = std::log2(wanted.monoFrequency / mMonoFrequency);
      if (octaves != 0) {
        mMonoFrequency = std::abs(octaves) < 0.001 ? wanted.monoFrequency : mMonoFrequency * std::exp2(octaves * mGlide);
        designLowEnd();
      }
    }
    if (approach(mWidthDB, wanted.widthDB, 0.001)) {
      mWidthShelf = BiquadCoefficients::highShelf(widthFrequency, mWidthDB, 0.71, mSampleRate);
    }
    approach(mCeilingDB, wanted.ceilingDB, 0.001);
  }

  /// The compressor follows its settings itself: its gain moves at its attack and release,
  /// so a changed threshold or ratio doesn't jump.
  void configureCompressor(Targets const &wanted) {
    mCompressor.setParameter(compThreshold, wanted.threshold);
    mCompressor.setParameter(compRatio, wanted.ratio);
    mCompressor.setParameter(compAttack, wanted.attack);
    mCompressor.setParameter(compRelease, wanted.release);
  }

  /// Low-End Mono's filters: a Linkwitz-Riley high-pass (two Butterworth sections) for the
  /// side, and for the mid the all-pass its high and low halves add up to, so the mid and
  /// side stay in phase.
  void designLowEnd() {
    mHighPass = BiquadCoefficients::highPass(mMonoFrequency, M_SQRT1_2, mSampleRate);
    mAllPass = BiquadCoefficients::allPass(mMonoFrequency, M_SQRT1_2, mSampleRate);
  }

  bool approach(double &value, double wanted, double snap) const {
    if (value == wanted) return false;
    value = std::abs(wanted - value) < snap ? wanted : value + (wanted - value) * mGlide;
    return true;
  }

  /// Moves `value` toward `target` by at most `step` a sample, writing where it is at each.
  static void ramp(float &value, float target, float step, float *out, int frames) {
    for (int i = 0; i < frames; ++i) {
      value += std::clamp(target - value, -step, step);
      out[i] = value;
    }
  }

  /// The character stage: the tube curve at four times the rate (so its harmonics don't
  /// alias), level-matched and blended with the clean sound. It always runs, and the clean
  /// sound always waits for it, so the latency is the same whatever the character.
  void character(std::array<float *, maximumChannels> const &work, int channels, int frames, float target) {
    std::array<float, chunk> blend;
    ramp(mValve, target, mFade, blend.data(), frames);
    int size = Oversampler::roundTripDelay;
    for (int c = 0; c < channels; ++c) {
      Channel &state = mChannels[size_t(c)];
      float *samples = work[size_t(c)];
      int position = mCharacterWrite;
      for (int i = 0; i < frames; ++i) {
        float points[Oversampler::factor];
        mCharacter.up(c, samples[i], points);
        for (float &point : points) point = Saturation::shape(point * valveDrive, tube) * mValveMatched;
        // The tube's asymmetry adds a little DC, which would eat headroom.
        float wet = state.dcBlock.process(mCharacter.down(c, points), mDCBlock);
        float clean = state.waiting[size_t(position)];
        state.waiting[size_t(position)] = samples[i];
        position = (position + 1) % size;
        samples[i] = clean + (wet - clean) * blend[size_t(i)];
      }
    }
    mCharacterWrite = (mCharacterWrite + frames) % size;
  }

  /// Width and Low-End Mono, on the mid (what's the same in both sides) and the side
  /// (what differs).
  void stereo(float *left, float *right, int frames, float target) {
    std::array<float, chunk> blend;
    ramp(mMono, target, mFade, blend.data(), frames);
    for (int i = 0; i < frames; ++i) {
      float mid = (left[i] + right[i]) / 2, side = (left[i] - right[i]) / 2;
      float high = mSideHigh2.process(mSideHigh.process(side, mHighPass), mHighPass);
      float phased = mMidPhase.process(mid, mAllPass);
      mid += (phased - mid) * blend[size_t(i)];
      side += (high - side) * blend[size_t(i)];
      side = mWidthState.process(side, mWidthShelf);
      left[i] = mid + side;
      right[i] = mid - side;
    }
  }

  /// Whether anything but Compare and Listen has changed since the last render.
  bool settingsChanged() {
    bool changed = false;
    for (size_t k = 0; k < mSeen.size(); ++k) {
      if (k == size_t(mstCompare - mstCharacter) || k == size_t(mstListen - mstCharacter) || mParameters.values[k] == mSeen[k]) {
        continue;
      }
      mSeen[k] = mParameters.values[k];
      changed = true;
    }
    return changed;
  }

  /// Starts learning what the chain does again (the last estimate holds meanwhile).
  void restartEstimate() {
    mLoudness->chainIn.reset();
    mLoudness->chainOut.reset();
    mLoudness->limited.reset();
    mEstimatedBlock = 0;
  }

  /// Every 100 ms, once there are two seconds of sound since the settings last changed:
  /// what the chain does to the loudness (integrated, so the whole stretch counts and the
  /// make-up doesn't ride the song), and what the limiter takes off at this make-up.
  void estimate() {
    Loudness &loudness = *mLoudness;
    if (loudness.chainOut.blocks() == mEstimatedBlock) return;
    mEstimatedBlock = loudness.chainOut.blocks();
    uint64_t enough = 20;
    if (loudness.chainIn.gatedBlocks() < enough || loudness.chainOut.gatedBlocks() < enough
        || loudness.limited.gatedBlocks() < enough) {
      return;
    }
    mChainChange = loudness.chainOut.integrated - loudness.chainIn.integrated;
    // Capped, so a song pushed far into the limiter isn't pushed further still.
    mLimiterLoss = std::clamp(loudness.limited.integrated - loudness.chainOut.integrated, -2.0f, 0.0f);
  }

  /// The gain that brings the measured song, as the chain leaves it, to the loudness asked
  /// for (none until the song has been measured).
  float makeUpTarget() const {
    float measured = mParameters[mstMeasuredLoudness];
    if (measured <= notMeasured + 0.05f) return 0;
    float loudness = std::clamp(mParameters[mstLoudness], -16.0f, -8.0f);
    return std::clamp(loudness - (measured + mChainChange + mLimiterLoss), 0.0f, 24.0f);
  }

  ParameterBank<mstCharacter, mstListen> mParameters;
  std::array<float, mstListen - mstCharacter + 1> mSeen {};
  double mSampleRate = 44100, mGlide = 0.05;
  int mChannelCount = 0;
  float mFade = 0.001f, mMakeUpGlide = 0.001f, mCompareGlide = 0.001f;

  std::array<Channel, maximumChannels> mChannels;
  std::array<double, bandCount> mBandGains {};
  std::array<BiquadCoefficients, bandCount> mBands;
  Compressor mCompressor;

  Oversampler mCharacter;
  BiquadCoefficients mDCBlock;
  int mCharacterWrite = 0;
  float mValve = 0, mValveMatched = 1;

  BiquadState mSideHigh, mSideHigh2, mMidPhase, mWidthState;
  BiquadCoefficients mHighPass, mAllPass, mWidthShelf;
  double mMonoFrequency = 120, mWidthDB = 0;
  float mMono = 0;

  TruePeakLimiter mLimiter;
  double mCeilingDB = -1;
  float mMakeUpDB = 0, mChainChange = 0, mLimiterLoss = 0;
  uint64_t mEstimatedBlock = 0;
  std::unique_ptr<Loudness> mLoudness;

  std::array<std::vector<float>, maximumChannels> mCompareDelay;
  int mCompareSize = 1, mCompareWrite = 0;
  float mCompareDB = 0, mCompareTarget = 0, mCompareBlend = 0;
  Oversampler mOutputPeaks;

  std::array<std::array<float, chunk>, maximumChannels> mWork {}, mDry {};

  std::vector<MasteringListenBlock> mListened;
  int mListenedCount = 0;
  bool mListening = false, mListenRestart = false;
  std::array<BiquadCoefficients, listenBandCount> mListenBands;
  std::array<BiquadState, listenBandCount> mListenBandStates;
  std::array<bool, listenBandCount> mListenBandValid {};
  ListenSums mListenSums;
  uint64_t mListenStep = 0;
  Oversampler mInputPeaks;
  std::array<std::array<float, chunk>, 2> mScratch {};
};

}  // namespace ongaku
