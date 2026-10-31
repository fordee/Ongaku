//
//  DownloadedMIDIFileTests.swift
//  OngakuTests
//

import Foundation
import OngakuCore
import Testing

/// Imports a MIDI file the user downloaded, which sets each channel's volume and pan at the
/// start and uses pitch bend. Skipped on machines without it.
struct DownloadedMIDIFileTests {
  private static let file = realHomeDirectory.appending(path: "Downloads/Movie_Themes_-_Addicted_To_Love.mid")

  @Test(.enabled(if: FileManager.default.fileExists(atPath: file.path)))
  func controllersAreKept() throws {
    let contents = try StandardMIDIFile.read(Data(contentsOf: Self.file))
    #expect(contents.tracks.count == 9)
    var kinds: Set<MIDIControlEvent.Kind> = []
    for track in contents.tracks {
      let region = try #require(track.regions.first)
      guard case .midi(let sequence) = region.content else { continue }
      kinds.formUnion(sequence.controls.map(\.kind))
      // The volume set at the very start keeps every region starting at bar 1, so it plays.
      #expect(region.start == .zero, "“\(track.name)” should start at bar 1")
      #expect(sequence.controls.contains { $0.kind == .volume && $0.position == .zero })
    }
    #expect(kinds.isSuperset(of: [.volume, .pan, .pitchBend]))
  }
}
