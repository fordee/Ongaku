//
//  DrumMachine.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <span>

#include "Biquad.hpp"
#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

/// A drum machine in the spirit of the classic analog ones (and Logic's Drum Machine
/// Designer): twelve synthesized drums, each on its General MIDI drum note, with its own
/// tune, decay, tone, level and pan.
class DrumMachine {
public:
  static constexpr AUParameterAddress firstAddress = drmVolume;
  static constexpr int padCount = OngakuDrumPadCount;
  static constexpr int parameterCount = drmFirstPad + OngakuDrumPadStride * padCount - drmVolume;

  /// Each pad's General MIDI note.
  static constexpr int notes[padCount] = {36, 38, 39, 37, 42, 46, 45, 47, 50, 56, 49, 70};

  DrumMachine() { mTargets.fill(0); }

  void setParameter(AUParameterAddress address, float value) {
    if (address >= firstAddress && address < firstAddress + parameterCount) mTargets[address - firstAddress] = value;
  }

  float parameter(AUParameterAddress address) const {
    return address >= firstAddress && address < firstAddress + parameterCount ? mTargets[address - firstAddress] : 0;
  }

  void initialize(double sampleRate) {
    mSampleRate = float(sampleRate);
    for (auto &voice : mVoices) voice = Voice();
  }

  /// How loud each pad is sounding right now (0–1), for lighting the pads.
  float activity(int pad) const { return mVoices[size_t(pad)].active ? std::min(1.0f, mVoices[size_t(pad)].amp) : 0; }

  void midi(uint8_t status, uint8_t data1, uint8_t data2) {
    if ((status & 0xF0) == 0x90 && data2 > 0) {
      for (int pad = 0; pad < padCount; ++pad) {
        if (notes[pad] == data1) trigger(pad, data2 / 127.0f);
      }
    }
    // Drums ring out on their own; note-offs are ignored, as on drum machines.
  }

  void process(std::span<float *> outputs, int frameCount) {
    if (outputs.empty()) return;
    float *left = outputs[0];
    float *right = outputs.size() > 1 ? outputs[1] : nullptr;
    float volume = std::pow(10.0f, value(drmVolume) / 20) * 0.6f;
    float drive = 1 + std::clamp(value(drmDrive) / 100, 0.0f, 1.0f) * 6;
    for (int pad = 0; pad < padCount; ++pad) {
      Voice &voice = mVoices[size_t(pad)];
      if (!voice.active) continue;
      float level = std::pow(10.0f, field(pad, OngakuDrumFieldLevel) / 20) * voice.velocity;
      float pan = std::clamp(field(pad, OngakuDrumFieldPan) / 100, -1.0f, 1.0f);
      float gainLeft = std::cos((pan + 1) * float(M_PI) / 4) * float(M_SQRT2);
      float gainRight = std::sin((pan + 1) * float(M_PI) / 4) * float(M_SQRT2);
      for (int i = 0; i < frameCount; ++i) {
        float sample = render(pad, voice) * level;
        left[i] += sample * gainLeft;
        if (right) right[i] += sample * gainRight;
      }
      if (voice.amp < 1e-4f && voice.time > 0.02f) voice.active = false;
    }
    // Drive saturates the whole kit, then the volume.
    for (int i = 0; i < frameCount; ++i) {
      left[i] = std::tanh(left[i] * drive) / drive * volume;
      if (right) right[i] = std::tanh(right[i] * drive) / drive * volume;
    }
    for (size_t c = 2; c < outputs.size(); ++c) std::copy_n(left, frameCount, outputs[c]);
  }

private:
  enum Pad { kick, snare, clap, rim, closedHat, openHat, lowTom, midTom, highTom, cowbell, crash, shaker };

  struct Voice {
    bool active = false;
    float velocity = 1;
    float time = 0;      // seconds since the hit
    float amp = 0;       // the main envelope
    float noiseAmp = 0;  // a second envelope, for noise or a click
    float decay = 0.999f, noiseDecay = 0.999f;
    std::array<float, 6> phases {};
    BiquadState filter, filter2;
    BiquadCoefficients coefficients, coefficients2;
  };

  float value(AUParameterAddress address) const { return mTargets[address - firstAddress]; }

  float field(int pad, OngakuDrumField which) const {
    return mTargets[drmFirstPad - firstAddress + OngakuDrumPadStride * pad + which];
  }

  /// The pad's tune as a frequency ratio, and its decay time scaled by its Decay knob.
  float tune(int pad) const { return std::exp2(field(pad, OngakuDrumFieldTune) / 12); }
  float decaySeconds(int pad, float base) const { return base * std::max(0.05f, field(pad, OngakuDrumFieldDecay) / 100); }
  float tone(int pad) const { return std::clamp(field(pad, OngakuDrumFieldTone) / 100, 0.0f, 1.0f); }

  float coefficient(float seconds) const { return std::exp(-1 / (std::max(0.001f, seconds) * mSampleRate)); }

  float noise() {
    mNoise ^= mNoise << 13;
    mNoise ^= mNoise >> 17;
    mNoise ^= mNoise << 5;
    return float(mNoise) / float(UINT32_MAX) * 2 - 1;
  }

  void trigger(int pad, float velocity) {
    // The closed hat chokes the open one, as on real machines (quickly, without a click).
    if (pad == closedHat) mVoices[openHat].decay = coefficient(0.004f);
    Voice &voice = mVoices[size_t(pad)];
    voice.active = true;
    voice.velocity = 0.25f + 0.75f * velocity;
    voice.time = 0;
    voice.amp = 1;
    voice.noiseAmp = 1;
    voice.phases.fill(0);
    voice.filter.reset();
    voice.filter2.reset();
    float t = tune(pad), brightness = tone(pad);
    double rate = mSampleRate;
    switch (pad) {
      case kick:
        voice.decay = coefficient(decaySeconds(pad, 0.5f));
        voice.noiseDecay = coefficient(0.004f);
        break;
      case snare:
        voice.decay = coefficient(decaySeconds(pad, 0.14f));
        voice.noiseDecay = coefficient(decaySeconds(pad, 0.2f));
        voice.coefficients = BiquadCoefficients::highPass(1200 * t, 0.7, rate);
        break;
      case clap:
        voice.decay = coefficient(decaySeconds(pad, 0.22f));
        voice.coefficients = BiquadCoefficients::highPass(900 * t, 0.7, rate);
        voice.coefficients2 = BiquadCoefficients::lowPass(2500 * t * (0.6 + brightness), 1.2, rate);
        break;
      case rim:
        voice.decay = coefficient(decaySeconds(pad, 0.03f));
        voice.coefficients = BiquadCoefficients::highPass(1700 * t, 3, rate);
        break;
      case closedHat:
      case openHat:
      case crash: {
        float base = pad == closedHat ? 0.05f : pad == openHat ? 0.45f : 1.6f;
        voice.decay = coefficient(decaySeconds(pad, base));
        voice.noiseDecay = coefficient(decaySeconds(pad, base * 0.7f));
        double cutoff = (pad == crash ? 4500.0 : 7000.0) * (0.6 + 0.8 * brightness);
        voice.coefficients = BiquadCoefficients::highPass(std::min(cutoff, rate * 0.45), 0.8, rate);
        voice.coefficients2 = BiquadCoefficients::bell(std::min(cutoff * 1.4, rate * 0.45), 6, 1.5, rate);
        break;
      }
      case lowTom:
      case midTom:
      case highTom:
        voice.decay = coefficient(decaySeconds(pad, 0.35f));
        voice.noiseDecay = coefficient(0.01f);
        break;
      case cowbell:
        voice.decay = coefficient(decaySeconds(pad, 0.3f));
        voice.noiseDecay = coefficient(0.03f);
        voice.coefficients = BiquadCoefficients::bell(2600 * t, 9, 2, rate);
        voice.coefficients2 = BiquadCoefficients::highPass(400, 0.7, rate);
        break;
      case shaker:
        voice.decay = coefficient(decaySeconds(pad, 0.11f));
        voice.coefficients = BiquadCoefficients::highPass(std::min(5000.0 * t, rate * 0.45), 0.7, rate);
        break;
      default:
        break;
    }
  }

  /// The next sample of a pad's drum.
  float render(int pad, Voice &voice) {
    float dt = 1 / mSampleRate;
    float t = tune(pad), brightness = tone(pad);
    float out = 0;
    switch (pad) {
      case kick: {
        // A sine falling quickly from about three times its pitch, with a click.
        float pitch = 50 * t * (1 + 2.2f * std::exp(-voice.time / 0.03f));
        voice.phases[0] += pitch * dt;
        out = std::sin(2 * float(M_PI) * voice.phases[0]) * voice.amp;
        out += noise() * voice.noiseAmp * brightness * 0.8f;
        break;
      }
      case snare: {
        // Two drum-head tones, and snares: high-passed noise (Tone sets how much).
        voice.phases[0] += 185 * t * dt;
        voice.phases[1] += 330 * t * dt;
        float body = (std::sin(2 * float(M_PI) * voice.phases[0]) + 0.6f * std::sin(2 * float(M_PI) * voice.phases[1])) * 0.6f;
        float snares = voice.filter.process(noise(), voice.coefficients);
        out = body * voice.amp * (1.2f - brightness * 0.7f) + snares * voice.noiseAmp * (0.3f + brightness);
        break;
      }
      case clap: {
        // Three quick bursts of filtered noise, then a short tail.
        float burst = 1;
        if (voice.time < 0.03f) {
          float within = std::fmod(voice.time, 0.01f);
          burst = std::exp(-within / 0.002f);
        }
        float filtered = voice.filter2.process(voice.filter.process(noise(), voice.coefficients), voice.coefficients2);
        out = filtered * burst * voice.amp * 1.6f;
        break;
      }
      case rim: {
        voice.phases[0] += 480 * t * dt;
        out = (voice.filter.process(noise(), voice.coefficients) * 0.8f + std::sin(2 * float(M_PI) * voice.phases[0])) * voice.amp;
        break;
      }
      case closedHat:
      case openHat:
      case crash: {
        // Six square waves at the 808's clashing frequencies, plus noise, filtered bright.
        static constexpr float ratios[6] = {205.3f, 304.4f, 369.6f, 522.7f, 540.0f, 800.0f};
        float metal = 0;
        for (int k = 0; k < 6; ++k) {
          voice.phases[size_t(k)] += ratios[k] * t * (pad == crash ? 1.0f : 1.4f) * dt;
          voice.phases[size_t(k)] -= std::floor(voice.phases[size_t(k)]);
          metal += voice.phases[size_t(k)] < 0.5f ? 1.0f : -1.0f;
        }
        float mixed = metal / 6 * 0.7f + noise() * (pad == crash ? 0.6f : 0.35f) * voice.noiseAmp;
        out = voice.filter2.process(voice.filter.process(mixed, voice.coefficients), voice.coefficients2) * voice.amp * 0.6f;
        break;
      }
      case lowTom:
      case midTom:
      case highTom: {
        float base = pad == lowTom ? 95.0f : pad == midTom ? 135.0f : 185.0f;
        float pitch = base * t * (1 + 0.6f * std::exp(-voice.time / 0.06f));
        voice.phases[0] += pitch * dt;
        out = std::sin(2 * float(M_PI) * voice.phases[0]) * voice.amp + noise() * voice.noiseAmp * brightness * 0.5f;
        break;
      }
      case cowbell: {
        voice.phases[0] += 540 * t * dt;
        voice.phases[1] += 800 * t * dt;
        voice.phases[0] -= std::floor(voice.phases[0]);
        voice.phases[1] -= std::floor(voice.phases[1]);
        float squares = ((voice.phases[0] < 0.5f ? 1.0f : -1.0f) + (voice.phases[1] < 0.5f ? 1.0f : -1.0f)) * 0.5f;
        // A sharp drop at the start, then the ring.
        float shape = voice.amp * (0.6f + 0.4f * voice.noiseAmp);
        out = voice.filter2.process(voice.filter.process(squares, voice.coefficients), voice.coefficients2) * shape * 0.25f;
        break;
      }
      case shaker: {
        float attack = std::min(1.0f, voice.time / 0.008f);
        out = voice.filter.process(noise(), voice.coefficients) * voice.amp * attack * 0.8f;
        break;
      }
      default:
        break;
    }
    voice.time += dt;
    voice.amp *= voice.decay;
    voice.noiseAmp *= voice.noiseDecay;
    return out;
  }

  std::array<float, size_t(parameterCount)> mTargets;
  std::array<Voice, padCount> mVoices;
  float mSampleRate = 44100;
  uint32_t mNoise = 0x2545F491;
};

}  // namespace ongaku
