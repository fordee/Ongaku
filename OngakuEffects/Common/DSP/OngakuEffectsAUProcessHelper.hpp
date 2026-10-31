//
//  OngakuEffectsAUProcessHelper.hpp
//  OngakuEffects
//

#pragma once

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#include <vector>
#include "OngakuEffectsDSPKernel.hpp"
#include "OngakuEffectsBufferedAudioBus.hpp"

/// Runs the kernel from the render block: pulls an effect's input, splits each buffer at
/// the events in it (parameter changes, MIDI) so they land on their sample, and processes.
class AUProcessHelper {
public:
  /// For an effect, `bufferedInputBus` is where its input is pulled into. An instrument has
  /// no input (pass null) and renders into `bufferedOutputBus` when the host gives it no
  /// buffers of its own.
  AUProcessHelper(OngakuEffectsDSPKernel &kernel, BufferedInputBus *bufferedInputBus, BufferedOutputBus *bufferedOutputBus)
    : mKernel{kernel}, mBufferedInputBus(bufferedInputBus), mBufferedOutputBus(bufferedOutputBus) {}

  void setChannelCount(UInt32 inputChannelCount, UInt32 outputChannelCount) {
    mInputBuffers.resize(inputChannelCount);
    mOutputBuffers.resize(outputChannelCount);
  }

  /// Handles the event list and the rendering loop.
  void processWithEvents(AudioBufferList *inBufferList, AudioBufferList *outBufferList, AudioTimeStamp const *timestamp,
                         AUAudioFrameCount frameCount, AURenderEvent const *events) {
    AUEventSampleTime now = AUEventSampleTime(timestamp->mSampleTime);
    AUAudioFrameCount framesRemaining = frameCount;
    AURenderEvent const *nextEvent = events;  // a linked list

    auto callProcess = [this](AudioBufferList *inBufferListPtr, AudioBufferList *outBufferListPtr, AUEventSampleTime now,
                              AUAudioFrameCount frameCount, AUAudioFrameCount const frameOffset) {
      size_t inputCount = inBufferListPtr == nullptr ? 0 : std::min(size_t(inBufferListPtr->mNumberBuffers), mInputBuffers.size());
      for (size_t channel = 0; channel < inputCount; ++channel) {
        mInputBuffers[channel] = (const float *)inBufferListPtr->mBuffers[channel].mData + frameOffset;
      }
      size_t outputCount = std::min(size_t(outBufferListPtr->mNumberBuffers), mOutputBuffers.size());
      for (size_t channel = 0; channel < outputCount; ++channel) {
        mOutputBuffers[channel] = (float *)outBufferListPtr->mBuffers[channel].mData + frameOffset;
      }
      mKernel.process(std::span<float const *>(mInputBuffers.data(), inputCount),
                      std::span<float *>(mOutputBuffers.data(), outputCount), now, frameCount);
    };

    while (framesRemaining > 0) {
      // No more events: process the rest and finish.
      if (nextEvent == nullptr) {
        AUAudioFrameCount const frameOffset = frameCount - framesRemaining;
        callProcess(inBufferList, outBufferList, now, framesRemaining, frameOffset);
        return;
      }

      // Late events start late.
      auto headEventTime = nextEvent->head.eventSampleTime;
      AUAudioFrameCount framesThisSegment = AUAudioFrameCount(std::max(AUEventSampleTime(0), headEventTime - now));
      framesThisSegment = std::min(framesThisSegment, framesRemaining);

      // Everything before the next event.
      if (framesThisSegment > 0) {
        AUAudioFrameCount const frameOffset = frameCount - framesRemaining;
        callProcess(inBufferList, outBufferList, now, framesThisSegment, frameOffset);
        framesRemaining -= framesThisSegment;
        now += AUEventSampleTime(framesThisSegment);
      }

      nextEvent = performAllSimultaneousEvents(now, nextEvent);
    }
  }

  AURenderEvent const *performAllSimultaneousEvents(AUEventSampleTime now, AURenderEvent const *event) {
    do {
      mKernel.handleOneEvent(now, event);
      event = event->head.next;
      // While the next event is simultaneous (or late).
    } while (event && event->head.eventSampleTime <= now);
    return event;
  }

  AUInternalRenderBlock internalRenderBlock() {
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags, const AudioTimeStamp *timestamp,
                              AUAudioFrameCount frameCount, NSInteger outputBusNumber, AudioBufferList *outputData,
                              const AURenderEvent *realtimeEventListHead,
                              AURenderPullInputBlock __unsafe_unretained pullInputBlock) {
      if (frameCount > mKernel.maximumFramesToRender()) {
        return kAudioUnitErr_TooManyFramesToProcess;
      }

      // An instrument makes its sound from nothing: silence, then its voices added in.
      if (mBufferedInputBus == nullptr) {
        mBufferedOutputBus->prepareOutputBufferList(outputData, frameCount, true);
        processWithEvents(nullptr, outputData, timestamp, frameCount, realtimeEventListHead);
        return noErr;
      }

      AudioUnitRenderActionFlags pullFlags = 0;
      AUAudioUnitStatus err = mBufferedInputBus->pullInput(&pullFlags, timestamp, frameCount, 0, pullInputBlock);
      if (err != 0) { return err; }

      AudioBufferList *inAudioBufferList = mBufferedInputBus->mutableAudioBufferList;

      // If the host passed null output buffers, process in place in the input buffers.
      AudioBufferList *outAudioBufferList = outputData;
      if (outAudioBufferList->mBuffers[0].mData == nullptr) {
        for (UInt32 i = 0; i < outAudioBufferList->mNumberBuffers; ++i) {
          outAudioBufferList->mBuffers[i].mData = inAudioBufferList->mBuffers[i].mData;
        }
      }

      processWithEvents(inAudioBufferList, outAudioBufferList, timestamp, frameCount, realtimeEventListHead);
      return noErr;
    };
  }

private:
  OngakuEffectsDSPKernel &mKernel;
  std::vector<const float *> mInputBuffers;
  std::vector<float *> mOutputBuffers;
  BufferedInputBus *mBufferedInputBus;
  BufferedOutputBus *mBufferedOutputBus;
};
