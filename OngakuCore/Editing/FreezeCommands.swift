//
//  FreezeCommands.swift
//  OngakuCore
//

import Foundation

/// Freezes a track, as Logic's Freeze button does: from now on it plays `file`, a render of
/// its regions through its instrument (and, in Pre Fader mode, its inserts), so they stop
/// using the processor. The engine renders the file first; this records it.
public struct FreezeTrack: EditCommand {
  public var trackID: Track.ID
  public var file: AudioFileReference
  /// The channel strip the file was rendered with, so plug-in settings changed in windows
  /// that were still open are kept for when the track is unfrozen.
  public var renderedChannel: ChannelStrip?

  public init(_ trackID: Track.ID, file: AudioFileReference, renderedChannel: ChannelStrip? = nil) {
    self.trackID = trackID
    self.file = file
    self.renderedChannel = renderedChannel
  }

  public var actionName: String { "Freeze Track" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    guard project.tracks[index].canFreeze else {
      throw EditError.invalidValue("Aux tracks and summing stacks can’t be frozen.")
    }
    if let renderedChannel {
      project.tracks[index].channel.instrument = renderedChannel.instrument
      project.tracks[index].channel.inserts = renderedChannel.inserts
    }
    project.tracks[index].freezeFile = file
    project.tracks[index].isRecordArmed = false
  }
}

/// Unfreezes a track: it plays its regions through its plug-ins again, and can be edited.
public struct UnfreezeTrack: EditCommand {
  public var trackID: Track.ID

  public init(_ trackID: Track.ID) {
    self.trackID = trackID
  }

  public var actionName: String { "Unfreeze Track" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    project.tracks[index].freezeFile = nil
  }
}

/// Chooses what freezing a track renders. A frozen track has to be unfrozen first.
public struct SetFreezeMode: EditCommand {
  public var trackID: Track.ID
  public var mode: FreezeMode

  public init(_ trackID: Track.ID, to mode: FreezeMode) {
    self.trackID = trackID
    self.mode = mode
  }

  public var actionName: String { "Set Freeze Mode" }

  public func apply(to project: inout Project) throws {
    let index = try project.requireTrackIndex(trackID)
    project.tracks[index].freezeMode = mode
  }
}

extension EditError {
  /// Editing a frozen track's regions or the plug-ins rendered into its freeze file.
  static func trackIsFrozen(_ track: Track) -> EditError {
    .invalidValue("“\(track.name)” is frozen. Unfreeze it to change its regions or plug-ins.")
  }
}

extension Project {
  /// Throws if an edit from `previous` to this project changed what a frozen track's freeze
  /// file was rendered from: its regions, its instrument, its inserts (in Pre Fader mode) or
  /// its freeze mode; or record-enabled it. Freezing and unfreezing themselves are allowed. `ProjectEditor` checks
  /// this after every command, so no command can get round it.
  public func checkFrozenTracksUnchanged(from previous: Project) throws {
    for track in tracks where track.isFrozen {
      guard let old = previous.track(withID: track.id), old.freezeFile == track.freezeFile else { continue }
      let changed = old.regions != track.regions
        || old.channel.instrument != track.channel.instrument
        || old.freezeMode != track.freezeMode
        || (track.freezesInserts && old.channel.inserts != track.channel.inserts)
        || (track.isRecordArmed && !old.isRecordArmed)
      if changed {
        throw EditError.trackIsFrozen(track)
      }
    }
    // Regions can't be moved onto a frozen track either; that changes its regions above.
  }

  /// The project as playback hears it: each frozen track becomes an audio track playing its
  /// freeze file from the start of the project, without the instrument (and, in Pre Fader
  /// mode, the inserts) that were rendered into it. Its fader, pan, sends, output and
  /// automation are unchanged, since they come after the freeze.
  ///
  /// A freeze file that `isAvailable` says is missing leaves its track playing as if it
  /// weren't frozen, so a lost file never silences a track.
  public func playingFreezeFiles(isAvailable: (AudioFileReference) -> Bool = { _ in true }) -> Project {
    var played = self
    for index in played.tracks.indices {
      guard let file = played.tracks[index].freezeFile, isAvailable(file) else { continue }
      var track = played.tracks[index]
      let seconds = Double(file.frameCount) / file.sampleRate
      let region = Region(
        id: file.id, name: track.name, start: .zero, length: max(Tick(1), tempoMap.tickPosition(atSeconds: seconds)),
        content: .audio(AudioRegionContent(fileID: file.id)))
      track.kind = .audio
      track.regions = [region]
      track.channel.instrument = nil
      track.channel.audioInput = nil
      if track.freezesInserts {
        track.channel.inserts = []
      }
      track.isRecordArmed = false
      played.tracks[index] = track
      if played.audioFile(withID: file.id) == nil {
        played.audioFiles.append(file)
      }
    }
    return played
  }
}
