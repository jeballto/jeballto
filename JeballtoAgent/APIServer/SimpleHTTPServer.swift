import Foundation
import Network

/// HTTP request representation
struct HTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data?
  let queryParameters: [String: String]

  /// Parses query parameters from path
  static func parseQueryParameters(_ path: String) -> (path: String, params: [String: String]) {
    guard let urlComponents = URLComponents(string: path) else { return (path, [:]) }

    let cleanPath = urlComponents.path
    var params: [String: String] = [:]

    if let queryItems = urlComponents.queryItems { for item in queryItems {
      params[item.name] = item.value ?? ""
    } }

    return (cleanPath, params)
  }
}

/// HTTP response representation
struct HTTPResponse: Error {
  let statusCode: Int
  let headers: [String: String]
  let body: Data?

  init(statusCode: Int, headers: [String: String] = [:], body: Data? = nil) {
    self.statusCode = statusCode
    var defaultHeaders = headers
    if body != nil, defaultHeaders["Content-Type"] == nil { defaultHeaders["Content-Type"] = "application/json" }
    self.headers = defaultHeaders
    self.body = body
  }

  /// Creates JSON response
  static func json(_ object: some Encodable, statusCode: Int = 200) -> HTTPResponse {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    do {
      let data = try encoder.encode(object)
      return HTTPResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: data)
    } catch {
      let fallback = "{\"error\":{\"code\":\"INTERNAL_ERROR\",\"message\":\"Failed to encode response\"}}"
      return HTTPResponse(
        statusCode: 500,
        headers: ["Content-Type": "application/json"],
        body: fallback.data(using: .utf8)
      )
    }
  }

  /// Creates error response
  static func error(_ code: String, message: String, statusCode: Int = 400) -> HTTPResponse {
    let errorResponse = ErrorResponse(code: code, message: message)
    return json(errorResponse, statusCode: statusCode)
  }

  /// Creates success response
  static func success(message: String? = nil, statusCode: Int = 200) -> HTTPResponse {
    let successResponse = SuccessResponse(message: message)
    return json(successResponse, statusCode: statusCode)
  }

  /// Converts to raw HTTP response bytes
  func toData() -> Data {
    var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"

    // Add headers
    for (key, value) in headers {
      response += "\(key): \(value)\r\n"
    }

    // Always include Content-Length (0 for empty bodies)
    let bodyLength = body?.count ?? 0
    response += "Content-Length: \(bodyLength)\r\n"

    // Signal connection will close (no keep-alive support)
    response += "Connection: close\r\n"

    response += "\r\n"

    var data = response.data(using: .utf8) ?? Data()
    if let body { data.append(body) }

    return data
  }

  private var statusText: String {
    switch statusCode {
    case 200: "OK"
    case 201: "Created"
    case 202: "Accepted"
    case 204: "No Content"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 409: "Conflict"
    case 413: "Payload Too Large"
    case 500: "Internal Server Error"
    case 504: "Gateway Timeout"
    default: "Unknown"
    }
  }
}

/// Route handler type
typealias RouteHandler = (HTTPRequest) async throws -> HTTPResponse

enum HTTPServerError: Error, LocalizedError {
  case invalidPort(UInt16)
  case listenerCreationFailed(Error)

  var errorDescription: String? {
    switch self {
    case .invalidPort(let port): "Invalid port number: \(port)"
    case .listenerCreationFailed(let error): "Failed to create listener: \(error.localizedDescription)"
    }
  }
}

/// Simple HTTP server using Network framework
class SimpleHTTPServer {
  private let port: UInt16
  private let host: String
  private let queue: DispatchQueue
  private var listener: NWListener?
  private var isRunning = false

  /// Maximum allowed request body size (1 MB)
  private static let maxRequestBodySize = 1_048_576

  /// Maximum allowed header size (64 KB)
  private static let maxHeaderSize = 65536

  /// Connection timeout in seconds
  private static let connectionTimeoutSeconds: TimeInterval = 30

  private var routes: [String: [String: RouteHandler]] = [:]
  var authToken: String?

  init(port: UInt16, host: String = "0.0.0.0") {
    self.port = port
    self.host = host
    queue = DispatchQueue(label: "com.jeballto.httpserver")
  }

  func start() throws {
    guard !isRunning else {
      logWarning("HTTP server already running on port \(port)", category: "HTTPServer")
      return
    }

    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: .any)
    guard let serverPort = NWEndpoint.Port(rawValue: port) else { throw HTTPServerError.invalidPort(port) }

    let newListener = try NWListener(using: parameters, on: serverPort)

    newListener.newConnectionHandler = { [weak self] connection in self?.handleConnection(connection) }

    newListener.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready: logInfo("HTTP server listening on port \(self?.port ?? 0)", category: "HTTPServer")
      case .failed(let error): logError("HTTP server failed: \(error)", category: "HTTPServer")
      default: break
      }
    }

    newListener.start(queue: queue)
    listener = newListener
    isRunning = true

    logInfo("HTTP server started on port \(port)", category: "HTTPServer")
  }

  /// Stops the HTTP server
  func stop() {
    listener?.cancel()
    listener = nil
    isRunning = false
    logInfo("HTTP server stopped", category: "HTTPServer")
  }

  // MARK: - Route Registration

  func route(_ method: String, _ path: String, handler: @escaping RouteHandler) {
    routes[path, default: [:]][method] = handler
    logDebug("Registered route: \(method) \(path)", category: "HTTPServer")
  }

  /// Convenience methods for common HTTP methods
  func get(_ path: String, handler: @escaping RouteHandler) { route("GET", path, handler: handler) }

  func post(_ path: String, handler: @escaping RouteHandler) { route("POST", path, handler: handler) }

  func delete(_ path: String, handler: @escaping RouteHandler) { route("DELETE", path, handler: handler) }

  func patch(_ path: String, handler: @escaping RouteHandler) { route("PATCH", path, handler: handler) }

  // MARK: - Connection Handling

  private func handleConnection(_ connection: NWConnection) {
    connection.start(queue: queue)

    // Schedule a timeout to cancel idle connections
    let timeoutItem = DispatchWorkItem { [weak connection] in
      logDebug("Connection timed out, cancelling", category: "HTTPServer")
      connection?.cancel()
    }
    queue.asyncAfter(deadline: .now() + Self.connectionTimeoutSeconds, execute: timeoutItem)

    // Read complete HTTP request (headers + body)
    readFullRequest(connection: connection, accumulatedData: Data()) { [weak self] fullData in
      timeoutItem.cancel()
      guard let self, let fullData else {
        connection.cancel()
        return
      }

      switch parseHTTPRequest(fullData) {
      case .success(let request):
        let task = Task<Void, Never> {
          let response = await self.handleRequest(request)
          guard !Task.isCancelled else {
            connection.cancel()
            return
          }
          let responseData = response.toData()
          connection.send(content: responseData, completion: .contentProcessed { _ in connection.cancel() })
        }
        // Detect client disconnect: a receive on an idle connection will complete
        // with an error or isComplete=true when the remote end closes.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
          if isComplete || error != nil {
            task.cancel()
          }
        }
      case .failure(let errorResponse):
        let responseData = errorResponse.toData()
        connection.send(content: responseData, completion: .contentProcessed { _ in connection.cancel() })
      }
    }
  }

  /// Reads the full HTTP request by accumulating data until headers + full body are received.
  private func readFullRequest(
    connection: NWConnection,
    accumulatedData: Data,
    completion: @escaping (Data?) -> Void
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
      guard let data else {
        completion(accumulatedData.isEmpty ? nil : accumulatedData)
        return
      }

      var accumulated = accumulatedData
      accumulated.append(data)

      let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
      var headerEndIndex: Data.Index?
      if accumulated.count >= 4 {
        for i in accumulated.startIndex ... (accumulated.endIndex - 4) {
          if accumulated[i] == separator[0], accumulated[i + 1] == separator[1],
             accumulated[i + 2] == separator[2], accumulated[i + 3] == separator[3]
          {
            headerEndIndex = i
            break
          }
        }
      }

      guard let headerEnd = headerEndIndex else {
        if accumulated.count > Self.maxHeaderSize {
          logWarning("Headers exceed \(Self.maxHeaderSize) bytes, closing connection", category: "HTTPServer")
          completion(nil)
          return
        }
        if isComplete || error != nil {
          completion(accumulated)
        } else {
          self.readFullRequest(connection: connection, accumulatedData: accumulated, completion: completion)
        }
        return
      }

      // Parse Content-Length from headers
      let headerData = accumulated[accumulated.startIndex ..< headerEnd]
      let headerString = String(data: headerData, encoding: .utf8) ?? ""
      var contentLength = 0
      for line in headerString.components(separatedBy: "\r\n") {
        if line.lowercased().hasPrefix("content-length:") {
          let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
          contentLength = Int(value) ?? 0
          break
        }
      }

      // Check if we have the full body
      let bodyStart = headerEnd + 4 // skip \r\n\r\n
      let receivedBodyLength = accumulated.endIndex - bodyStart
      if receivedBodyLength >= contentLength || isComplete || error != nil {
        completion(accumulated)
      } else {
        self.readFullRequest(connection: connection, accumulatedData: accumulated, completion: completion)
      }
    }
  }

  private static let malformedRequestError = HTTPResponse.error(
    "INVALID_REQUEST", message: "Malformed HTTP request", statusCode: 400
  )

  private func parseHTTPRequest(_ data: Data) -> Result<HTTPRequest, HTTPResponse> {
    // Find the header/body separator (\r\n\r\n) in raw bytes
    let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
    var separatorIndex: Data.Index?
    if data.count >= 4 {
      for i in data.startIndex ... (data.endIndex - 4) {
        if data[i] == separator[0], data[i + 1] == separator[1],
           data[i + 2] == separator[2], data[i + 3] == separator[3]
        {
          separatorIndex = i
          break
        }
      }
    }

    guard let headerEndIndex = separatorIndex else { return .failure(Self.malformedRequestError) }

    // Parse headers portion as UTF-8
    let headerData = data[data.startIndex ..< headerEndIndex]
    guard let headerString = String(data: headerData, encoding: .utf8) else {
      return .failure(Self.malformedRequestError)
    }

    let lines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return .failure(Self.malformedRequestError) }

    let parts = requestLine.components(separatedBy: " ")
    guard parts.count >= 2 else { return .failure(Self.malformedRequestError) }

    let method = parts[0]
    let fullPath = parts[1]

    // Parse query parameters
    let (path, queryParams) = HTTPRequest.parseQueryParameters(fullPath)

    // Parse headers (case-insensitive: store keys lowercased)
    var headers: [String: String] = [:]
    for index in 1 ..< lines.count {
      let line = lines[index]
      if let colonIndex = line.firstIndex(of: ":") {
        let key = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        headers[key] = value
      }
    }

    // Extract body using byte offset (preserves binary data correctly)
    let bodyStartIndex = headerEndIndex + 4 // skip \r\n\r\n
    var body: Data?
    if bodyStartIndex < data.endIndex {
      let bodyData = data[bodyStartIndex ..< data.endIndex]
      if bodyData.count > Self.maxRequestBodySize {
        logWarning("Request body too large (\(bodyData.count) bytes), rejecting", category: "HTTPServer")
        return .failure(HTTPResponse.error(
          "PAYLOAD_TOO_LARGE",
          message: "Request body exceeds maximum size of \(Self.maxRequestBodySize) bytes",
          statusCode: 413
        ))
      }
      if !bodyData.isEmpty { body = Data(bodyData) }
    }

    return .success(HTTPRequest(
      method: method, path: path, headers: headers, body: body, queryParameters: queryParams
    ))
  }

  private func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
    logDebug("HTTP Request: \(request.method) \(request.path)", category: "HTTPServer")

    // Skip authentication for health check endpoint
    let isHealthCheck = request.path == "/v1/health"

    // Check authentication if token is set (except for health check)
    // Headers are stored lowercased for case-insensitive lookup
    if !isHealthCheck, let authToken {
      guard let authHeader = request.headers["authorization"],
            authHeader.hasPrefix("Bearer "),
            constantTimeEqual(String(authHeader.dropFirst("Bearer ".count)), authToken) else
      {
        logWarning("Unauthorized request: \(request.method) \(request.path)", category: "HTTPServer")
        return HTTPResponse.error("UNAUTHORIZED", message: "Invalid or missing authentication token", statusCode: 401)
      }
    }

    // Find matching route (exact match or wildcard)
    if let methodHandlers = routes[request.path], let handler = methodHandlers[request.method] {
      do { return try await handler(request) } catch {
        logError("Handler error for \(request.path): \(error)", category: "HTTPServer")
        return HTTPResponse.error("INTERNAL_ERROR", message: error.localizedDescription, statusCode: 500)
      }
    }

    // Check for parameterized routes (e.g., /v1/vms/{id})
    for (routePath, methodHandlers) in routes {
      if let handler = methodHandlers[request.method], routePath.contains("{") {
        if matchesRoute(request.path, pattern: routePath) {
          do { return try await handler(request) } catch {
            return HTTPResponse.error("INTERNAL_ERROR", message: error.localizedDescription, statusCode: 500)
          }
        }
      }
    }

    // Do not echo the request path back to avoid information disclosure
    logDebug("Route not found: \(request.method) \(request.path)", category: "HTTPServer")
    return HTTPResponse.error(
      "NOT_FOUND",
      message: "The requested resource was not found",
      statusCode: 404
    )
  }

  /// Constant-time string comparison to prevent timing side-channel attacks.
  /// Compares full length of both strings to avoid leaking length information.
  private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8)
    let bBytes = Array(b.utf8)

    // XOR lengths into result to avoid early return that leaks length via timing
    var result: UInt8 = 0
    let maxLen = max(aBytes.count, bBytes.count)

    for i in 0 ..< maxLen {
      let aByte: UInt8 = i < aBytes.count ? aBytes[i] : 0
      let bByte: UInt8 = i < bBytes.count ? bBytes[i] : 0
      result |= aByte ^ bByte
    }

    // Also check that lengths match (constant-time via XOR)
    result |= UInt8(truncatingIfNeeded: aBytes.count ^ bBytes.count)
    return result == 0
  }

  /// Simple route matching with {param} support
  private func matchesRoute(_ path: String, pattern: String) -> Bool {
    let pathComponents = path.split(separator: "/")
    let patternComponents = pattern.split(separator: "/")

    guard pathComponents.count == patternComponents.count else { return false }

    for (pathComp, patternComp) in zip(pathComponents, patternComponents) {
      if patternComp.hasPrefix("{"), patternComp.hasSuffix("}") {
        // This is a parameter, match anything
        continue
      }
      if pathComp != patternComp { return false }
    }

    return true
  }
}
