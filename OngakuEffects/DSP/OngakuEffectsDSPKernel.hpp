//
//  OngakuEffectsDSPKernel.hpp
//  OngakuEffects
//

#pragma once

#import <AudioToolbox/AudioToolbox.h>
#import <algorithm>
#import <span>
#import <array>

#import "OngakuEffectsParameterAddresses.h"
#import "ChannelEQ.hpp"
#import "Compressor.hpp"
#import "Reverb.hpp"
#import "Delay.hpp"
#import "RetroSynth.hpp"
#import "DrumMachine.hpp"
#import "Sampler.hpp"
#import "Dynamics.hpp"
#import "Colour.hpp"
#import "ConvolutionReverb.hpp"
#import "VocalStrip.hpp"
#import "SessionDrummer.hpp"
#import "Mastering.hpp"

/// How many samples have been written to an analyser tap (see `setAnalyserTap`), read
/// safely from another thread.
inline uint32_t OngakuAnalyserWritten(uint32_t const *written) {
  return __atomic_load_n(written, __ATOMIC_ACQUIRE);
}

/// A meter's latest value (see `setMeters`), read safely from another thread.
inline float OngakuMeterValue(float const *meters, OngakuMeter meter) {
  float value;
  __atomic_load(meters + meter, &value, __ATOMIC_RELAXED);
  return value;
}

/// The Compressor's output level for an input level (both dB), for drawing its curve.
inline float OngakuCompressorCurve(float input, float threshold, float ratio, float knee) {
  return ongaku::Compressor::curve(input, threshold, ratio, knee);
}

/// The Saturation's curve (level-matched) at an input, for drawing it.
inline float OngakuSaturationCurve(float input, float drive, int type) {
  return ongaku::Saturation::curve(input, drive, type);
}

/// The Reverb's wet tone (its low and high cuts) in dB at a frequency.
inline float OngakuReverbTone(float lowCut, float highCut, double sampleRate, float frequency) {
  return ongaku::Reverb::toneDecibels(lowCut, highCut, sampleRate, frequency);
}

/// The Channel EQ's gain in decibels at each frequency, from its parameters (indexed by
/// address), for drawing its curve.
inline void OngakuChannelEQResponse(
  float const *parameters, double sampleRate, float const *frequencies, float *decibels, int count) {
  ongaku::ChannelEQ::response(parameters, sampleRate, frequencies, decibels, count);
}

/// Mastering's EQ curve for the window: `gains` are the five bands' settings.
inline void OngakuMasteringEQResponse(
  int character, float eqAmount, float const *gains, double sampleRate, float const *frequencies, float *decibels, int count) {
  ongaku::Mastering::response(character, eqAmount, gains, sampleRate, frequencies, decibels, count);
}

/*
 OngakuEffectsDSPKernel
 Runs whichever effect the Audio Unit was created as. As a non-ObjC class, this is safe to
 use from the render thread: it never allocates or locks there.
 */
class OngakuEffectsDSPKernel {
public:
  void setKind(OngakuEffectKind kind) { mKind = kind; }

  void initialize(int inputChannelCount, int outputChannelCount, double inSampleRate) {
    mSampleRate = inSampleRate;
    switch (mKind) {
      case OngakuEffectKindChannelEQ: mChannelEQ.initialize(outputChannelCount, inSampleRate); break;
      case OngakuEffectKindCompressor: mCompressor.initialize(outputChannelCount, inSampleRate); break;
      case OngakuEffectKindReverb: mReverb.initialize(outputChannelCount, inSampleRate); break;
      case OngakuEffectKindDelay: mDelay.initialize(outputChannelCount, inSampleRate); break;
      case OngakuEffectKindRetroSynth: mSynth.initialize(inSampleRate); break;
      case OngakuEffectKindDrumMachine: mDrums.initialize(inSampleRate); break;
      case OngakuEffectKindSampler: mSampler.initialize(inSampleRate); break;
      case OngakuEffectKindNoiseGate: mGate.initialize(outputChannelCount, inSampleRate); break;
      case OngakuEffectKindTransientShaper: mShaper.initialize(outputChannelCount, inSampleRate); break;
      case OngakuEffectKindMaximizer: mMaximizer.initialize(outputChannelCount, inSampleRate); break;
      case OngakuEffectKindDeEsser: mDeEsser.initialize(outputChannelCount, inSampleRate); break;
      case OngakuEffectKindSaturation: mSaturation.initialize(outputChannelCount, inSampleRate); break;
      case OngakuEffectKindDoubler: mDoubler.initialize(outputChannelCount, inSampleRate); break;
      case OngakuEffectKindConvolutionReverb: mConvolution.initialize(outputChannelCount, inSampleRate); break;
      case OngakuEffectKindVocalStrip: mVocalStrip.initialize(outputChannelCount, inSampleRate); break;
      case OngakuEffectKindSessionDrummer: mDrummer.initialize(inSampleRate); break;
      case OngakuEffectKindMastering: mMastering.initialize(outputChannelCount, inSampleRate); break;
    }
  }

  void deInitialize() {}

  // MARK: - Bypass
  bool isBypassed() { return mBypassed; }

  void setBypass(bool shouldBypass) { mBypassed = shouldBypass; }

  // MARK: - Parameter Getter / Setter
  void setParameter(AUParameterAddress address, AUValue value) {
    switch (mKind) {
      case OngakuEffectKindChannelEQ: mChannelEQ.setParameter(address, value); break;
      case OngakuEffectKindCompressor: mCompressor.setParameter(address, value); break;
      case OngakuEffectKindReverb: mReverb.setParameter(address, value); break;
      case OngakuEffectKindDelay: mDelay.setParameter(address, value); break;
      case OngakuEffectKindRetroSynth: mSynth.setParameter(address, value); break;
      case OngakuEffectKindDrumMachine: mDrums.setParameter(address, value); break;
      case OngakuEffectKindSampler: mSampler.setParameter(address, value); break;
      case OngakuEffectKindNoiseGate: mGate.setParameter(address, value); break;
      case OngakuEffectKindTransientShaper: mShaper.setParameter(address, value); break;
      case OngakuEffectKindMaximizer: mMaximizer.setParameter(address, value); break;
      case OngakuEffectKindDeEsser: mDeEsser.setParameter(address, value); break;
      case OngakuEffectKindSaturation: mSaturation.setParameter(address, value); break;
      case OngakuEffectKindDoubler: mDoubler.setParameter(address, value); break;
      case OngakuEffectKindConvolutionReverb: mConvolution.setParameter(address, value); break;
      case OngakuEffectKindVocalStrip: mVocalStrip.setParameter(address, value); break;
      case OngakuEffectKindSessionDrummer: mDrummer.setParameter(address, value); break;
      case OngakuEffectKindMastering: mMastering.setParameter(address, value); break;
    }
  }

  AUValue getParameter(AUParameterAddress address) {
    // Returns the setting, not where a glide toward it has got to.
    switch (mKind) {
      case OngakuEffectKindChannelEQ: return mChannelEQ.parameter(address);
      case OngakuEffectKindCompressor: return mCompressor.parameter(address);
      case OngakuEffectKindReverb: return mReverb.parameter(address);
      case OngakuEffectKindDelay: return mDelay.parameter(address);
      case OngakuEffectKindRetroSynth: return mSynth.parameter(address);
      case OngakuEffectKindDrumMachine: return mDrums.parameter(address);
      case OngakuEffectKindSampler: return mSampler.parameter(address);
      case OngakuEffectKindNoiseGate: return mGate.parameter(address);
      case OngakuEffectKindTransientShaper: return mShaper.parameter(address);
      case OngakuEffectKindMaximizer: return mMaximizer.parameter(address);
      case OngakuEffectKindDeEsser: return mDeEsser.parameter(address);
      case OngakuEffectKindSaturation: return mSaturation.parameter(address);
      case OngakuEffectKindDoubler: return mDoubler.parameter(address);
      case OngakuEffectKindConvolutionReverb: return mConvolution.parameter(address);
      case OngakuEffectKindVocalStrip: return mVocalStrip.parameter(address);
      case OngakuEffectKindSessionDrummer: return mDrummer.parameter(address);
      case OngakuEffectKindMastering: return mMastering.parameter(address);
    }
    return 0;
  }

  /// How long the effect keeps sounding after its input stops, in seconds.
  double tailSeconds() const {
    switch (mKind) {
      case OngakuEffectKindReverb: return mReverb.tailSeconds();
      case OngakuEffectKindDelay: return mDelay.tailSeconds(mLastTempo);
      case OngakuEffectKindConvolutionReverb: return mConvolution.tailSeconds();
      case OngakuEffectKindDoubler: return 0.1;
      default: return 0;
    }
  }

  /// How late the effect's output is, in samples at `sampleRate`: the Maximizer's look-ahead,
  /// the convolution's block, and Mastering's oversampling and look-ahead.
  int latencySamples(double sampleRate) const {
    switch (mKind) {
      case OngakuEffectKindMaximizer: return ongaku::Maximizer::lookAhead(sampleRate);
      case OngakuEffectKindMastering: return ongaku::Mastering::latency(sampleRate);
      case OngakuEffectKindConvolutionReverb: return ongaku::ConvolutionReverb::blockSize;
      default: return 0;
    }
  }

  // MARK: - Max Frames
  AUAudioFrameCount maximumFramesToRender() const { return mMaxFramesToRender; }

  void setMaximumFramesToRender(const AUAudioFrameCount &maxFrames) { mMaxFramesToRender = maxFrames; }

  // MARK: - Musical Context
  void setMusicalContextBlock(AUHostMusicalContextBlock contextBlock) { mMusicalContextBlock = contextBlock; }
  void setTransportStateBlock(AUHostTransportStateBlock transportBlock) { mTransportStateBlock = transportBlock; }

  // MARK: - Session Drummer

  /// The drummer's part (see `ongaku::SessionDrummer::setPart`).
  void setDrummerPart(DrummerPart const *part) { mDrummer.setPart(part); }
  void setMIDIOutput(AUMIDIOutputEventBlock block) { mDrummer.setMIDIOutput(block); }
  void setAppleKit(AudioUnit unit) { mDrummer.setAppleKit(unit); }

  // MARK: - Analyser

  /// Where to copy the output (mixed to mono) for an analyser to read: a ring of
  /// `capacity` samples, and a running count of samples written.
  void setAnalyserTap(float *samples, uint32_t capacity, uint32_t *written) {
    mTapSamples = samples;
    mTapCapacity = capacity;
    mTapWritten = written;
  }

  /// Where to publish meter levels (`OngakuMeterCount` floats; see `OngakuMeter`).
  void setMeters(float *meters) { mMeters = meters; }

  // MARK: - Sampler

  /// The Sampler's sample (see `ongaku::Sampler::setSample`).
  void setSample(SamplerSample const *sample) { mSampler.setSample(sample); }

  // MARK: - Convolution and loudness

  /// The Convolution Reverb's impulse response (see `ongaku::ConvolutionReverb::setImpulse`).
  void setImpulse(ongaku::ConvolutionImpulse const *impulse) { mConvolution.setImpulse(impulse); }

  /// Starts the Maximizer's integrated loudness and true peak again.
  void resetLoudness() { mMaximizer.resetLoudness(); }

  /// Mastering's Listen: start (afresh) or stop, and what it has heard so far.
  void masteringListen(bool on) { mMastering.listen(on); }
  bool masteringIsListening() const { return mMastering.isListening(); }
  int masteringListenedBlocks() const { return mMastering.listenedBlocks(); }
  ongaku::MasteringListenBlock masteringListenedBlock(int index) const { return mMastering.listenedBlock(index); }

  // MARK: - Notes from the interface

  /// Queues a MIDI message from the instrument's own interface (its on-screen keyboard),
  /// played at the start of the next render. Called from one thread (the main thread).
  void queueInterfaceMIDI(uint8_t status, uint8_t data1, uint8_t data2) {
    uint32_t write = __atomic_load_n(&mInterfaceWrite, __ATOMIC_RELAXED);
    uint32_t read = __atomic_load_n(&mInterfaceRead, __ATOMIC_ACQUIRE);
    if (write - read >= interfaceQueueSize) return;  // full: drop it
    mInterfaceQueue[write % interfaceQueueSize] = uint32_t(status) << 16 | uint32_t(data1) << 8 | data2;
    __atomic_store_n(&mInterfaceWrite, write + 1, __ATOMIC_RELEASE);
  }

  // MARK: - Internal Process
  void process(std::span<float const *> inputBuffers, std::span<float *> outputBuffers, AUEventSampleTime bufferStartTime, AUAudioFrameCount frameCount) {
    // Notes played on the interface's keyboard.
    uint32_t write = __atomic_load_n(&mInterfaceWrite, __ATOMIC_ACQUIRE);
    uint32_t read = __atomic_load_n(&mInterfaceRead, __ATOMIC_RELAXED);
    for (; read != write; ++read) {
      uint32_t message = mInterfaceQueue[read % interfaceQueueSize];
      midi(uint8_t(message >> 16), uint8_t(message >> 8), uint8_t(message));
    }
    __atomic_store_n(&mInterfaceRead, read, __ATOMIC_RELEASE);

    if (mBypassed) {
      for (UInt32 channel = 0; channel < std::min(inputBuffers.size(), outputBuffers.size()); ++channel) {
        if (inputBuffers[channel] != outputBuffers[channel]) {
          std::copy_n(inputBuffers[channel], frameCount, outputBuffers[channel]);
        }
      }
    } else {
      switch (mKind) {
        case OngakuEffectKindChannelEQ: mChannelEQ.process(inputBuffers, outputBuffers, int(frameCount)); break;
        case OngakuEffectKindCompressor:
          mCompressor.process(inputBuffers, outputBuffers, int(frameCount));
          meter(OngakuMeterInputPeak, mCompressor.lastInputPeak);
          meter(OngakuMeterOutputPeak, mCompressor.lastOutputPeak);
          meter(OngakuMeterGainReduction, mCompressor.lastReduction);
          break;
        case OngakuEffectKindReverb: mReverb.process(inputBuffers, outputBuffers, int(frameCount)); break;
        case OngakuEffectKindDelay: {
          double tempo = hostTempo();
          mDelay.process(inputBuffers, outputBuffers, int(frameCount), tempo);
          meter(OngakuMeterTempo, float(tempo));
          break;
        }
        case OngakuEffectKindRetroSynth: mSynth.process(outputBuffers, int(frameCount)); break;
        case OngakuEffectKindDrumMachine:
          mDrums.process(outputBuffers, int(frameCount));
          for (int pad = 0; pad < ongaku::DrumMachine::padCount; ++pad) {
            meter(OngakuMeter(OngakuMeterFirstPad + pad), mDrums.activity(pad));
          }
          break;
        case OngakuEffectKindNoiseGate:
          mGate.process(inputBuffers, outputBuffers, int(frameCount));
          levels(mGate.meters, mGate.lastReduction);
          meter(OngakuMeterGateOpen, mGate.isOpen() ? 1 : 0);
          break;
        case OngakuEffectKindTransientShaper:
          mShaper.process(inputBuffers, outputBuffers, int(frameCount));
          levels(mShaper.meters, mShaper.lastGain);
          break;
        case OngakuEffectKindMaximizer:
          mMaximizer.process(inputBuffers, outputBuffers, int(frameCount));
          levels(mMaximizer.meters, mMaximizer.lastReduction);
          meter(OngakuMeterMomentary, mMaximizer.loudness.momentary);
          meter(OngakuMeterShortTerm, mMaximizer.loudness.shortTerm);
          meter(OngakuMeterIntegrated, mMaximizer.loudness.integrated);
          meter(OngakuMeterTruePeak, mMaximizer.loudness.truePeak());
          break;
        case OngakuEffectKindDeEsser:
          mDeEsser.process(inputBuffers, outputBuffers, int(frameCount));
          levels(mDeEsser.meters, mDeEsser.lastReduction);
          break;
        case OngakuEffectKindSaturation:
          mSaturation.process(inputBuffers, outputBuffers, int(frameCount));
          levels(mSaturation.meters, 0);
          break;
        case OngakuEffectKindDoubler:
          mDoubler.process(inputBuffers, outputBuffers, int(frameCount));
          levels(mDoubler.meters, 0);
          break;
        case OngakuEffectKindConvolutionReverb:
          mConvolution.process(inputBuffers, outputBuffers, int(frameCount));
          levels(mConvolution.meters, 0);
          break;
        case OngakuEffectKindVocalStrip:
          mVocalStrip.process(inputBuffers, outputBuffers, int(frameCount));
          levels(mVocalStrip.meters, mVocalStrip.lastCompression);
          meter(OngakuMeter(OngakuMeterFirstPad), mVocalStrip.lastDeEssing);
          break;
        case OngakuEffectKindMastering:
          mMastering.process(inputBuffers, outputBuffers, int(frameCount));
          levels(mMastering.meters, mMastering.lastCompression);
          meter(OngakuMeterInputLoudness, mMastering.inputLoudness);
          meter(OngakuMeterOutputLoudness, mMastering.outputLoudness);
          meter(OngakuMeterLimiting, mMastering.lastLimiting);
          meter(OngakuMeterTruePeak, mMastering.outputTruePeak);
          meter(OngakuMeterMakeUp, mMastering.makeUp);
          break;
        case OngakuEffectKindSampler:
          mSampler.process(outputBuffers, int(frameCount));
          for (int index = 0; index < ongaku::Sampler::shownPlayheads; ++index) {
            meter(OngakuMeter(OngakuMeterFirstPlayhead + index), mSampler.playhead(index));
          }
          break;
        case OngakuEffectKindSessionDrummer: {
          DrummerClock clock = drummerClock(bufferStartTime, frameCount);
          mDrummer.process(outputBuffers, int(frameCount), bufferStartTime, clock);
          meter(OngakuMeterPartPosition, float(mDrummer.partPosition()));
          meter(OngakuMeterTempo, float(clock.tempo));
          meter(OngakuMeterSignature, float(clock.beatsPerBar * 100 + clock.beatUnit));
          for (int pad = 0; pad < ongaku::DrumMachine::padCount; ++pad) {
            meter(OngakuMeter(OngakuMeterFirstPad + pad), mDrummer.activity(pad));
          }
          break;
        }
      }
    }
    tap(outputBuffers, frameCount);
  }

  void handleOneEvent(AUEventSampleTime now, AURenderEvent const *event) {
    switch (event->head.eventType) {
      case AURenderEventParameter:
      case AURenderEventParameterRamp:
        setParameter(event->parameter.parameterAddress, event->parameter.value);
        break;
      case AURenderEventMIDI:
        if (event->MIDI.length > 0) midi(event->MIDI.data[0], event->MIDI.data[1], event->MIDI.data[2]);
        break;
      case AURenderEventMIDIEventList:
        handleEventList(event->MIDIEventsList.eventList);
        break;
      default:
        break;
    }
  }

  // MARK: Member Variables
  AUHostMusicalContextBlock mMusicalContextBlock;

  double mSampleRate = 44100.0;
  bool mBypassed = false;
  AUAudioFrameCount mMaxFramesToRender = 1024;

private:
  /// A MIDI 1.0 message, for the instruments.
  void midi(uint8_t status, uint8_t data1, uint8_t data2) {
    if (mKind == OngakuEffectKindRetroSynth) mSynth.midi(status, data1 & 0x7F, data2 & 0x7F);
    if (mKind == OngakuEffectKindDrumMachine) mDrums.midi(status, data1 & 0x7F, data2 & 0x7F);
    if (mKind == OngakuEffectKindSampler) mSampler.midi(status, data1 & 0x7F, data2 & 0x7F);
    if (mKind == OngakuEffectKindSessionDrummer) mDrummer.midi(status, data1 & 0x7F, data2 & 0x7F);
  }

  /// Where the host's song is at `sampleTime` (within this render, for `frameCount` frames):
  /// its tempo, beat, meter and whether it's playing.
  ///
  /// The drummer keeps its own steady count from block to block, and only takes the host's
  /// beat when it's somewhere else (a locate, a loop): hosts that update their position
  /// coarsely would otherwise make it double or skip hits. A host without a transport block
  /// is taken to be playing while its beat keeps moving.
  DrummerClock drummerClock(AUEventSampleTime sampleTime, AUAudioFrameCount frameCount) {
    DrummerClock clock;
    double tempo = 0, beat = 0, downbeat = 0;
    double numerator = 4;
    NSInteger denominator = 4, sampleOffset = 0;
    bool known = mMusicalContextBlock != nullptr
      && mMusicalContextBlock(&tempo, &numerator, &denominator, &beat, &sampleOffset, &downbeat);
    if (!known || tempo <= 0) {
      clock.tempo = mLastTempo;
      clock.playing = false;
      return clock;
    }
    mLastTempo = tempo;
    // The context is for the start of this render; segments later in it are further on.
    if (beat != mCycleBeat) {
      mCycleBeat = beat;
      mCycleStart = sampleTime;
    }
    clock.tempo = tempo;
    double beatsPerSample = tempo / 60.0 / mSampleRate;
    double hostBeat = beat + double(sampleTime - mCycleStart) * beatsPerSample;
    clock.beatsPerBar = int32_t(std::lround(numerator));
    clock.beatUnit = int32_t(denominator);
    if (mTransportStateBlock != nullptr) {
      AUHostTransportStateFlags flags = 0;
      if (mTransportStateBlock(&flags, nullptr, nullptr, nullptr)) {
        clock.playing = (flags & AUHostTransportStateMoving) != 0;
      }
    } else {
      // Moving if the beat has changed in the last quarter of a second.
      if (beat != mPreviousCycleBeat) mLastBeatChange = sampleTime;
      clock.playing = sampleTime - mLastBeatChange < AUEventSampleTime(mSampleRate / 4);
    }
    mPreviousCycleBeat = beat;
    // Carry on counting unless the host has gone somewhere else.
    bool following = mHasNextBeat && std::abs(hostBeat - mNextBeat) < 0.15;
    clock.beat = following ? mNextBeat : hostBeat;
    mHasNextBeat = clock.playing;
    mNextBeat = clock.beat + double(frameCount) * beatsPerSample;
    return clock;
  }

  /// Universal MIDI Packets: MIDI 1.0 channel voice messages, and MIDI 2.0 ones scaled back
  /// to MIDI 1.0's ranges.
  void handleEventList(MIDIEventList const &list) {
    MIDIEventPacket const *packet = &list.packet[0];
    for (UInt32 index = 0; index < list.numPackets; ++index) {
      if (packet->wordCount > 0) {
        UInt32 word = packet->words[0];
        UInt32 type = word >> 28;
        uint8_t status = (word >> 16) & 0xFF;
        if (type == 0x2) {
          midi(status, (word >> 8) & 0x7F, word & 0x7F);
        } else if (type == 0x4 && packet->wordCount > 1) {
          UInt32 data = packet->words[1];
          switch (status & 0xF0) {
            case 0x80:
            case 0x90: midi(status, (word >> 8) & 0x7F, std::max<UInt32>((status & 0xF0) == 0x90 ? 1 : 0, (data >> 16) >> 9)); break;
            case 0xB0: midi(status, (word >> 8) & 0x7F, data >> 25); break;
            case 0xE0: { UInt32 bend = data >> 18; midi(status, bend & 0x7F, (bend >> 7) & 0x7F); break; }
            default: break;
          }
        }
      }
      packet = MIDIEventPacketNext(packet);
    }
  }

  /// The song's tempo from the host, or 120 BPM if it doesn't say.
  double hostTempo() {
    double tempo = 0;
    if (mMusicalContextBlock != nullptr && mMusicalContextBlock(&tempo, nullptr, nullptr, nullptr, nullptr, nullptr) && tempo > 0) {
      mLastTempo = tempo;
    }
    return mLastTempo;
  }

  void levels(ongaku::PeakMeters const &peaks, float reduction) {
    meter(OngakuMeterInputPeak, peaks.input);
    meter(OngakuMeterOutputPeak, peaks.output);
    meter(OngakuMeterGainReduction, reduction);
  }

  void meter(OngakuMeter which, float value) {
    if (mMeters != nullptr) __atomic_store(mMeters + which, &value, __ATOMIC_RELAXED);
  }

  void tap(std::span<float *> outputBuffers, AUAudioFrameCount frameCount) {
    if (mTapSamples == nullptr || outputBuffers.empty()) return;
    uint32_t written = *mTapWritten;
    float scale = 1.0f / float(outputBuffers.size());
    for (AUAudioFrameCount i = 0; i < frameCount; ++i) {
      float sum = 0;
      for (float *channel : outputBuffers) sum += channel[i];
      mTapSamples[(written + i) % mTapCapacity] = sum * scale;
    }
    __atomic_store_n(mTapWritten, written + frameCount, __ATOMIC_RELEASE);
  }

  OngakuEffectKind mKind = OngakuEffectKindChannelEQ;
  ongaku::ChannelEQ mChannelEQ;
  ongaku::Compressor mCompressor;
  ongaku::Reverb mReverb;
  ongaku::Delay mDelay;
  ongaku::RetroSynth mSynth;
  ongaku::DrumMachine mDrums;
  ongaku::Sampler mSampler;
  ongaku::NoiseGate mGate;
  ongaku::TransientShaper mShaper;
  ongaku::Maximizer mMaximizer;
  ongaku::DeEsser mDeEsser;
  ongaku::Saturation mSaturation;
  ongaku::Doubler mDoubler;
  ongaku::ConvolutionReverb mConvolution;
  ongaku::VocalStrip mVocalStrip;
  ongaku::SessionDrummer mDrummer;
  ongaku::Mastering mMastering;
  AUHostTransportStateBlock mTransportStateBlock = nullptr;
  double mCycleBeat = -1, mPreviousCycleBeat = -1;
  AUEventSampleTime mCycleStart = 0, mLastBeatChange = -1'000'000'000;
  double mNextBeat = 0;
  bool mHasNextBeat = false;

  static constexpr uint32_t interfaceQueueSize = 64;
  std::array<uint32_t, interfaceQueueSize> mInterfaceQueue {};
  uint32_t mInterfaceWrite = 0, mInterfaceRead = 0;
  double mLastTempo = 120;
  float *mMeters = nullptr;

  float *mTapSamples = nullptr;
  uint32_t mTapCapacity = 0;
  uint32_t *mTapWritten = nullptr;
};
