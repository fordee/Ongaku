//
//  ChannelNodes.swift
//  OngakuEngine
//

import AVFAudio
import AudioToolbox
import OngakuCore

/// The mixer path every track shares, whatever its kind:
///
///     source ─▶ input ─▶ insert 1 … insert n ─▶ pre-fader ─┬─▶ fader ─┬─▶ Stereo Out
///                                                          │          └─▶ post-fader sends
///                                                          └─▶ pre-fader sends
///
/// The source is the track's player nodes (audio), its instrument (software instrument) or
/// the sends from other tracks (aux). Sends are extra connections from the pre-fader or fader
/// node into an aux track's input, with the send level set on that connection.
@MainActor
final class ChannelNodes {
  /// What the track produces is mixed into this node.
  let input = AVAudioMixerNode()
  /// After the inserts and before the fader; pre-fader sends start here.
  let preFader = AVAudioMixerNode()
  /// Applies volume, mute and solo; pan and post-fader sends are set on its connections.
  let fader = AVAudioMixerNode()

  private struct Insert {
    var reference: PluginReference
    var unit: AVAudioUnit
  }

  private unowned let engine: AVAudioEngine
  private let format: AVAudioFormat
  /// Where "Stereo Out" is for this channel: the Stereo Out channel's input, or the
  /// engine's main mixer for the Stereo Out channel itself.
  private let mainOutput: AVAudioMixerNode
  private var inserts: [Insert] = []
  /// The plug-ins currently connected between input and pre-fader, in order.
  private var connectedChain: [PluginReference.ID] = []
  /// Plug-ins still loading, by plug-in ID.
  private var pendingInserts: [PluginReference.ID: Task<Void, Never>] = [:]
  private var wantedInserts: [PluginReference] = []
  /// The input bus on each destination mixer this channel feeds, kept stable so changing a
  /// send's level never needs a reconnection.
  private var mainBus: AVAudioNodeBus?
  private var routing: Routing?

  /// What the fader and pre-fader nodes connect to.
  struct Routing: Equatable {
    var postFader: [Destination]
    var preFader: [Destination]
    /// The aux track the fader outputs to instead of Stereo Out (a summing stack, say).
    var output: Track.ID?
    /// Samples the output is delayed by, for plug-in delay compensation.
    var outputDelay = 0

    struct Destination: Equatable {
      var trackID: Track.ID
      var level: Float
      /// Samples this send is delayed by, for plug-in delay compensation.
      var delay = 0
      /// The send this connection is, if it's one.
      var sendID: Send.ID?
      /// An automated send gets its own mixer, whose gain the automation drives.
      var isAutomated = false
    }

    /// The routing for a channel strip's sends and output. A send to the aux the channel
    /// already outputs to is left out: it would need a second connection to the same input.
    init(sends: [Send], output: ChannelOutput = .stereoOut, automatedSends: Set<Send.ID> = []) {
      let sends = sends.filter { $0.destinationTrackID != output.trackID }
      func destination(_ send: Send) -> Destination {
        Destination(
          trackID: send.destinationTrackID, level: Float(send.linearGain), sendID: send.id,
          isAutomated: automatedSends.contains(send.id))
      }
      postFader = sends.filter { !$0.isPreFader }.map(destination)
      preFader = sends.filter(\.isPreFader).map(destination)
      self.output = output.trackID
    }

    /// A send's connection, and whether it's taken before the fader.
    func send(_ id: Send.ID) -> (destination: Destination, isPreFader: Bool)? {
      if let destination = postFader.first(where: { $0.sendID == id }) { return (destination, false) }
      if let destination = preFader.first(where: { $0.sendID == id }) { return (destination, true) }
      return nil
    }

    init(postFader: [Destination], preFader: [Destination], output: Track.ID? = nil) {
      self.postFader = postFader
      self.preFader = preFader
      self.output = output
    }

    /// The delays a compensation plan gives this channel's output and sends.
    func compensated(by plan: DelayCompensation, for trackID: Track.ID) -> Routing {
      var routing = self
      routing.outputDelay = plan.delay(from: trackID, to: output.map(DelayCompensation.Destination.track) ?? .stereoOut)
      for index in routing.postFader.indices {
        routing.postFader[index].delay = plan.delay(from: trackID, to: .track(routing.postFader[index].trackID))
      }
      for index in routing.preFader.indices {
        routing.preFader[index].delay = plan.delay(from: trackID, to: .track(routing.preFader[index].trackID))
      }
      return routing
    }
  }

  /// Where one of the channel's connections goes: Stereo Out or an aux.
  private enum EdgeKey: Hashable {
    case main
    case aux(Track.ID)
  }

  /// A delayed connection: sample delays (more than one for a long delay), then a mixer that
  /// sets the level and pan into the destination (effects can't set levels on the mixer
  /// after them).
  private struct DelayEdge {
    let delays: [AVAudioUnitEffect]
    let mixer: AVAudioMixerNode

    var nodes: [AVAudioNode] { delays + [mixer] }
  }

  private var faderEdges: [EdgeKey: DelayEdge] = [:]
  private var preFaderEdges: [EdgeKey: DelayEdge] = [:]

  /// How much the inserts delay the sound, in samples. Bypassed plug-ins pass sound
  /// straight through (though some still report their latency), so they don't count.
  var insertLatency: Int {
    inserts.filter { !$0.reference.isBypassed }.reduce(0) { total, insert in
      total + Int((insert.unit.withAUAudioUnit { $0.latency } * format.sampleRate).rounded())
    }
  }

  /// - Parameter format: The format the channel mixes in: stereo at the engine's sample
  ///   rate. Every connection uses it explicitly; left to `nil`, an unconnected mixer
  ///   defaults to 44.1 kHz and the channel would resample twice on any other rate.
  /// What plug-ins are told about the song's tempo and position.
  private let musicalContext: HostMusicalContext?

  init(
    engine: AVAudioEngine, format: AVAudioFormat, musicalContext: HostMusicalContext? = nil,
    mainOutput: AVAudioMixerNode? = nil
  ) throws {
    self.engine = engine
    self.format = format
    self.mainOutput = mainOutput ?? engine.mainMixerNode
    self.musicalContext = musicalContext
    for node in [input, preFader, fader] {
      engine.attach(node)
    }
    do {
      // Connect from the output backwards. On a running engine a node is initialized when
      // it joins a path that is already rendering, so connecting upstream first would leave
      // the input uninitialized and players feeding it would fail with error -10867.
      let bus = engine.freeInputBus(on: self.mainOutput, for: fader)
      try engine.connectNode(fader, to: self.mainOutput, fromBus: 0, toBus: bus, format: format)
      try engine.connectNode(preFader, to: fader, format: format)
      try engine.connectNode(input, to: preFader, format: format)
      mainBus = bus
      // That is the wiring of a channel with no sends and no inserts.
      routing = Routing(postFader: [], preFader: [])
    } catch {
      for node in [input, preFader, fader] {
        engine.detach(node)
      }
      throw error
    }
    installAutomationObserver()
  }

  // MARK: - Mix

  /// Addresses of mixer parameters: scope << 61 | element << 32 | parameter.
  enum FaderParameter {
    /// The gain of the fader's input from the pre-fader node. Volume automation drives it,
    /// leaving the output gain to the fader setting and mute.
    static let inputGain: AUParameterAddress = 1 << 61
    /// The fader's output pan (a balance control for stereo), driven by pan automation.
    static let outputPan: AUParameterAddress = 2 << 61 | 2
    /// A mixer's output gain: an automated send's level, on the send's own mixer.
    static let outputGain: AUParameterAddress = 2 << 61
  }

  /// Something automation drives: one parameter of one node. The node's render observer
  /// hands each buffer its part of the curve, and the node's own sample timeline (which its
  /// clock records) is where ramps are placed: every node counts samples separately.
  final class AutomationTarget {
    let queue: AutomationQueue
    let clock: RenderClock
    let node: AVAudioNode
    /// Turns a parameter value (decibels, -1…1 pan, 0…1 plug-in) into the node's value.
    let engineValue: (Double) -> Float
    fileprivate var observerToken: Int?

    fileprivate init(node: AVAudioNode, address: AUParameterAddress, clock: RenderClock, engineValue: @escaping (Double) -> Float) {
      self.node = node
      queue = AutomationQueue(address: address)
      self.clock = clock
      self.engineValue = engineValue
    }

    func setValue(_ value: Double) {
      let address = queue.address
      let engineValue = engineValue(value)
      node.withAUAudioUnit { $0.parameterTree?.parameter(withAddress: address)?.value = engineValue }
    }
  }

  let volumeAutomation = AutomationQueue(address: FaderParameter.inputGain)
  let panAutomation = AutomationQueue(address: FaderParameter.outputPan)
  private var observerToken: Int?
  /// The fader's timeline, which volume and pan automation is placed in.
  let renderClock = RenderClock()
  /// Send and plug-in automation, each on its own node.
  private var targets: [AutomationParameter: AutomationTarget] = [:]

  /// Where this run's automation starts in each node's timeline: found from a host time
  /// (live) or from the offline render (bounces), and remembered per node.
  enum AutomationAnchor {
    case hostTime(UInt64)
    /// The engine sample time the music starts at, and the one the preroll started at
    /// (when every node rendered for the first time).
    case offline(musicStart: Int64, prerollStart: Int64)
  }

  private var anchor: AutomationAnchor?
  private var anchoredStarts: [ObjectIdentifier: Int64] = [:]
  /// How late the sound reaches the fader, from plug-in latency: automation waits as long.
  private var faderLatency = 0

  /// Starts placing automation for a run of the transport (or a bounce).
  func beginAutomation(anchor: AutomationAnchor, faderLatency: Int) {
    self.anchor = anchor
    self.faderLatency = faderLatency
    anchoredStarts = [:]
  }

  /// The fader's sample time at a host time, once it has rendered.
  func faderSampleTime(atHostTime hostTime: UInt64) -> Int64? {
    renderClock.sampleTime(atHostTime: hostTime, sampleRate: format.sampleRate)
  }

  /// Applies the strip's settings. An automated parameter is driven by automation instead,
  /// so its static setting is neutralized here (unity gain, centre pan).
  func applyMix(_ channel: ChannelStrip, isAudible: Bool, automated: Set<AutomationParameter> = []) {
    let volumeIsAutomated = automated.contains(.volume)
    fader.outputVolume = isAudible ? (volumeIsAutomated ? 1 : Float(channel.linearGain)) : 0
    if !volumeIsAutomated {
      setFaderParameter(FaderParameter.inputGain, to: 1)
    }
    let panIsAutomated = automated.contains(.pan)
    fader.pan = panIsAutomated ? 0 : Float(channel.pan)
    // A delayed connection's own mixer carries the pan into its destination.
    for edge in faderEdges.values {
      edge.mixer.pan = fader.pan
    }
    if !panIsAutomated {
      setFaderParameter(FaderParameter.outputPan, to: 0)
    }
  }

  /// Applies a fader level immediately, while the person is still dragging it.
  func setLiveVolume(_ decibels: Double) {
    fader.outputVolume = Self.engineValue(of: .volume, decibels)
  }

  /// Sets an automated parameter straight away (when the transport stops, say, or while a
  /// control is moved by hand during Touch or Latch).
  func setAutomatedValue(_ parameter: AutomationParameter, to value: Double) {
    switch parameter {
    case .volume, .pan:
      setFaderParameter(automation(for: parameter)?.address ?? 0, to: Self.engineValue(of: parameter, value))
    case .sendLevel, .plugin:
      target(for: parameter)?.setValue(value)
    }
  }

  /// What a mixer parameter is set to for a value: linear gain for decibels, -1...1 for pan.
  static func engineValue(of parameter: AutomationParameter, _ value: Double) -> Float {
    switch parameter {
    case .volume, .sendLevel: value <= ChannelStrip.volumeRange.lowerBound ? 0 : Float(pow(10, value / 20))
    case .pan, .plugin: Float(value)
    }
  }

  private func setFaderParameter(_ address: AUParameterAddress, to value: Float) {
    fader.withAUAudioUnit { unit in
      unit.parameterTree?.parameter(withAddress: address)?.value = value
    }
  }

  /// The queue a parameter's ramps go into, if it can be automated on this channel now.
  func automation(for parameter: AutomationParameter) -> AutomationQueue? {
    switch parameter {
    case .volume: volumeAutomation
    case .pan: panAutomation
    case .sendLevel, .plugin: target(for: parameter)?.queue
    }
  }

  /// Makes sure every automated send and plug-in parameter has its target, with its render
  /// observer installed, before the transport starts (a node's timeline is only known once
  /// it has rendered with its observer in place). Targets for nodes that went away go too.
  func prepareAutomation(for parameters: Set<AutomationParameter>) {
    for (parameter, target) in targets where !parameters.contains(parameter) || currentNode(for: parameter) !== target.node {
      removeTarget(target)
      targets[parameter] = nil
    }
    for parameter in parameters where targets[parameter] == nil {
      _ = target(for: parameter)
    }
  }

  /// The node a send or plug-in parameter lives on now: an automated send's own mixer, or
  /// the plug-in.
  private func currentNode(for parameter: AutomationParameter) -> AVAudioNode? {
    switch parameter {
    case .volume, .pan:
      return fader
    case .sendLevel(let id):
      guard let send = routing.flatMap({ $0.send(id) }) else { return nil }
      return (send.isPreFader ? preFaderEdges : faderEdges)[.aux(send.destination.trackID)]?.mixer
    case .plugin(let parameter):
      return inserts.first { $0.reference.id == parameter.pluginID }?.unit
    }
  }

  private func target(for parameter: AutomationParameter) -> AutomationTarget? {
    guard let node = currentNode(for: parameter) else { return nil }
    if let existing = targets[parameter], existing.node === node { return existing }
    if let stale = targets[parameter] { removeTarget(stale) }

    let target: AutomationTarget
    switch parameter {
    case .volume, .pan:
      return nil
    case .sendLevel:
      target = AutomationTarget(node: node, address: FaderParameter.outputGain, clock: RenderClock()) {
        Self.engineValue(of: parameter, $0)
      }
    case .plugin(let pluginParameter):
      let address = pluginParameter.address
      guard let bounds = node.withAUAudioUnit({ unit in
        unit.parameterTree?.parameter(withAddress: address).map { (Double($0.minValue), Double($0.maxValue)) }
      }) ?? nil else { return nil }
      let (minimum, maximum) = bounds
      target = AutomationTarget(node: node, address: pluginParameter.address, clock: RenderClock()) { value in
        Float(minimum + min(max(value, 0), 1) * (maximum - minimum))
      }
    }
    let queue = target.queue
    let clock = target.clock
    target.observerToken = node.withAUAudioUnit { unit in
      unit.token(byAddingRenderObserver: Self.observer(queues: [queue], clock: clock, schedule: unit.scheduleParameterBlock))
    }
    targets[parameter] = target
    return target
  }

  private func removeTarget(_ target: AutomationTarget) {
    target.queue.flush()
    if let token = target.observerToken {
      target.node.withAUAudioUnit { $0.removeRenderObserver(token) }
    }
    target.observerToken = nil
  }

  /// How much later than the fader's input a parameter's node gets the music, beyond the
  /// fader latency: a send's compensating delay, or minus the latency of the plug-ins from
  /// this one on (a plug-in hears the music before they delay it).
  private func extraDelay(for parameter: AutomationParameter) -> Int {
    switch parameter {
    case .volume, .pan:
      return 0
    case .sendLevel(let id):
      return routing.flatMap { $0.send(id)?.destination.delay } ?? 0
    case .plugin(let pluginParameter):
      guard let index = inserts.firstIndex(where: { $0.reference.id == pluginParameter.pluginID }) else { return 0 }
      return -inserts[index...].filter { !$0.reference.isBypassed }.reduce(0) { total, insert in
        total + Int((insert.unit.withAUAudioUnit { $0.latency } * format.sampleRate).rounded())
      }
    }
  }

  /// Where the music starts in a node's timeline for the current run, once known.
  private func anchoredStart(clock: RenderClock, node: AVAudioNode) -> Int64? {
    let key = ObjectIdentifier(node)
    if let start = anchoredStarts[key] { return start }
    guard let anchor else { return nil }
    let start: Int64?
    switch anchor {
    case .hostTime(let hostTime):
      start = clock.sampleTime(atHostTime: hostTime, sampleRate: format.sampleRate)
    case .offline(let musicStart, let prerollStart):
      // Every node first rendered during the preroll, which began at `prerollStart`.
      start = clock.lastRender().map { $0.sampleTime - prerollStart + musicStart }
    }
    if let start { anchoredStarts[key] = start }
    return start
  }

  /// Queues a ramp between two times (seconds after the music starts). Ramps in decibels
  /// are straight in decibels, so they're split into pieces (straight in gain) that change
  /// by at most half a decibel each; a fade then sounds the same as its curve looks.
  func schedule(_ parameter: AutomationParameter, from startTime: Double, to endTime: Double, startValue: Double, endValue: Double) {
    let queue: AutomationQueue
    let start: Int64
    let toEngine: (Double) -> Float
    switch parameter {
    case .volume, .pan:
      guard let anchored = anchoredStart(clock: renderClock, node: fader), let faderQueue = automation(for: parameter) else { return }
      queue = faderQueue
      start = anchored
      toEngine = { Self.engineValue(of: parameter, $0) }
    case .sendLevel, .plugin:
      guard let target = target(for: parameter), let anchored = anchoredStart(clock: target.clock, node: target.node) else { return }
      queue = target.queue
      start = anchored
      toEngine = target.engineValue
    }
    let rate = format.sampleRate
    let offset = start + Int64(faderLatency + extraDelay(for: parameter))
    let from = offset + Int64((startTime * rate).rounded())
    let to = offset + Int64((endTime * rate).rounded())
    guard to > from else { return }
    let pieces = parameter.isDecibels ? Int(min(max((abs(endValue - startValue) / 0.5).rounded(.up), 1), 256, Double(to - from))) : 1
    for piece in 0..<pieces {
      let fromFraction = Double(piece) / Double(pieces)
      let toFraction = Double(piece + 1) / Double(pieces)
      queue.push(AutomationQueue.Ramp(
        start: from + Int64((Double(to - from) * fromFraction).rounded()),
        end: from + Int64((Double(to - from) * toFraction).rounded()),
        from: toEngine(startValue + (endValue - startValue) * fromFraction),
        to: toEngine(startValue + (endValue - startValue) * toFraction)))
    }
  }

  func flushAutomation() {
    volumeAutomation.flush()
    panAutomation.flush()
    for target in targets.values {
      target.queue.flush()
    }
  }

  /// Hands each buffer its part of the fader's automation, just before the fader renders it.
  private func installAutomationObserver() {
    observerToken = fader.withAUAudioUnit { unit in
      unit.token(byAddingRenderObserver: Self.observer(
        queues: [volumeAutomation, panAutomation], clock: renderClock, schedule: unit.scheduleParameterBlock))
    }
  }

  /// A render observer that records a node's clock and delivers its queued automation. Made
  /// outside the main actor: it runs on the render thread.
  nonisolated private static func observer(
    queues: [AutomationQueue], clock: RenderClock, schedule: @escaping AUScheduleParameterBlock
  ) -> AURenderObserver {
    { flags, timestamp, frameCount, _ in
      guard flags.contains(.unitRenderAction_PreRender) else { return }
      clock.record(timestamp.pointee)
      let start = Int64(timestamp.pointee.mSampleTime)
      for queue in queues {
        queue.deliver(bufferStart: start, frameCount: Int64(frameCount), to: schedule)
      }
    }
  }

  /// Connects the fader to its output (Stereo Out or an aux) and both send points to aux
  /// inputs. Reconnects only when the set of destinations changes; level changes just
  /// update the connections.
  func applyRouting(_ newRouting: Routing, auxInputs: [Track.ID: AVAudioMixerNode]) throws {
    if routing.map({ destinations($0) }) != destinations(newRouting) {
      try connect(
        fader, to: newRouting.postFader, includingMain: true, output: newRouting.output, outputDelay: newRouting.outputDelay,
        edges: &faderEdges, auxInputs: auxInputs)
      try connect(
        preFader, to: newRouting.preFader, includingMain: false, output: nil, outputDelay: 0, edges: &preFaderEdges,
        auxInputs: auxInputs)
    }
    // Delays that only changed length (within the same number of units) don't need
    // reconnecting.
    for (destinations, edges) in [(newRouting.postFader, faderEdges), (newRouting.preFader, preFaderEdges)] {
      for destination in destinations {
        if let edge = edges[.aux(destination.trackID)] { SampleDelay.set(edge.delays, to: destination.delay) }
      }
    }
    if let edge = faderEdges[newRouting.output.map(EdgeKey.aux) ?? .main] {
      SampleDelay.set(edge.delays, to: newRouting.outputDelay)
    }

    for (source, destinations, edges) in [(fader, newRouting.postFader, faderEdges), (preFader, newRouting.preFader, preFaderEdges)] {
      for destination in destinations {
        guard let aux = auxInputs[destination.trackID], let bus = auxBuses[destination.trackID] else { continue }
        let feeder: any AVAudioMixing = edges[.aux(destination.trackID)]?.mixer ?? source
        // An automated send's level is its own mixer's gain, which automation drives.
        feeder.destination(forMixer: aux, bus: bus)?.volume = destination.isAutomated ? 1 : destination.level
      }
    }
    if let output = newRouting.output, let aux = auxInputs[output], let bus = auxBuses[output] {
      let feeder: any AVAudioMixing = faderEdges[.aux(output)]?.mixer ?? fader
      feeder.destination(forMixer: aux, bus: bus)?.volume = 1
    }
    routing = newRouting
  }

  /// What needs a reconnection: the destinations, and how many delay units each needs.
  private func destinations(_ routing: Routing) -> [[String]] {
    func key(_ destination: Routing.Destination) -> String {
      "\(destination.trackID)×\(SampleDelay.unitCount(for: destination.delay))\(destination.isAutomated ? "a" : "")"
    }
    let output = routing.output.map { "\($0)" } ?? "main"
    return [routing.postFader.map(key), routing.preFader.map(key), ["\(output)×\(SampleDelay.unitCount(for: routing.outputDelay))"]]
  }

  /// The input bus used on each aux this channel sends to.
  private var auxBuses: [Track.ID: AVAudioNodeBus] = [:]

  private func connect(
    _ source: AVAudioMixerNode, to destinations: [Routing.Destination], includingMain: Bool, output: Track.ID?,
    outputDelay: Int, edges: inout [EdgeKey: DelayEdge], auxInputs: [Track.ID: AVAudioMixerNode]
  ) throws {
    // Where each connection goes, and how much it's delayed.
    var targets: [(key: EdgeKey, node: AVAudioMixerNode, bus: AVAudioNodeBus, delay: Int, needsMixer: Bool)] = []
    var points: [AVAudioConnectionPoint] = []
    if includingMain, let output, let aux = auxInputs[output] {
      // Output to an aux (a summing stack, say) instead of Stereo Out.
      let bus = auxBuses[output] ?? engine.freeInputBus(on: aux, for: source)
      auxBuses[output] = bus
      targets.append((.aux(output), aux, bus, outputDelay, false))
    } else if includingMain, let mainBus {
      targets.append((.main, mainOutput, mainBus, outputDelay, false))
    } else if !includingMain {
      // The pre-fader node always feeds the fader.
      points.append(AVAudioConnectionPoint(node: fader, bus: 0))
    }
    for destination in destinations {
      guard let aux = auxInputs[destination.trackID] else { continue }
      let bus = auxBuses[destination.trackID] ?? engine.freeInputBus(on: aux, for: source)
      auxBuses[destination.trackID] = bus
      targets.append((.aux(destination.trackID), aux, bus, destination.delay, destination.isAutomated))
    }

    // Delayed connections go through delays and their own mixer; the rest go straight there.
    var usedEdges: Set<EdgeKey> = []
    for target in targets {
      let unitCount = SampleDelay.unitCount(for: target.delay)
      // A delayed or automated connection goes through its own mixer.
      guard unitCount > 0 || target.needsMixer else {
        points.append(AVAudioConnectionPoint(node: target.node, bus: target.bus))
        continue
      }
      if let existing = edges[target.key], existing.delays.count != unitCount {
        for node in existing.nodes { engine.detach(node) }
        edges[target.key] = nil
      }
      let edge = try edges[target.key] ?? makeDelayEdge(unitCount: unitCount)
      edges[target.key] = edge
      usedEdges.insert(target.key)
      SampleDelay.set(edge.delays, to: target.delay)
      edge.mixer.pan = source === fader ? fader.pan : 0
      engine.disconnectNodeOutput(edge.mixer)
      try engine.connectNode(edge.mixer, to: target.node, fromBus: 0, toBus: target.bus, format: format)
      if let first = edge.nodes.first {
        points.append(AVAudioConnectionPoint(node: first, bus: 0))
      }
    }
    for (key, edge) in edges where !usedEdges.contains(key) {
      for node in edge.nodes { engine.detach(node) }
      edges[key] = nil
    }
    engine.disconnectNodeOutput(source)
    if points.count == 1, let point = points.first, let node = point.node {
      // One destination (no sends on this side): a plain connection.
      try engine.connectNode(source, to: node, fromBus: 0, toBus: point.bus, format: format)
    } else {
      try engine.connectNode(source, to: points, fromBus: 0, format: format)
    }
  }

  /// Delays chained into their mixer, from the mixer back (see `init` on connection order).
  private func makeDelayEdge(unitCount: Int) throws -> DelayEdge {
    let edge = DelayEdge(delays: (0..<unitCount).map { _ in SampleDelay.makeUnit() }, mixer: AVAudioMixerNode())
    for node in edge.nodes { engine.attach(node) }
    let chain = edge.nodes
    for index in chain.indices.dropLast().reversed() {
      try engine.connectNode(chain[index], to: chain[index + 1], format: format)
    }
    return edge
  }

  // MARK: - Inserts

  /// Brings the insert chain in line with the channel strip: reuses loaded plug-ins, loads
  /// new ones (Apple's effects in process, others out of process) and applies bypass.
  func setInserts(
    _ references: [PluginReference], onLoadFailure: @escaping (PluginReference, any Error) -> Void,
    onInstalled: @escaping () -> Void
  ) {
    wantedInserts = references
    let wantedIDs = Set(references.map(\.id))
    for (id, task) in pendingInserts where !wantedIDs.contains(id) {
      task.cancel()
      pendingInserts[id] = nil
    }
    for reference in references where !inserts.contains(where: { $0.reference.id == reference.id }) {
      guard pendingInserts[reference.id] == nil else { continue }
      if BuiltInEffect.isBuiltIn(reference) {
        let unit = AVAudioUnitEffect(audioComponentDescription: Self.description(of: reference))
        install(unit, for: reference)
      } else {
        pendingInserts[reference.id] = Task { [weak self] in
          do {
            let unit = try await AVAudioUnit.instantiate(with: Self.description(of: reference), options: [.loadOutOfProcess])
            guard let self, !Task.isCancelled else { return }
            self.pendingInserts[reference.id] = nil
            self.install(unit, for: reference)
            self.rebuildChain()
            onInstalled()
          } catch {
            self?.pendingInserts[reference.id] = nil
            onLoadFailure(reference, error)
          }
        }
      }
    }
    rebuildChain()
  }

  private func install(_ unit: AVAudioUnit, for reference: PluginReference) {
    if let musicalContext {
      unit.withAUAudioUnit { $0.musicalContextBlock = musicalContext.block }
    }
    if let state = reference.state,
      let fullState = try? PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any]
    {
      unit.withAUAudioUnit { $0.fullState = fullState }
    }
    engine.attach(unit)
    inserts.append(Insert(reference: reference, unit: unit))
  }

  /// Reconnects input → loaded inserts (in the strip's order) → pre-fader, and detaches
  /// plug-ins that were removed.
  private func rebuildChain() {
    let order = wantedInserts.map(\.id)
    for removed in inserts where !order.contains(removed.reference.id) {
      engine.detach(removed.unit)
    }
    inserts = inserts.filter { order.contains($0.reference.id) }
      .sorted { order.firstIndex(of: $0.reference.id)! < order.firstIndex(of: $1.reference.id)! }
    for (index, insert) in inserts.enumerated() {
      if let wanted = wantedInserts.first(where: { $0.id == insert.reference.id }) {
        if wanted.state != insert.reference.state {
          applyState(wanted.state, to: insert.unit)
        }
        inserts[index].reference = wanted
        insert.unit.withAUAudioUnit { $0.shouldBypassEffect = wanted.isBypassed }
      }
    }

    // Reconnecting interrupts the sound, so leave an unchanged chain alone.
    let chain = inserts.map(\.reference.id)
    guard chain != connectedChain else { return }
    connectedChain = chain

    engine.disconnectNodeOutput(input)
    for insert in inserts {
      engine.disconnectNodeOutput(insert.unit)
    }
    var previous: AVAudioNode = input
    do {
      for insert in inserts {
        try engine.connectNode(previous, to: insert.unit, format: format)
        previous = insert.unit
      }
      try engine.connectNode(previous, to: preFader, format: format)
    } catch {
      // Fall back to a straight connection so the track still plays.
      try? engine.connectNode(input, to: preFader, format: format)
    }
  }

  /// The project's settings for a loaded plug-in changed (an undo, or Analyze Whole Song):
  /// it takes them, unless it has them already, as it does when they came from its own
  /// window as it closed.
  private func applyState(_ state: Data?, to unit: AVAudioUnit) {
    guard let state, let fullState = try? PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any]
    else { return }
    let current = unit.withAUAudioUnit { $0.fullState }
    if let current, NSDictionary(dictionary: current).isEqual(to: fullState) { return }
    unit.withAUAudioUnit { $0.fullState = fullState }
  }

  private static func description(of reference: PluginReference) -> AudioComponentDescription {
    AudioComponentDescription(
      componentType: reference.componentType, componentSubType: reference.componentSubType,
      componentManufacturer: reference.componentManufacturer, componentFlags: 0, componentFlagsMask: 0)
  }

  /// Scoped access to a loaded insert, for its interface and saved settings.
  func withInsertAudioUnit<Result>(_ pluginID: PluginReference.ID, _ body: (borrowing AUAudioUnit) -> Result) -> Result? {
    inserts.first { $0.reference.id == pluginID }?.unit.withAUAudioUnit(body)
  }

  /// Waits until every plug-in that is loading has been installed (or has failed).
  func waitForPendingInserts() async {
    while let task = pendingInserts.values.first {
      await task.value
    }
  }

  func isLoadingInsert(_ pluginID: PluginReference.ID) -> Bool {
    pendingInserts[pluginID] != nil
  }

  func insertState(_ pluginID: PluginReference.ID) -> Data? {
    guard let fullState = withInsertAudioUnit(pluginID, { $0.fullState }) ?? nil else { return nil }
    return try? PropertyListSerialization.data(fromPropertyList: fullState, format: .binary, options: 0)
  }

  func detach() {
    for task in pendingInserts.values {
      task.cancel()
    }
    for insert in inserts {
      engine.detach(insert.unit)
    }
    inserts = []
    flushAutomation()
    if let observerToken {
      fader.withAUAudioUnit { $0.removeRenderObserver(observerToken) }
    }
    observerToken = nil
    for target in targets.values {
      removeTarget(target)
    }
    targets = [:]
    for edge in Array(faderEdges.values) + Array(preFaderEdges.values) {
      for node in edge.nodes { engine.detach(node) }
    }
    faderEdges = [:]
    preFaderEdges = [:]
    for node in [input, preFader, fader] {
      engine.detach(node)
    }
  }
}

extension AVAudioEngine {
  /// Input buses handed out by `freeInputBus(on:for:)`, by mixer, with the node each was
  /// handed to.
  @MainActor private static var claimedBuses: [ObjectIdentifier: [AVAudioNodeBus: WeakNode]] = [:]

  private struct WeakNode {
    weak var node: AVAudioNode?
  }

  /// An input bus of `mixer` for `source` to connect to, that no other node is using.
  ///
  /// Don't use the mixer's `nextAvailableInputBus`: on a running engine, connections only
  /// show up in the graph later, so it keeps returning the same bus, and several channels
  /// added at once would each replace the previous one's connection and only the last
  /// would be heard. So buses handed out here stay taken for as long as the node they went
  /// to is attached to this engine.
  @MainActor
  func freeInputBus(on mixer: AVAudioMixerNode, for source: AVAudioNode) -> AVAudioNodeBus {
    let key = ObjectIdentifier(mixer)
    var claims = Self.claimedBuses[key, default: [:]].filter { _, claim in
      guard let node = claim.node else { return false }
      return node !== source && node.engine === self
    }
    var bus: AVAudioNodeBus = 0
    while claims[bus] != nil || inputConnectionPoint(for: mixer, inputBus: bus).map({ $0.node !== source }) == true {
      bus += 1
    }
    claims[bus] = WeakNode(node: source)
    Self.claimedBuses[key] = claims
    return bus
  }
}
