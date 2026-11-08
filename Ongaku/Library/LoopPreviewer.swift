//
//  LoopPreviewer.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// The sound the Loop Browser is previewing, if any: click a sound to hear it in the song's
/// tempo and key, click it again (or another) to stop.
@MainActor
@Observable
final class LoopPreviewer {
  static let shared = LoopPreviewer()

  /// The item playing, by library and path.
  private(set) var playing: SoundLibraryItem.ID?
  private(set) var playingLibrary: UUID?
  @ObservationIgnored private let engine = LoopPreviewEngine()

  private init() {
    engine.onFinish = { [weak self] in
      self?.playing = nil
      self?.playingLibrary = nil
    }
  }

  func isPlaying(_ item: SoundLibraryItem, in library: UUID) -> Bool {
    playing == item.id && playingLibrary == library
  }

  /// Plays an item matched to the song at `position`, or stops it if it's the one playing.
  func toggle(_ item: SoundLibraryItem, at url: URL, in library: UUID, project: Project, position: Tick) {
    if isPlaying(item, in: library) {
      stop()
      return
    }
    let isLoop = item.kind == .loop
    let rate = isLoop ? item.tempo.map { project.tempoMap.tempo(at: position) / $0 } ?? 1 : 1
    let semitones = isLoop ? item.semitones(toMatch: project.key(at: position)) : 0
    do {
      try engine.play(url, loops: isLoop, rate: rate, semitones: semitones, deviceUID: AppSettings.audioOutput.deviceUID)
      playing = item.id
      playingLibrary = library
    } catch {
      stop()
    }
  }

  func stop() {
    engine.stop()
    playing = nil
    playingLibrary = nil
  }
}
