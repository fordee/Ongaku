//
//  MusicXMLTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// MusicXML export: well formed, with the score's notes, rests, ties, triplets and chords.
struct MusicXMLTests {
  private let quarter: Int64 = 960

  private func note(_ pitch: Int, _ start: Int64, _ length: Int64) -> MIDINote {
    MIDINote(pitch: pitch, velocity: 90, start: Tick(start), length: Tick(length))
  }

  private func export(_ notes: [MIDINote], bars: Int64 = 1, key: KeySignature? = nil, chords: [ChordChange] = []) throws -> XMLDocument {
    var project = Project()
    if let key { project.keySignature = key }
    project.chords = chords
    let region = Region(name: "Tune", start: .zero, length: Tick(quarter * 4 * bars), content: .midi(MIDISequence(notes: notes)))
    let layout = ScoreLayout(region: region, in: project)
    let text = MusicXML.document(for: layout, title: "Tune & Co", partName: "Piano")
    return try XMLDocument(xmlString: text, options: [])
  }

  private func values(_ document: XMLDocument, _ path: String) throws -> [String] {
    try document.nodes(forXPath: path).compactMap(\.stringValue)
  }

  @Test func theDocumentIsWellFormedWithAttributes() throws {
    let document = try export([note(72, 0, quarter)], key: KeySignature(tonic: 2, mode: .major))
    #expect(try values(document, "//work-title") == ["Tune & Co"])
    #expect(try values(document, "//divisions") == ["960"])
    #expect(try values(document, "//key/fifths") == ["2"])
    #expect(try values(document, "//time/beats") == ["4"])
    #expect(try values(document, "//clef/sign") == ["G"])
  }

  @Test func notesRestsAndDurationsAddUpToTheBar() throws {
    let document = try export([note(72, quarter, quarter)])
    let durations = try values(document, "//measure[1]/note/duration").compactMap(Int.init)
    #expect(durations.reduce(0, +) == 3840)
    #expect(try values(document, "//note/pitch/step") == ["C"])
    #expect(try values(document, "//note/pitch/octave") == ["5"])
    #expect(try document.nodes(forXPath: "//note/rest").count == 2)
  }

  @Test func tiesAcrossTheBarLineAreWrittenBothEnds() throws {
    let document = try export([note(67, quarter * 3, quarter * 2)], bars: 2)
    #expect(try document.nodes(forXPath: "//measure[1]//tie[@type='start']").count == 1)
    #expect(try document.nodes(forXPath: "//measure[2]//tie[@type='stop']").count == 1)
  }

  @Test func tripletsCarryTheirTimeModification() throws {
    let third = quarter / 3
    let document = try export((0..<3).map { note(72, Int64($0) * third, third) })
    #expect(try document.nodes(forXPath: "//time-modification/actual-notes").count == 3)
    #expect(try document.nodes(forXPath: "//tuplet[@type='start']").count == 1)
    #expect(try document.nodes(forXPath: "//tuplet[@type='stop']").count == 1)
  }

  @Test func chordSymbolsAreHarmonies() throws {
    let chords = [ChordChange(position: .zero, chord: Chord(name: "B♭m7")!), ChordChange(position: Tick(quarter * 2), chord: Chord(name: "F")!)]
    let document = try export([note(65, 0, quarter * 4)], chords: chords)
    #expect(try values(document, "//harmony/root/root-step") == ["B", "F"])
    #expect(try values(document, "//harmony/root/root-alter") == ["-1"])
    #expect(try values(document, "//harmony/kind") == ["minor-seventh", "major"])
    #expect(try values(document, "//harmony/offset") == ["1920"])
  }

  @Test func grandStavesBackUpForTheSecondStaff() throws {
    let document = try export([note(76, 0, quarter), note(40, 0, quarter)])
    #expect(try values(document, "//staves") == ["2"])
    #expect(try values(document, "//clef/sign") == ["G", "F"])
    #expect(try values(document, "//backup/duration") == ["3840"])
  }
}
