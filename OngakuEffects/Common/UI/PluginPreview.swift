//
//  PluginPreview.swift
//  OngakuEffects
//

import AudioToolbox
import SwiftUI

/// A real Ongaku plug-in, made in the preview's own process, in its whole window (the header
/// too), for SwiftUI previews.
///
/// Audio Unit extensions can't host previews, so the OngakuEffectsPreviews app, which builds
/// this folder's code as well, hosts them: make it the active scheme to preview a plug-in
/// window. Nothing plays through the plug-in; `values` sets parameters first, and `prepare`
/// can set anything else (what a listen found, or meter readings) to show the window in a
/// particular state. (Not only in debug builds:
/// `#Preview` bodies are compiled in every configuration.)
struct PluginPreview: View {
  let effect: OngakuEffect
  var values: [OngakuEffectsParameterAddress: AUValue] = [:]
  var prepare: (OngakuEffectsAudioUnit) -> Void = { _ in }

  var body: some View {
    if let window = Self.window(for: effect, values: values, prepare: prepare) {
      window
    } else {
      Text("“\(String(describing: effect))” couldn’t be made").padding()
    }
  }

  /// The window the extension would show for `effect` (see `AudioUnitViewController`).
  @MainActor
  private static func window(
    for effect: OngakuEffect, values: [OngakuEffectsParameterAddress: AUValue], prepare: (OngakuEffectsAudioUnit) -> Void
  ) -> AnyView? {
    let description = AudioComponentDescription(
      componentType: effect.isInstrument ? kAudioUnitType_MusicDevice : kAudioUnitType_Effect,
      componentSubType: effect.subType, componentManufacturer: 0x4F6E_676B, componentFlags: 0, componentFlagsMask: 0)
    guard let audioUnit = try? OngakuEffectsAudioUnit(componentDescription: description) else { return nil }
    for (address, value) in values {
      audioUnit.parameterTree?.parameter(withAddress: address.rawValue)?.value = value
    }
    prepare(audioUnit)
    let session = PluginSession(audioUnit: audioUnit)
    guard let tree = audioUnit.observableParameterTree(onUserChange: { [weak session] address, oldValue in
      session?.noteUserChange(address: address, oldValue: oldValue)
    }) else { return nil }
    let drummerModel = audioUnit.drummer.map { SessionDrummerModel(controller: $0, session: session) }
    return AnyView(
      OngakuEffectsMainView(audioUnit: audioUnit, parameterTree: tree, session: session, drummerModel: drummerModel)
        .frame(width: effect.windowSize.width, height: effect.windowSize.height))
  }
}
