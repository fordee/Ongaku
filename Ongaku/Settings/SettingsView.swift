//
//  SettingsView.swift
//  Ongaku
//

import AppKit
import CoreMIDI
import OngakuCore
import OngakuEngine
import SwiftUI

/// The app's settings, stored in user defaults. Views read them with `@AppStorage` using
/// these keys; the rest of the app reads the static properties.
enum AppSettings {
  // MARK: General

  static let newProjectTemplateKey = "NewProjectTemplate"
  static let followsPlayheadKey = "FollowsPlayhead"
  nonisolated static let snapModeKey = "SnapMode"

  /// What a new project starts with.
  enum NewProjectTemplate: String, CaseIterable {
    case instrumentTrack, audioTrack, empty

    var title: String {
      switch self {
      case .instrumentTrack: "One software instrument track"
      case .audioTrack: "One audio track"
      case .empty: "No tracks"
      }
    }

    func makeProject() -> Project {
      switch self {
      case .instrumentTrack: .newDefault()
      case .audioTrack: Project(tracks: [Track(name: "Audio 1", kind: .audio)])
      case .empty: Project()
      }
    }
  }

  /// What dragging regions and clicking in the tracks area snaps to.
  nonisolated enum SnapMode: String, CaseIterable {
    /// A grid that gets finer as you zoom in (Logic's Smart snap).
    case automatic
    case bar, beat
    case eighthTriplet, sixteenthTriplet
    case off

    var title: String {
      switch self {
      case .automatic: "Automatic (follows the zoom)"
      case .bar: "Bars"
      case .beat: "Beats"
      case .eighthTriplet: "1/8 Triplets"
      case .sixteenthTriplet: "1/16 Triplets"
      case .off: "Off"
      }
    }
  }

  static var newProjectTemplate: NewProjectTemplate {
    UserDefaults.standard.string(forKey: newProjectTemplateKey).flatMap(NewProjectTemplate.init) ?? .instrumentTrack
  }

  static var followsPlayhead: Bool {
    UserDefaults.standard.object(forKey: followsPlayheadKey) as? Bool ?? true
  }

  nonisolated static var snapMode: SnapMode {
    UserDefaults.standard.string(forKey: snapModeKey).flatMap(SnapMode.init) ?? .automatic
  }

  // MARK: Audio

  static let outputDeviceKey = "OutputDeviceUID"
  static let bufferSizeKey = "IOBufferSize"
  static let bufferSizes = [32, 64, 128, 256, 512, 1024, 2048]
  static let defaultBufferSize = 512

  static var audioOutput: AudioOutputSettings {
    let uid = UserDefaults.standard.string(forKey: outputDeviceKey) ?? ""
    let frames = UserDefaults.standard.integer(forKey: bufferSizeKey)
    return AudioOutputSettings(deviceUID: uid.isEmpty ? nil : uid, bufferFrames: frames > 0 ? frames : defaultBufferSize)
  }

  // MARK: Recording

  static let countInBarsKey = "CountInBars"
  /// The count-in last chosen here, which the control bar's Count-in button switches back
  /// on after switching it off.
  static let countInBarsWhenOnKey = "CountInBarsWhenOn"
  static let clickWhileRecordingKey = "ClickWhileRecording"
  static let recordingFileTypeKey = "RecordingFileType"
  static let recordingBitDepthKey = "RecordingBitDepth"

  static var recordingOptions: RecordingOptions {
    let defaults = UserDefaults.standard
    return RecordingOptions(
      countInBars: defaults.integer(forKey: countInBarsKey),
      clickWhileRecording: defaults.bool(forKey: clickWhileRecordingKey),
      fileType: defaults.string(forKey: recordingFileTypeKey).flatMap(RecordingFileType.init) ?? .caf,
      bitDepth: RecordingBitDepth(rawValue: defaults.integer(forKey: recordingBitDepthKey)) ?? .int24)
  }

  // MARK: MIDI

  static let ignoredMIDISourcesKey = "IgnoredMIDISources"
  static let importedMIDITrackColorsKey = "ImportedMIDITrackColors"

  /// How tracks imported from a MIDI file are coloured.
  enum ImportedTrackColors: String, CaseIterable {
    /// Every track gets the colour new instrument tracks get (green unless changed).
    case instrumentColor
    /// Each track gets the next colour in the palette, so they're easy to tell apart.
    case varied

    var title: String {
      switch self {
      case .instrumentColor: "All the same color"
      case .varied: "A different color for each track"
      }
    }
  }

  static var importedMIDITrackColors: ImportedTrackColors {
    UserDefaults.standard.string(forKey: importedMIDITrackColorsKey).flatMap(ImportedTrackColors.init) ?? .instrumentColor
  }

  /// MIDI sources switched off, stored as their unique IDs separated by commas (so
  /// `@AppStorage` can hold them).
  static var ignoredMIDISources: Set<MIDIUniqueID> {
    decodeSources(UserDefaults.standard.string(forKey: ignoredMIDISourcesKey) ?? "")
  }

  static func decodeSources(_ text: String) -> Set<MIDIUniqueID> {
    Set(text.split(separator: ",").compactMap { MIDIUniqueID($0) })
  }

  static func encodeSources(_ ids: Set<MIDIUniqueID>) -> String {
    ids.sorted().map(String.init).joined(separator: ",")
  }

  // MARK: Metronome

  static let metronomeSoundKey = "MetronomeSound"
  static let metronomeLevelKey = "MetronomeLevel"
  static let metronomeAccentKey = "MetronomeAccentsDownbeats"

  static var metronome: MetronomeSettings {
    let defaults = UserDefaults.standard
    return MetronomeSettings(
      sound: defaults.string(forKey: metronomeSoundKey).flatMap(MetronomeSettings.Sound.init) ?? .click,
      level: defaults.object(forKey: metronomeLevelKey) as? Double ?? 1,
      accentsDownbeats: defaults.object(forKey: metronomeAccentKey) as? Bool ?? true)
  }

  // MARK: Display

  static let lcdColorKey = "LCDColor"

  /// The LCD's backlight colour.
  enum LCDColor: String, CaseIterable {
    case blue, amber, green, white

    var title: String { rawValue.capitalized }

    var palette: LCDPalette {
      switch self {
      case .blue: .blue
      case .amber: .amber
      case .green: .green
      case .white: .white
      }
    }
  }

  /// The settings key for the colour new tracks of a kind get.
  static func newTrackColorKey(for kind: TrackKind) -> String {
    switch kind {
    case .softwareInstrument: "NewInstrumentTrackColor"
    case .audio: "NewAudioTrackColor"
    case .aux: "NewAuxTrackColor"
    }
  }

  static func newTrackColor(for kind: TrackKind) -> TrackColor {
    UserDefaults.standard.string(forKey: newTrackColorKey(for: kind)).flatMap(TrackColor.init) ?? kind.defaultColor
  }

  // MARK: Automation

  static let newTrackAutomationModeKey = "NewTrackAutomationMode"
  static let automationThinningKey = "AutomationThinning"

  /// How many of the points recorded while moving a control are kept.
  enum AutomationThinning: String, CaseIterable {
    case off, light, normal, heavy

    var title: String {
      switch self {
      case .off: "Off (keep every point)"
      case .light: "Light"
      case .normal: "Normal"
      case .heavy: "Heavy"
      }
    }

    /// Scales how far a point may stray from a straight line before it's kept.
    var toleranceScale: Double {
      switch self {
      case .off: 0
      case .light: 0.5
      case .normal: 1
      case .heavy: 2
      }
    }
  }

  static var newTrackAutomationMode: AutomationMode {
    UserDefaults.standard.string(forKey: newTrackAutomationModeKey).flatMap(AutomationMode.init) ?? .read
  }

  static var automationThinning: AutomationThinning {
    UserDefaults.standard.string(forKey: automationThinningKey).flatMap(AutomationThinning.init) ?? .normal
  }

  // MARK: Agents

  static let agentServerEnabledKey = "AgentServerEnabled"
  static let agentServerPortKey = "AgentServerPort"
  static let agentServerTokenKey = "AgentServerToken"
  static let defaultAgentServerPort = 7317
  static let agentServerPortRange = 1024...65535

  /// Whether AI agents can connect to Ongaku's MCP server (off until switched on).
  static var isAgentServerEnabled: Bool {
    UserDefaults.standard.bool(forKey: agentServerEnabledKey)
  }

  static var agentServerPort: Int {
    let port = UserDefaults.standard.integer(forKey: agentServerPortKey)
    return agentServerPortRange.contains(port) ? port : defaultAgentServerPort
  }

  /// The secret agents send with every request, made the first time it's needed.
  static var agentServerToken: String {
    if let token = UserDefaults.standard.string(forKey: agentServerTokenKey), !token.isEmpty { return token }
    let token = makeAgentServerToken()
    UserDefaults.standard.set(token, forKey: agentServerTokenKey)
    return token
  }

  /// 32 random bytes, as URL-safe base64 (safe to paste into a shell command).
  static func makeAgentServerToken() -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
}

/// The Settings window (Ongaku ▸ Settings…), with a tab per area like Logic's.
struct SettingsView: View {
  var body: some View {
    TabView {
      Tab("General", systemImage: "gearshape") {
        GeneralSettingsView()
      }
      Tab("Audio", systemImage: "speaker.wave.2") {
        AudioSettingsView()
      }
      Tab("Recording", systemImage: "record.circle") {
        RecordingSettingsView()
      }
      Tab("MIDI", systemImage: "pianokeys") {
        MIDISettingsView()
      }
      Tab("Metronome", systemImage: "metronome") {
        MetronomeSettingsView()
      }
      Tab("Display", systemImage: "display") {
        DisplaySettingsView()
      }
      Tab("Automation", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
        AutomationSettingsView()
      }
      Tab("Libraries", systemImage: "music.note.list") {
        LibrariesSettingsView()
      }
      Tab("Agents", systemImage: "sparkles") {
        AgentSettingsView()
      }
    }
    .frame(width: 560)
  }
}

// MARK: - General

private struct GeneralSettingsView: View {
  @AppStorage(AppSettings.newProjectTemplateKey) private var template = AppSettings.NewProjectTemplate.instrumentTrack
  @AppStorage(AppSettings.followsPlayheadKey) private var followsPlayhead = true
  @AppStorage(AppSettings.snapModeKey) private var snapMode = AppSettings.SnapMode.automatic

  var body: some View {
    Form {
      Section("Projects") {
        Picker("New projects start with", selection: $template) {
          ForEach(AppSettings.NewProjectTemplate.allCases, id: \.self) { Text($0.title).tag($0) }
        }
      }
      Section("Editing") {
        Picker("Snap regions to", selection: $snapMode) {
          ForEach(AppSettings.SnapMode.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Toggle("Scroll to follow the playhead during playback", isOn: $followsPlayhead)
      }
    }
    .settingsPane()
  }
}

// MARK: - Audio

private struct AudioSettingsView: View {
  @AppStorage(AppSettings.outputDeviceKey) private var outputDeviceUID = ""
  @AppStorage(AppSettings.bufferSizeKey) private var bufferSize = AppSettings.defaultBufferSize
  @State private var devices: [AudioOutputDevice] = []
  @State private var systemDefault: AudioOutputDevice?

  /// The device in use: the chosen one, or the system default.
  private var device: AudioOutputDevice? {
    devices.first { $0.uid == outputDeviceUID } ?? systemDefault
  }

  var body: some View {
    Form {
      Section {
        Picker("Output device", selection: $outputDeviceUID) {
          Text(systemDefault.map { "System Default (\($0.name))" } ?? "System Default").tag("")
          Divider()
          ForEach(devices) { Text($0.name).tag($0.uid) }
          // A chosen device that's unplugged stays chosen, and the default plays meanwhile.
          if !outputDeviceUID.isEmpty, !devices.contains(where: { $0.uid == outputDeviceUID }) {
            Text("Not Connected").tag(outputDeviceUID)
          }
        }
        Picker("I/O buffer size", selection: $bufferSize) {
          ForEach(bufferSizes, id: \.self) { Text("\($0) samples").tag($0) }
        }
        if let device {
          LabeledContent("Sample rate", value: "\(device.sampleRate.formatted(.number.precision(.fractionLength(0...1)))) Hz")
          LabeledContent("Buffer latency", value: latency(of: device))
        }
      } header: {
        Text("Output")
      } footer: {
        Text("Smaller buffers make playing instruments feel more immediate but use more of the processor. If you hear crackles, choose a larger buffer.")
          .foregroundStyle(.secondary)
      }
      Section {
        LabeledContent("Input device") {
          Button("Open Sound Settings…", action: openSoundSettings)
        }
      } header: {
        Text("Input")
      } footer: {
        Text("Audio tracks record from the input chosen in System Settings › Sound.")
          .foregroundStyle(.secondary)
      }
    }
    .settingsPane()
    .onAppear(perform: loadDevices)
  }

  /// The buffer sizes the device accepts (all of them if it isn't known).
  private var bufferSizes: [Int] {
    guard let range = device?.bufferSizeRange else { return AppSettings.bufferSizes }
    let sizes = AppSettings.bufferSizes.filter(range.contains)
    return sizes.contains(bufferSize) ? sizes : (sizes + [bufferSize]).sorted()
  }

  private func latency(of device: AudioOutputDevice) -> String {
    let milliseconds = Double(bufferSize) / device.sampleRate * 1000
    return "\(milliseconds.formatted(.number.precision(.fractionLength(1)))) ms"
  }

  private func loadDevices() {
    devices = AudioOutputDevice.all()
    systemDefault = AudioOutputDevice.systemDefault()
  }

  private func openSoundSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
      NSWorkspace.shared.open(url)
    }
  }
}

// MARK: - Recording

private struct RecordingSettingsView: View {
  @AppStorage(AppSettings.countInBarsKey) private var countInBars = 0
  @AppStorage(AppSettings.countInBarsWhenOnKey) private var countInBarsWhenOn = 1
  @AppStorage(AppSettings.clickWhileRecordingKey) private var clickWhileRecording = false
  @AppStorage(AppSettings.recordingFileTypeKey) private var fileType = RecordingFileType.caf
  @AppStorage(AppSettings.recordingBitDepthKey) private var bitDepth = RecordingBitDepth.int24

  var body: some View {
    Form {
      Section("Metronome") {
        Picker("Count-in", selection: $countInBars) {
          Text("None").tag(0)
          Text("1 bar").tag(1)
          Text("2 bars").tag(2)
        }
        .onChange(of: countInBars) { _, bars in
          if bars > 0 { countInBarsWhenOn = bars }
        }
        Toggle("Click while recording, even with the metronome off", isOn: $clickWhileRecording)
      }
      Section {
        Picker("File type", selection: $fileType) {
          Text("CAF").tag(RecordingFileType.caf)
          Text("WAV").tag(RecordingFileType.wav)
          Text("AIFF").tag(RecordingFileType.aiff)
        }
        Picker("Bit depth", selection: $bitDepth) {
          Text("16-bit").tag(RecordingBitDepth.int16)
          Text("24-bit").tag(RecordingBitDepth.int24)
          Text("32-bit float").tag(RecordingBitDepth.float32)
        }
      } header: {
        Text("Audio Files")
      } footer: {
        Text("Recordings are saved inside the project, at the output device’s sample rate.")
          .foregroundStyle(.secondary)
      }
    }
    .settingsPane()
  }
}

// MARK: - MIDI

private struct MIDISettingsView: View {
  @AppStorage(AppSettings.ignoredMIDISourcesKey) private var ignoredSources = ""
  @AppStorage(AppSettings.importedMIDITrackColorsKey)
  private var importedTrackColors = AppSettings.ImportedTrackColors.instrumentColor
  /// The colour "All the same color" gives them: the one set for new instrument tracks.
  @AppStorage(AppSettings.newTrackColorKey(for: .softwareInstrument))
  private var instrumentTrackColor = TrackKind.softwareInstrument.defaultColor
  @State private var sources: [MIDIInputRouter.Source] = []

  var body: some View {
    Form {
      Section {
        if sources.isEmpty {
          Text("No MIDI keyboards or controllers are connected.")
            .foregroundStyle(.secondary)
        }
        ForEach(sources) { source in
          Toggle(source.name, isOn: listening(to: source))
        }
      } header: {
        Text("Inputs")
      } footer: {
        Text("Ongaku Studio plays and records from the inputs that are on.")
          .foregroundStyle(.secondary)
      }
      Section("Importing MIDI Files") {
        Picker("Track colors", selection: $importedTrackColors) {
          ForEach(AppSettings.ImportedTrackColors.allCases, id: \.self) { option in
            HStack(spacing: 8) {
              Text(option.title)
              TrackColorSwatches(colors: option == .varied ? TrackColor.importPalette : [instrumentTrackColor])
            }
            .tag(option)
          }
        }
        .pickerStyle(.radioGroup)
      }
    }
    .settingsPane()
    .onAppear { sources = MIDIInputRouter.sources() }
  }

  private func listening(to source: MIDIInputRouter.Source) -> Binding<Bool> {
    Binding {
      !AppSettings.decodeSources(ignoredSources).contains(source.id)
    } set: { isOn in
      var ignored = AppSettings.decodeSources(ignoredSources)
      if isOn {
        ignored.remove(source.id)
      } else {
        ignored.insert(source.id)
      }
      ignoredSources = AppSettings.encodeSources(ignored)
    }
  }
}

// MARK: - Metronome

private struct MetronomeSettingsView: View {
  @AppStorage(AppSettings.metronomeSoundKey) private var sound = MetronomeSettings.Sound.click
  @AppStorage(AppSettings.metronomeLevelKey) private var level = 1.0
  @AppStorage(AppSettings.metronomeAccentKey) private var accentsDownbeats = true

  var body: some View {
    Form {
      Section {
        Picker("Sound", selection: $sound) {
          Text("Click").tag(MetronomeSettings.Sound.click)
          Text("Woodblock").tag(MetronomeSettings.Sound.woodblock)
          Text("Hi-Hat").tag(MetronomeSettings.Sound.hiHat)
          Text("Beep").tag(MetronomeSettings.Sound.beep)
        }
        LabeledContent("Volume") {
          HStack {
            Slider(value: $level, in: 0...1)
              .frame(width: 180)
            Text(level.formatted(.percent.precision(.fractionLength(0))))
              .monospacedDigit()
              .frame(width: 44, alignment: .trailing)
          }
        }
        Toggle("Accent the first beat of each bar", isOn: $accentsDownbeats)
      } footer: {
        Text("Switch the metronome on with K or the button in the control bar. The count-in is set under Recording.")
          .foregroundStyle(.secondary)
      }
    }
    .settingsPane()
  }
}

// MARK: - Display

private struct DisplaySettingsView: View {
  @AppStorage(AppSettings.lcdColorKey) private var lcdColor = AppSettings.LCDColor.blue

  var body: some View {
    Form {
      Section("Control Bar") {
        Picker("LCD color", selection: $lcdColor) {
          ForEach(AppSettings.LCDColor.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        LCDColorSample(palette: lcdColor.palette)
      }
      Section {
        NewTrackColorPicker(title: "Software instrument tracks", kind: .softwareInstrument)
        NewTrackColorPicker(title: "Audio tracks", kind: .audio)
        NewTrackColorPicker(title: "Aux tracks", kind: .aux)
      } header: {
        Text("Colors of New Tracks")
      } footer: {
        Text("Tracks you already have keep their colors.")
          .foregroundStyle(.secondary)
      }
    }
    .settingsPane()
  }
}

/// A few characters in an LCD colour, to show what it looks like.
private struct LCDColorSample: View {
  let palette: LCDPalette

  var body: some View {
    HStack(spacing: 14) {
      ForEach(["1  1  1", "120", "4/4"], id: \.self) { text in
        Text(text)
          .font(Theme.monospaced(15))
          .foregroundStyle(palette.text)
          .shadow(color: palette.glow.opacity(0.55), radius: 2.5)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
    .background(
      RoundedRectangle(cornerRadius: 5)
        .fill(LinearGradient(colors: [palette.glassTop, palette.glassBottom], startPoint: .top, endPoint: .bottom))
    )
    .frame(maxWidth: .infinity, alignment: .trailing)
    .accessibilityHidden(true)
  }
}

private struct NewTrackColorPicker: View {
  let title: String
  let kind: TrackKind
  @AppStorage private var color: TrackColor

  init(title: String, kind: TrackKind) {
    self.title = title
    self.kind = kind
    _color = AppStorage(wrappedValue: kind.defaultColor, AppSettings.newTrackColorKey(for: kind))
  }

  var body: some View {
    Picker(selection: $color) {
      ForEach(TrackColor.allCases, id: \.self) { Text($0.name).tag($0) }
    } label: {
      HStack(spacing: 8) {
        TrackColorSwatches(colors: [color])
        Text(title)
      }
    }
  }
}

// MARK: - Automation

private struct AutomationSettingsView: View {
  @AppStorage(AppSettings.newTrackAutomationModeKey) private var newTrackMode = AutomationMode.read
  @AppStorage(AppSettings.automationThinningKey) private var thinning = AppSettings.AutomationThinning.normal

  var body: some View {
    Form {
      Section {
        Picker("Mode for new tracks", selection: $newTrackMode) {
          ForEach(AutomationMode.allCases, id: \.self) { Text($0.name).tag($0) }
        }
      } footer: {
        Text("Read plays a track’s automation. Touch and Latch also record it while you move a fader or pan control during playback.")
          .foregroundStyle(.secondary)
      }
      Section {
        Picker("Thin recorded automation", selection: $thinning) {
          ForEach(AppSettings.AutomationThinning.allCases, id: \.self) { Text($0.title).tag($0) }
        }
      } footer: {
        Text("Moving a control records many points. Thinning removes the ones that don’t change the curve’s shape, which keeps it easy to edit.")
          .foregroundStyle(.secondary)
      }
    }
    .settingsPane()
  }
}

// MARK: - Libraries

/// Sound library folders: loops and samples for the Loop Browser, and sampler instruments.
private struct LibrariesSettingsView: View {
  private let libraries = SoundLibraries.shared

  var body: some View {
    Form {
      Section {
        BuiltInSoundsRow()
      } header: {
        Text("Built-in Sounds")
      }
      Section {
        if libraries.libraries.isEmpty {
          Text("None yet. Ongaku Studio doesn’t come with loops or samples: add a library to use them.")
            .foregroundStyle(.secondary)
        }
        ForEach(libraries.libraries) { library in
          LibraryLocationRow(library: library)
        }
        HStack {
          Spacer()
          Button("Add Library…") { SoundLibraries.chooseFolders() }
        }
      } header: {
        Text("Additional Libraries")
      } footer: {
        Text("Add any folder of sounds — Logic Pro’s or GarageBand’s sound library, a sample pack, a SoundFont collection. Ongaku Studio indexes the loops, samples and sampler instruments in it and keeps the index up to date as files change. Files stay where they are; the ones you use are copied into your song.")
          .foregroundStyle(.secondary)
      }
    }
    .settingsPane()
  }
}

/// What comes with Ongaku Studio: always there, so it can't be removed or rescanned.
private struct BuiltInSoundsRow: View {
  var body: some View {
    let programs = GeneralMIDI.families.reduce(0) { $0 + $1.programs.count }
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "shippingbox.fill")
        .foregroundStyle(Theme.accent)
        .font(.title2)
      VStack(alignment: .leading, spacing: 2) {
        Text("Ongaku Studio").fontWeight(.medium)
        Text("\(InstrumentLibrary.ongakuInstruments().count) Ongaku instruments · \(programs) General MIDI sounds · \(GeneralMIDI.drumKits.count) drum kits")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("In the Library (Y) for every instrument track, with the Audio Unit instruments installed on this Mac.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .accessibilityElement(children: .combine)
  }
}

private struct LibraryLocationRow: View {
  let library: SoundLibraries.Library

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "folder.fill")
        .foregroundStyle(Theme.accent)
        .font(.title2)
      VStack(alignment: .leading, spacing: 2) {
        Text(library.name).fontWeight(.medium)
        Text(library.location.path)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(summary)
          .font(.caption)
          .foregroundStyle(isProblem ? Theme.record : .secondary)
          .accessibilityIdentifier("library-status")
      }
      Spacer()
      Button("Rescan") { SoundLibraries.shared.rescan(library.id) }
        .disabled(isScanning)
      Button("Remove") { SoundLibraries.shared.remove(library.id) }
    }
    .accessibilityElement(children: .contain)
  }

  private var isScanning: Bool {
    if case .scanning = library.status { true } else { false }
  }

  private var isProblem: Bool {
    if case .unavailable = library.status { true } else { false }
  }

  private var summary: String {
    switch library.status {
    case .unavailable(let message): return message
    case .scanning(let done): return "Indexing… \(done.formatted()) files"
    case .ready:
      let parts = [
        (library.count(of: .loop), "loop", "loops"), (library.count(of: .oneShot), "sample", "samples"),
        (library.count(of: .instrument), "instrument", "instruments"),
        (library.count(of: .impulseResponse), "impulse response", "impulse responses"),
      ]
      .filter { $0.0 > 0 }
      .map { "\($0.0.formatted()) \($0.0 == 1 ? $0.1 : $0.2)" }
      return parts.isEmpty ? "No sounds found" : parts.joined(separator: " · ")
    }
  }
}

// MARK: - Agents

/// Lets AI agents make music in Ongaku through its MCP server.
private struct AgentSettingsView: View {
  @AppStorage(AppSettings.agentServerEnabledKey) private var isEnabled = false
  @AppStorage(AppSettings.agentServerPortKey) private var port = AppSettings.defaultAgentServerPort
  @AppStorage(AppSettings.agentServerTokenKey) private var token = ""
  private let server = AgentServer.shared

  var body: some View {
    Form {
      Section {
        Toggle("Let AI agents make music in Ongaku Studio", isOn: $isEnabled)
        LabeledContent("Status") {
          Text(statusText)
            .foregroundStyle(statusIsProblem ? Theme.record : .secondary)
            .accessibilityIdentifier("agent-server-status")
        }
      } footer: {
        Text("Agents such as Claude Code connect over MCP and work on the frontmost song: they can read it, write parts, set up the arrangement and chords, and play it. You see each change as it happens, and can undo it. What they read of the song goes to the AI service behind the agent.")
          .foregroundStyle(.secondary)
      }
      Section {
        TextField("Port", value: $port, format: .number.grouping(.never))
        LabeledContent("Address") {
          Text(server.url).textSelection(.enabled)
        }
        LabeledContent("Token") {
          HStack {
            Text(token.isEmpty ? "—" : String(token.prefix(8)) + "…")
              .font(.body.monospaced())
            Button("Copy") { copy(AppSettings.agentServerToken) }
            Button("New Token") { token = AppSettings.makeAgentServerToken() }
              .help("Agents using the old token will have to be set up again.")
          }
        }
      } footer: {
        Text("Only apps on this Mac can connect, and only with the token.")
          .foregroundStyle(.secondary)
      }
      Section {
        LabeledContent("Claude Code") {
          Button("Copy Setup Command") { copy(server.claudeCodeCommand) }
        }
      } footer: {
        Text("Paste the command into Terminal to add Ongaku Studio to Claude Code. Other MCP clients need the address, and the token sent as “Authorization: Bearer <token>”.")
          .foregroundStyle(.secondary)
      }
    }
    .settingsPane()
    .onAppear {
      // Make the token now, so it can be shown and copied.
      if token.isEmpty { token = AppSettings.agentServerToken }
    }
  }

  private var statusText: String {
    switch server.status {
    case .off: "Off"
    case .starting: "Starting…"
    case .failed(let message): message
    case .listening:
      server.clients.isEmpty ? "Ready for agents" : "Connected: \(server.clients.joined(separator: ", "))"
    }
  }

  private var statusIsProblem: Bool {
    if case .failed = server.status { true } else { false }
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

extension View {
  /// A Settings tab: a grouped form that never scrolls, so the window grows to fit the
  /// whole tab instead of showing a scroll bar.
  fileprivate func settingsPane() -> some View {
    formStyle(.grouped)
      .scrollDisabled(true)
      .scrollIndicators(.never)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// A row of the colours imported tracks will get.
private struct TrackColorSwatches: View {
  let colors: [TrackColor]

  var body: some View {
    HStack(spacing: 3) {
      ForEach(colors, id: \.self) { color in
        RoundedRectangle(cornerRadius: 2)
          .fill(color.color)
          .frame(width: 14, height: 10)
      }
    }
    .accessibilityHidden(true)
  }
}

extension TrackColor {
  /// The colour's name, for menus, in US spelling as macOS uses ("Gray").
  var name: String {
    rawValue.capitalized
  }

  /// The colours given in turn to tracks imported with varied colours: every colour except
  /// grey, in rainbow order.
  static var importPalette: [TrackColor] {
    allCases.filter { $0 != .gray }
  }
}

#Preview {
  SettingsView()
}
