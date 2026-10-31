//
//  SettingsTests.swift
//  OngakuTests
//

import OngakuCore
@testable import Ongaku
import Testing

/// The General and MIDI settings. Nothing here writes to user defaults, so running the
/// tests doesn't change the app's own settings.
@MainActor
struct SettingsTests {
  private let window = ProjectWindowModel(document: OngakuDocument(project: Project()))
  /// 4/4 at the default tempo: a beat is 960 ticks and a bar 3840.
  private let position = Tick(3840 + 960 + 500)

  @Test func snapModes() {
    #expect(window.snap(position, mode: .bar) == Tick(3840))
    #expect(window.snap(position, mode: .beat) == Tick(3840 + 1920))
    #expect(window.snap(position, mode: .off) == position)
    #expect(window.snap(position, mode: .automatic) == window.snap(position), "Automatic follows the zoom")
  }

  @Test func beatsFollowTheMeter() throws {
    try window.document.editor.perform(SetTimeSignature(TimeSignature(beatsPerBar: 6, beatUnit: 8)), undoManager: nil)
    // In 6/8 a beat is an eighth note (480 ticks): 1300 ticks into bar 2 rounds to 3 beats.
    #expect(window.snap(Tick(2880 + 1300), mode: .beat) == Tick(2880 + 1440))
  }

  @Test func newProjectTemplates() {
    #expect(AppSettings.NewProjectTemplate.instrumentTrack.makeProject().tracks.map(\.kind) == [.softwareInstrument])
    #expect(AppSettings.NewProjectTemplate.audioTrack.makeProject().tracks.map(\.kind) == [.audio])
    #expect(AppSettings.NewProjectTemplate.empty.makeProject().tracks.isEmpty)
  }

  @Test func ignoredMIDISourcesRoundTrip() {
    let ids: Set<Int32> = [-1_234_567, 42, 99]
    #expect(AppSettings.decodeSources(AppSettings.encodeSources(ids)) == ids)
    #expect(AppSettings.decodeSources("").isEmpty)
  }
}
