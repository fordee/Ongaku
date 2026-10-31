//
//  ProjectWindowModel+Mastering.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// Analyze Whole Song, while it runs: how far it has got.
@MainActor
@Observable
final class SongAnalysis {
  var progress = 0.0
  /// While it waits for flexed regions to finish processing, before rendering.
  var isWaitingForFlex = false
  @ObservationIgnored var task: Task<Void, Never>?

  func cancel() {
    task?.cancel()
  }
}

/// Ongaku Mastering on Stereo Out: opening it from the strip, and Analyze Whole Song, which
/// lets it listen to the whole song offline instead of while you play it.
extension ProjectWindowModel {
  /// The Mastering on Stereo Out, if there is one.
  var stereoOutMastering: PluginReference? {
    project.stereoOutInserts.first { OngakuEffect($0) == .mastering }
  }

  /// Stereo Out's Master button: opens Mastering, putting it on Stereo Out first if it isn't
  /// there (after any other plug-ins, where mastering goes).
  func showMastering() {
    Task {
      guard let mastering = await masteringOnStereoOut() else { return }
      showInsertWindow(mastering.id, on: Project.stereoOutID)
    }
  }

  /// Plays the whole song offline through Mastering's Listen, faster than real time, and
  /// gives the song's Mastering what it found, as one undoable change. Mastering is put on
  /// Stereo Out first if it isn't there.
  func analyzeSongForMastering() {
    guard songAnalysis == nil else { return }
    // The whole song, even with cycle on: Listen should hear all of it.
    var whole = project
    whole.cycle.isEnabled = false
    guard let range = whole.bounceRange else {
      errorMessage = BounceError.nothingToBounce.localizedDescription
      return
    }
    engine.stop()
    let analysis = SongAnalysis()
    songAnalysis = analysis
    analysis.task = Task { [weak self] in
      guard let self else { return }
      let failure = await listenToWholeSong(range, analysis: analysis)
      // The sheet goes first, so a failure's alert isn't lost behind it.
      songAnalysis = nil
      if let failure { errorMessage = failure }
    }
  }

  /// Analyze Whole Song's work; what went wrong, if anything did.
  private func listenToWholeSong(_ range: Range<Tick>, analysis: SongAnalysis) async -> String? {
    guard let mastering = await masteringOnStereoOut(), !Task.isCancelled else { return nil }
    do {
      guard let state = try await masteringState(for: mastering, over: range, analysis: analysis) else {
        return Task.isCancelled ? nil : Self.tooLittleMusicMessage
      }
      adoptMasteringState(state, for: mastering) { _ = perform($0, named: "Analyze Whole Song") }
      return nil
    } catch is CancellationError {
      return nil
    } catch {
      return "The song couldn’t be analyzed: \(error.localizedDescription)"
    }
  }

  static let tooLittleMusicMessage =
    "Mastering heard too little music to go on. It needs at least \(Int(MasteringAnalysis.minimumSeconds)) seconds that aren’t silent."

  /// Plays `range` offline through Mastering's Listen, returning the settings it chose, or
  /// `nil` if it heard too little (or was cancelled while waiting for flexed regions).
  func masteringState(for mastering: PluginReference, over range: Range<Tick>, analysis: SongAnalysis?) async throws -> Data? {
    analysis?.isWaitingForFlex = true
    await finishFlexRenders()
    analysis?.isWaitingForFlex = false
    guard !Task.isCancelled else { return nil }
    let bouncer = ProjectBouncer(project: projectWithCurrentPluginStates()) { [weak document] file in
      document?.url(for: file)
    }
    return try await bouncer.listenForMastering(mastering.id, range: range, sampleRate: engine.outputSampleRate) {
      analysis?.progress = $0
    }
  }

  /// Gives the song's Mastering the settings an analysis chose, with `perform` (one undo
  /// step).
  func adoptMasteringState(_ state: Data, for mastering: PluginReference, perform: (any EditCommand) throws -> Void) rethrows {
    // Undo goes back to the settings Mastering has now. Those reach the song only when its
    // window closes (or the song is saved), so store them first, as saving does.
    if let current = engine.insertState(mastering.id, onTrack: Project.stereoOutID) {
      var settled = project
      try? SetPluginState(current, forPlugin: mastering.id, on: Project.stereoOutID).apply(to: &settled)
      document.editor.load(settled)
    }
    try perform(SetPluginState(state, forPlugin: mastering.id, on: Project.stereoOutID))
  }

  /// The Mastering on Stereo Out once it's loaded, adding it first if there isn't one.
  func masteringOnStereoOut() async -> PluginReference? {
    let mastering: PluginReference
    if let existing = stereoOutMastering {
      mastering = existing
    } else {
      guard project.stereoOutInserts.count < ChannelStrip.maximumInserts else {
        errorMessage = "Stereo Out has no free slot for Mastering. Remove one of its plug-ins first."
        return nil
      }
      mastering = OngakuEffect.mastering.makeReference()
      guard perform(AddInsert(mastering, to: Project.stereoOutID), named: "Add Mastering") else { return nil }
    }
    // A plug-in loads in the background (out of process), so wait for it.
    for _ in 0..<200 {
      guard project.stereoOutInserts.contains(where: { $0.id == mastering.id }) else { return nil }
      if engine.withInsertAudioUnit(mastering.id, onTrack: Project.stereoOutID, { _ in }) != nil { return mastering }
      try? await Task.sleep(for: .milliseconds(50))
    }
    errorMessage = "Mastering couldn’t be loaded."
    return nil
  }
}

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
