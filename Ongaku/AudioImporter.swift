//
//  AudioImporter.swift
//  Ongaku
//

import AVFAudio
import Foundation
import OngakuCore
import UniformTypeIdentifiers

/// Copies audio files into a document's staging folder and describes them for the project.
///
/// Imported files go to a temporary staging folder first because an unsaved document has no
/// package on disk yet. On save, the document writer copies staged files into the package's
/// "Audio Files" folder.
enum AudioImporter {
  enum ImportError: LocalizedError {
    case unreadable(fileName: String, underlying: any Error)

    var errorDescription: String? {
      switch self {
      case .unreadable(let fileName, let underlying):
        "“\(fileName)” isn’t an audio file Ongaku Studio can read (\(underlying.localizedDescription))."
      }
    }
  }

  /// Whether a dropped URL looks like audio, before trying to open it.
  nonisolated static func isAudioFile(_ url: URL) -> Bool {
    guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
    return type.conforms(to: .audio)
  }

  /// Reads the format of `source`, then copies it into `stagingDirectory` under `fileName`.
  @concurrent
  nonisolated static func stage(
    _ source: URL, as fileName: String, in stagingDirectory: URL
  ) async throws -> (reference: AudioFileReference, stagedURL: URL) {
    let format: AVAudioFormat
    let frameCount: AVAudioFramePosition
    do {
      let file = try AVAudioFile(forReading: source)
      format = file.fileFormat
      frameCount = file.length
    } catch {
      throw ImportError.unreadable(fileName: source.lastPathComponent, underlying: error)
    }

    try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    let destination = stagingDirectory.appending(path: fileName)
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: source, to: destination)

    let reference = AudioFileReference(
      fileName: fileName, sampleRate: format.sampleRate,
      channelCount: Int(format.channelCount), frameCount: frameCount)
    return (reference, destination)
  }

  /// A file name that isn't used by another audio file in the project, keeping the original
  /// name where possible ("Vocal.wav", then "Vocal 2.wav").
  static func uniqueFileName(for source: URL, in project: Project) -> String {
    let existing = Set(project.audioFiles.map { $0.fileName.lowercased() })
    let base = source.deletingPathExtension().lastPathComponent
    let pathExtension = source.pathExtension
    var candidate = source.lastPathComponent
    var number = 2
    while existing.contains(candidate.lowercased()) {
      candidate = pathExtension.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(pathExtension)"
      number += 1
    }
    return candidate
  }
}
