//
//  BounceInPlaceTests.swift
//  OngakuCoreTests
//

import Foundation
import Testing
@testable import OngakuCore

/// Rendering one track on its own (Bounce in Place, Export All Tracks), and putting a bounce
/// on a new track.
struct BounceInPlaceTests {
  private let bar = Tick.quarterNotes(4)

  private func project() -> (Project, Track) {
    var keys = Track(name: "Keys", kind: .softwareInstrument)
    keys.regions = [
      Region(name: "A", start: bar, length: bar, content: .midi(MIDISequence())),
      Region(name: "B", start: bar * 3, length: bar, content: .midi(MIDISequence())),
    ]
    keys.channel.volume = -6
    keys.channel.pan = 0.5
    keys.channel.isMuted = true
    keys.channel.inserts = [PluginReference(componentType: 0, componentSubType: 0, componentManufacturer: 0, name: "Echo")]
    let aux = Track(name: "Verb", kind: .aux)
    keys.channel.sends = [Send(destinationTrackID: aux.id, level: -10)]
    keys.automation = [
      AutomationLane(parameter: .volume, points: [AutomationPoint(position: .zero, value: -3)]),
      AutomationLane(parameter: .plugin(PluginParameter(pluginID: keys.channel.inserts[0].id, address: 1, name: "Time")), points: [AutomationPoint(position: .zero, value: 0.5)]),
    ]
    var project = Project(tracks: [keys, aux])
    project.masterVolume = -4
    return (project, keys)
  }

  @Test func aTrackIsRenderedOnItsOwn() throws {
    let (project, keys) = project()
    let alone = try #require(project.isolating(keys.id, options: TrackRenderOptions()))
    let track = try #require(alone.tracks.first)
    #expect(alone.tracks.count == 1 && alone.masterVolume == 0 && alone.stereoOutInserts.isEmpty)
    #expect(track.channel.sends.isEmpty && !track.channel.isMuted && track.channel.output == .stereoOut)
    #expect(track.channel.volume == 0 && track.channel.pan == 0, "At unity in the centre by default")
    #expect(track.channel.inserts.count == 1)
    #expect(track.automation.map(\.parameter) == [keys.automation[1].parameter], "The plug-in's automation, not the fader's")

    let dry = try #require(project.isolating(keys.id, options: TrackRenderOptions(includesEffects: false, includesVolumeAndPan: true)))
    #expect(dry.tracks[0].channel.inserts.isEmpty && dry.tracks[0].channel.volume == -6)
    #expect(dry.tracks[0].automation.map(\.parameter) == [.volume])

    let one = try #require(project.isolating(keys.id, regionIDs: [keys.regions[1].id], options: TrackRenderOptions()))
    #expect(one.tracks[0].regions.map(\.name) == ["B"])
    #expect(project.isolating(project.tracks[1].id, options: TrackRenderOptions()) == nil, "Aux tracks have no regions")
    #expect(project.span(ofTrack: keys.id) == bar..<(bar * 4))
  }

  @Test func theBounceGoesOnANewTrackBelow() throws {
    let (project, keys) = project()
    let file = AudioFileReference(fileName: "Keys Bounce.caf", sampleRate: 48_000, channelCount: 2, frameCount: 48_000 * 7)
    var muted = project
    try BounceInPlace(keys.id, regions: Set(keys.regions.map(\.id)), file: file, into: Track(name: "Keys Bounce", kind: .audio), source: .mute)
      .apply(to: &muted)
    #expect(muted.tracks.map(\.name) == ["Keys", "Keys Bounce", "Verb"])
    let region = try #require(muted.tracks[1].regions.first)
    #expect(region.start == bar && region.name == "Keys Bounce")
    #expect(muted.tracks[0].regions.allSatisfy { $0.isMuted })
    #expect(muted.audioFile(withID: file.id) != nil)

    var deleted = project
    try BounceInPlace(keys.id, regions: [keys.regions[0].id], file: file, into: Track(name: "Keys Bounce", kind: .audio), source: .delete)
      .apply(to: &deleted)
    #expect(deleted.tracks[0].regions.map(\.name) == ["B"])
  }
}

/// Split into Stems: each stem on its own track in a folder stack below, the original muted.
struct SplitIntoStemsTests {
  private func stems() -> (stems: [SplitIntoStems.Stem], tracks: [Track]) {
    let names = ["Drums", "Bass", "Other", "Vocals"]
    let stems = names.map { SplitIntoStems.Stem(name: $0, file: AudioFileReference(fileName: "\($0).wav", sampleRate: 44_100, channelCount: 2, frameCount: 44_100)) }
    return (stems, names.map { Track(name: $0, kind: .audio) })
  }

  @Test func stemsGoInAFolderBelowTheTrackWithTheOriginalMuted() throws {
    let file = AudioFileReference(fileName: "Song.wav", sampleRate: 44_100, channelCount: 2, frameCount: 441_000)
    let region = Region(name: "Song", start: Tick(3840), length: Tick(7680), content: .audio(AudioRegionContent(fileID: file.id)))
    var project = Project(tracks: [Track(name: "Mix", kind: .audio, regions: [region]), Track(name: "After", kind: .audio)], audioFiles: [file])
    let (stems, tracks) = stems()
    let folder = Track(name: "Song Stems", kind: .aux)
    try SplitIntoStems(region.id, stems: stems, into: tracks, stack: folder).apply(to: &project)
    #expect(project.tracks.map(\.name) == ["Mix", "Song Stems", "Drums", "Bass", "Other", "Vocals", "After"])
    #expect(project.tracks[1].isFolderStack)
    #expect(project.tracks[2...5].allSatisfy { $0.stackID == folder.id })
    #expect(project.tracks[2].regions.first?.start == Tick(3840) && project.tracks[2].regions.first?.length == Tick(7680))
    #expect(project.tracks[5].regions.first?.name == "Song – Vocals")
    #expect(project.tracks[0].regions[0].isMuted)
    #expect(project.audioFiles.count == 5)
  }

  @Test func inAStackTheStemsJoinIt() throws {
    let file = AudioFileReference(fileName: "Song.wav", sampleRate: 44_100, channelCount: 2, frameCount: 441_000)
    let region = Region(name: "Song", start: .zero, length: Tick(3840), content: .audio(AudioRegionContent(fileID: file.id)))
    var stack = Track(name: "Band", kind: .aux)
    stack.isSummingStack = true
    var mix = Track(name: "Mix", kind: .audio, regions: [region])
    mix.stackID = stack.id
    mix.channel.output = .track(stack.id)
    var project = Project(tracks: [stack, mix], audioFiles: [file])
    let (stems, tracks) = stems()
    try SplitIntoStems(region.id, stems: stems, into: tracks, stack: Track(name: "x", kind: .aux), mutesOriginal: false).apply(to: &project)
    #expect(project.tracks.count == 6)
    #expect(project.tracks[2...].allSatisfy { $0.stackID == stack.id && $0.channel.output == .track(stack.id) })
    #expect(!project.tracks[1].regions[0].isMuted)
  }
}
