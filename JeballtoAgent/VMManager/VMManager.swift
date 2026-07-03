// swiftlint:disable file_length type_body_length
import Foundation
import Network
import os
import Virtualization

/// Tracks detailed installation progress for a VM
struct InstallProgress {
  var progress: Double // overall 0.0 to 1.0
  var phaseProgress: Double // progress within current phase 0.0 to 1.0
  var message: String
  var phase: String // "setup", "downloading", "installing"
  var bytesDownloaded: UInt64?
  var bytesTotal: UInt64?
  var downloadSpeed: UInt64? // bytes per second (instantaneous)
}

/// Central manager for all VM instances
actor VMManager {
  /// Maximum concurrent running/installing VMs (Apple Silicon hardware limit)
  private static let maxConcurrentVMs = 2
  private static let natResolveMaxAttempts = 20

  /// In-memory registry of active VM instances
  private var vmRegistry: [UUID: VMInstance] = [:]

  /// Tracks current installation progress per VM
  private var installationProgress: [UUID: InstallProgress] = [:]

  /// Active installers (needed to access VZVirtualMachine during installation for keystroke injection)
  private var activeInstallers: [UUID: VMInstaller] = [:]

  /// Tracks when a VM entered RUNNING state (for uptime calculation)
  private var runningSinceByVM: [UUID: Date] = [:]

  /// Background networking setup tasks, keyed by VM ID, so they can be cancelled on stop/delete
  private var networkingTasks: [UUID: Task<Void, Never>] = [:]

  /// Background SSH readiness probing tasks, keyed by VM ID
  private var sshProbingTasks: [UUID: Task<Void, Never>] = [:]

  /// Lifetime-expiry tasks, keyed by VM ID. Sleeps until `definition.expiresAt`, then stops the VM.
  private var expiryTasks: [UUID: Task<Void, Never>] = [:]

  /// VM IDs that have claimed one Apple Virtualization slot while transitioning into an active state.
  private var capacityReservations: Set<UUID> = []

  /// VM IDs currently being exported as OCI images.
  private var imageExportReservations: [UUID: UUID] = [:]

  /// Tracks which VMs have had their SSH daemon confirmed ready this boot cycle
  private var sshReadyVMs: Set<UUID> = []

  /// Persistence store for VM definitions
  private let persistenceStore: PersistenceStore

  /// Event bus for VM events
  private let eventBus: EventBus

  /// Configuration
  private let config: Config

  private let guiManager: GUIManager?
  private let networkManager: NetworkManager?
  private let portForwardingManager: PortForwardingManager?

  /// Callback into APIServer to cancel tracked install tasks during force deletion.
  nonisolated(unsafe) var installCancellationHandler: (@Sendable (UUID) -> Bool)?

  /// Subscription token for event bus (nonisolated(unsafe) to allow assignment in actor init)
  private nonisolated(unsafe) var eventSubscription: EventBus.SubscriptionToken?

  init(
    persistenceStore: PersistenceStore,
    eventBus: EventBus,
    config: Config,
    guiManager: GUIManager? = nil,
    networkManager: NetworkManager? = nil,
    portForwardingManager: PortForwardingManager? = nil
  ) {
    self.persistenceStore = persistenceStore
    self.eventBus = eventBus
    self.config = config
    self.guiManager = guiManager
    self.networkManager = networkManager
    self.portForwardingManager = portForwardingManager

    // Subscribe to VM events to persist state changes
    eventSubscription = eventBus.subscribe { [weak self] event in
      guard let self else { return }
      Task<Void, Never> { await self.handleEvent(event) }
    }
  }

  deinit { if let token = eventSubscription { eventBus.unsubscribe(token) } }

  /// Handles VM events and persists state changes
  private func handleEvent(_ event: VMEvent) async {
    switch event {
    case .vmStarting(let id): await persistState(id, .starting)
    case .vmRunning(let id):
      await persistState(id, .running)
      if runningSinceByVM[id] == nil {
        runningSinceByVM[id] = Date()
      }
      networkingTasks[id]?.cancel()
      networkingTasks[id] = Task<Void, Never> { await self.setupNetworkingForVM(id) }
      await startExpiryOnFirstRun(id)
    case .vmStopping(let id): await persistState(id, .stopping)
    case .vmStopped(let id):
      await persistState(id, .stopped)
      runningSinceByVM.removeValue(forKey: id)
      networkingTasks[id]?.cancel()
      networkingTasks.removeValue(forKey: id)
      sshProbingTasks[id]?.cancel()
      sshProbingTasks.removeValue(forKey: id)
      sshReadyVMs.remove(id)
      cancelExpiry(id)
      await cleanupNetworkingForVM(id)
      await deleteIfEphemeral(id)
    case .vmPaused(let id):
      await persistState(id, .paused)
      runningSinceByVM.removeValue(forKey: id)
      networkingTasks[id]?.cancel()
      networkingTasks.removeValue(forKey: id)
      sshProbingTasks[id]?.cancel()
      sshProbingTasks.removeValue(forKey: id)
      sshReadyVMs.remove(id)
      await cleanupNetworkingForVM(id)
    case .vmResumed(let id):
      await persistState(id, .running, label: "after resume")
      runningSinceByVM[id] = Date()
      networkingTasks[id]?.cancel()
      networkingTasks[id] = Task<Void, Never> { await self.setupNetworkingForVM(id) }
    case .installProgress(
      let vmId,
      let progress,
      let phaseProgress,
      let message,
      let phase,
      let bytesDownloaded,
      let bytesTotal,
      let downloadSpeed
    ):
      installationProgress[vmId] = InstallProgress(
        progress: progress, phaseProgress: phaseProgress, message: message, phase: phase,
        bytesDownloaded: bytesDownloaded, bytesTotal: bytesTotal, downloadSpeed: downloadSpeed
      )
    case .installCompleted(let vmId):
      installationProgress[vmId] = InstallProgress(
        progress: 1.0, phaseProgress: 1.0, message: "Installation completed", phase: "completed"
      )
    case .installFailed(let vmId, let error):
      let current = installationProgress[vmId]?.progress ?? 0.0
      installationProgress[vmId] = InstallProgress(
        progress: current, phaseProgress: 0.0, message: "Failed: \(error)", phase: "failed"
      )
    case .errorOccurred(let id, _):
      if let id {
        cancelExpiry(id)
        await deleteIfEphemeral(id)
      }
    default: break
    }
  }

  /// Auto-deletes ephemeral VMs when they reach a terminal state
  private func deleteIfEphemeral(_ id: UUID) async {
    guard let instance = vmRegistry[id] else { return }
    let isEphemeral = await MainActor.run { instance.definition.ephemeral }
    guard isEphemeral else { return }
    logInfo("Ephemeral VM \(id) reached terminal state - auto-deleting", category: "VMManager")
    do {
      try await deleteVM(id, deleteFiles: true, force: false)
    } catch {
      logWarning("Failed to auto-delete ephemeral VM \(id): \(error)", category: "VMManager")
    }
  }

  /// On first `.running` after creation, stamps `expiresAt` from `lifetimeSeconds` and schedules an expiry task.
  /// Idempotent: if `expiresAt` is already set, just (re)schedules the task.
  private func startExpiryOnFirstRun(_ id: UUID) async {
    guard let instance = vmRegistry[id] else { return }
    let (lifetime, existing) = await MainActor.run {
      (instance.definition.lifetimeSeconds, instance.definition.expiresAt)
    }
    guard let lifetime else { return }
    if existing == nil {
      let expiry = Date().addingTimeInterval(TimeInterval(lifetime))
      await MainActor.run { instance.definition.setExpiry(expiry) }
      let snapshot = await MainActor.run { instance.definition }
      do {
        try await persistenceStore.updateVM(id, snapshot)
      } catch {
        logWarning("Failed to persist expiresAt for VM \(id): \(error)", category: "VMManager")
      }
      logInfo("VM \(id) lifetime \(lifetime)s -> expires at \(expiry)", category: "VMManager")
    }
    scheduleExpiry(id)
  }

  /// Schedules a background task that fires at `definition.expiresAt`. Replaces any existing task.
  private func scheduleExpiry(_ id: UUID) {
    expiryTasks[id]?.cancel()
    guard let instance = vmRegistry[id] else { return }
    let task = Task<Void, Never> { [weak self] in
      guard let self else { return }
      let expiresAt = await MainActor.run { instance.definition.expiresAt }
      guard let expiresAt else { return }
      let delay = expiresAt.timeIntervalSinceNow
      if delay > 0 {
        let nanos = UInt64(min(delay, TimeInterval(UInt64.max / 1_000_000_000)) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
      }
      if Task.isCancelled { return }
      await handleExpiry(id)
    }
    expiryTasks[id] = task
  }

  private func cancelExpiry(_ id: UUID) {
    expiryTasks[id]?.cancel()
    expiryTasks.removeValue(forKey: id)
  }

  /// Invoked when a VM's lifetime expires: stops if still operational. Ephemeral delete happens via `.vmStopped` ->
  /// `deleteIfEphemeral`.
  private func handleExpiry(_ id: UUID) async {
    expiryTasks.removeValue(forKey: id)
    guard let instance = vmRegistry[id] else { return }
    let state = instance.currentState
    let operational: Set<VMState> = [.starting, .running, .pausing, .paused, .resuming]
    guard operational.contains(state) else {
      logInfo("VM \(id) expiry fired in non-operational state \(state.rawValue); no action", category: "VMManager")
      return
    }
    logInfo("VM \(id) reached lifetime limit - stopping", category: "VMManager")
    do {
      if state == .paused {
        try await forceStopVM(id)
      } else {
        try await stopVM(id)
      }
    } catch {
      logWarning("Failed to stop VM \(id) on expiry: \(error)", category: "VMManager")
    }
  }

  /// Persists a VM state change, logging errors without throwing
  private func persistState(_ vmId: UUID, _ state: VMState, label: String? = nil) async {
    do {
      try await persistenceStore.updateVMState(vmId, state: state)
    } catch {
      let suffix = label.map { " \($0)" } ?? ""
      logError("Failed to persist \(state.rawValue)\(suffix) for VM \(vmId): \(error)", category: "VMManager")
    }
  }

  // MARK: - Initialization

  /// Loads all persisted VMs and reconciles their states.
  ///
  /// Transitional states (`starting`, `stopping`, `pausing`, `resuming`) are reset to `stopped`
  /// because the `VZVirtualMachine` process does not survive an agent restart. `paused` VMs with
  /// an existing save file on disk are preserved and can be resumed. All other states are kept as-is.
  func loadPersistedVMs() async throws {
    logInfo("Loading persisted VMs from database", category: "VMManager")

    let definitions = await persistenceStore.listVMs()

    for var definition in definitions {
      // Reconcile state: transitional and operational states become STOPPED after agent restart
      // Exception: PAUSED VMs with save files are preserved for resume
      let needsReconciliation = definition.state != .created && definition.state != .stopped
        && definition.state != .error && definition.state != .deleted
      if needsReconciliation {
        let hasSaveFile = definition.paths.saveFilePath.map { FileManager.default.fileExists(atPath: $0) } ?? false

        if definition.state == .paused, hasSaveFile {
          logInfo(
            "VM \(definition.id) was PAUSED with save file. Preserving PAUSED state for resume.",
            category: "VMManager"
          )
        } else {
          let state = definition.state.rawValue
          logWarning(
            "VM \(definition.id) was \(state) but agent restarted, marking STOPPED",
            category: "VMManager"
          )
          definition.updateState(.stopped)

          // Clean up orphan save files for non-paused VMs being forced to STOPPED
          if let saveFilePath = definition.paths.saveFilePath,
             FileManager.default.fileExists(atPath: saveFilePath)
          {
            try? FileManager.default.removeItem(atPath: saveFilePath)
            logInfo("Cleaned up orphan save file for VM \(definition.id)", category: "VMManager")
          }
        }
      }

      // Clear stale network state from previous agent run.
      // TCP proxies don't survive restarts, so persisted ports/IPs are invalid.
      // This matches what cleanupNetworkingForVM() does for normal stops.
      if definition.network.sshPort != nil || definition.network.vncPort != nil || definition.network.natIP != nil {
        let ssh = definition.network.sshPort.map(String.init) ?? "nil"
        let vnc = definition.network.vncPort.map(String.init) ?? "nil"
        let nat = definition.network.natIP ?? "nil"
        logInfo(
          "Clearing stale network state for VM \(definition.id) (ssh: \(ssh), vnc: \(vnc), nat: \(nat))",
          category: "VMManager"
        )
        definition.clearSSHPort()
        definition.clearVNCPort()
        definition.clearNATIP()
      }

      // Persist any changes from reconciliation or stale network cleanup
      if definition != definitions[definitions.firstIndex(where: { $0.id == definition.id })!] {
        try await persistenceStore.updateVM(definition.id, definition)
      }

      // Create VMInstance (but don't start it)
      let def = definition
      let instance = await MainActor.run { VMInstance(definition: def, eventBus: eventBus) }
      vmRegistry[definition.id] = instance

      // Restore expiry timer if one was persisted
      if def.expiresAt != nil {
        scheduleExpiry(def.id)
      }
    }

    logInfo("Loaded \(definitions.count) VMs from persistence", category: "VMManager")
  }

  // MARK: - VM Creation

  /// Creates a new blank VM with the specified configuration.
  ///
  /// The VM starts in `created` state. macOS must be installed via `installVM(id:source:progressCallback:)`
  /// before the VM can be started. To create a VM from an OCI image (no install needed),
  /// use ``createVMFromImage(name:imagePath:ephemeral:lifetimeSeconds:resources:)`` instead.
  func createVM(
    name: String,
    resources: VMResources,
    ephemeral: Bool = false,
    lifetimeSeconds: Int? = nil
  ) async throws -> VMDefinition {
    let vmId = UUID()
    logInfo(
      "Creating new VM: \(name) with ID: \(vmId) (ephemeral: \(ephemeral), lifetime: \(lifetimeSeconds.map(String.init) ?? "none"))",
      category: "VMManager"
    )

    // Create paths for the VM
    let paths = VMPaths.forVM(id: vmId, baseDir: config.storage.vmStorageDir)

    // Create VM definition
    let definition = VMDefinition(
      id: vmId,
      name: name,
      state: .created,
      ephemeral: ephemeral,
      resources: resources,
      network: VMNetwork(), // Generates unique MAC address
      paths: paths,
      metadata: [:],
      lifetimeSeconds: lifetimeSeconds
    )

    // Validate resources
    guard resources.validate() else {
      throw VMManagerError.invalidResources("Resources do not meet minimum requirements")
    }

    // Create VM bundle directory
    try FileManager.default.createDirectory(atPath: paths.bundlePath, withIntermediateDirectories: true)

    // Persist the definition
    try await persistenceStore.createVM(definition)

    // Create VM instance
    let instance = await MainActor.run { VMInstance(definition: definition, eventBus: eventBus) }
    vmRegistry[vmId] = instance

    // Publish event
    eventBus.publish(.vmCreated(vmId: vmId, name: name))

    logInfo("VM \(name) created successfully with ID: \(vmId)", category: "VMManager")

    return definition
  }

  /// Creates a VM by cloning an existing image bundle.
  ///
  /// Resources come from the image bundle itself (or from `VMResources.default` placeholder when
  /// the bundle is from a registry pull). Callers that need specific CPU, memory, or disk should use
  /// `PATCH /v1/vms/{id}` after creation. `resources` arg here is only used internally by
  /// `cloneVM` to carry source VM resources into the clone.
  func createVMFromImage(
    name: String,
    imagePath: String,
    ephemeral: Bool = false,
    lifetimeSeconds: Int? = nil,
    resources: VMResources = VMResources.default
  ) async throws -> VMDefinition {
    let vmId = UUID()
    logInfo(
      "Creating VM from image: \(name) with ID: \(vmId) (ephemeral: \(ephemeral), lifetime: \(lifetimeSeconds.map(String.init) ?? "none"))",
      category: "VMManager"
    )

    let paths = VMPaths.forVM(id: vmId, baseDir: config.storage.vmStorageDir)

    guard resources.validate() else {
      throw VMManagerError.invalidResources("Resources do not meet minimum requirements")
    }

    // Clone the image bundle to the new VM path
    try FileManager.default.copyItem(atPath: imagePath, toPath: paths.bundlePath)

    do {
      // Regenerate MachineIdentifier for uniqueness (HardwareModel is preserved from source)
      let machineIdentifierURL = URL(fileURLWithPath: paths.machineIdentifierPath)
      let newMachineIdentifier = VZMacMachineIdentifier()
      try newMachineIdentifier.dataRepresentation.write(to: machineIdentifierURL)

      // Remove stale save file from source - it references the old MachineIdentifier
      if let saveFilePath = paths.saveFilePath, FileManager.default.fileExists(atPath: saveFilePath) {
        try? FileManager.default.removeItem(atPath: saveFilePath)
      }

      let definition = VMDefinition(
        id: vmId,
        name: name,
        state: .stopped,
        ephemeral: ephemeral,
        resources: resources,
        network: VMNetwork(),
        paths: paths,
        metadata: ["createdFromImage": imagePath],
        lifetimeSeconds: lifetimeSeconds
      )

      try await persistenceStore.createVM(definition)

      let instance = await MainActor.run { VMInstance(definition: definition, eventBus: eventBus) }
      vmRegistry[vmId] = instance

      eventBus.publish(.vmCreated(vmId: vmId, name: name))

      logInfo("VM \(name) created from image with ID: \(vmId)", category: "VMManager")
      return definition
    } catch {
      // Clean up the cloned bundle on failure
      try? FileManager.default.removeItem(atPath: paths.bundlePath)
      throw error
    }
  }

  // MARK: - VM Cloning

  /// Creates a clone of an existing VM with a new name and identity
  func cloneVM(
    _ sourceVmId: UUID,
    name: String,
    resources: VMResources? = nil,
    force: Bool = false,
    ephemeral: Bool = false
  ) async throws -> VMDefinition {
    let sourceInstance = try getVMInstance(sourceVmId)

    if force {
      try await forceStopVM(sourceVmId)
    }

    guard sourceInstance.currentState == .stopped || sourceInstance.currentState == .created else {
      throw VMManagerError.invalidState(
        "Source VM must be stopped before cloning (current: \(sourceInstance.currentState.rawValue), use force=true to auto-stop)"
      )
    }

    let sourceDefinition = await MainActor.run { sourceInstance.definition }
    let cloneResources = resources ?? sourceDefinition.resources

    guard cloneResources.validate() else {
      throw VMManagerError.invalidResources("Resources do not meet minimum requirements")
    }

    logInfo("Cloning VM \(sourceVmId) as '\(name)'", category: "VMManager")

    let clonedDefinition = try await createVMFromImage(
      name: name,
      imagePath: sourceDefinition.paths.bundlePath,
      ephemeral: ephemeral,
      resources: cloneResources
    )

    eventBus.publish(.vmCloned(vmId: clonedDefinition.id, sourceVmId: sourceVmId, name: name))

    logInfo("VM \(sourceVmId) cloned as \(clonedDefinition.id)", category: "VMManager")
    return clonedDefinition
  }

  // MARK: - VM Updates

  /// Updates name, CPU, memory, and/or disk for a stopped or created VM.
  /// Disk can only be enlarged, not shrunk. Resource changes take effect on next VM start.
  func updateVM(
    _ vmId: UUID,
    name: String?,
    cpuCount: Int?,
    memorySize: UInt64?,
    diskSize: UInt64?
  ) async throws -> VMDefinition {
    let instance = try getVMInstance(vmId)

    let hasResourceChanges = cpuCount != nil || memorySize != nil || diskSize != nil

    let state = instance.currentState
    if hasResourceChanges {
      try ensureNoImageExportReservation(for: vmId, operation: "update resources for")
      guard state == .stopped || state == .created else {
        throw VMManagerError.invalidState(
          "VM must be stopped or created to update resources (current: \(state.rawValue))"
        )
      }
    }

    var definition = await MainActor.run { instance.definition }

    if let name { definition.name = name }

    if hasResourceChanges {
      var newResources = definition.resources

      if let cpuCount { newResources.cpuCount = cpuCount }
      if let memorySize { newResources.memorySize = memorySize }

      if let diskSize {
        guard diskSize >= definition.resources.diskSize else {
          throw VMManagerError.invalidResources(
            "Disk can only be enlarged, not shrunk (current: \(definition.resources.diskGB)GB)"
          )
        }

        if diskSize > definition.resources.diskSize {
          let diskImagePath = definition.paths.diskImagePath
          guard FileManager.default.fileExists(atPath: diskImagePath) else {
            throw VMManagerError.operationFailed("Disk image not found at \(diskImagePath)")
          }
          try resizeDiskImage(at: diskImagePath, to: diskSize)
          logInfo(
            "Resized disk image for VM \(vmId): \(definition.resources.diskGB)GB -> \(Double(diskSize) / (1024 * 1024 * 1024))GB",
            category: "VMManager"
          )
        }

        newResources.diskSize = diskSize
      }

      guard newResources.validate() else {
        throw VMManagerError.invalidResources("Resources do not meet minimum requirements")
      }

      definition.resources = newResources
    }

    definition.updatedAt = Date()

    let updatedDefinition = definition
    await MainActor.run { instance.definition = updatedDefinition }
    try await persistenceStore.updateVM(vmId, updatedDefinition)

    eventBus.publish(.vmResourcesUpdated(vmId: vmId))

    logInfo("Updated VM \(vmId)", category: "VMManager")
    return updatedDefinition
  }

  /// Builds the Apple-supported resize command for VM disk images.
  ///
  /// VM disks are created as ASIF via `diskutil image create`, so they must be resized
  /// through `diskutil image resize` rather than `hdiutil resize`.
  static func diskImageResizeCommand(path: String, newSize: UInt64) -> (executableURL: URL, arguments: [String]) {
    (
      executableURL: URL(fileURLWithPath: "/usr/sbin/diskutil"),
      arguments: ["image", "resize", "--size", "\(newSize)", path]
    )
  }

  /// Resizes a VM disk image using the Apple-supported path for ASIF images.
  private func resizeDiskImage(at path: String, to newSize: UInt64) throws {
    let command = Self.diskImageResizeCommand(path: path, newSize: newSize)
    let process = Process()
    process.executableURL = command.executableURL
    process.arguments = command.arguments

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw VMManagerError.operationFailed(
        "Disk resize failed for \(path) (exit \(process.terminationStatus)): \(output)"
      )
    }
  }

  // MARK: - VM Lifecycle Operations

  /// Starts a VM.
  ///
  /// Enforces the Apple Silicon 2-VM concurrent limit. Active count includes running, installing,
  /// paused, transitional VMs, and in-flight start/resume/install reservations.
  /// Throws `VMManagerError.concurrentVMLimitReached` if the limit is exceeded.
  func startVM(_ vmId: UUID) async throws {
    let instance = try getVMInstance(vmId)

    try ensureNoImageExportReservation(for: vmId, operation: "start")
    let initialState = instance.currentState
    let reserved = try reserveCapacityIfNeeded(for: vmId, currentState: initialState, operation: "start")
    defer { if reserved { releaseCapacityReservation(for: vmId) } }

    logInfo("Starting VM \(vmId)", category: "VMManager")

    // Initialize if not already initialized
    if await MainActor.run(body: { instance.virtualMachine }) == nil { try await instance.initialize() }

    // Start the VM (event handler will persist the state)
    try await instance.start()

    logInfo("VM \(vmId) started successfully", category: "VMManager")
  }

  /// Stops a VM
  func stopVM(_ vmId: UUID) async throws {
    let instance = try getVMInstance(vmId)

    if instance.currentState == .stopped {
      logInfo("VM \(vmId) is already stopped, returning existing state", category: "VMManager")
      return
    }

    logInfo("Stopping VM \(vmId)", category: "VMManager")

    // Stop the VM (event handler will persist the state via delegate callback)
    try await instance.stop()

    logInfo("VM \(vmId) stopped successfully", category: "VMManager")
  }

  /// Pauses a VM
  func pauseVM(_ vmId: UUID) async throws {
    let instance = try getVMInstance(vmId)

    logInfo("Pausing VM \(vmId)", category: "VMManager")

    // Pause the VM (event handler will persist the state)
    try await instance.pause()

    logInfo("VM \(vmId) paused successfully", category: "VMManager")
  }

  /// Resumes a paused VM
  func resumeVM(_ vmId: UUID) async throws {
    let instance = try getVMInstance(vmId)

    let initialState = instance.currentState
    let reserved = try reserveCapacityIfNeeded(for: vmId, currentState: initialState, operation: "resume")
    defer { if reserved { releaseCapacityReservation(for: vmId) } }

    logInfo("Resuming VM \(vmId)", category: "VMManager")

    // Initialize if not already initialized (needed after agent restart)
    if await MainActor.run(body: { instance.virtualMachine }) == nil {
      try await instance.initialize()
    }

    // Check if we need to restore from save file (after agent restart)
    if let saveFilePath = await MainActor.run(body: { instance.definition.paths.saveFilePath }),
       FileManager.default.fileExists(atPath: saveFilePath)
    {
      logInfo("Resuming VM \(vmId) from saved state file", category: "VMManager")
      try await instance.resumeFromSave()
      logInfo("VM \(vmId) resumed from save file successfully", category: "VMManager")
      return
    }

    // Normal resume (VM already in memory)
    try await instance.resume()

    logInfo("VM \(vmId) resumed successfully", category: "VMManager")
  }

  /// Saves a VM's state
  func saveVM(_ vmId: UUID) async throws {
    let instance = try getVMInstance(vmId)

    logInfo("Saving VM \(vmId) state", category: "VMManager")

    // Save the VM
    try await instance.save()

    // Update persistence
    try await persistenceStore.updateVMState(vmId, state: .paused)

    logInfo("VM \(vmId) state saved successfully", category: "VMManager")
  }

  // MARK: - VM Installation

  func installVM(_ vmId: UUID, ipswSource: String? = nil) async throws {
    let instance = try getVMInstance(vmId)

    logInfo("Starting installation for VM \(vmId)", category: "VMManager")

    guard instance.currentState == .created else {
      throw VMManagerError.invalidState(
        "VM must be in CREATED state for installation (current: \(instance.currentState.rawValue))"
      )
    }

    let reserved = try reserveCapacityIfNeeded(for: vmId, currentState: instance.currentState, operation: "install")
    defer { if reserved { releaseCapacityReservation(for: vmId) } }

    // Update state to INSTALLING
    try instance.stateMachine.transition(to: .installing)
    await MainActor.run { instance.definition.updateState(.installing) }
    try await persistenceStore.updateVMState(vmId, state: .installing)

    let definition = await MainActor.run { instance.definition }
    let installer = VMInstaller(vmDefinition: definition, eventBus: eventBus)
    activeInstallers[vmId] = installer

    do {
      try await runInstallation(installer: installer, ipswSource: ipswSource)
      try await completeInstallation(vmId: vmId, instance: instance, installer: installer)
    } catch {
      await handleInstallationFailure(vmId: vmId, instance: instance, error: error)
      throw error
    }
  }

  /// Runs the appropriate installation method based on the IPSW source
  private func runInstallation(installer: VMInstaller, ipswSource: String?) async throws {
    if let ipswSource {
      if ipswSource.hasPrefix("https://") {
        try await installer.downloadAndInstallFromURL(ipswSource)
      } else if ipswSource.hasPrefix("http://") {
        throw VMManagerError
          .operationFailed("HTTP URLs are not allowed for IPSW downloads due to MITM risk. Use HTTPS instead.")
      } else {
        try await installer.installFromIPSW(ipswPath: ipswSource)
      }
    } else {
      try await installer.downloadAndInstall()
    }
  }

  /// Cleans up after successful installation: detaches installer VM, sets state to STOPPED
  func completeInstallation(vmId: UUID, instance: VMInstance, installer: VMInstaller) async throws {
    guard !skipInstallationFinalizationIfCancelled(vmId: vmId, context: "post-install cleanup") else { return }

    // After installation, VZMacOSInstaller auto-boots the VM transiently.
    // We detach and let it shut down on its own - calling stop() is unsafe here
    // due to a race with VZVirtualMachine's precondition check.
    logInfo("Post-installation cleanup for VM \(vmId)", category: "VMManager")

    if let installerVM = installer.virtualMachine {
      installer.delegate?.onStop = nil
      installer.delegate?.onError = nil
      await MainActor.run { installerVM.delegate = nil }
      let vmState = await MainActor.run { installerVM.state }
      logInfo("Post-install VM state: \(vmState.rawValue) (detached)", category: "VMManager")

      // The macOS installer auto-boots the VM transiently after installation.
      // Wait for that transient VM to fully stop before releasing, so callers
      // (e.g. Jeballtofile start step) can acquire the auxiliary storage lock.
      if vmState != .stopped {
        logInfo("Waiting for transient installer VM to release auxiliary storage...", category: "VMManager")
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
          try await Task.sleep(nanoseconds: 500_000_000) // 500ms
          guard !skipInstallationFinalizationIfCancelled(
            vmId: vmId,
            context: "post-install auxiliary storage wait"
          ) else { return }
          let state = await MainActor.run { installerVM.state }
          if state == .stopped {
            logInfo("Transient installer VM stopped - auxiliary storage released", category: "VMManager")
            break
          }
        }
      }
    }

    activeInstallers.removeValue(forKey: vmId)
    guard !skipInstallationFinalizationIfCancelled(vmId: vmId, context: "final installation state update") else { return }

    instance.stateMachine.forceState(.stopped)
    await MainActor.run { instance.definition.updateState(.stopped) }
    try await persistenceStore.updateVMState(vmId, state: .stopped)
    eventBus.publish(.vmStopped(vmId: vmId))

    logInfo("Installation completed - VM set to STOPPED (start explicitly to use)", category: "VMManager")
  }

  /// Handles installation failure: transitions to error state and publishes failure event
  func handleInstallationFailure(vmId: UUID, instance: VMInstance, error: Error) async {
    guard !skipInstallationFinalizationIfCancelled(vmId: vmId, context: "installation failure handling") else { return }

    activeInstallers.removeValue(forKey: vmId)

    do { try instance.stateMachine.transition(to: .error) } catch {
      logWarning("Failed to transition to error state: \(error)", category: "VMManager")
    }
    await MainActor.run { instance.definition.updateState(.error) }
    do { try await persistenceStore.updateVMState(vmId, state: .error) } catch {
      logWarning("Failed to persist error state: \(error)", category: "VMManager")
    }

    eventBus.publish(.installFailed(vmId: vmId, error: error.localizedDescription))
    logError("Installation failed for VM \(vmId): \(error)", category: "VMManager")
  }

  private func skipInstallationFinalizationIfCancelled(vmId: UUID, context: String) -> Bool {
    guard Task.isCancelled else { return false }
    activeInstallers.removeValue(forKey: vmId)
    logInfo("Skipping \(context) for cancelled installation of VM \(vmId)", category: "VMManager")
    return true
  }

  /// Gets the installation status for a VM
  func getInstallationStatus(_ vmId: UUID) throws -> (state: VMState, installProgress: InstallProgress?) {
    let instance = try getVMInstance(vmId)
    let progressInfo = installationProgress[vmId]
    return (instance.currentState, progressInfo)
  }

  // MARK: - Network Setup

  /// Waits for any pending networking setup task for a VM to complete.
  /// Call before enabling SSH/VNC to avoid race conditions with auto-enable.
  func awaitNetworkingSetup(_ vmId: UUID) async {
    if let task = networkingTasks[vmId] {
      _ = await task.value
    }
  }

  /// Resolves NAT IP and sets up SSH forwarding after a VM becomes running
  private func setupNetworkingForVM(_ vmId: UUID) async {
    guard let ip = await ensureNATIP(vmId, logFailure: false) else {
      guard !Task.isCancelled else { return }
      logInfo(
        "NAT IP not yet available for VM \(vmId); SSH/VNC forwarding can be enabled once IP appears",
        category: "VMManager"
      )
      return
    }

    let definition: VMDefinition
    do {
      definition = try await persistenceStore.getVM(vmId)
    } catch {
      logError("Failed to load VM \(vmId) for network setup: \(error)", category: "VMManager")
      return
    }

    var updated = definition
    if updated.network.natIP == nil {
      updated.updateNATIP(ip)
    }

    if config.networking.autoEnableSSHForwarding, updated.network.sshPort == nil, let portForwardingManager {
      if let sshPort = await portForwardingManager.allocatePort() {
        do {
          try await portForwardingManager.setupSSHForwarding(vmId: vmId, vmIPAddress: ip, sshPort: sshPort)
          updated.updateSSHPort(sshPort)
          logInfo("Auto-enabled SSH forwarding for VM \(vmId) on port \(sshPort)", category: "VMManager")
          sshProbingTasks[vmId]?.cancel()
          sshProbingTasks[vmId] = Task<Void, Never> { await self.probeSSHReadiness(vmId: vmId, sshPort: sshPort) }
        } catch {
          await portForwardingManager.releasePort(sshPort)
          logError("Failed to setup SSH forwarding for VM \(vmId): \(error)", category: "VMManager")
        }
      }
    }

    do {
      try await persistenceStore.updateVM(vmId, updated)
      if let instance = vmRegistry[vmId] {
        let snapshot = updated
        await MainActor.run { instance.definition = snapshot }
      }
    } catch {
      logError("Failed to persist network config for VM \(vmId): \(error)", category: "VMManager")
    }
  }

  /// Probes localhost:sshPort in the background until the SSH daemon responds with its banner,
  /// then publishes sshReady. Stops on task cancellation or if already published for this boot.
  private func probeSSHReadiness(vmId: UUID, sshPort: Int) async {
    let maxAttempts = 40
    let probeDelay: UInt64 = 3_000_000_000 // 3 seconds between probes

    for attempt in 1 ... maxAttempts {
      if Task.isCancelled { return }
      if sshReadyVMs.contains(vmId) { return }

      if await checkSSHBanner(port: sshPort) {
        if Task.isCancelled { return }
        sshReadyVMs.insert(vmId)
        eventBus.publish(.sshReady(vmId: vmId))
        logInfo(
          "SSH daemon ready on VM \(vmId) port \(sshPort) (probe attempt \(attempt))",
          category: "VMManager"
        )
        return
      }

      logDebug(
        "SSH probe \(attempt)/\(maxAttempts) - no banner yet on port \(sshPort)",
        category: "VMManager"
      )
      do {
        try await Task.sleep(nanoseconds: probeDelay)
      } catch {
        return
      }
    }

    logWarning(
      "SSH probe exhausted \(maxAttempts) attempts for VM \(vmId) on port \(sshPort)",
      category: "VMManager"
    )
  }

  /// Attempts a TCP connection to localhost:port and reads the SSH banner.
  /// Returns true if the banner starts with "SSH-2.0".
  /// Cancels the NWConnection immediately if the calling task is cancelled.
  private func checkSSHBanner(port: Int) async -> Bool {
    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
    let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
    let connection = NWConnection(to: endpoint, using: .tcp)
    let queue = DispatchQueue(label: "com.jeballto.sshprobe.\(port)")

    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        // OSAllocatedUnfairLock is Sendable, preventing Swift 6 warnings for mutable
        // var capture across @Sendable closures dispatched on a serial queue.
        let resumed = OSAllocatedUnfairLock(initialState: false)

        connection.stateUpdateHandler = { state in
          switch state {
          case .ready:
            connection.receive(minimumIncompleteLength: 8, maximumLength: 256) { data, _, _, _ in
              connection.cancel()
              let alreadyResumed = resumed.withLock { prev in
                let was = prev
                prev = true
                return was
              }
              guard !alreadyResumed else { return }
              if let data, let banner = String(data: data, encoding: .utf8) {
                continuation.resume(returning: banner.hasPrefix("SSH-2.0"))
              } else {
                continuation.resume(returning: false)
              }
            }
          case .failed, .cancelled:
            let alreadyResumed = resumed.withLock { prev in
              let was = prev
              prev = true
              return was
            }
            guard !alreadyResumed else { return }
            continuation.resume(returning: false)
          default:
            break
          }
        }

        connection.start(queue: queue)

        // Safety timeout: if no state change fires within 4 seconds, give up on this attempt.
        queue.asyncAfter(deadline: .now() + 4) {
          let alreadyResumed = resumed.withLock { prev in
            let was = prev
            prev = true
            return was
          }
          guard !alreadyResumed else { return }
          connection.cancel()
          continuation.resume(returning: false)
        }
      }
    } onCancel: {
      connection.cancel()
    }
  }

  /// Cleans up SSH/VNC forwarding and NAT IP when a VM stops
  private func cleanupNetworkingForVM(_ vmId: UUID) async {
    guard let portForwardingManager else { return }

    await portForwardingManager.stopSSHForwarding(vmId: vmId)
    await portForwardingManager.stopVNCForwarding(vmId: vmId)

    let definition: VMDefinition
    do {
      definition = try await persistenceStore.getVM(vmId)
    } catch { return }

    var updated = definition
    if let sshPort = updated.network.sshPort {
      await portForwardingManager.releasePort(sshPort)
      updated.clearSSHPort()
    }
    if let vncPort = updated.network.vncPort {
      await portForwardingManager.releaseVNCPort(vncPort)
      updated.clearVNCPort()
    }
    updated.clearNATIP()

    do {
      try await persistenceStore.updateVM(vmId, updated)
      if let instance = vmRegistry[vmId] {
        let snapshot = updated
        await MainActor.run { instance.definition = snapshot }
      }
    } catch {
      logError("Failed to clear network config for VM \(vmId): \(error)", category: "VMManager")
    }
  }

  /// Resolves and persists NAT IP for a VM if currently unknown.
  /// Returns the known/resolved IP or nil if resolution failed.
  func ensureNATIP(
    _ vmId: UUID,
    maxAttempts: Int = VMManager.natResolveMaxAttempts,
    logFailure: Bool = true
  ) async -> String? {
    guard let networkManager else { return nil }

    let definition: VMDefinition
    do {
      definition = try await persistenceStore.getVM(vmId)
    } catch {
      logError("Failed to load VM \(vmId) for NAT resolution: \(error)", category: "VMManager")
      return nil
    }

    if let existing = definition.network.natIP, !existing.isEmpty {
      return existing
    }

    guard let resolved = await networkManager.resolveNATIP(
      macAddress: definition.network.macAddress,
      maxAttempts: maxAttempts,
      logFailure: logFailure
    ) else {
      return nil
    }

    var updated = definition
    updated.updateNATIP(resolved)
    do {
      try await persistenceStore.updateVM(vmId, updated)
      if let instance = vmRegistry[vmId] {
        let snapshot = updated
        await MainActor.run { instance.definition = snapshot }
      }
    } catch {
      logError("Failed to persist NAT IP for VM \(vmId): \(error)", category: "VMManager")
    }

    return resolved
  }

  // MARK: - Command Execution

  func executeCommand(
    _ vmId: UUID,
    command: String,
    user: String,
    password: String?,
    timeout: TimeInterval,
    retryOnSSHFailure: Bool = false
  ) async throws -> CommandResult {
    let instance = try getVMInstance(vmId)
    guard instance.currentState == .running else {
      throw VMManagerError.invalidState(
        "VM must be RUNNING for command execution (current: \(instance.currentState.rawValue))"
      )
    }

    guard let sshPort = await MainActor.run(body: { instance.definition.network.sshPort }) else {
      throw VMManagerError.operationFailed("SSH port not configured for VM \(vmId)")
    }

    let executor = CommandExecutor()
    return try await executor.execute(
      command: command,
      sshPort: sshPort,
      user: user,
      password: password,
      timeout: timeout,
      retryOnSSHFailure: retryOnSSHFailure
    )
  }

  func executeKeystrokes(_ vmId: UUID, keystrokes: [String]) async throws -> Int {
    let instance = try getVMInstance(vmId)
    guard instance.currentState == .running || instance.currentState == .installing else {
      throw VMManagerError.invalidState(
        "VM must be RUNNING or INSTALLING for keystrokes (current: \(instance.currentState.rawValue))"
      )
    }

    guard let guiManager else {
      throw VMManagerError.operationFailed("GUI manager not available")
    }

    let vm: VZVirtualMachine
    if instance.currentState == .installing {
      guard let installerVM = activeInstallers[vmId]?.virtualMachine else {
        throw VMManagerError.operationFailed("Installer VM not available - installation may not have started yet")
      }
      vm = installerVM
    } else {
      guard let instanceVM = await MainActor.run(body: { instance.virtualMachine }) else {
        throw VMManagerError.operationFailed("VM instance not initialized")
      }
      vm = instanceVM
    }

    var allActions: [KeystrokeAction] = []
    for sequence in keystrokes {
      let actions = try KeystrokeParser.parse(sequence)
      allActions.append(contentsOf: actions)
    }

    let injector = KeystrokeInjector()
    return try await injector.execute(actions: allActions, vm: vm, vmId: vmId, guiManager: guiManager)
  }

  // MARK: - GUI Operations

  func openGUI(_ vmId: UUID) async throws {
    let instance = try getVMInstance(vmId)

    guard instance.currentState == .running else {
      throw VMManagerError.invalidState(
        "VM must be RUNNING to open GUI (current: \(instance.currentState.rawValue))"
      )
    }

    guard let vm = await MainActor.run(body: { instance.virtualMachine }) else {
      throw VMManagerError.operationFailed("VM has no VZVirtualMachine instance")
    }

    guard let guiManager else {
      throw VMManagerError.operationFailed("GUI manager not available")
    }

    let vmName = await MainActor.run { instance.definition.name }
    await guiManager.openGUI(vmId: vmId, virtualMachine: vm, vmName: vmName)
  }

  func closeGUI(_ vmId: UUID) async throws {
    _ = try getVMInstance(vmId)

    guard let guiManager else {
      throw VMManagerError.operationFailed("GUI manager not available")
    }

    await guiManager.closeGUI(vmId: vmId)
  }

  func isGUIOpen(_ vmId: UUID) async -> Bool {
    guard let guiManager else { return false }
    return await guiManager.isGUIOpen(vmId: vmId)
  }

  /// Captures a screenshot of a running VM's display as PNG data
  func screenshotVM(_ vmId: UUID) async throws -> Data {
    let instance = try getVMInstance(vmId)

    guard instance.currentState == .running else {
      throw VMManagerError.invalidState(
        "VM must be RUNNING to capture screenshot (current: \(instance.currentState.rawValue))"
      )
    }

    guard let vm = await MainActor.run(body: { instance.virtualMachine }) else {
      throw VMManagerError.operationFailed("VM has no VZVirtualMachine instance")
    }

    guard let guiManager else {
      throw VMManagerError.operationFailed("GUI manager not available")
    }

    do {
      return try await guiManager.captureScreenshot(vmId: vmId, virtualMachine: vm)
    } catch {
      throw VMManagerError.operationFailed("Screenshot capture failed: \(error.localizedDescription)")
    }
  }

  // MARK: - VM Deletion

  /// Forces a VM into the stopped state and persists the change.
  /// Logs persistence failures rather than silently swallowing them.
  private func forceSetStopped(_ vmId: UUID, _ instance: VMInstance) async {
    instance.stateMachine.forceState(.stopped)
    await MainActor.run { instance.definition.updateState(.stopped) }
    do {
      try await persistenceStore.updateVMState(vmId, state: .stopped)
    } catch {
      logError("Failed to persist forced stop for VM \(vmId): \(error)", category: "VMManager")
    }
  }

  /// Force-stops a VM regardless of its current state.
  /// Attempts a graceful stop for running/paused VMs; forces state for transitional states.
  func forceStopVM(_ vmId: UUID) async throws {
    let instance = try getVMInstance(vmId)

    switch instance.currentState {
    case .running, .paused:
      do {
        try await instance.stop()
      } catch {
        await forceSetStopped(vmId, instance)
      }
    case .installing:
      let removedInstaller = activeInstallers.removeValue(forKey: vmId) != nil
      let cancelledTask = installCancellationHandler?(vmId) ?? false

      if removedInstaller || cancelledTask {
        logInfo("Cancelled active installation for VM \(vmId)", category: "VMManager")
      } else {
        logInfo("No active installation to cancel for VM \(vmId)", category: "VMManager")
      }
      await forceSetStopped(vmId, instance)
    case .starting, .stopping, .pausing, .resuming:
      await forceSetStopped(vmId, instance)
    default:
      break // already stopped/created/error - nothing to do
    }
  }

  /// Deletes a VM and its associated files.
  /// - Parameters:
  ///   - vmId: UUID of the VM to delete
  ///   - deleteFiles: If true, removes the VM bundle from disk
  ///   - force: If true, force-stops the VM before deletion even if running
  func deleteVM(_ vmId: UUID, deleteFiles: Bool = true, force: Bool = false) async throws {
    logInfo("Deleting VM \(vmId) (force: \(force))", category: "VMManager")

    let instance = try getVMInstance(vmId)
    try ensureNoImageExportReservation(for: vmId, operation: "delete")

    if force {
      if let guiManager, await guiManager.isGUIOpen(vmId: vmId) {
        await guiManager.closeGUI(vmId: vmId)
      }
      try await forceStopVM(vmId)
    }

    guard instance.currentState == .stopped || instance.currentState == .created
      || instance.currentState == .error else
    {
      throw VMManagerError.invalidState("VM must be stopped before deletion")
    }

    // Capture before cleanup to avoid data race with @MainActor callbacks mutating VMInstance.definition
    let (bundlePath, vmName) = await MainActor.run { (instance.definition.paths.bundlePath, instance.definition.name) }

    if deleteFiles {
      if FileManager.default.fileExists(atPath: bundlePath) {
        try FileManager.default.removeItem(atPath: bundlePath)
        logInfo("Deleted VM bundle at \(bundlePath)", category: "VMManager")
      } else {
        logWarning("VM bundle not found at \(bundlePath)", category: "VMManager")
      }
    }

    networkingTasks[vmId]?.cancel()
    networkingTasks.removeValue(forKey: vmId)
    runningSinceByVM.removeValue(forKey: vmId)
    await instance.cleanup()
    vmRegistry.removeValue(forKey: vmId)
    installationProgress.removeValue(forKey: vmId)
    try await persistenceStore.deleteVM(vmId)
    eventBus.publish(.vmDeleted(vmId: vmId, name: vmName))

    logInfo("VM \(vmId) deleted successfully", category: "VMManager")
  }

  /// Deletes all VMs (force-stopping each) and clears the persistence database.
  /// - Returns: Tuple with count of deleted, failed, and error messages per failure
  func wipeAllVMs() async throws -> (deleted: Int, failed: Int, errors: [String]) {
    logWarning("Wiping all VMs", category: "VMManager")

    await guiManager?.closeAllGUIs()

    let vmIds = Array(vmRegistry.keys)
    var deleted = 0
    var failed = 0
    var errors: [String] = []

    for vmId in vmIds {
      do {
        try await deleteVM(vmId, deleteFiles: true, force: true)
        deleted += 1
      } catch {
        failed += 1
        errors.append("VM \(vmId): \(error.localizedDescription)")
        logError("Failed to wipe VM \(vmId): \(error)", category: "VMManager")
      }
    }

    // Clear any orphan persistence entries not in registry
    try await persistenceStore.deleteAllVMs()
    installationProgress.removeAll()
    activeInstallers.removeAll()

    logInfo("Wipe completed: \(deleted) deleted, \(failed) failed", category: "VMManager")
    return (deleted, failed, errors)
  }

  // MARK: - VM Queries

  /// Returns all VM definitions from the persistence store.
  ///
  /// This reflects the persisted state, not the in-memory registry. Definitions are the source
  /// of truth for state, resources, and network info across agent restarts.
  func listVMs() async -> [VMDefinition] { await persistenceStore.listVMs() }

  /// Gets a specific VM definition
  func getVM(_ vmId: UUID) async throws -> VMDefinition {
    do {
      return try await persistenceStore.getVM(vmId)
    } catch let error as PersistenceError {
      switch error {
      case .vmNotFound(let id):
        throw VMManagerError.vmNotFound(id)
      default:
        throw VMManagerError.operationFailed(error.localizedDescription)
      }
    }
  }

  /// Gets VM instance (in-memory)
  func getVMInstance(_ vmId: UUID) throws -> VMInstance {
    guard let instance = vmRegistry[vmId] else { throw VMManagerError.vmNotFound(vmId) }
    return instance
  }

  /// Updates a VM definition in the persistence store
  func updateVMDefinition(_ vmId: UUID, definition: VMDefinition) async throws {
    do {
      try await persistenceStore.updateVM(vmId, definition)
    } catch let error as PersistenceError {
      switch error {
      case .vmNotFound(let id):
        throw VMManagerError.vmNotFound(id)
      default:
        throw VMManagerError.operationFailed(error.localizedDescription)
      }
    }
  }

  /// Checks if a VM exists
  func vmExists(_ vmId: UUID) async -> Bool { await persistenceStore.vmExists(vmId) }

  /// Returns total number of VMs
  func vmCount() async -> Int { await persistenceStore.count() }

  /// Returns number of running VMs
  func runningVMCount() -> Int { vmRegistry.values.filter { $0.currentState == .running }.count }

  /// Returns number of active VMs (running + installing) that count against Apple's concurrent limit
  func activeVMCount() -> Int {
    let activeIds = Set(vmRegistry.compactMap { vmId, instance in
      isCapacityConsumingState(instance.currentState) ? vmId : nil
    })
    return activeIds.union(capacityReservations).count
  }

  private func isCapacityConsumingState(_ state: VMState) -> Bool {
    switch state {
    case .installing, .starting, .running, .pausing, .paused, .resuming:
      true
    case .created, .stopping, .stopped, .error, .deleted:
      false
    }
  }

  @discardableResult
  private func reserveCapacityIfNeeded(for vmId: UUID, currentState: VMState, operation: String) throws -> Bool {
    guard !isCapacityConsumingState(currentState) else { return false }

    let active = activeVMCount()
    guard active < Self.maxConcurrentVMs else {
      throw VMManagerError.concurrentVMLimitReached(
        "Cannot \(operation) VM: \(active) VMs already active (max \(Self.maxConcurrentVMs))"
      )
    }

    capacityReservations.insert(vmId)
    return true
  }

  private func releaseCapacityReservation(for vmId: UUID) {
    capacityReservations.remove(vmId)
  }

  @discardableResult
  func claimImageExport(_ vmId: UUID) throws -> UUID {
    let instance = try getVMInstance(vmId)
    let state = instance.currentState
    guard state == .stopped || state == .created else {
      throw VMManagerError.invalidState(
        "VM must be stopped or created before image export (current: \(state.rawValue))"
      )
    }
    guard imageExportReservations[vmId] == nil else {
      throw VMManagerError.invalidState("VM image export already in progress")
    }

    let token = UUID()
    imageExportReservations[vmId] = token
    return token
  }

  func releaseImageExport(_ vmId: UUID, token: UUID) {
    if imageExportReservations[vmId] == token {
      imageExportReservations.removeValue(forKey: vmId)
    }
  }

  private func ensureNoImageExportReservation(for vmId: UUID, operation: String) throws {
    guard imageExportReservations[vmId] == nil else {
      throw VMManagerError.invalidState("Cannot \(operation) VM while image export is in progress")
    }
  }

  // MARK: - State Queries

  /// Gets the current state of a VM
  func getVMState(_ vmId: UUID) throws -> VMState {
    let instance = try getVMInstance(vmId)
    return instance.currentState
  }

  /// Returns VM uptime in seconds when RUNNING, otherwise nil.
  func getVMUptime(_ vmId: UUID) throws -> Int? {
    let state = try getVMState(vmId)
    guard state == .running, let runningSince = runningSinceByVM[vmId] else {
      return nil
    }
    return max(0, Int(Date().timeIntervalSince(runningSince)))
  }

  // MARK: - Graceful Shutdown

  /// Stops all running VMs gracefully (for agent shutdown)
  func stopAllVMs() async {
    await guiManager?.closeAllGUIs()

    logInfo("Stopping all VMs for graceful shutdown", category: "VMManager")

    let instances = Array(vmRegistry.values)

    for instance in instances where instance.currentState == .running {
      let instanceId = await MainActor.run { instance.definition.id }
      do {
        logInfo("Stopping VM \(instanceId)", category: "VMManager")
        try await instance.stop()
      } catch {
        logError("Failed to stop VM \(instanceId): \(error)", category: "VMManager")
        // Force state update
        instance.stateMachine.forceState(.stopped)
        try? await persistenceStore.updateVMState(instanceId, state: .stopped)
      }
    }

    logInfo("All VMs stopped", category: "VMManager")
  }

  /// Prepares all VMs for agent shutdown.
  /// - Ephemeral VMs are stopped (if operational) and deleted - they are not intended to survive restart.
  /// - Non-ephemeral running VMs are paused and saved so they can be resumed on next launch.
  /// Bounded by the 30s timeout in `applicationShouldTerminate`.
  func cleanupForShutdown() async {
    await guiManager?.closeAllGUIs()

    logInfo("Preparing VMs for shutdown", category: "VMManager")

    let instances = Array(vmRegistry.values)

    for instance in instances {
      let (instanceId, isEphemeral) = await MainActor.run {
        (instance.definition.id, instance.definition.ephemeral)
      }
      cancelExpiry(instanceId)
      let state = instance.currentState

      if isEphemeral {
        logInfo("Cleaning up ephemeral VM \(instanceId) in state \(state.rawValue)", category: "VMManager")
        do {
          try await deleteVM(instanceId, deleteFiles: true, force: true)
        } catch {
          logError("Failed to delete ephemeral VM \(instanceId) on shutdown: \(error)", category: "VMManager")
        }
      } else if state == .running {
        do {
          logInfo("Saving VM \(instanceId)", category: "VMManager")
          try await instance.save()
        } catch { logError("Failed to save VM \(instanceId): \(error)", category: "VMManager") }
      }
    }

    logInfo("Shutdown VM cleanup complete", category: "VMManager")
  }
}

// MARK: - Errors

enum VMManagerError: Error, LocalizedError {
  case vmNotFound(UUID)
  case invalidState(String)
  case invalidResources(String)
  case operationFailed(String)
  case concurrentVMLimitReached(String)

  var errorDescription: String? {
    switch self {
    case .vmNotFound(let id): "VM not found: \(id.uuidString)"
    case .invalidState(let message): "Invalid state: \(message)"
    case .invalidResources(let message): "Invalid resources: \(message)"
    case .operationFailed(let message): "Operation failed: \(message)"
    case .concurrentVMLimitReached(let message): "Concurrent VM limit reached: \(message)"
    }
  }
}
