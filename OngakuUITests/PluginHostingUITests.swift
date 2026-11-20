//
//  PluginHostingUITests.swift
//  OngakuUITests
//

import AppKit
import XCTest

/// Other makers' plug-ins: the Plug-in Manager, menus by maker, MIDI FX and presets.
/// Tests that need an installed plug-in use whatever is on the Mac (Cardinal, here) and
/// are skipped where there's none.
final class PluginHostingUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  /// The Plug-ins tab lists other makers' plug-ins; one turned off there leaves the
  /// instrument menu, and comes back when it's turned on.
  @MainActor
  func testPluginManagerTurnsPlugInsOffInTheMenus() throws {
    let app = launchWithNewProject()
    let maker = try XCTUnwrap(firstInstrumentMaker(in: app), "No Audio Unit instruments by other makers are installed")
    let plugin = maker.plugin

    openPluginSettings(in: app)
    // The checkbox reads its plug-in's name, maker and check.
    let row = app.checkBoxes.matching(NSPredicate(format: "label BEGINSWITH %@", plugin)).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5), "\(plugin) is listed")
    let status = ["Not checked", "Works", "It "].contains { row.label.contains($0) }
    XCTAssertTrue(status, "Each plug-in shows its check: \(row.label)")
    attachScreenshot(of: app, named: "Plug-ins Settings")
    if (row.value as? Int) == 0 { row.click() }  // Start from on.
    row.click()
    XCTAssertEqual(row.value as? Int, 0, "Turned off")
    app.typeKey("w", modifierFlags: .command)

    XCTAssertFalse(instrumentMenuOffers(maker, in: app), "A plug-in that's turned off isn't offered")

    openPluginSettings(in: app)
    row.click()
    XCTAssertEqual(row.value as? Int, 1, "Turned on again")
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(instrumentMenuOffers(maker, in: app), "…and is offered again")
  }

  /// The MIDI FX menu has Ongaku's effects and an Audio Units submenu.
  @MainActor
  func testMIDIFXMenuOffersAudioUnits() throws {
    let app = launchWithNewProject()
    let strip = openMixerStrip(in: app)
    strip.descendants(matching: .any)["add-midi-effect"].firstMatch.click()
    XCTAssertTrue(app.menuItems["Arpeggiator"].firstMatch.waitForExistence(timeout: 5), "Ongaku's MIDI effects are listed")
    app.menuItems["Audio Units"].firstMatch.hover()
    let none = app.menuItems["No Audio Unit MIDI effects are installed"].firstMatch
    let anyMaker = app.menuItems.matching(NSPredicate(format: "title != ''")).count > 0
    XCTAssertTrue(none.waitForExistence(timeout: 3) || anyMaker, "The Audio Units submenu opens")
    attachScreenshot(of: app, named: "MIDI FX Menu")
    app.typeKey(.escape, modifierFlags: [])
    app.typeKey(.escape, modifierFlags: [])
  }

  /// An Apple effect's window has a Presets menu: factory presets, and presets saved in
  /// Ongaku, which can be deleted. Its slot has no Side Chain menu, as it has no side chain.
  @MainActor
  func testPresetsAreSavedChosenAndDeletedFromThePluginWindow() throws {
    let app = launchWithNewProject()
    let strip = openMixerStrip(in: app)
    strip.descendants(matching: .any)["add-insert"].firstMatch.click()
    // Apple's Distortion, not the Ongaku section's Distortion category, which comes first.
    XCTAssertTrue(app.menuItems["Distortion"].firstMatch.waitForExistence(timeout: 5))
    let distortion = try XCTUnwrap(app.menuItems.matching(identifier: "Distortion").allElementsBoundByIndex.last)
    distortion.click()
    let slot = strip.descendants(matching: .any)["insert-slot"].firstMatch
    XCTAssertTrue(slot.waitForExistence(timeout: 5))

    slot.rightClick()
    XCTAssertTrue(app.menuItems["Bypass"].firstMatch.waitForExistence(timeout: 3))
    XCTAssertFalse(app.menuItems["Side Chain"].exists, "No side chain input, so no Side Chain menu")
    app.typeKey(.escape, modifierFlags: [])

    slot.click()
    let window = app.windows.matching(NSPredicate(format: "title CONTAINS 'Distortion'")).firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10), "The plug-in's window opens")
    let presets = window.descendants(matching: .any)["plugin-presets"].firstMatch
    XCTAssertTrue(presets.waitForExistence(timeout: 5), "It has a Presets menu")

    deleteLeftoverTestPresets(with: presets, in: app)
    presets.click()
    XCTAssertTrue(app.menuItems["Save Preset As…"].firstMatch.waitForExistence(timeout: 3))
    XCTAssertTrue(app.menuItems["Factory Presets"].firstMatch.exists, "Apple's distortion has factory presets")
    attachScreenshot(of: app, named: "Presets Menu")
    app.menuItems["Save Preset As…"].firstMatch.click()

    let name = "UI Test \(UUID().uuidString.prefix(6))"
    let field = app.dialogs.textFields.firstMatch.exists ? app.dialogs.textFields.firstMatch : app.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5), "Save asks for a name")
    // It starts with the current preset's name: replace it.
    field.click()
    field.typeKey(.rightArrow, modifierFlags: .command)
    field.typeKey(.delete, modifierFlags: .command)
    field.typeText(name)
    app.buttons["Save"].firstMatch.click()

    presets.click()
    XCTAssertTrue(app.menuItems[name].firstMatch.waitForExistence(timeout: 3), "The saved preset is listed")
    app.menuItems["Delete Preset"].firstMatch.hover()
    let delete = app.menuItems.matching(identifier: name).allElementsBoundByIndex.last ?? app.menuItems[name].firstMatch
    delete.click()

    presets.click()
    XCTAssertTrue(app.menuItems["Save Preset As…"].firstMatch.waitForExistence(timeout: 3))
    XCTAssertFalse(app.menuItems[name].exists, "Deleted")
    app.typeKey(.escape, modifierFlags: [])
  }

  // MARK: - Helpers

  /// Presets an earlier, interrupted run saved (their names contain "UI Test").
  @MainActor
  private func deleteLeftoverTestPresets(with presets: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<10 {
      presets.click()
      let delete = app.menuItems["Delete Preset"].firstMatch
      guard delete.waitForExistence(timeout: 2) else { break }
      delete.hover()
      let leftover = delete.menus.firstMatch.menuItems.matching(NSPredicate(format: "title CONTAINS 'UI Test'")).firstMatch
      guard leftover.waitForExistence(timeout: 2) else { break }
      leftover.click()
    }
    closeMenus(in: app)
  }

  /// The first other maker in the instrument menu's Audio Units submenu, and one of its
  /// plug-ins.
  @MainActor
  private func firstInstrumentMaker(in app: XCUIApplication) -> (maker: String, plugin: String)? {
    openInstrumentAudioUnits(in: app)
    defer { closeMenus(in: app) }
    let excluded: Set<String> = ["No Audio Unit instruments are installed", ""]
    // The submenu's items are the makers; hover the first to see its plug-ins.
    let submenu = app.menuItems["Audio Units"].firstMatch.menus.firstMatch
    guard submenu.waitForExistence(timeout: 3) else { return nil }
    guard let maker = submenu.children(matching: .menuItem).allElementsBoundByIndex.map(\.title).first(where: { !excluded.contains($0) })
    else { return nil }
    submenu.menuItems[maker].firstMatch.hover()
    let plugins = submenu.menuItems[maker].firstMatch.menus.firstMatch
    guard plugins.waitForExistence(timeout: 3), let plugin = plugins.children(matching: .menuItem).allElementsBoundByIndex.first?.title
    else { return nil }
    return (maker, plugin)
  }

  /// Whether the instrument menu's Audio Units submenu lists the maker's plug-in.
  @MainActor
  private func instrumentMenuOffers(_ entry: (maker: String, plugin: String), in app: XCUIApplication) -> Bool {
    openInstrumentAudioUnits(in: app)
    defer { closeMenus(in: app) }
    let submenu = app.menuItems["Audio Units"].firstMatch.menus.firstMatch
    guard submenu.waitForExistence(timeout: 3) else { return false }
    let maker = submenu.menuItems[entry.maker].firstMatch
    guard maker.exists else { return false }
    maker.hover()
    return maker.menus.firstMatch.menuItems[entry.plugin].firstMatch.waitForExistence(timeout: 3)
  }

  @MainActor
  private func openInstrumentAudioUnits(in app: XCUIApplication) {
    let menu = app.descendants(matching: .any)["instrument-menu"].firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 5))
    menu.click()
    let audioUnits = app.menuItems["Audio Units"].firstMatch
    XCTAssertTrue(audioUnits.waitForExistence(timeout: 3))
    audioUnits.hover()
  }

  @MainActor
  private func closeMenus(in app: XCUIApplication) {
    for _ in 0..<3 { app.typeKey(.escape, modifierFlags: []) }
  }

  @MainActor
  private func openPluginSettings(in app: XCUIApplication) {
    app.typeKey(",", modifierFlags: .command)
    let tab = app.toolbars.buttons["Plug-ins"].firstMatch
    XCTAssertTrue(tab.waitForExistence(timeout: 5), "Settings has a Plug-ins tab")
    tab.click()
  }

  @MainActor
  private func openMixerStrip(in app: XCUIApplication) -> XCUIElement {
    app.typeKey("x", modifierFlags: [])
    let mixer = app.descendants(matching: .any)["mixer"].firstMatch
    XCTAssertTrue(mixer.waitForExistence(timeout: 5), "X should open the mixer")
    let strip = mixer.descendants(matching: .any)["channel-strip"].firstMatch
    XCTAssertTrue(strip.waitForExistence(timeout: 5))
    return strip
  }

  @MainActor
  private func launchWithNewProject() -> XCUIApplication {
    let app = XCUIApplication()
    // Settings are remembered between launches; start every test from the defaults (a new
    // project with one instrument track, whatever Settings says).
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-TrackHeaderWidth", "230", "-NewProjectTemplate", "instrumentTrack"]
    app.launch()
    app.typeKey(.escape, modifierFlags: [])
    app.typeKey("n", modifierFlags: .command)
    XCTAssertTrue(app.descendants(matching: .any)["track-header"].firstMatch.waitForExistence(timeout: 10))
    return app
  }

  @MainActor
  private func attachScreenshot(of app: XCUIApplication, named name: String) {
    let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
