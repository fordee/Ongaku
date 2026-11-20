//
//  StripSilenceView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

extension ProjectWindowModel {
  /// The selected audio regions, which Strip Silence works on.
  var selectedAudioRegionIDs: [Region.ID] {
    project.tracks.flatMap(\.regions).filter { region in
      guard selectedRegionIDs.contains(region.id), case .audio = region.content else { return false }
      return true
    }.map(\.id)
  }

  /// Edit › Strip Silence…: opens its dialog for the selected audio regions.
  func showStripSilence() {
    guard !selectedAudioRegionIDs.isEmpty else {
      errorMessage = "Select one or more audio regions to strip silence from."
      return
    }
    isShowingStripSilence = true
  }

  /// Logic's Strip Silence: each selected audio region is cut into its stretches of sound,
  /// the silence between removed, as one undo step. Reads the audio in the background.
  func stripSilence(from regionIDs: [Region.ID], settings: SilenceDetector.Settings) {
    let jobs = regionIDs.compactMap { id -> (Region.ID, URL, Int64, Int64)? in
      guard let region = project.region(withID: id), case .audio(let audio) = region.content,
        let file = project.audioFile(withID: audio.fileID), let url = document.url(for: file)
      else { return nil }
      return (id, url, audio.fileStartFrame, Int64((project.duration(of: region) * file.sampleRate).rounded()))
    }
    Task {
      do {
        var commands: [any EditCommand] = []
        for (id, url, startFrame, frames) in jobs {
          let sounds = try await FlexAudio.sounds(in: url, from: startFrame, frames: frames, settings: settings)
          commands.append(StripSilence(id, keeping: sounds))
        }
        guard !commands.isEmpty else { return }
        perform(CompositeCommand("Strip Silence", commands: commands))
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

/// Strip Silence's dialog, with Logic's four settings.
struct StripSilenceView: View {
  let model: ProjectWindowModel
  @State private var settings = SilenceDetector.Settings()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Strip Silence").font(.headline)
      Text("Cuts the selected audio regions into the parts with sound in them and removes the silence between.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Form {
        LabeledContent("Threshold") {
          Stepper("\(Int(settings.threshold)) dB", value: $settings.threshold, in: -80...(-10), step: 2)
        }
        .help("Quieter than this is silence.")
        LabeledContent("Minimum Silence") {
          Stepper("\(Int(settings.minimumSilence * 1000)) ms", value: $settings.minimumSilence, in: 0.02...2, step: 0.05)
        }
        .help("Shorter gaps are kept, so a phrase isn't cut into pieces.")
        LabeledContent("Pre-Attack") {
          Stepper("\(Int(settings.preAttack * 1000)) ms", value: $settings.preAttack, in: 0...0.5, step: 0.01)
        }
        .help("How much is kept before each sound, so its attack isn't cut.")
        LabeledContent("Post-Release") {
          Stepper("\(Int(settings.postRelease * 1000)) ms", value: $settings.postRelease, in: 0...2, step: 0.05)
        }
        .help("How much is kept after each sound, so its tail rings out.")
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Strip Silence") {
          model.stripSilence(from: model.selectedAudioRegionIDs, settings: settings)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 400)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Strip Silence")
    .accessibilityIdentifier("strip-silence")
  }
}

#Preview {
  @Previewable @State var model = ProjectWindowModel(document: OngakuDocument(project: .previewSong))
  StripSilenceView(model: model)
}
