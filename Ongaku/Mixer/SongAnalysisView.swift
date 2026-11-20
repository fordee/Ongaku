//
//  SongAnalysisView.swift
//  Ongaku
//

import AppKit
import OngakuCore
import SwiftUI

/// Analyze Whole Song's progress, as a sheet over the window.
struct SongAnalysisView: View {
  let model: ProjectWindowModel
  let analysis: SongAnalysis

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Analyzing “\(model.exportFileName)” for Mastering").font(.headline)
      VStack(alignment: .leading, spacing: 6) {
        ProgressView(value: analysis.progress)
        Text(analysis.isWaitingForFlex
          ? "Finishing processing flexed audio…"
          : "Mastering is listening to the whole song, faster than it plays. When it’s done, it sets the EQ, compression and loudness for the song.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { analysis.cancel() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}

#Preview {
  let model = ProjectWindowModel(document: OngakuDocument())
  let analysis = SongAnalysis()
  analysis.progress = 0.4
  return SongAnalysisView(model: model, analysis: analysis)
}

/// Analyze Whole Song, in Mastering's title bar.
struct AnalyzeSongButton: View {
  let model: ProjectWindowModel

  var body: some View {
    Button("Analyze Whole Song") { model.analyzeSongForMastering() }
      .controlSize(.small)
      .disabled(model.songAnalysis != nil)
      .help("Mastering listens to the whole song, faster than it plays, instead of while you play it, then sets itself up for it")
      .padding(.horizontal, 10)
  }

  func accessory() -> NSTitlebarAccessoryViewController {
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = NSHostingView(rootView: self)
    accessory.view.frame.size = accessory.view.fittingSize
    accessory.layoutAttribute = .trailing
    return accessory
  }
}
