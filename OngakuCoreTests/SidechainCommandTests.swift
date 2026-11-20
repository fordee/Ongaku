//
//  SidechainCommandTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Choosing which track feeds a plug-in's side chain.
struct SidechainCommandTests {
  @Test func aSideChainIsSetClearedAndNeverLoops() throws {
    let compressor = PluginReference(componentType: 0x6175_6678, componentSubType: 1, componentManufacturer: 2, name: "Compressor")
    var bass = Track(name: "Bass", kind: .audio)
    bass.channel.inserts = [compressor]
    let kick = Track(name: "Kick", kind: .audio)
    var reverb = Track(name: "Reverb", kind: .aux)
    reverb.channel.inserts = [compressor]
    reverb.channel.inserts[0].id = UUID()
    var project = Project(tracks: [bass, kick, reverb])

    try SetSidechain(kick.id, forPlugin: compressor.id, on: bass.id).apply(to: &project)
    #expect(project.tracks[0].channel.inserts[0].sidechainSourceID == kick.id)
    #expect(project.sidechains(from: kick.id) == [compressor.id])

    // The bass sends to the reverb, so the reverb can't drive the bass's compressor…
    project.tracks[0].channel.sends = [Send(destinationTrackID: reverb.id)]
    #expect(throws: EditError.self) { try SetSidechain(reverb.id, forPlugin: compressor.id, on: bass.id).apply(to: &project) }
    // …nor itself.
    #expect(throws: EditError.self) { try SetSidechain(bass.id, forPlugin: compressor.id, on: bass.id).apply(to: &project) }
    // And with the bass driving the reverb's compressor, the reverb can't send back to the bass.
    let reverbCompressor = project.tracks[2].channel.inserts[0].id
    try SetSidechain(bass.id, forPlugin: reverbCompressor, on: reverb.id).apply(to: &project)
    project.tracks[0].channel.sends = []
    #expect(project.sendWouldCreateFeedback(from: reverb.id, to: bass.id))

    try SetSidechain(nil, forPlugin: compressor.id, on: bass.id).apply(to: &project)
    #expect(project.tracks[0].channel.inserts[0].sidechainSourceID == nil)
  }
}
