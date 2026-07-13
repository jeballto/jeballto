import Foundation
import Network

/// Simple HTTP server using Network framework
final class SimpleHTTPServer: @unchecked Sendable {
  typealias ListenerFactory = @Sendable (NWParameters, NWEndpoint.Port) throws -> NWListener

  private enum ListenerLifecycleState {
    case stopped
    case starting(UUID, NetworkListenerReadiness)
    case running(UUID)
  }

  private struct ListenerStopSnapshot {
    let readiness: NetworkListenerReadiness?
    let contexts: [HTTPConnectionContext]
  }

  private let port: UInt16
  private let host: String
  private let maxConcurrentRequests: Int
  private let queue: DispatchQueue
  private let listenerFactory: ListenerFactory
  private var listener: NWListener?
  private var listenerLifecycleState: ListenerLifecycleState = .stopped
  private let lifecycleLock = NSLock()
  private var activeConnections: [ObjectIdentifier: HTTPConnectionContext] = [:]
  private let requestLimitLock = NSLock()
  private var activeRequestCount = 0
  private let configurationLock = NSLock()

  /// Maximum allowed request body size (1 MB)
  private static let maxRequestBodySize = 1_048_576

  /// Maximum allowed header size (64 KB)
  private static let maxHeaderSize = 65536

  /// Connection timeout in seconds
  private static let connectionTimeoutSeconds: TimeInterval = 30

  private var routes: [String: [String: RouteHandler]] = [:]
  private var _authToken: String?
  private var _requestAdmissionHandler: HTTPRequestAdmissionHandler?

  var authToken: String? {
    get { configurationLock.withLock { _authToken } }
    set { configurationLock.withLock { _authToken = newValue } }
  }

  var requestAdmissionHandler: HTTPRequestAdmissionHandler? {
    get { configurationLock.withLock { _requestAdmissionHandler } }
    set { configurationLock.withLock { _requestAdmissionHandler = newValue } }
  }

  init(
    port: UInt16,
    host: String = "0.0.0.0",
    maxConcurrentRequests: Int = 100,
    listenerFactory: @escaping ListenerFactory = { parameters, port in
      try NWListener(using: parameters, on: port)
    }
  ) {
    self.port = port
    self.host = host
    self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    self.listenerFactory = listenerFactory
    queue = DispatchQueue(label: "com.jeballto.httpserver")
  }
}

extension SimpleHTTPServer {
  func start() throws {
    guard let serverPort = NWEndpoint.Port(rawValue: port) else { throw HTTPServerError.invalidPort(port) }
    guard let (generation, readiness) = try beginStartup() else {
      logWarning("HTTP server already running on port \(port)", category: "HTTPServer")
      return
    }

    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: .any)
    let newListener = try makeListener(
      parameters: parameters,
      port: serverPort,
      generation: generation,
      readiness: readiness
    )
    configureListener(newListener, generation: generation, readiness: readiness)
    try startListener(newListener, generation: generation, readiness: readiness)
    try waitForListenerStartup(generation: generation, readiness: readiness)

    logInfo("HTTP server started on port \(port)", category: "HTTPServer")
  }

  /// Stops the HTTP server
  func stop() {
    let contexts = stopAcceptingAndTakeActiveConnections()
    for context in contexts {
      _ = context.requestCancellation()
    }
    logInfo("HTTP server stopped", category: "HTTPServer")
  }

  /// Stops accepting new connections while allowing current handlers to be drained separately.
  func stopAccepting() {
    let snapshot = takeListenerAndConnections(takeConnections: false)
    snapshot.readiness?.cancel()
  }

  /// Stops accepting requests, cancels in-flight handlers, and waits for them to leave route code.
  func stopAndWait() async {
    let contexts = stopAcceptingAndTakeActiveConnections()
    let tasks = contexts.compactMap { $0.requestCancellation() }
    for task in tasks {
      await task.value
    }
    for context in contexts {
      context.finish()
    }
    logInfo("HTTP server stopped and active requests drained", category: "HTTPServer")
  }

  private func stopAcceptingAndTakeActiveConnections() -> [HTTPConnectionContext] {
    let snapshot = takeListenerAndConnections(takeConnections: true)
    snapshot.readiness?.cancel()
    return snapshot.contexts
  }

  private func beginStartup() throws -> (UUID, NetworkListenerReadiness)? {
    try lifecycleLock.withLock {
      switch listenerLifecycleState {
      case .stopped:
        let generation = UUID()
        let readiness = NetworkListenerReadiness()
        listenerLifecycleState = .starting(generation, readiness)
        return (generation, readiness)
      case .starting:
        throw HTTPServerError.listenerStartupInProgress
      case .running:
        return nil
      }
    }
  }

  private func makeListener(
    parameters: NWParameters,
    port: NWEndpoint.Port,
    generation: UUID,
    readiness: NetworkListenerReadiness
  ) throws -> NWListener {
    do {
      return try listenerFactory(parameters, port)
    } catch {
      guard abandonStartupIfCurrent(generation) else {
        throw HTTPServerError.listenerStartupFailed(NetworkListenerReadiness.ReadinessError.cancelled)
      }
      readiness.cancel()
      throw HTTPServerError.listenerCreationFailed(error)
    }
  }

  private func configureListener(
    _ newListener: NWListener,
    generation: UUID,
    readiness: NetworkListenerReadiness
  ) {
    newListener.newConnectionHandler = { [weak self] connection in self?.handleConnection(connection) }
    newListener.stateUpdateHandler = { [weak self] state in
      self?.handleListenerStateUpdate(state, generation: generation)
      readiness.observe(state)
    }
  }

  private func handleListenerStateUpdate(_ state: NWListener.State, generation: UUID) {
    switch state {
    case .ready:
      if markListenerReady(generation) {
        logInfo("HTTP server listening on port \(port)", category: "HTTPServer")
      }
    case .failed(let error):
      if let snapshot = takeListenerIfCurrent(generation) {
        logError("HTTP server failed: \(error)", category: "HTTPServer")
        Self.cancelRequests(snapshot.contexts)
      }
    case .cancelled:
      if let snapshot = takeListenerIfCurrent(generation) {
        Self.cancelRequests(snapshot.contexts)
      }
    default:
      break
    }
  }

  private func startListener(
    _ newListener: NWListener,
    generation: UUID,
    readiness: NetworkListenerReadiness
  ) throws {
    let didStart = lifecycleLock.withLock { () -> Bool in
      guard case .starting(let currentGeneration, _) = listenerLifecycleState,
            currentGeneration == generation,
            listener == nil else
      {
        return false
      }
      listener = newListener
      newListener.start(queue: queue)
      return true
    }
    guard didStart else {
      Self.cancelListener(newListener)
      readiness.cancel()
      throw HTTPServerError.listenerStartupFailed(NetworkListenerReadiness.ReadinessError.cancelled)
    }
  }

  private func waitForListenerStartup(generation: UUID, readiness: NetworkListenerReadiness) throws {
    do {
      try readiness.wait(timeout: 5)
    } catch {
      cancelListenerStartup(generation)
      throw HTTPServerError.listenerStartupFailed(error)
    }
    guard isListenerRunning(generation) else {
      cancelListenerStartup(generation)
      throw HTTPServerError.listenerStartupFailed(NetworkListenerReadiness.ReadinessError.cancelled)
    }
  }

  private func isListenerRunning(_ generation: UUID) -> Bool {
    lifecycleLock.withLock {
      guard case .running(let currentGeneration) = listenerLifecycleState else { return false }
      return currentGeneration == generation && listener != nil
    }
  }

  private func cancelListenerStartup(_ generation: UUID) {
    guard let snapshot = takeListenerIfCurrent(generation) else { return }
    snapshot.readiness?.cancel()
    Self.cancelRequests(snapshot.contexts)
  }

  private static func cancelRequests(_ contexts: [HTTPConnectionContext]) {
    for context in contexts {
      _ = context.requestCancellation()
    }
  }
}

extension SimpleHTTPServer {
  // MARK: - Route Registration

  func route(_ method: String, _ path: String, handler: @escaping RouteHandler) {
    configurationLock.withLock {
      routes[path, default: [:]][method] = handler
    }
    logDebug("Registered route: \(method) \(path)", category: "HTTPServer")
  }

  /// Convenience methods for common HTTP methods
  func get(_ path: String, handler: @escaping RouteHandler) { route("GET", path, handler: handler) }

  func post(_ path: String, handler: @escaping RouteHandler) { route("POST", path, handler: handler) }

  func delete(_ path: String, handler: @escaping RouteHandler) { route("DELETE", path, handler: handler) }

  func patch(_ path: String, handler: @escaping RouteHandler) { route("PATCH", path, handler: handler) }

  var registeredRouteSignatures: Set<HTTPRouteSignature> {
    configurationLock.withLock {
      Set(routes.flatMap { path, handlers in
        handlers.keys.map { HTTPRouteSignature(method: $0, path: path) }
      })
    }
  }
}

private extension SimpleHTTPServer {
  // MARK: - Connection Handling

  private func handleConnection(_ connection: NWConnection) {
    connection.start(queue: queue)

    guard claimRequestSlot() else {
      let response = HTTPResponse.error(
        "TOO_MANY_REQUESTS",
        message: "Maximum concurrent connections exceeded",
        statusCode: 429
      )
      connection.send(content: response.toData(), completion: .contentProcessed { _ in connection.cancel() })
      return
    }
    let slot = HTTPConnectionSlot { [weak self] in self?.releaseRequestSlot() }
    let identifier = ObjectIdentifier(connection)
    let context = HTTPConnectionContext(connection: connection, slot: slot) { [weak self] in
      self?.removeActiveConnection(identifier)
    }
    guard registerActiveConnection(context, identifier: identifier) else {
      _ = context.requestCancellation()
      return
    }

    // Schedule a timeout to cancel idle connections
    let timeout = HTTPConnectionTimeout { [weak context] in
      logDebug("Connection timed out, cancelling", category: "HTTPServer")
      _ = context?.requestCancellation()
    }
    timeout.schedule(on: queue, after: Self.connectionTimeoutSeconds)

    // Read complete HTTP request (headers + body)
    readFullRequest(connection: connection, accumulatedData: Data()) { [weak self] readResult in
      timeout.cancel()
      guard let self, let readResult, context.isCancellationRequested == false else {
        context.finish()
        return
      }

      let fullData: Data
      switch readResult {
      case .success(let data):
        fullData = data
      case .failure(let errorResponse):
        let responseData = errorResponse.toData()
        connection.send(content: responseData, completion: .contentProcessed { _ in
          context.finish()
        })
        return
      }

      switch Self.parseHTTPRequest(fullData) {
      case .success(let request):
        guard context.installHandlerTask({
          Task<Void, Never> {
            guard context.isCancellationRequested == false, Task.isCancelled == false else {
              context.finish()
              return
            }
            let response = await self.handleRequest(request)
            guard context.isCancellationRequested == false, Task.isCancelled == false else {
              context.finish()
              // Finalization actions such as a completed hard reset must not be lost merely
              // because the requesting client disconnected before the response could be sent.
              response.runAfterSendAction()
              return
            }
            let responseData = response.toData()
            connection.send(content: responseData, completion: .contentProcessed { _ in
              context.finish()
              response.runAfterSendAction()
            })
          }
        }) != nil else {
          context.finish()
          return
        }
        // A graceful receive-side EOF may be a valid TCP half-close from a client
        // that is still waiting for the response. Only transport errors cancel work.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, error in
          if error != nil {
            _ = context.requestCancellation()
          }
        }
      case .failure(let errorResponse):
        let responseData = errorResponse.toData()
        connection.send(content: responseData, completion: .contentProcessed { _ in
          context.finish()
        })
      }
    }
  }

  /// Reads the full HTTP request by accumulating data until headers + full body are received.
  private func readFullRequest(
    connection: NWConnection,
    accumulatedData: Data,
    completion: @escaping @Sendable (Result<Data, HTTPResponse>?) -> Void
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
      guard let data else {
        completion(accumulatedData.isEmpty ? nil : .failure(Self.malformedRequestError))
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

      if let response = Self.headerLimitResponse(
        accumulatedCount: accumulated.count,
        headerEnd: headerEndIndex
      ) {
        logWarning("Headers exceed \(Self.maxHeaderSize) bytes, closing connection", category: "HTTPServer")
        completion(.failure(response))
        return
      }

      guard let headerEnd = headerEndIndex else {
        if isComplete || error != nil {
          completion(.success(accumulated))
        } else {
          self.readFullRequest(connection: connection, accumulatedData: accumulated, completion: completion)
        }
        return
      }

      // Parse Content-Length from headers
      let headerData = accumulated[accumulated.startIndex ..< headerEnd]
      let headerString = String(data: headerData, encoding: .utf8) ?? ""
      let contentLength: Int
      switch Self.contentLength(fromHeaderString: headerString) {
      case .success(let value):
        contentLength = value
      case .failure(let response):
        completion(.failure(response))
        return
      }

      if contentLength > Self.maxRequestBodySize {
        logWarning(
          "Content-Length \(contentLength) exceeds \(Self.maxRequestBodySize), rejecting",
          category: "HTTPServer"
        )
        completion(.failure(Self.payloadTooLargeResponse()))
        return
      }

      // Check if we have the full body
      let bodyStart = headerEnd + 4 // skip \r\n\r\n
      let receivedBodyLength = accumulated.endIndex - bodyStart
      if receivedBodyLength > Self.maxRequestBodySize {
        logWarning(
          "Request body exceeds \(Self.maxRequestBodySize) bytes while reading, rejecting",
          category: "HTTPServer"
        )
        completion(.failure(Self.payloadTooLargeResponse()))
        return
      }
      if receivedBodyLength > contentLength {
        completion(.failure(Self.malformedRequestError))
        return
      }
      if receivedBodyLength >= contentLength {
        completion(.success(accumulated))
      } else if isComplete || error != nil {
        completion(.failure(Self.malformedRequestError))
      } else {
        self.readFullRequest(connection: connection, accumulatedData: accumulated, completion: completion)
      }
    }
  }

  private static let malformedRequestError = HTTPResponse.error(
    "INVALID_REQUEST", message: "Malformed HTTP request", statusCode: 400
  )
}

extension SimpleHTTPServer {
  static func contentLength(fromHeaderString headerString: String) -> Result<Int, HTTPResponse> {
    var values: [Int] = []
    for line in headerString.components(separatedBy: "\r\n") {
      if line.lowercased().hasPrefix("transfer-encoding:") {
        return .failure(malformedRequestError)
      }
      guard line.lowercased().hasPrefix("content-length:") else { continue }
      let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
      guard value.isEmpty == false,
            value.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
            let contentLength = Int(value) else
      {
        return .failure(malformedRequestError)
      }
      values.append(contentLength)
    }
    guard values.count <= 1 else { return .failure(malformedRequestError) }
    return .success(values.first ?? 0)
  }

  private static func payloadTooLargeResponse() -> HTTPResponse {
    HTTPResponse.error(
      "PAYLOAD_TOO_LARGE",
      message: "Request body exceeds maximum size of \(maxRequestBodySize) bytes",
      statusCode: 413
    )
  }

  private static func headersTooLargeResponse() -> HTTPResponse {
    HTTPResponse.error(
      "HEADERS_TOO_LARGE",
      message: "Request headers exceed maximum size of \(maxHeaderSize) bytes",
      statusCode: 431
    )
  }

  static func headerLimitResponse(accumulatedCount: Int, headerEnd: Int?) -> HTTPResponse? {
    if let headerEnd {
      guard headerEnd > maxHeaderSize else { return nil }
    } else {
      // Up to three bytes beyond the header allowance may be a partial CRLFCRLF
      // terminator split across receives. A larger unterminated buffer is
      // unambiguously oversized and can be rejected without waiting for more data.
      guard accumulatedCount > maxHeaderSize + 3 else { return nil }
    }
    return headersTooLargeResponse()
  }
}

private extension SimpleHTTPServer {
  private func abandonStartupIfCurrent(_ generation: UUID) -> Bool {
    lifecycleLock.withLock {
      guard case .starting(let currentGeneration, _) = listenerLifecycleState,
            currentGeneration == generation else
      {
        return false
      }
      listenerLifecycleState = .stopped
      return true
    }
  }

  private func markListenerReady(_ generation: UUID) -> Bool {
    lifecycleLock.withLock {
      guard case .starting(let currentGeneration, _) = listenerLifecycleState,
            currentGeneration == generation,
            listener != nil else
      {
        return false
      }
      listenerLifecycleState = .running(generation)
      return true
    }
  }

  private func takeListenerIfCurrent(_ generation: UUID) -> ListenerStopSnapshot? {
    lifecycleLock.withLock {
      let readiness: NetworkListenerReadiness?
      switch listenerLifecycleState {
      case .starting(let currentGeneration, let currentReadiness) where currentGeneration == generation:
        readiness = currentReadiness
      case .running(let currentGeneration) where currentGeneration == generation:
        readiness = nil
      default:
        return nil
      }

      listenerLifecycleState = .stopped
      let currentListener = listener
      listener = nil
      Self.cancelListener(currentListener)
      let contexts = Array(activeConnections.values)
      activeConnections.removeAll()
      return ListenerStopSnapshot(readiness: readiness, contexts: contexts)
    }
  }

  private func takeListenerAndConnections(takeConnections: Bool) -> ListenerStopSnapshot {
    lifecycleLock.withLock {
      let readiness: NetworkListenerReadiness? = if case .starting(_, let currentReadiness) = listenerLifecycleState {
        currentReadiness
      } else {
        nil
      }

      listenerLifecycleState = .stopped
      let currentListener = listener
      listener = nil
      Self.cancelListener(currentListener)
      let contexts = takeConnections ? Array(activeConnections.values) : []
      if takeConnections { activeConnections.removeAll() }
      return ListenerStopSnapshot(readiness: readiness, contexts: contexts)
    }
  }

  private static func cancelListener(_ listener: NWListener?) {
    guard let listener else { return }
    listener.newConnectionHandler = nil
    listener.stateUpdateHandler = nil
    listener.cancel()
  }

  private func registerActiveConnection(_ context: HTTPConnectionContext, identifier: ObjectIdentifier) -> Bool {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    guard case .running = listenerLifecycleState else { return false }
    activeConnections[identifier] = context
    return true
  }

  private func removeActiveConnection(_ identifier: ObjectIdentifier) {
    lifecycleLock.lock()
    activeConnections.removeValue(forKey: identifier)
    lifecycleLock.unlock()
  }
}

extension SimpleHTTPServer {
  static func parseHTTPRequest(_ data: Data) -> Result<HTTPRequest, HTTPResponse> {
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

    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3,
          parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else
    {
      return .failure(Self.malformedRequestError)
    }

    let method = String(parts[0])
    let fullPath = String(parts[1])
    guard method.isEmpty == false,
          method.unicodeScalars.allSatisfy(Self.isHTTPHeaderNameScalar) else
    {
      return .failure(Self.malformedRequestError)
    }

    // Parse query parameters
    let path: String
    let queryParams: [String: String]
    switch HTTPRequest.parseQueryParameters(fullPath) {
    case .success(let parsedTarget):
      path = parsedTarget.path
      queryParams = parsedTarget.params
    case .failure:
      return .failure(Self.malformedRequestError)
    }

    // Parse headers (case-insensitive: store keys lowercased)
    var headers: [String: String] = [:]
    for index in 1 ..< lines.count {
      let line = lines[index]
      guard let colonIndex = line.firstIndex(of: ":") else { return .failure(Self.malformedRequestError) }
      let rawKey = String(line[..<colonIndex])
      let key = rawKey.lowercased()
      guard rawKey.isEmpty == false,
            rawKey == rawKey.trimmingCharacters(in: .whitespaces),
            rawKey.unicodeScalars.allSatisfy(Self.isHTTPHeaderNameScalar),
            headers[key] == nil else
      {
        return .failure(Self.malformedRequestError)
      }
      let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
      guard value.unicodeScalars.allSatisfy({ $0.value == 0x09 || $0.value >= 0x20 && $0.value != 0x7F }) else {
        return .failure(Self.malformedRequestError)
      }
      headers[key] = value
    }

    // Extract body using byte offset (preserves binary data correctly)
    let bodyStartIndex = headerEndIndex + 4 // skip \r\n\r\n
    let bodyData = data[bodyStartIndex ..< data.endIndex]
    if bodyData.count > Self.maxRequestBodySize {
      logWarning("Request body too large (\(bodyData.count) bytes), rejecting", category: "HTTPServer")
      return .failure(Self.payloadTooLargeResponse())
    }
    let declaredContentLength: Int
    switch Self.contentLength(fromHeaderString: headerString) {
    case .success(let length):
      declaredContentLength = length
    case .failure(let response):
      return .failure(response)
    }
    guard bodyData.count == declaredContentLength else {
      return .failure(Self.malformedRequestError)
    }
    let body = bodyData.isEmpty ? nil : Data(bodyData)

    return .success(HTTPRequest(
      method: method, path: path, headers: headers, body: body, queryParameters: queryParams
    ))
  }

  private static func isHTTPHeaderNameScalar(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.value {
    case 0x21, 0x23 ... 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x30 ... 0x39,
         0x41 ... 0x5A, 0x5E ... 0x7A, 0x7C, 0x7E:
      true
    default:
      false
    }
  }

  func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
    logDebug("HTTP Request: \(request.method) \(request.path)", category: "HTTPServer")

    // Skip authentication for health check endpoint
    let isHealthCheck = request.path == "/v1/health"

    // Check authentication if token is set (except for health check)
    // Headers are stored lowercased for case-insensitive lookup
    let authToken = configurationLock.withLock { _authToken }
    if !isHealthCheck, let authToken {
      guard let authHeader = request.headers["authorization"],
            let suppliedToken = Self.bearerToken(from: authHeader),
            constantTimeEqual(suppliedToken, expected: authToken) else
      {
        logWarning("Unauthorized request: \(request.method) \(request.path)", category: "HTTPServer")
        return HTTPResponse.error("UNAUTHORIZED", message: "Invalid or missing authentication token", statusCode: 401)
      }
    }

    guard Task.isCancelled == false else { return Self.requestCancelledResponse }

    let requestAdmissionHandler = configurationLock.withLock { _requestAdmissionHandler }
    if let requestAdmissionHandler {
      switch await requestAdmissionHandler(request) {
      case .allowed:
        guard Task.isCancelled == false else { return Self.requestCancelledResponse }
      case .leased(let release):
        guard Task.isCancelled == false else {
          await release()
          return Self.requestCancelledResponse
        }
        let response = await dispatchRequest(request)
        await release()
        return response
      case .rejected(let response):
        return response
      }
    }

    return await dispatchRequest(request)
  }

  private static let requestCancelledResponse = HTTPResponse.error(
    "REQUEST_CANCELLED",
    message: "Request processing was cancelled",
    statusCode: 499
  )

  private func dispatchRequest(_ request: HTTPRequest) async -> HTTPResponse {
    let routes = configurationLock.withLock { self.routes }

    // Find matching route (exact match or wildcard)
    if let methodHandlers = routes[request.path] {
      if let handler = methodHandlers[request.method] {
        return await invokeRouteHandler(handler, request: request)
      }
      return Self.methodNotAllowed(allowedMethods: Set(methodHandlers.keys))
    }

    // Check for parameterized routes (e.g., /v1/vms/{id})
    var allowedMethods: Set<String> = []
    for (routePath, methodHandlers) in routes {
      if routePath.contains("{"), matchesRoute(request.path, pattern: routePath) {
        allowedMethods.formUnion(methodHandlers.keys)
        if let handler = methodHandlers[request.method] {
          return await invokeRouteHandler(handler, request: request)
        }
      }
    }
    if allowedMethods.isEmpty == false {
      return Self.methodNotAllowed(allowedMethods: allowedMethods)
    }

    // Do not echo the request path back to avoid information disclosure
    logDebug("Route not found: \(request.method) \(request.path)", category: "HTTPServer")
    return HTTPResponse.error(
      "NOT_FOUND",
      message: "The requested resource was not found",
      statusCode: 404
    )
  }

  private func invokeRouteHandler(_ handler: RouteHandler, request: HTTPRequest) async -> HTTPResponse {
    do {
      return try await handler(request)
    } catch is CancellationError {
      logDebug("Handler cancelled for \(request.method) \(request.path)", category: "HTTPServer")
      return Self.requestCancelledResponse
    } catch {
      logError(
        "Handler error for \(request.method) \(request.path): \(error.localizedDescription)",
        category: "HTTPServer"
      )
      return HTTPResponse.error("INTERNAL_ERROR", message: error.localizedDescription, statusCode: 500)
    }
  }

  private func claimRequestSlot() -> Bool {
    requestLimitLock.lock()
    defer { requestLimitLock.unlock() }
    guard activeRequestCount < maxConcurrentRequests else { return false }
    activeRequestCount += 1
    return true
  }

  private func releaseRequestSlot() {
    requestLimitLock.lock()
    activeRequestCount = max(0, activeRequestCount - 1)
    requestLimitLock.unlock()
  }

  /// Compares a bearer token without branching on the supplied token length.
  private func constantTimeEqual(_ supplied: String, expected: String) -> Bool {
    let suppliedBytes = Array(supplied.utf8)
    let expectedBytes = Array(expected.utf8)

    var difference = suppliedBytes.count ^ expectedBytes.count
    for index in 0 ..< expectedBytes.count {
      let suppliedByte = index < suppliedBytes.count ? suppliedBytes[index] : 0
      difference |= Int(suppliedByte ^ expectedBytes[index])
    }

    return difference == 0
  }

  static func bearerToken(from header: String) -> String? {
    guard let separator = header.firstIndex(of: " ") else { return nil }
    let scheme = header[..<separator]
    guard scheme.caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
    let credentials = header[separator...].drop(while: { $0 == " " })
    guard credentials.isEmpty == false,
          credentials.contains(where: { $0 == " " || $0 == "\t" }) == false else
    {
      return nil
    }
    return String(credentials)
  }

  private static func methodNotAllowed(allowedMethods: Set<String>) -> HTTPResponse {
    let response = HTTPResponse.error(
      "METHOD_NOT_ALLOWED",
      message: "The requested method is not allowed for this resource",
      statusCode: 405
    )
    var headers = response.headers
    headers["Allow"] = allowedMethods.sorted().joined(separator: ", ")
    return HTTPResponse(statusCode: response.statusCode, headers: headers, body: response.body)
  }

  /// Simple route matching with {param} support
  private func matchesRoute(_ path: String, pattern: String) -> Bool {
    let pathComponents = path.split(separator: "/", omittingEmptySubsequences: false)
    let patternComponents = pattern.split(separator: "/", omittingEmptySubsequences: false)

    guard pathComponents.count == patternComponents.count else { return false }

    for (pathComp, patternComp) in zip(pathComponents, patternComponents) {
      if patternComp.hasPrefix("{"), patternComp.hasSuffix("}") {
        guard pathComp.isEmpty == false else { return false }
        continue
      }
      if pathComp != patternComp { return false }
    }

    return true
  }
}

private final class HTTPConnectionTimeout: @unchecked Sendable {
  private let item: DispatchWorkItem

  init(operation: @escaping @Sendable () -> Void) {
    item = DispatchWorkItem(block: operation)
  }

  func schedule(on queue: DispatchQueue, after seconds: TimeInterval) {
    queue.asyncAfter(deadline: .now() + seconds, execute: item)
  }

  func cancel() {
    item.cancel()
  }
}
