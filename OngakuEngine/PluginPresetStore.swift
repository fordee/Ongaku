//
//  PluginPresetStore.swift
//  OngakuEngine
//

import Foundation
import OngakuCore

/// The presets saved in Ongaku for other makers' plug-ins: each is the plug-in's whole
/// state (`fullState`, as a property list), in a folder per plug-in. A plug-in's own user
/// presets would go in ~/Library/Audio/Presets, which a sandboxed app can't count on
/// writing to; Ongaku's own plug-ins keep theirs themselves.
public struct PluginPresetStore: Sendable {
  public let folder: URL

  public init(folder: URL) {
    self.folder = folder
  }

  /// In Ongaku's Application Support folder.
  public static var standard: PluginPresetStore {
    let support = URL.applicationSupportDirectory.appending(path: "Ongaku Studio", directoryHint: .isDirectory)
    return PluginPresetStore(folder: support.appending(path: "Plug-in Presets", directoryHint: .isDirectory))
  }

  /// A plug-in's presets, by name.
  public func names(for plugin: PluginReference) -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder(for: plugin), includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == Self.fileExtension }
      .map { $0.deletingPathExtension().lastPathComponent }
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  public func state(named name: String, for plugin: PluginReference) -> Data? {
    try? Data(contentsOf: url(named: name, for: plugin))
  }

  /// Saves a preset, replacing one of the same name.
  public func save(_ state: Data, named name: String, for plugin: PluginReference) throws {
    try FileManager.default.createDirectory(at: folder(for: plugin), withIntermediateDirectories: true)
    try state.write(to: url(named: name, for: plugin), options: .atomic)
  }

  public func delete(named name: String, for plugin: PluginReference) throws {
    try FileManager.default.removeItem(at: url(named: name, for: plugin))
  }

  // MARK: - Files

  private static let fileExtension = "plist"

  /// Named for the plug-in's four-character codes, which stay the same from version to
  /// version (its name may not).
  private func folder(for plugin: PluginReference) -> URL {
    let codes = [plugin.componentManufacturer, plugin.componentType, plugin.componentSubType].map(Self.code)
    return folder.appending(path: codes.joined(separator: "-"), directoryHint: .isDirectory)
  }

  private func url(named name: String, for plugin: PluginReference) -> URL {
    // A name can't make its own path: slashes and a leading dot are replaced.
    var safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    if safe.hasPrefix(".") { safe = "_" + safe.dropFirst() }
    return folder(for: plugin).appending(path: safe).appendingPathExtension(Self.fileExtension)
  }

  /// A four-character code as text, or its number when it isn't printable.
  private static func code(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
    guard bytes.allSatisfy({ (0x21...0x7E).contains($0) && $0 != 0x2F }) else { return String(format: "%08X", value) }
    return String(decoding: bytes, as: UTF8.self)
  }
}
