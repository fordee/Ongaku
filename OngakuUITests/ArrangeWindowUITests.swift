//
//  ArrangeWindowUITests.swift
//  OngakuUITests
//

import AppKit
import XCTest

final class ArrangeWindowUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  // MARK: - Tests

  /// The track headers are pinned over a scrolling area, so after scrolling sideways their
  /// buttons must still receive clicks where they are drawn.
  @MainActor
  func testTrackHeaderButtonsWorkAfterScrollingSideways() throws {
    let app = launchWithNewProject()
    let mute = app.buttons["mute"].firstMatch
    XCTAssertTrue(mute.waitForExistence(timeout: 5))
    XCTAssertEqual(mute.value as? String, "Off")

    mute.click()
    XCTAssertEqual(mute.value as? String, "On")

    app.scrollViews.firstMatch.scroll(byDeltaX: -1200, deltaY: 0)
    attachScreenshot(of: app, named: "Scrolled sideways")

    mute.click()
    XCTAssertEqual(mute.value as? String, "Off")
  }

  @MainActor
  func testImportAudioThenPlay() throws {
    let audioURL = try makeTestTone()
    let app = launchWithNewProject()

    importAudio(audioURL, into: app)

    let region = app.descendants(matching: .any)["region"].firstMatch
    XCTAssertTrue(region.waitForExistence(timeout: 10), "Importing should add a region")
    attachScreenshot(of: app, named: "Imported")

    let position = app.descendants(matching: .any)["lcd-position"].firstMatch
    XCTAssertEqual(position.label, "Position: bar 1, beat 1")

    // Click the region to focus the tracks area, then play and stop with Space.
    region.click()
    app.typeKey(" ", modifierFlags: [])
    let started = app.buttons["Stop"].waitForExistence(timeout: 2)
    attachScreenshot(of: app, named: "After Space")
    XCTAssertTrue(started, "Space should start playback")
    Thread.sleep(forTimeInterval: 2.5)
    attachScreenshot(of: app, named: "Playing")

    app.typeKey(" ", modifierFlags: [])
    XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 2), "Space should stop playback")
  }

  /// Double-clicking an instrument lane creates a MIDI region and opens the piano roll;
  /// double-clicking there adds a note, which plays and can be deleted.
  @MainActor
  func testCreateRegionAndEditNotesInThePianoRoll() throws {
    let app = launchWithNewProject()
    // The lane starts just right of its track header.
    let header = app.descendants(matching: .any)["track-header"].firstMatch
    header.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: 60, dy: 0)).doubleClick()
    XCTAssertTrue(app.descendants(matching: .any)["region"].firstMatch.waitForExistence(timeout: 5))
    let notesArea = app.descendants(matching: .any)["piano-roll-notes"].firstMatch
    XCTAssertTrue(notesArea.waitForExistence(timeout: 5), "Creating a MIDI region should open the piano roll")

    // The Inspector and the tracks area have scroll views too; use the piano roll's own.
    let pianoRollScroll = app.scrollViews.containing(.any, identifier: "piano-roll-notes").firstMatch
    visiblePoint(in: notesArea, within: pianoRollScroll, x: 0.1).doubleClick()
    let note = app.descendants(matching: .any)["note"].firstMatch
    XCTAssertTrue(note.waitForExistence(timeout: 5), "Double-clicking the piano roll should add a note")
    attachScreenshot(of: app, named: "Piano roll with a note")

    // Play from the start, so the note sounds, then stop.
    note.click()
    app.typeKey(" ", modifierFlags: [])
    XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 2))
    Thread.sleep(forTimeInterval: 1)
    app.typeKey(" ", modifierFlags: [])

    // Delete the selected note.
    note.click()
    app.typeKey(.delete, modifierFlags: [])
    let deleted = note.waitForNonExistence(timeout: 3)
    attachScreenshot(of: app, named: "After Delete")
    XCTAssertTrue(deleted, "Delete should remove the selected note")
  }

  @MainActor
  func testImportMIDIFile() throws {
    // Format 0, 96 PPQ, track "Vibe": two notes at 100 BPM in 3/4.
    let bytes: [UInt8] = [
      0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 0, 96,
      0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 44,
      0x00, 0xFF, 0x03, 0x04, 0x56, 0x69, 0x62, 0x65,
      0x00, 0xFF, 0x51, 0x03, 0x09, 0x27, 0xC0,
      0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08,
      0x00, 0xC0, 0x0B,
      0x00, 0x90, 0x3C, 0x64, 0x60, 0x3C, 0x00, 0x00, 0x40, 0x50, 0x30, 0x80, 0x40, 0x00,
      0x00, 0xFF, 0x2F, 0x00,
    ]
    let url = FileManager.default.temporaryDirectory.appending(path: "Ongaku Test.mid")
    try Data(bytes).write(to: url)

    let app = launchWithNewProject()
    importFile(url, menuItem: "Import MIDI File…", into: app)

    let header = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Vibe'")).firstMatch
    XCTAssertTrue(header.waitForExistence(timeout: 10), "The MIDI file's track should be added")
    XCTAssertTrue(app.descendants(matching: .any)["region"].firstMatch.exists)
    attachScreenshot(of: app, named: "Imported MIDI file")
  }

  /// The mixer (X) shows channel strips; inserts, sends to a new aux, faders and recording
  /// all work from it.
  @MainActor
  func testMixerInsertsSendsFaderAndRecord() throws {
    let app = launchWithNewProject()
    app.typeKey("x", modifierFlags: [])
    // The Inspector shows the selected track's strip too, so look inside the Mixer.
    let mixer = app.descendants(matching: .any)["mixer"].firstMatch
    XCTAssertTrue(mixer.waitForExistence(timeout: 5), "X should open the mixer")
    let strip = mixer.descendants(matching: .any)["channel-strip"].firstMatch
    XCTAssertTrue(strip.waitForExistence(timeout: 5))
    XCTAssertTrue(mixer.descendants(matching: .any)["master-strip"].exists)

    // Add Ongaku's reverb (in its Reverb & Delay submenu) as an insert.
    strip.descendants(matching: .any)["add-insert"].firstMatch.click()
    app.menuItems["Reverb & Delay"].firstMatch.hover()
    app.menuItems["Reverb"].firstMatch.click()
    XCTAssertTrue(strip.descendants(matching: .any)["insert-slot"].firstMatch.waitForExistence(timeout: 5))

    // Send to a new aux: a second channel strip appears.
    strip.descendants(matching: .any)["add-send"].firstMatch.click()
    app.menuItems["New Aux"].click()
    let strips = mixer.descendants(matching: .any).matching(identifier: "channel-strip")
    let auxAppeared = NSPredicate { _, _ in strips.count == 2 }
    expectation(for: auxAppeared, evaluatedWith: nil)
    waitForExpectations(timeout: 5)

    // The strip is taller than the mixer pane, so the fader and the buttons below it start
    // out of view; scroll down to them.
    let recordEnable = strip.buttons["Record Enable"].firstMatch
    strip.scroll(byDeltaX: 0, deltaY: -400)
    XCTAssertTrue(recordEnable.isHittable, "Scrolling the mixer should reveal the strip's buttons")

    // Drag the first fader down; the dB readout above it changes from 0.0.
    // Look inside the track's strip: Stereo Out has a fader too.
    let fader = strip.descendants(matching: .any)["fader"].firstMatch
    let readout = strip.staticTexts.matching(identifier: "volume-readout").firstMatch
    XCTAssertEqual(readout.value as? String, "0.0")
    fader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
      .click(forDuration: 0.1, thenDragTo: fader.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
    attachScreenshot(of: app, named: "Mixer")
    XCTAssertNotEqual(readout.value as? String, "0.0", "Dragging the fader should change the volume")

    // Record-enable the instrument track, record with R, then stop.
    recordEnable.click()
    app.typeKey("r", modifierFlags: [])
    XCTAssertTrue(app.buttons["Stop Recording"].firstMatch.waitForExistence(timeout: 5), "R should start recording")
    attachScreenshot(of: app, named: "Recording")
    app.typeKey("r", modifierFlags: [])
    XCTAssertTrue(app.buttons["Stop Recording"].firstMatch.waitForNonExistence(timeout: 5), "R again should stop")
  }

  /// Dragging the headers' right edge resizes them, within limits, and the instrument name
  /// stays inside its header however narrow it gets.
  @MainActor
  func testTrackHeadersResizeAndKeepTheirContentInside() throws {
    let app = launchWithNewProject()
    let header = app.descendants(matching: .any)["track-header"].firstMatch
    let handle = app.descendants(matching: .any)["header-resize-handle"].firstMatch
    XCTAssertTrue(handle.waitForExistence(timeout: 5))
    let startWidth = header.frame.width

    func dragHandle(by distance: CGFloat) {
      let grab = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      grab.click(forDuration: 0.1, thenDragTo: grab.withOffset(CGVector(dx: distance, dy: 0)))
    }

    dragHandle(by: 100)
    XCTAssertEqual(header.frame.width, startWidth + 100, accuracy: 3, "Dragging the edge should widen the headers")
    attachScreenshot(of: app, named: "Wide headers")

    dragHandle(by: -400)
    XCTAssertEqual(header.frame.width, 190, accuracy: 3, "The headers shouldn't get narrower than their minimum")
    let instrument = header.descendants(matching: .any)["instrument-menu"].firstMatch
    XCTAssertLessThanOrEqual(instrument.frame.maxX, header.frame.maxX, "The instrument name should stay inside the header")
    XCTAssertTrue(header.buttons["Mute"].isHittable, "The track buttons should still be visible")
    attachScreenshot(of: app, named: "Narrow headers")
  }

  // MARK: - Helpers

  @MainActor
  private func importAudio(_ url: URL, into app: XCUIApplication) {
    importFile(url, menuItem: "Import Audio Files…", into: app)
  }

  /// Chooses a File menu import command, then enters the path with Go to Folder. The panel
  /// takes a moment to appear and to show the Go to Folder field.
  @MainActor
  private func importFile(_ url: URL, menuItem: String, into app: XCUIApplication) {
    app.menuBars.menuBarItems["File"].click()
    app.menuItems[menuItem].click()
    Thread.sleep(forTimeInterval: 2)
    app.typeKey("g", modifierFlags: [.command, .shift])
    Thread.sleep(forTimeInterval: 1)
    // Paste rather than type the path: typing a long path one key at a time races with
    // the Go to Folder field's autocompletion. The clipboard is restored afterwards.
    let pasteboard = NSPasteboard.general
    let savedItems = pasteboard.pasteboardItems?.map { item in
      item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
    } ?? []
    defer {
      pasteboard.clearContents()
      pasteboard.writeObjects(savedItems.map { contents in
        let item = NSPasteboardItem()
        for (type, data) in contents { item.setData(data, forType: type) }
        return item
      })
    }
    pasteboard.clearContents()
    pasteboard.setString(url.path, forType: .string)
    app.typeKey("v", modifierFlags: .command)
    app.typeKey(.return, modifierFlags: [])
    Thread.sleep(forTimeInterval: 1)
    app.typeKey(.return, modifierFlags: [])
  }

  /// A point inside both `element` and the visible part of `container`, so clicks land on
  /// screen even when the element is much larger than the scroll view showing it.
  @MainActor
  private func visiblePoint(in element: XCUIElement, within container: XCUIElement, x fraction: CGFloat = 0.25) -> XCUICoordinate {
    let visible = element.frame.intersection(container.frame)
    let target = CGPoint(x: visible.minX + visible.width * fraction, y: visible.midY)
    return element.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: target.x - element.frame.minX, dy: target.y - element.frame.minY))
  }

  @MainActor
  private func launchWithNewProject() -> XCUIApplication {
    let app = XCUIApplication()
    // The track header width is remembered between launches; start every test from the default.
    app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-TrackHeaderWidth", "230"]
    app.launch()
    // A document app may open with an Open panel; dismiss it and create a new project.
    app.typeKey(.escape, modifierFlags: [])
    app.typeKey("n", modifierFlags: .command)
    XCTAssertTrue(app.descendants(matching: .any)["track-header"].firstMatch.waitForExistence(timeout: 10))
    return app
  }

  @MainActor
  private func attachScreenshot(of app: XCUIApplication, named name: String) {
    let screenshot = app.windows.firstMatch.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    // Also keep a copy on disk for inspecting runs without opening the result bundle.
    let folder = FileManager.default.temporaryDirectory.appending(path: "OngakuUITestScreenshots", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try? screenshot.pngRepresentation.write(to: folder.appending(path: "\(name).png"))
  }

  /// Writes a 6-second, 48 kHz stereo WAV that pulses on every beat at 120 BPM.
  private func makeTestTone() throws -> URL {
    let sampleRate = 48_000
    let frameCount = sampleRate * 6
    var samples = Data(capacity: frameCount * 4)
    for frame in 0..<frameCount {
      let time = Double(frame) / Double(sampleRate)
      let envelope = exp(-time.truncatingRemainder(dividingBy: 0.5) * 8)
      let value = Int16(12_000 * envelope * sin(2 * .pi * 220 * time))
      withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
      withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
    }

    func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    var wav = Data("RIFF".utf8)
    append(UInt32(36 + samples.count), to: &wav)
    wav.append(contentsOf: Data("WAVEfmt ".utf8))
    append(UInt32(16), to: &wav)
    append(UInt16(1), to: &wav)  // PCM
    append(UInt16(2), to: &wav)  // channels
    append(UInt32(sampleRate), to: &wav)
    append(UInt32(sampleRate * 4), to: &wav)  // byte rate
    append(UInt16(4), to: &wav)  // block align
    append(UInt16(16), to: &wav)  // bits per sample
    wav.append(contentsOf: Data("data".utf8))
    append(UInt32(samples.count), to: &wav)
    wav.append(samples)

    let url = FileManager.default.temporaryDirectory.appending(path: "Ongaku Test Tone.wav")
    try wav.write(to: url)
    return url
  }
}
