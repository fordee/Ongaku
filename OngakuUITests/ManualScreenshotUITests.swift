//
//  ManualScreenshotUITests.swift
//  OngakuUITests
//

import AppKit
import XCTest

/// Takes the manual's screenshots (Docs/Manual/images) of the app's demo song, one scene at
/// a time (see `ManualDemo` in the app). Run it on an idle Mac: it opens a window for each
/// scene. Set MANUAL_SHOTS to a comma-separated list of file names to take only those.
final class ManualScreenshotUITests: XCTestCase {
  /// What part of the window a shot shows.
  private enum Area {
    case window
    /// One element, by accessibility identifier (the first, if several match).
    case element(String)
    /// The tracks area: right of the Inspector and below the control bar.
    case tracks
    /// The ruler and global tracks: between the control bar and the first track.
    case ruler
    /// The editor pane, from its header down.
    case editor
    /// The Settings window.
    case settings
  }

  private struct Shot {
    var file: String
    var scene: String
    var area: Area
    /// Done in the window before the shot (opening a menu, say).
    var prepare: (XCUIApplication) -> Void = { _ in }
  }

  private let shots: [Shot] = [
    Shot(file: "project-window", scene: "overview", area: .window),
    Shot(file: "control-bar", scene: "control-bar", area: .element("control-bar")),
    Shot(file: "track-header", scene: "track-header", area: .element("track-header")),
    Shot(file: "cycle-range", scene: "cycle", area: .ruler),
    Shot(file: "regions", scene: "regions", area: .tracks),
    Shot(file: "tool-menu", scene: "tool-menu", area: .tracks),
    Shot(file: "region-inspector-midi", scene: "region-inspector-midi", area: .element("inspector")),
    Shot(file: "region-inspector-audio", scene: "region-inspector-audio", area: .element("inspector")),
    Shot(file: "looped-region", scene: "loop", area: .tracks),
    Shot(file: "arrangement-track", scene: "arrangement", area: .tracks),
    Shot(file: "stack-expanded", scene: "stack-expanded", area: .tracks),
    Shot(file: "stack-collapsed", scene: "stack-collapsed", area: .tracks),
    Shot(file: "record-enabled", scene: "record-armed", area: .window),
    Shot(file: "take-folder", scene: "take-folder", area: .tracks),
    Shot(file: "piano-roll", scene: "piano-roll", area: .window),
    Shot(file: "piano-roll-header", scene: "piano-roll-header", area: .element("editor-header")),
    Shot(file: "step-sequencer", scene: "step-sequencer", area: .editor),
    Shot(file: "midi-draw-pitch-bend", scene: "pitch-bend", area: .editor),
    Shot(file: "drummer-track", scene: "drummer-track", area: .tracks),
    Shot(file: "chord-track", scene: "chord-track", area: .tracks),
    Shot(file: "flex-menu", scene: "flex-menu", area: .window) { app in
      ManualScreenshotUITests.clickIfThere(app.popUpButtons["Flex"].firstMatch)
    },
    Shot(file: "flex-markers", scene: "flex-markers", area: .tracks),
    Shot(file: "smart-tempo", scene: "smart-tempo", area: .window) { app in
      ManualScreenshotUITests.clickIfThere(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'BPM'")).firstMatch)
    },
    Shot(file: "sends", scene: "sends", area: .element("mixer")),
    Shot(file: "automation", scene: "automation", area: .tracks),
    Shot(file: "library", scene: "library", area: .window),
    Shot(file: "settings-audio", scene: "overview", area: .settings) { app in
      app.typeKey(",", modifierFlags: .command)
      ManualScreenshotUITests.clickIfThere(app.toolbars.buttons["Audio"].firstMatch)
    },
  ]

  /// Clicks an element if it turns up; a missing one only spoils that shot, not the run.
  private static func clickIfThere(_ element: XCUIElement) {
    if element.waitForExistence(timeout: 5) {
      element.click()
    } else {
      XCTFail("Couldn't find \(element)")
    }
  }

  /// Where the images go: the repository's Docs/Manual/images, found from this file.
  private let folder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Docs/Manual/images", directoryHint: .isDirectory)

  @MainActor
  func testManualScreenshots() throws {
    continueAfterFailure = true
    let only = ProcessInfo.processInfo.environment["MANUAL_SHOTS"].map { Set($0.split(separator: ",").map(String.init)) }
    for shot in shots where only?.contains(shot.file) ?? true {
      take(shot)
    }
  }

  @MainActor
  private func take(_ shot: Shot) {
    let app = XCUIApplication()
    app.launchArguments += [
      "-ApplePersistenceIgnoreState", "YES", "-TrackHeaderWidth", "280", "-OngakuManualScene", shot.scene,
    ]
    app.launch()
    defer { app.terminate() }
    // A document app may open with an Open panel; dismiss it and make a new project.
    app.typeKey(.escape, modifierFlags: [])
    app.typeKey("n", modifierFlags: .command)
    let window = app.windows["manual-ready"]
    guard window.waitForExistence(timeout: 60) else {
      XCTFail("\(shot.file): the scene “\(shot.scene)” didn't get ready")
      return
    }
    // The pointer rests where the app opened, which can leave a tooltip in the shot: park it
    // over the empty area below the tracks.
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.97)).hover()
    shot.prepare(app)
    Thread.sleep(forTimeInterval: 1)

    let image: NSImage?
    switch shot.area {
    case .window:
      image = window.screenshot().image
    case .element(let identifier):
      let element = window.descendants(matching: .any)[identifier].firstMatch
      image = element.exists ? element.screenshot().image : nil
    case .tracks:
      image = crop(window) { frames in
        CGRect(x: frames.inspector.maxX, y: frames.controlBar.maxY, width: frames.window.maxX - frames.inspector.maxX,
          height: (frames.editorHeader?.minY ?? frames.window.maxY) - frames.controlBar.maxY)
      }
    case .ruler:
      image = crop(window) { frames in
        CGRect(x: frames.inspector.maxX, y: frames.controlBar.maxY, width: frames.window.maxX - frames.inspector.maxX,
          height: frames.firstTrack.minY - frames.controlBar.maxY)
      }
    case .editor:
      image = crop(window) { frames in
        guard let header = frames.editorHeader else { return nil }
        return CGRect(x: header.minX, y: header.minY, width: frames.window.maxX - header.minX, height: frames.window.maxY - header.minY)
      }
    case .settings:
      let settings = app.windows.matching(NSPredicate(format: "identifier != 'manual-ready'")).firstMatch
      image = settings.waitForExistence(timeout: 5) ? settings.screenshot().image : nil
    }
    guard let image else {
      XCTFail("\(shot.file): nothing to capture")
      return
    }
    save(image, as: shot.file)
  }

  /// Where the window's main areas are, in screen points.
  private struct Frames {
    var window: CGRect
    var controlBar: CGRect
    var inspector: CGRect
    var firstTrack: CGRect
    var editorHeader: CGRect?
  }

  /// The window's screenshot, cut to `rect` (in screen points).
  @MainActor
  private func crop(_ window: XCUIElement, to rect: (Frames) -> CGRect?) -> NSImage? {
    func frame(_ identifier: String) -> CGRect? {
      let element = window.descendants(matching: .any)[identifier].firstMatch
      return element.exists ? element.frame : nil
    }
    guard let controlBar = frame("control-bar"), let firstTrack = frame("track-header") else { return nil }
    // Without the Inspector, the tracks start at the window's edge.
    let inspector = frame("inspector") ?? CGRect(x: window.frame.minX, y: controlBar.maxY, width: 0, height: 0)
    let frames = Frames(
      window: window.frame, controlBar: controlBar, inspector: inspector, firstTrack: firstTrack,
      editorHeader: frame("editor-header"))
    guard let area = rect(frames),
      let full = window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return nil }
    let scale = CGFloat(full.width) / window.frame.width
    let pixels = CGRect(
      x: (area.minX - window.frame.minX) * scale, y: (area.minY - window.frame.minY) * scale,
      width: area.width * scale, height: area.height * scale
    ).integral
    guard let cropped = full.cropping(to: pixels) else { return nil }
    return NSImage(cgImage: cropped, size: area.size)
  }

  @MainActor
  private func save(_ image: NSImage, as name: String) {
    let attachment = XCTAttachment(image: image)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { return }
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try png.write(to: folder.appending(path: "\(name).png"))
    } catch {
      // The test runner may not be allowed to write there; the attachments have the images.
      let fallback = FileManager.default.temporaryDirectory.appending(path: "ManualScreenshots", directoryHint: .isDirectory)
      try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
      try? png.write(to: fallback.appending(path: "\(name).png"))
      print("MANUALSHOT \(name): saved to \(fallback.path) (\(error.localizedDescription))")
    }
  }
}
