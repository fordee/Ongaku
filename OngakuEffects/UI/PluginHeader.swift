//
//  PluginHeader.swift
//  OngakuEffects
//

import AudioToolbox
import SwiftUI

extension OngakuEffect {
  /// The name shown in the window's header.
  var displayName: String {
    switch self {
    case .channelEQ: "Channel EQ"
    case .compressor: "Compressor"
    case .reverb: "Reverb"
    case .delay: "Delay"
    case .retroSynth: "Retro Synth"
    case .drumMachine: "Drum Machine"
    case .sampler: "Sampler"
    case .noiseGate: "Noise Gate"
    case .transientShaper: "Transient Shaper"
    case .maximizer: "Maximizer"
    case .deEsser: "De-Esser"
    case .saturation: "Saturation"
    case .doubler: "Doubler"
    case .convolutionReverb: "Convolution Reverb"
    case .vocalStrip: "Vocal Strip"
    case .sessionDrummer: "Session Drummer"
    case .mastering: "Mastering"
    }
  }
}

/// The bar across the top of every Ongaku plug-in: the name, the preset (step through with
/// the arrows, or pick from the menu; a dot shows it's been changed), saving your own
/// presets, A/B comparison, and undo and redo.
struct PluginHeader: View {
  static let height: CGFloat = 36

  let effect: OngakuEffect
  let session: PluginSession

  @State private var isSaving = false
  @State private var renaming: AUAudioUnitPreset?

  var body: some View {
    HStack(spacing: 10) {
      HStack(spacing: 6) {
        Text("ongaku")
          .font(.system(size: 13, weight: .heavy, design: .rounded))
          .foregroundStyle(LinearGradient(
            colors: [Color(red: 0.95, green: 0.55, blue: 0.3), Color(red: 0.9, green: 0.35, blue: 0.6)],
            startPoint: .leading, endPoint: .trailing))
        Text(effect.displayName)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(EffectStyle.value)
      }
      .fixedSize()
      .accessibilityElement(children: .combine)

      Spacer(minLength: 12)

      presetControl

      Button {
        isSaving = true
      } label: {
        Image(systemName: "square.and.arrow.down")
      }
      .buttonStyle(HeaderButtonStyle())
      .help("Save these settings as a preset of your own")
      .accessibilityLabel("Save Preset")
      .popover(isPresented: $isSaving, arrowEdge: .bottom) {
        PresetNameForm(title: "Save Preset", initialName: session.presetName ?? "", action: "Save") { name in
          session.saveUserPreset(named: name)
          isSaving = false
        }
      }

      Spacer(minLength: 12)

      abControl

      HStack(spacing: 2) {
        Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
          .disabled(!session.canUndo)
          .help("Undo the last change")
          .accessibilityLabel("Undo")
          .keyboardShortcut("z", modifiers: .command)
        Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
          .disabled(!session.canRedo)
          .help("Redo")
          .accessibilityLabel("Redo")
          .keyboardShortcut("z", modifiers: [.command, .shift])
      }
      .buttonStyle(HeaderButtonStyle())
    }
    .padding(.horizontal, 12)
    .frame(height: Self.height)
    .background(Color(white: 0.09))
    .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.6)).frame(height: 1) }
    .popover(item: $renaming, arrowEdge: .bottom) { preset in
      PresetNameForm(title: "Rename Preset", initialName: preset.name, action: "Rename") { name in
        session.renameUserPreset(preset, to: name)
        renaming = nil
      }
    }
  }

  // MARK: - Presets

  private var presetControl: some View {
    HStack(spacing: 0) {
      Button { session.step(by: -1) } label: { Image(systemName: "chevron.left") }
        .buttonStyle(HeaderButtonStyle(width: 24))
        .help("Previous preset")
        .accessibilityLabel("Previous Preset")
        .disabled(session.allPresets.isEmpty)
      Menu {
        if !session.factoryPresets.isEmpty {
          Section("Factory") {
            ForEach(session.factoryPresets, id: \.number) { preset in
              presetButton(preset)
            }
          }
        }
        Section("My Presets") {
          if session.userPresets.isEmpty {
            Text("Save settings with the ↓ button to keep them here")
          }
          ForEach(session.userPresets, id: \.number) { preset in
            presetButton(preset)
          }
        }
        if !session.userPresets.isEmpty {
          Divider()
          Menu("Rename") {
            ForEach(session.userPresets, id: \.number) { preset in
              Button(preset.name) { renaming = preset }
            }
          }
          Menu("Delete") {
            ForEach(session.userPresets, id: \.number) { preset in
              Button(preset.name, role: .destructive) { session.deleteUserPreset(preset) }
            }
          }
        }
      } label: {
        HStack(spacing: 6) {
          Text(session.presetName ?? "No Preset")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(session.presetName == nil ? EffectStyle.label : EffectStyle.value)
            .lineLimit(1)
          if session.isModified {
            Circle().fill(Color.orange).frame(width: 6, height: 6)
              .help("Changed since the preset was chosen")
          }
          Spacer(minLength: 0)
          Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(EffectStyle.label)
        }
        .padding(.horizontal, 10)
        .frame(width: 210, height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.16)))
        .contentShape(.rect)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("Preset")
      .accessibilityValue(session.presetName.map { session.isModified ? "\($0), changed" : $0 } ?? "None")
      Button { session.step(by: 1) } label: { Image(systemName: "chevron.right") }
        .buttonStyle(HeaderButtonStyle(width: 24))
        .help("Next preset")
        .accessibilityLabel("Next Preset")
        .disabled(session.allPresets.isEmpty)
    }
  }

  private func presetButton(_ preset: AUAudioUnitPreset) -> some View {
    Button {
      session.choose(preset)
    } label: {
      if preset.name == session.presetName {
        Label(preset.name, systemImage: "checkmark")
      } else {
        Text(preset.name)
      }
    }
  }

  // MARK: - A/B

  private var abControl: some View {
    HStack(spacing: 0) {
      ForEach([PluginSession.Slot.a, .b], id: \.self) { slot in
        let isActive = session.activeSlot == slot
        Button {
          if !isActive { session.switchSlot() }
        } label: {
          Text(slot.rawValue)
            .font(.system(size: 11, weight: .bold))
            .frame(width: 26, height: 22)
            .foregroundStyle(isActive ? Color.black : EffectStyle.label)
            .background(RoundedRectangle(cornerRadius: 5).fill(isActive ? Color.orange : Color.clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings \(slot.rawValue)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
      }
      Menu {
        Button("Copy \(session.activeSlot.rawValue) to \(session.otherSlotName)") { session.copyToOtherSlot() }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold)).foregroundStyle(EffectStyle.label)
          .frame(width: 20, height: 22)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityLabel("A/B options")
    }
    .padding(2)
    .background(RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.16)))
    .help("Compare two versions of the settings: changes in A and B are kept separately")
  }
}

/// The header's small square buttons.
private struct HeaderButtonStyle: ButtonStyle {
  var width: CGFloat = 26
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(isEnabled ? EffectStyle.value : EffectStyle.label.opacity(0.5))
      .frame(width: width, height: 24)
      .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Color(white: 0.25) : Color(white: 0.16)))
      .contentShape(.rect)
  }
}

/// Asks for a preset's name.
private struct PresetNameForm: View {
  let title: String
  let initialName: String
  let action: String
  let commit: (String) -> Void

  @State private var name = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.headline)
      TextField("Preset Name", text: $name)
        .textFieldStyle(.roundedBorder)
        .frame(width: 220)
        .onSubmit(save)
      HStack {
        Spacer()
        Button(action, action: save)
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
    .padding(14)
    .onAppear { name = initialName }
  }

  private func save() {
    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    commit(name)
  }
}

extension AUAudioUnitPreset: @retroactive Identifiable {
  public var id: Int { number }
}
