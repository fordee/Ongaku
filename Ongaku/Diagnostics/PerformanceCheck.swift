//
//  PerformanceCheck.swift
//  Ongaku
//

#if DEBUG
import AVFAudio
import AppKit
import OngakuCore
import OngakuEngine
import QuartzCore
import SwiftUI

/// A debug-only, self-driving performance check. Launch with `-OngakuPerformanceCheck YES`:
/// a window opens with the stress-test song, plays it silently, scrolls, zooms and selects
/// by itself (no synthesized input), records how smoothly frames arrive, writes a report to
/// the app's temporary folder and quits.
enum PerformanceCheck {
  static var isRequested: Bool {
    UserDefaults.standard.bool(forKey: "OngakuPerformanceCheck")
  }

  static var reportURL: URL {
    FileManager.default.temporaryDirectory.appending(path: "OngakuPerformanceCheck.txt")
  }

  /// Progress goes to standard output as it happens, since the sandboxed app's own
  /// temporary folder can't be read from outside.
  static func log(_ line: String) {
    print("PERFCHECK \(line)")
    fflush(stdout)
  }
}

/// Counts frames as the display refreshes, and calls `onFrame` on each, from the main thread.
/// A frame that arrives late (more than 1.5 refresh intervals after the last) is a hitch.
@MainActor
final class FrameRecorder: NSObject {
  struct Summary {
    var frames = 0
    var hitches = 0
    /// Time lost to hitches, beyond the expected refresh interval.
    var hitchTime: Double = 0
    var worstGap: Double = 0
    var duration: Double = 0
  }

  private var link: CADisplayLink?
  private var lastTimestamp: CFTimeInterval?
  private var summary = Summary()
  private var phaseStart: CFTimeInterval = CACurrentMediaTime()
  var onFrame: (() -> Void)?

  func attach(to view: NSView) {
    guard link == nil else { return }
    let link = view.displayLink(target: self, selector: #selector(frame(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func stop() {
    link?.invalidate()
    link = nil
  }

  @objc private func frame(_ link: CADisplayLink) {
    let interval = link.targetTimestamp - link.timestamp
    if let lastTimestamp {
      let gap = link.timestamp - lastTimestamp
      summary.worstGap = max(summary.worstGap, gap)
      if interval > 0, gap > interval * 1.5 {
        summary.hitches += 1
        summary.hitchTime += gap - interval
      }
    }
    lastTimestamp = link.timestamp
    summary.frames += 1
    onFrame?()
  }

  func beginPhase() {
    summary = Summary()
    lastTimestamp = nil
    phaseStart = CACurrentMediaTime()
  }

  func endPhase() -> Summary {
    var result = summary
    result.duration = CACurrentMediaTime() - phaseStart
    return result
  }
}

/// The window the check runs in: the normal project window around the stress song.
struct PerformanceCheckView: View {
  @State private var model: ProjectWindowModel?
  @State private var recorder = FrameRecorder()

  var body: some View {
    Group {
      if let model {
        ProjectWindow(model: model)
          .background(DisplayLinkHost(recorder: recorder))
          .task { await run(model) }
      } else {
        Text("Preparing the stress-test song…")
          .foregroundStyle(Theme.secondaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Theme.window)
      }
    }
    .frame(minWidth: 900, minHeight: 500)
    .task {
      guard model == nil else { return }
      PerformanceCheck.log("preparing the song")
      do {
        model = try await Self.makeModel()
        PerformanceCheck.log("song ready")
      } catch {
        PerformanceCheck.log("couldn't prepare the song: \(error)")
        NSApp.terminate(nil)
      }
    }
  }

  /// The stress song, with real audio files so waveforms draw, and Stereo Out at -∞ so
  /// playback is silent.
  private static func makeModel() async throws -> ProjectWindowModel {
    let folder = FileManager.default.temporaryDirectory.appending(path: "OngakuPerformanceCheck")
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
          let value = 0.5 * sin(Float(frame) / 48_000 * .pi) * sin(2 * .pi * Float(110 * (index + 1)) * Float(frame) / 48_000)
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
    return ProjectWindowModel(document: document)
  }

  // MARK: - The script

  private func run(_ model: ProjectWindowModel) async {
    var report = ["Ongaku Studio performance check — \(Date().formatted())", "Song: stress test (100 tracks, 1,123 regions)", ""]
    func sleep(_ seconds: Double) async {
      try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }
    func phase(_ name: String, seconds: Double, onFrame: (() -> Void)? = nil, during: () async -> Void = {}) async {
      PerformanceCheck.log("phase: \(name)")
      recorder.onFrame = onFrame
      recorder.beginPhase()
      let clock = ContinuousClock()
      let start = clock.now
      await during()
      let remaining = seconds - Double((clock.now - start).components.seconds)
      if remaining > 0 { await sleep(remaining) }
      recorder.onFrame = nil
      let summary = recorder.endPhase()
      let hitchRatio = summary.duration > 0 ? summary.hitchTime * 1000 / summary.duration : 0
      report.append(String(
        format: "%@: %d frames in %.1f s (%.0f fps), %d hitches, %.0f ms/s hitch time, worst frame gap %.0f ms",
        name, summary.frames, summary.duration, Double(summary.frames) / max(summary.duration, 0.001),
        summary.hitches, hitchRatio, summary.worstGap * 1000))
    }

    // Let the window, instruments and waveforms settle.
    await sleep(3)
    guard let scrollView = tracksScrollView() else {
      report.append("Couldn't find the tracks area's scroll view.")
      finish(report)
      return
    }

    await phase("Idle", seconds: 3)
    await phase("Playback", seconds: 8, during: { model.engine.play() })
    model.engine.stop()
    model.engine.locate(to: .zero)

    var x: CGFloat = 0
    await phase("Scroll sideways (12 pt per frame)", seconds: 5, onFrame: {
      x += 12
      scroll(scrollView, to: CGPoint(x: x, y: scrollView.contentView.bounds.minY))
    })
    var y: CGFloat = 0
    await phase("Scroll down (6 pt per frame)", seconds: 5, onFrame: {
      y += 6
      scroll(scrollView, to: CGPoint(x: scrollView.contentView.bounds.minX, y: y))
    })
    scroll(scrollView, to: .zero)
    await phase("Zoom in and out", seconds: 4, during: {
      for step in 0..<6 {
        model.zoom(by: step.isMultiple(of: 2) ? 1.5 : 1 / 1.5)
        await sleep(0.6)
      }
    })
    await phase("Select tracks and regions", seconds: 4, during: {
      for index in 0..<10 {
        model.selectedTrackID = model.project.tracks[index].id
        model.selectedRegionIDs = model.project.tracks[index].regions.first.map { [$0.id] } ?? []
        await sleep(0.35)
      }
    })
    model.bottomPane = .mixer
    await sleep(1)
    await phase("Playback with the Mixer open", seconds: 8, during: { model.engine.play() })
    model.engine.stop()
    finish(report)
  }

  private func finish(_ report: [String]) {
    recorder.stop()
    let text = report.joined(separator: "\n") + "\n"
    try? text.write(to: PerformanceCheck.reportURL, atomically: true, encoding: .utf8)
    text.split(separator: "\n").forEach { PerformanceCheck.log(String($0)) }
    model?.engine.shutDown()
    NSApp.terminate(nil)
  }

  /// The tracks area: the widest scroll view in the window.
  private func tracksScrollView() -> NSScrollView? {
    guard let window = NSApp.windows.first(where: { $0.title == "Performance Check" || $0.identifier?.rawValue.contains("performance-check") == true }),
      let root = window.contentView
    else { return nil }
    var found: [NSScrollView] = []
    func visit(_ view: NSView) {
      if let scrollView = view as? NSScrollView { found.append(scrollView) }
      view.subviews.forEach(visit)
    }
    visit(root)
    return found.max { ($0.documentView?.frame.width ?? 0) < ($1.documentView?.frame.width ?? 0) }
  }

  private func scroll(_ scrollView: NSScrollView, to point: CGPoint) {
    scrollView.contentView.scroll(to: point)
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }
}

/// Puts the frame recorder's display link on the window's screen.
private struct DisplayLinkHost: NSViewRepresentable {
  let recorder: FrameRecorder

  func makeNSView(context: Context) -> NSView {
    HostView(recorder: recorder)
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class HostView: NSView {
    let recorder: FrameRecorder

    init(recorder: FrameRecorder) {
      self.recorder = recorder
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil { recorder.attach(to: self) }
    }
  }
}
#endif
