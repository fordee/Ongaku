//
//  ProjectWindowModel+Flex.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// Flex Time in the window: rendering flexed regions in the background, and the edits made
/// on regions with Flex on (markers, quantize).
extension ProjectWindowModel {
  /// The project as it plays: flexed regions play their renders once they're ready.
  var playedProject: Project {
    project.playingFlexRenders(flexRenders)
  }

  /// Starts rendering every flexed region that isn't rendered yet. When a render finishes,
  /// playback switches to it.
  func refreshFlexRenders() {
    let project = project
    for track in project.tracks where track.kind == .audio {
      for region in track.regions {
        guard let key = project.flexRenderKey(for: region, on: track), flexRenders[key] == nil, flexRenderTasks[key] == nil,
          let source = project.audioFile(withID: key.fileID).flatMap(document.url(for:))
        else { continue }
        let document = document
        flexRenderTasks[key] = Task { [weak self] in
          do {
            let destination = try document.newFlexRenderURL()
            let render = try await FlexAudio.render(key, source: source, to: destination)
            guard let self else { return }
            document.adoptFlexRender(render, at: destination)
            self.flexRenders[key] = render
            self.flexRenderTasks[key] = nil
            self.updateFlexProcessing()
            self.engine.update(project: self.playedProject)
          } catch {
            self?.flexRenderTasks[key] = nil
            self?.updateFlexProcessing()
            self?.errorMessage = "“\(region.name)” couldn’t be flexed: \(error.localizedDescription)"
          }
        }
      }
    }
    updateFlexProcessing()
  }

  /// Notes which regions' renders are still being made, for their "Processing" labels.
  private func updateFlexProcessing() {
    var regionIDs: Set<Region.ID> = []
    if !flexRenderTasks.isEmpty {
      let project = project
      for track in project.tracks where track.kind == .audio {
        for region in track.regions {
          if let key = project.flexRenderKey(for: region, on: track), flexRenderTasks[key] != nil { regionIDs.insert(region.id) }
        }
      }
    }
    if regionIDs != flexProcessingRegionIDs { flexProcessingRegionIDs = regionIDs }
  }

  /// Waits for the renders still being made, so a bounce or a freeze plays every flex edit
  /// rather than the audio as recorded.
  func finishFlexRenders() async {
    refreshFlexRenders()
    var waited: Set<Project.FlexRenderKey> = []
    while let (key, task) = flexRenderTasks.first(where: { !waited.contains($0.key) }) {
      waited.insert(key)
      await task.value
    }
  }

  func setFlexMode(_ mode: FlexMode?, for trackID: Track.ID) {
    perform(SetFlexMode(mode, for: trackID))
  }

  /// Moves Flex markers of a region by `strength`, to the nearest lines of `grid`: Logic's
  /// audio quantize. Finds the region's transients first (in the background).
  func quantizeFlex(_ regionID: Region.ID, grid: Tick, strength: Double = 1) {
    guard let region = project.region(withID: regionID), case .audio(let audio) = region.content,
      let file = project.audioFile(withID: audio.fileID), let url = document.url(for: file)
    else { return }
    let frames = Int64((project.duration(of: region) * file.sampleRate).rounded())
    Task {
      do {
        let transients = try await FlexAudio.transients(in: url, from: audio.fileStartFrame, frames: frames)
        guard let current = project.region(withID: regionID) else { return }
        let markers = project.quantizedFlexMarkers(for: current, transients: transients, grid: grid, strength: strength)
        guard !markers.isEmpty else {
          errorMessage = "No hits were found in “\(region.name)” to quantize."
          return
        }
        perform(SetFlexMarkers(markers, in: regionID, actionName: "Quantize Audio"))
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  /// The selected audio regions whose audio matches `predicate`.
  func selectedRegionIDs(where predicate: (AudioRegionContent) -> Bool) -> Set<Region.ID> {
    Set(project.tracks.flatMap(\.regions).filter { region in
      guard selectedRegionIDs.contains(region.id), case .audio(let audio) = region.content else { return false }
      return predicate(audio)
    }.map(\.id))
  }

  /// Removes the flex markers of several regions, as one step (with Flex off too).
  func clearFlexMarkers(in regionIDs: Set<Region.ID>) {
    perform(CompositeCommand("Remove Flex Markers", commands: regionIDs.map { SetFlexMarkers([], in: $0) }))
  }

  /// Puts the retuned notes of several regions back, as one step.
  func resetPitchEdits(in regionIDs: Set<Region.ID>) {
    perform(CompositeCommand("Reset Retuned Notes", commands: regionIDs.map { SetPitchEdits([], in: $0) }))
  }

  /// Seconds into a region at a position on the timeline.
  func regionSeconds(_ region: Region, at position: Tick) -> Double {
    project.tempoMap.seconds(at: position) - project.tempoMap.seconds(at: region.start)
  }

  /// The timeline position `seconds` into a region.
  func position(in region: Region, atSeconds seconds: Double) -> Tick {
    project.tempoMap.tickPosition(atSeconds: project.tempoMap.seconds(at: region.start) + seconds)
  }

  /// The flex marker a click at `position` grabs, if one is within `tolerance`.
  func flexMarker(in region: Region, near position: Tick, tolerance: Tick) -> FlexMarker? {
    guard case .audio(let audio) = region.content else { return nil }
    return audio.flexMarkers.first { marker in
      let markerPosition = self.position(in: region, atSeconds: marker.target)
      return abs((markerPosition - position).rawValue) <= tolerance.rawValue
    }
  }

  /// Ends a flex drag: `marker` (new or moved) now plays at `position`.
  func finishFlexDrag(_ marker: FlexMarker, in regionID: Region.ID, to position: Tick) {
    guard let region = project.region(withID: regionID), case .audio(let audio) = region.content else { return }
    var moved = marker
    moved.target = regionSeconds(region, at: snap(position))
    var markers = audio.flexMarkers.filter { $0.id != marker.id }
    markers.append(moved)
    let isNew = !audio.flexMarkers.contains { $0.id == marker.id }
    perform(SetFlexMarkers(markers, in: regionID, actionName: isNew ? "Add Flex Marker" : "Move Flex Marker"))
  }

  func deleteFlexMarker(_ markerID: FlexMarker.ID, in regionID: Region.ID) {
    guard let region = project.region(withID: regionID), case .audio(let audio) = region.content else { return }
    perform(SetFlexMarkers(audio.flexMarkers.filter { $0.id != markerID }, in: regionID, actionName: "Delete Flex Marker"))
  }
}

/// The stretch of an audio file a region plays, which Flex Pitch analyses once.
struct DetectedNotesKey: Hashable {
  var fileID: AudioFileReference.ID
  var fileStartFrame: Int64
  var frameCount: Int64
}

extension ProjectWindowModel {
  func detectedNotesKey(for region: Region) -> DetectedNotesKey? {
    guard case .audio(let audio) = region.content, let file = project.audioFile(withID: audio.fileID) else { return nil }
    let frames = Int64((project.duration(of: region) * file.sampleRate).rounded())
    return DetectedNotesKey(fileID: audio.fileID, fileStartFrame: audio.fileStartFrame, frameCount: frames)
  }

  /// The notes Flex Pitch found in a region, or `nil` while they're being found (this
  /// starts finding them).
  func detectedNotes(in region: Region) -> [DetectedNote]? {
    guard let key = detectedNotesKey(for: region) else { return [] }
    if let notes = detectedNotes[key] { return notes }
    if noteDetectionTasks[key] == nil, let file = project.audioFile(withID: key.fileID), let url = document.url(for: file) {
      noteDetectionTasks[key] = Task { [weak self] in
        let notes = (try? await FlexAudio.notes(in: url, from: key.fileStartFrame, frames: key.frameCount)) ?? []
        self?.detectedNotes[key] = notes
        self?.noteDetectionTasks[key] = nil
      }
    }
    return nil
  }

  /// The edit retuning a detected note, if it's been moved.
  func pitchEdit(for note: DetectedNote, in region: Region) -> PitchEdit? {
    guard case .audio(let audio) = region.content else { return nil }
    return audio.pitchEdits.first { abs($0.start - note.start) < 0.02 && abs($0.end - note.end) < 0.02 }
  }

  /// Moves a detected note to sound `semitones` from where it was sung (0 resets it).
  func retune(_ note: DetectedNote, in regionID: Region.ID, by semitones: Double) {
    guard let region = project.region(withID: regionID), case .audio(let audio) = region.content else { return }
    let existing = pitchEdit(for: note, in: region)
    var edits = audio.pitchEdits.filter { $0.id != existing?.id }
    if abs(semitones) > 0.001 {
      edits.append(PitchEdit(id: existing?.id ?? UUID(), start: note.start, end: note.end, semitones: semitones))
    }
    perform(SetPitchEdits(edits, in: regionID, actionName: abs(semitones) > 0.001 ? "Retune Note" : "Reset Note"))
  }

  /// Logic's Pitch Correction at 100 %: every detected note moved to the nearest semitone.
  func correctPitch(of regionID: Region.ID) {
    guard let region = project.region(withID: regionID), let notes = detectedNotes(in: region) else {
      errorMessage = "Ongaku Studio is still finding the notes. Try again in a moment."
      return
    }
    let edits = notes.compactMap { note -> PitchEdit? in
      let correction = note.pitch.rounded() - note.pitch
      guard abs(correction) > 0.02 else { return nil }
      return PitchEdit(start: note.start, end: note.end, semitones: correction)
    }
    perform(SetPitchEdits(edits, in: regionID, actionName: "Correct Pitch"))
  }
}

// MARK: - Smart Tempo

extension ProjectWindowModel {
  /// Finds a region's tempo in the background (the audio as recorded, so a stretched
  /// region's original tempo).
  func detectTempo(of regionID: Region.ID) {
    guard let region = project.region(withID: regionID), case .audio(let audio) = region.content,
      let file = project.audioFile(withID: audio.fileID), let url = document.url(for: file),
      !tempoDetectionRegionIDs.contains(regionID)
    else { return }
    let frames = Int64((project.duration(of: region) * audio.stretch * file.sampleRate).rounded())
    tempoDetectionRegionIDs.insert(regionID)
    Task {
      defer { tempoDetectionRegionIDs.remove(regionID) }
      do {
        if let tempo = try await FlexAudio.tempo(in: url, from: audio.fileStartFrame, frames: frames) {
          detectedTempos[regionID] = tempo
        } else {
          errorMessage = "“\(region.name)” doesn’t have a steady enough beat to find its tempo."
        }
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  func adaptProjectTempo(to regionID: Region.ID) {
    guard let tempo = detectedTempos[regionID] else { return }
    perform(AdaptProjectTempo(to: tempo, of: regionID))
  }

  func matchProjectTempo(_ regionID: Region.ID) {
    guard let tempo = detectedTempos[regionID] else { return }
    perform(MatchProjectTempo(regionID, from: tempo))
  }
}
