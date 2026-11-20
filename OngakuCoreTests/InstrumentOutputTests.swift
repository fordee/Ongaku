//
//  InstrumentOutputTests.swift
//  OngakuCoreTests
//

import Foundation
@testable import OngakuCore
import Testing

/// Aux tracks for a multi-output instrument's other outputs.
struct InstrumentOutputTests {
  @Test func eachOutputGetsOneAuxTrackAfterTheInstrument() throws {
    let kit = Track(name: "Kit", kind: .softwareInstrument)
    let bass = Track(name: "Bass", kind: .audio)
    var project = Project(tracks: [kit, bass])
    try AddInstrumentOutputs(of: kit.id, outputNames: ["Snare", "Hats"]).apply(to: &project)
    #expect(project.tracks.map(\.name) == ["Kit", "Kit Snare", "Kit Hats", "Bass"])
    #expect(project.tracks[1].kind == .aux)
    #expect(project.tracks[2].channel.instrumentOutput == InstrumentOutput(trackID: kit.id, bus: 2))

    // Asking again adds only the outputs without one.
    project.tracks.remove(at: 1)
    try AddInstrumentOutputs(of: kit.id, outputNames: ["Snare", "Hats"]).apply(to: &project)
    #expect(project.tracks.map(\.name) == ["Kit", "Kit Hats", "Kit Snare", "Bass"])

    // Saved and read back.
    let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
    #expect(decoded.tracks[1].channel.instrumentOutput == project.tracks[1].channel.instrumentOutput)

    // Freezing would silence them.
    let file = AudioFileReference(fileName: "Freeze.caf", sampleRate: 48_000, channelCount: 2, frameCount: 1)
    #expect(throws: EditError.self) { try FreezeTrack(kit.id, file: file).apply(to: &project) }
    #expect(throws: EditError.self) { try AddInstrumentOutputs(of: bass.id, outputNames: ["Out 2"]).apply(to: &project) }
  }
}
