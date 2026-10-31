//
//  DrawingPerformanceTests.swift
//  OngakuTests
//

import AVFAudio
import AppKit
import Foundation
import OngakuCore
@testable import OngakuEngine
@testable import Ongaku
import SwiftUI
import Testing

/// Measures how long the main views take to lay out and draw the stress-test song.
///
/// The views live in a borderless window that is never put on screen, and no input is
/// synthesized: this times SwiftUI's own work (view updates, layout and drawing) for each
/// kind of change, not what the screen shows.
@MainActor
@Suite(.serialized)
struct DrawingPerformanceTests {
  private static let size = CGSize(width: 1400, height: 820)

  /// A window model for the stress song, with real audio files so waveforms draw.
  private func makeWindow() async throws -> ProjectWindowModel {
    let folder = FileManager.default.temporaryDirectory.appending(path: "OngakuDrawingPerformance")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let document = OngakuDocument(project: Project())
    var references: [AudioFileReference] = []
    for index in 0..<4 {
      let url = folder.appending(path: "Tone \(index).caf")
      if !FileManager.default.fileExists(atPath: url.path) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 8)!
        buffer.frameLength = 48_000 * 8
        for frame in 0..<Int(buffer.frameLength) {
          let value = 0.5 * sin(Float(frame) / 48_000 * .pi) * sin(2 * .pi * 220 * Float(frame) / 48_000)
          buffer.floatChannelData![0][frame] = value
          buffer.floatChannelData![1][frame] = value
        }
        try file.write(from: buffer)
      }
      references.append(try await document.stageAudio(from: url, reservedNames: Set(references.map(\.fileName))))
    }
    var project = StressTestProject.make(audioFiles: references)
    project.masterVolume = ChannelStrip.volumeRange.lowerBound
    document.editor.load(project)
    let window = ProjectWindowModel(document: document)
    // Waveforms are read in the background; wait for them.
    for _ in 0..<200 where window.waveforms.waveforms.count < references.count {
      try await Task.sleep(for: .milliseconds(20))
    }
    return window
  }

  /// Hosts a view in an offscreen window.
  private func host(_ view: some View) -> (NSWindow, NSView) {
    let hosting = NSHostingView(rootView: view.frame(width: Self.size.width, height: Self.size.height))
    hosting.frame = CGRect(origin: .zero, size: Self.size)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    return (window, hosting)
  }

  /// Lets SwiftUI apply pending changes, then lays out and redraws what changed (as the
  /// window would at the next screen refresh).
  private func settle(_ view: NSView) {
    RunLoop.main.run(until: Date())
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    CATransaction.flush()
  }

  private func measure(_ name: String, repetitions: Int, view: NSView, change: (Int) -> Void) -> [Duration] {
    let clock = ContinuousClock()
    var times: [Duration] = []
    for index in 0..<repetitions {
      times.append(clock.measure {
        change(index)
        settle(view)
      })
    }
    let sorted = times.sorted()
    print("PERF \(name): median \(ms(sorted[sorted.count / 2])), max \(ms(sorted.last!)) over \(repetitions)")
    print("PERFSTEPS \(name): \(times.map { ms($0) }.joined(separator: ", "))")
    return times
  }

  private func ms(_ duration: Duration) -> String {
    let value = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    return value.formatted(.number.precision(.fractionLength(2))) + " ms"
  }

  private func scrollView(in view: NSView) -> NSScrollView? {
    if let scrollView = view as? NSScrollView { return scrollView }
    for subview in view.subviews {
      if let found = scrollView(in: subview) { return found }
    }
    return nil
  }

  @Test func tracksArea() async throws {
    let window = try await makeWindow()
    defer { window.engine.shutDown() }
    let (hostWindow, view) = host(ArrangeView(model: window))
    defer { hostWindow.close() }

    let clock = ContinuousClock()
    print("PERF tracks area first draw: \(ms(clock.measure { settle(view) }))")
    _ = measure("tracks area idle (no change, baseline)", repetitions: 10, view: view) { _ in }

    // Scrolling sideways a screen at a time, then down through the tracks.
    let scroller = try #require(scrollView(in: view), "The tracks area should be an NSScrollView")
    _ = measure("tracks area scroll sideways (per step)", repetitions: 20, view: view) { step in
      scroller.contentView.scroll(to: CGPoint(x: CGFloat(step + 1) * 300, y: 0))
      scroller.reflectScrolledClipView(scroller.contentView)
    }
    _ = measure("tracks area scroll down (per step)", repetitions: 20, view: view) { step in
      scroller.contentView.scroll(to: CGPoint(x: 0, y: CGFloat(step + 1) * 150))
      scroller.reflectScrolledClipView(scroller.contentView)
    }
    // The playhead moves about 30 times a second while playing.
    _ = measure("tracks area playhead move", repetitions: 30, view: view) { step in
      window.engine.locate(to: .quarterNotes(Double(step) * 0.25))
    }
    _ = measure("tracks area zoom", repetitions: 6, view: view) { step in
      window.zoom(by: step.isMultiple(of: 2) ? 1.5 : 1 / 1.5)
    }
    _ = measure("tracks area select a region", repetitions: 10, view: view) { step in
      window.selectedRegionIDs = [window.project.tracks[step].regions[0].id]
    }
    window.isAutomationVisible = true
    _ = measure("tracks area with automation, scroll sideways", repetitions: 10, view: view) { step in
      scroller.contentView.scroll(to: CGPoint(x: CGFloat(step) * 300, y: 0))
      scroller.reflectScrolledClipView(scroller.contentView)
    }
  }

  @Test func mixer() async throws {
    let window = try await makeWindow()
    defer { window.engine.shutDown() }
    let (hostWindow, view) = host(MixerView(model: window))
    defer { hostWindow.close() }
    let clock = ContinuousClock()
    print("PERF mixer first draw (100 strips): \(ms(clock.measure { settle(view) }))")
    _ = measure("mixer idle (no change, baseline)", repetitions: 10, view: view) { _ in }
    _ = measure("mixer fader edit", repetitions: 10, view: view) { step in
      window.setChannel(window.project.tracks[step].id, actionName: "Volume") { $0.volume -= 1 }
    }
    _ = measure("mixer playhead move (automated faders follow)", repetitions: 30, view: view) { step in
      window.engine.locate(to: .quarterNotes(Double(step)))
      // What the window's follower view does on each playhead move.
      window.refreshAutomatedControls()
    }
  }

  /// The Piano Roll and Step Editor on a long, busy region: 2,000 notes over 64 bars, as
  /// in the guitar parts of a downloaded song.
  @Test func pianoRollAndStepEditor() async throws {
    let notes = (0..<2_000).map { index in
      MIDINote(pitch: 40 + (index * 7) % 36, velocity: 60 + index % 60, start: Tick(240) * Int64(index / 2 * 1), length: Tick(360))
    }
    let region = Region(name: "Guitar", start: .zero, length: .quarterNotes(256), content: .midi(MIDISequence(notes: notes)))
    let window = ProjectWindowModel(document: OngakuDocument(project: Project(tracks: [
      Track(name: "Guitar", kind: .softwareInstrument, regions: [region]),
    ])))
    defer { window.engine.shutDown() }
    window.openEditor(for: region.id)
    let (hostWindow, view) = host(PianoRollView(model: window.pianoRoll))
    defer { hostWindow.close() }
    let clock = ContinuousClock()
    let firstDraw = clock.measure { settle(view) }
    print("PERF piano roll first draw (2,000 notes): \(ms(firstDraw))")
    let playhead = measure("piano roll playhead move", repetitions: 30, view: view) { step in
      window.engine.locate(to: .quarterNotes(Double(step) * 0.25))
    }
    _ = measure("piano roll select a note", repetitions: 10, view: view) { step in
      window.pianoRoll.selectedNoteIDs = [notes[step].id]
    }
    let stepEditor = clock.measure {
      window.pianoRoll.editorKind = .stepEditor
      settle(view)
    }
    print("PERF step editor first draw: \(ms(stepEditor))")
    window.pianoRoll.editorKind = .pianoRoll
    settle(view)
    #expect(firstDraw < .milliseconds(500), "The Piano Roll opens quickly")
    #expect(stepEditor < .milliseconds(500), "So does the Step Editor")
    #expect(playhead.sorted()[playhead.count / 2] < .milliseconds(8), "The playhead moves without stalling the window")
  }

  @Test func wholeWindow() async throws {
    let window = try await makeWindow()
    defer { window.engine.shutDown() }
    let (hostWindow, view) = host(ContentViewHarness(model: window))
    defer { hostWindow.close() }
    let clock = ContinuousClock()
    print("PERF whole window first draw: \(ms(clock.measure { settle(view) }))")
    _ = measure("whole window playhead move", repetitions: 30, view: view) { step in
      window.engine.locate(to: .quarterNotes(Double(step) * 0.25))
      window.refreshAutomatedControls()
    }
    _ = measure("whole window select another track", repetitions: 10, view: view) { step in
      window.selectedTrackID = window.project.tracks[step].id
    }
  }
}

/// The main window's layout (control bar, Inspector and tracks area) without a document.
private struct ContentViewHarness: View {
  let model: ProjectWindowModel

  var body: some View {
    VStack(spacing: 0) {
      ControlBar(model: model)
      HStack(spacing: 0) {
        InspectorView(model: model)
        ArrangeView(model: model)
      }
    }
    .background(Theme.window)
    .preferredColorScheme(.dark)
  }
}
