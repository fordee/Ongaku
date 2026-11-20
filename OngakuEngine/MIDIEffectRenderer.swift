//
//  MIDIEffectRenderer.swift
//  OngakuEngine
//

import AVFAudio
import AudioToolbox

/// Hosts a MIDI effect plug-in (an Audio Unit MIDI processor) for an instrument: the
/// instrument's render observer renders it just before the instrument renders, with the
/// instrument's timestamp, and the MIDI it plays goes straight on to the next plug-in or the
/// instrument, in the same render cycle. Everything then counts samples in the instrument's
/// timeline.
///
/// Why not `AVAudioEngine.connectMIDI`? Rendering offline (bounces and freezes), the engine
/// stops rendering a MIDI processor after a few cycles, so its notes stop; and a MIDI
/// processor node never reports a valid `lastRenderTime`, so events can't be timed for it.
///
/// Real-time rules: `render` runs on the render thread. Its buffers are allocated up front,
/// and it only sets their sizes and calls the plug-in.
final class MIDIEffectRenderer: @unchecked Sendable {
  let unit: AVAudioUnit
  let sampleRate: Double
  /// Plays MIDI into the plug-in.
  let scheduleMIDIEvent: AUScheduleMIDIEventBlock?
  let scheduleMIDIEventList: AUMIDIEventListBlock?
  private let renderBlock: AURenderBlock
  private let capacity: AUAudioFrameCount
  /// Where the plug-in's audio goes (MIDI effects make none worth hearing), one buffer per
  /// channel, and each buffer's memory.
  private let buffers: UnsafeMutableAudioBufferListPointer
  private let channelData: [UnsafeMutableRawPointer]

  /// Starts the plug-in rendering at `format`'s sample rate, in blocks of up to
  /// `maximumFrames`.
  init(unit: AVAudioUnit, format: AVAudioFormat, maximumFrames: AUAudioFrameCount) throws {
    self.unit = unit
    sampleRate = format.sampleRate
    capacity = maximumFrames
    let (renderBlock, schedule, scheduleList, channels) = try unit.withAUAudioUnit {
      audioUnit -> (AURenderBlock, AUScheduleMIDIEventBlock?, AUMIDIEventListBlock?, Int) in
      audioUnit.maximumFramesToRender = maximumFrames
      var channels = 0
      if audioUnit.outputBusses.count > 0 {
        try? audioUnit.outputBusses[0].setFormat(format)
        channels = Int(audioUnit.outputBusses[0].format.channelCount)
      }
      if !audioUnit.renderResourcesAllocated {
        try audioUnit.allocateRenderResources()
      }
      return (audioUnit.renderBlock, audioUnit.scheduleMIDIEventBlock, audioUnit.scheduleMIDIEventListBlock, channels)
    }
    self.renderBlock = renderBlock
    scheduleMIDIEvent = schedule
    scheduleMIDIEventList = scheduleList
    buffers = AudioBufferList.allocate(maximumBuffers: channels)
    let bytes = Int(maximumFrames) * MemoryLayout<Float>.size
    channelData = (0..<channels).map { _ in UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16) }
  }

  deinit {
    for data in channelData {
      data.deallocate()
    }
    free(buffers.unsafeMutablePointer)
    unit.withAUAudioUnit { $0.deallocateRenderResources() }
  }

  /// Sends the MIDI the plug-in plays to the next plug-in or the instrument (`nil` drops it).
  func sendOutput(toEvents schedule: AUScheduleMIDIEventBlock?, eventLists scheduleList: AUMIDIEventListBlock?) {
    unit.withAUAudioUnit { audioUnit in
      audioUnit.midiOutputEventBlock = schedule.map { schedule in
        { sampleTime, cable, length, bytes in
          schedule(sampleTime, cable, length, bytes)
          return noErr
        }
      }
      audioUnit.midiOutputEventListBlock = scheduleList.map { scheduleList in
        { sampleTime, cable, eventList in scheduleList(sampleTime, cable, eventList) }
      }
    }
  }

  /// Render thread: renders one cycle, at the instrument's timestamp.
  func render(at timestamp: UnsafePointer<AudioTimeStamp>, frameCount: AUAudioFrameCount) {
    guard frameCount <= capacity else { return }
    let byteSize = frameCount * UInt32(MemoryLayout<Float>.size)
    for index in channelData.indices {
      buffers[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: channelData[index])
    }
    var flags = AudioUnitRenderActionFlags()
    _ = renderBlock(&flags, timestamp, frameCount, 0, buffers.unsafeMutablePointer, nil)
  }
}
