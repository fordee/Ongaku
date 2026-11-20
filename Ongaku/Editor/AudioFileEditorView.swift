//
//  AudioFileEditorView.swift
//  Ongaku
//

import AVFAudio
import OngakuCore
import OngakuEngine
import SwiftUI

extension ProjectWindowModel {
  /// The Audio File Editor's functions: `edit` applied to `frames` of the file a region
  /// plays (all of it if `nil`). The edited file replaces the original for every region and
  /// take that plays it, as one undo step. Returns the work, for tests to wait on.
  @discardableResult
  func editAudioFile(of regionID: Region.ID, _ edit: AudioFileEdit, frames: Range<Int64>?) -> Task<Void, Never>? {
    guard let region = project.region(withID: regionID), case .audio(let audio) = region.content,
      let file = project.audioFile(withID: audio.fileID), let source = document.url(for: file)
    else { return nil }
    let range = frames ?? 0..<file.frameCount
    // "Vox.wav" becomes "Vox Edit.caf", then "Vox Edit 2.caf" and so on.
    let baseName = (file.fileName as NSString).deletingPathExtension.replacing(/\ Edit(\ \d+)?$/, with: "")
    return Task {
      do {
        let destination = try document.newRenderedAudioURL()
        let edited = try await FlexAudio.edit(source, edit, frames: range, to: destination)
        let reference = try document.adoptRecordedAudio(
          at: destination, sampleRate: edited.sampleRate, channelCount: edited.channelCount, frameCount: edited.frameCount,
          preferredName: "\(baseName) Edit", reservedNames: document.savedAudioFileNames)
        perform(ReplaceAudioFile(file.id, with: reference, actionName: edit.actionName))
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

/// Logic's Audio File Editor: the whole file the open audio region plays, with the part the
/// region uses picked out. Drag to select part of the file (click to select all of it), then
/// choose a function: it changes the file itself, so every region playing it changes too.
struct AudioFileEditorView: View {
  let model: PianoRollModel
  let region: Region

  static let rulerHeight: CGFloat = 18

  var body: some View {
    let window = model.window
    if case .audio(let audio) = region.content, let file = window.project.audioFile(withID: audio.fileID) {
      if let waveform = window.waveforms.waveforms[file.id] {
        let used = audio.fileStartFrame..<min(
          file.frameCount, audio.fileStartFrame + Int64((window.project.duration(of: region) * audio.stretch * file.sampleRate).rounded()))
        let color = window.project.tracks.first { $0.regions.contains { $0.id == region.id } }?.color.color ?? Theme.accent
        AudioFileCanvas(model: model, file: file, waveform: waveform, used: used, color: color)
      } else {
        ProgressView("Reading the file…")
          .controlSize(.small)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

private struct AudioFileCanvas: View {
  let model: PianoRollModel
  let file: AudioFileReference
  let waveform: Waveform
  /// The frames the region plays.
  let used: Range<Int64>
  let color: Color

  var body: some View {
    GeometryReader { geometry in
      let width = max(geometry.size.width, 1)
      let frameCount = max(file.frameCount, 1)
      let x: (Int64) -> CGFloat = { CGFloat(Double($0) / Double(frameCount)) * width }
      let frame: (CGFloat) -> Int64 = { min(max(Int64((Double($0 / width) * Double(frameCount)).rounded()), 0), frameCount) }
      VStack(spacing: 0) {
        SecondsRuler(duration: file.duration, width: width)
          .frame(height: AudioFileEditorView.rulerHeight)
        Canvas { context, size in
          let middle = size.height / 2
          // The part the region plays in the track's colour, the rest dimmed.
          context.fill(Path(CGRect(x: x(used.lowerBound), y: 0, width: x(used.upperBound) - x(used.lowerBound), height: size.height)),
            with: .color(color.opacity(0.12)))
          var inside = Path(), outside = Path()
          var column: CGFloat = 0
          while column < size.width {
            let start = frame(column), end = frame(column + 1)
            let height = max(0.5, CGFloat(waveform.peak(fromFrame: start, toFrame: end)) * (middle - 4))
            let bar = CGRect(x: column, y: middle - height, width: 1, height: height * 2)
            if used.contains(start) { inside.addRect(bar) } else { outside.addRect(bar) }
            column += 1
          }
          context.fill(outside, with: .color(Theme.tertiaryText))
          context.fill(inside, with: .color(color))
          context.fill(Path(CGRect(x: 0, y: middle, width: size.width, height: 0.5)), with: .color(Theme.divider))
          if let selection = model.audioFileSelection {
            let rect = CGRect(x: x(selection.lowerBound), y: 0, width: max(1, x(selection.upperBound) - x(selection.lowerBound)), height: size.height)
            context.fill(Path(rect), with: .color(Theme.accent.opacity(0.25)))
            context.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(Theme.accent), lineWidth: 1)
          }
        }
        .contentShape(.rect)
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { drag in
              let ends = [frame(drag.startLocation.x), frame(drag.location.x)]
              model.audioFileSelection = abs(drag.translation.width) < 2 ? nil : ends.min()!..<ends.max()!
            }
        )
        .accessibilityElement()
        .accessibilityLabel("Audio file \(file.fileName)")
        .accessibilityValue(AudioFileEditorFunctions.selectionText(model.audioFileSelection, in: file))
        .accessibilityIdentifier("audio-file-waveform")
      }
    }
    .background(Theme.lanes)
    .help("Drag to select part of the file; click to select all of it. Functions change the file for every region that plays it.")
  }
}

/// Seconds along the top of the file, labelled about every 80 points.
private struct SecondsRuler: View {
  let duration: Double
  let width: CGFloat

  var body: some View {
    Canvas { context, size in
      guard duration > 0 else { return }
      let steps = [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
      let step = steps.first { Double(80 / width) * duration <= $0 } ?? 600
      var seconds = 0.0
      while seconds <= duration {
        let x = CGFloat(seconds / duration) * width
        context.fill(Path(CGRect(x: x, y: size.height - 5, width: 1, height: 5)), with: .color(Theme.rulerTick))
        context.draw(
          Text(seconds.formatted(.number.precision(.fractionLength(step < 1 ? 2 : 0))) + " s")
            .font(Theme.monospaced(9, weight: .regular)).foregroundStyle(Theme.rulerText),
          at: CGPoint(x: x + 3, y: size.height / 2 - 1), anchor: .leading)
        seconds += step
      }
    }
    .background(Theme.ruler)
    .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
  }
}

/// The Audio File Editor's part of the editor header: what's selected and the Functions menu.
struct AudioFileEditorFunctions: View {
  let model: PianoRollModel
  let region: Region

  var body: some View {
    let window = model.window
    let file: AudioFileReference? = if case .audio(let audio) = region.content { window.project.audioFile(withID: audio.fileID) } else { nil }
    if let file {
      Text(Self.selectionText(model.audioFileSelection, in: file))
        .font(Theme.monospaced(10, weight: .regular))
        .foregroundStyle(Theme.secondaryText)
      Menu("Functions") {
        Button("Normalize") { run(.normalize(peak: 0)) }
        Menu("Change Gain") {
          ForEach([6.0, 3, 1, -1, -3, -6], id: \.self) { decibels in
            Button((decibels > 0 ? "+" : "−") + "\(Int(abs(decibels))) dB") { run(.gain(decibels)) }
          }
        }
        Divider()
        Button("Fade In") { run(.fadeIn) }
        Button("Fade Out") { run(.fadeOut) }
        Button("Silence") { run(.silence) }
        Divider()
        Button("Reverse") { run(.reverse) }
        Button("Invert") { run(.invert) }
        Button("Remove DC Offset") { run(.removeDCOffset) }
        Divider()
        Button("Select Region") { model.audioFileSelection = Self.usedFrames(of: region, in: window.project) }
        Button("Select All") { model.audioFileSelection = nil }
      }
      .fixedSize()
      .help("Change the selected part of the file (or all of it), for every region that plays it. Each change can be undone.")
    }
  }

  private func run(_ edit: AudioFileEdit) {
    model.window.editAudioFile(of: region.id, edit, frames: model.audioFileSelection)
  }

  /// The frames of its file a region plays.
  static func usedFrames(of region: Region, in project: Project) -> Range<Int64>? {
    guard case .audio(let audio) = region.content, let file = project.audioFile(withID: audio.fileID) else { return nil }
    let frames = Int64((project.duration(of: region) * audio.stretch * file.sampleRate).rounded())
    return audio.fileStartFrame..<min(file.frameCount, audio.fileStartFrame + frames)
  }

  static func selectionText(_ selection: Range<Int64>?, in file: AudioFileReference) -> String {
    guard let selection else { return "Whole file" }
    let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(3))
    return "\((Double(selection.lowerBound) / file.sampleRate).formatted(format))–\((Double(selection.upperBound) / file.sampleRate).formatted(format)) s"
  }
}

#Preview {
  AudioFileEditorPreview()
    .frame(width: 760, height: 300)
}

/// A second of decaying tones, as a file in the staging folder, open in the editor.
private struct AudioFileEditorPreview: View {
  @State private var window: ProjectWindowModel = {
    let rate = 48_000.0
    let samples = (0..<Int(rate * 2)).map { index -> Float in
      let time = Double(index) / rate
      let beat = time.truncatingRemainder(dividingBy: 0.5)
      return Float(0.8 * exp(-beat * 8) * sin(2 * .pi * 220 * time))
    }
    let url = FileManager.default.temporaryDirectory.appending(path: "Audio File Editor Preview.caf")
    let document = OngakuDocument(project: Project())
    if let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
    {
      buffer.frameLength = buffer.frameCapacity
      samples.withUnsafeBufferPointer { buffer.floatChannelData?[0].update(from: $0.baseAddress!, count: samples.count) }
      if let output = try? AVAudioFile(forWriting: url, settings: format.settings) {
        try? output.write(from: buffer)
        output.close()
      }
    }
    let file = try? document.adoptRecordedAudio(
      at: url, sampleRate: rate, channelCount: 1, frameCount: Int64(samples.count), preferredName: "Vox")
    var project = Project()
    if let file {
      project.audioFiles = [file]
      project.tracks = [Track(name: "Vox", kind: .audio, regions: [
        Region(name: "Vox", start: .zero, length: .quarterNotes(2), content: .audio(AudioRegionContent(fileID: file.id, fileStartFrame: 24_000))),
      ])]
    }
    document.editor.load(project)
    let window = ProjectWindowModel(document: document)
    if let region = project.tracks.first?.regions.first {
      window.editorRegionID = region.id
      window.pianoRoll.audioFileSelection = 60_000..<72_000
    }
    if let file {
      let peaks = stride(from: 0, to: samples.count, by: Waveform.framesPerPeak).map { start in
        samples[start..<min(start + Waveform.framesPerPeak, samples.count)].map(abs).max() ?? 0
      }
      window.waveforms.adopt(Waveform(peaks: peaks, sampleRate: rate), for: file.id)
    }
    return window
  }()

  var body: some View {
    PianoRollView(model: window.pianoRoll)
  }
}
