//
//  ProjectArchive.swift
//  OngakuCore
//

import CryptoKit
import Foundation

/// Reads and writes the contents of an `.ongaku` project package.
///
/// Package layout:
///
///     MySong.ongaku/
///       Project.json      the serialized `Project`
///       Audio Files/      audio referenced by `Project.audioFiles`
///       Freeze Files/     renders frozen tracks play (`Track.freezeFile`)
///       Plug-in Settings/ large plug-in states (`PluginReference.stateFileName`)
///
/// The JSON is pretty-printed with sorted keys so projects diff cleanly in version control.
public enum ProjectArchive {
  public static let projectFileName = "Project.json"
  public static let audioFilesDirectoryName = "Audio Files"
  public static let freezeFilesDirectoryName = "Freeze Files"
  public static let pluginSettingsDirectoryName = "Plug-in Settings"
  /// Plug-in states bigger than this are kept in their own files rather than in the JSON,
  /// where they'd be base64 and rewritten on every save (a sampler's audio, say).
  public static let largePluginStateSize = 64 * 1024

  public enum ArchiveError: Error, LocalizedError, Equatable {
    case unsupportedFormatVersion(Int)

    public var errorDescription: String? {
      switch self {
      case .unsupportedFormatVersion(let version):
        "This project was saved by a newer version of Ongaku Studio (format \(version))."
      }
    }
  }

  public static func encode(_ project: Project) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    // A project opened from an older file is saved in the current format, so an older build
    // refuses it rather than silently dropping what it can't read.
    var current = project
    current.formatVersion = Project.currentFormatVersion
    return try encoder.encode(current)
  }

  public static func decode(_ data: Data) throws -> Project {
    // Check the version first so a newer file gives a clear error instead of a decoding failure.
    struct Header: Decodable {
      var formatVersion: Int
    }
    let decoder = JSONDecoder()
    let header = try decoder.decode(Header.self, from: data)
    guard header.formatVersion <= Project.currentFormatVersion else {
      throw ArchiveError.unsupportedFormatVersion(header.formatVersion)
    }
    // Older versions are migrated here as the format evolves.
    return try decoder.decode(Project.self, from: data)
  }
}

// MARK: - Large plug-in states

extension ProjectArchive {
  /// The project as Project.json stores it: plug-in states over `largePluginStateSize`
  /// replaced by the names of files holding them, and those files. A file is named for its
  /// plug-in and contents, so an unchanged state keeps its file from save to save.
  public static func separatingLargePluginStates(_ project: Project) -> (project: Project, files: [String: Data]) {
    var stored = project
    var files: [String: Data] = [:]
    stored.updatePlugins { plugin in
      guard let state = plugin.state, state.count > largePluginStateSize else {
        plugin.stateFileName = nil
        return
      }
      let digest = SHA256.hash(data: state).prefix(8).map { String(format: "%02x", $0) }.joined()
      let name = "\(plugin.id.uuidString)-\(digest).plist"
      files[name] = state
      plugin.state = nil
      plugin.stateFileName = name
    }
    return (stored, files)
  }

  /// Puts states kept in files back into the plug-ins that name them. A missing file
  /// leaves the plug-in at its defaults.
  public static func restoringPluginStates(_ project: inout Project, from file: (String) -> Data?) {
    project.updatePlugins { plugin in
      guard let name = plugin.stateFileName else { return }
      plugin.state = file(name)
      plugin.stateFileName = nil
    }
  }
}

extension Project {
  /// Changes every plug-in reference: each track's instrument and inserts, and Stereo Out's.
  mutating func updatePlugins(_ change: (inout PluginReference) -> Void) {
    for insert in stereoOutInserts.indices {
      change(&stereoOutInserts[insert])
    }
    for index in tracks.indices {
      if case .audioUnit(var instrument) = tracks[index].channel.instrument {
        change(&instrument)
        tracks[index].channel.instrument = .audioUnit(instrument)
      }
      for insert in tracks[index].channel.inserts.indices {
        change(&tracks[index].channel.inserts[insert])
      }
    }
  }
}
