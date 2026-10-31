//
//  SessionDrummer.hpp
//  OngakuEffects
//

#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <span>

#include "DrumMachine.hpp"
#include "OngakuEffectsParameterAddresses.h"

/// One hit of the drummer's part: when (in quarter notes from the song's start), which
/// General MIDI drum, and how hard.
struct DrummerHit {
  double beat;
  uint8_t note;
  uint8_t velocity;
};

/// The drummer's whole part, once through. Hits are sorted by beat. After `length` it
/// carries on from `loopStart` (0 when the song repeats; the last section's start when it
/// doesn't). Made and freed on the main thread; the render thread only reads it.
struct DrummerPart {
  double length;
  double loopStart;
  int32_t count;
  DrummerHit const *hits;
};

/// Where the song is, from the host (or the preview clock).
struct DrummerClock {
  double tempo = 120;
  double beat = 0;
  bool playing = false;
  int32_t beatsPerBar = 4;
  int32_t beatUnit = 4;
};

namespace ongaku {

/// The Session Drummer: plays its part in time with the host's song position, on the
/// Drum Machine's kit and/or as MIDI out to another instrument.
class SessionDrummer {
public:
  static constexpr AUParameterAddress firstAddress = sdrVolume;
  static constexpr int parameterCount = sdrParameterCount;
  /// The most hits that can sound in one render (plenty for a drum part).
  static constexpr int maximumHitsPerRender = 128;

  SessionDrummer() {
    mValues.fill(0);
    mValues[sdrPlaysKit - firstAddress] = 1;
    mValues[sdrSendsMIDI - firstAddress] = 1;
  }

  void setParameter(AUParameterAddress address, float value) {
    if (address >= firstAddress && address < firstAddress + parameterCount) {
      mValues[address - firstAddress] = value;
    } else {
      // The kit's own settings.
      mDrums.setParameter(address, value);
    }
  }

  float parameter(AUParameterAddress address) const {
    if (address >= firstAddress && address < firstAddress + parameterCount) return mValues[address - firstAddress];
    return mDrums.parameter(address);
  }

  void initialize(double sampleRate) {
    mSampleRate = sampleRate;
    mDrums.initialize(sampleRate);
    mPreviewBeat = 0;
    mPendingOffCount = 0;
  }

  /// Apple's sampler, loaded with one of the system's General MIDI drum kits, to play
  /// instead of the Drum Machine when Kit isn't 0. Made, loaded and disposed of on another
  /// thread; the old one must outlive any render in progress (the Audio Unit waits).
  void setAppleKit(AudioUnit unit) { __atomic_store_n(&mAppleKit, unit, __ATOMIC_RELEASE); }

  /// Hands over a new part (or none). The old one must stay alive until the render thread
  /// has moved on (the Audio Unit frees it a couple of seconds later).
  void setPart(DrummerPart const *part) { __atomic_store_n(&mPart, part, __ATOMIC_RELEASE); }

  void setMIDIOutput(AUMIDIOutputEventBlock block) { mMIDIOutput = block; }

  /// Notes played into the plug-in play its kit, so it can be played by hand too.
  void midi(uint8_t status, uint8_t data1, uint8_t data2) { mDrums.midi(status, playable(data1), data2); }

  /// How loud each pad is sounding (0–1), for lighting the kit: the Drum Machine's voices,
  /// or recent hits on an Apple kit.
  float activity(int pad) const { return std::max(mDrums.activity(pad), mHitLevels[size_t(pad)]); }

  /// Where the part is now (quarter notes into it), for the window; negative when stopped.
  double partPosition() const { return mLastPartPosition; }

  /// Renders `frameCount` frames starting at `startTime`, with the song at `clock` at the
  /// first of them.
  void process(std::span<float *> outputs, int frameCount, AUEventSampleTime startTime, DrummerClock clock) {
    for (float *channel : outputs) std::fill_n(channel, frameCount, 0.0f);
    sendPendingOffs(startTime, frameCount);

    bool previewing = !clock.playing && value(sdrPreview) >= 0.5f;
    if (previewing) {
      clock.beat = mPreviewBeat;
      clock.playing = true;
    } else {
      mPreviewBeat = 0;
    }
    double beatsPerSample = std::max(clock.tempo, 1.0) / 60.0 / mSampleRate;
    if (previewing) mPreviewBeat += beatsPerSample * frameCount;

    // The hits in this render, by sample.
    std::array<std::pair<int, DrummerHit>, maximumHitsPerRender> due;
    int dueCount = 0;
    DrummerPart const *part = __atomic_load_n(&mPart, __ATOMIC_ACQUIRE);
    mLastPartPosition = -1;
    if (clock.playing && part != nullptr && part->count > 0 && part->length > 0 && clock.beat >= -1e-9) {
      double start = map(*part, std::max(0.0, clock.beat));
      double span = beatsPerSample * frameCount;
      mLastPartPosition = start;
      auto collect = [&](double from, double to, double offsetBeats) {
        DrummerHit const *first = std::lower_bound(part->hits, part->hits + part->count, from,
          [](DrummerHit const &hit, double beat) { return hit.beat < beat; });
        for (DrummerHit const *hit = first; hit < part->hits + part->count && hit->beat < to; ++hit) {
          if (dueCount == maximumHitsPerRender) return;
          int frame = int((hit->beat - from + offsetBeats) / beatsPerSample);
          due[size_t(dueCount++)] = {std::clamp(frame, 0, frameCount - 1), *hit};
        }
      };
      if (start + span <= part->length) {
        collect(start, start + span, 0);
      } else {
        // Wraps round: the end of the part, then from where it carries on.
        collect(start, part->length, 0);
        collect(part->loopStart, part->loopStart + (start + span - part->length), part->length - start);
      }
    }

    bool playsKit = value(sdrPlaysKit) >= 0.5f, sendsMIDI = value(sdrSendsMIDI) >= 0.5f;
    for (float &level : mHitLevels) level *= std::exp(-float(frameCount) / float(mSampleRate * 0.12));

    // An Apple kit: every hit at its sample, then the whole render from the sampler.
    AudioUnit appleKit = value(sdrKit) >= 0.5f ? __atomic_load_n(&mAppleKit, __ATOMIC_ACQUIRE) : nullptr;
    if (appleKit != nullptr) {
      for (int index = 0; index < dueCount; ++index) {
        auto [frame, hit] = due[size_t(index)];
        if (playsKit) {
          MusicDeviceMIDIEvent(appleKit, 0x99, hit.note, hit.velocity, UInt32(frame));
          light(hit.note, hit.velocity);
        }
        if (sendsMIDI) sendNote(startTime + frame, hit.note, hit.velocity);
      }
      renderAppleKit(appleKit, outputs, frameCount, startTime, playsKit);
      return;
    }

    int rendered = 0;
    for (int index = 0; index < dueCount; ++index) {
      auto [frame, hit] = due[size_t(index)];
      if (frame > rendered) {
        renderKit(outputs, rendered, frame - rendered, playsKit);
        rendered = frame;
      }
      if (playsKit) mDrums.midi(0x90, playable(hit.note), hit.velocity);
      if (playsKit) light(hit.note, hit.velocity);
      if (sendsMIDI) sendNote(startTime + frame, hit.note, hit.velocity);
    }
    if (rendered < frameCount) renderKit(outputs, rendered, frameCount - rendered, playsKit);
  }

private:
  /// The part's position for a song position (quarter notes), allowing for repeats.
  static double map(DrummerPart const &part, double beat) {
    if (beat < part.length) return beat;
    double loop = part.length - part.loopStart;
    if (loop <= 0) return part.length;
    return part.loopStart + std::fmod(beat - part.length, loop);
  }

  /// The Drum Machine has no ride or pedal hat: the open and closed hats stand in.
  static uint8_t playable(uint8_t note) {
    switch (note) {
      case 51: case 59: case 53: return 46;
      case 44: return 42;
      case 57: case 52: case 55: return 49;
      default: return note;
    }
  }

  /// The Drum Machine pad a General MIDI drum lights.
  void light(uint8_t note, uint8_t velocity) {
    uint8_t pad = playable(note);
    for (int index = 0; index < DrumMachine::padCount; ++index) {
      if (DrumMachine::notes[index] == pad) mHitLevels[size_t(index)] = std::max(mHitLevels[size_t(index)], velocity / 127.0f);
    }
  }

  /// Renders Apple's sampler into the outputs (stereo or mono), at the kit volume.
  void renderAppleKit(AudioUnit unit, std::span<float *> outputs, int frameCount, AUEventSampleTime startTime, bool playsKit) {
    if (outputs.empty() || frameCount <= 0) return;
    struct { AudioBufferList list; AudioBuffer second; } buffers {};
    UInt32 channels = UInt32(std::min<size_t>(outputs.size(), 2));
    buffers.list.mNumberBuffers = channels;
    for (UInt32 channel = 0; channel < channels; ++channel) {
      buffers.list.mBuffers[channel] = AudioBuffer {1, UInt32(frameCount * int(sizeof(float))), outputs[channel]};
    }
    AudioTimeStamp timestamp {};
    timestamp.mSampleTime = Float64(startTime);
    timestamp.mFlags = kAudioTimeStampSampleTimeValid;
    AudioUnitRenderActionFlags flags = 0;
    if (AudioUnitRender(unit, &flags, &timestamp, 0, UInt32(frameCount), &buffers.list) != noErr) {
      for (float *channel : outputs) std::fill_n(channel, frameCount, 0.0f);
      return;
    }
    float gain = playsKit ? std::pow(10.0f, value(sdrVolume) / 20) : 0;
    for (UInt32 channel = 0; channel < channels; ++channel) {
      for (int i = 0; i < frameCount; ++i) outputs[channel][i] *= gain;
    }
    // A mono output gets the left channel; a third channel and beyond stay silent.
    for (size_t channel = channels; channel < outputs.size(); ++channel) std::fill_n(outputs[channel], frameCount, 0.0f);
  }

  void renderKit(std::span<float *> outputs, int offset, int frames, bool playsKit) {
    if (frames <= 0) return;
    std::array<float *, 2> shifted {};
    size_t count = std::min<size_t>(outputs.size(), 2);
    for (size_t channel = 0; channel < count; ++channel) shifted[channel] = outputs[channel] + offset;
    mDrums.process(std::span<float *>(shifted.data(), count), frames);
    float gain = playsKit ? std::pow(10.0f, value(sdrVolume) / 20) : 0;
    for (size_t channel = 0; channel < count; ++channel) {
      for (int i = 0; i < frames; ++i) shifted[channel][i] *= gain;
    }
  }

  void sendNote(AUEventSampleTime time, uint8_t note, uint8_t velocity) {
    if (mMIDIOutput == nullptr) return;
    uint8_t on[3] = {0x99, note, velocity};
    mMIDIOutput(time, 0, 3, on);
    // Its note-off a moment later (drum samplers mostly ignore it, but other instruments
    // want one).
    if (mPendingOffCount < int(mPendingOffs.size())) {
      mPendingOffs[size_t(mPendingOffCount++)] = {time + AUEventSampleTime(mSampleRate * 0.05), note};
    }
  }

  void sendPendingOffs(AUEventSampleTime start, int frameCount) {
    if (mPendingOffCount == 0) return;
    AUEventSampleTime end = start + frameCount;
    int kept = 0;
    for (int index = 0; index < mPendingOffCount; ++index) {
      auto off = mPendingOffs[size_t(index)];
      if (off.first < end) {
        if (mMIDIOutput != nullptr) {
          uint8_t bytes[3] = {0x89, off.second, 0};
          mMIDIOutput(std::max(off.first, start), 0, 3, bytes);
        }
      } else {
        mPendingOffs[size_t(kept++)] = off;
      }
    }
    mPendingOffCount = kept;
  }

  float value(AUParameterAddress address) const { return mValues[address - firstAddress]; }

  DrumMachine mDrums;
  std::array<float, parameterCount> mValues {};
  double mSampleRate = 44100;
  double mPreviewBeat = 0;
  double mLastPartPosition = -1;
  DrummerPart const *mPart = nullptr;
  AudioUnit mAppleKit = nullptr;
  std::array<float, DrumMachine::padCount> mHitLevels {};
  AUMIDIOutputEventBlock mMIDIOutput = nullptr;
  std::array<std::pair<AUEventSampleTime, uint8_t>, 256> mPendingOffs {};
  int mPendingOffCount = 0;
};

}  // namespace ongaku
