//
//  Keys.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <span>

#include "DelayLine.hpp"
#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

/// A sine from a table (a cycle of 4,096 points, read with linear interpolation), for
/// instruments that run many oscillators at once.
struct SineTable {
  static constexpr int size = 4096;
  std::array<float, size + 1> values {};

  SineTable() {
    for (int i = 0; i <= size; ++i) values[size_t(i)] = float(std::sin(2 * M_PI * double(i) / size));
  }

  /// The sine at `phase` cycles (any value; only the fraction counts).
  float operator()(double phase) const {
    double wrapped = phase - std::floor(phase);
    double position = wrapped * size;
    int index = int(position);
    float fraction = float(position - index);
    return values[size_t(index)] + (values[size_t(index + 1)] - values[size_t(index)]) * fraction;
  }
};

inline SineTable const &sineTable() {
  static SineTable const table;
  return table;
}

inline double noteFrequency(double note) { return 440.0 * std::exp2((note - 69) / 12); }

/// The parameters of an instrument, as a flat bank from its first address to its last.
template <AUParameterAddress first, AUParameterAddress last>
struct KeysParameters {
  std::array<float, last - first + 1> values {};
  void set(AUParameterAddress address, float value) {
    if (address >= first && address <= last) values[address - first] = value;
  }
  float get(AUParameterAddress address) const { return address >= first && address <= last ? values[address - first] : 0; }
  float operator[](AUParameterAddress address) const { return values[address - first]; }
};

// MARK: - Electric Piano

/// An electric piano in the manner of a Rhodes, made by FM (as the DX7's famous electric
/// piano was): each note a sine whose phase is pushed by a second at the same pitch (the
/// tine's body, brighter the harder it's struck and mellowing as it rings) and, for a
/// moment at the start, by one far above (the bell's ping). Notes fade away while held,
/// the high ones sooner, and stop softly on release unless the sustain pedal is down.
class ElectricPiano {
public:
  static constexpr int voiceCount = 16;

  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  void initialize(double sampleRate) {
    // Made here, not on the audio thread.
    (void)sineTable();
    mSampleRate = sampleRate;
    for (auto &voice : mVoices) voice = Voice();
    mSustain = false;
    mTremoloPhase = 0;
  }

  int activeVoices() const {
    return int(std::count_if(mVoices.begin(), mVoices.end(), [](Voice const &voice) { return voice.level > 0 || voice.attack < 1; }));
  }

  void midi(uint8_t status, uint8_t data1, uint8_t data2) {
    switch (status & 0xF0) {
      case 0x90:
        if (data2 > 0) { noteOn(data1, data2); } else { noteOff(data1); }
        break;
      case 0x80: noteOff(data1); break;
      case 0xB0:
        if (data1 == 64) setSustain(data2 >= 64);
        if (data1 == 120 || data1 == 123) {
          for (auto &voice : mVoices) {
            voice.isHeld = false;
            if (data1 == 120) voice = Voice();
          }
          mSustain = false;
        }
        break;
      case 0xE0: mBend = (float((data2 << 7) | data1) - 8192) / 8192 * 2; break;
      default: break;
    }
  }

  void process(std::span<float *> outputs, int frameCount) {
    if (outputs.empty()) return;
    float *left = outputs[0];
    float *right = outputs.size() > 1 ? outputs[1] : nullptr;
    std::fill_n(left, frameCount, 0.0f);
    if (right) std::fill_n(right, frameCount, 0.0f);

    SineTable const &sine = sineTable();
    float tone = std::clamp(mParameters[epTone] / 100, 0.0f, 1.0f);
    float bell = std::clamp(mParameters[epBell] / 100, 0.0f, 1.0f);
    float decayScale = std::clamp(mParameters[epDecay] / 100, 0.25f, 4.0f);
    float sensitivity = std::clamp(mParameters[epVelocity] / 100, 0.0f, 1.0f);
    double rate = mSampleRate;
    float bend = std::exp2(mBend / 12);

    for (auto &voice : mVoices) {
      if (voice.level <= 0 && voice.attack >= 1) continue;
      double frequency = noteFrequency(voice.note) * bend;
      double step = frequency / rate;
      // While held a note falls 40 dB in about 10 s low down, 5 s at middle C and under 2 s
      // at the top (at 100 %), the high ones dying sooner as real tines do.
      float holdSeconds = decayScale * float(10 * std::exp2(-(voice.note - 36) / 24.0));
      float held = std::exp(-4.6f / (std::max(0.05f, holdSeconds) * float(rate)));
      // The damper: 60 dB in about 0.4 s, a little longer for the low notes.
      float damperSeconds = 0.2f + 0.3f * float(std::exp2(-(voice.note - 48) / 24.0));
      float damped = std::exp(-6.9f / (damperSeconds * float(rate)));
      float brightnessFall = std::exp(-1 / (0.35f * float(rate)));
      float bellFall = std::exp(-1 / (0.06f * float(rate)));
      float velocity = voice.velocity;
      float loudness = (1 - sensitivity) * 0.6f + sensitivity * std::pow(velocity, 1.4f);
      float index = tone * (0.25f + (0.4f + 1.4f * sensitivity * velocity));
      for (int i = 0; i < frameCount; ++i) {
        if (voice.attack < 1) voice.attack = std::min(1.0f, voice.attack + float(1 / (0.0015 * rate)));
        float envelope = voice.level * voice.attack;
        float modulation = index * (0.35f + 0.65f * voice.brightness) * sine(voice.modulator)
          + bell * 2.2f * velocity * velocity * voice.bellLevel * sine(voice.bellPhase);
        float sample = sine(voice.carrier + modulation / (2 * M_PI)) * envelope * loudness;
        left[i] += sample;
        voice.carrier += step;
        voice.modulator += step;
        voice.bellPhase += step * 14.0;
        voice.brightness *= brightnessFall;
        voice.bellLevel *= bellFall;
        voice.level *= (voice.isHeld || voice.isSustained) ? held : damped;
        if (voice.level < 1e-4f) {
          voice.level = 0;
          voice.attack = 1;
          break;
        }
      }
      voice.carrier -= std::floor(voice.carrier);
      voice.modulator -= std::floor(voice.modulator);
      voice.bellPhase -= std::floor(voice.bellPhase);
    }

    // The tone stage: a little drive, the tremolo panning between the sides, the volume.
    float drive = std::clamp(mParameters[epDrive] / 100, 0.0f, 1.0f) * 4;
    float tremoloRate = std::clamp(mParameters[epTremoloRate], 0.5f, 12.0f);
    float tremoloDepth = std::clamp(mParameters[epTremoloDepth] / 100, 0.0f, 1.0f);
    float volume = std::pow(10.0f, std::clamp(mParameters[epVolume], -24.0f, 12.0f) / 20) * 0.35f;
    for (int i = 0; i < frameCount; ++i) {
      float x = left[i];
      if (drive > 0) x = std::tanh(x * (1 + drive)) / std::tanh(1 + drive) * 0.9f;
      float wobble = float(std::sin(2 * M_PI * mTremoloPhase));
      mTremoloPhase += tremoloRate / rate;
      if (mTremoloPhase >= 1) mTremoloPhase -= 1;
      left[i] = x * volume * (1 - tremoloDepth * (0.5f + 0.5f * wobble));
      if (right) right[i] = x * volume * (1 - tremoloDepth * (0.5f - 0.5f * wobble));
    }
    for (size_t c = 2; c < outputs.size(); ++c) std::copy_n(left, frameCount, outputs[c]);
  }

private:
  struct Voice {
    int note = 60;
    float velocity = 0;
    double carrier = 0, modulator = 0, bellPhase = 0;
    float level = 0, attack = 1, brightness = 1, bellLevel = 1;
    bool isHeld = false, isSustained = false;
    uint64_t age = 0;
  };

  void noteOn(int note, int velocity) {
    Voice *chosen = nullptr;
    for (auto &voice : mVoices) if (voice.note == note && voice.level > 0) chosen = &voice;
    if (!chosen) for (auto &voice : mVoices) if (voice.level <= 0) { chosen = &voice; break; }
    if (!chosen) {
      chosen = &*std::min_element(mVoices.begin(), mVoices.end(), [](Voice const &a, Voice const &b) { return a.level < b.level; });
    }
    Voice &voice = *chosen;
    bool restrike = voice.level > 0 && voice.note == note;
    voice.note = note;
    voice.velocity = velocity / 127.0f;
    voice.level = 1;
    voice.attack = restrike ? 1 : 0;
    if (!restrike) voice.carrier = voice.modulator = voice.bellPhase = 0;
    voice.brightness = 1;
    voice.bellLevel = 1;
    voice.isHeld = true;
    voice.isSustained = false;
    voice.age = ++mClock;
  }

  void noteOff(int note) {
    for (auto &voice : mVoices) {
      if (voice.note != note || !voice.isHeld) continue;
      voice.isHeld = false;
      voice.isSustained = mSustain;
    }
  }

  void setSustain(bool down) {
    mSustain = down;
    if (!down) for (auto &voice : mVoices) voice.isSustained = false;
  }

  KeysParameters<epTone, epVolume> mParameters;
  std::array<Voice, voiceCount> mVoices;
  double mSampleRate = 44100;
  double mTremoloPhase = 0;
  float mBend = 0;
  bool mSustain = false;
  uint64_t mClock = 0;
};

// MARK: - Organ

/// A tonewheel organ in the manner of a Hammond B3: each key nine sines (one per drawbar,
/// at its footage's harmonic, the highest folding back down an octave as the tonewheels
/// do), a click as the key's contacts close, single-triggered percussion, the scanner's
/// vibrato or chorus, a little overdrive and a rotary speaker whose horn and drum speed up
/// and slow down at their own pace. The mod wheel past half switches the rotary to fast.
class Organ {
public:
  static constexpr int voiceCount = 32;
  static constexpr std::array<double, 9> harmonics {0.5, 1.5, 1, 2, 3, 4, 5, 6, 8};

  void setParameter(AUParameterAddress address, float value) { mParameters.set(address, value); }
  float parameter(AUParameterAddress address) const { return mParameters.get(address); }

  void initialize(double sampleRate) {
    (void)sineTable();
    mSampleRate = sampleRate;
    for (auto &voice : mVoices) voice = Voice();
    mScanner.allocate(int(0.01 * sampleRate));
    mScanner.clear();
    mHorn.allocate(int(0.01 * sampleRate));
    mHorn.clear();
    mPercussion = 0;
    mHeldKeys = 0;
    mHornRate = mDrumRate = targetRates().first;
    mLow1 = mLow2 = 0;
  }

  int activeVoices() const {
    return int(std::count_if(mVoices.begin(), mVoices.end(), [](Voice const &voice) { return voice.gate > 0 || voice.isHeld; }));
  }

  /// How fast the horn is turning now (hertz), for the window.
  float hornRate() const { return float(mHornRate); }

  void midi(uint8_t status, uint8_t data1, uint8_t data2) {
    switch (status & 0xF0) {
      case 0x90:
        if (data2 > 0) { noteOn(data1); } else { noteOff(data1); }
        break;
      case 0x80: noteOff(data1); break;
      case 0xB0:
        if (data1 == 1) mWheelFast = data2 >= 64;
        if (data1 == 120 || data1 == 123) {
          for (auto &voice : mVoices) voice.isHeld = false;
          mHeldKeys = 0;
        }
        break;
      default: break;
    }
  }

  void process(std::span<float *> outputs, int frameCount) {
    if (outputs.empty()) return;
    float *left = outputs[0];
    float *right = outputs.size() > 1 ? outputs[1] : nullptr;
    double rate = mSampleRate;
    SineTable const &sine = sineTable();

    // Each drawbar about 3 dB a step, nothing at 0.
    std::array<float, 9> levels {};
    float total = 0;
    for (int bar = 0; bar < 9; ++bar) {
      float setting = std::clamp(mParameters[AUParameterAddress(orgFirstDrawbar + bar)], 0.0f, 8.0f);
      levels[size_t(bar)] = setting <= 0 ? 0 : std::pow(10.0f, (setting - 8) * 3 / 20);
      total += levels[size_t(bar)];
    }
    // Full drawbars are loud: keep a chord in range without changing the balance.
    float scale = 0.18f / std::max(1.0f, std::sqrt(total));
    bool percussionOn = mParameters[orgPercussion] >= 0.5f;
    double percussionHarmonic = mParameters[orgPercussionHarmonic] >= 0.5f ? 3 : 2;
    float percussionFall = std::exp(-1 / ((mParameters[orgPercussionDecay] >= 0.5f ? 1.0f : 0.25f) * float(rate)));
    float click = std::clamp(mParameters[orgClick] / 100, 0.0f, 1.0f);
    float gateStep = float(1 / (0.004 * rate));

    for (int i = 0; i < frameCount; ++i) {
      float sum = 0;
      for (auto &voice : mVoices) {
        if (voice.gate <= 0 && !voice.isHeld) continue;
        voice.gate = std::clamp(voice.gate + (voice.isHeld ? gateStep : -gateStep), 0.0f, 1.0f);
        float sample = 0;
        for (int bar = 0; bar < 9; ++bar) {
          if (levels[size_t(bar)] > 0) sample += sine(voice.phases[size_t(bar)]) * levels[size_t(bar)];
          voice.phases[size_t(bar)] += voice.steps[size_t(bar)];
          if (voice.phases[size_t(bar)] >= 1) voice.phases[size_t(bar)] -= 1;
        }
        if (percussionOn && voice.hasPercussion) {
          sample += sine(voice.percussionPhase) * mPercussion * 1.2f;
          voice.percussionPhase += voice.baseStep * percussionHarmonic;
          if (voice.percussionPhase >= 1) voice.percussionPhase -= 1;
        }
        // The key click: a short burst of bright noise as the contacts close.
        if (voice.clickLeft > 0) {
          voice.clickState = voice.clickState * 1664525u + 1013904223u;
          float noise = float(voice.clickState >> 9) / float(1 << 23) * 2 - 1;
          sample += noise * click * 0.5f * float(voice.clickLeft) / float(voice.clickLength);
          --voice.clickLeft;
        }
        sum += sample * voice.gate;
      }
      mPercussion *= percussionFall;
      left[i] = sum * scale;
    }

    vibrato(left, frameCount);
    // Overdrive, as of the organ's preamp pushed.
    float drive = std::clamp(mParameters[orgDrive] / 100, 0.0f, 1.0f) * 6;
    if (drive > 0) {
      float normal = 1 / std::tanh(1 + drive);
      for (int i = 0; i < frameCount; ++i) left[i] = std::tanh(left[i] * (1 + drive)) * normal * 0.8f;
    }
    rotary(left, right, frameCount);
    float volume = std::pow(10.0f, std::clamp(mParameters[orgVolume], -24.0f, 12.0f) / 20);
    for (int i = 0; i < frameCount; ++i) {
      left[i] *= volume;
      if (right) right[i] *= volume;
    }
    for (size_t c = 2; c < outputs.size(); ++c) std::copy_n(left, frameCount, outputs[c]);
  }

private:
  struct Voice {
    int note = -1;
    std::array<double, 9> phases {}, steps {};
    double baseStep = 0, percussionPhase = 0;
    float gate = 0;
    bool isHeld = false, hasPercussion = false;
    int clickLeft = 0, clickLength = 1;
    uint32_t clickState = 22222;
  };

  void noteOn(int note) {
    Voice *chosen = nullptr;
    for (auto &voice : mVoices) if (voice.note == note) chosen = &voice;
    if (!chosen) for (auto &voice : mVoices) if (voice.gate <= 0 && !voice.isHeld) { chosen = &voice; break; }
    if (!chosen) {
      chosen = &*std::min_element(mVoices.begin(), mVoices.end(), [](Voice const &a, Voice const &b) { return a.gate < b.gate; });
    }
    Voice &voice = *chosen;
    double frequency = noteFrequency(note);
    voice.note = note;
    voice.baseStep = frequency / mSampleRate;
    for (int bar = 0; bar < 9; ++bar) {
      double partial = frequency * harmonics[size_t(bar)];
      // The top tonewheels run out: higher partials fold back down an octave.
      while (partial > 5900) partial /= 2;
      voice.steps[size_t(bar)] = partial / mSampleRate;
    }
    // Single-trigger percussion: only keys struck when none is held sound it; keys added
    // while others are held don't.
    bool strikes = !voice.isHeld && mHeldKeys == 0;
    if (strikes) {
      mPercussion = 1;
      for (auto &other : mVoices) other.hasPercussion = false;
    }
    if (!voice.isHeld) voice.hasPercussion = strikes;
    if (!voice.isHeld) ++mHeldKeys;
    voice.isHeld = true;
    voice.clickLength = std::max(1, int(0.004 * mSampleRate));
    voice.clickLeft = voice.clickLength;
    voice.clickState = 22222u + uint32_t(note) * 7919u;
  }

  void noteOff(int note) {
    for (auto &voice : mVoices) {
      if (voice.note != note || !voice.isHeld) continue;
      voice.isHeld = false;
      mHeldKeys = std::max(0, mHeldKeys - 1);
    }
  }

  /// The scanner vibrato: a short delay swept at about 7 Hz (V1–V3 deeper each), or the
  /// same mixed with the dry sound for chorus (C1–C3).
  void vibrato(float *samples, int frameCount) {
    int type = std::clamp(int(std::lround(mParameters[orgVibrato])), 0, 6);
    if (type == 0) return;
    int depthIndex = (type - 1) % 3;
    bool chorus = type >= 4;
    float depth = std::array<float, 3> {0.25f, 0.5f, 0.9f}[size_t(depthIndex)] * 0.001f * float(mSampleRate);
    float base = 0.0015f * float(mSampleRate);
    for (int i = 0; i < frameCount; ++i) {
      mScanner.write(samples[i]);
      float swept = mScanner.read(base + depth * float(std::sin(2 * M_PI * mScannerPhase)));
      mScannerPhase += 6.9 / mSampleRate;
      if (mScannerPhase >= 1) mScannerPhase -= 1;
      samples[i] = chorus ? (samples[i] + swept) * 0.6f : swept;
    }
  }

  /// The rotary speaker's speeds (horn, drum) in hertz for its setting.
  std::pair<double, double> targetRates() const {
    int setting = std::clamp(int(std::lround(mParameters[orgRotary])), 0, 2);
    bool fast = setting == 2 || (setting == 1 && mWheelFast);
    return fast ? std::pair<double, double>(6.8, 5.9) : std::pair<double, double>(0.8, 0.66);
  }

  /// The rotary speaker: the highs (above about 800 Hz) through the horn, turning toward and
  /// away from each side (louder and higher as it comes round), the lows through the drum.
  void rotary(float *left, float *right, int frameCount) {
    int setting = std::clamp(int(std::lround(mParameters[orgRotary])), 0, 2);
    if (setting == 0 || right == nullptr) {
      if (right) std::copy_n(left, frameCount, right);
      return;
    }
    auto [hornTarget, drumTarget] = targetRates();
    // The horn spins up in about a second, the heavier drum in about four.
    double hornGlide = 1 - std::exp(-1 / (0.8 * mSampleRate));
    double drumGlide = 1 - std::exp(-1 / (3.5 * mSampleRate));
    float split = float(1 - std::exp(-2 * M_PI * 800 / mSampleRate));
    float base = 0.002f * float(mSampleRate);
    float doppler = 0.0003f * float(mSampleRate);
    for (int i = 0; i < frameCount; ++i) {
      mHornRate += (hornTarget - mHornRate) * hornGlide;
      mDrumRate += (drumTarget - mDrumRate) * drumGlide;
      mLow1 += (left[i] - mLow1) * split;
      mLow2 += (mLow1 - mLow2) * split;
      float lows = mLow2, highs = left[i] - mLow2;
      mHorn.write(highs);
      float hornSine = float(std::sin(2 * M_PI * mHornPhase));
      float hornLeft = mHorn.read(base + doppler * hornSine) * (0.6f + 0.4f * hornSine);
      float hornRight = mHorn.read(base - doppler * hornSine) * (0.6f - 0.4f * hornSine);
      float drumSine = float(std::sin(2 * M_PI * mDrumPhase));
      left[i] = hornLeft + lows * (0.85f + 0.15f * drumSine);
      right[i] = hornRight + lows * (0.85f - 0.15f * drumSine);
      mHornPhase += mHornRate / mSampleRate;
      mDrumPhase += mDrumRate / mSampleRate;
      if (mHornPhase >= 1) mHornPhase -= 1;
      if (mDrumPhase >= 1) mDrumPhase -= 1;
    }
  }

  KeysParameters<orgFirstDrawbar, orgVolume> mParameters;
  std::array<Voice, voiceCount> mVoices;
  DelayLine mScanner, mHorn;
  double mSampleRate = 44100;
  double mScannerPhase = 0, mHornPhase = 0, mDrumPhase = 0, mHornRate = 0.8, mDrumRate = 0.66;
  float mPercussion = 0, mLow1 = 0, mLow2 = 0;
  int mHeldKeys = 0;
  bool mWheelFast = false;
};

}  // namespace ongaku
