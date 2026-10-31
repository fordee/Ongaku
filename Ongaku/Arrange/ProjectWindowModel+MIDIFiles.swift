//
//  ProjectWindowModel+MIDIFiles.swift
//  Ongaku
//

import CoreTransferable
import Foundation
import OngakuCore
import UniformTypeIdentifiers

/// Importing and exporting Standard MIDI Files.
extension ProjectWindowModel {
  /// Adds the tracks from MIDI files. Into a project with no regions yet, the file's tempo
  /// and meter are used and its timing is kept; otherwise the file starts at the bar
  /// containing `position`.
  func importMIDIFiles(_ urls: [URL], at position: Tick) async {
    var commands: [any EditCommand] = []
    var useFileTempo = project.hasNoRegions
    for url in urls {
      let isAccessing = url.startAccessingSecurityScopedResource()
      defer {
        if isAccessing { url.stopAccessingSecurityScopedResource() }
      }
      do {
        let contents = try await Task.detached { try StandardMIDIFile.read(Data(contentsOf: url)) }.value
        guard !contents.tracks.isEmpty else {
          errorMessage = "“\(url.lastPathComponent)” doesn’t contain any notes."
          continue
        }
        var tracks = Self.colorImportedTracks(
          contents.tracks, AppSettings.importedMIDITrackColors,
          instrumentColor: AppSettings.newTrackColor(for: .softwareInstrument))
        for index in tracks.indices {
          tracks[index].automationMode = AppSettings.newTrackAutomationMode
        }
        if !useFileTempo {
          let offset = project.tempoMap.bar(containing: position).start
          for trackIndex in tracks.indices {
            for regionIndex in tracks[trackIndex].regions.indices {
              tracks[trackIndex].regions[regionIndex].start += offset
            }
          }
        }
        // A file that says its key sets the song's, as its tempo does, into an empty project.
        let keys = useFileTempo && (contents.keySignature != nil || !contents.keyChanges.isEmpty)
          ? (start: contents.keySignature ?? project.keySignature, changes: contents.keyChanges) : nil
        commands.append(ImportTracks(tracks, tempoMap: useFileTempo ? contents.tempoMap : nil, keys: keys))
        useFileTempo = false
      } catch {
        errorMessage = "“\(url.lastPathComponent)” couldn’t be imported: \(error.localizedDescription)"
      }
    }
    guard !commands.isEmpty else { return }
    perform(CompositeCommand("Import MIDI File", commands: commands))
  }

  /// Colours a MIDI file's tracks as the settings ask: all in the instrument track colour,
  /// or each in the next colour of the palette, starting again from the first for each file.
  static func colorImportedTracks(
    _ tracks: [Track], _ option: AppSettings.ImportedTrackColors, instrumentColor: TrackColor
  ) -> [Track] {
    let palette = TrackColor.importPalette
    return tracks.enumerated().map { index, track in
      var track = track
      track.color = option == .varied ? palette[index % palette.count] : instrumentColor
      return track
    }
  }

  func midiExport() -> MIDIFileExport {
    MIDIFileExport(data: StandardMIDIFile.write(project))
  }

  /// The document's name, for naming exported files.
  var exportFileName: String {
    document.displayName ?? "Untitled"
  }
}

/// A Standard MIDI File for the export panel.
struct MIDIFileExport: Transferable {
  var data: Data

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .midi) { $0.data }
  }
}
