//
//  PluginManager.swift
//  Ongaku
//

import Foundation
import Observation
import OngakuEngine

/// Which installed plug-ins the menus offer, as in Logic's Plug-in Manager: each can be
/// turned off, and each can be checked (see `PluginCheck`). One that fails its check is
/// left out until it's checked again, or turned on anyway; a new version is checked afresh.
@MainActor
@Observable
final class PluginManager {
  static let shared = PluginManager()

  /// A check's outcome for one version of a plug-in.
  struct Check: Codable, Equatable {
    var version: String
    var passed: Bool
    var message: String?
  }

  private static let turnedOffKey = "PluginManager.turnedOff"
  private static let turnedOnAnywayKey = "PluginManager.turnedOnAnyway"
  private static let checksKey = "PluginManager.checks"

  private let defaults: UserDefaults
  /// Plug-ins the person turned off, and failed ones they turned on anyway (by entry ID).
  private(set) var turnedOff: Set<String>
  private(set) var turnedOnAnyway: Set<String>
  private(set) var checks: [String: Check]
  /// The plug-ins being checked, and how many are left.
  private(set) var checking: String?
  private(set) var remainingChecks = 0
  /// Bumped whenever what the menus offer changes.
  private(set) var revision = 0

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    turnedOff = Set(defaults.stringArray(forKey: Self.turnedOffKey) ?? [])
    turnedOnAnyway = Set(defaults.stringArray(forKey: Self.turnedOnAnywayKey) ?? [])
    checks = (defaults.data(forKey: Self.checksKey)).flatMap { try? JSONDecoder().decode([String: Check].self, from: $0) } ?? [:]
  }

  // MARK: - What the menus offer

  /// Whether the menus offer a plug-in: it's on, and it hasn't failed a check of this
  /// version (unless it was turned on anyway).
  func isOffered(_ entry: InstrumentLibrary.Entry) -> Bool {
    _ = revision
    guard !turnedOff.contains(entry.id) else { return false }
    return !hasFailed(entry) || turnedOnAnyway.contains(entry.id)
  }

  func offered(_ entries: [InstrumentLibrary.Entry]) -> [InstrumentLibrary.Entry] {
    entries.filter(isOffered)
  }

  /// The last check of this version of a plug-in, if it's been checked.
  func check(of entry: InstrumentLibrary.Entry) -> Check? {
    checks[entry.id].flatMap { $0.version == entry.version ? $0 : nil }
  }

  func hasFailed(_ entry: InstrumentLibrary.Entry) -> Bool {
    check(of: entry)?.passed == false
  }

  /// Turns a plug-in on or off in the menus. Turning on a failed one uses it anyway.
  func setOffered(_ isOffered: Bool, _ entry: InstrumentLibrary.Entry) {
    if isOffered {
      turnedOff.remove(entry.id)
      if hasFailed(entry) { turnedOnAnyway.insert(entry.id) }
    } else {
      turnedOff.insert(entry.id)
      turnedOnAnyway.remove(entry.id)
    }
    save()
  }

  // MARK: - Checking

  /// Checks plug-ins one at a time, in the background of the Settings window.
  func check(_ entries: [InstrumentLibrary.Entry]) async {
    remainingChecks += entries.count
    defer { checking = nil }
    for entry in entries {
      checking = entry.name
      let result = await PluginCheck.check(entry)
      remainingChecks -= 1
      record(result, for: entry)
    }
  }

  func record(_ result: PluginCheck.Result, for entry: InstrumentLibrary.Entry) {
    switch result {
    case .passed:
      checks[entry.id] = Check(version: entry.version, passed: true)
      turnedOnAnyway.remove(entry.id)
    case .failed(let message):
      checks[entry.id] = Check(version: entry.version, passed: false, message: message)
    }
    save()
  }

  private func save() {
    defaults.set(turnedOff.sorted(), forKey: Self.turnedOffKey)
    defaults.set(turnedOnAnyway.sorted(), forKey: Self.turnedOnAnywayKey)
    defaults.set(try? JSONEncoder().encode(checks), forKey: Self.checksKey)
    revision += 1
  }
}
