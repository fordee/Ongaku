//
//  DAWProject.swift
//  OngakuCore
//

import Foundation

/// DAWproject, the open project format Bitwig started and Studio One, Cubase, Reaper and
/// others read and write: a ZIP of `project.xml` (tracks, mixer, arrangement), `metadata.xml`
/// and the audio and plug-in files they refer to. Positions are in beats.
///
/// What carries over: tracks (instrument, audio, aux, and stacks as group tracks), their
/// fader, pan, mute, solo, sends and outputs, Audio Unit plug-ins with their settings, MIDI
/// and audio regions (with fades, loops and mutes), tempo (with ramps) and time signature
/// changes, markers and arrangement sections, and volume, pan and send automation. What
/// can't (General MIDI and library sounds, MIDI FX, other formats' plug-ins, Flex) is listed
/// as a warning rather than dropped silently.
public enum DAWProject {
  public static let fileExtension = "dawproject"
  static let ticksPerBeat = Double(Tick.perQuarterNote)

  static func beats(_ tick: Tick) -> String { format(Double(tick.rawValue) / ticksPerBeat) }
  static func tick(beats: Double) -> Tick { Tick(Int64((beats * ticksPerBeat).rounded())) }

  static func format(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e12 { return String(format: "%.1f", value) }
    return String(format: "%.6f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
  }

  static func escape(_ text: String) -> String { MusicXML.escape(text) }

  static let colors: [TrackColor: String] = [
    .red: "#e5484d", .orange: "#f5a23d", .yellow: "#f2d548", .green: "#5cc36b", .teal: "#3fc4c4", .blue: "#4c8fe8",
    .purple: "#9b6be8", .pink: "#e86bb4", .gray: "#9a9a9a",
  ]

  /// Four-character codes for Audio Unit device IDs ("aumu:ospl:Ongk").
  static func fourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    return String(decoding: bytes, as: UTF8.self)
  }

  static func code(_ text: Substring) -> UInt32? {
    let bytes = Array(text.utf8)
    guard bytes.count == 4 else { return UInt32(text) }
    return bytes.reduce(0) { $0 << 8 | UInt32($1) }
  }
}

// MARK: - Export

extension DAWProject {
  public struct Export: Sendable {
    public var entries: [ZipArchive.Entry]
    public var warnings: [String]
  }

  /// A project as a DAWproject's files. `audioData` reads an audio file; `pluginState`
  /// gives a plug-in's saved settings (as an .aupreset property list).
  public static func export(
    _ project: Project, title: String, audioData: @escaping (AudioFileReference) -> Data?,
    pluginState: @escaping (PluginReference) -> Data?
  ) -> Export {
    var writer = Writer(project: project, audioData: audioData, pluginState: pluginState)
    let xml = writer.projectXML()
    let metadata = """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <MetaData>
        <Title>\(escape(title))</Title>
        <Comment>Made with Ongaku Studio</Comment>
      </MetaData>

      """
    return Export(
      entries: [ZipArchive.Entry(path: "project.xml", data: Data(xml.utf8)), ZipArchive.Entry(path: "metadata.xml", data: Data(metadata.utf8))]
        + writer.files,
      warnings: writer.warnings)
  }

  private struct Writer {
    let project: Project
    let audioData: (AudioFileReference) -> Data?
    let pluginState: (PluginReference) -> Data?
    var files: [ZipArchive.Entry] = []
    var warnings: [String] = []
    private var nextID = 0
    /// Each track's channel, and the parameters automation points at.
    private var channelIDs: [Track.ID: String] = [:]
    private var volumeIDs: [Track.ID: String] = [:]
    private var panIDs: [Track.ID: String] = [:]
    private var sendIDs: [Send.ID: String] = [:]
    private var trackIDs: [Track.ID: String] = [:]
    private var writtenAudio: [AudioFileReference.ID: String] = [:]

    init(project: Project, audioData: @escaping (AudioFileReference) -> Data?, pluginState: @escaping (PluginReference) -> Data?) {
      self.project = project
      self.audioData = audioData
      self.pluginState = pluginState
    }

    mutating func id() -> String {
      nextID += 1
      return "id\(nextID)"
    }

    mutating func projectXML() -> String {
      let tempoID = id(), signatureID = id(), masterID = id(), masterChannelID = id()
      for track in project.tracks {
        trackIDs[track.id] = id()
        channelIDs[track.id] = id()
        volumeIDs[track.id] = id()
        panIDs[track.id] = id()
        for send in track.channel.sends { sendIDs[send.id] = id() }
      }
      let firstTempo = project.tempoMap.tempoChanges.first?.bpm ?? 120
      let firstSignature = project.tempoMap.meterChanges.first?.signature ?? .fourFour
      var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Project version="1.0">
          <Application name="Ongaku Studio" version="1.2"/>
          <Transport>
            <Tempo id="\(tempoID)" name="Tempo" unit="bpm" min="20.0" max="666.0" value="\(DAWProject.format(firstTempo))"/>
            <TimeSignature id="\(signatureID)" numerator="\(firstSignature.beatsPerBar)" denominator="\(firstSignature.beatUnit)"/>
          </Transport>
          <Structure>

        """
      // Top-level tracks, each stack with its subtracks inside it.
      for track in project.tracks where track.stackID == nil {
        xml += trackXML(track, masterChannelID: masterChannelID, indent: "    ")
      }
      xml += """
            <Track id="\(masterID)" name="Stereo Out" contentType="audio notes" loaded="true">
              <Channel id="\(masterChannelID)" role="master" audioChannels="2" solo="false">

        """
      xml += devicesXML(project.stereoOutInserts.map { ($0, "audioFX") }, indent: "        ")
      xml += parameters(volume: project.masterVolume, pan: 0, isMuted: false, volumeID: id(), panID: id(), indent: "        ")
      xml += "      </Channel>\n    </Track>\n  </Structure>\n"
      xml += arrangementXML(tempoID: tempoID, signatureID: signatureID)
      xml += "</Project>\n"
      return xml
    }

    // MARK: Structure

    mutating func trackXML(_ track: Track, masterChannelID: String, indent: String) -> String {
      let trackID = trackIDs[track.id]!, channelID = channelIDs[track.id]!
      let contentType = track.isStack ? "tracks" : track.kind == .softwareInstrument ? "notes" : "audio"
      let role = track.isStack ? "submix" : track.kind == .aux ? "effect" : "regular"
      let destination = destinationID(for: track, master: masterChannelID)
      var xml = "\(indent)<Track id=\"\(trackID)\" name=\"\(escape(track.name))\" color=\"\(DAWProject.colors[track.color] ?? "#9a9a9a")\" contentType=\"\(contentType)\" loaded=\"true\">\n"
      xml += "\(indent)  <Channel id=\"\(channelID)\" role=\"\(role)\" audioChannels=\"2\" solo=\"\(track.channel.isSoloed)\" destination=\"\(destination)\">\n"
      // The instrument, MIDI effects and inserts.
      var devices: [(PluginReference, String)] = []
      switch track.channel.instrument {
      case .audioUnit(let plugin): devices.append((plugin, "instrument"))
      case .generalMIDI, .generalMIDIPercussion:
        warnings.append("“\(track.name)” plays a General MIDI sound, which other apps don't have: choose an instrument there.")
      case .sampler(let instrument):
        warnings.append("“\(track.name)” plays “\(instrument.name)” from a sound library, which doesn't go with the project: choose an instrument there.")
      case nil: break
      }
      if !track.channel.midiEffects.isEmpty {
        warnings.append("“\(track.name)”'s Ongaku MIDI FX don't carry over (other apps don't have them).")
      }
      devices += track.channel.inserts.map { ($0, "audioFX") }
      xml += devicesXML(devices, indent: indent + "    ")
      xml += parameters(
        volume: track.channel.volume, pan: track.channel.pan, isMuted: track.channel.isMuted, volumeID: volumeIDs[track.id]!,
        panID: panIDs[track.id]!, indent: indent + "    ")
      let sends = track.channel.sends.filter { channelIDs[$0.destinationTrackID] != nil }
      if !sends.isEmpty {
        xml += "\(indent)    <Sends>\n"
        for send in sends {
          xml += "\(indent)      <Send id=\"\(id())\" destination=\"\(channelIDs[send.destinationTrackID]!)\" type=\"\(send.isPreFader ? "pre" : "post")\">\n"
          xml += "\(indent)        <Volume id=\"\(sendIDs[send.id]!)\" name=\"Send\" unit=\"linear\" min=\"0.0\" max=\"2.0\" value=\"\(DAWProject.format(send.linearGain))\"/>\n"
          xml += "\(indent)      </Send>\n"
        }
        xml += "\(indent)    </Sends>\n"
      }
      xml += "\(indent)  </Channel>\n"
      if track.isStack {
        for subtrack in project.tracks where subtrack.stackID == track.id {
          xml += trackXML(subtrack, masterChannelID: masterChannelID, indent: indent + "  ")
        }
      }
      return xml + "\(indent)</Track>\n"
    }

    /// Where a track's sound goes: its stack (for a summing stack), the track its output
    /// names, or Stereo Out.
    func destinationID(for track: Track, master: String) -> String {
      if let stackID = track.stackID, let stack = project.tracks.first(where: { $0.id == stackID }), stack.isSummingStack,
        let channel = channelIDs[stackID]
      {
        return channel
      }
      if case .track(let id) = track.channel.output, let channel = channelIDs[id] { return channel }
      return master
    }

    func parameters(volume: Double, pan: Double, isMuted: Bool, volumeID: String, panID: String, indent: String) -> String {
      let gain = volume <= ChannelStrip.volumeRange.lowerBound ? 0 : pow(10, volume / 20)
      return """
        \(indent)<Mute id="\(volumeID)m" name="Mute" value="\(isMuted)"/>
        \(indent)<Pan id="\(panID)" name="Pan" unit="normalized" min="0.0" max="1.0" value="\(DAWProject.format((pan + 1) / 2))"/>
        \(indent)<Volume id="\(volumeID)" name="Volume" unit="linear" min="0.0" max="2.0" value="\(DAWProject.format(gain))"/>

        """
    }

    mutating func devicesXML(_ devices: [(PluginReference, String)], indent: String) -> String {
      guard !devices.isEmpty else { return "" }
      var xml = "\(indent)<Devices>\n"
      for (plugin, role) in devices {
        let deviceID = [plugin.componentType, plugin.componentSubType, plugin.componentManufacturer].map(DAWProject.fourCC).joined(separator: ":")
        xml += "\(indent)  <AuPlugin id=\"\(id())\" name=\"\(escape(plugin.name))\" deviceID=\"\(escape(deviceID))\" deviceName=\"\(escape(plugin.name))\" deviceRole=\"\(role)\" loaded=\"true\">\n"
        xml += "\(indent)    <Enabled id=\"\(id())\" name=\"On/Off\" value=\"\(!plugin.isBypassed)\"/>\n"
        if let state = pluginState(plugin) {
          let path = "plugins/\(plugin.id.uuidString).aupreset"
          files.append(ZipArchive.Entry(path: path, data: state))
          xml += "\(indent)    <State path=\"\(path)\"/>\n"
        }
        xml += "\(indent)  </AuPlugin>\n"
      }
      return xml + "\(indent)</Devices>\n"
    }

    // MARK: Arrangement

    mutating func arrangementXML(tempoID: String, signatureID: String) -> String {
      var xml = "  <Arrangement id=\"\(id())\">\n"
      let tempos = project.tempoMap.tempoChanges
      if tempos.count > 1 || tempos.contains(where: \.rampsToNext) {
        xml += "    <TempoAutomation id=\"\(id())\" unit=\"bpm\">\n      <Target parameter=\"\(tempoID)\"/>\n"
        for change in tempos {
          xml += "      <RealPoint time=\"\(DAWProject.beats(change.position))\" value=\"\(DAWProject.format(change.bpm))\" interpolation=\"\(change.rampsToNext ? "linear" : "hold")\"/>\n"
        }
        xml += "    </TempoAutomation>\n"
      }
      let meters = project.tempoMap.meterChanges
      if meters.count > 1 {
        xml += "    <TimeSignatureAutomation id=\"\(id())\">\n      <Target parameter=\"\(signatureID)\"/>\n"
        for change in meters {
          let position = project.tempoMap.tickPosition(ofBarIndex: change.barIndex)
          xml += "      <TimeSignaturePoint time=\"\(DAWProject.beats(position))\" numerator=\"\(change.signature.beatsPerBar)\" denominator=\"\(change.signature.beatUnit)\"/>\n"
        }
        xml += "    </TimeSignatureAutomation>\n"
      }
      let markers = project.markers.map { ($0.position, $0.name) } + project.arrangement.map { ($0.start, $0.name) }
      if !markers.isEmpty {
        xml += "    <Markers id=\"\(id())\">\n"
        for (position, name) in markers.sorted(by: { $0.0 < $1.0 }) {
          xml += "      <Marker id=\"\(id())\" time=\"\(DAWProject.beats(position))\" name=\"\(escape(name))\"/>\n"
        }
        xml += "    </Markers>\n"
      }
      xml += "    <Lanes id=\"\(id())\" timeUnit=\"beats\">\n"
      for track in project.tracks where !track.regions.isEmpty || !track.automation.isEmpty {
        xml += "      <Lanes id=\"\(id())\" track=\"\(trackIDs[track.id]!)\">\n"
        if !track.regions.isEmpty {
          xml += "        <Clips id=\"\(id())\">\n"
          for region in track.regions { xml += clipXML(region, track: track, indent: "          ") }
          xml += "        </Clips>\n"
        }
        xml += automationXML(track, indent: "        ")
        xml += "      </Lanes>\n"
      }
      xml += "    </Lanes>\n  </Arrangement>\n"
      return xml
    }

    mutating func clipXML(_ region: Region, track: Track, indent: String) -> String {
      let duration = region.isLooped ? (region.loopedLength ?? region.length) : region.length
      var attributes = "id=\"\(id())\" name=\"\(escape(region.name))\" time=\"\(DAWProject.beats(region.start))\" duration=\"\(DAWProject.beats(duration))\""
      if region.isMuted { attributes += " enable=\"false\"" }
      switch region.content {
      case .midi(let sequence):
        _ = sequence
        attributes += " playStart=\"0.0\""
        if region.isLooped { attributes += " loopStart=\"0.0\" loopEnd=\"\(DAWProject.beats(region.length))\"" }
        var xml = "\(indent)<Clip \(attributes)>\n\(indent)  <Notes id=\"\(id())\">\n"
        for note in region.playedNotes where !note.isMuted {
          let velocity = DAWProject.format(Double(note.velocity) / 127)
          xml += "\(indent)    <Note time=\"\(DAWProject.beats(note.start))\" duration=\"\(DAWProject.beats(note.length))\" channel=\"\(note.channel)\" key=\"\(note.pitch)\" vel=\"\(velocity)\" rel=\"\(velocity)\"/>\n"
        }
        return xml + "\(indent)  </Notes>\n\(indent)</Clip>\n"
      case .audio(let content):
        guard let file = project.audioFiles.first(where: { $0.id == content.fileID }), let path = audioPath(for: file) else {
          warnings.append("An audio file of “\(track.name)” couldn't be read, so its region was left out.")
          return ""
        }
        if content.gain != 0 { warnings.append("Region gain on “\(region.name)” doesn't carry over (DAWproject clips have none).") }
        if !content.flexMarkers.isEmpty || !content.pitchEdits.isEmpty || content.stretch != 1 || region.transpose != 0 {
          warnings.append("“\(region.name)” is flexed, stretched or transposed: it's exported as recorded.")
        }
        let offset = Double(content.fileStartFrame) / file.sampleRate
        attributes += " contentTimeUnit=\"seconds\" playStart=\"\(DAWProject.format(offset))\""
        attributes += " fadeTimeUnit=\"seconds\" fadeInTime=\"\(DAWProject.format(content.fadeIn))\" fadeOutTime=\"\(DAWProject.format(content.fadeOut))\""
        if region.isLooped {
          let loopSeconds = project.tempoMap.seconds(at: region.start + region.length) - project.tempoMap.seconds(at: region.start)
          attributes += " loopStart=\"\(DAWProject.format(offset))\" loopEnd=\"\(DAWProject.format(offset + loopSeconds))\""
        }
        let seconds = Double(file.frameCount) / file.sampleRate
        return """
          \(indent)<Clip \(attributes)>
          \(indent)  <Audio id="\(id())" channels="\(file.channelCount)" sampleRate="\(Int(file.sampleRate))" duration="\(DAWProject.format(seconds))">
          \(indent)    <File path="\(escape(path))"/>
          \(indent)  </Audio>
          \(indent)</Clip>

          """
      }
    }

    /// Puts an audio file in the archive (once) and gives its path there.
    mutating func audioPath(for file: AudioFileReference) -> String? {
      if let path = writtenAudio[file.id] { return path }
      guard let data = audioData(file) else { return nil }
      var name = file.fileName
      if files.contains(where: { $0.path == "audio/\(name)" }) { name = "\(file.id.uuidString)-\(name)" }
      let path = "audio/\(name)"
      files.append(ZipArchive.Entry(path: path, data: data))
      writtenAudio[file.id] = path
      return path
    }

    mutating func automationXML(_ track: Track, indent: String) -> String {
      var xml = ""
      for lane in track.automation where !lane.points.isEmpty {
        let target: String, unit: String
        let convert: (Double) -> Double
        switch lane.parameter {
        case .volume:
          (target, unit) = (volumeIDs[track.id]!, "linear")
          convert = { $0 <= ChannelStrip.volumeRange.lowerBound ? 0 : pow(10, $0 / 20) }
        case .pan:
          (target, unit) = (panIDs[track.id]!, "normalized")
          convert = { ($0 + 1) / 2 }
        case .sendLevel(let sendID):
          guard let id = sendIDs[sendID] else { continue }
          (target, unit) = (id, "linear")
          convert = { $0 <= Send.levelRange.lowerBound ? 0 : pow(10, $0 / 20) }
        case .plugin(let parameter):
          warnings.append("Automation of “\(parameter.name)” on “\(track.name)” doesn't carry over (only volume, pan and sends do).")
          continue
        }
        xml += "\(indent)<Points id=\"\(id())\" unit=\"\(unit)\">\n\(indent)  <Target parameter=\"\(target)\"/>\n"
        for point in lane.points {
          xml += "\(indent)  <RealPoint time=\"\(DAWProject.beats(point.position))\" value=\"\(DAWProject.format(convert(point.value)))\" interpolation=\"linear\"/>\n"
        }
        xml += "\(indent)</Points>\n"
      }
      return xml
    }
  }
}

// MARK: - Import

extension DAWProject {
  public enum ImportError: LocalizedError {
    case noProject

    public var errorDescription: String? { "The file has no project.xml: it isn't a DAWproject." }
  }

  /// A DAWproject read into a song. Its audio regions refer to `audioFiles` by ID; the app
  /// copies each file's data into the song and swaps in the copies' references.
  public struct Import: Sendable {
    public var project: Project
    public var audioFiles: [AudioFile]
    public var warnings: [String]
    public var title: String?

    public struct AudioFile: Sendable {
      public var reference: AudioFileReference
      public var data: Data
    }
  }

  public static func read(_ entries: [ZipArchive.Entry]) throws -> Import {
    guard let projectEntry = entries.first(where: { $0.path == "project.xml" }) else { throw ImportError.noProject }
    let document = try XMLDocument(data: projectEntry.data, options: [])
    let files = Dictionary(entries.map { ($0.path, $0.data) }, uniquingKeysWith: { first, _ in first })
    var reader = Reader(files: files)
    try reader.read(document)
    var title: String?
    if let metadata = entries.first(where: { $0.path == "metadata.xml" }),
      let meta = try? XMLDocument(data: metadata.data, options: []),
      let text = try? meta.nodes(forXPath: "//Title").first?.stringValue, !text.isEmpty
    {
      title = text
    }
    return Import(project: reader.project, audioFiles: reader.audioFiles, warnings: reader.warnings, title: title)
  }

  private struct Reader {
    let files: [String: Data]
    var project = Project()
    var audioFiles: [Import.AudioFile] = []
    var warnings: [String] = []
    /// What each id in the file is, once read.
    private var tracksByID: [String: Track.ID] = [:]
    private var tracksByChannel: [String: Track.ID] = [:]
    private var masterChannel: String?
    private enum Target { case volume(Track.ID), pan(Track.ID), send(Track.ID, Send.ID), masterVolume }
    private var targets: [String: Target] = [:]
    private var pendingSends: [(track: Track.ID, send: Send.ID, destination: String, level: Double, pre: Bool)] = []
    private var pendingOutputs: [(track: Track.ID, destination: String)] = []
    private var audioByPath: [String: AudioFileReference] = [:]

    init(files: [String: Data]) {
      self.files = files
      project.tracks = []
      project.audioFiles = []
    }

    static func attribute(_ element: XMLElement, _ name: String) -> String? { element.attribute(forName: name)?.stringValue }
    static func double(_ element: XMLElement, _ name: String) -> Double? { attribute(element, name).flatMap(Double.init) }
    static func children(_ element: XMLElement, _ name: String) -> [XMLElement] { element.elements(forName: name) }

    mutating func read(_ document: XMLDocument) throws {
      guard let root = document.rootElement() else { throw ImportError.noProject }
      // Transport.
      if let transport = Self.children(root, "Transport").first {
        if let tempo = Self.children(transport, "Tempo").first, let bpm = Self.double(tempo, "value") {
          try? project.tempoMap.setTempo(min(max(bpm, TempoMap.bpmRange.lowerBound), TempoMap.bpmRange.upperBound))
        }
        if let signature = Self.children(transport, "TimeSignature").first,
          let numerator = Self.attribute(signature, "numerator").flatMap(Int.init),
          let denominator = Self.attribute(signature, "denominator").flatMap(Int.init)
        {
          try? project.tempoMap.setTimeSignature(TimeSignature(beatsPerBar: numerator, beatUnit: denominator), atBarIndex: 0)
        }
      }
      // Tracks, then the arrangement (which refers to them).
      if let structure = Self.children(root, "Structure").first {
        for element in Self.children(structure, "Track") { readTrack(element, stack: nil) }
        for element in Self.children(structure, "Channel") { readMasterChannel(element) }
      }
      resolveRouting()
      if let arrangement = Self.children(root, "Arrangement").first { readArrangement(arrangement) }
      if !Self.children(root, "Scenes").isEmpty, (try? root.nodes(forXPath: "Scenes//Clip").isEmpty) == false {
        warnings.append("The project's clip launcher scenes aren't imported, only its arrangement.")
      }
      project.extendEndPastContent()
    }

    // MARK: Tracks

    mutating func readTrack(_ element: XMLElement, stack: Track.ID?) {
      let name = Self.attribute(element, "name") ?? "Track"
      let contentType = Self.attribute(element, "contentType") ?? ""
      let channel = Self.children(element, "Channel").first
      let role = channel.flatMap { Self.attribute($0, "role") } ?? "regular"
      let nested = Self.children(element, "Track")
      if role == "master" {
        if let channel { readMasterChannel(channel) }
        return
      }
      let kind: TrackKind
      if !nested.isEmpty || contentType == "tracks" || role == "submix" {
        kind = .aux
      } else if role == "effect" {
        kind = .aux
      } else if contentType.split(separator: " ").contains("notes") {
        kind = .softwareInstrument
      } else {
        kind = .audio
      }
      var track = Track(name: name, kind: kind, color: color(Self.attribute(element, "color")))
      track.channel = ChannelStrip(audioInput: kind == .audio ? .defaultInput : nil)
      track.stackID = stack
      let isStack = !nested.isEmpty || contentType == "tracks"
      if isStack { track.isSummingStack = true }
      if let id = Self.attribute(element, "id") { tracksByID[id] = track.id }
      if let channel { readChannel(channel, into: &track) }
      project.tracks.append(track)
      for child in nested { readTrack(child, stack: track.id) }
    }

    mutating func readChannel(_ channel: XMLElement, into track: inout Track) {
      if let id = Self.attribute(channel, "id") { tracksByChannel[id] = track.id }
      track.channel.isSoloed = Self.attribute(channel, "solo") == "true"
      if let volume = Self.children(channel, "Volume").first {
        track.channel.volume = decibels(Self.double(volume, "value") ?? 1)
        if let id = Self.attribute(volume, "id") { targets[id] = .volume(track.id) }
      }
      if let pan = Self.children(channel, "Pan").first {
        track.channel.pan = min(1, max(-1, (Self.double(pan, "value") ?? 0.5) * 2 - 1))
        if let id = Self.attribute(pan, "id") { targets[id] = .pan(track.id) }
      }
      if let mute = Self.children(channel, "Mute").first { track.channel.isMuted = Self.attribute(mute, "value") == "true" }
      if let destination = Self.attribute(channel, "destination") { pendingOutputs.append((track.id, destination)) }
      for send in Self.children(channel, "Sends").flatMap({ Self.children($0, "Send") }) {
        guard let destination = Self.attribute(send, "destination") else { continue }
        let volume = Self.children(send, "Volume").first
        let sendID = UUID()
        if let id = volume.flatMap({ Self.attribute($0, "id") }) { targets[id] = .send(track.id, sendID) }
        pendingSends.append((track.id, sendID, destination, decibels(volume.flatMap { Self.double($0, "value") } ?? 1), Self.attribute(send, "type") == "pre"))
      }
      // Plug-ins: Audio Units come back with their settings; others are named in a warning.
      var instrument: PluginReference?
      for devices in Self.children(channel, "Devices") {
        for device in devices.children?.compactMap({ $0 as? XMLElement }) ?? [] {
          let name = Self.attribute(device, "name") ?? Self.attribute(device, "deviceName") ?? device.name ?? "Plug-in"
          let role = Self.attribute(device, "deviceRole") ?? "audioFX"
          guard device.name == "AuPlugin", let plugin = audioUnit(device, name: name) else {
            let format = device.name?.replacingOccurrences(of: "Plugin", with: "") ?? "Unknown"
            warnings.append("“\(name)” on “\(track.name)” is a \(format) plug-in or a built-in device of another app, which Ongaku Studio can't load.")
            continue
          }
          switch role {
          case "instrument": instrument = plugin
          case "noteFX": warnings.append("The MIDI effect “\(name)” on “\(track.name)” wasn't loaded (Ongaku hosts MIDI FX plug-ins, but not from DAWproject yet).")
          default: track.channel.inserts.append(plugin)
          }
        }
      }
      if track.kind == .softwareInstrument {
        track.channel.instrument = instrument.map { .audioUnit($0) } ?? .defaultSampler
      }
    }

    mutating func readMasterChannel(_ channel: XMLElement) {
      masterChannel = Self.attribute(channel, "id")
      if let volume = Self.children(channel, "Volume").first {
        project.masterVolume = decibels(Self.double(volume, "value") ?? 1)
        if let id = Self.attribute(volume, "id") { targets[id] = .masterVolume }
      }
      for devices in Self.children(channel, "Devices") {
        for device in devices.children?.compactMap({ $0 as? XMLElement }) ?? [] {
          let name = Self.attribute(device, "name") ?? "Plug-in"
          if device.name == "AuPlugin", let plugin = audioUnit(device, name: name) {
            project.stereoOutInserts.append(plugin)
          } else {
            warnings.append("“\(name)” on the master channel couldn't be loaded.")
          }
        }
      }
    }

    func audioUnit(_ device: XMLElement, name: String) -> PluginReference? {
      guard let deviceID = Self.attribute(device, "deviceID") else { return nil }
      let parts = deviceID.split(separator: ":")
      guard parts.count == 3, let type = DAWProject.code(parts[0]), let subtype = DAWProject.code(parts[1]),
        let manufacturer = DAWProject.code(parts[2])
      else { return nil }
      var plugin = PluginReference(componentType: type, componentSubType: subtype, componentManufacturer: manufacturer, name: name)
      if let enabled = Self.children(device, "Enabled").first { plugin.isBypassed = Self.attribute(enabled, "value") == "false" }
      if let path = Self.children(device, "State").first.flatMap({ Self.attribute($0, "path") }) { plugin.state = files[path] }
      return plugin
    }

    /// Sends and outputs, now every channel is known.
    mutating func resolveRouting() {
      for (trackID, sendID, destination, level, pre) in pendingSends {
        guard let target = tracksByChannel[destination], let index = project.tracks.firstIndex(where: { $0.id == trackID }) else { continue }
        project.tracks[index].channel.sends.append(Send(id: sendID, destinationTrackID: target, level: max(Send.levelRange.lowerBound, level), isPreFader: pre))
      }
      for (trackID, destination) in pendingOutputs {
        guard let index = project.tracks.firstIndex(where: { $0.id == trackID }) else { continue }
        if destination == masterChannel { continue }
        guard let target = tracksByChannel[destination] else { continue }
        // A summing stack's own subtracks feed it already.
        if project.tracks[index].stackID == target { continue }
        project.tracks[index].channel.output = .track(target)
      }
    }

    func decibels(_ gain: Double) -> Double {
      gain <= 0 ? ChannelStrip.volumeRange.lowerBound : min(ChannelStrip.volumeRange.upperBound, max(ChannelStrip.volumeRange.lowerBound, 20 * log10(gain)))
    }

    func color(_ hex: String?) -> TrackColor? {
      guard let hex, hex.hasPrefix("#"), hex.count >= 7, let value = UInt32(hex.dropFirst().prefix(6), radix: 16) else { return nil }
      let (red, green, blue) = (Double(value >> 16 & 0xFF), Double(value >> 8 & 0xFF), Double(value & 0xFF))
      return DAWProject.colors.min { first, second in
        distance(first.value, red, green, blue) < distance(second.value, red, green, blue)
      }?.key
      func distance(_ candidate: String, _ r: Double, _ g: Double, _ b: Double) -> Double {
        let value = UInt32(candidate.dropFirst(), radix: 16) ?? 0
        let (cr, cg, cb) = (Double(value >> 16 & 0xFF), Double(value >> 8 & 0xFF), Double(value & 0xFF))
        return (cr - r) * (cr - r) + (cg - g) * (cg - g) + (cb - b) * (cb - b)
      }
    }

    // MARK: Arrangement

    mutating func readArrangement(_ arrangement: XMLElement) {
      // Tempo and meter changes.
      if let tempo = Self.children(arrangement, "TempoAutomation").first {
        let points = Self.children(tempo, "RealPoint").compactMap { point -> (Double, Double, Bool)? in
          guard let time = Self.double(point, "time"), let value = Self.double(point, "value") else { return nil }
          return (time, value, Self.attribute(point, "interpolation") == "linear")
        }
        for (time, value, ramps) in points {
          let position = DAWProject.tick(beats: time)
          try? project.tempoMap.setTempo(min(max(value, TempoMap.bpmRange.lowerBound), TempoMap.bpmRange.upperBound), at: position)
          if ramps { project.tempoMap.setRamp(true, at: position) }
        }
      }
      if let signatures = Self.children(arrangement, "TimeSignatureAutomation").first {
        for point in Self.children(signatures, "TimeSignaturePoint") {
          guard let time = Self.double(point, "time"), let numerator = Self.attribute(point, "numerator").flatMap(Int.init),
            let denominator = Self.attribute(point, "denominator").flatMap(Int.init)
          else { continue }
          let bar = project.tempoMap.bar(containing: DAWProject.tick(beats: time))
          try? project.tempoMap.setTimeSignature(TimeSignature(beatsPerBar: numerator, beatUnit: denominator), atBarIndex: bar.index)
        }
      }
      for markers in Self.children(arrangement, "Markers") {
        for marker in Self.children(markers, "Marker") {
          guard let time = Self.double(marker, "time") else { continue }
          project.markers.append(Marker(name: Self.attribute(marker, "name") ?? "Marker", position: DAWProject.tick(beats: time)))
        }
      }
      for lanes in Self.children(arrangement, "Lanes") { readLanes(lanes, track: nil, timeUnit: Self.attribute(lanes, "timeUnit") ?? "beats") }
    }

    mutating func readLanes(_ lanes: XMLElement, track: Track.ID?, timeUnit: String) {
      let track = Self.attribute(lanes, "track").flatMap { tracksByID[$0] } ?? track
      let unit = Self.attribute(lanes, "timeUnit") ?? timeUnit
      if unit == "seconds" { warnings.append("Some lanes are timed in seconds; they were read as if in beats.") }
      for child in lanes.children?.compactMap({ $0 as? XMLElement }) ?? [] {
        switch child.name {
        case "Lanes": readLanes(child, track: track, timeUnit: unit)
        case "Clips":
          guard let track else { continue }
          for clip in Self.children(child, "Clip") { readClip(clip, track: track) }
        case "Points": readPoints(child)
        default: continue
        }
      }
    }

    mutating func readClip(_ clip: XMLElement, track trackID: Track.ID) {
      guard let index = project.tracks.firstIndex(where: { $0.id == trackID }), let time = Self.double(clip, "time"),
        let duration = Self.double(clip, "duration"), duration > 0
      else { return }
      let name = Self.attribute(clip, "name") ?? project.tracks[index].name
      let start = DAWProject.tick(beats: time)
      let loopStart = Self.double(clip, "loopStart"), loopEnd = Self.double(clip, "loopEnd")
      let isMuted = Self.attribute(clip, "enable") == "false"
      let playStart = Self.double(clip, "playStart") ?? 0
      if let notes = descendant(clip, "Notes") {
        guard project.tracks[index].kind == .softwareInstrument else { return }
        var midiNotes: [MIDINote] = []
        for note in Self.children(notes, "Note") {
          guard let noteTime = Self.double(note, "time"), let length = Self.double(note, "duration"),
            let key = Self.attribute(note, "key").flatMap(Int.init), MIDINote.pitchRange.contains(key)
          else { continue }
          let velocity = Int(((Self.double(note, "vel") ?? 0.8) * 127).rounded())
          let relative = noteTime - playStart
          guard relative >= 0 else { continue }
          midiNotes.append(MIDINote(
            pitch: key, velocity: min(127, max(1, velocity)), channel: min(15, max(0, Self.attribute(note, "channel").flatMap(Int.init) ?? 0)),
            start: DAWProject.tick(beats: relative), length: max(Tick(1), DAWProject.tick(beats: length))))
        }
        var region = Region(name: name, start: start, length: DAWProject.tick(beats: duration), content: .midi(MIDISequence(notes: midiNotes)))
        if let loopStart, let loopEnd, loopEnd > loopStart, loopEnd - loopStart < duration - 1e-6 {
          region.length = DAWProject.tick(beats: loopEnd - loopStart)
          region.isLooped = true
          region.loopedLength = DAWProject.tick(beats: duration)
        }
        region.isMuted = isMuted
        project.tracks[index].regions.append(region)
      } else if let audio = descendant(clip, "Audio") {
        guard project.tracks[index].kind == .audio,
          let path = Self.children(audio, "File").first.flatMap({ Self.attribute($0, "path") })
        else { return }
        guard let reference = audioFile(path, audio: audio) else {
          warnings.append("The audio file “\(path)” isn't in the project, so its clip was left out.")
          return
        }
        if descendant(clip, "Warps") != nil {
          warnings.append("“\(name)” is warped in the original; it plays at its recorded speed here.")
        }
        let contentUnit = Self.attribute(clip, "contentTimeUnit") ?? "beats"
        let offsetSeconds = contentUnit == "seconds" ? playStart : project.tempoMap.seconds(at: DAWProject.tick(beats: playStart))
        let fadeUnit = Self.attribute(clip, "fadeTimeUnit") ?? "beats"
        func fadeSeconds(_ value: Double?) -> Double {
          guard let value else { return 0 }
          return fadeUnit == "seconds" ? value : project.tempoMap.seconds(at: start + DAWProject.tick(beats: value)) - project.tempoMap.seconds(at: start)
        }
        var content = AudioRegionContent(
          fileID: reference.id, fileStartFrame: Int64(max(0, offsetSeconds) * reference.sampleRate),
          fadeIn: fadeSeconds(Self.double(clip, "fadeInTime")), fadeOut: fadeSeconds(Self.double(clip, "fadeOutTime")))
        content.gain = 0
        var region = Region(name: name, start: start, length: DAWProject.tick(beats: duration), content: .audio(content))
        region.isMuted = isMuted
        project.tracks[index].regions.append(region)
      }
      project.tracks[index].regions.sort { $0.start < $1.start }
    }

    func descendant(_ element: XMLElement, _ name: String) -> XMLElement? {
      for child in element.children?.compactMap({ $0 as? XMLElement }) ?? [] {
        if child.name == name { return child }
        if let found = descendant(child, name) { return found }
      }
      return nil
    }

    mutating func audioFile(_ path: String, audio: XMLElement) -> AudioFileReference? {
      if let existing = audioByPath[path] { return existing }
      guard let data = files[path] else { return nil }
      let sampleRate = Self.double(audio, "sampleRate") ?? 44_100
      let reference = AudioFileReference(
        fileName: (path as NSString).lastPathComponent, sampleRate: sampleRate,
        channelCount: Self.attribute(audio, "channels").flatMap(Int.init) ?? 2,
        frameCount: Int64((Self.double(audio, "duration") ?? 0) * sampleRate))
      audioByPath[path] = reference
      audioFiles.append(Import.AudioFile(reference: reference, data: data))
      project.audioFiles.append(reference)
      return reference
    }

    mutating func readPoints(_ points: XMLElement) {
      guard let parameter = Self.children(points, "Target").first.flatMap({ Self.attribute($0, "parameter") }),
        let target = targets[parameter]
      else { return }
      let values = Self.children(points, "RealPoint").compactMap { point -> (Tick, Double)? in
        guard let time = Self.double(point, "time"), let value = Self.double(point, "value") else { return nil }
        return (DAWProject.tick(beats: time), value)
      }
      guard !values.isEmpty else { return }
      let lane: (Track.ID, AutomationLane)
      switch target {
      case .volume(let track):
        lane = (track, AutomationLane(parameter: .volume, points: values.map { AutomationPoint(position: $0.0, value: decibels($0.1)) }))
      case .pan(let track):
        lane = (track, AutomationLane(parameter: .pan, points: values.map { AutomationPoint(position: $0.0, value: min(1, max(-1, $0.1 * 2 - 1))) }))
      case .send(let track, let send):
        lane = (track, AutomationLane(
          parameter: .sendLevel(send),
          points: values.map { AutomationPoint(position: $0.0, value: max(Send.levelRange.lowerBound, decibels($0.1))) }))
      case .masterVolume:
        warnings.append("Master volume automation isn't imported.")
        return
      }
      if let index = project.tracks.firstIndex(where: { $0.id == lane.0 }) { project.tracks[index].automation.append(lane.1) }
    }
  }
}

extension Project {
  /// The project with its audio regions (and audio file list) pointing at other files: for
  /// imports, once each file has been copied into the song.
  public func replacingAudioFiles(_ replacements: [AudioFileReference.ID: AudioFileReference]) -> Project {
    var project = self
    project.audioFiles = audioFiles.map { replacements[$0.id] ?? $0 }
    for trackIndex in project.tracks.indices {
      for regionIndex in project.tracks[trackIndex].regions.indices {
        guard case .audio(var content) = project.tracks[trackIndex].regions[regionIndex].content,
          let replacement = replacements[content.fileID]
        else { continue }
        content.fileID = replacement.id
        project.tracks[trackIndex].regions[regionIndex].content = .audio(content)
      }
    }
    return project
  }
}
