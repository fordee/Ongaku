//
//  RegionEditabilityTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Which edits each kind of region takes, checked the same way by every command.
struct RegionEditabilityTests {
  private let file = AudioFileReference(fileName: "Vocal.caf", sampleRate: 48_000, channelCount: 1, frameCount: 192_000)

  private func audioProject(flexed: Bool) -> (Project, Region.ID) {
    let markers = flexed ? [FlexMarker(source: 0.5, target: 0.6)] : []
    let region = Region(
      name: "Vocal", start: .zero, length: .quarterNotes(8), content: .audio(AudioRegionContent(fileID: file.id, flexMarkers: markers)))
    return (Project(tracks: [Track(name: "Vocal", kind: .audio, regions: [region])], audioFiles: [file]), region.id)
  }

  private func message(_ body: () throws -> Void) -> String? {
    do { try body() } catch { return error.localizedDescription }
    return nil
  }

  @Test func takeFoldersOnlyLetTheirNotesBeEdited() {
    let take = Take(name: "Take 1", content: .midi(MIDISequence()))
    let region = Region(
      name: "Keys", start: .zero, length: .quarterNotes(4), content: take.content,
      takeFolder: TakeFolder(takes: [take], playing: take.id, length: .quarterNotes(4)))
    for edit in RegionEdit.allCases where edit != .editNotes {
      #expect(region.reasonCantEdit(edit)?.hasPrefix("“Keys” is a take folder. Flatten it first") == true, "\(edit)")
    }
    #expect(region.canEdit(.editNotes))
  }

  @Test func flexedAudioRefusesEveryEditThatShiftsItsTime() throws {
    let (flexed, id) = audioProject(flexed: true)
    let resize = message { var project = flexed; try ResizeRegion(id, start: .zero, length: .quarterNotes(4)).apply(to: &project) }
    let split = message { var project = flexed; try SplitRegion(id, at: .quarterNotes(2)).apply(to: &project) }
    let loopHandle = message { var project = flexed; try SetRegionLoop(id, to: .quarterNotes(16)).apply(to: &project) }
    let loopSwitch = message { var project = flexed; try SetRegionParameter(.looped(true), for: [id]).apply(to: &project) }
    #expect(resize?.hasPrefix("To resize “Vocal”, first remove its flex markers") == true)
    #expect(split?.hasPrefix("To split “Vocal”") == true)
    #expect(loopHandle != nil && loopHandle == loopSwitch, "The Loop switch and the loop handle agree")

    // Without flex markers, all of them work.
    let (plain, plainID) = audioProject(flexed: false)
    var project = plain
    try SetRegionParameter(.looped(true), for: [plainID]).apply(to: &project)
    try SplitRegion(plainID, at: .quarterNotes(2)).apply(to: &project)
  }

  @Test func generatedNotesCantBeEditedButControllersCan() throws {
    var region = Region(
      name: "Drums", start: .zero, length: .quarterNotes(4), content: .midi(MIDISequence()), drummer: DrummerPerformance())
    region.renderDrummer(tempoMap: TempoMap())
    var project = Project(tracks: [Track(name: "Drums", kind: .softwareInstrument, regions: [region])])

    let added = message { try AddNotes([MIDINote(pitch: 38, start: .zero, length: Tick(240))], to: region.id).apply(to: &project) }
    #expect(added == "“Drums” is played by the Drummer. Convert it to a MIDI region first to edit its notes.")

    try AddControlEvents([MIDIControlEvent(kind: .sustain, position: .zero, value: 127)], to: region.id).apply(to: &project)
    guard case .midi(let sequence) = project.region(withID: region.id)?.content else { Issue.record(); return }
    #expect(sequence.controls.count == 1)
  }
}
