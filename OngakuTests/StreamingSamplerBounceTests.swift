//
//  StreamingSamplerBounceTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
@testable import OngakuEngine
import Testing

/// Bounces a song of big library instruments, which Apple's sampler plays from disk as they
/// go. Rendering a dozen of them at full speed overflowed the sampler's disk request queue
/// and Core Audio aborted the app. Uses Logic's factory instruments, found through the app's
/// libraries (a library named “Logic” must hold them), and skips without them.
@MainActor
@Suite(.serialized)
struct StreamingSamplerBounceTests {
  nonisolated private static let library = URL(filePath: "/Volumes/Logic/Library/Application Support/Logic")
  nonisolated private static let instruments = [
    "Sampler Instruments/Japanese Traditional/Koto.exs",
    "Sampler Instruments/10 World/02 Asian/Japanese Shakuhachi Flute.exs",
    "Sampler Instruments/08 Guitars/01 Acoustic Guitars/Steel String Acoustic 1.exs",
    "Sampler Instruments/06 Pop Strings/Cello (Pizzicato).exs",
    "Sampler Instruments/09 Orchestral/09 Strings/Basses Legato.exs",
    "Sampler Instruments/09 Orchestral/09 Strings/Cellos Legato.exs",
    "Sampler Instruments/09 Orchestral/09 Strings/Violas Legato.exs",
    "Sampler Instruments/09 Orchestral/09 Strings/Violins 1 Legato.exs",
    "Sampler Instruments/09 Orchestral/09 Strings/Violins 2 Legato.exs",
    "Sampler Instruments/09 Orchestral/02 Brass/French Horns Legato.exs",
    "Sampler Instruments/09 Orchestral/08 Choir/Classical Ensemble.exs",
    "Sampler Instruments/09 Orchestral/04 Tuned Percussion/Timpani SingleStrokes.exs",
    "Sampler Instruments/Japanese Traditional/Taiko Drums.exs",
    "Sampler Instruments/09 Orchestral/06 Harp/Harp.exs",
  ]

  nonisolated private static var isInstalled: Bool {
    instruments.allSatisfy { FileManager.default.isReadableFile(atPath: library.appending(path: $0).path(percentEncoded: false)) }
  }

  /// Every track plays overlapping chords on every beat for 32 bars, so many voices stream at once.
  private func song() -> Project {
    let tracks = Self.instruments.enumerated().map { index, path in
      var track = Track(name: path, kind: .softwareInstrument)
      track.channel.instrument = .sampler(SamplerInstrument(libraryID: nil, libraryName: "Logic", path: path))
      var notes: [MIDINote] = []
      for beat in 0..<128 {
        for offset in [0, 4, 7, 12] {
          let pitch = 36 + (index * 3 + beat * 5 + offset) % 48
          notes.append(MIDINote(pitch: pitch, velocity: 100, start: .quarterNotes(Double(beat)), length: .quarterNotes(2)))
        }
      }
      track.regions = [Region(name: "Chords", start: .zero, length: .quarterNotes(128), content: .midi(MIDISequence(notes: notes)))]
      return track
    }
    return Project(tracks: tracks)
  }

  @Test(.enabled(if: isInstalled)) func bouncingManyStreamingSamplersFinishes() async throws {
    let project = song()
    let folder = FileManager.default.temporaryDirectory.appending(path: "StreamingSamplerBounce-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let bouncer = ProjectBouncer(project: project) { _ in nil }
    let range = try #require(project.bounceRange)
    let started = ContinuousClock.now
    let result = try await bouncer.bounce(
      range, settings: BounceSettings(bitDepth: .thirtyTwoFloat, includeTail: false), to: folder.appending(path: "Mix.wav"))
    print("Library sampler bounce: \(result.duration) s of music in \(ContinuousClock.now - started), \(Self.footprintMB()) MB in use")
    #expect(result.duration > 60)
    #expect(result.peakDecibels > -60, "The instruments are heard")
  }

  /// The app's memory footprint, as Activity Monitor shows it, in megabytes.
  private static func footprintMB() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return status == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
  }
}
