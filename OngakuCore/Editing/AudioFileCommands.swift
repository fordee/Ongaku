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
