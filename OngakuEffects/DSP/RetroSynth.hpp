//
//  RetroSynth.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <span>

#include "OngakuEffectsParameterAddresses.h"

namespace ongaku {

/// An attack, decay, sustain, release envelope: a straight rise, then exponential falls
/// (each reaching its target in about its time, as analog envelopes sound).
class Envelope {
public:
  enum class Stage { idle, attack, decay, sustain, release };

  void set(float attackSeconds, float decaySeconds, float sustainLevel, float releaseSeconds, float sampleRate) {
    mAttackStep = 1 / std::max(1.0f, attackSeconds * sampleRate);
    mDecay = std::exp(-4.6f / std::max(1.0f, decaySeconds * sampleRate));
    mSustain = std::clamp(sustainLevel, 0.0f, 1.0f);
    mRelease = std::exp(-4.6f / std::max(1.0f, releaseSeconds * sampleRate));
  }

  void start() { mStage = Stage::attack; }
  void release() { if (mStage != Stage::idle) mStage = Stage::release; }
  void reset() { mStage = Stage::idle; mLevel = 0; }
  bool isActive() const { return mStage != Stage::idle; }
  bool isReleasing() const { return mStage == Stage::release; }
  float level() const { return mLevel; }

  float next() {
    switch (mStage) {
      case Stage::idle: return 0;
      case Stage::attack:
        mLevel += mAttackStep;
        if (mLevel >= 1) { mLevel = 1; mStage = Stage::decay; }
        break;
      case Stage::decay:
        mLevel = mSustain + (mLevel - mSustain) * mDecay;
        if (std::abs(mLevel - mSustain) < 1e-4f) { mLevel = mSustain; mStage = Stage::sustain; }
        break;
      case Stage::sustain:
        mLevel = mSustain;
        break;
      case Stage::release:
        mLevel *= mRelease;
        if (mLevel < 1e-4f) reset();
        break;
    }
    return mLevel;
  }

private:
  Stage mStage = Stage::idle;
  float mLevel = 0;
  float mAttackStep = 0.01f, mDecay = 0.999f, mSustain = 1, mRelease = 0.999f;
};

/// Smooths the corners of a saw or pulse so they don't alias (polynomial band-limited steps).
inline float polyBlep(float phase, float step) {
  if (phase < step) {
    float t = phase / step;
    return t + t - t * t - 1;
  }
  if (phase > 1 - step) {
    float t = (phase - 1) / step;
    return t * t + t + t + 1;
  }
  return 0;
}

/// A waveform from a phase (0–1) and the phase step per sample.
inline float oscillator(int wave, float phase, float step, float pulseWidth) {
  switch (wave) {
    case 0:  // saw
      return 2 * phase - 1 - polyBlep(phase, step);
    case 1: {  // pulse (a square at 50 %)
      float value = phase < pulseWidth ? 1.0f : -1.0f;
      float shifted = phase + 1 - pulseWidth;
      if (shifted >= 1) shifted -= 1;
      return value + polyBlep(phase, step) - polyBlep(shifted, step);
    }
    case 2:  // triangle
      return 4 * std::abs(phase - 0.5f) - 1;
    default:  // sine
      return std::sin(2 * float(M_PI) * phase);
  }
}

/// Bends a phase so its first half takes `shape` of the cycle (0.5 leaves it alone): a
/// phase-distortion "shape" that skews saws, triangles and sines.
inline float warp(float phase, float shape) {
  return phase < shape ? phase * 0.5f / shape : 0.5f + (phase - shape) * 0.5f / (1 - shape);
}

/// A waveform with its shape: the pulse's width, or how the other waves skew.
inline float shapedOscillator(int wave, float phase, float step, float shape) {
  if (wave == 1) return oscillator(1, phase, step, shape);
  // The warp speeds the phase through one half, so the corner smoothing must too.
  float warpedStep = step * (phase < shape ? 0.5f / shape : 0.5f / (1 - shape));
  return oscillator(wave, warp(phase, shape), warpedStep, 0.5f);
}

/// A four-pole low-pass ladder in the Moog style, solved without a sample of delay in its
/// feedback (Zavalishin's topology-preserving transform), with a little saturation.
class LadderFilter {
public:
  void set(float cutoff, float resonance, float sampleRate) {
    float g = std::tan(float(M_PI) * std::clamp(cutoff, 20.0f, sampleRate * 0.45f) / sampleRate);
    mG = g / (1 + g);
    mResonance = std::clamp(resonance, 0.0f, 1.0f) * 3.9f;
  }

  float process(float input) {
    // The feedback the four stages will produce, from their current states.
    float g2 = mG * mG, g4 = g2 * g2;
    float scale = 1 - mG;  // s / (1 + g) in terms of G
    float sigma = mG * g2 * mState[0] * scale + g2 * mState[1] * scale + mG * mState[2] * scale + mState[3] * scale;
    float estimate = (g4 * input + sigma) / (1 + mResonance * g4);
    float x = std::tanh(input - mResonance * estimate);
    for (auto &state : mState) {
      float v = (x - state) * mG;
      float y = v + state;
      state = y + v;
      x = y;
    }
    return x;
  }

  void reset() { mState.fill(0); }

  void flushDenormals() {
    for (auto &state : mState) if (std::abs(state) < 1e-20f) state = 0;
  }

private:
  std::array<float, 4> mState {};
  float mG = 0.5f;
  float mResonance = 0;
};

/// An analog-style polyphonic synthesizer in the spirit of Logic's Retro Synth: two
/// oscillators and noise, a resonant ladder filter with its own envelope, an amplifier
/// envelope, an LFO for vibrato, filter wobble and pulse-width movement, and glide.
class RetroSynth {
public:
  static constexpr AUParameterAddress firstAddress = synOsc1Wave;
  static constexpr int parameterCount = synUnisonSpread - synOsc1Wave + 1;
  static constexpr int voiceCount = 16;
  static constexpr int maxUnison = 7;

  RetroSynth() { mTargets.fill(0); }

  void setParameter(AUParameterAddress address, float value) {
    if (address >= firstAddress && address < firstAddress + parameterCount) mTargets[address - firstAddress] = value;
  }

  float parameter(AUParameterAddress address) const {
    return address >= firstAddress && address < firstAddress + parameterCount ? mTargets[address - firstAddress] : 0;
  }

  void initialize(double sampleRate) {
    mSampleRate = float(sampleRate);
    reset();
  }

  void reset() {
    for (auto &voice : mVoices) voice = Voice();
    mHeldCount = 0;
    mSustainPedal = false;
  }

  /// How many voices are sounding (for meters and tests).
  int activeVoices() const {
    return int(std::count_if(mVoices.begin(), mVoices.end(), [](Voice const &voice) { return voice.amp.isActive(); }));
  }

  // MARK: MIDI

  void midi(uint8_t status, uint8_t data1, uint8_t data2) {
    switch (status & 0xF0) {
      case 0x90:
        if (data2 > 0) { noteOn(data1, data2); } else { noteOff(data1); }
        break;
      case 0x80: noteOff(data1); break;
      case 0xB0:
        if (data1 == 1) mModWheel = data2 / 127.0f;
        if (data1 == 64) setSustain(data2 >= 64);
        if (data1 == 120 || data1 == 123) allNotesOff(data1 == 120);
        break;
      case 0xE0:
        mPitchBend = (float((data2 << 7) | data1) - 8192) / 8192;
        break;
      default: break;
    }
  }

  // MARK: Rendering

  void process(std::span<float *> outputs, int frameCount) {
    if (outputs.empty()) return;
    updateSettings();
    float *left = outputs[0];
    float *right = outputs.size() > 1 ? outputs[1] : nullptr;
    for (int start = 0; start < frameCount; start += controlInterval) {
      int frames = std::min(controlInterval, frameCount - start);
      float lfo = nextLFO(frames);
      for (auto &voice : mVoices) {
        if (!voice.amp.isActive()) continue;
        renderVoice(voice, left + start, right ? right + start : nullptr, frames, lfo);
      }
    }
    // A single note reaches about −20 dB RMS, leaving room for chords.
    float gain = std::pow(10.0f, value(synGain) / 20) * 0.4f;
    for (int i = 0; i < frameCount; ++i) left[i] *= gain;
    if (right) for (int i = 0; i < frameCount; ++i) right[i] *= gain;
    for (size_t c = 2; c < outputs.size(); ++c) std::copy_n(left, frameCount, outputs[c]);
    for (auto &voice : mVoices) {
      voice.filter.flushDenormals();
      voice.filterRight.flushDenormals();
    }
  }

private:
  static constexpr int controlInterval = 16;

  struct Voice {
    int note = -1;
    float velocity = 0;
    float pitch = 60;  // where the pitch has glided to, in semitones
    // Each stacked unison voice has its own oscillator phases.
    std::array<float, maxUnison> phase1 {}, phase2 {};
    float subPhase = 0;
    Envelope amp, filterEnvelope;
    LadderFilter filter, filterRight;
    bool isHeld = false;      // the key is down
    bool isSustained = false; // released while the pedal was down
    uint64_t age = 0;
  };

  float value(AUParameterAddress address) const { return mTargets[address - firstAddress]; }
  int wave(AUParameterAddress address) const { return std::clamp(int(std::lround(value(address))), 0, 3); }
  bool isMono() const { return value(synMode) >= 0.5f; }

  void updateSettings() {
    for (auto &voice : mVoices) {
      voice.amp.set(value(synAmpAttack) / 1000, value(synAmpDecay) / 1000, value(synAmpSustain) / 100,
                    value(synAmpRelease) / 1000, mSampleRate);
      voice.filterEnvelope.set(value(synFilterAttack) / 1000, value(synFilterDecay) / 1000,
                               value(synFilterSustain) / 100, value(synFilterRelease) / 1000, mSampleRate);
    }
  }

  void noteOn(int note, int velocity) {
    float level = velocity / 127.0f;
    if (isMono()) {
      Voice &voice = mVoices[0];
      bool legato = voice.amp.isActive() && !voice.amp.isReleasing() && mHeldCount > 0;
      pushHeld(note);
      voice.note = note;
      voice.velocity = level;
      voice.isHeld = true;
      voice.isSustained = false;
      if (!legato) {
        // A new phrase: start from the note (glide only joins notes played legato).
        if (value(synGlide) <= 0 || !voice.amp.isActive()) voice.pitch = float(note);
        voice.amp.start();
        voice.filterEnvelope.start();
      }
      return;
    }
    // The voice already playing this note, a free voice, the quietest releasing one, or
    // the oldest.
    Voice *chosen = nullptr;
    for (auto &voice : mVoices) if (voice.note == note && voice.amp.isActive()) chosen = &voice;
    if (!chosen) for (auto &voice : mVoices) if (!voice.amp.isActive()) { chosen = &voice; break; }
    if (!chosen) {
      for (auto &voice : mVoices) {
        if (voice.amp.isReleasing() && (!chosen || voice.amp.level() < chosen->amp.level())) chosen = &voice;
      }
    }
    if (!chosen) {
      chosen = &*std::min_element(mVoices.begin(), mVoices.end(), [](Voice const &a, Voice const &b) { return a.age < b.age; });
    }
    Voice &voice = *chosen;
    if (!voice.amp.isActive()) {
      voice.filter.reset();
      voice.filterRight.reset();
      // Stacked voices start at different points in their cycles, so they don't phase.
      for (int k = 0; k < maxUnison; ++k) {
        voice.phase1[k] = k == 0 ? 0 : float((k * 37) % 100) / 100;
        voice.phase2[k] = k == 0 ? 0 : float((k * 61) % 100) / 100;
      }
      voice.subPhase = 0;
      // Glide starts from the last note played.
      voice.pitch = value(synGlide) > 0 && mLastNote >= 0 ? float(mLastNote) : float(note);
    }
    voice.note = note;
    voice.velocity = level;
    voice.isHeld = true;
    voice.isSustained = false;
    voice.age = ++mClock;
    voice.amp.start();
    voice.filterEnvelope.start();
    mLastNote = note;
  }

  void noteOff(int note) {
    if (isMono()) {
      removeHeld(note);
      Voice &voice = mVoices[0];
      if (voice.note != note) return;
      if (mHeldCount > 0) {
        // Back to the last key still held, legato.
        voice.note = mHeld[mHeldCount - 1];
        return;
      }
      voice.isHeld = false;
      if (mSustainPedal) { voice.isSustained = true; } else { voice.amp.release(); voice.filterEnvelope.release(); }
      return;
    }
    for (auto &voice : mVoices) {
      if (voice.note != note || !voice.isHeld) continue;
      voice.isHeld = false;
      if (mSustainPedal) {
        voice.isSustained = true;
      } else {
        voice.amp.release();
        voice.filterEnvelope.release();
      }
    }
  }

  void setSustain(bool isDown) {
    mSustainPedal = isDown;
    if (isDown) return;
    for (auto &voice : mVoices) {
      if (!voice.isSustained) continue;
      voice.isSustained = false;
      voice.amp.release();
      voice.filterEnvelope.release();
    }
  }

  void allNotesOff(bool immediately) {
    mHeldCount = 0;
    for (auto &voice : mVoices) {
      voice.isHeld = false;
      voice.isSustained = false;
      if (immediately) { voice.amp.reset(); voice.filterEnvelope.reset(); }
      else { voice.amp.release(); voice.filterEnvelope.release(); }
    }
  }

  void pushHeld(int note) {
    removeHeld(note);
    if (mHeldCount < int(mHeld.size())) mHeld[mHeldCount++] = note;
  }

  void removeHeld(int note) {
    int kept = 0;
    for (int i = 0; i < mHeldCount; ++i) if (mHeld[i] != note) mHeld[kept++] = mHeld[i];
    mHeldCount = kept;
  }

  /// The LFO's value (−1…1) for the next stretch of samples.
  float nextLFO(int frames) {
    float rate = std::max(0.01f, value(synLfoRate));
    float previous = mLfoPhase;
    mLfoPhase += rate * float(frames) / mSampleRate;
    if (mLfoPhase >= 1) {
      mLfoPhase -= std::floor(mLfoPhase);
      mRandom = nextNoise();
    }
    (void)previous;
    switch (std::clamp(int(std::lround(value(synLfoWave))), 0, 2)) {
      case 0: return 4 * std::abs(mLfoPhase - 0.5f) - 1;  // triangle
      case 1: return mLfoPhase < 0.5f ? 1.0f : -1.0f;     // square
      default: return mRandom;                             // random steps
    }
  }

  float nextNoise() {
    mNoiseState ^= mNoiseState << 13;
    mNoiseState ^= mNoiseState >> 17;
    mNoiseState ^= mNoiseState << 5;
    return float(mNoiseState) / float(UINT32_MAX) * 2 - 1;
  }

  void renderVoice(Voice &voice, float *left, float *right, int frames, float lfo) {
    // Glide toward the note over the glide time.
    float glideSeconds = value(synGlide) / 1000;
    float glide = glideSeconds > 0 ? 1 - std::exp(-float(frames) / (glideSeconds * mSampleRate / 4.6f)) : 1;
    voice.pitch += (float(voice.note) - voice.pitch) * glide;

    // Pitch: the note, bend, and vibrato (the mod wheel adds more).
    float vibrato = (value(synLfoPitch) + mModWheel * 50) / 100 * lfo;
    float pitch1 = voice.pitch + mPitchBend * value(synBendRange) + vibrato;
    float pitch2 = pitch1 + value(synOsc2Semitones) + value(synOsc2Detune) / 100;
    float pulseMovement = value(synLfoPulse) / 100 * 0.4f * lfo;
    float shape1 = std::clamp(value(synPulseWidth) / 100 + pulseMovement, 0.05f, 0.95f);
    float shape2 = std::clamp(value(synOsc2Shape) / 100 + pulseMovement, 0.05f, 0.95f);
    int wave1 = wave(synOsc1Wave), wave2 = wave(synOsc2Wave);
    int mode = std::clamp(int(std::lround(value(synOsc2Mode))), 0, 2);
    float fm = std::clamp(value(synFM) / 100, 0.0f, 1.0f);
    float mix = std::clamp(value(synOscMix) / 100, 0.0f, 1.0f);
    float noise = std::clamp(value(synNoise) / 100, 0.0f, 1.0f);
    float sub = std::clamp(value(synSubLevel) / 100, 0.0f, 1.0f);
    float subStep = std::min(0.45f, 440 * std::exp2((pitch1 - 12 - 69) / 12) / mSampleRate);

    // Unison: stacked copies, tuned evenly across the detune and panned across the spread.
    int unison = std::clamp(int(std::lround(value(synUnison))), 1, maxUnison);
    float detune = value(synUnisonDetune) / 100;
    float spread = std::clamp(value(synUnisonSpread) / 100, 0.0f, 1.0f);
    std::array<float, maxUnison> step1s, step2s, gainsLeft, gainsRight;
    for (int k = 0; k < unison; ++k) {
      float position = unison == 1 ? 0 : float(k) / float(unison - 1) * 2 - 1;  // −1…1
      float offset = position * detune / 2;
      step1s[k] = std::min(0.45f, 440 * std::exp2((pitch1 + offset - 69) / 12) / mSampleRate);
      step2s[k] = std::min(0.45f, 440 * std::exp2((pitch2 + offset - 69) / 12) / mSampleRate);
      float pan = position * spread;
      gainsLeft[k] = std::min(1.0f, 1 - pan);
      gainsRight[k] = std::min(1.0f, 1 + pan);
    }
    float unisonScale = 1 / std::sqrt(float(unison));

    // Cutoff: the knob, opened by the filter envelope, following the keyboard, wobbled by
    // the LFO.
    float envelopeOctaves = value(synFilterEnv) / 100 * 6 * voice.filterEnvelope.level();
    float keyOctaves = value(synKeyTrack) / 100 * (voice.pitch - 60) / 12;
    float lfoOctaves = value(synLfoFilter) / 100 * 3 * lfo;
    float cutoff = value(synCutoff) * std::exp2(envelopeOctaves + keyOctaves + lfoOctaves);
    voice.filter.set(cutoff, value(synResonance) / 100, mSampleRate);
    voice.filterRight.set(cutoff, value(synResonance) / 100, mSampleRate);

    float velocityGain = 1 - value(synVelocity) / 100 * (1 - voice.velocity);
    for (int i = 0; i < frames; ++i) {
      float sumLeft = 0, sumRight = 0;
      for (int k = 0; k < unison; ++k) {
        float two = shapedOscillator(wave2, voice.phase2[k], step2s[k], shape2);
        // FM: oscillator 2 pushes oscillator 1's phase back and forth.
        float phase1 = voice.phase1[k] + fm * 0.3f * two;
        phase1 -= std::floor(phase1);
        float one = shapedOscillator(wave1, phase1, step1s[k], shape1);
        if (mode == 2) two *= one;  // ring modulation
        float signal = one * (1 - mix) + two * mix;
        sumLeft += signal * gainsLeft[k];
        sumRight += signal * gainsRight[k];

        voice.phase2[k] += step2s[k];
        if (voice.phase2[k] >= 1) voice.phase2[k] -= 1;
        voice.phase1[k] += step1s[k];
        if (voice.phase1[k] >= 1) {
          voice.phase1[k] -= 1;
          // Sync: oscillator 2 starts its cycle again whenever oscillator 1 does.
          if (mode == 1) voice.phase2[k] = voice.phase1[k] * step2s[k] / step1s[k];
        }
      }
      float common = oscillator(1, voice.subPhase, subStep, 0.5f) * sub * 0.8f + nextNoise() * noise * 0.5f;
      voice.subPhase += subStep;
      if (voice.subPhase >= 1) voice.subPhase -= 1;

      voice.filterEnvelope.next();
      float amplitude = voice.amp.next() * velocityGain;
      left[i] += voice.filter.process((sumLeft * unisonScale + common) * 0.7f) * amplitude;
      if (right) right[i] += voice.filterRight.process((sumRight * unisonScale + common) * 0.7f) * amplitude;
    }
    if (!voice.amp.isActive()) voice.note = -1;
  }

  std::array<float, parameterCount> mTargets;
  std::array<Voice, voiceCount> mVoices;
  std::array<int, 16> mHeld {};
  int mHeldCount = 0;
  int mLastNote = -1;
  uint64_t mClock = 0;
  float mSampleRate = 44100;
  float mModWheel = 0;
  float mPitchBend = 0;
  bool mSustainPedal = false;
  float mLfoPhase = 0;
  float mRandom = 0;
  uint32_t mNoiseState = 0x12345678;
};

}  // namespace ongaku
