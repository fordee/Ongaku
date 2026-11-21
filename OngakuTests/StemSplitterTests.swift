//
//  StemSplitterTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
@testable import Ongaku
import OngakuCore
@testable import OngakuEngine
import Testing

/// The Stem Splitter's model, read from the bundled checkpoint.
struct StemSplitterTests {
  private var modelURL: URL? { Bundle.main.url(forResource: "htdemucs", withExtension: "th") }

  @Test func theCheckpointIsReadWithoutPython() throws {
    let url = try #require(modelURL, "Run Scripts/fetch-stem-model.sh to put the model in Ongaku/StemModel")
    let checkpoint = try TorchCheckpoint(contentsOf: url)
    let state = checkpoint.state
    #expect(state.count > 500)
    let first = try #require(state["encoder.0.conv.weight"])
    #expect(first.shape == [48, 4, 8, 1])
    #expect(checkpoint.kwargs["sources"].map { "\($0)" }?.contains("vocals") == true)
    #expect(abs((checkpoint.kwargs["segment"]?.double ?? 0) - 7.8) < 1e-9)
  }

  // MARK: - The arithmetic, against plain loops

  @Test func theSTFTIsTorchsNormalizedDFTAndInvertsExactly() {
    let stft = StemSTFT(size: 64, hop: 16)
    let signal = (0..<300).map { Float(sin(Double($0) * 0.37) + 0.3 * cos(Double($0) * 1.9)) }
    let spectrum = stft.forward(signal)
    // Frame 5 against a direct DFT of the same (centred, reflect-padded, Hann) frame.
    let padded = StemSTFT.reflect(signal, left: 32, right: 32)
    let window = (0..<64).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 64) }
    for k in [0, 3, 17, 32] {
      var re = 0.0, im = 0.0
      for n in 0..<64 {
        let x = Double(padded[5 * 16 + n]) * window[n]
        re += x * cos(2 * .pi * Double(k * n) / 64)
        im -= x * sin(2 * .pi * Double(k * n) / 64)
      }
      #expect(abs(Double(spectrum.real[5][k]) - re / 8) < 1e-3, "bin \(k) real")
      #expect(abs(Double(spectrum.imaginary[5][k]) - im / 8) < 1e-3, "bin \(k) imaginary")
    }
    let back = stft.inverse(real: spectrum.real, imaginary: spectrum.imaginary, length: signal.count)
    let error = zip(back, signal).map { abs($0 - $1) }.max() ?? 1
    #expect(error < 1e-4, "Round trip error \(error)")
  }

  private func random(_ count: Int, seed: Int) -> [Float] {
    var state = UInt64(seed) &* 6364136223846793005 &+ 1442695040888963407
    return (0..<count).map { _ in
      state = state &* 6364136223846793005 &+ 1442695040888963407
      return Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1
    }
  }

  @Test func convolutionsMatchPlainLoops() {
    // Along columns, with stride, padding and dilation, over two rows.
    let (c, r, t, o, k) = (3, 2, 20, 4, 3)
    let x = random(c * r * t, seed: 1), weight = random(o * c * k, seed: 2), bias = random(o, seed: 3)
    let (stride, padding, dilation) = (2, 2, 2)
    let result = StemOps.convColumns(x, channels: c, rows: r, columns: t, weight: weight, bias: bias, outChannels: o, kernel: k, stride: stride, padding: padding, dilation: dilation)
    for oc in 0..<o {
      for row in 0..<r {
        for out in 0..<result.columns {
          var sum = bias[oc]
          for ic in 0..<c {
            for tap in 0..<k {
              let source = out * stride + tap * dilation - padding
              if source >= 0 && source < t { sum += weight[(oc * c + ic) * k + tap] * x[(ic * r + row) * t + source] }
            }
          }
          #expect(abs(result.values[(oc * r + row) * result.columns + out] - sum) < 1e-4)
        }
      }
    }
    // Along rows (frequency), kernel 8 stride 4 padding 2.
    let rows = 16, columns = 3
    let fx = random(c * rows * columns, seed: 4), fw = random(o * c * 8, seed: 5)
    let freq = StemOps.convRows(fx, channels: c, rows: rows, columns: columns, weight: fw, bias: bias, outChannels: o, kernel: 8, stride: 4, padding: 2)
    #expect(freq.rows == 4)
    for oc in 0..<o {
      for fr in 0..<freq.rows {
        for col in 0..<columns {
          var sum = bias[oc]
          for ic in 0..<c {
            for tap in 0..<8 {
              let source = fr * 4 + tap - 2
              if source >= 0 && source < rows { sum += fw[(oc * c + ic) * 8 + tap] * fx[(ic * rows + source) * columns + col] }
            }
          }
          #expect(abs(freq.values[(oc * freq.rows + fr) * columns + col] - sum) < 1e-4)
        }
      }
    }
    // 3×3, padding 1.
    let w3 = random(o * c * 9, seed: 6)
    let three = StemOps.conv3x3(fx, channels: c, rows: rows, columns: columns, weight: w3, bias: bias, outChannels: o)
    for oc in 0..<o {
      for fr in 0..<rows {
        for col in 0..<columns {
          var sum = bias[oc]
          for ic in 0..<c {
            for a in 0..<3 {
              for b in 0..<3 {
                let rr = fr + a - 1, cc = col + b - 1
                if rr >= 0 && rr < rows && cc >= 0 && cc < columns { sum += w3[((oc * c + ic) * 3 + a) * 3 + b] * fx[(ic * rows + rr) * columns + cc] }
              }
            }
          }
          #expect(abs(three[(oc * rows + fr) * columns + col] - sum) < 1e-4)
        }
      }
    }
    // Transposed, along columns: weights [in, out, k].
    let tw = random(c * o * 8, seed: 7)
    let up = StemOps.convTranspose(x, channels: c, rows: r, columns: t, weight: tw, bias: bias, outChannels: o, kernel: 8, stride: 4, alongRows: false)
    #expect(up.columns == (t - 1) * 4 + 8)
    var expected = [Float](repeating: 0, count: o * r * up.columns)
    for oc in 0..<o {
      for row in 0..<r {
        for i in 0..<up.columns { expected[(oc * r + row) * up.columns + i] = bias[oc] }
      }
    }
    for ic in 0..<c {
      for oc in 0..<o {
        for row in 0..<r {
          for i in 0..<t {
            for tap in 0..<8 { expected[(oc * r + row) * up.columns + i * 4 + tap] += tw[(ic * o + oc) * 8 + tap] * x[(ic * r + row) * t + i] }
          }
        }
      }
    }
    #expect(zip(up.values, expected).allSatisfy { abs($0 - $1) < 1e-4 })
  }

  // MARK: - The whole model

  @Test func theModelSeparatesDrumsFromAHeldChord() throws {
    let url = try #require(modelURL)
    let model = try HTDemucs(checkpoint: url)
    let rate = HTDemucs.sampleRate
    let count = Int(rate * 6)
    // Kick drums every half second, and an organ-like C major chord held throughout.
    var kicks = [Float](repeating: 0, count: count), chord = [Float](repeating: 0, count: count)
    for i in 0..<count {
      let t = Double(i) / rate
      let sinceHit = t.truncatingRemainder(dividingBy: 0.5)
      kicks[i] = Float(0.8 * exp(-sinceHit * 18) * sin(2 * .pi * (50 + 80 * exp(-sinceHit * 30)) * sinceHit))
      chord[i] = Float([261.63, 329.63, 392.0].reduce(0) { $0 + 0.08 * sin(2 * .pi * $1 * t) + 0.03 * sin(4 * .pi * $1 * t) })
    }
    let mix = zip(kicks, chord).map(+)
    let started = Date()
    let stems = model.separate(left: mix, right: mix)
    print("STEMS one 6 s segment took \(Date().timeIntervalSince(started)) s")
    #expect(stems.count == 4 && stems.allSatisfy { $0.count == 2 && $0[0].count == count })
    #expect(stems.allSatisfy { $0.allSatisfy { $0.allSatisfy(\.isFinite) } })
    func correlation(_ a: [Float], _ b: [Float]) -> Double {
      let n = Double(a.count)
      let ma = a.reduce(0, +) / Float(n), mb = b.reduce(0, +) / Float(n)
      var ab = 0.0, aa = 0.0, bb = 0.0
      for i in a.indices {
        let x = Double(a[i] - ma), y = Double(b[i] - mb)
        ab += x * y
        aa += x * x
        bb += y * y
      }
      return ab / max(1e-12, (aa * bb).squareRoot())
    }
    let drums = stems[0][0], other = stems[2][0]
    print("STEMS drums~kicks \(correlation(drums, kicks)) drums~chord \(correlation(drums, chord)) other~chord \(correlation(other, chord)) other~kicks \(correlation(other, kicks))")
    #expect(correlation(drums, kicks) > 0.8, "The drums stem is the kicks")
    #expect(correlation(drums, kicks) > correlation(drums, chord))
    // And between them the stems add back up to the mix.
    let sum = (0..<count).map { i in stems.reduce(Float(0)) { $0 + $1[0][i] } }
    #expect(correlation(sum, mix) > 0.95)
  }
}

/// Split into Stems in a song window.
@MainActor
struct StemSplitWindowTests {
  @Test func aRegionIsSplitIntoAFolderOfStems() async throws {
    try #require(ProjectWindowModel.stemModelURL != nil)
    // Three seconds of kicks and a chord, as a stereo WAV.
    let rate = 44_100.0, count = Int(rate * 3)
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
    buffer.frameLength = AVAudioFrameCount(count)
    for i in 0..<count {
      let t = Double(i) / rate, since = t.truncatingRemainder(dividingBy: 0.5)
      let value = Float(0.7 * exp(-since * 18) * sin(2 * .pi * 60 * since) + 0.1 * sin(2 * .pi * 261.63 * t) + 0.1 * sin(2 * .pi * 392 * t))
      buffer.floatChannelData![0][i] = value
      buffer.floatChannelData![1][i] = value
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    file.close()

    let document = OngakuDocument(project: Project())
    let window = ProjectWindowModel(document: document)
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    window.undoManager = undoManager
    let reference = try await document.stageAudio(from: url)
    let region = Region.audio(for: reference, at: .zero, tempoMap: window.project.tempoMap, name: "Groove")
    undoManager.beginUndoGrouping()
    window.perform(CompositeCommand("Setup", commands: [AddAudioFile(reference), AddTrack(Track(name: "Mix", kind: .audio, regions: [region]))]))
    undoManager.endUndoGrouping()

    window.selectedRegionIDs = [region.id]
    #expect(window.stemSplitTarget?.id == region.id)
    window.showStemSplit()
    undoManager.beginUndoGrouping()
    await window.startStemSplit()?.value
    undoManager.endUndoGrouping()
    #expect(window.errorMessage == nil)
    #expect(window.stemSplit == nil, "The dialog closes when it's done")
    let names = window.project.tracks.map(\.name)
    #expect(names == ["Mix", "Groove Stems", "Mix Drums", "Mix Bass", "Mix Other", "Mix Vocals"])
    #expect(window.project.tracks[0].regions[0].isMuted)
    // The stems are real files, as long as the region.
    for track in window.project.tracks[2...] {
      guard case .audio(let content) = track.regions.first?.content,
        let stem = window.project.audioFiles.first(where: { $0.id == content.fileID })
      else {
        Issue.record("\(track.name) has a stem")
        continue
      }
      #expect(abs(Double(stem.frameCount) / stem.sampleRate - 3) < 0.05)
      #expect(document.url(for: stem).map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }
    #expect(undoManager.undoActionName == "Split into Stems")
    undoManager.undo()
    #expect(window.project.tracks.map(\.name) == ["Mix"] && !window.project.tracks[0].regions[0].isMuted)
  }
}
