//
//  DAWProjectWindowTests.swift
//  OngakuTests
//

import AVFAudio
import Foundation
import OngakuCore
@testable import Ongaku
import Testing

/// Opening a DAWproject in a window: its audio copied into the song, regions pointing at the
/// copies, and a report of what didn't carry over.
@MainActor
struct DAWProjectWindowTests {
  /// Half a second of a 440 Hz tone, as a WAV file's bytes.
  private func wav() throws -> Data {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
    buffer.frameLength = 24_000
    for frame in 0..<24_000 { buffer.floatChannelData![0][frame] = Float(0.4 * sin(2 * .pi * 440 * Double(frame) / 48_000)) }
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
    try file.write(from: buffer)
    // Finished (its header written) before it's read.
    file.close()
    return try Data(contentsOf: url)
  }

  @Test func anImportedProjectBringsItsAudioIntoTheSong() async throws {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <Project version="1.0">
        <Transport><Tempo unit="bpm" value="100.0"/></Transport>
        <Structure>
          <Track contentType="audio" id="a" name="Guitar"><Channel role="regular" id="ac"/></Track>
          <Track contentType="notes" id="n" name="Synth"><Channel role="regular" id="nc">
            <Devices><ClapPlugin name="Surge XT" deviceRole="instrument"/></Devices></Channel></Track>
        </Structure>
        <Arrangement><Lanes timeUnit="beats">
          <Lanes track="a"><Clips><Clip time="2.0" duration="1.0" contentTimeUnit="seconds" playStart="0.0">
            <Audio sampleRate="48000" channels="1" duration="0.5"><File path="audio/guitar.wav"/></Audio></Clip></Clips></Lanes>
        </Lanes></Arrangement>
      </Project>
      """
    let imported = try DAWProject.read([
      ZipArchive.Entry(path: "project.xml", data: Data(xml.utf8)), ZipArchive.Entry(path: "audio/guitar.wav", data: try wav()),
    ])
    let window = ProjectWindowModel(document: OngakuDocument(project: Project()))
    await window.loadImported(imported, named: "Jam.dawproject")

    let project = window.project
    #expect(project.tracks.map(\.name) == ["Guitar", "Synth"])
    #expect(project.tempoMap.tempoChanges.first?.bpm == 100)
    let file = try #require(project.audioFiles.first)
    #expect(file.frameCount == 24_000 && file.sampleRate == 48_000, "The copy's own format, read from the file")
    guard case .audio(let content) = project.tracks[0].regions.first?.content else {
      Issue.record("The guitar region")
      return
    }
    #expect(content.fileID == file.id)
    #expect(window.document.url(for: file).map { FileManager.default.fileExists(atPath: $0.path) } == true)
    let report = try #require(window.interchangeReport)
    #expect(report.title == "Opened “Jam.dawproject”")
    #expect(report.message.contains("Surge XT"))
  }
}
