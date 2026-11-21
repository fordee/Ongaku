//
//  InstrumentLibrary.swift
//  OngakuEngine
//

import AVFAudio
import AudioToolbox
import OngakuCore

/// The Audio Unit instruments installed on this Mac.
public enum InstrumentLibrary {
  public struct Entry: Identifiable, Sendable, Hashable {
    public var manufacturer: String
    public var name: String
    public var componentType: UInt32
    public var componentSubType: UInt32
    public var componentManufacturer: UInt32
    /// The plug-in's version, as its maker numbers it.
    public var version: String
    public var id: String { "\(componentType)-\(componentSubType)-\(componentManufacturer)" }

    public init(
      manufacturer: String, name: String, componentType: UInt32, componentSubType: UInt32, componentManufacturer: UInt32,
      version: String = ""
    ) {
      self.manufacturer = manufacturer
      self.name = name
      self.componentType = componentType
      self.componentSubType = componentSubType
      self.componentManufacturer = componentManufacturer
      self.version = version
    }

    /// A new reference for adding this instrument to a track.
    public func makeReference() -> PluginReference {
      PluginReference(
        componentType: componentType, componentSubType: componentSubType,
        componentManufacturer: componentManufacturer, name: name)
    }
  }

  /// Installed third-party effect plug-ins (Apple's and Ongaku's own effects are offered
  /// as built-in effects).
  public static func audioUnitEffects() -> [Entry] {
    let types = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
    return types.flatMap { type in
      AVAudioUnitComponentManager.shared().components(
        matching: AudioComponentDescription(
          componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0))
    }
    .filter {
      let manufacturer = $0.audioComponentDescription.componentManufacturer
      return manufacturer != kAudioUnitManufacturer_Apple && manufacturer != OngakuEffect.manufacturer
    }
    .map { component in
      let description = component.audioComponentDescription
      return Entry(
        manufacturer: component.manufacturerName, name: component.name,
        componentType: description.componentType, componentSubType: description.componentSubType,
        componentManufacturer: description.componentManufacturer, version: component.versionString)
    }
    .sorted { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
  }

  /// Installed MIDI effect plug-ins (Audio Unit MIDI processors), for the MIDI FX slots.
  public static func audioUnitMIDIEffects() -> [Entry] {
    AVAudioUnitComponentManager.shared().components(
      matching: AudioComponentDescription(
        componentType: kAudioUnitType_MIDIProcessor, componentSubType: 0, componentManufacturer: 0, componentFlags: 0,
        componentFlagsMask: 0))
    .map { component in
      let description = component.audioComponentDescription
      return Entry(
        manufacturer: component.manufacturerName, name: component.name,
        componentType: description.componentType, componentSubType: description.componentSubType,
        componentManufacturer: description.componentManufacturer, version: component.versionString)
    }
    .sorted { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
  }

  /// Every installed plug-in of another maker's that a song can use: instruments, effects
  /// and MIDI effects, for the Plug-in Manager.
  public static func thirdPartyPlugins() -> [Entry] {
    audioUnitInstruments().filter { $0.componentManufacturer != kAudioUnitManufacturer_Apple }
      + audioUnitEffects() + audioUnitMIDIEffects().filter { $0.componentManufacturer != kAudioUnitManufacturer_Apple }
  }

  /// Ongaku's own instruments, from the extension inside the app. The Session Drummer is
  /// left out: it's a plug-in for other apps, and Ongaku has Drummer tracks instead.
  public static func ongakuInstruments() -> [Entry] {
    OngakuInstrument.allCases.filter { $0 != .sessionDrummer }.map { instrument in
      Entry(
        manufacturer: "Ongaku", name: instrument.name, componentType: instrument.componentType,
        componentSubType: instrument.subType, componentManufacturer: OngakuEffect.manufacturer)
    }
  }

  /// Installed instrument plug-ins, grouped by manufacturer and sorted by name. Apple's
  /// built-in sampler and DLS synth are left out because the General MIDI instruments
  /// already cover them.
  public static func audioUnitInstruments() -> [Entry] {
    let query = AudioComponentDescription(
      componentType: kAudioUnitType_MusicDevice, componentSubType: 0, componentManufacturer: 0,
      componentFlags: 0, componentFlagsMask: 0)
    let builtIns: Set<UInt32> = [kAudioUnitSubType_Sampler, kAudioUnitSubType_DLSSynth, kAudioUnitSubType_MIDISynth]
    return AVAudioUnitComponentManager.shared().components(matching: query)
      .filter { !($0.audioComponentDescription.componentManufacturer == kAudioUnitManufacturer_Apple
        && builtIns.contains($0.audioComponentDescription.componentSubType)) }
      // Ongaku's own instruments are listed separately (see `ongakuInstruments`).
      .filter { $0.audioComponentDescription.componentManufacturer != OngakuEffect.manufacturer }
      .map { component in
        let description = component.audioComponentDescription
        return Entry(
          manufacturer: component.manufacturerName, name: component.name,
          componentType: description.componentType, componentSubType: description.componentSubType,
          componentManufacturer: description.componentManufacturer, version: component.versionString)
      }
      .sorted { ($0.manufacturer, $0.name) < ($1.manufacturer, $1.name) }
  }
}
