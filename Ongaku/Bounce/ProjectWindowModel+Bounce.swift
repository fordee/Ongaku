//
//  ProjectWindowModel+Bounce.swift
//  Ongaku
//

import AppKit
import Foundation
import OngakuCore
import OngakuEngine
import UniformTypeIdentifiers

/// The Bounce dialog: render the mix (or every track, for Export All Tracks) to temporary
/// files, then save them where the person chooses.
@MainActor
@Observable
final class BounceModel {
  enum Phase {
    case options
    case rendering(progress: Double)
    case finished(BounceResult)
    /// Export All Tracks: one file per track, in `folder`.
    case finishedTracks(folder: URL, files: [URL])
  }

  /// The mix, or each track on its own (Logic's Export All Tracks as Audio Files).
  enum Target {
    case mix, allTracks
  }

  private static let settingsKey = "BounceSettings"
  private static let trackOptionsKey = "ExportTracksOptions"

  var phase = Phase.options
  /// The last settings used, remembered between bounces and launches.
  var settings: BounceSettings {
    didSet { UserDefaults.standard.set(try? JSONEncoder().encode(settings), forKey: Self.settingsKey) }
  }
  /// While the bounce waits for flexed regions to finish processing, before rendering.
  var isWaitingForFlex = false
  let range: Range<Tick>
  let target: Target
  /// What each track's file keeps of its channel strip, for Export All Tracks.
  var trackOptions: TrackRenderOptions {
    didSet { UserDefaults.standard.set(try? JSONEncoder().encode(trackOptions), forKey: Self.trackOptionsKey) }
  }
  @ObservationIgnored private(set) var task: Task<Void, Never>?

  init(range: Range<Tick>, target: Target = .mix) {
    self.range = range
    self.target = target
    settings = UserDefaults.standard.data(forKey: Self.settingsKey)
      .flatMap { try? JSONDecoder().decode(BounceSettings.self, from: $0) } ?? BounceSettings()
    trackOptions = UserDefaults.standard.data(forKey: Self.trackOptionsKey)
      .flatMap { try? JSONDecoder().decode(TrackRenderOptions.self, from: $0) } ?? TrackRenderOptions(includesVolumeAndPan: true)
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
        if target == .allTracks {
          let files = try await bounceTracks(of: project, to: folder, settings: settings, locateAudioFile: locateAudioFile)
          phase = .finishedTracks(folder: folder, files: files)
          return
        }
        let bouncer = ProjectBouncer(project: project, locateAudioFile: locateAudioFile)
        let result = try await bouncer.bounce(range, settings: settings, to: url) { [weak self] progress in
          self?.phase = .rendering(progress: progress)
        }
        phase = .finished(result)
      } catch is CancellationError {
        try? FileManager.default.removeItem(at: folder)
        phase = .options
      } catch {
        phase = .options
        onError("The bounce failed: \(error.localizedDescription)")
      }
    }
  }

  /// Export All Tracks: each track with regions on its own, over the whole range so the files
  /// line up, named in track order ("01 Drums.wav"). Normalizing would change the balance
  /// between them, so it's left off.
  private func bounceTracks(
    of project: Project, to folder: URL, settings: BounceSettings, locateAudioFile: @escaping AudioFileLocator
  ) async throws -> [URL] {
    var settings = settings
    settings.normalize = false
    let tracks = project.tracks.compactMap { track in project.isolating(track.id, options: trackOptions).map { (track, $0) } }
    guard !tracks.isEmpty else { throw BounceError.nothingToBounce }
    var files: [URL] = []
    for (index, (track, alone)) in tracks.enumerated() {
      let number = String(format: "%02d", index + 1)
      let name = track.name.replacing(/[\/:]/, with: "-")
      let url = folder.appending(path: "\(number) \(name).\(settings.format.fileExtension)")
      let bouncer = ProjectBouncer(project: alone, locateAudioFile: locateAudioFile)
      _ = try await bouncer.bounce(range, settings: settings, to: url) { [weak self] progress in
        self?.phase = .rendering(progress: (Double(index) + progress) / Double(tracks.count))
      }
      files.append(url)
    }
    return files
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  /// Removes the rendered files once they have been saved, or when the dialog closes.
  func discardFile() {
    cancel()
    switch phase {
    case .finished(let result): try? FileManager.default.removeItem(at: result.url.deletingLastPathComponent())
    case .finishedTracks(let folder, _): try? FileManager.default.removeItem(at: folder)
    default: break
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

  /// File › Export All Tracks as Audio Files (⇧⌘E): the Bounce dialog, making a file of each
  /// track on its own.
  func showExportAllTracks() {
    guard let range = project.bounceRange else {
      errorMessage = BounceError.nothingToBounce.localizedDescription
      return
    }
    engine.stop()
    bounce = BounceModel(range: range, target: .allTracks)
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
    if case .finishedTracks(_, let files) = bounce?.phase {
      saveTrackFiles(files)
      return
    }
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

  /// Export All Tracks' Save…: asks for a folder, then moves the track files into it,
  /// replacing files of the same names.
  private func saveTrackFiles(_ files: [URL]) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "Save Here"
    panel.message = "Choose a folder for the \(files.count) track files."
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    do {
      for file in files {
        let destination = folder.appending(path: file.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
          _ = try FileManager.default.replaceItemAt(destination, withItemAt: file)
        } else {
          try FileManager.default.moveItem(at: file, to: destination)
        }
      }
      closeBounce()
    } catch {
      errorMessage = "The track files couldn’t be saved: \(error.localizedDescription)"
    }
  }

  /// The project as it plays, with every plug-in's current settings, including changes made
  /// in plug-in windows that are still open (those are only stored in the project when they
  /// close). Flexed regions play their renders, as they do live, and plug-ins live playback
  /// left out (their process kept quitting) are left out too. Bounces, freezes and the mix
  /// analyses all render this, so they hear what plays.
  func projectWithCurrentPluginStates() -> Project {
    var project = playedProject
    project.removePlugins(engine.stoppedPluginIDs)
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
      for effectIndex in project.tracks[index].channel.midiEffects.indices {
        guard case .audioUnit(var plugin) = project.tracks[index].channel.midiEffects[effectIndex].settings,
          let state = engine.midiEffectState(plugin.id, onTrack: trackID)
        else { continue }
        plugin.state = state
        project.tracks[index].channel.midiEffects[effectIndex].settings = .audioUnit(plugin)
      }
    }
    for insertIndex in project.stereoOutInserts.indices {
      if let state = engine.insertState(project.stereoOutInserts[insertIndex].id, onTrack: Project.stereoOutID) {
        project.stereoOutInserts[insertIndex].state = state
      }
    }
    return project
  }

  /// "bar 1 to bar 9" or, for a cycle, "Cycle range, bar 5 to bar 9".
  func describeBounceRange(_ range: Range<Tick>) -> String {
    let positions = describeRange(range)
    return project.cycle.isEnabled ? "Cycle range, \(positions)" : positions
  }

  /// "bar 1 to bar 9 beat 3".
  func describeRange(_ range: Range<Tick>) -> String {
    let tempoMap = project.tempoMap
    return "\(Self.barBeat(tempoMap.musicalPosition(at: range.lowerBound))) to \(Self.barBeat(tempoMap.musicalPosition(at: range.upperBound)))"
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

extension Project {
  /// Takes plug-ins out of every channel strip: an instrument plug-in leaves its track
  /// silent, as it is live.
  fileprivate mutating func removePlugins(_ pluginIDs: Set<PluginReference.ID>) {
    guard !pluginIDs.isEmpty else { return }
    for index in tracks.indices {
      tracks[index].channel.inserts.removeAll { pluginIDs.contains($0.id) }
      tracks[index].channel.midiEffects.removeAll { $0.plugin.map { pluginIDs.contains($0.id) } ?? false }
      if case .audioUnit(let instrument) = tracks[index].channel.instrument, pluginIDs.contains(instrument.id) {
        tracks[index].channel.instrument = nil
      }
    }
    stereoOutInserts.removeAll { pluginIDs.contains($0.id) }
  }
}
