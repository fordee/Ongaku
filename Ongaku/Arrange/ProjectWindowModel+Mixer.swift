//
//  ProjectWindowModel+Mixer.swift
//  Ongaku
//

import Foundation
import OngakuCore
import OngakuEngine

/// Mixer and recording actions shared by channel strips, track headers, menus and keys.
extension ProjectWindowModel {
  // MARK: - Recording

  /// Points the engine's recordings at the document and adds finished takes to the project.
  func configureRecording() {
    engine.recordingDirectory = document.stagingDirectory
    engine.onRecordingFinished = { [weak self] result in
      self?.addRecording(result)
    }
  }

  /// Starts recording from the playhead, or stops if already recording.
  func toggleRecording() {
    if engine.isRecording {
      engine.stop()
    } else {
      Task { await engine.record() }
    }
  }

  func setRecordArmed(_ trackID: Track.ID, _ isArmed: Bool) {
    perform(SetRecordArmed(trackID, isArmed: isArmed))
    connectMIDIInput()
  }

  func setInputMonitoring(_ trackID: Track.ID, _ isMonitored: Bool) {
    perform(SetInputMonitoring(trackID, isMonitored: isMonitored))
  }

  /// Adds every take of a recording as one undoable step: new audio files and regions on
  /// the tracks they were recorded on.
  private func addRecording(_ result: RecordingResult) {
    var commands: [any EditCommand] = []
    var reservedNames: Set<String> = []
    for take in result.audio {
      guard let track = project.track(withID: take.trackID) else { continue }
      do {
        let file = try document.adoptRecordedAudio(
          at: take.fileURL, sampleRate: take.sampleRate, channelCount: take.channelCount,
          frameCount: take.frameCount, preferredName: track.name, reservedNames: reservedNames)
        reservedNames.insert(file.fileName)
        commands.append(AddAudioFile(file))
        if let passes = take.cyclePasses {
          commands.append(AddRegion(Self.takeFolder(of: file, passes: passes, name: track.name), to: track.id))
        } else {
          commands.append(AddRegion(Region.audio(for: file, at: take.start, tempoMap: project.tempoMap), to: track.id))
        }
      } catch {
        errorMessage = "The recording on “\(track.name)” couldn’t be added: \(error.localizedDescription)"
      }
    }
    for take in result.midi {
      commands.append(AddRegion(take.region, to: take.trackID))
    }
    guard !commands.isEmpty else { return }
    perform(CompositeCommand("Record", commands: commands))
  }

  /// A take folder over the cycle with a take per pass of one recorded file, the last
  /// playing (as in Logic).
  private static func takeFolder(of file: AudioFileReference, passes: (cycle: Range<Tick>, startFrames: [Int64]), name: String) -> Region {
    let takes = passes.startFrames.enumerated().map { index, frame in
      Take(name: "Take \(index + 1)", content: .audio(AudioRegionContent(fileID: file.id, fileStartFrame: frame)))
    }
    let length = passes.cycle.upperBound - passes.cycle.lowerBound
    let last = takes[takes.count - 1]
    return Region(
      name: name, start: passes.cycle.lowerBound, length: length, content: last.content,
      takeFolder: TakeFolder(takes: takes, playing: last.id, length: length))
  }

  // MARK: - Channel strips

  /// Changes a channel strip, and the rest of its mixer group for what the group links.
  func setChannel(_ trackID: Track.ID, actionName: String, _ change: (inout ChannelStrip) -> Void) {
    guard let track = project.track(withID: trackID) else { return }
    var channel = track.channel
    change(&channel)
    guard channel != track.channel else { return }
    perform(SetGroupedChannelStrip(trackID, to: channel, actionName: actionName))
  }

  // MARK: - Mixer groups

  /// Groups the selected tracks (and `trackID`) in a new group, as Logic's Group slot does.
  func createGroup(with trackID: Track.ID) {
    guard let number = project.nextGroupNumber else {
      errorMessage = "All \(MixerGroup.numbers.upperBound) groups are in use."
      return
    }
    let trackIDs = selectedTrackIDs.contains(trackID) ? selectedTrackIDs : [trackID]
    perform(CreateMixerGroup(MixerGroup(id: number), with: trackIDs))
  }

  func assignGroup(_ groupID: Int?, to trackID: Track.ID) {
    perform(SetTrackGroup(groupID, for: [trackID]))
  }

  func updateGroup(_ groupID: Int, actionName: String = "Change Group", _ change: (inout MixerGroup) -> Void) {
    guard var group = project.mixerGroup(withID: groupID) else { return }
    change(&group)
    guard group != project.mixerGroup(withID: groupID) else { return }
    perform(UpdateMixerGroup(group, actionName: actionName))
  }

  /// Renames a group (an empty name keeps the old one).
  func renameGroup(_ groupID: Int, to name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    updateGroup(groupID, actionName: "Rename Group") { $0.name = name }
  }

  /// While a grouped fader or pan control is dragged, the other members move with it.
  /// Returns where each of them went, so automation can be written for them too.
  @discardableResult
  func moveGroupLive(_ parameter: AutomationParameter, of trackID: Track.ID, to value: Double) -> [(track: Track, value: Double)] {
    guard let track = project.track(withID: trackID), let (group, partners) = project.groupPartners(of: trackID) else { return [] }
    let isLinked = switch parameter {
    case .volume: group.linksVolume
    case .pan: group.linksPan
    default: false
    }
    guard isLinked else { return [] }
    // Relative to what each control shows: while automation is being written that's the
    // last value written, for the partners as well as the control (or, for partners that
    // aren't writing, where the control last moved them).
    let delta = value - displayedValue(of: parameter, on: track)
    let write = automationWrite.flatMap { $0.trackID == trackID && $0.parameter == parameter ? $0 : nil }
    return partners.map { partner in
      let current = write?.heldPartnerValues[partner.id] ?? displayedValue(of: parameter, on: partner)
      let partnerValue = parameter.clamp(current + delta)
      engine.setLiveValue(parameter, partnerValue, onTrack: partner.id)
      return (partner, partnerValue)
    }
  }

  func addInsert(_ plugin: PluginReference, to trackID: Track.ID) {
    perform(AddInsert(plugin, to: trackID))
  }

  func removeInsert(_ pluginID: PluginReference.ID, from trackID: Track.ID) {
    pluginWindows[pluginID]?.close()
    perform(RemoveInsert(pluginID, from: trackID))
  }

  /// Installed third-party effects, looked up when the insert menu opens.
  var audioUnitEffects: [InstrumentLibrary.Entry] {
    InstrumentLibrary.audioUnitEffects()
  }

  /// The aux tracks a channel can send to: every aux except itself and any that would loop
  /// back to it.
  func sendDestinations(for trackID: Track.ID) -> [Track] {
    // Read once: the mixer asks this for every strip.
    let project = project
    let source = project.track(withID: trackID)
    // Not an aux it already sends to, nor the one it outputs to.
    var existing = Set(source?.channel.sends.map(\.destinationTrackID) ?? [])
    if let output = source?.channel.output.trackID { existing.insert(output) }
    return project.tracks.filter { track in
      track.kind == .aux && !existing.contains(track.id) && !project.sendWouldCreateFeedback(from: trackID, to: track.id)
    }
  }

  /// The auxes (and summing stacks) a track can output to: not itself, not an aux it sends
  /// to, and not one that would feed back into it.
  func outputDestinations(for trackID: Track.ID) -> [Track] {
    var project = project
    guard let index = project.trackIndex(for: trackID) else { return [] }
    let sends = Set(project.tracks[index].channel.sends.map(\.destinationTrackID))
    project.tracks[index].channel.output = .stereoOut
    return project.tracks.filter { track in
      track.kind == .aux && track.id != trackID && !sends.contains(track.id)
        && !project.outputWouldCreateFeedback(from: trackID, to: track.id)
    }
  }

  func setOutput(of trackID: Track.ID, to output: ChannelOutput) {
    guard project.track(withID: trackID)?.channel.output != output else { return }
    perform(SetTrackOutput(trackID, to: output))
  }

  func addSend(from trackID: Track.ID, to auxID: Track.ID) {
    perform(AddSend(Send(destinationTrackID: auxID), from: trackID))
  }

  /// Creates a new aux track and sends to it, as one undoable step.
  func sendToNewAux(from trackID: Track.ID) {
    let aux = makeTrack(name: project.nextTrackName(for: .aux), kind: .aux)
    perform(CompositeCommand("New Aux", commands: [
      AddTrack(aux), AddSend(Send(destinationTrackID: aux.id), from: trackID),
    ]))
  }
}
