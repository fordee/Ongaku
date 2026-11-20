//
//  AudioFileCommands.swift
//  OngakuCore
//

import Foundation

/// Registers an audio file that has been copied into the project package.
public struct AddAudioFile: EditCommand {
  public var file: AudioFileReference

  public init(_ file: AudioFileReference) {
    self.file = file
  }

  public var actionName: String { "Add Audio File" }

  public func apply(to project: inout Project) throws {
    guard project.audioFile(withID: file.id) == nil else { throw EditError.duplicateID(file.id) }
    guard file.sampleRate > 0, file.channelCount > 0, file.frameCount > 0 else {
      throw EditError.invalidValue("“\(file.fileName)” doesn’t contain any audio.")
    }
    project.audioFiles.append(file)
  }
}

extension Region {
  /// A region that plays a whole audio file from `start`, sized to the file's duration at the
  /// project tempo.
  public static func audio(
    for file: AudioFileReference, at start: Tick, tempoMap: TempoMap, name: String? = nil
  ) -> Region {
    let end = tempoMap.tickPosition(atSeconds: tempoMap.seconds(at: start) + file.duration)
    let fallbackName = (file.fileName as NSString).deletingPathExtension
    return Region(
      name: name ?? fallbackName, start: start, length: max(end - start, Tick(1)),
      content: .audio(AudioRegionContent(fileID: file.id)))
  }
}

/// Swaps an audio file for an edited copy (from the Audio File Editor): every region and
/// take that played the old file plays the new one, as if the file itself had changed. The
/// old file stays in the package, so undo brings it back.
public struct ReplaceAudioFile: EditCommand {
  public var oldFileID: AudioFileReference.ID
  public var newFile: AudioFileReference
  public var actionName: String

  public init(_ oldFileID: AudioFileReference.ID, with newFile: AudioFileReference, actionName: String) {
    self.oldFileID = oldFileID
    self.newFile = newFile
    self.actionName = actionName
  }

  public func apply(to project: inout Project) throws {
    guard let old = project.audioFile(withID: oldFileID) else { throw EditError.audioFileNotFound(oldFileID) }
    // Regions count frames into the file, so an edit mustn't move them.
    guard newFile.frameCount == old.frameCount, newFile.sampleRate == old.sampleRate else {
      throw EditError.invalidValue("The edited file must keep the original's length and sample rate.")
    }
    try AddAudioFile(newFile).apply(to: &project)
    func repoint(_ content: inout RegionContent) {
      if case .audio(var audio) = content, audio.fileID == oldFileID {
        audio.fileID = newFile.id
        content = .audio(audio)
      }
    }
    for track in project.tracks.indices {
      for region in project.tracks[track].regions.indices {
        repoint(&project.tracks[track].regions[region].content)
        if var folder = project.tracks[track].regions[region].takeFolder {
          for take in folder.takes.indices { repoint(&folder.takes[take].content) }
          project.tracks[track].regions[region].takeFolder = folder
        }
      }
    }
    project.audioFiles.removeAll { $0.id == oldFileID }
  }
}
