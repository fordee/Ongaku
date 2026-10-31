//
//  KeyChangeTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Key changes on the Signature track: the key from a bar on, what follows it, and where
/// they're kept.
struct KeyChangeTests {
  private let bar = Tick(3840)
  private let dMajor = KeySignature(tonic: 2, mode: .major)
  private let bMinor = KeySignature(tonic: 11, mode: .minor)

  @Test func theKeyChangesFromItsBarOn() throws {
    var project = Project()
    try SetKey(dMajor, at: bar * 8).apply(to: &project)
    #expect(project.key(at: .zero) == .cMajor)
    #expect(project.key(at: bar * 8 - Tick(1)) == .cMajor)
    #expect(project.key(at: bar * 8) == dMajor)
    #expect(project.key(at: bar * 20) == dMajor)
    #expect(project.keyStart(at: bar * 10) == bar * 8)
    #expect(project.keyStart(at: bar * 2) == .zero)
  }

  @Test func settingTheKeyAtTheStartChangesTheSongsKey() throws {
    var project = Project()
    try SetKey(bMinor, at: .zero).apply(to: &project)
    #expect(project.keySignature == bMinor)
    #expect(project.keyChanges.isEmpty)
  }

  @Test func aChangeAtTheSameBarIsReplacedNotDoubled() throws {
    var project = Project()
    try SetKey(dMajor, at: bar * 4).apply(to: &project)
    try SetKey(bMinor, at: bar * 4).apply(to: &project)
    #expect(project.keyChanges.map(\.key) == [bMinor])
  }

  @Test func aChangeToTheKeyAlreadyPlayingIsDropped() throws {
    var project = Project()
    try SetKey(.cMajor, at: bar * 4).apply(to: &project)
    #expect(project.keyChanges.isEmpty, "C major to C major changes nothing")
    // Changing the song's key to the change's key leaves the change with nothing to do.
    try SetKey(dMajor, at: bar * 4).apply(to: &project)
    try SetKeySignature(dMajor).apply(to: &project)
    #expect(project.keyChanges.isEmpty)
  }

  @Test func keyChangesMoveAndDelete() throws {
    var project = Project()
    try SetKey(dMajor, at: bar * 4).apply(to: &project)
    try SetKey(bMinor, at: bar * 8).apply(to: &project)
    let first = try #require(project.keyChanges.first)
    try MoveKeyChange(first.id, to: bar * 10).apply(to: &project)
    #expect(project.keyChanges.map(\.position) == [bar * 8, bar * 10], "Kept in order")
    #expect(project.key(at: bar * 9) == bMinor)
    #expect(throws: EditError.self) { try MoveKeyChange(first.id, to: .zero).apply(to: &project) }
    try RemoveKeyChanges([first.id]).apply(to: &project)
    #expect(project.keyChanges.map(\.key) == [bMinor])
  }

  @Test func keyChangesAreSavedAndOlderSongsHaveNone() throws {
    var project = Project()
    try SetKey(dMajor, at: bar * 4).apply(to: &project)
    let saved = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    #expect(saved.keyChanges == project.keyChanges)
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(project)) as? [String: Any])
    object["keyChanges"] = nil
    let older = try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(older.keyChanges.isEmpty)
  }

  @Test func sectionEditsTakeKeyChangesWithTheMusic() throws {
    var project = Project()
    try SetKey(dMajor, at: bar * 8).apply(to: &project)
    try InsertSilence(bar * 2..<bar * 4).apply(to: &project)
    #expect(project.keyChanges.map(\.position) == [bar * 10])
    try CutSection(bar * 2..<bar * 4).apply(to: &project)
    #expect(project.keyChanges.map(\.position) == [bar * 8])
    try CutSection(bar * 6..<bar * 10).apply(to: &project)
    #expect(project.keyChanges.isEmpty, "A change in the cut goes with it")
  }

  @Test func theBassPlayerPlaysTheNewKeysHomeChordWhereThereAreNoChords() throws {
    var project = Project()
    project.keyChanges = [KeyChange(position: bar * 2, key: dMajor)]
    var region = Region(
      name: "Verse", start: .zero, length: bar * 4, content: .midi(MIDISequence()),
      player: PlayerPerformance(style: .rootNotes, complexity: 0.5, leadsIntoNext: false, seed: 4))
    region.renderPlayer(in: project)
    guard case .midi(let sequence) = region.content else { Issue.record("No notes"); return }
    for (barIndex, root) in [0, 0, 2, 2].enumerated() {
      let downbeat = try #require(sequence.notes.first { abs($0.start.rawValue - bar.rawValue * Int64(barIndex)) <= 8 })
      #expect(downbeat.pitch % 12 == root, "Bar \(barIndex + 1) is on the key's home note")
    }
  }

  @Test func midiFilesCarryTheKeys() throws {
    var project = Project(tracks: [Track(name: "Keys", kind: .softwareInstrument, regions: [
      Region(name: "Notes", start: .zero, length: bar * 8, content: .midi(MIDISequence(notes: [
        MIDINote(pitch: 60, start: .zero, length: .quarterNotes(1)),
      ]))),
    ])])
    project.keySignature = bMinor
    project.keyChanges = [KeyChange(position: bar * 4, key: KeySignature(tonic: 3, mode: .major))]
    let contents = try StandardMIDIFile.read(StandardMIDIFile.write(project))
    #expect(contents.keySignature == bMinor)
    #expect(contents.keyChanges.map(\.position) == [bar * 4])
    #expect(contents.keyChanges.first?.key == KeySignature(tonic: 3, mode: .major))
  }

  @Test func keySignaturesUseTheFewestSharpsOrFlats() {
    let cases: [(KeySignature, Int)] = [
      (.cMajor, 0), (KeySignature(tonic: 7, mode: .major), 1), (KeySignature(tonic: 5, mode: .major), -1),
      (KeySignature(tonic: 6, mode: .major), 6), (KeySignature(tonic: 3, mode: .major), -3),
      (KeySignature(tonic: 9, mode: .minor), 0), (bMinor, 2), (KeySignature(tonic: 2, mode: .minor), -1),
    ]
    for (key, count) in cases {
      #expect(key.sharpsOrFlats == count, "\(key)")
      #expect(KeySignature(sharpsOrFlats: count, isMinor: key.mode == .minor) == key)
    }
  }
}
