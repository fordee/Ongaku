//
//  SoundLibraries.swift
//  Ongaku
//

import AppKit
import CoreServices
import Foundation
import OngakuCore
import OngakuEngine
import os

/// The sound library folders the user added in Settings: Logic's or GarageBand's library,
/// sample packs, SoundFont collections — any folder of sounds in standard formats.
///
/// Folders are remembered with security-scoped bookmarks (Ongaku is sandboxed) and indexed in
/// the background; each index is saved in Application Support, so it's there straight away at
/// the next launch and only new or changed files are read again. Folders are watched, and
/// rescanned a moment after their files change.
@MainActor
@Observable
final class SoundLibraries {
  /// Replaced only by previews, with made-up libraries.
  static var shared = SoundLibraries()

  /// A library folder, as remembered between launches.
  struct Location: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var bookmark: Data
    /// Where it was last found, to show when it can't be found now.
    var path: String
  }

  enum Status: Equatable {
    case ready
    case scanning(filesDone: Int)
    /// The folder couldn't be found (an unplugged drive, say) or read.
    case unavailable(String)
  }

  struct Library: Identifiable {
    var location: Location
    /// The folder, while it can be read.
    var url: URL?
    var items: [SoundLibraryItem] = []
    /// Each item's `searchText`, folded once.
    var searchTexts: [String] = []
    var status: Status = .ready
    var scanned: Date?

    var id: UUID { location.id }
    var name: String { location.name }

    func count(of kind: SoundLibraryItem.Kind) -> Int {
      items.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }

    /// Where an item's file is.
    func url(for item: SoundLibraryItem) -> URL? {
      url?.appending(path: item.path, directoryHint: .notDirectory)
    }
  }

  private(set) var libraries: [Library] = []
  /// Changes whenever any library's items do, so views can cache what they derive.
  private(set) var revision = 0

  private static let locationsKey = "SoundLibraryLocations"
  nonisolated private static let logger = Logger(subsystem: "net.4dware.Ongaku", category: "SoundLibraries")
  private var scans: [UUID: Task<Void, Never>] = [:]
  /// Per library, its audio files by lower-cased file name, for finding instruments' samples.
  /// Made when first needed, and forgotten when the library's index changes.
  private var audioFilesByName: [UUID: [String: [String]]] = [:]
  private var watchers: [UUID: FolderWatcher] = [:]
  private let defaults: UserDefaults
  private let indexDirectory: URL

  /// The shared libraries, from the user's settings. Tests make their own, with their own
  /// defaults and index folder.
  init(defaults: UserDefaults = .standard, indexDirectory: URL? = nil) {
    self.defaults = defaults
    self.indexDirectory = indexDirectory
      ?? URL.applicationSupportDirectory.appending(path: "Sound Libraries", directoryHint: .isDirectory)
    let locations = (defaults.data(forKey: Self.locationsKey))
      .flatMap { try? JSONDecoder().decode([Location].self, from: $0) } ?? []
    libraries = locations.map { Library(location: $0) }
    for library in libraries { open(library.id) }
  }

  /// Libraries that are only in memory, for previews.
  init(previewItems: [String: [SoundLibraryItem]]) {
    defaults = UserDefaults(suiteName: "SoundLibrariesPreview") ?? .standard
    indexDirectory = URL.temporaryDirectory
    libraries = previewItems.sorted { $0.key < $1.key }.map { name, items in
      Library(
        location: Location(id: UUID(), name: name, bookmark: Data(), path: "/Library/\(name)"),
        url: URL(fileURLWithPath: "/Library/\(name)"), items: items, searchTexts: items.map(\.searchText), scanned: .now)
    }
  }

  func library(withID id: UUID) -> Library? {
    libraries.first { $0.id == id }
  }

  // MARK: - Adding and removing

  /// Adds a folder the user chose (its URL carries the sandbox's permission to read it).
  /// A folder that's already a library, or inside one, is rescanned instead.
  @discardableResult
  func add(_ folder: URL) throws -> UUID {
    let isAccessing = folder.startAccessingSecurityScopedResource()
    defer { if isAccessing { folder.stopAccessingSecurityScopedResource() } }
    let path = folder.standardizedFileURL.path(percentEncoded: false)
    if let existing = libraries.first(where: { $0.location.path == path }) {
      rescan(existing.id)
      return existing.id
    }
    let bookmark = try folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
    let location = Location(id: UUID(), name: folder.lastPathComponent, bookmark: bookmark, path: path)
    libraries.append(Library(location: location))
    saveLocations()
    open(location.id)
    return location.id
  }

  /// Asks for folders to add, as Settings and the Loop Browser's Add Library… do.
  static func chooseFolders() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    // Some libraries live in packages (Logic's "Logic Pro Library.bundle"), which the panel
    // would otherwise treat as files that can be neither opened nor chosen.
    panel.treatsFilePackagesAsDirectories = true
    panel.prompt = "Add Library"
    panel.message = "Choose folders of loops, samples or sampler instruments."
    guard panel.runModal() == .OK else { return }
    for url in panel.urls {
      do {
        try shared.add(url)
      } catch {
        NSAlert(error: error).runModal()
      }
    }
  }

  func remove(_ id: UUID) {
    guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
    scans[id]?.cancel()
    scans[id] = nil
    watchers[id] = nil
    libraries[index].url?.stopAccessingSecurityScopedResource()
    libraries.remove(at: index)
    audioFilesByName[id] = nil
    try? FileManager.default.removeItem(at: indexURL(for: id))
    saveLocations()
    revision += 1
  }

  func rename(_ id: UUID, to name: String) {
    let name = name.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, let index = libraries.firstIndex(where: { $0.id == id }) else { return }
    libraries[index].location.name = name
    saveLocations()
    revision += 1
  }

  private func saveLocations() {
    let locations = libraries.map(\.location)
    defaults.set(try? JSONEncoder().encode(locations), forKey: Self.locationsKey)
  }

  // MARK: - Opening and scanning

  /// Finds a library's folder, loads its saved index, then rescans it in the background.
  private func open(_ id: UUID) {
    guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
    var library = libraries[index]
    var isStale = false
    guard let url = try? URL(resolvingBookmarkData: library.location.bookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale),
      url.startAccessingSecurityScopedResource()
    else {
      library.status = .unavailable("Can’t find “\(library.location.path)”.")
      libraries[index] = library
      return
    }
    library.url = url
    // A moved folder: remember where it is now.
    let path = url.standardizedFileURL.path(percentEncoded: false)
    if isStale || path != library.location.path {
      if let bookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]) {
        library.location.bookmark = bookmark
      }
      library.location.path = path
    }
    if let saved = loadIndex(for: id) {
      library.items = saved.items
      library.searchTexts = saved.items.map(\.searchText)
      library.scanned = saved.scanned
    }
    libraries[index] = library
    saveLocations()
    revision += 1
    rescan(id)
    watchers[id] = FolderWatcher(url: url) { [weak self] in
      self?.rescan(id)
    }
  }

  /// Indexes a library again, reading only files that are new or changed.
  func rescan(_ id: UUID) {
    guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
    guard let url = libraries[index].url else {
      open(id)
      return
    }
    scans[id]?.cancel()
    let previous = libraries[index].items
    libraries[index].status = .scanning(filesDone: 0)
    let indexURL = indexURL(for: id)
    scans[id] = Task { [weak self] in
      let progress = ScanProgress()
      let reporter = Task { [weak self] in
        // Show progress a few times a second, not on every batch.
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(250))
          self?.setStatus(.scanning(filesDone: progress.value), for: id)
        }
      }
      defer { reporter.cancel() }
      do {
        let items = try await Self.scan(url, reusing: previous, progress: progress)
        guard !Task.isCancelled else { return }
        self?.finishScan(id, items: items, saveTo: indexURL)
      } catch is CancellationError {
        return
      } catch {
        self?.setStatus(.unavailable(error.localizedDescription), for: id)
      }
    }
  }

  @concurrent
  private nonisolated static func scan(_ url: URL, reusing previous: [SoundLibraryItem], progress: ScanProgress) async throws -> [SoundLibraryItem] {
    // The scanner reads on threads of its own, which can't see the task: cancelling the
    // task sets a flag they check.
    try await withTaskCancellationHandler {
      try SoundLibraryScanner.scan(url, reusing: previous, progress: { progress.value = $0 }, shouldStop: { progress.isCancelled })
    } onCancel: {
      progress.isCancelled = true
    }
  }

  private func setStatus(_ status: Status, for id: UUID) {
    guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
    // Progress only while still scanning (a report can arrive just after the end).
    if case .scanning = status, libraries[index].status == .ready { return }
    if libraries[index].status != status { libraries[index].status = status }
  }

  private func finishScan(_ id: UUID, items: [SoundLibraryItem], saveTo indexURL: URL) {
    guard let index = libraries.firstIndex(where: { $0.id == id }) else { return }
    scans[id] = nil
    libraries[index].status = .ready
    let scanned = Date.now
    libraries[index].scanned = scanned
    guard items != libraries[index].items else { return }
    libraries[index].items = items
    libraries[index].searchTexts = items.map(\.searchText)
    audioFilesByName[id] = nil
    revision += 1
    let saved = SoundLibraryIndex(items: items, scanned: scanned)
    let directory = indexDirectory
    Task.detached(priority: .utility) {
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: indexURL, options: .atomic)
      } catch {
        Self.logger.error("Couldn’t save a sound library index: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - Instruments

  /// The library an instrument is in: the one it came from, or else one of the same name
  /// that has the file (the same library added on another Mac), or else any that has it.
  func library(for instrument: SamplerInstrument) -> Library? {
    func has(_ library: Library) -> Bool { library.items.contains { $0.path == instrument.path } }
    if let library = instrument.libraryID.flatMap(library(withID:)), library.url != nil { return library }
    let available = libraries.filter { $0.url != nil }
    return available.first { $0.name == instrument.libraryName && has($0) } ?? available.first(where: has)
  }

  /// The file to load for a library instrument. An EXS instrument whose samples have moved
  /// (the library is on another drive, say) is copied with its samples' folders pointing at
  /// where they are now, found by name in the added libraries; one from a newer Logic is
  /// copied with its zones in the classic layout Apple's sampler reads; and one whose groups
  /// set velocity layers or volume has them put on its zones, which Apple's sampler reads.
  func url(for instrument: SamplerInstrument) async throws -> URL {
    guard let library = library(for: instrument), let url = library.url(for: SoundLibraryItem(path: instrument.path, kind: .instrument)),
      FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false))
    else { throw EngineError.missingSamplerInstrument(instrument) }
    if instrument.fileExtension == "sfz" { return try samplerPreset(fromSFZ: url, instrument: instrument, in: library) }
    guard instrument.fileExtension == "exs", let data = try? Data(contentsOf: url), let exs = EXSInstrument(data: data) else {
      return url
    }
    let fileManager = FileManager.default
    var fixed = exs.relocatingSamples { sample in
      if fileManager.isReadableFile(atPath: sample.path) { return nil }
      return locateSample(named: sample.fileName, near: sample.folder, preferring: library.id)
    }
    // Newer Logic instruments' longer zones, which Apple's sampler can't read.
    if let classic = EXSInstrument(data: fixed ?? data)?.withClassicZones() { fixed = classic }
    if let grouped = EXSInstrument(data: fixed ?? data)?.withGroupSettingsOnZones() { fixed = grouped }
    guard let relocated = fixed else { return url }
    // Keep the instrument's own name: the sampler shows it.
    // One folder per instrument (its path, flattened), so instruments of the same name don't clash.
    let flattened = instrument.path.replacingOccurrences(of: "/", with: " ▸ ")
    let folder = URL.cachesDirectory.appending(path: "Sampler Instruments/\(library.id.uuidString)/\(flattened)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appending(path: url.lastPathComponent)
    try relocated.write(to: copy, options: .atomic)
    return copy
  }

  /// Apple's sampler doesn't read SFZ, so an SFZ instrument plays as a sampler preset made
  /// from it (see `SamplerPreset`), kept in the caches folder. Samples are found beside the
  /// instrument as the file says, or else by name in the libraries.
  private func samplerPreset(fromSFZ url: URL, instrument: SamplerInstrument, in library: Library) throws -> URL {
    guard let text = Self.text(of: url) else { throw EngineError.missingSamplerInstrument(instrument) }
    let folder = url.deletingLastPathComponent()
    let sfz = SFZInstrument(text: text) { Self.text(of: folder.appending(path: $0)) }
    let fileManager = FileManager.default
    var found = 0
    let preset = SamplerPreset.make(sfz, name: instrument.name) { sample in
      let beside = folder.appending(path: sample).standardizedFileURL
      if fileManager.isReadableFile(atPath: beside.path(percentEncoded: false)) {
        found += 1
        return beside
      }
      let name = String(sample.split(separator: "/").last ?? "")
      let near = (folder.path(percentEncoded: false) as NSString).appendingPathComponent((sample as NSString).deletingLastPathComponent)
      guard let other = self.locateSample(named: name, near: near, preferring: library.id) else { return nil }
      found += 1
      return URL(fileURLWithPath: other).appending(path: name)
    }
    guard found > 0 else {
      throw EngineError.samplerInstrumentFailed(instrument, NSError(domain: NSOSStatusErrorDomain, code: -43))
    }
    let flattened = instrument.path.replacingOccurrences(of: "/", with: " ▸ ")
    let cache = URL.cachesDirectory.appending(path: "Sampler Instruments/\(library.id.uuidString)/\(flattened)", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
    let presetURL = cache.appending(path: "\(instrument.name).aupreset")
    // As XML: Apple's sampler won't load a preset saved as a binary property list.
    try PropertyListSerialization.data(fromPropertyList: preset, format: .xml, options: 0).write(to: presetURL, options: .atomic)
    return presetURL
  }

  /// A text file's contents: UTF-8, or Latin-1, which older SFZ files often are.
  private static func text(of url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
  }

  /// The folder (an absolute path) of the audio file called `name` in the libraries, the one
  /// whose folders best match `folder` (where the instrument says it was), in `libraryID`'s
  /// library first.
  func locateSample(named name: String, near folder: String, preferring libraryID: UUID) -> String? {
    // Older instruments name folders the classic Mac way: "Macintosh HD:Library:…".
    let wanted = folder.split { $0 == "/" || $0 == ":" }.map { $0.lowercased() }
    var best: (score: Int, folder: String)?
    let ordered = libraries.filter { $0.id == libraryID } + libraries.filter { $0.id != libraryID }
    for library in ordered {
      guard let root = library.url else { continue }
      for path in audioFiles(in: library)[name.lowercased()] ?? [] {
        let folders = path.split(separator: "/").dropLast().map { $0.lowercased() }
        // How many of the folders it was in, from the innermost out, it's still in.
        let score = zip(wanted.reversed(), folders.reversed()).prefix { $0 == $1 }.count
        if best == nil || score > best!.score {
          best = (score, root.appending(path: folders.isEmpty ? "" : path.split(separator: "/").dropLast().joined(separator: "/"))
            .path(percentEncoded: false))
        }
      }
      // A match in the instrument's own library wins over others.
      if best != nil, library.id == libraryID { break }
    }
    return best.map { $0.folder.hasSuffix("/") && $0.folder.count > 1 ? String($0.folder.dropLast()) : $0.folder }
  }

  private func audioFiles(in library: Library) -> [String: [String]] {
    if let known = audioFilesByName[library.id] { return known }
    var names: [String: [String]] = [:]
    for item in library.items where item.kind != .instrument {
      let fileName = String(item.path.split(separator: "/").last ?? "").lowercased()
      names[fileName, default: []].append(item.path)
    }
    audioFilesByName[library.id] = names
    return names
  }

  // MARK: - Saved indexes

  private func indexURL(for id: UUID) -> URL {
    indexDirectory.appending(path: "\(id.uuidString).json")
  }

  private func loadIndex(for id: UUID) -> SoundLibraryIndex? {
    guard let data = try? Data(contentsOf: indexURL(for: id)),
      let index = try? JSONDecoder().decode(SoundLibraryIndex.self, from: data),
      index.version == SoundLibraryIndex.currentVersion
    else { return nil }
    return index
  }
}

/// The files done so far in a scan, written from the scanner's threads.
nonisolated private final class ScanProgress: Sendable {
  private let done = OSAllocatedUnfairLock(initialState: 0)
  private let cancelled = OSAllocatedUnfairLock(initialState: false)

  var value: Int {
    get { done.withLock { $0 } }
    set { done.withLock { $0 = newValue } }
  }

  var isCancelled: Bool {
    get { cancelled.withLock { $0 } }
    set { cancelled.withLock { $0 = newValue } }
  }
}

/// Calls back on the main actor a couple of seconds after files change anywhere in a
/// folder (FSEvents), so a sample pack copied in shows up without rescanning by hand.
@MainActor
final class FolderWatcher {
  private var stream: FSEventStreamRef?
  private let changed: @MainActor () -> Void
  private var pending: Task<Void, Never>?

  init(url: URL, changed: @escaping @MainActor () -> Void) {
    self.changed = changed
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
      MainActor.assumeIsolated { watcher.filesChanged() }
    }
    guard let stream = FSEventStreamCreate(
      nil, callback, &context, [url.path(percentEncoded: false)] as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone))
    else { return }
    FSEventStreamSetDispatchQueue(stream, .main)
    FSEventStreamStart(stream)
    self.stream = stream
  }

  isolated deinit {
    pending?.cancel()
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }

  private func filesChanged() {
    // Copying a pack in sends many events: wait for them to stop.
    pending?.cancel()
    pending = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      self?.changed()
    }
  }
}
