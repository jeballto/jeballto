import Foundation
import Network

/// HTTP server facade responsible for listener, connection, and request-slot lifecycles.
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
  private let requestDecoder: HTTPRequestDecoder
  private let router: HTTPRouter
  private let dispatcher: HTTPRequestDispatcher
  private var listener: NWListener?
  private var listenerLifecycleState: ListenerLifecycleState = .stopped
  private let lifecycleLock = NSLock()
  private var activeConnections: [ObjectIdentifier: HTTPConnectionContext] = [:]
  private let requestLimitLock = NSLock()
  private var activeRequestCount = 0

  private static let connectionTimeoutSeconds: TimeInterval = 30

  var authToken: String? {
    get { dispatcher.authToken }
    set { dispatcher.authToken = newValue }
  }

  var requestAdmissionHandler: HTTPRequestAdmissionHandler? {
    get { dispatcher.requestAdmissionHandler }
    set { dispatcher.requestAdmissionHandler = newValue }
  }

  init(
    port: UInt16,
    host: String = "0.0.0.0",
    maxConcurrentRequests: Int = 100,
    listenerFactory: @escaping ListenerFactory = { parameters, port in
      try NWListener(using: parameters, on: port)
    }
  ) {
    let router = HTTPRouter()
    self.port = port
    self.host = host
    self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    self.listenerFactory = listenerFactory
    requestDecoder = HTTPRequestDecoder()
    self.router = router
    dispatcher = HTTPRequestDispatcher(router: router)
    queue = DispatchQueue(label: "com.jeballto.httpserver")
  }
}

extension SimpleHTTPServer {
  func start() throws {
    guard let serverPort = NWEndpoint.Port(rawValue: port) else {
      throw HTTPServerError.invalidPort(port)
    }
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

  func stop() {
    let contexts = stopAcceptingAndTakeActiveConnections()
    for context in contexts {
      _ = context.requestCancellation()
    }
    logInfo("HTTP server stopped", category: "HTTPServer")
  }

  func stopAccepting() {
    let snapshot = takeListenerAndConnections(takeConnections: false)
    snapshot.readiness?.cancel()
  }

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
    newListener.newConnectionHandler = { [weak self] connection in
      self?.handleConnection(connection)
    }
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
  func route(_ method: String, _ path: String, handler: @escaping RouteHandler) {
    router.register(method: method, path: path, handler: handler)
    logDebug("Registered route: \(method) \(path)", category: "HTTPServer")
  }

  func get(_ path: String, handler: @escaping RouteHandler) {
    route("GET", path, handler: handler)
  }

  func post(_ path: String, handler: @escaping RouteHandler) {
    route("POST", path, handler: handler)
  }

  func delete(_ path: String, handler: @escaping RouteHandler) {
    route("DELETE", path, handler: handler)
  }

  func patch(_ path: String, handler: @escaping RouteHandler) {
    route("PATCH", path, handler: handler)
  }

  var registeredRouteSignatures: Set<HTTPRouteSignature> {
    router.registeredRouteSignatures
  }

  func handleRequest(_ request: HTTPRequest) async -> HTTPResponse {
    await dispatcher.dispatch(request)
  }
}

private extension SimpleHTTPServer {
  func handleConnection(_ connection: NWConnection) {
    connection.start(queue: queue)

    guard claimRequestSlot() else {
      let response = HTTPResponse.error(
        "TOO_MANY_REQUESTS",
        message: "Maximum concurrent connections exceeded",
        statusCode: 429
      )
      connection.send(content: response.toData(), completion: .contentProcessed { _ in
        connection.cancel()
      })
      return
    }

    let slot = HTTPConnectionSlot { [weak self] in
      self?.releaseRequestSlot()
    }
    let identifier = ObjectIdentifier(connection)
    let context = HTTPConnectionContext(connection: connection, slot: slot) { [weak self] in
      self?.removeActiveConnection(identifier)
    }
    guard registerActiveConnection(context, identifier: identifier) else {
      _ = context.requestCancellation()
      return
    }

    let timeout = HTTPConnectionTimeout { [weak context] in
      logDebug("Connection timed out, cancelling", category: "HTTPServer")
      _ = context?.requestCancellation()
    }
    timeout.schedule(on: queue, after: Self.connectionTimeoutSeconds)

    let reader = HTTPRequestReader(connection: connection, decoder: requestDecoder)
    reader.read { [weak self] readResult in
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
        send(errorResponse, on: connection, finishing: context)
        return
      }

      switch requestDecoder.decode(fullData) {
      case .success(let request):
        startHandler(for: request, connection: connection, context: context)
      case .failure(let errorResponse):
        send(errorResponse, on: connection, finishing: context)
      }
    }
  }

  func startHandler(
    for request: HTTPRequest,
    connection: NWConnection,
    context: HTTPConnectionContext
  ) {
    guard context.installHandlerTask({
      Task<Void, Never> {
        guard context.isCancellationRequested == false, Task.isCancelled == false else {
          context.finish()
          return
        }

        let response = await self.handleRequest(request)
        guard context.isCancellationRequested == false, Task.isCancelled == false else {
          context.finish()
          response.runAfterSendAction()
          return
        }

        connection.send(content: response.toData(), completion: .contentProcessed { _ in
          context.finish()
          response.runAfterSendAction()
        })
      }
    }) != nil else {
      context.finish()
      return
    }

    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, error in
      if error != nil {
        _ = context.requestCancellation()
      }
    }
  }

  func send(
    _ response: HTTPResponse,
    on connection: NWConnection,
    finishing context: HTTPConnectionContext
  ) {
    connection.send(content: response.toData(), completion: .contentProcessed { _ in
      context.finish()
    })
  }

  func claimRequestSlot() -> Bool {
    requestLimitLock.lock()
    defer { requestLimitLock.unlock() }
    guard activeRequestCount < maxConcurrentRequests else { return false }
    activeRequestCount += 1
    return true
  }

  func releaseRequestSlot() {
    requestLimitLock.lock()
    activeRequestCount = max(0, activeRequestCount - 1)
    requestLimitLock.unlock()
  }
}

private extension SimpleHTTPServer {
  func abandonStartupIfCurrent(_ generation: UUID) -> Bool {
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

  func markListenerReady(_ generation: UUID) -> Bool {
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
      if takeConnections {
        activeConnections.removeAll()
      }
      return ListenerStopSnapshot(readiness: readiness, contexts: contexts)
    }
  }

  static func cancelListener(_ listener: NWListener?) {
    guard let listener else { return }
    listener.newConnectionHandler = nil
    listener.stateUpdateHandler = nil
    listener.cancel()
  }

  func registerActiveConnection(
    _ context: HTTPConnectionContext,
    identifier: ObjectIdentifier
  ) -> Bool {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    guard case .running = listenerLifecycleState else { return false }
    activeConnections[identifier] = context
    return true
  }

  func removeActiveConnection(_ identifier: ObjectIdentifier) {
    lifecycleLock.lock()
    activeConnections.removeValue(forKey: identifier)
    lifecycleLock.unlock()
  }
}
