import Foundation

private struct ImageOperationTaskHandle: Sendable {
  let cancel: @Sendable () -> Void
  let wait: @Sendable () async -> Void
}

/// Main API server coordinating HTTP server and route handlers
/// Shared between Network callbacks and structured background tasks. Mutable registries and
/// configuration are protected by `stateLock`; managers provide their own actor isolation.
final class APIServer: @unchecked Sendable {
  // MARK: - Constants

  private static let serverUnavailableError = HTTPResponse.error(
    "INTERNAL_ERROR",
    message: "Server unavailable",
    statusCode: 500
  )
  static let maximumRetainedTerminalJeballtofileExecutions = 100

  // MARK: - Properties

  private let httpServer: SimpleHTTPServer
  let vmManager: VMManager
  let portForwardingManager: PortForwardingManager
  let imageManager: ImageManager
  let eventBus: EventBus
  let capabilityProvider: @Sendable () -> VirtualizationCapabilities
  let configPath: String
  let systemResetEnvironment: SystemResetEnvironment

  /// Locks protecting independent mutable state accessed from async route handlers.
  private let stateLock = NSLock()
  private let configLock = NSLock()
  private let lifecycleLock = NSLock()
  private let mutationGate = APIMutationGate()
  private var _config: Config
  private var _configRevision: UInt64 = 0
  private var _imageOperationTasks: [UUID: ImageOperationTaskHandle] = [:]
  private var _acceptsImageOperationTasks = true
  private var _jeballtofileExecutors: [UUID: JeballtofileExecutor] = [:]
  private var _terminalJeballtofileExecutionOrder: [UUID] = []
  private var _startUptime: TimeInterval?

  /// Thread-safe access to config
  var config: Config {
    configLock.withLock { _config }
  }

  func commitConfiguration(_ build: (Config) throws -> Config) throws -> (config: Config, revision: UInt64) {
    try configLock.withLock {
      let newConfig = try build(_config)
      try newConfig.save(to: configPath)
      _config = newConfig
      _configRevision &+= 1
      return (newConfig, _configRevision)
    }
  }

  func configurationSnapshot() -> (config: Config, revision: UInt64) {
    configLock.withLock { (_config, _configRevision) }
  }

  var registeredRouteSignatures: Set<HTTPRouteSignature> {
    httpServer.registeredRouteSignatures
  }

  // Mutating access to _jeballtofileExecutors is via the helpers
  // below (claim/release/get/snapshot). Exposing these as var-computed properties is unsafe:
  // `dict[key] = value` on a computed property lowers to get -> mutate-copy -> set, which
  // releases the lock between the read and the write and drops concurrent insertions.

  /// Monotonic server start time for uptime calculation.
  var startUptime: TimeInterval? {
    lifecycleLock.withLock { _startUptime }
  }

  init(
    vmManager: VMManager,
    portForwardingManager: PortForwardingManager,
    imageManager: ImageManager,
    eventBus: EventBus,
    config: Config,
    configPath: String = Config.defaultConfigPath(),
    systemResetEnvironment: SystemResetEnvironment = .live,
    capabilityProvider: @escaping @Sendable () -> VirtualizationCapabilities = { VirtualizationCapabilities() }
  ) {
    httpServer = SimpleHTTPServer(
      port: UInt16(config.api.port),
      host: config.api.host,
      maxConcurrentRequests: config.api.maxConcurrentRequests
    )
    self.vmManager = vmManager
    self.portForwardingManager = portForwardingManager
    self.imageManager = imageManager
    self.eventBus = eventBus
    self.configPath = configPath
    self.systemResetEnvironment = systemResetEnvironment
    self.capabilityProvider = capabilityProvider
    _config = config
    let mutationGate = mutationGate
    httpServer.requestAdmissionHandler = { request in
      guard Self.isMutatingRequest(request), Self.isExclusiveMaintenanceRequest(request) == false else {
        return .allowed
      }
      guard let leaseId = await mutationGate.acquireMutation() else {
        return .rejected(HTTPResponse.error(
          "MAINTENANCE_IN_PROGRESS",
          message: "The agent is performing destructive maintenance",
          statusCode: 503
        ))
      }
      return .leased {
        await mutationGate.releaseMutation(leaseId)
      }
    }

    // Set authentication token
    httpServer.authToken = config.api.token
    // Register all routes
    registerRoutes()
  }

  // MARK: - Lifecycle

  func start() throws {
    try httpServer.start()
    lifecycleLock.withLock {
      _startUptime = ProcessInfo.processInfo.systemUptime
    }
    logInfo("API server started on \(config.api.host):\(config.api.port)", category: "APIServer")
  }

  func stop() async {
    httpServer.stopAccepting()
    await suspendAndCancelImageOperationTasks()
    await cancelAndWaitAllBackgroundTasks()
    await httpServer.stopAndWait()
    // Catch work registered by a handler that was already entering route code when shutdown began.
    await cancelAndWaitAllBackgroundTasks()
    logInfo("API server stopped", category: "APIServer")
  }

  // MARK: - Route Registration

  private func registerRoutes() {
    registerVMRoutes()
    registerInfraRoutes()
    registerImageRoutes()
    registerJeballtofileRoutes()
    registerConfigRoutes()
    registerSystemRoutes()
    registerAuthRoutes()
    logInfo("API routes registered", category: "APIServer")
  }

  private func registerVMRoutes() {
    httpServer.get("/v1/health") { [weak self] _ in
      return await self?.handleHealth() ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/vms") { [weak self] request in
      return await self?.handleCreateVM(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/vms") { [weak self] request in
      return await self?.handleListVMs(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/vms/{id}") { [weak self] request in
      return await self?.handleGetVM(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/vms/{id}/start") { [weak self] request in
      return await self?.handleStartVM(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/vms/{id}/stop") { [weak self] request in
      return await self?.handleStopVM(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/vms/{id}/pause") { [weak self] request in
      return await self?.handlePauseVM(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/vms/{id}/resume") { [weak self] request in
      return await self?.handleResumeVM(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/vms") { [weak self] request in
      return await self?.handleWipeAllVMs(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/vms/{id}") { [weak self] request in
      return await self?.handleDeleteVM(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/vms/{id}/clone") { [weak self] request in
      return await self?.handleCloneVM(request) ?? Self.serverUnavailableError
    }

    httpServer.patch("/v1/vms/{id}") { [weak self] request in
      return await self?.handleUpdateVM(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/vms/{id}/install") { [weak self] request in
      return await self?.handleInstallVM(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/vms/{id}/install/status") { [weak self] request in
      return await self?.handleGetInstallStatus(request) ?? Self.serverUnavailableError
    }
  }

  private func registerInfraRoutes() {
    httpServer.get("/v1/vms/{id}/ssh") { [weak self] request in
      return await self?.handleGetSSH(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/vms/{id}/ssh") { [weak self] request in
      return await self?.handleEnableSSH(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/vms/{id}/ssh") { [weak self] request in
      return await self?.handleDisableSSH(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/vms/{id}/vnc") { [weak self] request in
      return await self?.handleEnableVNC(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/vms/{id}/vnc") { [weak self] request in
      return await self?.handleDisableVNC(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/vms/{id}/vnc") { [weak self] request in
      return await self?.handleGetVNC(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/vms/{id}/state") { [weak self] request in
      return await self?.handleGetState(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/vms/{id}/events") { [weak self] request in
      return await self?.handleGetEvents(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/vms/{id}/gui") { [weak self] request in
      return await self?.handleOpenGUI(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/vms/{id}/gui") { [weak self] request in
      return await self?.handleCloseGUI(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/vms/{id}/gui") { [weak self] request in
      return await self?.handleGetGUIStatus(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/vms/{id}/screenshot") { [weak self] request in
      return await self?.handleScreenshot(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/vms/{id}/execute") { [weak self] request in
      return await self?.handleExecuteCommand(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/vms/{id}/keystrokes") { [weak self] request in
      return await self?.handleKeystrokes(request) ?? Self.serverUnavailableError
    }
  }

  private func registerImageRoutes() {
    httpServer.get("/v1/images") { [weak self] request in
      return await self?.handleListImages(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/images/pull/operations") { [weak self] request in
      return await self?.handleListImagePullOperations(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/images/pull/operations") { [weak self] request in
      return await self?.handleCancelImagePullOperations(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/images/pull/operations/{operationId}") { [weak self] request in
      return await self?.handleGetImagePullOperation(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/images/pull/operations/{operationId}") { [weak self] request in
      return await self?.handleCancelImagePullOperation(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/images/push/operations") { [weak self] request in
      return await self?.handleListImagePushOperations(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/images/push/operations") { [weak self] request in
      return await self?.handleCancelImagePushOperations(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/images/push/operations/{operationId}") { [weak self] request in
      return await self?.handleGetImagePushOperation(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/images/push/operations/{operationId}") { [weak self] request in
      return await self?.handleCancelImagePushOperation(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/images/{id}") { [weak self] request in
      return await self?.handleGetImage(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/images") { [weak self] request in
      return await self?.handleWipeAllImages(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/images/{id}") { [weak self] request in
      return await self?.handleDeleteImage(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/images/pull") { [weak self] request in
      return await self?.handlePullImage(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/images/push") { [weak self] request in
      return await self?.handlePushImage(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/registries/login") { [weak self] request in
      return await self?.handleRegistryLogin(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/registries/logout") { [weak self] request in
      return await self?.handleRegistryLogout(request) ?? Self.serverUnavailableError
    }
  }

  private func registerJeballtofileRoutes() {
    httpServer.post("/v1/jeballtofiles") { [weak self] request in
      return await self?.handleCreateJeballtofile(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/jeballtofiles") { [weak self] request in
      return await self?.handleListJeballtofiles(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/jeballtofiles/{executionId}") { [weak self] request in
      return await self?.handleGetJeballtofileStatus(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/jeballtofiles/{executionId}/cancel") { [weak self] request in
      return await self?.handleCancelJeballtofile(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/jeballtofiles/{executionId}") { [weak self] request in
      return await self?.handleDeleteJeballtofile(request) ?? Self.serverUnavailableError
    }
  }

  private func registerConfigRoutes() {
    httpServer.get("/v1/config") { [weak self] _ in
      return await self?.handleGetConfig() ?? Self.serverUnavailableError
    }

    httpServer.patch("/v1/config") { [weak self] request in
      return await self?.handleUpdateConfig(request) ?? Self.serverUnavailableError
    }
  }

  private func registerSystemRoutes() {
    httpServer.get("/v1/system/capabilities") { [weak self] _ in
      return await self?.handleSystemCapabilities() ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/system/reset") { [weak self] request in
      return await self?.handleSystemReset(request) ?? Self.serverUnavailableError
    }
  }

  private func registerAuthRoutes() {
    httpServer.get("/v1/auth/verify") { [weak self] _ in
      return await self?.handleVerifyAuth() ?? Self.serverUnavailableError
    }
  }

  // MARK: - Helper Methods

  func makeVMResponse(from definition: VMDefinition) async -> VMResponse {
    let guiOpen = await vmManager.isGUIOpen(definition.id)
    let uptime = try? await vmManager.getVMUptime(definition.id)
    return VMResponse(from: definition, guiOpen: guiOpen, uptime: uptime)
  }

  func requireCapability(_ feature: VirtualizationFeature) -> HTTPResponse? {
    requireCapabilities([feature])
  }

  func requireCapabilities(_ features: [VirtualizationFeature]) -> HTTPResponse? {
    let capabilities = capabilityProvider()
    for feature in features {
      guard let capability = capabilities.features.first(where: { $0.id == feature.rawValue }) else {
        return HTTPResponse.error(
          "CAPABILITY_UNAVAILABLE",
          message: "Capability \(feature.rawValue) is not registered",
          statusCode: 409
        )
      }
      guard capability.enabled else {
        let reason = capability.reason ?? "Capability is unavailable on this host"
        return HTTPResponse.error(
          "CAPABILITY_UNAVAILABLE",
          message: "\(feature.rawValue) is unavailable: \(reason)",
          statusCode: 409
        )
      }
    }
    return nil
  }

  func extractResourceId(from path: String) -> UUID? {
    let components = path.split(separator: "/")
    guard components.count >= 3 else { return nil }

    let idString = String(components[2])
    return UUID(uuidString: idString)
  }

  func invalidQueryParameter(_ error: Error) -> HTTPResponse {
    HTTPResponse.error(
      "INVALID_QUERY_PARAMETER",
      message: error.localizedDescription,
      statusCode: 400
    )
  }

  func beginExclusiveMaintenance() async -> Bool {
    guard await mutationGate.beginMaintenance() else { return false }
    await suspendAndCancelImageOperationTasks()
    return true
  }

  func waitForActiveMutationsToDrain() async {
    await mutationGate.waitUntilDrained()
  }

  func endExclusiveMaintenance() async {
    resumeImageOperationTasks()
    await mutationGate.endMaintenance()
  }

  private static func isMutatingRequest(_ request: HTTPRequest) -> Bool {
    request.method == "POST" || request.method == "PATCH" || request.method == "DELETE"
  }

  private static func isExclusiveMaintenanceRequest(_ request: HTTPRequest) -> Bool {
    request.method == "POST" && request.path == "/v1/system/reset"
      || request.method == "DELETE" && (request.path == "/v1/vms" || request.path == "/v1/images")
  }

  /// Atomically inserts a Jeballtofile executor.
  func setJeballtofileExecutor(_ executionId: UUID, executor: JeballtofileExecutor) {
    stateLock.lock()
    defer { stateLock.unlock() }
    _terminalJeballtofileExecutionOrder.removeAll { $0 == executionId }
    _jeballtofileExecutors[executionId] = executor
  }

  /// Marks a fully-finished execution as eligible for bounded history retention.
  /// The executor calls this only after its task exits, so cancellation cleanup remains drainable.
  func recordTerminalJeballtofileExecutor(_ executionId: UUID) {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let executor = _jeballtofileExecutors[executionId],
          executor.execution.status != .running,
          _terminalJeballtofileExecutionOrder.contains(executionId) == false else { return }

    _terminalJeballtofileExecutionOrder.append(executionId)
    trimTerminalJeballtofileExecutionsIfNeeded()
  }

  private func trimTerminalJeballtofileExecutionsIfNeeded() {
    let overflow = _terminalJeballtofileExecutionOrder.count
      - Self.maximumRetainedTerminalJeballtofileExecutions
    guard overflow > 0 else { return }

    let expiredIds = _terminalJeballtofileExecutionOrder.prefix(overflow)
    for executionId in expiredIds {
      _jeballtofileExecutors.removeValue(forKey: executionId)
    }
    _terminalJeballtofileExecutionOrder.removeFirst(overflow)
  }

  /// Starts and stores the background task for an async image operation while holding the state lock.
  @discardableResult
  func startImageOperationTask<Success: Sendable>(
    _ operationId: UUID,
    start: () -> Task<Success, Never>
  ) -> Task<Success, Never>? {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard _acceptsImageOperationTasks else { return nil }
    let task = start()
    _imageOperationTasks[operationId] = ImageOperationTaskHandle(
      cancel: { task.cancel() },
      wait: { _ = await task.value }
    )
    return task
  }

  private func suspendAndCancelImageOperationTasks() async {
    let tasks = stateLock.withLock { () -> [UUID: ImageOperationTaskHandle] in
      _acceptsImageOperationTasks = false
      return _imageOperationTasks
    }
    for task in tasks.values {
      task.cancel()
    }
    for operationId in tasks.keys {
      await imageManager.cancelImageOperation(operationId)
    }
    for task in tasks.values {
      await task.wait()
    }
    stateLock.withLock {
      for operationId in tasks.keys {
        _imageOperationTasks.removeValue(forKey: operationId)
      }
    }
  }

  private func resumeImageOperationTasks() {
    stateLock.withLock {
      _acceptsImageOperationTasks = true
    }
  }

  #if DEBUG
  func suspendImageOperationTaskRegistrationForTesting() async {
    await suspendAndCancelImageOperationTasks()
  }

  func resumeImageOperationTaskRegistrationForTesting() {
    resumeImageOperationTasks()
  }
  #endif

  /// Removes the stored background task after completion.
  func releaseImageOperationTask(_ operationId: UUID) {
    stateLock.lock()
    defer { stateLock.unlock() }
    _imageOperationTasks.removeValue(forKey: operationId)
  }

  @discardableResult
  func cancelImageOperationTask(_ operationId: UUID) -> Bool {
    guard let task = imageOperationTask(operationId) else { return false }
    task.cancel()
    return true
  }

  @discardableResult
  func cancelAndWaitImageOperationTask(_ operationId: UUID) async -> Bool {
    guard let task = imageOperationTask(operationId) else { return false }
    task.cancel()
    await task.wait()
    return true
  }

  @discardableResult
  func cancelAndWaitImageOperationTasks(_ operationIds: Set<UUID>) async -> Int {
    let tasks = imageOperationTasks(operationIds: operationIds)

    for task in tasks.values {
      task.cancel()
    }
    for task in tasks.values {
      await task.wait()
    }
    return tasks.count
  }

  @discardableResult
  func cancelAllImageOperationTasks() async -> Int {
    let tasks = imageOperationTasks()

    for task in tasks.values {
      task.cancel()
    }
    for operationId in tasks.keys {
      await imageManager.cancelImageOperation(operationId)
    }
    for task in tasks.values {
      await task.wait()
    }
    return tasks.count
  }

  private func imageOperationTasks() -> [UUID: ImageOperationTaskHandle] {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _imageOperationTasks
  }

  private func imageOperationTask(_ operationId: UUID) -> ImageOperationTaskHandle? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _imageOperationTasks[operationId]
  }

  private func imageOperationTasks(operationIds: Set<UUID>) -> [UUID: ImageOperationTaskHandle] {
    stateLock.lock()
    defer { stateLock.unlock() }
    var tasks: [UUID: ImageOperationTaskHandle] = [:]
    for operationId in operationIds {
      if let task = _imageOperationTasks[operationId] {
        tasks[operationId] = task
      }
    }
    return tasks
  }

  func finishImageOperationTask(_ operationId: UUID, result: Result<ImageRecord, Error>) async {
    switch result {
    case .success(let record):
      await imageManager.completeImageOperation(operationId, record: record)
    case .failure(let error):
      await imageManager.failImageOperation(operationId, error: error)
    }
    releaseImageOperationTask(operationId)
  }

  /// Atomically removes the expected Jeballtofile executor.
  @discardableResult
  func removeJeballtofileExecutor(_ executionId: UUID, expected: JeballtofileExecutor) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard _jeballtofileExecutors[executionId] === expected else { return false }
    _jeballtofileExecutors.removeValue(forKey: executionId)
    _terminalJeballtofileExecutionOrder.removeAll { $0 == executionId }
    return true
  }

  @discardableResult
  func cancelAllJeballtofileExecutors() async -> Int {
    let executors = drainJeballtofileExecutors()
    for executor in executors.values where executor.execution.status == .running {
      executor.cancel()
    }
    for executor in executors.values {
      await executor.waitUntilFinished()
    }
    return executors.count
  }

  private func drainJeballtofileExecutors() -> [UUID: JeballtofileExecutor] {
    stateLock.lock()
    defer { stateLock.unlock() }
    let executors = _jeballtofileExecutors
    _jeballtofileExecutors.removeAll()
    _terminalJeballtofileExecutionOrder.removeAll()
    return executors
  }

  /// Returns the executor for the given id, or nil.
  func getJeballtofileExecutor(_ executionId: UUID) -> JeballtofileExecutor? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _jeballtofileExecutors[executionId]
  }

  /// Returns a snapshot of active executors and retained terminal history.
  func listJeballtofileExecutors() -> [JeballtofileExecutor] {
    stateLock.lock()
    defer { stateLock.unlock() }
    return Array(_jeballtofileExecutors.values)
  }

  func cancelAndWaitAllBackgroundTasks() async {
    let installs = await vmManager.cancelAllInstallations()
    let images = await cancelAllImageOperationTasks()
    let jeballtofiles = await cancelAllJeballtofileExecutors()
    logInfo(
      "Cancelled background tasks: installs=\(installs), images=\(images), jeballtofiles=\(jeballtofiles)",
      category: "APIServer"
    )
  }
}

actor APIMutationGate {
  private var maintenanceInProgress = false
  private var activeMutations: Set<UUID> = []
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []

  func acquireMutation() -> UUID? {
    guard maintenanceInProgress == false else { return nil }
    let id = UUID()
    activeMutations.insert(id)
    return id
  }

  func releaseMutation(_ id: UUID) {
    activeMutations.remove(id)
    resumeDrainWaitersIfNeeded()
  }

  func beginMaintenance() -> Bool {
    guard maintenanceInProgress == false else { return false }
    maintenanceInProgress = true
    return true
  }

  func waitUntilDrained() async {
    guard activeMutations.isEmpty == false else { return }
    await withCheckedContinuation { continuation in
      drainWaiters.append(continuation)
    }
  }

  func endMaintenance() {
    maintenanceInProgress = false
  }

  #if DEBUG
  func hasDrainWaiterForTesting() -> Bool {
    drainWaiters.isEmpty == false
  }
  #endif

  private func resumeDrainWaitersIfNeeded() {
    guard activeMutations.isEmpty else { return }
    let waiters = drainWaiters
    drainWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}
