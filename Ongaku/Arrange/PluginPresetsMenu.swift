//
//  PluginPresetsMenu.swift
//  Ongaku
//

import AppKit
import AudioToolbox
import OngakuCore
import OngakuEngine
import SwiftUI

/// The Presets menu itself.
struct PluginPresetsMenu: View {
  let presets: PluginPresets

  var body: some View {
    Menu {
      if !presets.factoryPresets.isEmpty {
        Section("Factory Presets") {
          ForEach(presets.factoryPresets, id: \.self) { name in
            Button(name) { presets.chooseFactoryPreset(name) }
          }
        }
      }
      Section("My Presets") {
        if presets.savedPresets.isEmpty {
          Text("None saved yet")
        }
        ForEach(presets.savedPresets, id: \.self) { name in
          Button(name) { presets.chooseSavedPreset(name) }
        }
      }
      Divider()
      Button("Save Preset As…") { presets.saveAs() }
      if !presets.savedPresets.isEmpty {
        Menu("Delete Preset") {
          ForEach(presets.savedPresets, id: \.self) { name in
            Button(name, role: .destructive) { presets.delete(name) }
          }
        }
      }
    } label: {
      // The title bar sizes it once, so names truncate rather than grow it.
      Text(presets.current ?? "Presets")
        .lineLimit(1)
        .frame(width: 140, alignment: .leading)
    }
    .menuStyle(.button)
    .controlSize(.small)
    .fixedSize()
    .padding(.horizontal, 10)
    .accessibilityLabel("Presets")
    .accessibilityIdentifier("plugin-presets")
  }

  func accessory() -> NSTitlebarAccessoryViewController {
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = NSHostingView(rootView: self)
    accessory.view.frame.size = accessory.view.fittingSize
    accessory.layoutAttribute = .trailing
    return accessory
  }
}
