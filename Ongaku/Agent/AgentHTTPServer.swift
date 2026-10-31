//
//  AgentHTTPServer.swift
//  Ongaku
//

import Foundation
import MCP
import Network

/// The MCP server's HTTP side: a small HTTP/1.1 server on this Mac's loopback address only,
/// which hands each request to the MCP SDK's Streamable HTTP transport for its session.
///
/// The SDK has the transport but no listener, so this is the listener. Each connection
/// carries one request and is closed after its response (or, for a stream, when the
/// stream ends), which every HTTP client handles and keeps this simple.
actor AgentHTTPServer {
  typealias ServerFactory = @Sendable () async -> Server
  typealias ClientsChanged = @Sendable ([String]) async -> Void

  static let endpoint = "/mcp"
  /// Sessions an agent hasn't used for this long are closed.
  static let sessionTimeout: TimeInterval = 4 * 60 * 60

  private struct Session {
    let server: Server
    let transport: StatefulHTTPServerTransport
    var clientName: String
    var lastUsed: Date
  }

  private let port: UInt16
  private let token: String
  private let makeServer: ServerFactory
  private let clientsChanged: ClientsChanged
  private var listener: NWListener?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var sessions: [String: Session] = [:]
  private var cleanup: Task<Void, Never>?

  init(port: UInt16, token: String, makeServer: @escaping ServerFactory, clientsChanged: @escaping ClientsChanged) {
    self.port = port
    self.token = token
    self.makeServer = makeServer
    self.clientsChanged = clientsChanged
  }

  /// Starts listening, returning once the port is open (or throwing why it couldn't be).
  func start() async throws {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    // Only programs on this Mac can connect.
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in
      Task { await self?.accept(connection) }
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      let resumed = ResumeOnce(continuation)
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready: resumed.resume()
        case .failed(let error): resumed.resume(throwing: error)
        case .waiting(let error): resumed.resume(throwing: error)
        case .cancelled: resumed.resume(throwing: CancellationError())
        default: break
        }
      }
      listener.start(queue: .global(qos: .userInitiated))
    }
    cleanup = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        await self?.closeIdleSessions()
      }
    }
  }

  func stop() async {
    cleanup?.cancel()
    listener?.cancel()
    listener = nil
    for connection in connections.values { connection.cancel() }
    connections = [:]
    for session in sessions.values { await session.transport.disconnect() }
    sessions = [:]
    await clientsChanged([])
  }

  // MARK: - Connections

  private func accept(_ connection: NWConnection) {
    let id = ObjectIdentifier(connection)
    connections[id] = connection
    connection.start(queue: .global(qos: .userInitiated))
    Task {
      await serve(connection)
      connection.cancel()
      forget(id)
    }
  }

  private func forget(_ id: ObjectIdentifier) {
    connections[id] = nil
  }

  private func serve(_ connection: NWConnection) async {
    let channel = HTTPChannel(connection)
    let request: ParsedRequest
    do {
      request = try await channel.readRequest()
    } catch let error as HTTPChannel.RequestError {
      await channel.write(status: error.status, headers: [:], body: Data(error.message.utf8))
      return
    } catch {
      return
    }
    await channel.write(await respond(to: request))
  }

  /// The response to a request: it must be for the endpoint, with the token.
  func respond(to request: ParsedRequest) async -> HTTPResponse {
    guard request.path == Self.endpoint else {
      return .error(statusCode: 404, .invalidRequest("Not Found: Ongaku's MCP server is at \(Self.endpoint)"))
    }
    guard isAuthorized(request.http) else {
      return .error(
        statusCode: 401, .invalidRequest("Unauthorized: send the token from Ongaku's Settings › Agents as “Authorization: Bearer <token>”."),
        extraHeaders: ["WWW-Authenticate": "Bearer"])
    }
    return await handle(request.http)
  }

  /// The token, compared without stopping at the first difference.
  private func isAuthorized(_ request: HTTPRequest) -> Bool {
    guard let header = request.header(HTTPHeaderName.authorization), header.hasPrefix("Bearer ") else { return false }
    let given = Array(header.dropFirst("Bearer ".count).utf8)
    let expected = Array(token.utf8)
    guard given.count == expected.count else { return false }
    return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
  }

  // MARK: - Sessions

  /// Requests with a session go to its transport; an `initialize` starts a new session.
  private func handle(_ request: HTTPRequest) async -> HTTPResponse {
    let sessionID = request.header(HTTPHeaderName.sessionID)
    if let sessionID, var session = sessions[sessionID] {
      session.lastUsed = Date()
      sessions[sessionID] = session
      let response = await session.transport.handleRequest(request)
      if request.method.uppercased() == "DELETE", response.statusCode == 200 {
        sessions[sessionID] = nil
        await reportClients()
      }
      return response
    }
    if request.method.uppercased() == "POST", let body = request.body, isInitialize(body) {
      return await startSession(with: request)
    }
    if sessionID != nil {
      return .error(statusCode: 404, .invalidRequest("Not Found: the session has ended; connect again."))
    }
    return .error(statusCode: 400, .invalidRequest("Bad Request: missing \(HTTPHeaderName.sessionID) header"))
  }

  private func isInitialize(_ body: Data) -> Bool {
    (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["method"] as? String == "initialize"
  }

  private func startSession(with request: HTTPRequest) async -> HTTPResponse {
    let sessionID = UUID().uuidString
    let transport = StatefulHTTPServerTransport(
      sessionIDGenerator: FixedSessionID(id: sessionID),
      validationPipeline: StandardValidationPipeline(validators: [
        OriginValidator.localhost(port: Int(port)),
        AcceptHeaderValidator(mode: .sseRequired),
        ContentTypeValidator(),
        ProtocolVersionValidator(),
        SessionValidator(),
      ]))
    let server = await makeServer()
    do {
      try await server.start(transport: transport) { [weak self] client, _ in
        await self?.name(sessionID, client.name)
      }
    } catch {
      await transport.disconnect()
      return .error(statusCode: 500, .internalError("Couldn't start a session: \(error.localizedDescription)"))
    }
    sessions[sessionID] = Session(server: server, transport: transport, clientName: "Agent", lastUsed: Date())
    let response = await transport.handleRequest(request)
    if case .error = response {
      sessions[sessionID] = nil
      await transport.disconnect()
    }
    await reportClients()
    return response
  }

  private func name(_ sessionID: String, _ clientName: String) async {
    sessions[sessionID]?.clientName = clientName
    await reportClients()
  }

  private func closeIdleSessions() async {
    let now = Date()
    let idle = sessions.filter { now.timeIntervalSince($0.value.lastUsed) > Self.sessionTimeout }
    guard !idle.isEmpty else { return }
    for (id, session) in idle {
      sessions[id] = nil
      await session.transport.disconnect()
    }
    await reportClients()
  }

  private func reportClients() async {
    await clientsChanged(sessions.values.map(\.clientName).sorted())
  }

  private struct FixedSessionID: SessionIDGenerator {
    let id: String
    func generateSessionID() -> String { id }
  }
}

/// A request as read off a connection.
nonisolated struct ParsedRequest: Sendable {
  var path: String
  var http: HTTPRequest
}

/// Reads one HTTP/1.1 request from a connection and writes its response.
nonisolated struct HTTPChannel: Sendable {
  struct RequestError: Error {
    var status: Int
    var message: String
  }

  static let maximumHeaderBytes = 64 * 1024
  static let maximumBodyBytes = 16 * 1024 * 1024

  let connection: NWConnection

  init(_ connection: NWConnection) {
    self.connection = connection
  }

  func readRequest() async throws -> ParsedRequest {
    var buffer = Data()
    let separator = Data("\r\n\r\n".utf8)
    var headerEnd: Range<Data.Index>?
    while headerEnd == nil {
      guard let chunk = try await receive() else { throw RequestError(status: 400, message: "Incomplete request") }
      buffer.append(chunk)
      headerEnd = buffer.range(of: separator)
      if headerEnd == nil, buffer.count > Self.maximumHeaderBytes { throw RequestError(status: 431, message: "Headers too large") }
    }
    guard let headerEnd else { throw RequestError(status: 400, message: "Bad request") }
    let lines = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
    let requestLine = lines[0].split(separator: " ")
    guard requestLine.count == 3 else { throw RequestError(status: 400, message: "Bad request line") }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }
    let request = HTTPRequest(method: String(requestLine[0]), headers: headers, path: nil)
    if request.header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
      throw RequestError(status: 411, message: "Send a Content-Length")
    }
    let length = Int(request.header("Content-Length") ?? "0") ?? 0
    guard (0...Self.maximumBodyBytes).contains(length) else { throw RequestError(status: 413, message: "Request too large") }
    var body = Data(buffer[headerEnd.upperBound...])
    while body.count < length {
      guard let chunk = try await receive() else { throw RequestError(status: 400, message: "Incomplete body") }
      body.append(chunk)
    }
    let target = String(requestLine[1])
    let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
    return ParsedRequest(
      path: path,
      http: HTTPRequest(method: request.method, headers: headers, body: length > 0 ? body.prefix(length) : nil, path: path))
  }

  /// The next bytes from the client; `nil` once it has closed the connection.
  private func receive() async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let data, !data.isEmpty {
          continuation.resume(returning: data)
        } else {
          continuation.resume(returning: isComplete ? nil : Data())
        }
      }
    }
  }

  func write(_ response: HTTPResponse) async {
    if case .stream(let stream, let headers) = response {
      var streamHeaders = headers
      streamHeaders["Transfer-Encoding"] = "chunked"
      guard await send(head(status: 200, headers: streamHeaders)) else { return }
      do {
        for try await chunk in stream {
          var framed = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
          framed.append(chunk)
          framed.append(Data("\r\n".utf8))
          guard await send(framed) else { return }
        }
      } catch {}
      _ = await send(Data("0\r\n\r\n".utf8))
      return
    }
    await write(status: response.statusCode, headers: response.headers, body: response.bodyData ?? Data())
  }

  func write(status: Int, headers: [String: String], body: Data) async {
    var headers = headers
    headers["Content-Length"] = String(body.count)
    var data = head(status: status, headers: headers)
    data.append(body)
    _ = await send(data)
  }

  private func head(status: Int, headers: [String: String]) -> Data {
    var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\nConnection: close\r\n"
    for (name, value) in headers where name.lowercased() != "connection" {
      text += "\(name): \(value)\r\n"
    }
    return Data((text + "\r\n").utf8)
  }

  /// Sends bytes, returning whether they went (false once the client has gone).
  private func send(_ data: Data) async -> Bool {
    await withCheckedContinuation { continuation in
      connection.send(content: data, completion: .contentProcessed { error in
        continuation.resume(returning: error == nil)
      })
    }
  }

  private static func reason(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 202: "Accepted"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 406: "Not Acceptable"
    case 411: "Length Required"
    case 413: "Content Too Large"
    case 415: "Unsupported Media Type"
    case 431: "Request Header Fields Too Large"
    default: status >= 500 ? "Internal Server Error" : "Error"
    }
  }
}

/// Resumes a continuation the first time only: a listener reports several states.
nonisolated final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?

  init(_ continuation: CheckedContinuation<Void, any Error>) {
    self.continuation = continuation
  }

  func resume(throwing error: (any Error)? = nil) {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
  }
}
