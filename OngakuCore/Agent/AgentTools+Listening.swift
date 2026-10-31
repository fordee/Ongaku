//
//  AgentTools+Listening.swift
//  OngakuCore
//

import Foundation

/// Tools that let an agent "hear" the mix: measure it against a finished master's balance,
/// bounce it to a file, and master it.
extension AgentToolbox {
  static let listeningTools: [AgentTool] = [analyzeMix, bounce, masterSong]

  private static let rangeProperties: [String: AgentValue] = [
    "from": Schema.position("Where to start; the start of the song if left out."),
    "to": Schema.position("Where to stop; the end of the last region if left out."),
  ]

  static let analyzeMix = AgentTool(
    name: "analyze_mix", title: "Analyze Mix",
    description: """
      Renders the mix (faster than real time, plug-ins and automation included) and measures \
      it, since you can't listen: loudness (LUFS), peaks, how far peaks stand above the \
      loudness, the stereo width, and the octave-band balance against a typical finished \
      master, for the whole song and each arrangement section, with notes on what stands \
      out. Use it after mixing changes, and to compare sections.
      """,
    properties: rangeProperties, isReadOnly: true
  ) { arguments, session in
    let project = session.project
    let range = try AgentListening.range(arguments, in: project)
    let audio = try await session.renderMix(range)
    let blocks = MixMeasurement.blocks(left: audio.left, right: audio.right, sampleRate: audio.sampleRate)
    guard !blocks.isEmpty else { throw AgentError.notPossible("The mix is too short to measure.") }
    let whole = MixMeasurement.summary(of: blocks)
    var result: [String: AgentValue] = [
      "from": AgentNotation.format(range.lowerBound, tempoMap: project.tempoMap),
      "to": AgentNotation.format(range.upperBound, tempoMap: project.tempoMap),
      "seconds": .number(Double(blocks.count) * MixMeasurement.blockSeconds),
      "song": AgentListening.describe(whole),
      "notes": .array(AgentListening.notes(on: whole).map { .string($0) }),
      "bands": .string(MasteringAnalysis.bandCenters.map { $0 < 1000 ? "\(AgentNotation.formatNumber($0)) Hz" : "\(AgentNotation.formatNumber($0 / 1000)) kHz" }.joined(separator: ", ")),
    ]
    // Each section's own blocks, by where it lies in the render.
    let startSeconds = project.tempoMap.seconds(at: range.lowerBound)
    let sections = project.arrangement.sorted { $0.start < $1.start }.filter { $0.start < range.upperBound && $0.end > range.lowerBound }
    result["sections"] = .array(sections.map { section in
      let first = Int(((project.tempoMap.seconds(at: max(section.start, range.lowerBound)) - startSeconds) / MixMeasurement.blockSeconds).rounded())
      let last = Int(((project.tempoMap.seconds(at: min(section.end, range.upperBound)) - startSeconds) / MixMeasurement.blockSeconds).rounded())
      let slice = Array(blocks[min(max(first, 0), blocks.count)..<min(max(last, first), blocks.count)])
      guard case .object(var info) = AgentListening.describe(MixMeasurement.summary(of: slice)) else { return .null }
      info["name"] = .string(section.name)
      info["start"] = AgentNotation.format(section.start, tempoMap: project.tempoMap)
      return .object(info)
    })
    return .object(result)
  }

  static let bounce = AgentTool(
    name: "bounce", title: "Bounce",
    description: """
      Bounces the mix to an audio file in the person's Music folder (Music › Ongaku Studio › \
      Bounces), as File › Bounce does, and returns its path, length and peak. The cycle range \
      if it's on, otherwise the whole song, unless from/to say otherwise.
      """,
    properties: rangeProperties.merging([
      "format": Schema.choice(BounceSettings.FileFormat.allCases.map(\.rawValue), "wav (the default), aiff or m4a."),
      "normalize": Schema.boolean("Raises the level so the loudest peak sits just below full scale."),
    ]) { current, _ in current }
  ) { arguments, session in
    let project = session.project
    let range = try AgentListening.range(arguments, in: project, followsCycle: true)
    var settings = BounceSettings()
    if let format = try arguments.optionalChoice("format", BounceSettings.FileFormat.self) { settings.format = format }
    if let normalize = try arguments.optionalBool("normalize") { settings.normalize = normalize }
    let result = try await session.bounce(range, settings: settings)
    var info: [String: AgentValue] = [
      "path": .string(result.path), "seconds": .number(result.seconds), "peakDb": .number(result.peakDecibels),
    ]
    if result.isClipped { info["warning"] = "It clips (peaks above 0 dBFS): lower Stereo Out, or bounce with normalize." }
    return .object(info)
  }

  static let masterSong = AgentTool(
    name: "master_song", title: "Master Song",
    description: """
      Masters the song with Ongaku Mastering on Stereo Out (added if it isn't there), as its \
      Analyze Whole Song does: it listens to the whole song and sets its EQ, compression and \
      width to suit, and works out the loudness. Returns what it found and set. One undo step.
      """
  ) { _, session in
    guard let result = try await session.masterSong() else {
      throw AgentError.notPossible("Mastering heard too little music to go on: it needs at least \(Int(MasteringAnalysis.minimumSeconds)) seconds that aren't silent.")
    }
    return [
      "loudnessLufs": .number(result.loudness), "truePeakDb": .number(result.truePeak),
      "peakToLoudnessDb": .number(result.peakToLoudness), "sideToMidDb": .number(result.sideToMid),
      "eq": .string(zip(["Low Shelf", "Low-Mid", "Presence", "Air", "High Shelf"], result.eq).map { "\($0) \(AgentNotation.formatNumber($1)) dB" }.joined(separator: ", ")),
      "compressor": .string("threshold \(AgentNotation.formatNumber(result.threshold)) dB, ratio \(AgentNotation.formatNumber(result.ratio)):1"),
      "widthPercent": .number(result.width),
      "note": "Mastering's Loudness and Ceiling settings are left as they were; open it from Stereo Out to hear and adjust.",
    ]
  }
}

enum AgentListening {
  /// The stretch to render: from/to, else the cycle (for bounce, when it's on), else the song.
  static func range(_ arguments: AgentArguments, in project: Project, followsCycle: Bool = false) throws -> Range<Tick> {
    var whole = project
    if !followsCycle || arguments.has("from") || arguments.has("to") { whole.cycle.isEnabled = false }
    guard let songRange = whole.bounceRange else { throw AgentError.notPossible("The song is empty, so there's nothing to hear.") }
    let start = try arguments.optionalPosition("from", in: project) ?? songRange.lowerBound
    let end = try arguments.optionalPosition("to", in: project) ?? songRange.upperBound
    guard end > start else { throw AgentError.invalidArgument("to", "it must end after it starts.") }
    return start..<end
  }

  static func describe(_ summary: MixMeasurement.Summary) -> AgentValue {
    var info: [String: AgentValue] = ["peakDb": .number(summary.peak)]
    if let loudness = summary.loudness { info["loudnessLufs"] = .number(loudness) } else { info["silent"] = true }
    if let maximum = summary.maximumLoudness { info["loudestMomentLufs"] = .number(maximum) }
    if let peakToLoudness = summary.peakToLoudness { info["peakToLoudnessDb"] = .number(peakToLoudness) }
    if let sideToMid = summary.sideToMid { info["sideToMidDb"] = .number(sideToMid) }
    info["balanceDb"] = .array(summary.balance.map { $0.map { AgentValue.number($0) } ?? .null })
    return .object(info)
  }

  /// Plain words on what stands out, for an agent to act on.
  static func notes(on summary: MixMeasurement.Summary) -> [String] {
    guard let loudness = summary.loudness else { return ["The mix is silent."] }
    var notes: [String] = []
    if summary.peak > -0.1 { notes.append("Peaks reach full scale, so it may clip: lower Stereo Out or the loudest tracks.") }
    if loudness < -23 { notes.append("Quiet (\(Int(loudness.rounded())) LUFS); master_song or a Maximizer on Stereo Out would bring it up toward the -14 LUFS streaming services play at.") }
    if let peakToLoudness = summary.peakToLoudness, peakToLoudness > 16 {
      notes.append("Very peaky (\(Int(peakToLoudness.rounded())) dB from peaks to loudness): drums or transients stand well above the rest; a compressor would even it out.")
    }
    let names = ["sub (31 Hz)", "low bass (63 Hz)", "bass (125 Hz)", "low mids (250 Hz)", "mids (500 Hz)", "mids (1 kHz)", "upper mids (2 kHz)", "presence (4 kHz)", "brightness (8 kHz)", "air (16 kHz)"]
    for (index, value) in summary.balance.enumerated() {
      guard let value, abs(value) >= 4, names.indices.contains(index) else { continue }
      notes.append("\(names[index].capitalized(with: nil)) is \(Int(abs(value).rounded())) dB \(value > 0 ? "heavier" : "lighter") than a typical master.")
    }
    if let sideToMid = summary.sideToMid {
      if sideToMid > -3 { notes.append("Very wide: the sides are nearly as loud as the middle, which can sound hollow in mono.") }
      if sideToMid < -20 { notes.append("Nearly mono: panning parts apart, or a stereo reverb, would widen it.") }
    }
    if notes.isEmpty { notes.append("Nothing stands out: the balance is close to a typical master.") }
    return notes
  }
}
