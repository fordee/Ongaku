//
//  FlexPitchTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Flex Pitch: finding the notes of monophonic audio and retuning them.
struct FlexPitchTests {
  private let rate = 48_000.0

  /// A note with a few harmonics (like a voice or a reed), `seconds` long.
  private func note(_ midi: Double, seconds: Double) -> [Float] {
    let frequency = 440 * pow(2, (midi - 69) / 12)
    return (0..<Int(seconds * rate)).map { index in
      let t = Double(index) / rate
      return Float(0.4 * sin(2 * .pi * frequency * t) + 0.2 * sin(4 * .pi * frequency * t) + 0.1 * sin(6 * .pi * frequency * t))
    }
  }

  private func silence(_ seconds: Double) -> [Float] {
    [Float](repeating: 0, count: Int(seconds * rate))
  }

  @Test func notesAreFoundWithTheirPitch() {
    // A3, C4 (tied on), a rest, then E4 a quarter tone sharp.
    let audio = note(57, seconds: 0.5) + note(60, seconds: 0.5) + silence(0.2) + note(64.5, seconds: 0.5)
    let notes = PitchDetector.notes(audio, sampleRate: rate)
    #expect(notes.count == 3)
    for (found, expected) in zip(notes, [57.0, 60.0, 64.5]) {
      #expect(abs(found.pitch - expected) < 0.1, "\(found.pitch) vs \(expected)")
    }
    #expect(abs((notes.first?.start ?? 1) - 0) < 0.03)
    #expect(abs((notes.last?.start ?? 0) - 1.2) < 0.05, "The last note starts after the rest")
  }

  @Test func silenceHasNoNotes() {
    #expect(PitchDetector.notes(silence(1), sampleRate: rate).isEmpty)
  }

  @Test func retuningMovesANoteAndKeepsItsTiming() {
    // One second of A4; the middle half second moved up a whole tone.
    let audio = note(69, seconds: 1)
    let edit = PitchEdit(start: 0.25, end: 0.75, semitones: 2)
    let retuned = PitchShifter.apply([edit], to: [audio], sampleRate: rate)[0]
    #expect(retuned.count == audio.count)
    let notes = PitchDetector.notes(retuned, sampleRate: rate)
    let middle = notes.first { $0.start > 0.2 && $0.start < 0.4 }
    #expect(middle.map { abs($0.pitch - 71) < 0.15 } == true, "The middle is B4 (\(String(describing: middle?.pitch)))")
    #expect(notes.first.map { abs($0.pitch - 69) < 0.15 } == true, "The start is still A4")
  }

  @Test func flexPitchRendersTheEdits() {
    let audio = note(69, seconds: 1)
    let map = FlexMap(markers: [], duration: 1)
    let rendered = FlexRenderer.render(
      [audio], map: map, mode: .pitch, pitchEdits: [PitchEdit(start: 0, end: 1, semitones: -12)], sampleRate: rate)[0]
    #expect(rendered.count == audio.count)
    let notes = PitchDetector.notes(rendered, sampleRate: rate)
    #expect(notes.contains { abs($0.pitch - 57) < 0.15 }, "An octave down: \(notes.map(\.pitch))")
  }

  @Test func pitchEditsNeedFlexPitchToRender() throws {
    let file = AudioFileReference(fileName: "Vocal.caf", sampleRate: rate, channelCount: 1, frameCount: 96_000)
    let region = Region(name: "Vocal", start: .zero, length: .quarterNotes(4), content: .audio(AudioRegionContent(fileID: file.id)))
    var project = Project(tracks: [Track(name: "Vocal", kind: .audio, regions: [region], flexMode: .rhythmic)], audioFiles: [file])
    try SetPitchEdits([PitchEdit(start: 0.5, end: 1, semitones: 1)], in: region.id).apply(to: &project)
    #expect(project.flexRenderKey(for: project.tracks[0].regions[0], on: project.tracks[0]) == nil, "Rhythmic doesn't retune")
    project.tracks[0].flexMode = .pitch
    let key = try #require(project.flexRenderKey(for: project.tracks[0].regions[0], on: project.tracks[0]))
    #expect(key.pitchEdits.count == 1)
    #expect(throws: EditError.self) {
      try SetPitchEdits([PitchEdit(start: 0.5, end: 1, semitones: 30)], in: region.id).apply(to: &project)
    }
    let reopened = try ProjectArchive.decode(ProjectArchive.encode(project))
    #expect(reopened == project)
  }
}
