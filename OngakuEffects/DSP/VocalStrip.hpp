//
//  VocalStrip.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <span>
#include <vector>

#include "Biquad.hpp"
#include "Compressor.hpp"
#include "Dynamics.hpp"
#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

/// A vocal chain on one knob each, like a channel strip set up for singing: a low cut for
/// rumble and pops, a de-esser, a compressor to even the level, then body, presence and
/// air EQ, and the output.
class VocalStrip {
public:
  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::min(channelCount, maximumChannels);
    for (auto &channel : mChannels) channel = Channel();
    mDeEsser.initialize(channelCount, sampleRate);
    mCompressor.initialize(channelCount, sampleRate);
    for (auto &buffer : mBuffers) buffer.assign(4096, 0);
  }

  PeakMeters meters;
  /// What the compressor and de-esser are taking away (dB).
  float lastCompression = 0, lastDeEssing = 0;

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    configure();
    // In pieces that fit the working buffers.
    for (int start = 0; start < frameCount; start += 4096) {
      int frames = std::min(4096, frameCount - start);
      std::array<float const *, maximumChannels> in {};
      std::array<float *, maximumChannels> work {};
      for (int c = 0; c < channels; ++c) {
        in[size_t(c)] = inputs[c] + start;
        work[size_t(c)] = mBuffers[size_t(c)].data();
        for (int i = 0; i < frames; ++i) work[size_t(c)][i] = mChannels[c].lowCut.process(in[size_t(c)][i], mLowCut);
      }
      std::span<float const *> workIn(const_cast<float const **>(work.data()), size_t(channels));
      std::span<float *> workOut(work.data(), size_t(channels));
      mDeEsser.process(workIn, workOut, frames);
      mCompressor.process(workIn, workOut, frames);
      float output = linear(mParameters[voxOutput]);
      for (int c = 0; c < channels; ++c) {
        Channel &state = mChannels[c];
        float *out = outputs[c] + start;
        for (int i = 0; i < frames; ++i) {
          float sample = state.body.process(work[size_t(c)][i], mBody);
          sample = state.presence.process(sample, mPresence);
          out[i] = state.air.process(sample, mAir) * output;
        }
        for (BiquadState *filter : {&state.lowCut, &state.body, &state.presence, &state.air}) filter->flushDenormals();
      }
    }
    lastCompression = mCompressor.lastReduction;
    lastDeEssing = mDeEsser.lastReduction;
    meters.measure(inputs, outputs, channels, frameCount);
  }

private:
  struct Channel {
    BiquadState lowCut, body, presence, air;
  };

  /// The knobs, turned into settings for the stages.
  void configure() {
    mLowCut = BiquadCoefficients::highPass(std::clamp(mParameters[voxLowCut], 20.0f, 400.0f), 0.707, mSampleRate);
    mBody = BiquadCoefficients::lowShelf(220, std::clamp(mParameters[voxBody], -100.0f, 100.0f) / 100 * 6, 0.7, mSampleRate);
    mPresence = BiquadCoefficients::bell(4500, std::clamp(mParameters[voxPresence], -100.0f, 100.0f) / 100 * 8, 0.9, mSampleRate);
    mAir = BiquadCoefficients::highShelf(
      std::min(12000.0, mSampleRate * 0.4), std::clamp(mParameters[voxAir], -100.0f, 100.0f) / 100 * 8, 0.7, mSampleRate);

    float deEss = std::clamp(mParameters[voxDeEss] / 100, 0.0f, 1.0f);
    mDeEsser.setParameter(desFrequency, 6500);
    mDeEsser.setParameter(desThreshold, -18 - deEss * 22);
    mDeEsser.setParameter(desRange, deEss * 12);
    mDeEsser.setParameter(desListen, 0);

    float compress = std::clamp(mParameters[voxCompress] / 100, 0.0f, 1.0f);
    mCompressor.setParameter(compThreshold, -6 - compress * 26);
    mCompressor.setParameter(compRatio, 1.5f + compress * 3);
    mCompressor.setParameter(compAttack, 8);
    mCompressor.setParameter(compRelease, 120);
    mCompressor.setParameter(compKnee, 8);
    mCompressor.setParameter(compMakeUp, 0);
    mCompressor.setParameter(compAutoGain, compress > 0 ? 1 : 0);
    mCompressor.setParameter(compMix, compress > 0 ? 100 : 0);
    mCompressor.setParameter(compDetection, 1);
  }

  ParameterBank<voxLowCut, voxOutput> mParameters;
  double mSampleRate = 44100;
  int mChannelCount = 0;
  std::array<Channel, maximumChannels> mChannels;
  BiquadCoefficients mLowCut, mBody, mPresence, mAir;
  DeEsser mDeEsser;
  Compressor mCompressor;
  std::array<std::vector<float>, maximumChannels> mBuffers;
};

}  // namespace ongaku
