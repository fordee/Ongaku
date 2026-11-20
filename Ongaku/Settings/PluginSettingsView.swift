//
//  PluginSettingsView.swift
//  Ongaku
//

import AudioToolbox
import OngakuEngine
import SwiftUI

/// The Plug-in Manager: other makers' Audio Units on this Mac, whether the menus offer each
/// one, and whether it works here.
struct PluginSettingsView: View {
  private let manager = PluginManager.shared
  @State private var plugins = InstrumentLibrary.thirdPartyPlugins()

  var body: some View {
    Form {
      Section {
        if plugins.isEmpty {
          Text("No other makers’ Audio Units are installed. Ongaku Studio’s own instruments and effects are always in the menus.")
            .foregroundStyle(.secondary)
        }
        ForEach(plugins) { entry in
          PluginRow(entry: entry)
        }
      } header: {
        Text("Audio Units")
      } footer: {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            if let name = manager.checking {
              ProgressView().controlSize(.small)
              Text("Checking “\(name)”… \(manager.remainingChecks) to go")
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Check All") {
              let all = plugins
              Task { await manager.check(all) }
            }
            .disabled(manager.checking != nil || plugins.isEmpty)
          }
          Text("A check loads a plug-in the way a song does, in its own process, and gets it ready to play. Plug-ins that are turned off, or fail their check, are left out of the menus; songs that already use them still load them.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(minHeight: 260, idealHeight: 440)
  }
}

private struct PluginRow: View {
  let entry: InstrumentLibrary.Entry
  private let manager = PluginManager.shared

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Toggle(isOn: Binding(get: { manager.isOffered(entry) }, set: { manager.setOffered($0, entry) })) {
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.name).fontWeight(.medium)
          Text(([entry.manufacturer, kind] + (entry.version.isEmpty ? [] : ["version \(entry.version)"])).joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(status)
            .font(.caption)
            .foregroundStyle(manager.hasFailed(entry) ? Theme.record : .secondary)
            .accessibilityIdentifier("plugin-status")
        }
      }
      .toggleStyle(.checkbox)
      Spacer()
      Button("Check") {
        Task { await manager.check([entry]) }
      }
      .disabled(manager.checking != nil)
    }
    .accessibilityElement(children: .contain)
  }

  private var kind: String {
    switch entry.componentType {
    case kAudioUnitType_MusicDevice: "Instrument"
    case kAudioUnitType_MusicEffect: "Effect (takes MIDI)"
    case kAudioUnitType_MIDIProcessor: "MIDI Effect"
    default: "Effect"
    }
  }

  private var status: String {
    guard let check = manager.check(of: entry) else { return "Not checked" }
    if check.passed { return "Works" }
    let reason = check.message ?? "It failed its check."
    return manager.isOffered(entry) ? "\(reason) Turned on anyway." : reason
  }
}

#Preview {
  PluginSettingsView()
    .frame(width: 560)
}
