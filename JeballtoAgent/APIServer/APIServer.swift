import Foundation

/// Main API server coordinating HTTP server and route handlers
class APIServer {
  // MARK: - Constants

  private static let serverUnavailableError = HTTPResponse.error(
    "INTERNAL_ERROR",
    message: "Server unavailable",
    statusCode: 500
  )

  // MARK: - Properties

  private let httpServer: SimpleHTTPServer
  let vmManager: VMManager
  let portForwardingManager: PortForwardingManager
  let imageManager: ImageManager
  let eventBus: EventBus
  let capabilityProvider: @Sendable () -> VirtualizationCapabilities

  /// Lock protecting mutable state accessed from async route handlers
  private let stateLock = NSLock()
  private var _config: Config
  /// Active install per VM: a unique token (stamped by claim) plus the Task. The token lets a
  /// completing task check that it is still the current claim before removing its entry.
  private var _installationTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
  private var _imageOperationTasks: [UUID: Task<Void, Never>] = [:]
  private var _jeballtofileExecutors: [UUID: JeballtofileExecutor] = [:]

  /// Thread-safe access to config
  var config: Config {
    get { stateLock.lock(); defer { stateLock.unlock() }; return _config }
    set { stateLock.lock(); defer { stateLock.unlock() }; _config = newValue }
  }

  // Mutating access to _installationTasks and _jeballtofileExecutors is via the helpers
  // below (claim/release/get/snapshot). Exposing these as var-computed properties is unsafe:
  // `dict[key] = value` on a computed property lowers to get -> mutate-copy -> set, which
  // releases the lock between the read and the write and drops concurrent insertions.

  /// Server start time for uptime calculation
  let startTime: Date

  init(
    vmManager: VMManager,
    portForwardingManager: PortForwardingManager,
    imageManager: ImageManager,
    eventBus: EventBus,
    config: Config,
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
    self.capabilityProvider = capabilityProvider
    _config = config
    startTime = Date()

    // Set authentication token
    httpServer.authToken = config.api.token
    vmManager.installCancellationHandler = { [weak self] vmId in
      self?.cancelInstallationTask(vmId) ?? false
    }

    // Register all routes
    registerRoutes()
  }

  // MARK: - Lifecycle

  func start() throws {
    try httpServer.start()
    logInfo("API server started on \(config.api.host):\(config.api.port)", category: "APIServer")
  }

  func stop() {
    httpServer.stop()
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

    httpServer.get("/v1/images/pull/operations/{id}") { [weak self] request in
      return await self?.handleGetImagePullOperation(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/images/pull/operations/{id}") { [weak self] request in
      return await self?.handleCancelImagePullOperation(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/images/push/operations") { [weak self] request in
      return await self?.handleListImagePushOperations(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/images/push/operations") { [weak self] request in
      return await self?.handleCancelImagePushOperations(request) ?? Self.serverUnavailableError
    }

    httpServer.get("/v1/images/push/operations/{id}") { [weak self] request in
      return await self?.handleGetImagePushOperation(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/images/push/operations/{id}") { [weak self] request in
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

    httpServer.get("/v1/jeballtofiles/{id}") { [weak self] request in
      return await self?.handleGetJeballtofileStatus(request) ?? Self.serverUnavailableError
    }

    httpServer.post("/v1/jeballtofiles/{id}/cancel") { [weak self] request in
      return await self?.handleCancelJeballtofile(request) ?? Self.serverUnavailableError
    }

    httpServer.delete("/v1/jeballtofiles/{id}") { [weak self] request in
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

  func updateVMDefinition(_ vmId: UUID, definition: VMDefinition) async throws {
    try await vmManager.updateVMDefinition(vmId, definition: definition)
  }

  func extractResourceId(from path: String) -> UUID? {
    let components = path.split(separator: "/")
    guard components.count >= 3 else { return nil }

    let idString = String(components[2])
    return UUID(uuidString: idString)
  }

  /// Atomically reserves an installation slot for `vmId` and runs `start` inside the lock
  /// to produce the Task, so the task and its release token are assigned together. Returns
  /// nil (without calling `start`) if a non-cancelled task already owns the slot.
  ///
  /// `start` is passed a release token it must forward to `releaseInstallationTask` when
  /// the task body finishes, so only the owning task can evict its own entry.
  func claimInstallationTask(_ vmId: UUID, start: (UUID) -> Task<Void, Never>) -> Task<Void, Never>? {
    stateLock.lock()
    defer { stateLock.unlock() }
    if let existing = _installationTasks[vmId], !existing.task.isCancelled {
      return nil
    }
    let token = UUID()
    let task = start(token)
    _installationTasks[vmId] = (token, task)
    return task
  }

  /// Atomically removes an installation task entry. Only removes if the stored token matches,
  /// so a stale completion from a superseded task cannot evict the currently-claimed task.
  func releaseInstallationTask(_ vmId: UUID, token: UUID) {
    stateLock.lock()
    defer { stateLock.unlock() }
    if _installationTasks[vmId]?.token == token {
      _installationTasks.removeValue(forKey: vmId)
    }
  }

  /// Atomically inserts a Jeballtofile executor.
  func setJeballtofileExecutor(_ executionId: UUID, executor: JeballtofileExecutor) {
    stateLock.lock()
    defer { stateLock.unlock() }
    _jeballtofileExecutors[executionId] = executor
  }

  /// Starts and stores the background task for an async image operation while holding the state lock.
  @discardableResult
  func startImageOperationTask(_ operationId: UUID, start: () -> Task<Void, Never>) -> Task<Void, Never> {
    stateLock.lock()
    defer { stateLock.unlock() }
    let task = start()
    _imageOperationTasks[operationId] = task
    return task
  }

  /// Removes the stored background task after completion.
  func releaseImageOperationTask(_ operationId: UUID) {
    stateLock.lock()
    defer { stateLock.unlock() }
    _imageOperationTasks.removeValue(forKey: operationId)
  }

  @discardableResult
  func cancelImageOperationTask(_ operationId: UUID) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let task = _imageOperationTasks.removeValue(forKey: operationId) else { return false }
    task.cancel()
    return true
  }

  @discardableResult
  func cancelAndWaitImageOperationTask(_ operationId: UUID) async -> Bool {
    guard let task = drainImageOperationTask(operationId) else { return false }
    task.cancel()
    await task.value
    return true
  }

  @discardableResult
  func cancelAndWaitImageOperationTasks(_ operationIds: Set<UUID>) async -> Int {
    let tasks = drainImageOperationTasks(operationIds: operationIds)

    for task in tasks.values {
      task.cancel()
    }
    for task in tasks.values {
      await task.value
    }
    return tasks.count
  }

  @discardableResult
  func cancelAllImageOperationTasks() async -> Int {
    let tasks = drainImageOperationTasks()

    for task in tasks.values {
      task.cancel()
    }
    for operationId in tasks.keys {
      await imageManager.cancelImageOperation(operationId)
    }
    for task in tasks.values {
      await task.value
    }
    return tasks.count
  }

  private func drainImageOperationTasks() -> [UUID: Task<Void, Never>] {
    stateLock.lock()
    defer { stateLock.unlock() }
    let tasks = _imageOperationTasks
    _imageOperationTasks.removeAll()
    return tasks
  }

  private func drainImageOperationTask(_ operationId: UUID) -> Task<Void, Never>? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _imageOperationTasks.removeValue(forKey: operationId)
  }

  private func drainImageOperationTasks(operationIds: Set<UUID>) -> [UUID: Task<Void, Never>] {
    stateLock.lock()
    defer { stateLock.unlock() }
    var tasks: [UUID: Task<Void, Never>] = [:]
    for operationId in operationIds {
      if let task = _imageOperationTasks.removeValue(forKey: operationId) {
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

  /// Atomically removes a Jeballtofile executor.
  func removeJeballtofileExecutor(_ executionId: UUID) {
    stateLock.lock()
    defer { stateLock.unlock() }
    _jeballtofileExecutors.removeValue(forKey: executionId)
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
    return executors
  }

  /// Returns the executor for the given id, or nil.
  func getJeballtofileExecutor(_ executionId: UUID) -> JeballtofileExecutor? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return _jeballtofileExecutors[executionId]
  }

  /// Returns a snapshot of all active executors.
  func listJeballtofileExecutors() -> [JeballtofileExecutor] {
    stateLock.lock()
    defer { stateLock.unlock() }
    return Array(_jeballtofileExecutors.values)
  }

  @discardableResult
  func cancelInstallationTask(_ vmId: UUID) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard let task = _installationTasks.removeValue(forKey: vmId) else { return false }
    task.task.cancel()
    return true
  }
}
