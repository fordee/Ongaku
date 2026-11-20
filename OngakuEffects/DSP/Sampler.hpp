//
//  Sampler.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <span>

#include "OngakuEffectsParameterAddresses.h"
#include "RetroSynth.hpp"

/// A sample for the Sampler to play: one or two channels of audio at their own rate. The
/// Audio Unit owns the memory and keeps it alive until the Sampler has stopped using it.
struct SamplerSample {
  float const *left;
  /// Null for a mono sample.
  float const *right;
  int64_t frames;
  double sampleRate;
};

/// One of the Sampler's zones: a sample and where it plays (see `SamplerZoneSettings`).
struct SamplerKeyZone {
  SamplerSample sample;
  int lowKey, highKey;
  int lowVelocity, highVelocity;
  /// The key that plays the sample at its own pitch, or −1 to follow the Root Note knob.
  int root;
  /// Cents.
  float tune;
  /// Linear.
  float gain;
  /// −1 (left) to 1 (right).
  float pan;
};

/// The Sampler's zones. The Audio Unit owns the memory (and the samples') and keeps it alive
/// until the Sampler has stopped using it.
struct SamplerKeymap {
  SamplerKeyZone const *zones;
  int count;
};

namespace ongaku {

/// A sampler in the spirit of Logic's Sampler: zones of samples mapped across the keyboard
/// and velocities (a single sample is one zone over everything), each pitched from its
/// root note, between start and end markers, with an optional loop (with a crossfade),
/// then a resonant filter, envelopes, an LFO and glide. Every zone a note falls in plays.
class Sampler {
public:
  static constexpr AUParameterAddress firstAddress = splStart;
  static constexpr int parameterCount = splGain - splStart + 1;
  static constexpr int voiceCount = 16;
  /// How many voices' playheads are published for the waveform display.
  static constexpr int shownPlayheads = OngakuMeterCount - OngakuMeterFirstPlayhead;

  Sampler() { mTargets.fill(0); }

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

  /// Replaces the zones (or removes them, with null). Called from any thread; the render
  /// thread picks them up at its next buffer and stops the notes playing samples that are
  /// no longer in a zone (their memory may go away). Notes playing samples still there
  /// carry on.
  void setKeymap(SamplerKeymap const *keymap) { __atomic_store_n(&mPending, keymap, __ATOMIC_RELEASE); }

  /// The sample the window is showing (by its first channel), whose playheads `playhead`
  /// reports; null for every voice's.
  void setShownSample(float const *left) { __atomic_store_n(&mShown, left, __ATOMIC_RELAXED); }

  /// Where a voice playing the shown sample is in it (0–1 of its length), or −1 for none,
  /// for drawing playheads on the waveform.
  float playhead(int index) const {
    float const *shown = __atomic_load_n(&mShown, __ATOMIC_RELAXED);
    int found = 0;
    for (auto const &voice : mVoices) {
      if (!voice.amp.isActive() || (shown != nullptr && voice.sample.left != shown)) continue;
      if (found++ == index) return voice.shownPosition;
    }
    return -1;
  }

  // MARK: MIDI

  void midi(uint8_t status, uint8_t data1, uint8_t data2) {
    // Notes at the start of a buffer arrive before it renders, so take up new zones now.
    takeNewKeymap();
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
    takeNewKeymap();
    if (mKeymap == nullptr) return;

    updateSettings();
    float *left = outputs[0];
    float *right = outputs.size() > 1 ? outputs[1] : nullptr;
    for (auto &voice : mVoices) {
      if (voice.amp.isActive()) voice.region = currentRegion(voice.sample);
    }
    for (int start = 0; start < frameCount; start += controlInterval) {
      int frames = std::min(controlInterval, frameCount - start);
      float lfo = nextLFO(frames);
      for (auto &voice : mVoices) {
        if (!voice.amp.isActive()) continue;
        renderVoice(voice, left + start, right ? right + start : nullptr, frames, lfo);
      }
    }
    float gain = std::pow(10.0f, value(splGain) / 20);
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

  /// Switches to zones given by `setKeymap`, stopping the notes playing samples no longer
  /// in any zone (whose memory may go away). On the render thread.
  void takeNewKeymap() {
    SamplerKeymap const *keymap = __atomic_load_n(&mPending, __ATOMIC_ACQUIRE);
    if (keymap == mKeymap) return;
    mKeymap = keymap;
    if (keymap == nullptr) {
      reset();
      return;
    }
    for (auto &voice : mVoices) {
      if (!voice.amp.isActive()) continue;
      bool isKept = false;
      for (int index = 0; index < keymap->count && !isKept; ++index) {
        isKept = keymap->zones[index].sample.left == voice.sample.left;
      }
      if (!isKept) {
        voice.amp.reset();
        voice.filterEnvelope.reset();
        voice.note = -1;
        voice.shownPosition = -1;
      }
    }
  }

  /// The markers in sample frames, and the loop in the voice's playing order.
  struct Region {
    double start = 0, end = 0;
    bool reverse = false;
    /// The loop, as distances from the start of play (0 … end − start).
    double loopStart = 0, loopEnd = 0;
    /// 0 off, 1 forward, 2 alternate.
    int loop = 0;
    double crossfade = 0;
  };

  struct Voice {
    int note = -1;
    float velocity = 0;
    float pitch = 60;  // where the pitch has glided to, in semitones
    /// Where it is between the start and end markers, in sample frames, counted from the
    /// end it starts at (so a reversed sample counts back from the end marker).
    double position = 0;
    /// 1 forward, −1 on the way back of an alternating loop.
    int direction = 1;
    bool isLooping = false;
    float shownPosition = -1;
    Envelope amp, filterEnvelope;
    LadderFilter filter, filterRight;
    bool isHeld = false;
    bool isSustained = false;
    uint64_t age = 0;
    /// The zone it's playing: its sample, and its root (−1 for the knob's), tuning, level
    /// and pan, taken when the note starts.
    SamplerSample sample {};
    int root = -1;
    float tune = 0;
    float gain = 1;
    float panLeft = 1, panRight = 1;
    Region region;
  };

  float value(AUParameterAddress address) const { return mTargets[address - firstAddress]; }
  bool isOn(AUParameterAddress address) const { return value(address) >= 0.5f; }
  bool isMono() const { return isOn(splVoices); }
  bool isOneShot() const { return isOn(splPlayMode); }

  Region currentRegion(SamplerSample const &sample) const {
    Region region;
    double last = double(std::max<int64_t>(1, sample.frames - 1));
    double start = std::clamp(double(value(splStart)) / 100, 0.0, 1.0) * last;
    double end = std::clamp(double(value(splEnd)) / 100, 0.0, 1.0) * last;
    if (end < start) std::swap(start, end);
    if (end - start < 2) end = std::min(last, start + 2);
    region.start = start;
    region.end = end;
    region.reverse = isOn(splReverse);

    // The loop markers, kept inside the start and end markers.
    double loopStart = std::clamp(double(value(splLoopStart)) / 100 * last, start, end);
    double loopEnd = std::clamp(double(value(splLoopEnd)) / 100 * last, start, end);
    if (loopEnd < loopStart) std::swap(loopStart, loopEnd);
    // Measured in playing order: a reversed sample plays from the end marker back.
    if (region.reverse) {
      region.loopStart = end - loopEnd;
      region.loopEnd = end - loopStart;
    } else {
      region.loopStart = loopStart - start;
      region.loopEnd = loopEnd - start;
    }
    // One Shot plays the sample through once, so it never loops.
    int loop = std::clamp(int(std::lround(value(splLoop))), 0, 2);
    region.loop = !isOneShot() && region.loopEnd - region.loopStart >= 16 ? loop : 0;
    // The crossfade blends the end of the loop into what comes just before its start, so it
    // can be no longer than that, nor than half the loop.
    double crossfade = double(value(splCrossfade)) / 1000 * sample.sampleRate;
    region.crossfade = std::clamp(crossfade, 0.0, std::min(region.loopStart, (region.loopEnd - region.loopStart) / 2));
    return region;
  }

  void updateSettings() {
    for (auto &voice : mVoices) {
      voice.amp.set(value(splAmpAttack) / 1000, value(splAmpDecay) / 1000, value(splAmpSustain) / 100,
                    value(splAmpRelease) / 1000, mSampleRate);
      voice.filterEnvelope.set(value(splFilterAttack) / 1000, value(splFilterDecay) / 1000,
                               value(splFilterSustain) / 100, value(splFilterRelease) / 1000, mSampleRate);
    }
  }

  /// Gives a voice a zone to play.
  static void assign(Voice &voice, SamplerKeyZone const &zone) {
    voice.sample = zone.sample;
    voice.root = zone.root;
    voice.tune = zone.tune;
    voice.gain = zone.gain;
    float pan = std::clamp(zone.pan, -1.0f, 1.0f);
    voice.panLeft = std::min(1.0f, 1 - pan);
    voice.panRight = std::min(1.0f, 1 + pan);
    voice.region = Region();
  }

  static bool plays(SamplerKeyZone const &zone, int note, int velocity) {
    return zone.sample.frames >= 2 && note >= zone.lowKey && note <= zone.highKey && velocity >= zone.lowVelocity &&
           velocity <= zone.highVelocity;
  }

  void start(Voice &voice) {
    voice.position = 0;
    voice.direction = 1;
    voice.isLooping = false;
    voice.amp.start();
    voice.filterEnvelope.start();
  }

  void noteOn(int note, int velocity) {
    if (mKeymap == nullptr) return;
    float level = velocity / 127.0f;
    if (isMono()) {
      // One note at a time, from the first zone it falls in.
      SamplerKeyZone const *zone = nullptr;
      for (int index = 0; index < mKeymap->count && !zone; ++index) {
        if (plays(mKeymap->zones[index], note, velocity)) zone = &mKeymap->zones[index];
      }
      if (!zone) return;
      Voice &voice = mVoices[0];
      // Gliding into another zone's sample starts it afresh.
      bool legato = voice.amp.isActive() && !voice.amp.isReleasing() && mHeldCount > 0 && voice.sample.left == zone->sample.left;
      pushHeld(note);
      voice.note = note;
      voice.velocity = level;
      voice.isHeld = true;
      voice.isSustained = false;
      if (!legato) {
        if (value(splGlide) <= 0 || !voice.amp.isActive()) voice.pitch = float(note);
        assign(voice, *zone);
        voice.filter.reset();
        voice.filterRight.reset();
        start(voice);
      }
      return;
    }
    // A voice for every zone the note falls in (layers).
    bool played = false;
    for (int index = 0; index < mKeymap->count; ++index) {
      SamplerKeyZone const &zone = mKeymap->zones[index];
      if (!plays(zone, note, velocity)) continue;
      Voice &voice = chooseVoice(note, zone);
      voice.filter.reset();
      voice.filterRight.reset();
      voice.pitch = value(splGlide) > 0 && mLastNote >= 0 ? float(mLastNote) : float(note);
      voice.note = note;
      voice.velocity = level;
      voice.isHeld = true;
      voice.isSustained = false;
      voice.age = ++mClock;
      assign(voice, zone);
      start(voice);
      played = true;
    }
    if (played) mLastNote = note;
  }

  /// The voice already playing this note from this zone's sample, a free voice, the
  /// quietest releasing one, or the oldest.
  Voice &chooseVoice(int note, SamplerKeyZone const &zone) {
    Voice *chosen = nullptr;
    for (auto &voice : mVoices) {
      if (voice.note == note && voice.amp.isActive() && voice.sample.left == zone.sample.left) chosen = &voice;
    }
    if (!chosen) for (auto &voice : mVoices) if (!voice.amp.isActive()) { chosen = &voice; break; }
    if (!chosen) {
      for (auto &voice : mVoices) {
        if (voice.amp.isReleasing() && (!chosen || voice.amp.level() < chosen->amp.level())) chosen = &voice;
      }
    }
    if (!chosen) {
      chosen = &*std::min_element(mVoices.begin(), mVoices.end(), [](Voice const &a, Voice const &b) { return a.age < b.age; });
    }
    return *chosen;
  }

  void release(Voice &voice) {
    // One Shot plays the sample to its end, whatever the key does.
    if (isOneShot()) return;
    voice.amp.release();
    voice.filterEnvelope.release();
  }

  void noteOff(int note) {
    if (isMono()) {
      removeHeld(note);
      Voice &voice = mVoices[0];
      if (voice.note != note) return;
      if (mHeldCount > 0) {
        voice.note = mHeld[mHeldCount - 1];
        return;
      }
      voice.isHeld = false;
      if (mSustainPedal) { voice.isSustained = true; } else { release(voice); }
      return;
    }
    for (auto &voice : mVoices) {
      if (voice.note != note || !voice.isHeld) continue;
      voice.isHeld = false;
      if (mSustainPedal) { voice.isSustained = true; } else { release(voice); }
    }
  }

  void setSustain(bool isDown) {
    mSustainPedal = isDown;
    if (isDown) return;
    for (auto &voice : mVoices) {
      if (!voice.isSustained) continue;
      voice.isSustained = false;
      release(voice);
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

  float nextLFO(int frames) {
    float rate = std::max(0.01f, value(splLfoRate));
    mLfoPhase += rate * float(frames) / mSampleRate;
    if (mLfoPhase >= 1) {
      mLfoPhase -= std::floor(mLfoPhase);
      mRandom = nextNoise();
    }
    switch (std::clamp(int(std::lround(value(splLfoWave))), 0, 2)) {
      case 0: return 4 * std::abs(mLfoPhase - 0.5f) - 1;
      case 1: return mLfoPhase < 0.5f ? 1.0f : -1.0f;
      default: return mRandom;
    }
  }

  float nextNoise() {
    mNoiseState ^= mNoiseState << 13;
    mNoiseState ^= mNoiseState >> 17;
    mNoiseState ^= mNoiseState << 5;
    return float(mNoiseState) / float(UINT32_MAX) * 2 - 1;
  }

  /// One channel of the sample at a fractional frame, by cubic (Hermite) interpolation.
  static float read(float const *channel, int64_t frames, double index) {
    int64_t i = int64_t(std::floor(index));
    float t = float(index - double(i));
    auto at = [&](int64_t n) { return channel[std::clamp<int64_t>(n, 0, frames - 1)]; };
    float y0 = at(i - 1), y1 = at(i), y2 = at(i + 1), y3 = at(i + 2);
    float c1 = 0.5f * (y2 - y0);
    float c2 = y0 - 2.5f * y1 + 2 * y2 - 0.5f * y3;
    float c3 = 0.5f * (y3 - y0) + 1.5f * (y1 - y2);
    return ((c3 * t + c2) * t + c1) * t + y1;
  }

  /// The sample at a distance into the region (in playing order), both channels.
  static void readAt(SamplerSample const &sample, Region const &region, double distance, float &left, float &right) {
    double index = region.reverse ? region.end - distance : region.start + distance;
    left = read(sample.left, sample.frames, index);
    right = sample.right ? read(sample.right, sample.frames, index) : left;
  }

  void renderVoice(Voice &voice, float *left, float *right, int frames, float lfo) {
    Region const &region = voice.region;
    SamplerSample const &sample = voice.sample;
    // Glide toward the note over the glide time.
    float glideSeconds = value(splGlide) / 1000;
    float glide = glideSeconds > 0 ? 1 - std::exp(-float(frames) / (glideSeconds * mSampleRate / 4.6f)) : 1;
    voice.pitch += (float(voice.note) - voice.pitch) * glide;

    // Pitch: from the root note (if it follows the keys), transposed and tuned, with bend
    // and vibrato (the mod wheel adds more).
    float root = voice.root >= 0 ? float(voice.root) : std::round(value(splRoot));
    float keys = isOn(splFollowKeys) ? voice.pitch - root : 0;
    float vibrato = (value(splLfoPitch) + mModWheel * 50) / 100 * lfo;
    float semitones = keys + std::round(value(splTranspose)) + (value(splTune) + voice.tune) / 100 + mPitchBend * value(splBendRange) +
                      vibrato;
    double step = std::exp2(double(semitones) / 12) * sample.sampleRate / mSampleRate;

    bool filterOn = isOn(splFilterOn);
    if (filterOn) {
      float envelopeOctaves = value(splFilterEnv) / 100 * 6 * voice.filterEnvelope.level();
      float keyOctaves = value(splKeyTrack) / 100 * (voice.pitch - 60) / 12;
      float lfoOctaves = value(splLfoFilter) / 100 * 3 * lfo;
      float cutoff = value(splCutoff) * std::exp2(envelopeOctaves + keyOctaves + lfoOctaves);
      voice.filter.set(cutoff, value(splResonance) / 100, mSampleRate);
      voice.filterRight.set(cutoff, value(splResonance) / 100, mSampleRate);
    }
    float velocityGain = (1 - value(splVelocity) / 100 * (1 - voice.velocity * voice.velocity)) * voice.gain;
    float tremolo = 1 - value(splLfoAmp) / 100 * (0.5f + 0.5f * lfo);
    double length = region.end - region.start;
    double loopLength = region.loopEnd - region.loopStart;

    for (int i = 0; i < frames; ++i) {
      float sampleLeft, sampleRight;
      readAt(sample, region, voice.position, sampleLeft, sampleRight);
      // Approaching the end of a forward loop, fade into the audio before the loop start,
      // which is what follows when it jumps back.
      if (region.loop == 1 && region.crossfade > 0 && voice.position > region.loopEnd - region.crossfade &&
          voice.position < region.loopEnd) {
        float otherLeft, otherRight;
        readAt(sample, region, voice.position - loopLength, otherLeft, otherRight);
        float t = float((voice.position - (region.loopEnd - region.crossfade)) / region.crossfade);
        float out = std::sqrt(1 - t), in = std::sqrt(t);
        sampleLeft = sampleLeft * out + otherLeft * in;
        sampleRight = sampleRight * out + otherRight * in;
      }
      // A short fade at the end marker, so a sample cut short doesn't click.
      float edge = region.loop == 0 ? float(std::clamp((length - voice.position) / (64 * step), 0.0, 1.0)) : 1;

      voice.filterEnvelope.next();
      float amplitude = voice.amp.next() * velocityGain * tremolo * edge;
      if (filterOn) {
        sampleLeft = voice.filter.process(sampleLeft);
        sampleRight = voice.filterRight.process(sampleRight);
      }
      left[i] += sampleLeft * amplitude * voice.panLeft;
      if (right) right[i] += sampleRight * amplitude * voice.panRight;

      // Move on, looping once the loop is reached.
      voice.position += step * voice.direction;
      if (region.loop == 1 && voice.position >= region.loopEnd) {
        voice.position = region.loopStart + std::fmod(voice.position - region.loopStart, loopLength);
      } else if (region.loop == 2) {
        if (voice.direction > 0 && voice.position >= region.loopEnd) {
          voice.position = std::max(region.loopStart, 2 * region.loopEnd - voice.position);
          voice.direction = -1;
        } else if (voice.direction < 0 && voice.position <= region.loopStart) {
          voice.position = std::min(region.loopEnd, 2 * region.loopStart - voice.position);
          voice.direction = 1;
        }
      }
      if (voice.position >= length) {
        voice.amp.reset();
        voice.filterEnvelope.reset();
        break;
      }
    }
    if (voice.amp.isActive()) {
      double index = region.reverse ? region.end - voice.position : region.start + voice.position;
      voice.shownPosition = float(index / double(sample.frames - 1));
    } else {
      voice.note = -1;
      voice.shownPosition = -1;
    }
  }

  std::array<float, size_t(parameterCount)> mTargets;
  std::array<Voice, voiceCount> mVoices;
  SamplerKeymap const *mPending = nullptr;
  SamplerKeymap const *mKeymap = nullptr;
  float const *mShown = nullptr;
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
  uint32_t mNoiseState = 0x9E3779B9;
};

}  // namespace ongaku
