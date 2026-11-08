//
//  SoundLibraryScanner.swift
//  OngakuCore
//

import Foundation
import Synchronization

/// Indexes a library folder: finds the sounds in it, in standard formats, and reads what
/// their files say about them. Files unchanged since the last scan keep their entries, so
/// rescanning a large library only reads what's new.
public enum SoundLibraryScanner {
  /// Audio files; `.sdir` is Space Designer's impulse responses, which are AIFF files.
  public static let audioExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "caf", "mp3", "m4a", "flac", "sdir"]
  /// Sampler instrument formats Apple's sampler (or Ongaku) can play.
  public static let instrumentExtensions: Set<String> = ["exs", "sf2", "dls", "sfz", "aupreset"]
  /// Packages whose insides aren't library sounds: songs keep their own copies of audio.
  public static let skippedPackageExtensions: Set<String> = [
    "logicx", "band", "ongaku", "app", "component", "vst", "vst3", "aaxplugin", "bundle-backup",
  ]

  /// Every sound under `root`, reusing `previous` entries for files that haven't changed.
  /// Calls `progress` (from any thread) with the number of files done every so often; stops
  /// early with `CancellationError` once `shouldStop` (also asked from any thread) says so.
  public static func scan(
    _ root: URL, reusing previous: [SoundLibraryItem] = [], progress: @Sendable (Int) -> Void = { _ in },
    shouldStop: @Sendable () -> Bool = { false }
  ) throws -> [SoundLibraryItem] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
    else { return [] }
    let known = Dictionary(previous.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    let rootPath = root.standardizedFileURL.path(percentEncoded: false)
    let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

    // First find the files (quick), then read the new and changed ones, several at a time.
    var found: [(url: URL, path: String, modified: Double, size: Int64)] = []
    for case let url as URL in enumerator {
      let fileExtension = url.pathExtension.lowercased()
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
      if values.isDirectory == true {
        if skippedPackageExtensions.contains(fileExtension) { enumerator.skipDescendants() }
        continue
      }
      guard values.isRegularFile == true,
        audioExtensions.contains(fileExtension) || instrumentExtensions.contains(fileExtension)
      else { continue }
      let fullPath = url.standardizedFileURL.path(percentEncoded: false)
      guard fullPath.hasPrefix(prefix) else { continue }
      found.append((url, String(fullPath.dropFirst(prefix.count)), values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0,
        Int64(values.fileSize ?? 0)))
      if found.count % 1000 == 0, shouldStop() { throw CancellationError() }
    }

    var items = [SoundLibraryItem?](repeating: nil, count: found.count)
    var toRead: [Int] = []
    for (index, file) in found.enumerated() {
      if let old = known[file.path], old.modified == file.modified, old.size == file.size {
        items[index] = old
      } else {
        toRead.append(index)
      }
    }
    progress(found.count - toRead.count)

    let batch = 64
    let batches = (toRead.count + batch - 1) / batch
    let state = Mutex((read: [Int: SoundLibraryItem](), done: found.count - toRead.count, cancelled: false))
    DispatchQueue.concurrentPerform(iterations: batches) { batchIndex in
      guard !state.withLock({ $0.cancelled }) else { return }
      var read: [Int: SoundLibraryItem] = [:]
      for index in toRead[(batchIndex * batch)..<min(toRead.count, (batchIndex + 1) * batch)] {
        let file = found[index]
        read[index] = item(at: file.url, path: file.path, modified: file.modified, size: file.size)
      }
      let stop = shouldStop()
      let done = state.withLock { state in
        state.read.merge(read) { first, _ in first }
        state.done += read.count
        if stop { state.cancelled = true }
        return state.done
      }
      progress(done)
    }
    let result = state.withLock { $0 }
    if result.cancelled { throw CancellationError() }
    for (index, item) in result.read { items[index] = item }
    return items.compactMap { $0 }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }

  /// Reads one file's entry.
  public static func item(at url: URL, path: String, modified: Double, size: Int64) -> SoundLibraryItem {
    var item = SoundLibraryItem(path: path, kind: .oneShot, modified: modified, size: size)
    let folders = item.folders
    if instrumentExtensions.contains(url.pathExtension.lowercased()) {
      item.kind = .instrument
      item.category = SoundCategory.classify([item.name] + folders.reversed())
      if ["sf2", "dls"].contains(item.fileExtension) { item.presets = SoundBankReader.presets(in: url) }
      return item
    }
    let metadata = (try? AudioFileMetadata.read(url)) ?? AudioFileMetadata()
    return describe(item, with: metadata)
  }

  /// Fills in an entry from a file's metadata.
  public static func describe(_ entry: SoundLibraryItem, with metadata: AudioFileMetadata) -> SoundLibraryItem {
    var item = entry
    item.kind = metadata.isLoop ? .loop : .oneShot
    item.duration = metadata.duration
    if isImpulseResponse(item) {
      item.kind = .impulseResponse
      item.category = .fx
      return item
    }
    if metadata.isLoop {
      item.beats = metadata.beats
      item.tempo = metadata.tempo.map { ($0 * 100).rounded() / 100 }
      item.timeSignature = metadata.timeSignature
    }
    item.keyTonic = metadata.keyTonic
    item.keyMode = metadata.keyMode
    item.genre = metadata.genre
    item.tags = ([metadata.subcategory].compactMap { $0 } + metadata.descriptors)
    item.hasMIDI = metadata.hasMIDI
    item.category = SoundCategory.classify(
      [metadata.category, metadata.subcategory].compactMap { $0 } + [item.name] + item.folders.reversed())
    return item
  }
}

extension SoundLibraryScanner {
  /// Whether an audio file is an impulse response: a Space Designer file, or audio in a
  /// folder of them ("Impulse Responses", "IRs").
  static func isImpulseResponse(_ item: SoundLibraryItem) -> Bool {
    if item.fileExtension == "sdir" { return true }
    return item.folders.contains { folder in
      let name = folder.lowercased()
      return name.contains("impulse") || name == "ir" || name == "irs"
    }
  }
}

/// A library's index as saved between launches.
public struct SoundLibraryIndex: Codable, Sendable {
  /// Version 2 lists SoundFont and DLS presets; version 3 finds impulse responses.
  public static let currentVersion = 3

  public var version: Int
  public var items: [SoundLibraryItem]
  public var scanned: Date

  public init(items: [SoundLibraryItem], scanned: Date = .now) {
    version = Self.currentVersion
    self.items = items
    self.scanned = scanned
  }
}
