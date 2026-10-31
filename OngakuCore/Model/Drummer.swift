//
//  Drummer.swift
//  OngakuCore
//

import Foundation

/// A session drummer's part for one region, as with Logic's Drummer: a style, how busy and
/// how loud to play, how often to fill, and which drums to use. The region's notes are
/// generated from it (see `Region.renderDrummer(tempoMap:)`), bar by bar in the song's
/// meter, so everything that plays or reads notes works on a drummer region unchanged.
///
/// The playing is worked out from the settings and a seed, so it's the same every time
/// until a setting changes or a new take is asked for.
public struct DrummerPerformance: Codable, Sendable, Equatable {
  public enum Style: String, Codable, Sendable, CaseIterable, Identifiable {
    case rock, pop, funk, hipHop, songwriter, electronic, shuffle

    public var id: Self { self }

    public var title: String {
      switch self {
      case .rock: "Rock"
      case .pop: "Pop"
      case .funk: "Funk"
      case .hipHop: "Hip-Hop"
      case .songwriter: "Songwriter"
      case .electronic: "Electronic"
      case .shuffle: "Purdie Shuffle"
      }
    }

    public var summary: String {
      switch self {
      case .rock: "Straight eighths on the hi-hat, a solid backbeat, tom fills"
      case .pop: "Tight and steady, with a lighter touch and more kick variation"
      case .funk: "Syncopated kicks, sixteenth hi-hats and lots of ghost notes"
      case .hipHop: "Laid-back, swung sixteenths with off-beat kicks"
      case .songwriter: "Sparse and gentle, cross-stick when quiet"
      case .electronic: "Four on the floor, off-beat open hats, snare rolls"
      case .shuffle: "Half-time triplet shuffle: hi-hat on each beat's first and last triplet, ghost notes between, the backbeat on 3"
      }
    }

    /// The swing a new part in this style starts with.
    public var defaultSwing: Double {
      switch self {
      case .hipHop: 0.45
      case .funk: 0.15
      // In the shuffle, "swing" is how hard the ghost notes are (see `ghostVelocity`).
      case .shuffle: 0.4
      default: 0
      }
    }
  }

  /// Where the backbeat falls.
  public enum Feel: String, Codable, Sendable, CaseIterable, Identifiable {
    case halfTime, normal, doubleTime
    public var id: Self { self }
    public var title: String {
      switch self {
      case .halfTime: "Half Time"
      case .normal: "Normal"
      case .doubleTime: "Double Time"
      }
    }
  }

  /// What keeps time: the hi-hat, the ride, or the hi-hat opening up to the ride (or open
  /// hats) when the part is loud.
  public enum Timekeeper: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic, hiHat, ride
    public var id: Self { self }
    public var title: String {
      switch self {
      case .automatic: "Automatic"
      case .hiHat: "Hi-Hat"
      case .ride: "Ride"
      }
    }
  }

  /// The kit it plays: General MIDI has every drum; the Drum Machine has no ride, so open
  /// hats stand in for it.
  public enum Kit: String, Codable, Sendable {
    case generalMIDI, drumMachine
  }

  public var style: Style
  /// Simple (0) to complex (1): extra kicks, ghost notes, busier hi-hats and fills.
  public var complexity: Double
  /// Soft (0) to loud (1).
  public var loudness: Double
  /// None (0) to many, long fills (1).
  public var fills: Double
  /// Delays the off-beats toward a triplet feel at 1.
  public var swing: Double
  public var feel: Feel
  public var timekeeper: Timekeeper
  public var playsKickAndSnare: Bool
  public var playsCymbals: Bool
  public var playsToms: Bool
  public var playsPercussion: Bool
  /// Fill into whatever comes after the region (Logic does this when another section
  /// follows).
  public var fillsAtEnd: Bool
  /// A crash on the first downbeat, as a section starts.
  public var crashesAtStart: Bool
  public var kit: Kit
  /// Which take: a new seed plays the same settings differently.
  public var seed: UInt64

  public init(
    style: Style = .rock, complexity: Double = 0.45, loudness: Double = 0.55, fills: Double = 0.5, swing: Double? = nil,
    feel: Feel = .normal, timekeeper: Timekeeper = .automatic, playsKickAndSnare: Bool = true, playsCymbals: Bool = true,
    playsToms: Bool = true, playsPercussion: Bool = false, fillsAtEnd: Bool = true, crashesAtStart: Bool = false,
    kit: Kit = .generalMIDI, seed: UInt64 = 1
  ) {
    self.style = style
    self.complexity = complexity
    self.loudness = loudness
    self.fills = fills
    self.swing = swing ?? style.defaultSwing
    self.feel = feel
    self.timekeeper = timekeeper
    self.playsKickAndSnare = playsKickAndSnare
    self.playsCymbals = playsCymbals
    self.playsToms = playsToms
    self.playsPercussion = playsPercussion
    self.fillsAtEnd = fillsAtEnd
    self.crashesAtStart = crashesAtStart
    self.kit = kit
    self.seed = seed
  }

  // MARK: - Sections

  /// How a drummer plays a song section, from its name: quieter and simpler in an intro or
  /// a breakdown, loud and busy in a chorus, half time in a bridge's breakdown, and so on.
  public static func forSection(
    named name: String, style: Style, kit: Kit, isFirst: Bool, isLast: Bool, seed: UInt64
  ) -> DrummerPerformance {
    var part = DrummerPerformance(style: style, kit: kit, seed: seed)
    switch name.lowercased() {
    case "intro":
      (part.complexity, part.loudness, part.fills) = (0.3, 0.4, 0.4)
    case "verse":
      (part.complexity, part.loudness, part.fills) = (0.45, 0.5, 0.4)
    case "pre-chorus":
      (part.complexity, part.loudness, part.fills) = (0.5, 0.62, 0.65)
    case "chorus":
      (part.complexity, part.loudness, part.fills) = (0.6, 0.78, 0.55)
    case "bridge":
      (part.complexity, part.loudness, part.fills) = (0.5, 0.58, 0.6)
    case "solo":
      (part.complexity, part.loudness, part.fills) = (0.68, 0.75, 0.6)
    case "breakdown":
      (part.complexity, part.loudness, part.fills) = (0.25, 0.35, 0.3)
      part.feel = .halfTime
      part.playsToms = false
    case "outro":
      (part.complexity, part.loudness, part.fills) = (0.4, 0.6, 0.5)
    default:
      break
    }
    part.crashesAtStart = !isFirst
    part.fillsAtEnd = !isLast
    return part
  }

  // MARK: - Playing

  /// General MIDI drum notes.
  enum Drum {
    static let kick = 36, sideStick = 37, snare = 38, clap = 39, closedHat = 42, lowTom = 45, openHat = 46, midTom = 47,
      crash = 49, highTom = 50, ride = 51, cowbell = 56, shaker = 70
  }

  /// One group of beats the groove is built on: four sixteenths (a quarter note), or six
  /// (a dotted quarter in 6/8, or the long group of 7/8).
  struct Pulse {
    var step: Int
    var length: Int
  }

  /// A drum hit, from the start of the song.
  struct Hit {
    var pitch: Int
    var position: Tick
    var velocity: Int
  }

  static let sixteenth = Tick(240)

  /// The notes the drummer plays from `start` for `length`, with the song's meter from
  /// `tempoMap`, relative to `start`.
  public func notes(from start: Tick, length: Tick, tempoMap: TempoMap) -> [MIDINote] {
    guard length > .zero else { return [] }
    let end = start + length
    var hits: [Hit] = []
    let first = tempoMap.bar(containing: start)
    var barIndex = first.index
    var barStart = first.start
    var barNumber = 0
    var fillEndedLastBar = false
    while barStart < end {
      let signature = tempoMap.timeSignature(atBarIndex: barIndex)
      let barEnd = tempoMap.tickPosition(ofBarIndex: barIndex + 1)
      var random = SplitMix(seed: seed ^ (UInt64(barNumber + 1) &* 0x9E37_79B9_7F4A_7C15) ^ UInt64(Style.allCases.firstIndex(of: style) ?? 0))
      let pulses = Self.pulses(of: signature)
      // Fills: into whatever follows on the region's last bar, and now and then every
      // four bars within it.
      let isLastBar = barEnd >= end
      var fillPulses = 0
      if isLastBar, fillsAtEnd, fills > 0.05 {
        fillPulses = fills < 0.35 ? 1 : fills < 0.7 ? 2 : pulses.count
      } else if !isLastBar, barNumber % 4 == 3, random.unit() < fills * 0.8 {
        fillPulses = fills > 0.75 && barNumber % 8 == 7 ? 2 : 1
      }
      if !playsKickAndSnare && !playsToms { fillPulses = 0 }
      fillPulses = min(fillPulses, pulses.count)
      let crash = playsCymbals && ((barNumber == 0 && crashesAtStart) || (fillEndedLastBar && loudness > 0.45))
      hits += bar(
        at: barStart, pulses: pulses, fillPulses: fillPulses, crash: crash, isCompound: signature.isCompound,
        random: &random)
      fillEndedLastBar = fillPulses > 0
      barIndex += 1
      barStart = barEnd
      barNumber += 1
    }
    // One note per drum per moment (the loudest), within the region.
    var seen: [String: Int] = [:]
    var notes: [MIDINote] = []
    for hit in hits where hit.position >= start && hit.position < end {
      let key = "\(hit.pitch)@\(hit.position.rawValue)"
      let velocity = min(max(hit.velocity, 1), 127)
      if let index = seen[key] {
        notes[index].velocity = max(notes[index].velocity, velocity)
        continue
      }
      seen[key] = notes.count
      notes.append(MIDINote(pitch: hit.pitch, velocity: velocity, start: hit.position - start, length: Tick(120)))
    }
    return notes.sorted { ($0.start, $0.pitch) < ($1.start, $1.pitch) }
  }

  /// A bar's pulses: dotted quarters in compound meters, otherwise quarters, with a group of
  /// three eighths taking up what's left over (7/8 is 2 + 2 + 3).
  static func pulses(of signature: TimeSignature) -> [Pulse] {
    let steps = Int(signature.ticksPerBar.rawValue / sixteenth.rawValue)
    if signature.isCompound {
      return stride(from: 0, to: steps, by: 6).map { Pulse(step: $0, length: min(6, steps - $0)) }
    }
    var pulses: [Pulse] = []
    var step = 0
    while step < steps {
      let remaining = steps - step
      let length = remaining <= 6 && remaining != 4 ? remaining : 4
      pulses.append(Pulse(step: step, length: length))
      step += length
    }
    return pulses
  }

  /// The pulses the snare plays on: beats 2 and 4 of 4/4, 2 and 3 of a waltz, the second
  /// pulse of 6/8 and so on (half time: the middle of the bar).
  func backbeats(_ pulses: [Pulse]) -> Set<Int> {
    let count = pulses.count
    switch count {
    case 1: return []
    case 2: return [1]
    case 3:
      return pulses.allSatisfy({ $0.length == pulses[0].length }) ? [1, 2] : [2]
    default:
      if feel == .halfTime, count % 2 == 0 { return [count / 2] }
      return Set(stride(from: 1, to: count, by: 2))
    }
  }

  /// How likely each kick is, by where it falls in a four-sixteenth pulse: the step it's on,
  /// and the complexity it needs. The pulse's role picks the row: the bar's first pulse,
  /// a backbeat, or any other.
  private var kickTable: (first: [Int: Double], back: [Int: Double], other: [Int: Double]) {
    switch style {
    case .rock: ([0: 0, 2: 0.55, 3: 0.85], [2: 0.5, 3: 0.75], [0: 0.05, 2: 0.35, 3: 0.7, 1: 0.85])
    case .pop: ([0: 0, 2: 0.45, 3: 0.8], [2: 0.6, 3: 0.8], [0: 0.15, 2: 0.3, 3: 0.75])
    case .funk: ([0: 0, 3: 0.35, 2: 0.6, 1: 0.85], [3: 0.45, 2: 0.65, 1: 0.9], [2: 0.15, 0: 0.4, 3: 0.55, 1: 0.8])
    case .hipHop: ([0: 0, 3: 0.3, 2: 0.6], [3: 0.5, 2: 0.7], [2: 0.1, 1: 0.5, 3: 0.65, 0: 0.75])
    case .songwriter: ([0: 0, 2: 0.6], [2: 0.75], [0: 0.2, 2: 0.55, 3: 0.85])
    case .electronic: ([0: 0, 3: 0.85], [0: 0, 3: 0.7], [0: 0, 3: 0.8])
    // The shuffle has its own triplet rules (see `shuffleBar`).
    case .shuffle: ([0: 0], [:], [:])
    }
  }

  /// How often ghost notes come in once the part is busy enough.
  private var ghostiness: Double {
    switch style {
    case .funk: 1.6
    case .hipHop: 1.0
    case .pop: 0.7
    case .rock: 0.6
    case .songwriter: 0.5
    case .electronic: 0.15
    case .shuffle: 1.2
    }
  }

  private var swingsSixteenths: Bool { style == .funk || style == .hipHop }

  private var baseVelocity: Double { 45 + min(max(loudness, 0), 1) * 75 }

  /// The drum keeping time: the ride when asked (or loud), else the closed hi-hat.
  private var timekeepingDrum: Int {
    let usesRide = timekeeper == .ride || (timekeeper == .automatic && loudness > 0.72 && style != .electronic)
    guard usesRide else { return Drum.closedHat }
    return kit == .generalMIDI ? Drum.ride : Drum.openHat
  }

  private func bar(
    at barStart: Tick, pulses: [Pulse], fillPulses: Int, crash: Bool, isCompound: Bool, random: inout SplitMix
  ) -> [Hit] {
    if style == .shuffle {
      return shuffleBar(at: barStart, pulses: pulses, fillPulses: fillPulses, crash: crash, random: &random)
    }
    var hits: [Hit] = []
    let complexity = min(max(self.complexity, 0), 1)
    let base = baseVelocity
    let backbeats = backbeats(pulses)
    let fillStart = pulses.count - fillPulses
    // Each bar varies a little: kicks need a little more or less complexity to come in.
    let variation = (random.unit() - 0.5) * 0.2
    let table = kickTable

    func position(_ step: Int) -> Tick { barStart + Self.sixteenth * Int64(step) }
    func add(_ pitch: Int, _ step: Int, _ velocity: Double) {
      hits.append(Hit(pitch: pitch, position: position(step), velocity: Int(velocity.rounded())))
    }

    if crash {
      add(Drum.crash, 0, base + 10)
      if playsKickAndSnare { add(Drum.kick, 0, base + 8) }
    }

    for (index, pulse) in pulses.enumerated() {
      let isFill = index >= fillStart
      let isBackbeat = backbeats.contains(index)
      let eighths = pulse.length >= 6 ? [0, 2, 4] : pulse.length >= 4 ? [0, 2] : [0]

      // Kick and snare.
      if playsKickAndSnare {
        if isFill {
          add(Drum.kick, pulse.step, base)
        } else {
          let row = index == 0 ? table.first : isBackbeat ? table.back : table.other
          let candidates: [Int: Double] =
            pulse.length >= 6 ? (index == 0 ? [0: 0, 4: 0.5, 3: 0.8] : isBackbeat ? [4: 0.6] : [0: 0.1, 4: 0.7]) : row
          // In step order, so the same settings always play the same (a dictionary's order varies).
          for (offset, needed) in candidates.sorted(by: { $0.key < $1.key }) where offset < pulse.length {
            let isDownbeat = index == 0 && offset == 0
            if isDownbeat || complexity >= needed + variation {
              add(Drum.kick, pulse.step + offset, base + (offset == 0 ? 6 : -4))
            }
          }
          if feel == .doubleTime {
            add(Drum.kick, pulse.step, base + 2)
          }
          // The backbeat (in double time, on every pulse's "and").
          let snareSteps: [Int] =
            feel == .doubleTime ? [pulse.step + pulse.length / 2] : isBackbeat ? [pulse.step] : []
          for step in snareSteps {
            let quiet = loudness < 0.35 && (style == .songwriter || style == .pop)
            add(quiet ? Drum.sideStick : Drum.snare, step, base + 8)
            if style == .electronic || (style == .hipHop && loudness > 0.55) { add(Drum.clap, step, base) }
          }
          // Ghost notes on the in-between sixteenths.
          if complexity > 0.35 {
            for offset in stride(from: 1, to: pulse.length, by: 2) where random.unit() < (complexity - 0.35) * ghostiness * 0.5 {
              add(Drum.snare, pulse.step + offset, 22 + random.unit() * 16)
            }
          }
        }
      }

      // Hi-hat or ride.
      if playsCymbals && !isFill {
        let drum = timekeepingDrum
        var steps: [Int]
        let sixteenths = Array(0..<pulse.length)
        switch style {
        case .songwriter: steps = complexity < 0.3 ? [0] : eighths
        case .rock: steps = eighths
        case .pop: steps = complexity > 0.75 ? sixteenths : eighths
        case .funk: steps = complexity > 0.4 ? sixteenths : eighths
        case .hipHop: steps = complexity > 0.6 ? sixteenths : eighths
        case .electronic: steps = complexity > 0.45 ? sixteenths.filter { $0 != 2 } : []
        case .shuffle: steps = eighths  // Not used: the shuffle has its own bar.
        }
        if isCompound || pulse.length >= 6 { steps = complexity > 0.7 ? sixteenths : eighths }
        if feel == .halfTime { steps = steps.filter { $0 % 2 == 0 } }
        for offset in steps {
          let accent: Double = offset == 0 ? 10 : offset % 2 == 0 ? 2 : -10
          add(drum, pulse.step + offset, base * 0.72 + accent + (random.unit() - 0.5) * 8)
        }
        if style == .electronic, pulse.length >= 4 {
          add(Drum.openHat, pulse.step + 2, base * 0.8)
        }
        // Funk opens the hat on the last "and" of the bar now and then.
        if style == .funk, index == pulses.count - 1, complexity > 0.5, pulse.length >= 4, random.unit() < 0.6 {
          add(Drum.openHat, pulse.step + 2, base * 0.8)
        }
      }

      // Percussion: a shaker in sixteenths, and a cowbell on the beat in busy funk.
      if playsPercussion && !isFill {
        for offset in 0..<pulse.length {
          add(Drum.shaker, pulse.step + offset, 30 + base * 0.25 + (offset % 2 == 1 ? 8 : 0))
        }
        if style == .funk, complexity > 0.6 { add(Drum.cowbell, pulse.step, base * 0.6) }
      }
    }

    if fillPulses > 0 {
      hits += fill(barStart: barStart, pulses: Array(pulses[fillStart...]), random: &random)
    }

    // Swing and a human touch.
    let humanize: Double = style == .electronic ? 0 : 10
    return hits.map { hit in
      var hit = hit
      let step = Int((hit.position - barStart).rawValue / Self.sixteenth.rawValue)
      let offset = step % 4
      if !isCompound, swing > 0 {
        if swingsSixteenths, offset % 2 == 1 {
          hit.position += Tick(Int64(80 * swing))
        } else if !swingsSixteenths, offset == 2 {
          hit.position += Tick(Int64(160 * swing))
        } else if !swingsSixteenths, offset == 3 {
          hit.position += Tick(Int64(80 * swing))
        }
      }
      if humanize > 0, hit.pitch != Drum.crash {
        hit.position += Tick(Int64(((random.unit() - 0.5) * humanize).rounded()))
        hit.velocity += Int(((random.unit() - 0.5) * 10).rounded())
      }
      hit.position = max(barStart, hit.position)
      return hit
    }
  }

  // MARK: - The Purdie shuffle

  /// A bar of Bernard Purdie's half-time shuffle, on triplets: each pulse is three triplet
  /// partials. The hi-hat plays the first and last of each, a ghost note on the snare fills
  /// the middle one, the backbeat falls once a bar (beat 3 of 4/4; on 2 and 4 in double
  /// time), and the kick pushes the last triplet before a beat. Busier parts add kicks and
  /// louder ghosts; louder ones open the hat and move to the ride.
  private func shuffleBar(
    at barStart: Tick, pulses: [Pulse], fillPulses: Int, crash: Bool, random: inout SplitMix
  ) -> [Hit] {
    var hits: [Hit] = []
    let complexity = min(max(self.complexity, 0), 1)
    let base = baseVelocity
    let count = pulses.count
    let fillStart = count - fillPulses
    let variation = (random.unit() - 0.5) * 0.2
    // The half-time backbeat, unless in double time.
    let backbeats: Set<Int> = feel == .doubleTime || count < 4 || count % 2 == 1 ? backbeatsInTime(pulses) : [count / 2]

    func position(_ pulse: Pulse, _ partial: Int, of partials: Int = 3) -> Tick {
      let pulseTicks = Self.sixteenth.rawValue * Int64(pulse.length)
      return barStart + Self.sixteenth * Int64(pulse.step) + Tick(pulseTicks * Int64(partial) / Int64(partials))
    }
    func add(_ pitch: Int, _ at: Tick, _ velocity: Double) {
      hits.append(Hit(pitch: pitch, position: at, velocity: Int(velocity.rounded())))
    }

    if crash, let first = pulses.first {
      add(Drum.crash, position(first, 0), base + 10)
      if playsKickAndSnare { add(Drum.kick, position(first, 0), base + 8) }
    }

    for (index, pulse) in pulses.enumerated() {
      let isFill = index >= fillStart
      let isBackbeat = backbeats.contains(index)

      if playsKickAndSnare {
        if isFill {
          add(Drum.kick, position(pulse, 0), base)
        } else {
          // Kicks: always the downbeat; then the last triplet of 2 (the shuffle's push),
          // the pickup into the next bar, and more as the part gets busier.
          var kicks: [(partial: Int, needed: Double)] = []
          if index == 0 { kicks.append((0, -1)) }
          if index == 1 { kicks.append((2, 0.2)) }
          if index == count - 1 { kicks.append((2, 0.45)) }
          if index != 1, index != count - 1, !isBackbeat { kicks.append((2, 0.65)) }
          if index == 0 { kicks.append((2, 0.8)) }
          if !isBackbeat, index != 0 { kicks.append((0, 0.9)) }
          for kick in kicks where kick.needed < 0 || complexity >= kick.needed + variation {
            add(Drum.kick, position(pulse, kick.partial), base + (kick.partial == 0 ? 6 : -2))
          }
          if isBackbeat {
            add(Drum.snare, position(pulse, 0), base + 10)
          }
          // The ghost notes: the middle triplet of every beat, the heart of the shuffle.
          let ghostChance = complexity < 0.1 ? 0 : min(1, 0.4 + complexity)
          if random.unit() < ghostChance {
            add(Drum.snare, position(pulse, 1), ghostVelocity + 6 * complexity + (random.unit() - 0.5) * 8)
          }
          // Busy parts drag into the backbeat with a ghost on the triplet before it.
          if complexity > 0.75, backbeats.contains(index + 1), random.unit() < 0.6 {
            add(Drum.snare, position(pulse, 2), ghostVelocity * 0.85 + (random.unit() - 0.5) * 6)
          }
        }
      }

      if playsCymbals && !isFill {
        let drum = timekeepingDrum
        add(drum, position(pulse, 0), base * 0.75 + 8 + (random.unit() - 0.5) * 6)
        add(drum, position(pulse, 2), base * 0.55 + (random.unit() - 0.5) * 6)
        // On the ride, the hi-hat foot keeps the backbeat.
        if drum != Drum.closedHat, isBackbeat || feel == .doubleTime {
          add(44, position(pulse, 0), base * 0.5)
        }
        // A loud, busy shuffle opens the hat into the next bar.
        if drum == Drum.closedHat, index == count - 1, loudness > 0.6, complexity > 0.5, random.unit() < 0.5 {
          add(Drum.openHat, position(pulse, 2), base * 0.7)
        }
      }

      if playsPercussion && !isFill {
        for partial in 0..<3 {
          add(Drum.shaker, position(pulse, partial), 30 + base * 0.25 + (partial == 1 ? -6 : 4))
        }
      }
    }

    // A triplet fill round the toms.
    if fillPulses > 0 {
      let fillPulsesList = Array(pulses[fillStart...])
      for (pulseIndex, pulse) in fillPulsesList.enumerated() {
        // The last pulse doubles up to sextuplets when the part is busy.
        let partials = complexity > 0.6 && pulseIndex == fillPulsesList.count - 1 ? 6 : 3
        for partial in 0..<partials {
          // How far through the fill: it moves down the toms as it goes.
          let fraction = (Double(pulseIndex) + Double(partial) / Double(partials)) / Double(fillPulsesList.count)
          if complexity < 0.3, partials == 3, partial == 1 { continue }
          let velocity = base * (0.7 + 0.35 * fraction) + (random.unit() - 0.5) * 6
          let pitch: Int
          if !playsToms {
            guard playsKickAndSnare else { continue }
            pitch = Drum.snare
          } else {
            switch fraction + (random.unit() - 0.5) * 0.2 {
            case ..<0.3: pitch = playsKickAndSnare ? Drum.snare : Drum.highTom
            case ..<0.55: pitch = Drum.highTom
            case ..<0.8: pitch = Drum.midTom
            default: pitch = Drum.lowTom
            }
          }
          add(pitch, position(pulse, partial, of: partials), velocity)
        }
      }
    }

    // A human touch (the triplets are the swing).
    return hits.map { hit in
      var hit = hit
      if hit.pitch != Drum.crash {
        hit.position += Tick(Int64(((random.unit() - 0.5) * 10).rounded()))
        hit.velocity += Int(((random.unit() - 0.5) * 8).rounded())
      }
      hit.position = max(barStart, hit.position)
      return hit
    }
  }

  /// How hard the shuffle's ghost notes are: the triplets are already the swing, so the
  /// Swing setting sets them instead, from a whisper (0) to clearly heard (1).
  private var ghostVelocity: Double { 12 + 46 * min(max(swing, 0), 1) }

  /// The backbeat in time (not half time): beats 2 and 4 of 4/4, and so on.
  private func backbeatsInTime(_ pulses: [Pulse]) -> Set<Int> {
    var normal = self
    normal.feel = .normal
    return normal.backbeats(pulses)
  }

  /// A fill across the last pulses of a bar: sixteenths (eighths when simple) moving from
  /// the snare round the toms, or a snare roll in electronic styles, getting louder.
  private func fill(barStart: Tick, pulses: [Pulse], random: inout SplitMix) -> [Hit] {
    guard let first = pulses.first, let last = pulses.last else { return [] }
    let complexity = min(max(self.complexity, 0), 1)
    let startStep = first.step
    let endStep = last.step + last.length
    let count = endStep - startStep
    var hits: [Hit] = []
    let base = baseVelocity
    for step in startStep..<endStep {
      let fraction = Double(step - startStep) / Double(max(1, count))
      // Simple fills play eighths; busier ones sixteenths with the odd gap.
      if complexity < 0.3, step % 2 == 1 { continue }
      if step != startStep, random.unit() < 0.15 * (1 - complexity) { continue }
      let velocity = base * (0.7 + 0.35 * fraction) + (random.unit() - 0.5) * 6
      let pitch: Int
      if style == .electronic || !playsToms {
        guard playsKickAndSnare else { continue }
        pitch = Drum.snare
      } else {
        let wobble = (random.unit() - 0.5) * 0.2
        switch fraction + wobble {
        case ..<0.25: pitch = playsKickAndSnare ? Drum.snare : Drum.highTom
        case ..<0.5: pitch = Drum.highTom
        case ..<0.75: pitch = Drum.midTom
        default: pitch = Drum.lowTom
        }
      }
      hits.append(Hit(pitch: pitch, position: barStart + Self.sixteenth * Int64(step), velocity: Int(velocity.rounded())))
      // An electronic roll speeds up to thirty-seconds at the end.
      if style == .electronic, complexity > 0.5, step >= endStep - min(4, count) {
        hits.append(Hit(
          pitch: Drum.snare, position: barStart + Self.sixteenth * Int64(step) + Tick(120), velocity: Int(velocity.rounded())))
      }
    }
    return hits
  }
}

extension Region {
  /// For a drummer region, replaces its notes with what the drummer plays over its length.
  /// Call after changing the performance, the region's length, or the song's meter.
  public mutating func renderDrummer(tempoMap: TempoMap) {
    guard let drummer, case .midi(var sequence) = content else { return }
    sequence.notes = drummer.notes(from: start, length: length, tempoMap: tempoMap)
    content = .midi(sequence)
  }

  public var isDrummerRegion: Bool { drummer != nil }
}

extension Project {
  /// Plays every drummer region again, after the meter changed under them.
  mutating func renderDrummerRegions() {
    for trackIndex in tracks.indices {
      for regionIndex in tracks[trackIndex].regions.indices where tracks[trackIndex].regions[regionIndex].drummer != nil {
        tracks[trackIndex].regions[regionIndex].renderDrummer(tempoMap: tempoMap)
      }
    }
  }
}
