//
//  MIDIImportColorTests.swift
//  OngakuTests
//

import OngakuCore
@testable import Ongaku
import Testing

/// The Settings option for colouring tracks imported from MIDI files.
@MainActor
struct MIDIImportColorTests {
  private let tracks = (1...10).map { Track(name: "Track \($0)", kind: .softwareInstrument) }

  @Test func instrumentColorUsesTheInstrumentTrackColor() {
    let colored = ProjectWindowModel.colorImportedTracks(tracks, .instrumentColor, instrumentColor: .teal)
    #expect(colored.map(\.color) == Array(repeating: .teal, count: 10))
  }

  @Test func variedGivesEachTrackTheNextColor() {
    let colored = ProjectWindowModel.colorImportedTracks(tracks, .varied, instrumentColor: .teal)
    #expect(colored.map(\.color) == [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .red, .orange])
    #expect(colored.map(\.id) == tracks.map(\.id), "Only the colours change")
  }
}
