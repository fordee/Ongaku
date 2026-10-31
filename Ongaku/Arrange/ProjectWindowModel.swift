//
//  ProjectWindowModel.swift
//  Ongaku
//

import AVFAudio
import AppKit
import OngakuCore
import OngakuEngine
import SwiftUI
import UniformTypeIdentifiers

/// Window-level state for one open project: the playback engine, selection, zoom and the
/// actions that menus, the control bar and the tracks area share.
@MainActor
@Observable
final class ProjectWindowModel {
  enum Layout {
    /// The track headers' width: dragged by their right edge and remembered between launches.
    static let defaultHeaderWidth: CGFloat = 230
    static let headerWidthRange: ClosedRange<CGFloat> = 190...520
    static let rulerHeight: CGFloat = 34
    /// A track's lane, where its regions are.
    static let trackHeight: CGFloat = 64
    /// The strip under each track's lane where its automation is drawn and edited, while
    /// automation is shown.
    static let automationHeight: CGFloat = 56
    /// Empty space after the last track, for dropping files onto new tracks.
    static let trailingSpace: CGFloat = 160
  }

  /// The grid that drags and clicks snap to, chosen from the zoom level.
  enum Grid: Equatable {
    case bar
    /// The beat of the meter at that bar.
    case beat
    case division(Tick)
  }

  static let zoomRange: ClosedRange<Double> = 2...160

  private static let headerWidthKey = "TrackHeaderWidth"

  private static var savedHeaderWidth: CGFloat {
    let saved = UserDefaults.standard.double(forKey: headerWidthKey)
    guard saved > 0 else { return Layout.defaultHeaderWidth }
    return min(max(CGFloat(saved), Layout.headerWidthRange.lowerBound), Layout.headerWidthRange.upperBound)
  }

  let document: OngakuDocument
  let engine: PlaybackEngine
  let waveforms = WaveformCache()
  let scroll = ScrollState()

  /// While regions are being dragged: how far they would move, already snapped.
  struct RegionDragPreview: Equatable {
    var offset: Tick
    var trackOffset: Int
    /// Option is held: dropping copies them, so the originals stay drawn where they are.
    var isCopy = false
  }

  /// While a region's edge is being dragged: its new range, already snapped.
  struct RegionTrimPreview: Equatable {
    var regionID: Region.ID
    var start: Tick
    var end: Tick
  }

  var selectedRegionIDs: Set<Region.ID> = []
  /// The track clicked last: the Inspector shows it and new tracks go after it.
  var selectedTrackID: Track.ID? {
    didSet { selectedTrackIDs = selectedTrackID.map { [$0] } ?? [] }
  }
  /// Every selected track (Shift- or Command-click track headers to select more), which
  /// Create Summing Stack groups. Setting `selectedTrackID` selects just that track.
  var selectedTrackIDs: Set<Track.ID> = []
  /// Summing stacks shown folded up, their subtracks hidden.
  var collapsedStackIDs: Set<Track.ID> = []
  var regionDragPreview: RegionDragPreview?
  /// What clicking in the tracks area does (Logic's left-click tool).
  var tool = ArrangeTool.pointer
  /// The Tool menu, open after pressing T until the next key.
  var isShowingToolMenu = false
  /// While a fade is being dragged with the Fade tool.
  var fadePreview: FadePreview?
  /// Rendered flexed regions, and the renders still being made (see ProjectWindowModel+Flex).
  @ObservationIgnored var flexRenders: [Project.FlexRenderKey: AudioFileReference] = [:]
  @ObservationIgnored var flexRenderTasks: [Project.FlexRenderKey: Task<Void, Never>] = [:]
  /// The regions whose flex renders are still being made (they play as recorded until then).
  var flexProcessingRegionIDs: Set<Region.ID> = []
  /// Flex Pitch: the notes found in each stretch of audio, once analysed.
  var detectedNotes: [DetectedNotesKey: [DetectedNote]] = [:]
  @ObservationIgnored var noteDetectionTasks: [DetectedNotesKey: Task<Void, Never>] = [:]
  /// Smart Tempo: the tempo found in each region analysed, by region.
  var detectedTempos: [Region.ID: DetectedTempo] = [:]
  var tempoDetectionRegionIDs: Set<Region.ID> = []
  /// While a flex marker is dragged: the region's markers as they'd become.
  var flexPreview: (regionID: Region.ID, markers: [FlexMarker])?
  /// The Arrangement and Marker tracks under the ruler (G).
  var isGlobalTracksVisible = false
  /// The chord being typed on the Chord track (a new one, or one being changed).
  var chordEdit: ChordEdit?
  /// The bar whose time signature change is open in its popover on the Signature track.
  var signatureEditBarIndex: Int?
  /// Where the Signature track's key popover is open: a key change, or the song's start.
  var keyEditPosition: Tick?
  var selectedSectionID: ArrangementSection.ID?
  /// The marker or section being renamed.
  var renameTarget: RenameTarget?
  var regionTrimPreview: RegionTrimPreview?
  /// While a region's loop handle is dragged: where its loops would end.
  var loopPreview: LoopPreview?
  /// Horizontal zoom: points per quarter note.
  var pointsPerQuarterNote: Double = 24
  var errorMessage: String?
  /// While recording past the end of the song: how far the tracks area reaches.
  var canvasEndWhileRecording: Tick?
  /// The kinds of file the import panel can be showing.
  enum ImportKind {
    case audio, midi

    /// What the import panel lets the person choose.
    var allowedContentTypes: [UTType] {
      switch self {
      case .audio: [.audio]
      case .midi: [.midi]
      }
    }
  }

  /// Which import panel is showing, if any.
  var activeImporter: ImportKind? {
    didSet {
      if let activeImporter { importerKind = activeImporter }
    }
  }
  /// The kind of the most recent import panel. Kept after the panel closes: its binding
  /// clears `activeImporter` before the completion handler runs.
  private(set) var importerKind = ImportKind.audio
  var isShowingMIDIExporter = false
  /// The Bounce dialog, while it's open.
  var bounce: BounceModel?
  /// Mastering's Analyze Whole Song, while it runs.
  var songAnalysis: SongAnalysis?
  /// Tracks being frozen, with how far each render has got (0 to 1).
  var freezeProgress: [Track.ID: Double] = [:]
  @ObservationIgnored var freezeTasks: [Track.ID: Task<Void, Never>] = [:]
  /// The MIDI region open in the piano roll.
  var editorRegionID: Region.ID?

  /// What the area under the tracks shows, like Logic's editor and mixer buttons.
  enum BottomPane: String, CaseIterable {
    case pianoRoll, mixer

    /// The shortest the pane can be dragged: room for its header and a little of its
    /// contents (the mixer's strips scroll when they don't fit).
    var minimumHeight: CGFloat { 120 }
  }

  /// Heights the mixer and piano roll were dragged to, remembered between launches. A pane
  /// that was never resized opens at its default height (see `EditingArea`).
  var paneHeights: [BottomPane: CGFloat] = ProjectWindowModel.savedPaneHeights
  /// How tall the mixer must be to show its tallest strip whole, with full-size faders.
  /// Measured by the mixer itself.
  var mixerIdealHeight: CGFloat?

  private static func paneHeightKey(_ pane: BottomPane) -> String {
    "\(pane.rawValue.prefix(1).uppercased())\(pane.rawValue.dropFirst())PaneHeight"
  }

  private static var savedPaneHeights: [BottomPane: CGFloat] {
    var heights: [BottomPane: CGFloat] = [:]
    for pane in BottomPane.allCases {
      let saved = UserDefaults.standard.double(forKey: paneHeightKey(pane))
      if saved > 0 { heights[pane] = CGFloat(saved) }
    }
    return heights
  }

  /// Remembers a pane's height for the next launch, or forgets it (`nil`) so the pane goes
  /// back to its default height.
  func savePaneHeight(_ pane: BottomPane) {
    if let height = paneHeights[pane] {
      UserDefaults.standard.set(Double(height), forKey: Self.paneHeightKey(pane))
    } else {
      UserDefaults.standard.removeObject(forKey: Self.paneHeightKey(pane))
    }
  }

  var bottomPane: BottomPane?
  /// The Library down the left of the window (Y).
  var isLibraryVisible = false {
    didSet { if isLibraryVisible, !oldValue { refreshAudioUnitInstruments() } }
  }
  /// Automation curves drawn over the track lanes (A).
  var isAutomationVisible = false {
    didSet { scroll.rowHeight = rowHeight }
  }
  /// How far apart tracks are: the lane, plus the automation strip while it's shown. Every
  /// row is the same height, so a row is found from y by division.
  var rowHeight: CGFloat {
    Layout.trackHeight + (isAutomationVisible ? Layout.automationHeight : 0)
  }
  /// Logic's Inspector down the left: the selected track's channel strip and Stereo Out (I).
  var isInspectorVisible = true
  /// How wide the track headers are, from `Layout.headerWidthRange`.
  var headerWidth: CGFloat = ProjectWindowModel.savedHeaderWidth {
    didSet { UserDefaults.standard.set(Double(headerWidth), forKey: Self.headerWidthKey) }
  }
  /// The parameter each track's automation lane shows; volume when not set.
  var automationParameters: [Track.ID: AutomationParameter] = [:]
  /// A control being recorded into automation, during playback in Touch or Latch.
  var automationWrite: AutomationWrite?
  /// Per track, what automated controls show (see `AutomatedControlValues`).
  @ObservationIgnored var automatedControlValues: [Track.ID: AutomatedControlValues] = [:]
  /// Per meter shown, how lit it is (see `MeterLevel`).
  @ObservationIgnored var meterLevels: [UUID: MeterLevel] = [:]

  var isEditorVisible: Bool {
    get { bottomPane == .pianoRoll }
    set { bottomPane = newValue ? .pianoRoll : (bottomPane == .pianoRoll ? nil : bottomPane) }
  }

  @ObservationIgnored weak var undoManager: UndoManager?
  /// The window this model's views are in, for key commands.
  @ObservationIgnored weak var hostWindow: NSWindow?
  /// Where Delete, the clipboard and the editor's keys apply: the area clicked last. Set on
  /// every click, so it isn't observed itself; `highlightedArea` follows it when it changes.
  @ObservationIgnored var activeEditingArea: EditingArea = .tracks {
    didSet {
      if highlightedArea != activeEditingArea { highlightedArea = activeEditingArea }
      // A chord stays selected only until something else is clicked.
      if activeEditingArea != .chordTrack, selectedChordID != nil { selectedChordID = nil }
    }
  }
  /// The area outlined as the one keys act on.
  private(set) var highlightedArea: EditingArea = .tracks
  /// The chord clicked on the Chord track, which Delete removes.
  var selectedChordID: UUID?
  /// Whether the pointer is over the Chord track, so clicks there count as its own.
  @ObservationIgnored var isPointerOverChordTrack = false
  /// Whether the pointer is over the tracks area, so T opens the tools of the area it's in.
  @ObservationIgnored var isPointerOverTracks = false
  @ObservationIgnored lazy var pianoRoll = PianoRollModel(window: self)
  /// Open plug-in interface windows, by plug-in.
  @ObservationIgnored var pluginWindows: [PluginReference.ID: PluginWindowController] = [:]
  /// Bumped only when the installed Audio Unit instruments change, so views reading the
  /// lists below update then, and aren't redrawn otherwise.
  private var audioUnitListsVersion = 0
  /// The lists, looked up when first needed (see `refreshAudioUnitInstruments`).
  @ObservationIgnored private var cachedAudioUnitLists: AudioUnitLists?

  init(document: OngakuDocument) {
    self.document = document
    engine = PlaybackEngine(project: document.editor.project) { [weak document] file in
      document?.url(for: file)
    }
    selectedTrackID = document.editor.project.tracks.first?.id
    loadWaveforms()
    configureRecording()
    applySettings()
    observeSettings()
    observeAudioUnitRegistrations()
    refreshFlexRenders()
    document.openPluginStates = { [weak self] in self?.openPluginStates() ?? [] }
  }

  /// Applies the Settings window's audio, recording and MIDI settings to this window's
  /// engine. Cheap when nothing changed, so it runs on every change to the defaults.
  func applySettings() {
    engine.apply(AppSettings.audioOutput)
    engine.recordingOptions = AppSettings.recordingOptions
    engine.metronomeSettings = AppSettings.metronome
    MIDIInputRouter.shared?.setIgnoredSources(AppSettings.ignoredMIDISources)
  }

  private func observeSettings() {
    Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
        guard let self else { return }
        self.applySettings()
      }
    }
  }

  var project: Project { document.editor.project }

  // MARK: - Audio Unit instruments

  private struct AudioUnitLists {
    var instruments: [InstrumentLibrary.Entry]
    var catalog: LibraryCatalog

    init(instruments: [InstrumentLibrary.Entry]) {
      self.instruments = instruments
      catalog = LibraryCatalog(audioUnits: instruments)
    }
  }

  private var audioUnitLists: AudioUnitLists {
    _ = audioUnitListsVersion
    if let cachedAudioUnitLists { return cachedAudioUnitLists }
    let lists = AudioUnitLists(instruments: InstrumentLibrary.audioUnitInstruments())
    cachedAudioUnitLists = lists
    return lists
  }

  /// Installed Audio Unit instruments, for the instrument menus.
  var audioUnitInstruments: [InstrumentLibrary.Entry] { audioUnitLists.instruments }
  /// The sounds the Library lists.
  var libraryCatalog: LibraryCatalog { audioUnitLists.catalog }

  /// Looks the installed Audio Unit instruments up again, so one installed while the window
  /// is open appears. Views only update if the list changed.
  func refreshAudioUnitInstruments() {
    guard let cached = cachedAudioUnitLists else { return }
    let instruments = InstrumentLibrary.audioUnitInstruments()
    guard instruments != cached.instruments else { return }
    cachedAudioUnitLists = AudioUnitLists(instruments: instruments)
    audioUnitListsVersion += 1
  }

  /// The system says when Audio Units are installed or removed.
  private func observeAudioUnitRegistrations() {
    Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: AVAudioUnitComponentManager.registrationsChangedNotification) {
        guard let self else { return }
        self.refreshAudioUnitInstruments()
      }
    }
  }

  /// Applies an edit (with undo), reporting a failure in the window. `named` gives the undo
  /// step another name ("Cut Region" for a delete, say). Returns whether it was applied.
  @discardableResult
  func perform(_ command: any EditCommand, named name: String? = nil) -> Bool {
    do {
      let named: any EditCommand = name.map { CompositeCommand($0, commands: [command]) } ?? command
      try document.editor.perform(named, undoManager: undoManager)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  /// Call after every project change, including undo and redo.
  func projectDidChange() {
    refreshFlexRenders()
    engine.update(project: playedProject)
    let regionIDs = Set(project.tracks.flatMap(\.regions).map(\.id))
    selectedRegionIDs.formIntersection(regionIDs)
    if let selectedChordID, !project.chords.contains(where: { $0.id == selectedChordID }) { self.selectedChordID = nil }
    if let selectedTrackID, project.track(withID: selectedTrackID) == nil {
      self.selectedTrackID = project.tracks.first?.id
    }
    let pluginIDs = Set(project.tracks.flatMap { track -> [PluginReference.ID] in
      var ids = track.channel.inserts.map(\.id)
      if case .audioUnit(let instrument) = track.channel.instrument { ids.append(instrument.id) }
      return ids
    } + project.stereoOutInserts.map(\.id))
    for pluginID in pluginWindows.keys where !pluginIDs.contains(pluginID) {
      pluginWindows[pluginID]?.close()
    }
    pianoRoll.projectDidChange()
    loadWaveforms()
    automatedControlValues = automatedControlValues.filter { id, _ in project.track(withID: id) != nil }
    refreshAutomatedControls()
  }

  private func loadWaveforms() {
    for file in project.audioFiles {
      waveforms.load(file, from: document.url(for: file))
    }
  }

  // MARK: - Meters

  /// A meter's level, created when a meter first shows it.
  func meterLevel(for id: UUID) -> MeterLevel {
    if let level = meterLevels[id] { return level }
    let level = MeterLevel()
    meterLevels[id] = level
    return level
  }

  /// Reads every shown meter about 30 times a second while the window is open, and updates
  /// only those whose lit amount changed. One loop for all meters, instead of a timer each.
  func runMeters() async {
    while !Task.isCancelled {
      for (id, level) in meterLevels {
        let reading = engine.meters.level(for: id)
        let left = MeterLevel.step(for: reading.left)
        let right = MeterLevel.step(for: reading.right)
        if left != level.left { level.left = left }
        if right != level.right { level.right = right }
      }
      try? await Task.sleep(for: .milliseconds(33))
    }
  }

  // MARK: - Geometry

  func x(for position: Tick) -> CGFloat {
    CGFloat(position.quarterNotes * pointsPerQuarterNote)
  }

  func position(forX x: CGFloat) -> Tick {
    .quarterNotes(Double(x) / pointsPerQuarterNote)
  }

  var contentWidth: CGFloat {
    x(for: max(project.endPosition, canvasEndWhileRecording ?? .zero)) + 240
  }

  /// Keeps room ahead of the playhead while recording past the end of the song (which only
  /// grows to fit the recording once it stops). Widens the tracks area 32 bars at a time,
  /// so it changes rarely.
  func makeRoomForRecording(at position: Tick) {
    let tempoMap = project.tempoMap
    let shownEnd = max(project.endPosition, canvasEndWhileRecording ?? .zero)
    let barIndex = tempoMap.bar(containing: position).index
    guard tempoMap.tickPosition(ofBarIndex: barIndex + 8) > shownEnd else { return }
    canvasEndWhileRecording = tempoMap.tickPosition(ofBarIndex: barIndex + 32)
  }

  var grid: Grid {
    let minimumWidth = 14.0
    if pointsPerQuarterNote / 4 >= minimumWidth { return .division(Tick(240)) }
    if pointsPerQuarterNote / 2 >= minimumWidth { return .division(Tick(480)) }
    if pointsPerQuarterNote >= minimumWidth { return .division(Tick(960)) }
    return .bar
  }

  /// Whether Control is held, which moves things freely while dragging, as in Logic. It's
  /// pressed after the drag starts, since Control-click is a right-click.
  static var isSnapBypassed: Bool { NSEvent.modifierFlags.contains(.control) }

  /// What positions snap to in a snap mode (the General setting), with Automatic following
  /// the zoom; `nil` when snapping is off.
  func snapGrid(for mode: AppSettings.SnapMode) -> Grid? {
    switch mode {
    case .automatic: grid
    case .bar: .bar
    case .beat: .beat
    case .eighthTriplet: .division(Tick(320))
    case .sixteenthTriplet: .division(Tick(160))
    case .off: nil
    }
  }

  /// The nearest grid position, measured from the start of the bar so odd meters snap
  /// correctly.
  func snap(_ position: Tick, mode: AppSettings.SnapMode = AppSettings.snapMode) -> Tick {
    guard !Self.isSnapBypassed, let snapGrid = snapGrid(for: mode) else { return max(.zero, position) }
    let tempoMap = project.tempoMap
    let (barIndex, barStart) = tempoMap.bar(containing: position)
    switch snapGrid {
    case .bar:
      let nextBar = tempoMap.tickPosition(ofBarIndex: barIndex + 1)
      return max(.zero, position - barStart < nextBar - position ? barStart : nextBar)
    case .beat:
      let size = tempoMap.timeSignature(atBarIndex: barIndex).ticksPerBeat
      let beats = (Double((position - barStart).rawValue) / Double(size.rawValue)).rounded()
      return max(.zero, barStart + size * Int64(beats))
    case .division(var size):
      // A quarter doesn't fit a compound meter's beat; there the zoom's quarter-note level
      // snaps to the dotted-quarter beat.
      let signature = tempoMap.timeSignature(atBarIndex: barIndex)
      if signature.isCompound, size == Tick(960) { size = signature.pulse }
      let divisions = (Double((position - barStart).rawValue) / Double(size.rawValue)).rounded()
      return max(.zero, barStart + size * Int64(divisions))
    }
  }

  func zoom(by factor: Double) {
    pointsPerQuarterNote = min(max(pointsPerQuarterNote * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
  }

  // MARK: - Transport

  func togglePlayback() {
    engine.togglePlayback()
  }

  func goToBeginning() {
    engine.locate(to: .zero)
  }

  /// Moves the playhead by whole bars, like Logic's comma and period keys. Going back from
  /// inside a bar first goes to that bar's start.
  func moveByBars(_ count: Int) {
    let tempoMap = project.tempoMap
    let playhead = engine.playheadPosition
    let (index, start) = tempoMap.bar(containing: playhead)
    let targetIndex = count < 0 && playhead > start ? index + count + 1 : index + count
    engine.locate(to: tempoMap.tickPosition(ofBarIndex: max(0, targetIndex)))
  }

  func toggleCycle() {
    var cycle = project.cycle
    cycle.isEnabled.toggle()
    perform(SetCycle(cycle))
  }

  func toggleMetronome() {
    perform(SetMetronome(!project.isMetronomeEnabled))
  }

  // MARK: - Editing

  /// A new track with the colour and automation mode the settings give new tracks.
  func makeTrack(name: String, kind: TrackKind) -> Track {
    Track(
      name: name, kind: kind, color: AppSettings.newTrackColor(for: kind),
      automationMode: AppSettings.newTrackAutomationMode)
  }

  func addTrack(_ kind: TrackKind) {
    var track = makeTrack(name: project.nextTrackName(for: kind), kind: kind)
    // Like Logic, a track added while a stack or one of its subtracks is selected joins it.
    if let selected = selectedTrack, let stackID = selected.isSummingStack ? selected.id : selected.stackID {
      track.stackID = stackID
      track.channel.output = .track(stackID)
      collapsedStackIDs.remove(stackID)
    }
    let index = selectedTrackID.flatMap(project.trackIndex(for:)).map { $0 + 1 }
    perform(AddTrack(track, at: index))
    selectedTrackID = track.id
  }

  /// Deletes the selected regions. Never deletes tracks: that's Track › Delete Track, so a
  /// stray Delete with nothing selected can't remove a track.
  func deleteSelection() {
    guard !selectedRegionIDs.isEmpty else { return }
    perform(DeleteRegions(selectedRegionIDs))
  }

  /// What Delete and Edit › Delete Selection remove: notes when the Piano Roll was clicked
  /// last, the selected chord when the Chord track was, otherwise regions. The other editors
  /// have no selection to delete, so Delete does nothing there (rather than remove notes the
  /// Piano Roll had selected, out of view).
  func deleteSelectionInActiveArea() {
    if activeEditingArea == .pianoRoll, isEditorVisible {
      if isPianoRollEditing { pianoRoll.deleteSelection() }
    } else if activeEditingArea == .chordTrack {
      if let selectedChordID {
        deleteChord(selectedChordID)
        self.selectedChordID = nil
      }
    } else {
      deleteSelection()
    }
  }

  var canDeleteSelectedTracks: Bool { !selectedTrackIDs.isEmpty }

  /// Deletes every selected track (a summing stack takes its subtracks with it), then
  /// selects the track that took the first one's place.
  func deleteSelectedTracks() {
    let trackIDs = selectedTrackIDs
    guard let firstIndex = project.tracks.firstIndex(where: { trackIDs.contains($0.id) }) else { return }
    perform(DeleteTracks(trackIDs))
    let remaining = project.tracks
    selectedTrackID = remaining.isEmpty ? nil : remaining[min(firstIndex, remaining.count - 1)].id
  }

  /// Splits the selected regions at the playhead, or every region under the playhead on the
  /// selected track when nothing is selected.
  func splitAtPlayhead() {
    let playhead = engine.playheadPosition
    let candidates: [Region]
    if selectedRegionIDs.isEmpty {
      candidates = selectedTrackID.flatMap(project.track(withID:))?.regions ?? []
    } else {
      candidates = project.tracks.flatMap(\.regions).filter { selectedRegionIDs.contains($0.id) }
    }
    let splits = candidates.filter { $0.start < playhead && playhead < $0.end }.map {
      SplitRegion($0.id, at: playhead)
    }
    guard !splits.isEmpty else { return }
    perform(CompositeCommand("Split Regions", commands: splits))
    selectedRegionIDs.formUnion(splits.map(\.newRegionID))
  }

  func select(_ regionID: Region.ID, extending: Bool) {
    activeEditingArea = .tracks
    if extending {
      if selectedRegionIDs.contains(regionID) {
        selectedRegionIDs.remove(regionID)
      } else {
        selectedRegionIDs.insert(regionID)
      }
    } else if !selectedRegionIDs.contains(regionID) {
      selectedRegionIDs = [regionID]
    }
    if let location = project.regionLocation(for: regionID) {
      selectedTrackID = project.tracks[location.track].id
    }
  }

  /// Moves the selected regions by a time offset and a number of tracks (as shown, so a
  /// collapsed stack's hidden subtracks don't count), as one undo step.
  /// Option-Left and Right in the tracks area: moves the selected regions a step of the snap
  /// grid (the zoom's grid while snapping is off), as Logic's nudge does, in one undo step.
  func nudgeSelectedRegions(by steps: Int, mode: AppSettings.SnapMode? = nil) {
    let regions = displayedTracks.flatMap(\.regions).filter { selectedRegionIDs.contains($0.id) }
    guard let start = regions.map(\.start).min() else { return }
    // Nothing goes before the project start, and the regions keep their spacing.
    let offset = max(snapStep(at: start, mode: mode) * Int64(steps), .zero - start)
    guard offset != .zero else { return }
    let commands = regions.map { MoveRegion($0.id, to: $0.start + offset) }
    perform(CompositeCommand(commands.count == 1 ? "Nudge Region" : "Nudge Regions", commands: commands))
  }

  /// How long a step of the snap grid is at a position (the zoom's grid while snapping is
  /// off), in the snap mode given or else the General setting's.
  func snapStep(at position: Tick, mode: AppSettings.SnapMode? = nil) -> Tick {
    let tempoMap = project.tempoMap
    let signature = tempoMap.timeSignature(atBarIndex: tempoMap.bar(containing: position).index)
    switch snapGrid(for: mode ?? AppSettings.snapMode) ?? grid {
    case .bar: return signature.ticksPerBar
    case .beat: return signature.ticksPerBeat
    // As when snapping, a compound meter's quarter-note level is its dotted-quarter beat.
    case .division(let size): return signature.isCompound && size == Tick(960) ? signature.pulse : size
    }
  }

  func moveSelection(by offset: Tick, trackOffset: Int) {
    let tracks = displayedTracks
    var commands: [any EditCommand] = []
    for (trackIndex, track) in tracks.enumerated() {
      for region in track.regions where selectedRegionIDs.contains(region.id) {
        let destinationIndex = min(max(trackIndex + trackOffset, 0), tracks.count - 1)
        let destination = tracks[destinationIndex]
        guard destination.kind == track.kind else {
          errorMessage = EditError.trackKindMismatch(expected: track.kind, found: destination.kind).localizedDescription
          return
        }
        commands.append(MoveRegion(region.id, to: max(.zero, region.start + offset), track: destination.id))
      }
    }
    guard !commands.isEmpty else { return }
    perform(CompositeCommand(commands.count == 1 ? "Move Region" : "Move Regions", commands: commands))
  }

  // MARK: - Import

  /// Imports audio files at a position. Files dropped on an audio track are placed one after
  /// another on it; otherwise each file gets a new audio track.
  func importAudio(_ urls: [URL], at position: Tick, onTrack targetTrackID: Track.ID?) async {
    let audioURLs = urls.filter(AudioImporter.isAudioFile)
    guard !audioURLs.isEmpty else {
      errorMessage = "Only audio and MIDI files can be added to the tracks area."
      return
    }
    let targetTrack = targetTrackID.flatMap(project.track(withID:)).flatMap { $0.kind == .audio ? $0 : nil }

    var commands: [any EditCommand] = []
    var reservedNames: Set<String> = []
    var cursor = position
    for url in audioURLs {
      let isAccessing = url.startAccessingSecurityScopedResource()
      defer {
        if isAccessing { url.stopAccessingSecurityScopedResource() }
      }
      do {
        let file = try await document.stageAudio(from: url, reservedNames: reservedNames)
        reservedNames.insert(file.fileName)
        commands.append(AddAudioFile(file))

        if let targetTrack {
          let region = Region.audio(for: file, at: cursor, tempoMap: project.tempoMap)
          commands.append(AddRegion(region, to: targetTrack.id))
          cursor = region.end
        } else {
          let region = Region.audio(for: file, at: position, tempoMap: project.tempoMap)
          let track = makeTrack(name: region.name, kind: .audio)
          commands.append(AddTrack(track))
          commands.append(AddRegion(region, to: track.id))
        }
      } catch {
        errorMessage = error.localizedDescription
      }
    }
    guard !commands.isEmpty else { return }
    perform(CompositeCommand(audioURLs.count == 1 ? "Import Audio File" : "Import Audio Files", commands: commands))
  }
}

/// The visible part of the tracks area. Kept separate from the window model so only the
/// views that depend on scrolling update while scrolling.
@MainActor
@Observable
final class ScrollState {
  static let chunkWidth: CGFloat = 1024

  private(set) var offset: CGPoint = .zero
  private(set) var viewportSize: CGSize = .zero
  /// The horizontal range waveforms and grid lines are drawn for: the viewport plus a margin,
  /// rounded to chunks so it only changes every so often while scrolling.
  private(set) var renderRange: ClosedRange<CGFloat> = 0...4096
  /// The rows (tracks) near the viewport: the visible ones plus a margin, rounded to chunks
  /// so it changes only every few rows while scrolling. Only these rows are drawn.
  private(set) var visibleRows: Range<Int> = 0..<32

  static let rowChunk = 8
  /// Changes when automation is shown or hidden.
  var rowHeight: CGFloat {
    didSet {
      if rowHeight != oldValue { update(offset: offset, viewportSize: viewportSize) }
    }
  }
  /// Where the first row starts in the scrolled content (below the ruler).
  private let rowsTop: CGFloat

  /// By default, the tracks area's rows.
  init(rowHeight: CGFloat? = nil, rowsTop: CGFloat? = nil) {
    self.rowHeight = rowHeight ?? ProjectWindowModel.Layout.trackHeight
    self.rowsTop = rowsTop ?? ProjectWindowModel.Layout.rulerHeight
  }

  func update(offset: CGPoint, viewportSize: CGSize) {
    // While a window is first laid out its scroll view briefly has no size. Changing the
    // render range then and again a moment later would re-lay out the content twice in one
    // frame, so wait for a real size.
    guard viewportSize.width > 0, viewportSize.height > 0 else { return }
    if self.offset != offset { self.offset = offset }
    if self.viewportSize != viewportSize { self.viewportSize = viewportSize }

    // At least four chunks wide, so the range for a typical window matches the initial one.
    let chunk = ScrollState.chunkWidth
    let start = max(0, ((offset.x - chunk) / chunk).rounded(.down) * chunk)
    let chunks = max(4, (viewportSize.width / chunk).rounded(.up) + 3)
    let end = start + chunks * chunk
    if renderRange != start...end { renderRange = start...end }

    let chunkRows = ScrollState.rowChunk
    let firstVisible = max(0, Int((offset.y - rowsTop) / rowHeight))
    let lastVisible = Int(((offset.y + viewportSize.height - rowsTop) / rowHeight).rounded(.up))
    let firstRow = max(0, (firstVisible / chunkRows - 1) * chunkRows)
    let lastRow = (lastVisible / chunkRows + 2) * chunkRows
    if visibleRows != firstRow..<lastRow { visibleRows = firstRow..<lastRow }
  }
}
