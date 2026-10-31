//
//  ProjectWindowModel+Instruments.swift
//  Ongaku
//

import AppKit
import AudioToolbox
import CoreAudioKit
import OngakuCore
import OngakuEngine
import SwiftUI

/// Instrument tracks: choosing instruments, plug-in windows, MIDI regions and the editor.
extension ProjectWindowModel {
  // MARK: - Instruments

  func setInstrument(_ source: InstrumentSource, for trackID: Track.ID) {
    guard let track = project.track(withID: trackID) else { return }
    if case .audioUnit(let old) = track.channel.instrument {
      pluginWindows[old.id]?.close()
    }
    var channel = track.channel
    channel.instrument = source
    perform(SetChannelStrip(trackID, to: channel, actionName: "Change Instrument"))
  }

  /// Opens the interface of a track's Audio Unit instrument in its own window.
  func showInstrumentWindow(for trackID: Track.ID) {
    guard let track = project.track(withID: trackID), case .audioUnit(let plugin) = track.channel.instrument else { return }
    guard !track.isFrozen else {
      errorMessage = EditError.invalidValue("“\(track.name)” is frozen. Unfreeze it to change its instrument.").localizedDescription
      return
    }
    guard !engine.isLoadingInstrument(forTrack: trackID) else {
      errorMessage = "“\(plugin.name)” is still loading."
      return
    }
    showPluginWindow(for: plugin, channelID: trackID, channelName: track.name) { body in
      engine.withInstrumentAudioUnit(forTrack: trackID, body)
    }
  }

  /// Opens the interface of an insert plug-in in its own window. `trackID` may be
  /// `Project.stereoOutID`, for a plug-in on Stereo Out.
  func showInsertWindow(_ pluginID: PluginReference.ID, on trackID: Track.ID) {
    guard let plugin = (try? project.inserts(of: trackID))?.first(where: { $0.id == pluginID }) else { return }
    let track = project.track(withID: trackID)
    if let track, track.isFrozen, track.freezesInserts {
      errorMessage = EditError.invalidValue("“\(track.name)” is frozen. Unfreeze it to change its plug-ins.").localizedDescription
      return
    }
    guard !engine.isLoadingInsert(pluginID, onTrack: trackID) else {
      errorMessage = "“\(plugin.name)” is still loading."
      return
    }
    showPluginWindow(for: plugin, channelID: trackID, channelName: track?.name ?? "Stereo Out") { body in
      engine.withInsertAudioUnit(pluginID, onTrack: trackID, body)
    }
  }

  /// Asks the plug-in for its view and shows it, or brings an open window to the front.
  /// `withAudioUnit` gives scoped access to the loaded plug-in.
  private func showPluginWindow(
    for plugin: PluginReference, channelID trackID: Track.ID, channelName: String,
    withAudioUnit: ((borrowing AUAudioUnit) -> Void) -> Void?
  ) {
    if let existing = pluginWindows[plugin.id] {
      existing.show()
      return
    }
    let title = "\(channelName) — \(plugin.name)"
    let requested: Void? = withAudioUnit { audioUnit in
      audioUnit.requestViewController { [weak self] viewController in
        DispatchQueue.main.async {
          self?.presentPluginWindow(
            viewController, title: title, size: OngakuEffect(plugin)?.windowSize ?? OngakuInstrument(plugin)?.windowSize,
            pluginID: plugin.id, trackID: trackID, isMastering: OngakuEffect(plugin) == .mastering)
        }
      }
    }
    if requested == nil {
      errorMessage = "“\(plugin.name)” isn’t loaded."
    }
  }

  private func presentPluginWindow(
    _ viewController: NSViewController?, title: String, size: CGSize?, pluginID: PluginReference.ID, trackID: Track.ID,
    isMastering: Bool
  ) {
    guard let viewController else {
      errorMessage = "This plug-in doesn’t have its own interface."
      return
    }
    // Mastering on Stereo Out can listen to the whole song offline, which only the host can do.
    let accessory = isMastering && trackID == Project.stereoOutID ? AnalyzeSongButton(model: self).accessory() : nil
    let controller = PluginWindowController(
      title: title, contentViewController: viewController, size: size, trackID: trackID, accessory: accessory
    ) { [weak self] in
      self?.pluginWindowDidClose(pluginID: pluginID, trackID: trackID)
    }
    pluginWindows[pluginID] = controller
    controller.show()
  }

  /// Stores the plug-in's settings in the project when its window closes, so they are
  /// saved with the song (and the change can be undone).
  private func pluginWindowDidClose(pluginID: PluginReference.ID, trackID: Track.ID) {
    pluginWindows[pluginID] = nil
    guard let change = changedPluginState(pluginID: pluginID, trackID: trackID) else { return }
    perform(change)
  }

  /// The settings of every plug-in whose window is open, where they've changed, for saving:
  /// they only reach the project when the window closes.
  func openPluginStates() -> [SetPluginState] {
    pluginWindows.compactMap { pluginID, window in
      changedPluginState(pluginID: pluginID, trackID: window.trackID)
    }
  }

  /// A plug-in's current settings, if they differ from what the project has.
  private func changedPluginState(pluginID: PluginReference.ID, trackID: Track.ID) -> SetPluginState? {
    let current: PluginReference?
    let state: Data?
    if trackID == Project.stereoOutID {
      current = project.stereoOutInserts.first { $0.id == pluginID }
      state = engine.insertState(pluginID, onTrack: trackID)
    } else if let track = project.track(withID: trackID), case .audioUnit(let instrument) = track.channel.instrument,
      instrument.id == pluginID
    {
      current = instrument
      state = engine.instrumentState(forTrack: trackID)
    } else {
      current = project.track(withID: trackID)?.channel.inserts.first { $0.id == pluginID }
      state = engine.insertState(pluginID, onTrack: trackID)
    }
    guard let current, let state, state != current.state else { return nil }
    return SetPluginState(state, forPlugin: pluginID, on: trackID)
  }

  /// The instrument tracks MIDI keyboards play: every record-enabled one, layered as in
  /// Logic (they all record what's played, so all are heard), or else the selected track if
  /// it's an instrument track.
  var liveMIDITrackIDs: [Track.ID] {
    let armed = project.tracks.filter { $0.kind == .softwareInstrument && $0.isRecordArmed }.map(\.id)
    if !armed.isEmpty { return armed }
    return selectedTrack.flatMap { $0.kind == .softwareInstrument ? [$0.id] : nil } ?? []
  }

  /// Sends MIDI keyboards to `liveMIDITrackIDs`. Called when the window becomes frontmost
  /// and when those tracks change.
  func connectMIDIInput() {
    engine.connectMIDIInput(toTracks: liveMIDITrackIDs)
  }

  // MARK: - MIDI regions and the editor

  /// Creates an empty one-bar MIDI region at the bar containing `position` and opens it in
  /// the piano roll.
  func createMIDIRegion(on trackID: Track.ID, at position: Tick) {
    guard let track = project.track(withID: trackID), track.kind == .softwareInstrument else { return }
    let tempoMap = project.tempoMap
    let bar = tempoMap.bar(containing: max(.zero, position))
    let end = tempoMap.tickPosition(ofBarIndex: bar.index + 1)
    let region = Region(name: track.name, start: bar.start, length: end - bar.start, content: .midi(MIDISequence()))
    perform(AddRegion(region, to: trackID))
    selectedTrackID = trackID
    selectedRegionIDs = [region.id]
    openEditor(for: region.id)
  }

  /// Opens a MIDI region, a take folder (audio or MIDI), or an audio region on a Flex Pitch
  /// track, in the editor pane.
  func openEditor(for regionID: Region.ID) {
    guard let region = project.region(withID: regionID), opensInEditor(region) else { return }
    editorRegionID = regionID
    showTakesFirst(for: region)
    bottomPane = .pianoRoll
  }

  /// Whether a region has an editor: MIDI, take folders, and audio on a Flex Pitch track.
  private func opensInEditor(_ region: Region) -> Bool {
    if case .midi = region.content { return true }
    return region.takeFolder != nil || project.tracks.first { $0.regions.contains { $0.id == region.id } }?.flexMode == .pitch
  }

  /// Take folders open in the Takes editor, so a MIDI one isn't edited in the Piano Roll
  /// without seeing which take that changes.
  private func showTakesFirst(for region: Region) {
    if region.takeFolder != nil { pianoRoll.editorKind = .takes }
  }

  /// Shows or hides the editor, opening the selected region if it has one (see
  /// `opensInEditor`), as double-clicking it does.
  func toggleEditor() {
    // Audio take folders open in the Takes editor, audio on a Flex Pitch track in Flex Pitch.
    if !isEditorVisible, let selected = selectedRegionIDs.first(where: { id in
      project.region(withID: id).map(opensInEditor) ?? false
    }) {
      editorRegionID = selected
      if let region = project.region(withID: selected) { showTakesFirst(for: region) }
    }
    bottomPane = isEditorVisible ? nil : .pianoRoll
  }

  /// Shows or hides the mixer, like Logic's X key.
  func toggleMixer() {
    bottomPane = bottomPane == .mixer ? nil : .mixer
  }

  func toggleLibrary() {
    isLibraryVisible.toggle()
  }

  func toggleInspector() {
    isInspectorVisible.toggle()
  }

  var selectedTrack: Track? {
    selectedTrackID.flatMap(project.track(withID:))
  }
}

/// A window showing an Audio Unit's own interface.
@MainActor
final class PluginWindowController: NSObject, NSWindowDelegate {
  private let window: NSWindow
  private let onClose: () -> Void
  /// The track whose plug-in this is.
  let trackID: Track.ID
  private var sizeObservation: NSKeyValueObservation?

  /// `size` is the content size to use, for plug-ins whose size is known ahead (Ongaku's
  /// own effects); others are sized as their interface asks.
  init(
    title: String, contentViewController: NSViewController, size: CGSize? = nil, trackID: Track.ID,
    accessory: NSTitlebarAccessoryViewController? = nil, onClose: @escaping () -> Void
  ) {
    self.trackID = trackID
    window = NSWindow(contentViewController: contentViewController)
    window.title = title
    window.styleMask.remove(.resizable)
    window.isReleasedWhenClosed = false
    self.onClose = onClose
    super.init()
    window.delegate = self
    if let accessory {
      window.addTitlebarAccessoryViewController(accessory)
    }
    // Plug-ins say how big they'd like to be, and an Audio Unit extension's interface (in
    // another process) often only says so once it has loaded, so follow it.
    if let size {
      resize(to: size)
      return
    }
    resize(to: contentViewController.preferredContentSize)
    sizeObservation = contentViewController.observe(\.preferredContentSize, options: [.new]) { [weak self] controller, _ in
      let size = controller.preferredContentSize
      DispatchQueue.main.async { self?.resize(to: size) }
    }
  }

  private func resize(to size: NSSize) {
    guard size.width > 0, size.height > 0, window.contentLayoutRect.size != size else { return }
    window.setContentSize(size)
  }

  func show() {
    window.makeKeyAndOrderFront(nil)
  }

  func close() {
    window.close()
  }

  func windowWillClose(_ notification: Notification) {
    onClose()
  }
}

/// Analyze Whole Song, in Mastering's title bar.
private struct AnalyzeSongButton: View {
  let model: ProjectWindowModel

  var body: some View {
    Button("Analyze Whole Song") { model.analyzeSongForMastering() }
      .controlSize(.small)
      .disabled(model.songAnalysis != nil)
      .help("Mastering listens to the whole song, faster than it plays, instead of while you play it, then sets itself up for it")
      .padding(.horizontal, 10)
  }

  func accessory() -> NSTitlebarAccessoryViewController {
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = NSHostingView(rootView: self)
    accessory.view.frame.size = accessory.view.fittingSize
    accessory.layoutAttribute = .trailing
    return accessory
  }
}
