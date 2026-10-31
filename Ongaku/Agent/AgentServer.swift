//
//  AgentServer.swift
//  Ongaku
//

import AppKit
import MCP
import Network
import Observation
import OngakuCore

/// Ongaku's MCP server, which lets AI agents (Claude Code, Claude Desktop and others) make
/// music in the frontmost song with the tools in `AgentToolbox`.
///
/// It's off until it's switched on in Settings › Agents, listens on this Mac only, and wants
/// the token shown there. Each tool call is one undoable step in the song's window.
@MainActor
@Observable
final class AgentServer {
  static let shared = AgentServer()

  enum Status: Equatable {
    case off
    case starting
    case listening(port: Int)
    case failed(String)
  }

  private(set) var status: Status = .off
  /// The agents connected, by the names they gave.
  private(set) var clients: [String] = []
  /// How many tool calls are running, so the control bar's badge can glow while an agent works.
  private(set) var callsInProgress = 0
  /// What an agent did last ("Add Drummer"), and whether it worked.
  private(set) var lastAction: (title: String, succeeded: Bool, date: Date)?

  @ObservationIgnored private var http: AgentHTTPServer?
  @ObservationIgnored private var running: (port: Int, token: String)?
  /// Project windows, most recently opened last.
  @ObservationIgnored private var windows: [WeakWindow] = []

  private struct WeakWindow {
    weak var model: ProjectWindowModel?
  }

  private init() {
    Task { [weak self] in
      for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
        self?.applySettings()
      }
    }
  }

  /// An agent's name as people say it: "claude-code" is "Claude Code".
  nonisolated static func displayName(_ clientName: String) -> String {
    guard clientName == clientName.lowercased(), clientName.contains(where: { $0 == "-" || $0 == "_" }) else { return clientName }
    return clientName.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
  }

  #if DEBUG
  /// For previews: shows an agent as connected (and working).
  func showForPreview(_ names: [String], working: Bool) {
    clients = names
    callsInProgress = working ? 1 : 0
  }
  #endif

  // MARK: - Windows

  func register(_ model: ProjectWindowModel) {
    windows.removeAll { $0.model == nil || $0.model === model }
    windows.append(WeakWindow(model: model))
  }

  func unregister(_ model: ProjectWindowModel) {
    windows.removeAll { $0.model == nil || $0.model === model }
  }

  /// The song agents work on: the frontmost project window's, else the last one opened.
  var activeWindow: ProjectWindowModel? {
    let open = windows.compactMap(\.model)
    if let main = NSApp.mainWindow, let model = open.first(where: { $0.hostWindow === main }) { return model }
    let ordered = NSApp.orderedWindows
    // Frontmost first; among windows that aren't on screen, the last opened.
    return open.reversed().min { lhs, rhs in
      (lhs.hostWindow.flatMap(ordered.firstIndex(of:)) ?? .max) < (rhs.hostWindow.flatMap(ordered.firstIndex(of:)) ?? .max)
    }
  }

  // MARK: - Starting and stopping

  /// Starts, stops or restarts the server to match Settings › Agents.
  func applySettings() {
    let wanted = AppSettings.isAgentServerEnabled ? (port: AppSettings.agentServerPort, token: AppSettings.agentServerToken) : nil
    guard wanted?.port != running?.port || wanted?.token != running?.token else { return }
    running = wanted
    let previous = http
    http = nil
    Task {
      await previous?.stop()
      guard let wanted else {
        status = .off
        return
      }
      await start(port: wanted.port, token: wanted.token)
    }
  }

  private func start(port: Int, token: String) async {
    status = .starting
    let server = AgentHTTPServer(
      port: UInt16(clamping: port), token: token, makeServer: { await AgentServer.makeMCPServer() },
      clientsChanged: { clients in await MainActor.run { AgentServer.shared.clients = clients.map(AgentServer.displayName) } })
    do {
      try await server.start()
      // Settings may have changed while it started.
      guard running?.port == port, running?.token == token else {
        await server.stop()
        return
      }
      http = server
      status = .listening(port: port)
    } catch {
      await server.stop()
      if running?.port == port { status = .failed(Self.describe(error, port: port)) }
    }
  }

  private static func describe(_ error: any Error, port: Int) -> String {
    if case .posix(let code)? = error as? NWError, code == .EADDRINUSE {
      return "Port \(port) is in use by another app; choose another."
    }
    return error.localizedDescription
  }

  /// The address agents connect to.
  var url: String { "http://127.0.0.1:\(AppSettings.agentServerPort)\(AgentHTTPServer.endpoint)" }

  /// The command that adds Ongaku to Claude Code.
  var claudeCodeCommand: String {
    "claude mcp add --transport http ongaku \(url) --header \"Authorization: Bearer \(AppSettings.agentServerToken)\""
  }

  // MARK: - MCP

  /// A server for one agent's session.
  nonisolated static func makeMCPServer() async -> Server {
    let server = Server(
      name: "ongaku-studio", version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
      title: "Ongaku Studio", instructions: AgentToolbox.instructions,
      capabilities: .init(
        prompts: .init(listChanged: false), resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)))
    await server.withMethodHandler(ListTools.self) { _ in
      ListTools.Result(tools: AgentToolbox.tools.map(mcpTool))
    }
    await server.withMethodHandler(CallTool.self) { parameters in
      await call(parameters.name, arguments: parameters.arguments ?? [:])
    }
    await server.withMethodHandler(ListPrompts.self) { _ in
      ListPrompts.Result(prompts: AgentPrompt.all.map { prompt in
        Prompt(
          name: prompt.name, title: prompt.title, description: prompt.description,
          arguments: prompt.arguments.map { Prompt.Argument(name: $0.name, description: $0.description, required: $0.isRequired) })
      })
    }
    await server.withMethodHandler(GetPrompt.self) { parameters in
      guard let prompt = AgentPrompt.named(parameters.name) else { throw MCPError.invalidParams("There's no prompt called \(parameters.name).") }
      do {
        let text = try prompt.message(parameters.arguments ?? [:])
        return GetPrompt.Result(description: prompt.description, messages: [.user(.text(text: text))])
      } catch {
        throw MCPError.invalidParams(error.localizedDescription)
      }
    }
    await server.withMethodHandler(ListResources.self) { _ in
      ListResources.Result(resources: AgentResources.list, nextCursor: nil)
    }
    await server.withMethodHandler(ReadResource.self) { parameters in
      guard let text = await AgentResources.read(parameters.uri) else {
        throw MCPError.invalidParams("There's no resource \(parameters.uri).")
      }
      return ReadResource.Result(contents: [.text(text.content, uri: parameters.uri, mimeType: text.mimeType)])
    }
    return server
  }

  nonisolated private static func mcpTool(_ tool: AgentTool) -> Tool {
    Tool(
      name: tool.name, title: tool.title, description: tool.description, inputSchema: Value(agentValue: tool.inputSchema),
      annotations: .init(
        title: tool.title, readOnlyHint: tool.isReadOnly, destructiveHint: tool.isDestructive, openWorldHint: false))
  }

  /// Runs a tool in the frontmost song. Failures go back to the agent as error results
  /// whose message says what to do instead.
  nonisolated private static func call(_ name: String, arguments: [String: MCP.Value]) async -> CallTool.Result {
    let converted = arguments.mapValues { AgentValue(mcpValue: $0) }
    let outcome: Result<String, any Error> = await Task { @MainActor in
      guard let window = AgentServer.shared.activeWindow else {
        return .failure(AgentError.notPossible("No song is open in Ongaku Studio. Ask the person to open or create one (File › New)."))
      }
      let server = AgentServer.shared
      server.callsInProgress += 1
      defer { server.callsInProgress -= 1 }
      let title = AgentToolbox.tool(named: name)?.title ?? name
      do {
        let result = try await AgentToolbox.call(name, arguments: converted, in: window).jsonString
        server.lastAction = (title, true, Date())
        return .success(result)
      } catch {
        server.lastAction = (title, false, Date())
        return .failure(error)
      }
    }.value
    switch outcome {
    case .success(let text):
      return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
    case .failure(let error):
      return CallTool.Result(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
    }
  }
}

extension AgentValue {
  nonisolated init(mcpValue value: MCP.Value) {
    switch value {
    case .null: self = .null
    case .bool(let flag): self = .bool(flag)
    case .int(let number): self = .int(number)
    case .double(let number): self = .double(number)
    case .string(let text): self = .string(text)
    case .data(mimeType: _, let data): self = .string(data.base64EncodedString())
    case .array(let items): self = .array(items.map { AgentValue(mcpValue: $0) })
    case .object(let items): self = .object(items.mapValues { AgentValue(mcpValue: $0) })
    }
  }
}

extension Value {
  nonisolated init(agentValue value: AgentValue) {
    switch value {
    case .null: self = .null
    case .bool(let flag): self = .bool(flag)
    case .int(let number): self = .int(number)
    case .double(let number): self = .double(number)
    case .string(let text): self = .string(text)
    case .array(let items): self = .array(items.map { Value(agentValue: $0) })
    case .object(let items): self = .object(items.mapValues { Value(agentValue: $0) })
    }
  }
}

/// What agents can read besides the tools: the song as it is now, and this manual.
nonisolated enum AgentResources {
  static let songURI = "ongaku://song"
  static let manualPrefix = "ongaku://manual/"

  /// The manual's chapters bundled with the app, by file name without ".md".
  static var chapters: [(name: String, title: String, url: URL)] {
    (Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: nil) ?? [])
      .filter { $0.lastPathComponent == "README.md" || $0.lastPathComponent.first?.isNumber == true }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { url in
        let name = url.deletingPathExtension().lastPathComponent
        let heading = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
        return (name == "README" ? "contents" : name, heading ?? name, url)
      }
  }

  static var list: [Resource] {
    [Resource(name: "song", uri: songURI, title: "The Song", description: "The song in the frontmost window, as get_song describes it.", mimeType: "application/json")]
      + chapters.map { chapter in
        Resource(
          name: chapter.name, uri: manualPrefix + chapter.name, title: "Manual: \(chapter.title)",
          description: "A chapter of the Ongaku Studio manual.", mimeType: "text/markdown")
      }
  }

  static func read(_ uri: String) async -> (content: String, mimeType: String)? {
    if uri == songURI {
      let song: String? = await Task { @MainActor in
        guard let window = AgentServer.shared.activeWindow else { return nil }
        return try? await AgentToolbox.call("get_song", arguments: [:], in: window).jsonString
      }.value
      return (song ?? #"{"error":"No song is open."}"#, "application/json")
    }
    guard uri.hasPrefix(manualPrefix) else { return nil }
    let name = String(uri.dropFirst(manualPrefix.count))
    guard let chapter = chapters.first(where: { $0.name == name }), let text = try? String(contentsOf: chapter.url, encoding: .utf8) else {
      return nil
    }
    return (text, "text/markdown")
  }
}
