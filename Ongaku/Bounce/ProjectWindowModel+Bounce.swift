//
//  ProjectWindowModel+Bounce.swift
//  Ongaku
//

import AppKit
import Foundation
import OngakuCore
import OngakuEngine
import UniformTypeIdentifiers

/// The Bounce dialog: render the mix to a temporary file, then save it where the person
/// chooses.
@MainActor
@Observable
final class BounceModel {
  enum Phase {
    case options
    case rendering(progress: Double)
    case finished(BounceResult)
  }

  private static let settingsKey = "BounceSettings"

  var phase = Phase.options
  /// The last settings used, remembered between bounces and launches.
  var settings: BounceSettings {
    didSet { UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey) }
  }
  /// While the bounce waits for flexed regions to finish processing, before rendering.
  var isWaitingForFlex = false
  let range: Range<Tick>
  @ObservationIgnored private var task: Task<Void, Never>?

  init(range: Range<Tick>) {
    self.range = range
    settings = UserDefaults.standard.data(forKey: Self.settingsKey)
      .flatMap { try? JSONDecoder().decode(BounceSettings.self, from: $0) } ?? BounceSettings()
  }

  var isRendering: Bool {
    if case .rendering = phase { true } else { false }
  }

  /// Renders the project `project` gives, once it's ready (it waits for flex renders).
  func start(
    project: @escaping @MainActor () async -> Project, name: String, locateAudioFile: @escaping AudioFileLocator,
    onError: @escaping (String) -> Void
  ) {
    // A folder per bounce, so windows with the same song name can't overwrite each other.
    let folder = FileManager.default.temporaryDirectory.appending(path: "Bounces/\(UUID().uuidString)", directoryHint: .isDirectory)
    let url = folder.appending(path: "\(name).\(settings.format.fileExtension)")
    let settings = settings
    let range = range
    phase = .rendering(progress: 0)
    task = Task {
      do {
        isWaitingForFlex = true
        let project = await project()
        isWaitingForFlex = false
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bouncer = ProjectBouncer(project: project, locateAudioFile: locateAudioFile)
        let result = try await bouncer.bounce(range, settings: settings, to: url) { [weak self] progress in
          self?.phase = .rendering(progress: progress)
        }
        phase = .finished(result)
      } catch is CancellationError {
        try? FileManager.default.removeItem(at: url)
        phase = .options
      } catch {
        phase = .options
        onError("The bounce failed: \(error.localizedDescription)")
      }
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  /// Removes the rendered file once it has been saved, or when the dialog closes.
  func discardFile() {
    cancel()
    if case .finished(let result) = phase {
      try? FileManager.default.removeItem(at: result.url.deletingLastPathComponent())
    }
  }
}

extension ProjectWindowModel {
  /// Opens the Bounce dialog, stopping playback first.
  func showBounce() {
    guard let range = project.bounceRange else {
      errorMessage = BounceError.nothingToBounce.localizedDescription
      return
    }
    engine.stop()
    bounce = BounceModel(range: range)
  }

  func startBounce() {
    guard let bounce else { return }
    // Flexed regions bounce as they'll play, so their renders have to be ready first.
    bounce.start(
      project: { [weak self] in
        await self?.finishFlexRenders()
        return self?.projectWithCurrentPluginStates() ?? Project()
      }, name: exportFileName,
      locateAudioFile: { [weak document] file in document?.url(for: file) },
      onError: { [weak self] message in self?.errorMessage = message })
  }

  func closeBounce() {
    bounce?.discardFile()
    bounce = nil
  }

  /// Save…: asks where to put the bounce, then moves the rendered file there. An AppKit save
  /// panel, not SwiftUI's fileExporter: exporting the file as a Transferable crashed (macOS
  /// 27.2), SwiftUI giving it an empty file name.
  func saveBounce() {
    guard let bounce, case .finished(let result) = bounce.phase else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [bounce.settings.format.contentType]
    panel.nameFieldStringValue = result.url.lastPathComponent
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    do {
      // The panel has already asked whether to replace a file that's there.
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: result.url)
      } else {
        try FileManager.default.moveItem(at: result.url, to: destination)
      }
      closeBounce()
    } catch {
      errorMessage = "The bounce couldn’t be saved: \(error.localizedDescription)"
    }
  }

  /// The project as it plays, with every plug-in's current settings, including changes made
  /// in plug-in windows that are still open (those are only stored in the project when they
  /// close). Flexed regions play their renders, as they do live.
  func projectWithCurrentPluginStates() -> Project {
    var project = playedProject
    for index in project.tracks.indices {
      let trackID = project.tracks[index].id
      if case .audioUnit(var instrument) = project.tracks[index].channel.instrument,
        let state = engine.instrumentState(forTrack: trackID)
      {
        instrument.state = state
        project.tracks[index].channel.instrument = .audioUnit(instrument)
      }
      for insertIndex in project.tracks[index].channel.inserts.indices {
        let pluginID = project.tracks[index].channel.inserts[insertIndex].id
        if let state = engine.insertState(pluginID, onTrack: trackID) {
          project.tracks[index].channel.inserts[insertIndex].state = state
        }
      }
    }
    for insertIndex in project.stereoOutInserts.indices {
      if let state = engine.insertState(project.stereoOutInserts[insertIndex].id, onTrack: Project.stereoOutID) {
        project.stereoOutInserts[insertIndex].state = state
      }
    }
    return project
  }

  /// "Bars 1–9" or, for a cycle, "Cycle: bars 5–9".
  func describeBounceRange(_ range: Range<Tick>) -> String {
    let tempoMap = project.tempoMap
    let start = tempoMap.musicalPosition(at: range.lowerBound)
    let end = tempoMap.musicalPosition(at: range.upperBound)
    let positions = "\(Self.barBeat(start)) to \(Self.barBeat(end))"
    return project.cycle.isEnabled ? "Cycle range, \(positions)" : positions
  }

  private static func barBeat(_ position: MusicalPosition) -> String {
    position.beat == 1 && position.division == 1 && position.tick == 0
      ? "bar \(position.bar)" : "bar \(position.bar) beat \(position.beat)"
  }
}

extension BounceSettings.FileFormat {
  var contentType: UTType {
    switch self {
    case .wav: .wav
    case .aiff: .aiff
    case .m4a: .mpeg4Audio
    }
  }
}
