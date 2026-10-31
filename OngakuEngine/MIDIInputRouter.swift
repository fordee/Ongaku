//
//  MIDIInputRouter.swift
//  OngakuEngine
//

import AudioToolbox
import CoreMIDI
import Foundation
import Synchronization

/// Sends notes from connected MIDI keyboards and controllers to the instruments of the
/// frontmost project window: its record-enabled instrument tracks, or its selected one.
///
/// Events go straight from CoreMIDI's thread to the instrument's MIDI block, without a hop to
/// the main thread, so a busy interface never adds latency to playing.
public final class MIDIInputRouter: @unchecked Sendable {
  /// The app-wide router. Created on first use; `nil` if CoreMIDI isn't available.
  public static let shared: MIDIInputRouter? = try? MIDIInputRouter()

  public enum RouterError: Error {
    case coreMIDI(OSStatus)
  }

  /// A MIDI keyboard, controller or other app that sends MIDI.
  public struct Source: Identifiable, Hashable, Sendable {
    /// CoreMIDI's unique ID for the source, which stays the same across launches.
    public var id: MIDIUniqueID
    public var name: String
  }

  /// The MIDI sources connected now.
  public static func sources() -> [Source] {
    (0..<MIDIGetNumberOfSources()).compactMap { index in
      let endpoint = MIDIGetSource(index)
      var id: MIDIUniqueID = 0
      guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr else { return nil }
      var name: Unmanaged<CFString>?
      MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name)
      return Source(id: id, name: (name?.takeRetainedValue() as String?) ?? "MIDI Source")
    }
  }

  /// Where input goes: straight to instruments, and to something that plays the tracks
  /// with MIDI effects (through each one's effects). Several tracks play it layered.
  struct Targets {
    var instruments: [AUScheduleMIDIEventBlock] = []
    var handler: (@Sendable ([UInt8], UInt64) -> Void)?

    var isEmpty: Bool { instruments.isEmpty && handler == nil }
  }

  private let targets = Mutex(Targets())
  /// While recording, incoming MIDI is also captured here with its timestamp.
  private let capture = Mutex<MIDICapture?>(nil)
  /// Sources the person switched off in Settings; everything else is listened to.
  private let ignoredSources = Mutex<Set<MIDIUniqueID>>([])
  private var client = MIDIClientRef()
  private var port = MIDIPortRef()

  private init() throws {
    var status = MIDIClientCreateWithBlock("Ongaku" as CFString, &client) { [weak self] notification in
      // Reconnect when keyboards are plugged in or removed.
      if notification.pointee.messageID == .msgSetupChanged {
        self?.connectAllSources()
      }
    }
    guard status == noErr else { throw RouterError.coreMIDI(status) }

    status = MIDIInputPortCreateWithProtocol(client, "Ongaku Input" as CFString, ._1_0, &port) { [weak self] eventList, _ in
      self?.receive(eventList)
    }
    guard status == noErr else { throw RouterError.coreMIDI(status) }
    connectAllSources()
  }

  deinit {
    MIDIPortDispose(port)
    MIDIClientDispose(client)
  }

  /// Chooses the instruments that receive input, and a handler that's also sent it (each
  /// message with its host time); none of either stops routing.
  func setTargets(instruments: [AUScheduleMIDIEventBlock], handler: (@Sendable ([UInt8], UInt64) -> Void)?) {
    targets.withLock { $0 = Targets(instruments: instruments, handler: handler) }
  }

  /// Starts or stops capturing input for recording.
  func setCapture(_ newCapture: MIDICapture?) {
    capture.withLock { $0 = newCapture }
  }

  /// Stops listening to some sources (and listens to all the others).
  public func setIgnoredSources(_ ids: Set<MIDIUniqueID>) {
    let changed = ignoredSources.withLock { ignored in
      defer { ignored = ids }
      return ignored != ids
    }
    if changed {
      connectAllSources()
    }
  }

  private func connectAllSources() {
    let ignored = ignoredSources.withLock { $0 }
    for index in 0..<MIDIGetNumberOfSources() {
      let endpoint = MIDIGetSource(index)
      var id: MIDIUniqueID = 0
      MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id)
      // Connecting a source that's already connected (or disconnecting one that isn't) is
      // harmless.
      if ignored.contains(id) {
        MIDIPortDisconnectSource(port, endpoint)
      } else {
        MIDIPortConnectSource(port, endpoint, nil)
      }
    }
  }

  /// Converts MIDI 1.0 channel-voice messages (Universal MIDI Packet type 2) to bytes and
  /// passes them on. Everything else (clock, SysEx, MIDI 2.0) is ignored for now.
  private func receive(_ eventList: UnsafePointer<MIDIEventList>) {
    let destination = targets.withLock { $0 }
    let capture = capture.withLock { $0 }
    guard !destination.isEmpty || capture != nil else { return }
    for packet in eventList.unsafeSequence() {
      // A timestamp of 0 means "now".
      let hostTime = packet.pointee.timeStamp == 0 ? mach_absolute_time() : packet.pointee.timeStamp
      for word in packet.words() where word >> 28 == 0x2 {
        let status = UInt8((word >> 16) & 0xFF)
        var bytes: (UInt8, UInt8, UInt8) = (status, UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F))
        // Program change and channel pressure have one data byte; the rest have two.
        let length = (status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0) ? 2 : 3
        for schedule in destination.instruments {
          withUnsafePointer(to: &bytes) { tuple in
            tuple.withMemoryRebound(to: UInt8.self, capacity: 3) { pointer in
              schedule(AUEventSampleTimeImmediate, 0, length, pointer)
            }
          }
        }
        destination.handler?(Array([bytes.0, bytes.1, bytes.2].prefix(length)), hostTime)
        capture?.receive(Array([bytes.0, bytes.1, bytes.2].prefix(length)), atHostTime: hostTime)
      }
    }
  }
}
