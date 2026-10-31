//
//  ProjectWindowModel+Freeze.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// Freezing tracks, like Logic's Freeze buttons: a track is rendered to a file in the
/// background, then plays that file instead of running its instrument and plug-ins.
extension ProjectWindowModel {
  /// The track header's Freeze button: freezes the track, unfreezes it, or stops a freeze
  /// that's still rendering.
  func toggleFreeze(_ trackID: Track.ID) {
    if freezeTasks[trackID] != nil {
      cancelFreeze(trackID)
    } else if project.track(withID: trackID)?.isFrozen == true {
      perform(UnfreezeTrack(trackID))
    } else {
      freezeTrack(trackID)
    }
  }

  /// Freezes or unfreezes the selected tracks (Track › Freeze Tracks): unfreezes them if
  /// they're all frozen, otherwise freezes the rest.
  func toggleFreezeSelectedTracks() {
    let tracks = project.tracks.filter { selectedTrackIDs.contains($0.id) && $0.canFreeze }
    if !tracks.isEmpty, tracks.allSatisfy(\.isFrozen) {
      perform(CompositeCommand("Unfreeze Tracks", commands: tracks.map { UnfreezeTrack($0.id) }))
    } else {
      for track in tracks where !track.isFrozen {
        freezeTrack(track.id)
      }
    }
  }

  /// Whether the selected tracks would be unfrozen (rather than frozen) by Track › Freeze.
  var selectedTracksAreFrozen: Bool {
    let tracks = project.tracks.filter { selectedTrackIDs.contains($0.id) && $0.canFreeze }
    return !tracks.isEmpty && tracks.allSatisfy(\.isFrozen)
  }

  var canFreezeSelectedTracks: Bool {
    project.tracks.contains { selectedTrackIDs.contains($0.id) && $0.canFreeze }
  }

  func freezeTrack(_ trackID: Track.ID) {
    guard freezeTasks[trackID] == nil, let track = project.track(withID: trackID), track.canFreeze, !track.isFrozen
    else { return }
    // Plug-in windows store their settings as they close: do that now, so the render uses
    // them and nothing can change them while it runs.
    closePluginWindows(of: track)
    let url: URL
    do {
      url = try document.newFreezeFileURL()
    } catch {
      errorMessage = "“\(track.name)” couldn’t be frozen: \(error.localizedDescription)"
      return
    }

    freezeProgress[trackID] = 0
    let sampleRate = engine.outputSampleRate
    freezeTasks[trackID] = Task { [weak self, document] in
      // Flexed regions freeze as they play, so their renders have to be ready first.
      await self?.finishFlexRenders()
      guard let rendered = self?.projectWithCurrentPluginStates(), let started = self?.project, !Task.isCancelled,
        let source = rendered.track(withID: trackID)
      else {
        self?.finishFreeze(trackID)
        return
      }
      do {
        let reference = try await ProjectBouncer.freeze(
          trackID, in: rendered, sampleRate: sampleRate, to: url,
          locateAudioFile: { [weak document] file in document?.url(for: file) }
        ) { [weak self] progress in
          self?.freezeProgress[trackID] = progress
        }
        guard let self else { return }
        self.finishFreeze(trackID)
        // Edits made while it rendered would be missing from the file.
        guard let now = self.project.track(withID: trackID), Self.rendersTheSame(now, as: started.track(withID: trackID)) else {
          try? FileManager.default.removeItem(at: url)
          self.errorMessage = "“\(track.name)” changed while it was being frozen. Freeze it again."
          return
        }
        document.adoptFreezeFile(reference, at: url)
        self.perform(FreezeTrack(trackID, file: reference, renderedChannel: source.channel))
      } catch {
        try? FileManager.default.removeItem(at: url)
        guard let self else { return }
        self.finishFreeze(trackID)
        if !(error is CancellationError) {
          self.errorMessage = "“\(track.name)” couldn’t be frozen: \(error.localizedDescription)"
        }
      }
    }
  }

  func cancelFreeze(_ trackID: Track.ID) {
    freezeTasks[trackID]?.cancel()
  }

  private func finishFreeze(_ trackID: Track.ID) {
    freezeTasks[trackID] = nil
    freezeProgress[trackID] = nil
  }

  /// Whether two versions of a track would render the same freeze file.
  private static func rendersTheSame(_ track: Track, as other: Track?) -> Bool {
    guard let other else { return false }
    return track.regions == other.regions && track.channel.instrument == other.channel.instrument
      && track.channel.inserts == other.channel.inserts && track.freezeMode == other.freezeMode
  }

  private func closePluginWindows(of track: Track) {
    var pluginIDs = track.channel.inserts.map(\.id)
    if case .audioUnit(let instrument) = track.channel.instrument {
      pluginIDs.append(instrument.id)
    }
    for id in pluginIDs {
      pluginWindows[id]?.close()
    }
  }
}
