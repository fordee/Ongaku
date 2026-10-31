//
//  AgentServerTests.swift
//  OngakuTests
//

import Foundation
import MCP
import OngakuCore
import OngakuEngine
@testable import Ongaku
import Testing

/// The MCP server end to end: an agent connecting over HTTP as Claude Code does, listing the
/// tools and making music in a window. It runs on its own port with its own token, so it
/// doesn't touch the app's settings or a server the person has switched on.
@MainActor
@Suite(.serialized)
struct AgentServerTests {
  private let port = Int.random(in: 41_000...48_000)
  private let token = "test-token-\(UUID().uuidString)"

  /// One MCP client session, sending requests as Claude Code does. The tests run inside
  /// the sandboxed app, which can't open connections to itself, so requests go straight to
  /// the server's handler rather than through a socket (`HTTPChannel` is the only part
  /// skipped).
  private struct Client {
    var server: AgentHTTPServer
    var port: Int
    var token: String?
    var sessionID: String?
    var nextID = 1

    /// Sends a JSON-RPC message, returning the HTTP status and the JSON-RPC reply (from a
    /// JSON body or the event stream the server answers with).
    mutating func send(_ method: String, _ params: [String: Any] = [:], notification: Bool = false) async throws
      -> (status: Int, reply: [String: Any]?)
    {
      var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
      if !notification {
        message["id"] = nextID
        nextID += 1
      }
      var headers = [
        "Host": "127.0.0.1:\(port)", "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
      ]
      if let token { headers["Authorization"] = "Bearer \(token)" }
      if let sessionID { headers["Mcp-Session-Id"] = sessionID }
      if method != "initialize" { headers["MCP-Protocol-Version"] = "2025-06-18" }
      let request = ParsedRequest(
        path: AgentHTTPServer.endpoint,
        http: HTTPRequest(method: "POST", headers: headers, body: try JSONSerialization.data(withJSONObject: message), path: AgentHTTPServer.endpoint))
      let response = await server.respond(to: request)
      if let id = response.headers.first(where: { $0.key.lowercased() == "mcp-session-id" })?.value { sessionID = id }
      var data = response.bodyData ?? Data()
      if case .stream(let stream, _) = response {
        for try await chunk in stream { data.append(chunk) }
      }
      let text = String(decoding: data, as: UTF8.self)
      let bodies = text.contains("data:")
        ? text.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        : [text]
      let replies = bodies.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
      return (response.statusCode, replies.first { $0["id"] != nil } ?? replies.first)
    }

    /// Calls a tool, returning its text and whether it failed.
    mutating func callTool(_ name: String, _ arguments: [String: Any] = [:]) async throws -> (text: String, isError: Bool) {
      let reply = try #require(try await send("tools/call", ["name": name, "arguments": arguments]).reply)
      let result = try #require(reply["result"] as? [String: Any], "\(reply)")
      let content = try #require(result["content"] as? [[String: Any]])
      return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }
  }

  private func startServer() async throws -> AgentHTTPServer {
    AgentHTTPServer(port: UInt16(port), token: token, makeServer: { await AgentServer.makeMCPServer() }, clientsChanged: { _ in })
  }

  @Test func anAgentConnectsListsToolsAndWritesASong() async throws {
    let server = try await startServer()
    let window = ProjectWindowModel(document: OngakuDocument(project: Project()))
    AgentServer.shared.register(window)
    defer {
      AgentServer.shared.unregister(window)
      window.engine.shutDown()
    }

    var client = Client(server: server, port: port, token: token)
    let initialize = try await client.send(
      "initialize",
      ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "test-agent", "version": "1"]])
    #expect(initialize.status == 200)
    let info = (initialize.reply?["result"] as? [String: Any])
    #expect((info?["serverInfo"] as? [String: Any])?["name"] as? String == "ongaku-studio")
    #expect((info?["instructions"] as? String)?.contains("bar:beat") == true)
    #expect(client.sessionID != nil)
    #expect(try await client.send("notifications/initialized", notification: true).status == 202)

    let list = try await client.send("tools/list")
    let tools = ((list.reply?["result"] as? [String: Any])?["tools"] as? [[String: Any]]) ?? []
    #expect(Set(tools.compactMap { $0["name"] as? String }) == Set(AgentToolbox.tools.map(\.name)))

    // A song in a few calls, each showing up in the window.
    #expect(try await client.callTool("set_tempo", ["bpm": 96]).isError == false)
    #expect(try await client.callTool("set_arrangement", ["sections": [["name": "Verse", "bars": 4], ["name": "Chorus", "bars": 4]]]).isError == false)
    #expect(try await client.callTool("set_chords", ["bars": ["Am", "F", "C", "G"], "to": "9"]).isError == false)
    #expect(try await client.callTool("add_drummer", ["style": "pop"]).isError == false)
    #expect(try await client.callTool("add_session_player", ["instrument": "bass"]).isError == false)
    let melody = try await client.callTool("create_track", ["name": "Melody", "instrument": "Flute"])
    #expect(melody.isError == false)
    #expect(try await client.callTool("create_region", ["track": "Melody", "start": "5", "bars": 1, "notes": ["A4 0 1", "C5 1 1", "E5 2 2"]]).isError == false)

    let project = window.project
    #expect(project.tempoMap.tempo(at: .zero) == 96)
    #expect(project.tracks.map(\.name).suffix(3) == ["Drummer", "Bass Player", "Melody"])
    #expect(project.chords.map(\.chord.description) == ["Am", "F", "C", "G", "Am", "F", "C", "G"])
    #expect(window.undoManager == nil || window.undoManager?.undoActionName.hasPrefix("Agent: ") == true)

    // A mistake comes back as an error the agent can act on, not a failed request.
    let mistake = try await client.callTool("create_region", ["track": "Nobody", "start": 1, "bars": 1])
    #expect(mistake.isError)
    #expect(mistake.text.contains("get_song"))

    let song = try await client.callTool("get_song")
    let summary = try #require(try JSONSerialization.jsonObject(with: Data(song.text.utf8)) as? [String: Any])
    #expect(summary["tempo"] as? Int == 96)

    await server.stop()
  }

  @Test func requestsNeedTheToken() async throws {
    let server = try await startServer()
    var withoutToken = Client(server: server, port: port, token: nil)
    let refused = try await withoutToken.send("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "x", "version": "1"]])
    #expect(refused.status == 401)
    var wrongToken = Client(server: server, port: port, token: "nope")
    #expect(try await wrongToken.send("tools/list").status == 401)
    await server.stop()
  }

  @Test func withNoSongOpenToolsSaySo() async throws {
    let server = try await startServer()
    var client = Client(server: server, port: port, token: token)
    _ = try await client.send("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "x", "version": "1"]])
    _ = try await client.send("notifications/initialized", notification: true)
    // Only when no project window is open (the test host may have one).
    if AgentServer.shared.activeWindow == nil {
      let result = try await client.callTool("get_song")
      #expect(result.isError)
      #expect(result.text.contains("No song is open"))
    }
    await server.stop()
  }
  @Test func promptsAndTheManualAreOffered() async throws {
    let server = try await startServer()
    var client = Client(server: server, port: port, token: token)
    _ = try await client.send("initialize", ["protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "claude-code", "version": "1"]])
    _ = try await client.send("notifications/initialized", notification: true)

    let prompts = ((try await client.send("prompts/list").reply?["result"] as? [String: Any])?["prompts"] as? [[String: Any]]) ?? []
    #expect(prompts.compactMap { $0["name"] as? String } == AgentPrompt.all.map(\.name))
    let sketch = try await client.send("prompts/get", ["name": "sketch_song", "arguments": ["style": "synth-pop", "mood": "wistful"]])
    let messages = ((sketch.reply?["result"] as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
    let text = (messages.first?["content"] as? [String: Any])?["text"] as? String
    #expect(text?.contains("synth-pop song in Ongaku Studio, feeling wistful") == true)
    // A prompt without what it needs is refused.
    #expect(try await client.send("prompts/get", ["name": "sketch_song"]).reply?["error"] != nil)

    let resources = ((try await client.send("resources/list").reply?["result"] as? [String: Any])?["resources"] as? [[String: Any]]) ?? []
    let uris = resources.compactMap { $0["uri"] as? String }
    #expect(uris.contains("ongaku://song"))
    #expect(uris.contains("ongaku://manual/11-ai-agents"))
    #expect(uris.contains("ongaku://manual/contents"))
    let chapter = try await client.send("resources/read", ["uri": "ongaku://manual/05-session-players"])
    let contents = ((chapter.reply?["result"] as? [String: Any])?["contents"] as? [[String: Any]]) ?? []
    #expect((contents.first?["text"] as? String)?.hasPrefix("# 5. Session Players") == true)
    await server.stop()
  }

  @Test func agentNamesAreShownAsPeopleSayThem() {
    #expect(AgentServer.displayName("claude-code") == "Claude Code")
    #expect(AgentServer.displayName("Claude Desktop") == "Claude Desktop")
    #expect(AgentServer.displayName("cursor") == "cursor")
  }
}
