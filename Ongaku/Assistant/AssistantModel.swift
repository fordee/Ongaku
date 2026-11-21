//
//  AssistantModel.swift
//  Ongaku
//

import Foundation
import FoundationModels
import OngakuCore

/// The Assistant: asks Apple's on-device model to do things in the song with Ongaku's agent
/// tools. Nothing leaves the Mac.
///
/// The model's context is small (about 4,096 tokens), so each request is answered in two
/// steps: a tiny request sorts it into an `AgentArea`, then a fresh session answers it with
/// that area's tools, a short guide and a summary of the song.
@MainActor
@Observable
final class AssistantModel {
  struct Message: Identifiable, Equatable {
    enum Role { case person, assistant, problem }
    let id = UUID()
    var role: Role
    var text: String
    /// The tools it used, by title: "Set Tempo", "Add Notes"…
    var actions: [String] = []
  }

  var messages: [Message] = []
  var draft = ""
  private(set) var isResponding = false
  /// The tool running now, to show while it works.
  private(set) var currentAction: String?
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var actions: [String] = []

  /// Why the assistant can't be used on this Mac now, or `nil` when it can.
  var unavailableReason: String? {
    Self.explanation(of: SystemLanguageModel.default.availability)
  }

  static func explanation(of availability: SystemLanguageModel.Availability) -> String? {
    switch availability {
    case .available: nil
    case .unavailable(.appleIntelligenceNotEnabled):
      "Turn on Apple Intelligence in System Settings › Apple Intelligence & Siri to use the Assistant."
    case .unavailable(.deviceNotEligible):
      "The Assistant needs a Mac that supports Apple Intelligence."
    case .unavailable(.modelNotReady):
      "Apple Intelligence is still getting ready on this Mac (it downloads its model in the background). Try again in a while."
    case .unavailable:
      "Apple Intelligence isn’t available on this Mac right now."
    }
  }

  /// Sends what's typed.
  func send(in window: ProjectWindowModel) {
    let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !request.isEmpty, !isResponding else { return }
    draft = ""
    let earlier = lastExchange
    messages.append(Message(role: .person, text: request))
    isResponding = true
    actions = []
    task = Task { [weak self, weak window] in
      guard let self else { return }
      defer {
        isResponding = false
        currentAction = nil
        task = nil
      }
      do {
        guard let window else { return }
        let reply = try await respond(to: request, earlier: earlier, in: window)
        if actions.isEmpty, let failure = lastFailure {
          // Every call failed, whatever the reply says.
          messages.append(Message(role: .problem, text: "Nothing changed. \(failure)"))
        } else {
          messages.append(Message(role: .assistant, text: reply, actions: actions))
        }
      } catch is CancellationError {
        messages.append(Message(role: .problem, text: "Stopped.", actions: actions))
      } catch {
        messages.append(Message(role: .problem, text: Self.describe(error), actions: actions))
      }
    }
  }

  func stop() {
    task?.cancel()
  }

  func clear() {
    stop()
    messages = []
  }

  // MARK: Answering

  /// The same answer each time, which also keeps the small model from wandering.
  static let options = GenerationOptions(sampling: .greedy)

  /// Most tool calls one request may make: the small model sometimes repeats itself.
  static let maximumToolCalls = 6

  private func respond(to request: String, earlier: String?, in window: ProjectWindowModel) async throws -> String {
    let names = try await Self.toolNames(for: request, earlier: earlier)
    try Task.checkCancellation()
    calls = [:]
    lastFailure = nil
    let tools: [any Tool] = try names.compactMap(AgentToolbox.tool(named:)).map { tool in
      try AgentToolAdapter(tool) { [weak self, weak window] name, arguments in
        guard let self, let window else { return "The song's window has closed." }
        return try await self.call(name, arguments: arguments, in: window)
      }
    }
    let readsOnly = names.allSatisfy { AgentToolbox.tool(named: $0)?.isReadOnly == true }
    do {
      let session = LanguageModelSession(
        tools: tools, instructions: await instructions(in: window, summaryLength: 1_200, earlier: earlier))
      let reply = try await session.respond(to: request, options: Self.options).content
      guard calls.isEmpty, !readsOnly else { return reply }
      // It answered without doing anything: once more, made to use its tools. A repeated call
      // ends that.
      isRequiringTools = true
      defer { isRequiringTools = false }
      let required = LanguageModelSession(tools: tools, instructions: await instructions(in: window, summaryLength: 1_200, earlier: nil))
      do {
        var options = Self.options
        options.toolCallingMode = .required
        return try await required.respond(to: request, options: options).content
      } catch let error as LanguageModelSession.ToolCallError where error.underlyingError is Finished {
        return actions.isEmpty ? "I couldn’t do that." : "Done: \(actions.joined(separator: ", "))."
      }
    } catch where Self.isContextOverflow(error) && calls.isEmpty {
      // Too much for the context before anything changed: again, with less of the song and
      // nothing from before.
      let session = LanguageModelSession(tools: tools, instructions: await instructions(in: window, summaryLength: 300, earlier: nil))
      return try await session.respond(to: request, options: Self.options).content
    }
  }

  /// Ends a request whose model must call tools.
  private struct Finished: Error {}
  @ObservationIgnored private var isRequiringTools = false

  /// The tools a request needs, one to three of them, chosen by a small first request that
  /// sees only their names and first sentences.
  static func toolNames(for request: String, earlier: String?) async throws -> [String] {
    let names = pickableToolNames
    let schema = try GenerationSchema(
      root: DynamicGenerationSchema(
        arrayOf: DynamicGenerationSchema(name: "Tool", description: "A tool's name.", anyOf: names), minimumElements: 1,
        maximumElements: 3),
      dependencies: [])
    let session = LanguageModelSession(instructions: pickerInstructions)
    var prompt = request
    if let earlier { prompt = "(Earlier: \(earlier))\n\(request)" }
    // The schema only lists the names, which the instructions already have.
    let response = try await session.respond(
      to: prompt, schema: schema, includeSchemaInPrompt: false, options: options)
    let chosen = (try? JSONDecoder().decode([String].self, from: Data(response.content.jsonString.utf8))) ?? []
    var unique: [String] = []
    for name in chosen where names.contains(name) && !unique.contains(name) { unique.append(name) }
    return unique
  }

  /// Every tool but get_song (the instructions have the song), area by area.
  static let pickableToolNames: [String] = {
    var names: [String] = []
    for name in ["undo"] + AgentArea.allCases.flatMap(\.toolNames) where !names.contains(name) { names.append(name) }
    return names
  }()

  /// The tools by name and title, which is all the picker needs.
  static let pickerInstructions: String = {
    let tools = pickableToolNames.compactMap(AgentToolbox.tool(named:)).map { "\($0.name) (\($0.title))" }
    return """
      Choose the fewest tools (one to three) a music app's assistant needs to do the person's \
      request. It already knows the song's tracks, sections and tempo. Prefer one tool that does \
      the whole job: add_drummer, add_session_player and add_loop make their own tracks.
      Tools: \(tools.joined(separator: ", ")).
      """
  }()

  /// The short guide and what's in the song now, cut to `summaryLength` characters.
  private func instructions(in window: ProjectWindowModel, summaryLength: Int, earlier: String?) async -> String {
    let song = (try? await AgentToolbox.call("get_song", arguments: [:], in: window, pitchNaming: AppSettings.agentPitchNaming))?
      .jsonString ?? "{}"
    return AgentToolbox.compactInstructions(pitchNaming: AppSettings.agentPitchNaming)
      + "\n\nThe song now (what get_song shows): " + Self.shortened(song, to: summaryLength)
      + (earlier.map { "\n\nBefore this request, \($0)." } ?? "")
  }

  /// This request's tool calls, by name and arguments, with what they returned.
  @ObservationIgnored private var calls: [String: String] = [:]
  /// Why this request's last failed call failed.
  @ObservationIgnored private var lastFailure: String?

  /// Runs one of the model's tool calls on the window, as an MCP agent's would run.
  private func call(_ name: String, arguments: [String: AgentValue], in window: ProjectWindowModel) async throws -> String {
    if Task.isCancelled { return "The person stopped the request." }
    let key = name + AgentValue.object(arguments).jsonString
    if calls[key] != nil, isRequiringTools { throw Finished() }
    if let earlier = calls[key] { return "You already did that, and it returned: \(earlier) Now answer the person." }
    guard calls.count < Self.maximumToolCalls else {
      if isRequiringTools { throw Finished() }
      return "That's enough tool calls for one request. Answer the person now."
    }
    let title = AgentToolbox.tool(named: name)?.title ?? name
    currentAction = title
    defer { currentAction = nil }
    let result: String
    do {
      let value = try await AgentToolbox.call(name, arguments: arguments, in: window, pitchNaming: AppSettings.agentPitchNaming)
      actions.append(title)
      result = Self.shortened(value.jsonString, to: 800)
    } catch {
      lastFailure = error.localizedDescription
      result = "That didn't work: \(error.localizedDescription)"
    }
    calls[key] = result
    return result
  }

  static func isContextOverflow(_ error: any Error) -> Bool {
    if let error = error as? LanguageModelError, case .contextSizeExceeded = error { return true }
    if let error = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = error { return true }
    if let error = error as? LanguageModelSession.ToolCallError { return isContextOverflow(error.underlyingError) }
    // The on-device model also reports it with a private error type.
    return String(describing: error).contains("maximum allowed")
  }

  /// The last request and reply, so "make it louder" knows what "it" is.
  private var lastExchange: String? {
    guard let reply = messages.last, reply.role == .assistant,
      let request = messages.dropLast().last, request.role == .person
    else { return nil }
    return Self.shortened("the person asked “\(request.text)”; you replied “\(reply.text)”", to: 400)
  }

  static func shortened(_ text: String, to length: Int) -> String {
    text.count <= length ? text : String(text.prefix(length)) + "…"
  }

  static func describe(_ error: any Error) -> String {
    if isContextOverflow(error) {
      return "That was too much for the on-device model at once. Try asking for one thing at a time."
    }
    if let explanation = explanation(of: SystemLanguageModel.default.availability) { return explanation }
    return "The assistant couldn’t answer: \(error.localizedDescription)"
  }
}

extension ProjectWindowModel {
  func toggleAssistant() {
    isAssistantVisible.toggle()
  }
}
