//
//  ConvolutionReverb.hpp
//  OngakuEffects
//

#pragma once

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <span>
#include <vector>

#include "Biquad.hpp"
#include "DelayLine.hpp"
#include "Dynamics.hpp"
#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

/// An impulse response, ready to convolve: stereo, cut into blocks, each block's spectrum
/// (as vDSP's packed real FFT) scaled so the convolution comes out at unity.
struct ConvolutionImpulse {
  static constexpr int blockSize = 256;
  static constexpr int fftSize = 2 * blockSize;
  static constexpr int log2FFTSize = 9;
  /// Impulse responses are kept to eight seconds.
  static constexpr double maximumSeconds = 8;

  int partitions = 0;
  double sampleRate = 44100;
  /// Its length in seconds.
  double seconds = 0;
  std::array<std::vector<float>, 2> real, imag;

  /// Cuts stereo audio (at the impulse's rate) into blocks and takes their spectra.
  static ConvolutionImpulse *make(std::array<std::vector<float>, 2> const &audio, double sampleRate) {
    auto *impulse = new ConvolutionImpulse();
    impulse->sampleRate = sampleRate;
    size_t length = std::min(audio[0].size(), size_t(maximumSeconds * sampleRate));
    impulse->seconds = double(length) / sampleRate;
    impulse->partitions = std::max(1, int((length + blockSize - 1) / blockSize));
    FFTSetup setup = vDSP_create_fftsetup(log2FFTSize, kFFTRadix2);
    std::vector<float> block(fftSize);
    // vDSP's forward real FFT is twice the DFT; two of them multiplied, then the inverse
    // (N times), make 4N.
    float scale = 1.0f / float(4 * fftSize);
    for (int c = 0; c < 2; ++c) {
      impulse->real[c].assign(size_t(impulse->partitions * blockSize), 0);
      impulse->imag[c].assign(size_t(impulse->partitions * blockSize), 0);
      auto const &source = audio[size_t(std::min<size_t>(c, audio.size() - 1))];
      for (int p = 0; p < impulse->partitions; ++p) {
        std::fill(block.begin(), block.end(), 0.0f);
        for (int i = 0; i < blockSize; ++i) {
          size_t index = size_t(p * blockSize + i);
          if (index < length && index < source.size()) block[size_t(i)] = source[index] * scale;
        }
        DSPSplitComplex split {impulse->real[c].data() + p * blockSize, impulse->imag[c].data() + p * blockSize};
        vDSP_ctoz(reinterpret_cast<DSPComplex const *>(block.data()), 2, &split, 1, blockSize);
        vDSP_fft_zrip(setup, &split, 1, log2FFTSize, kFFTDirection_Forward);
      }
    }
    vDSP_destroy_fftsetup(setup);
    return impulse;
  }

  /// A room's impulse response, synthesized as Space Designer does: early reflections
  /// spread by the size, then a dense, decorrelated tail building up and dying away over
  /// the decay time, losing its highs faster as the damping rises.
  static ConvolutionImpulse *synthesize(double sampleRate, float decay, float size, float damping) {
    decay = std::clamp(decay, 0.1f, 7.0f);
    float sizeAmount = std::clamp(size / 100, 0.0f, 1.0f);
    float dampingAmount = std::clamp(damping / 100, 0.0f, 1.0f);
    size_t length = size_t(std::min(maximumSeconds, double(decay) * 1.15 + 0.05) * sampleRate);
    std::array<std::vector<float>, 2> audio;
    for (int c = 0; c < 2; ++c) {
      auto &ir = audio[size_t(c)];
      ir.assign(length, 0);
      uint32_t noise = c == 0 ? 0x2545F491u : 0x9E3779B9u;
      auto random = [&noise]() {
        noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5;
        return float(noise) / float(UINT32_MAX) * 2 - 1;
      };
      // The tail.
      float buildUp = (0.004f + sizeAmount * 0.05f) * float(sampleRate);
      float lowPass = 0, coefficient = 0;
      for (size_t i = 0; i < length; ++i) {
        float t = float(i) / float(sampleRate);
        if (i % 64 == 0) {
          float cutoff = std::max(600.0f, 17000.0f * std::exp2(-t / decay * dampingAmount * 7));
          coefficient = std::exp(-2 * float(M_PI) * std::min(cutoff, float(sampleRate) * 0.45f) / float(sampleRate));
        }
        lowPass = (1 - coefficient) * random() + coefficient * lowPass;
        float envelope = std::exp(-6.9078f * t / decay) * std::min(1.0f, float(i) / buildUp);
        // The low-pass takes level away as it closes; give some back so the tail stays even.
        ir[i] = lowPass * envelope * (1 + dampingAmount * 2.5f * std::min(1.0f, t / decay));
      }
      // Early reflections, sparse and distinct, spread over up to 70 ms.
      int count = 6 + int(sizeAmount * 10);
      for (int k = 0; k < count; ++k) {
        float time = 0.002f + (0.005f + sizeAmount * 0.065f) * (float(k) + 0.5f * (random() + 1)) / float(count);
        size_t index = std::min(length - 1, size_t(time * float(sampleRate)));
        ir[index] += random() * 0.9f * std::exp(-float(k) / float(count) * 1.5f);
      }
    }
    // Unit energy per channel, so wet noise is as loud as dry noise.
    for (auto &ir : audio) {
      double energy = 0;
      for (float sample : ir) energy += double(sample) * sample;
      float gain = energy > 0 ? float(1 / std::sqrt(energy)) : 0;
      for (float &sample : ir) sample *= gain;
    }
    return make(audio, sampleRate);
  }
};

/// Convolution reverb in the style of Logic's Space Designer: the input played through an
/// impulse response by uniformly partitioned FFT convolution (overlap-save, 256-sample
/// blocks, reported as latency), with predelay, width, low and high cuts on the reverb,
/// and the mix.
class ConvolutionReverb {
public:
  static constexpr int blockSize = ConvolutionImpulse::blockSize;
  static constexpr int fftSize = ConvolutionImpulse::fftSize;

  ConvolutionReverb() = default;
  ConvolutionReverb(ConvolutionReverb const &other) : mParameters(other.mParameters) {}
  ConvolutionReverb &operator=(ConvolutionReverb const &other) {
    mParameters = other.mParameters;
    return *this;
  }
  ~ConvolutionReverb() {
    if (mSetup) vDSP_destroy_fftsetup(mSetup);
  }

  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  /// Replaces the impulse response. From any thread; the render thread takes it up at its
  /// next buffer (the input it has heard is kept, so the reverb carries on).
  void setImpulse(ConvolutionImpulse const *impulse) { __atomic_store_n(&mPending, impulse, __ATOMIC_RELEASE); }

  double tailSeconds() const {
    ConvolutionImpulse const *impulse = __atomic_load_n(&mPending, __ATOMIC_ACQUIRE);
    return (impulse ? impulse->seconds : 0) + mParameters[cnvPredelay] / 1000;
  }

  void initialize(int channelCount, double sampleRate) {
    mSampleRate = sampleRate;
    mChannelCount = std::min(channelCount, maximumChannels);
    if (!mSetup) mSetup = vDSP_create_fftsetup(ConvolutionImpulse::log2FFTSize, kFFTRadix2);
    mRing = int(std::ceil(ConvolutionImpulse::maximumSeconds * sampleRate / blockSize)) + 1;
    mInputReal.assign(size_t(mRing * blockSize), 0);
    mInputImag.assign(size_t(mRing * blockSize), 0);
    mInputWindow.assign(fftSize, 0);
    mTime.assign(fftSize, 0);
    for (int c = 0; c < 2; ++c) {
      mSumReal[c].assign(blockSize, 0);
      mSumImag[c].assign(blockSize, 0);
      mWet[c].assign(blockSize, 0);
    }
    mNewest = 0;
    mFill = 0;
    mPredelay.allocate(int(0.3 * sampleRate) + 4);
    mPredelay.clear();
    for (auto &line : mDry) {
      line.allocate(blockSize + 8);
      line.clear();
    }
    for (auto &state : mLowCut) state.reset();
    for (auto &state : mHighCut) state.reset();
  }

  PeakMeters meters;

  void process(std::span<float const *> inputs, std::span<float *> outputs, int frameCount) {
    int channels = int(std::min({inputs.size(), outputs.size(), size_t(mChannelCount)}));
    if (channels == 0) return;
    mImpulse = __atomic_load_n(&mPending, __ATOMIC_ACQUIRE);
    float predelay = std::clamp(mParameters[cnvPredelay], 0.0f, 250.0f) * 0.001f * float(mSampleRate);
    float width = std::clamp(mParameters[cnvWidth] / 100, 0.0f, 1.0f);
    float mix = std::clamp(mParameters[cnvMix] / 100, 0.0f, 1.0f);
    BiquadCoefficients lowCut = BiquadCoefficients::highPass(std::max(20.0f, mParameters[cnvLowCut]), 0.707, mSampleRate);
    BiquadCoefficients highCut = BiquadCoefficients::lowPass(
      std::min(double(mParameters[cnvHighCut]), mSampleRate * 0.45), 0.707, mSampleRate);
    // An equal-power crossfade, so the middle of the mix isn't a dip.
    float dryGain = std::cos(mix * float(M_PI) / 2), wetGain = std::sin(mix * float(M_PI) / 2);

    for (int i = 0; i < frameCount; ++i) {
      float mono = 0;
      for (int c = 0; c < channels; ++c) mono += inputs[c][i];
      mono /= float(channels);
      mPredelay.write(mono);
      mInputWindow[size_t(blockSize + mFill)] = predelay > 0 ? mPredelay.read(predelay) : mono;

      // The block computed last time, as this one fills (the latency is one block).
      float left = mWet[0][size_t(mFill)], right = mWet[1][size_t(mFill)];
      float mid = (left + right) / 2, side = (left - right) / 2 * width;
      std::array<float, 2> wet {mid + side, mid - side};
      for (int c = 0; c < channels; ++c) {
        mDry[c].write(inputs[c][i]);
        // The dry sound waits the same block (read(1) is the sample just written).
        float dry = mDry[c].read(blockSize + 1);
        float reverb = wet[size_t(std::min(c, 1))];
        reverb = mHighCut[c].process(mLowCut[c].process(reverb, lowCut), highCut);
        outputs[c][i] = dry * dryGain + reverb * wetGain;
      }
      if (++mFill == blockSize) {
        convolveBlock();
        mFill = 0;
      }
    }
    for (auto &state : mLowCut) state.flushDenormals();
    for (auto &state : mHighCut) state.flushDenormals();
    meters.measure(inputs, outputs, channels, frameCount);
  }

private:
  /// One block of overlap-save: the spectrum of the last two blocks of input joins the
  /// history, every partition of the impulse is multiplied with the input from as many
  /// blocks ago, and the sum's second half is the reverb for the next block.
  void convolveBlock() {
    mNewest = (mNewest + 1) % mRing;
    DSPSplitComplex input {mInputReal.data() + mNewest * blockSize, mInputImag.data() + mNewest * blockSize};
    vDSP_ctoz(reinterpret_cast<DSPComplex const *>(mInputWindow.data()), 2, &input, 1, blockSize);
    vDSP_fft_zrip(mSetup, &input, 1, ConvolutionImpulse::log2FFTSize, kFFTDirection_Forward);
    // The window slides: this block becomes the first half of the next one.
    std::copy(mInputWindow.begin() + blockSize, mInputWindow.end(), mInputWindow.begin());

    ConvolutionImpulse const *impulse = mImpulse;
    int partitions = impulse ? std::min(impulse->partitions, mRing) : 0;
    for (int c = 0; c < 2; ++c) {
      std::fill(mSumReal[c].begin(), mSumReal[c].end(), 0.0f);
      std::fill(mSumImag[c].begin(), mSumImag[c].end(), 0.0f);
      DSPSplitComplex sum {mSumReal[c].data(), mSumImag[c].data()};
      for (int p = 0; p < partitions; ++p) {
        int slot = (mNewest - p + mRing) % mRing;
        float const *xr = mInputReal.data() + slot * blockSize, *xi = mInputImag.data() + slot * blockSize;
        float const *hr = impulse->real[c].data() + p * blockSize, *hi = impulse->imag[c].data() + p * blockSize;
        // Bin 0 packs the DC and Nyquist bins, both real: multiply them on their own.
        float dc = sum.realp[0] + xr[0] * hr[0], nyquist = sum.imagp[0] + xi[0] * hi[0];
        DSPSplitComplex x {const_cast<float *>(xr) + 1, const_cast<float *>(xi) + 1};
        DSPSplitComplex h {const_cast<float *>(hr) + 1, const_cast<float *>(hi) + 1};
        DSPSplitComplex rest {sum.realp + 1, sum.imagp + 1};
        vDSP_zvma(&x, 1, &h, 1, &rest, 1, &rest, 1, blockSize - 1);
        sum.realp[0] = dc;
        sum.imagp[0] = nyquist;
      }
      vDSP_fft_zrip(mSetup, &sum, 1, ConvolutionImpulse::log2FFTSize, kFFTDirection_Inverse);
      vDSP_ztoc(&sum, 1, reinterpret_cast<DSPComplex *>(mTime.data()), 2, blockSize);
      std::copy(mTime.begin() + blockSize, mTime.end(), mWet[c].begin());
    }
  }

  ParameterBank<cnvPredelay, cnvMix> mParameters;
  double mSampleRate = 44100;
  int mChannelCount = 0;
  FFTSetup mSetup = nullptr;
  ConvolutionImpulse const *mPending = nullptr;
  ConvolutionImpulse const *mImpulse = nullptr;
  /// The input's spectra, newest at `mNewest`, for as many blocks as the longest impulse.
  std::vector<float> mInputReal, mInputImag;
  int mRing = 1, mNewest = 0, mFill = 0;
  std::vector<float> mInputWindow, mTime;
  std::array<std::vector<float>, 2> mSumReal, mSumImag, mWet;
  DelayLine mPredelay;
  std::array<DelayLine, maximumChannels> mDry;
  std::array<BiquadState, maximumChannels> mLowCut, mHighCut;
};

/// Builds and frees impulse responses (called from Swift, off the render thread).
inline ConvolutionImpulse *OngakuSynthesizeImpulse(double sampleRate, float decay, float size, float damping) {
  return ConvolutionImpulse::synthesize(sampleRate, decay, size, damping);
}

/// An impulse response from audio (one or two channels at `sourceRate`), resampled to
/// `sampleRate` and given unit energy.
inline ConvolutionImpulse *OngakuMakeImpulse(
  float const *left, float const *right, int64_t frames, double sourceRate, double sampleRate) {
  double ratio = sourceRate / sampleRate;
  size_t length = size_t(std::min(double(frames) / ratio, ConvolutionImpulse::maximumSeconds * sampleRate));
  std::array<std::vector<float>, 2> audio;
  for (int c = 0; c < 2; ++c) {
    float const *source = c == 1 && right ? right : left;
    audio[size_t(c)].resize(length);
    for (size_t i = 0; i < length; ++i) {
      double position = double(i) * ratio;
      int64_t whole = int64_t(position);
      float fraction = float(position - double(whole));
      float a = source[std::min(whole, frames - 1)], b = source[std::min(whole + 1, frames - 1)];
      audio[size_t(c)][i] = a + (b - a) * fraction;
    }
  }
  double energy = 0;
  for (auto &channel : audio) for (float sample : channel) energy += double(sample) * sample;
  float gain = energy > 0 ? float(std::sqrt(2 / energy)) : 0;
  for (auto &channel : audio) for (float &sample : channel) sample *= gain;
  return ConvolutionImpulse::make(audio, sampleRate);
}

inline void OngakuFreeImpulse(ConvolutionImpulse *impulse) { delete impulse; }

}  // namespace ongaku
