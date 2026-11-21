//
//  StemSplitView.swift
//  Ongaku
//

import OngakuCore
import OngakuEngine
import SwiftUI

/// The Stem Splitter dialog's state: which region, whether to mute it, and the split's
/// progress once it has started.
@MainActor
@Observable
final class StemSplitModel {
  let regionID: Region.ID
  var mutesOriginal = true
  var progress: Double?
  @ObservationIgnored var task: Task<Void, Never>?

  init(regionID: Region.ID) {
    self.regionID = regionID
  }
}

extension ProjectWindowModel {
  /// The audio region Split into Stems would split: the one selected.
  var stemSplitTarget: Region? {
    guard selectedRegionIDs.count == 1, let id = selectedRegionIDs.first, let region = project.region(withID: id),
      case .audio = region.content
    else { return nil }
    return region
  }

  /// The model the Stem Splitter runs, bundled with the app.
  static var stemModelURL: URL? { Bundle.main.url(forResource: "htdemucs", withExtension: "th") }

  /// Edit › Split into Stems…: opens its dialog for the selected audio region.
  func showStemSplit() {
    guard let region = stemSplitTarget else {
      errorMessage = "Select one audio region to split into stems."
      return
    }
    engine.stop()
    stemSplit = StemSplitModel(regionID: region.id)
  }

  func closeStemSplit() {
    stemSplit?.task?.cancel()
    stemSplit = nil
  }

  /// Splits the region's recording (the part it plays) into drums, bass, other and vocals,
  /// each on a new track in a folder stack below. Returns the work, for tests to wait on.
  @discardableResult
  func startStemSplit() -> Task<Void, Never>? {
    guard let dialog = stemSplit, let region = project.region(withID: dialog.regionID), case .audio(let content) = region.content,
      let file = project.audioFiles.first(where: { $0.id == content.fileID }), let url = document.url(for: file)
    else { return nil }
    // The part of the file the region plays.
    let seconds = (project.tempoMap.seconds(at: region.end) - project.tempoMap.seconds(at: region.start)) * content.stretch
    let frames = Int64(seconds * file.sampleRate)
    let mutesOriginal = dialog.mutesOriginal
    let trackName = project.tracks.first { $0.regions.contains { $0.id == region.id } }?.name ?? region.name
    dialog.progress = 0
    let task = Task { [weak self, weak dialog, document] in
      let folder = FileManager.default.temporaryDirectory.appending(path: "Stems \(UUID().uuidString)", directoryHint: .isDirectory)
      defer { try? FileManager.default.removeItem(at: folder) }
      do {
        let stems = try await Task.detached(priority: .userInitiated) {
          try await StemSplitter.split(
            fileAt: url, startFrame: content.fileStartFrame, frames: frames, model: ProjectWindowModel.stemModelURL, into: folder,
            baseName: region.name
          ) { progress in Task { @MainActor in dialog?.progress = progress } }
        }.value
        guard let self, !Task.isCancelled else { return }
        var staged: [SplitIntoStems.Stem] = []
        for stem in stems {
          let reference = try await document.stageAudio(
            from: stem.url, reservedNames: document.savedAudioFileNames.union(staged.map(\.file.fileName)))
          staged.append(SplitIntoStems.Stem(name: stem.name, file: reference))
        }
        let tracks = staged.map { makeTrack(name: "\(trackName) \($0.name)", kind: .audio) }
        let stack = makeTrack(name: "\(region.name) Stems", kind: .aux)
        if perform(SplitIntoStems(region.id, stems: staged, into: tracks, stack: stack, mutesOriginal: mutesOriginal)) {
          selectedTrackID = stack.id
        }
      } catch is CancellationError {
      } catch {
        self?.errorMessage = "“\(region.name)” couldn’t be split: \(error.localizedDescription)"
      }
      self?.stemSplit = nil
    }
    dialog.task = task
    return task
  }
}

/// Logic's Stem Splitter: splits a recording into drums, bass, vocals and everything else,
/// on this Mac.
struct StemSplitView: View {
  let model: ProjectWindowModel
  @Bindable var dialog: StemSplitModel

  var body: some View {
    let region = model.project.region(withID: dialog.regionID)
    VStack(alignment: .leading, spacing: 16) {
      Text("Split “\(region?.name ?? "")” into Stems").font(.headline)
      if let progress = dialog.progress {
        VStack(alignment: .leading, spacing: 6) {
          ProgressView(value: progress)
          Text(progress < 0.03 ? "Loading the model…" : "Separating… \(Int(progress * 100)) %")
            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
          Text("This runs on this Mac and takes about a minute for a three-minute song.")
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(minHeight: 110)
      } else {
        Text("Separates the recording into Drums, Bass, Other and Vocals, each on its own new track in a folder stack below this one. It runs on this Mac; nothing is sent anywhere.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Toggle("Mute the original region", isOn: $dialog.mutesOriginal)
          .help("Mutes the region you split, so the stems play instead. Unmute it to compare.")
        if ProjectWindowModel.stemModelURL == nil {
          Label("The Stem Splitter's model isn't installed with this copy of the app.", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .font(.callout)
        }
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { model.closeStemSplit() }
          .keyboardShortcut(.cancelAction)
        if dialog.progress == nil {
          Button("Split") { model.startStemSplit() }
            .keyboardShortcut(.defaultAction)
            .disabled(ProjectWindowModel.stemModelURL == nil)
        }
      }
    }
    .padding(20)
    .frame(width: 420)
    .accessibilityIdentifier("stem-split")
  }
}

#Preview("Stem Splitter") {
  StemSplitPreview()
}

/// Keeps the window model alive: the dialog refers to it without owning it.
private struct StemSplitPreview: View {
  @State private var window: ProjectWindowModel = {
    let file = AudioFileReference(fileName: "Band Take.wav", sampleRate: 48_000, channelCount: 2, frameCount: 48_000 * 180)
    let region = Region(name: "Band Take", start: .zero, length: .quarterNotes(360), content: .audio(AudioRegionContent(fileID: file.id)))
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [Track(name: "Band", kind: .audio, regions: [region])], audioFiles: [file])))
    window.stemSplit = StemSplitModel(regionID: region.id)
    return window
  }()

  var body: some View {
    if let dialog = window.stemSplit {
      StemSplitView(model: window, dialog: dialog)
    }
  }
}
