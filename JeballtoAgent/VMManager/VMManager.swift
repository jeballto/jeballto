// swiftlint:disable file_length type_body_length
import Darwin
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

enum VMShutdownAction: Equatable, Sendable {
  case deleteEphemeral
  case saveRunning
  case savePausedRuntime
  case recoverError
  case none
}

private enum VMCreationOperation: String, Codable {
  case blank
  case imageImport
}

private enum VMCreationPhase: String, Codable {
  case creating
  case committing
  case committed
}

private struct PendingVMCreationMarker: Codable {
  let formatVersion: Int
  let vmId: UUID
  let operation: VMCreationOperation
  let phase: VMCreationPhase
  let definition: VMDefinition?
}

private enum NetworkingSetupWaitError: Error {
  case timedOut
}

private struct NetworkingSetupTaskHandle: Sendable {
  let task: Task<Void, Never>
  let completion: NetworkingSetupCompletion
  let cancel: @Sendable () -> Void
}

private enum InstallationFinalizationFailure: Error, LocalizedError, Sendable {
  case incompleteBundle(String)
  case missingSuccessEvidence(UUID)
  case unusableSuccessEvidence(String)

  var errorDescription: String? {
    switch self {
    case .incompleteBundle(let reason):
      "Installation finalization found an incomplete VM bundle: \(reason)"
    case .missingSuccessEvidence(let vmId):
      "Installation finalization for VM \(vmId) has no durable success evidence"
    case .unusableSuccessEvidence(let reason):
      "Installation finalization cannot use its durable success evidence: \(reason)"
    }
  }
}

private enum InstallerRecoveryMode: Sendable {
  case finalizeSuccess
  case recordFinalizationFailure(InstallationFinalizationFailure)
  case cleanupCancellation
  case releaseAfterFailure
}

private struct InstallerRecoveryTaskHandle: Sendable {
  let token: UUID
  let task: Task<Void, Never>
}

private struct InstallationFailureHandlingContext: Sendable {
  let definition: VMDefinition
  let installation: VMInstallation
  let errorDescription: String
  let errorLogValue: String
  let protectsFiles: Bool
  let wasCancelled: Bool
}

private struct PendingInstallationFinalizationContext: Sendable {
  let definition: VMDefinition
  let installation: VMInstallation
  let errorDescription: String
  let errorLogValue: String
}

private final class NetworkingSetupCompletion: @unchecked Sendable {
  private struct Waiter {
    let continuation: CheckedContinuation<Void, Error>
    let timeoutItem: DispatchWorkItem?
  }

  private let lock = NSLock()
  private var completed = false
  private var waiters: [UUID: Waiter] = [:]
  private var cancelledBeforeRegistration: Set<UUID> = []

  func wait(until deadline: TimeInterval? = nil) async throws {
    try Task.checkCancellation()
    let waiterId = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        register(
          waiterId,
          continuation: continuation,
          deadline: deadline,
          taskIsCancelled: Task.isCancelled
        )
      }
    } onCancel: {
      self.cancel(waiterId)
    }
  }

  func complete() {
    let pending = lock.withLock { () -> [Waiter] in
      guard completed == false else { return [] }
      completed = true
      cancelledBeforeRegistration.removeAll()
      let pending = Array(waiters.values)
      waiters.removeAll()
      return pending
    }
    for waiter in pending {
      waiter.timeoutItem?.cancel()
      waiter.continuation.resume()
    }
  }

  private func register(
    _ waiterId: UUID,
    continuation: CheckedContinuation<Void, Error>,
    deadline: TimeInterval?,
    taskIsCancelled: Bool
  ) {
    var immediateResult: Result<Void, Error>?
    var timeoutItem: DispatchWorkItem?

    lock.lock()
    if taskIsCancelled || cancelledBeforeRegistration.remove(waiterId) != nil {
      immediateResult = .failure(CancellationError())
    } else if completed {
      immediateResult = .success(())
    } else if let deadline {
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      if remaining <= 0 {
        immediateResult = .failure(NetworkingSetupWaitError.timedOut)
      } else {
        let item = DispatchWorkItem { [weak self] in
          self?.timeOut(waiterId)
        }
        timeoutItem = item
        waiters[waiterId] = Waiter(continuation: continuation, timeoutItem: item)
      }
    } else {
      waiters[waiterId] = Waiter(continuation: continuation, timeoutItem: nil)
    }
    lock.unlock()

    if let immediateResult {
      continuation.resume(with: immediateResult)
    } else if let timeoutItem, let deadline {
      let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + remaining, execute: timeoutItem)
    }
  }

  private func cancel(_ waiterId: UUID) {
    let waiter = lock.withLock { () -> Waiter? in
      if let waiter = waiters.removeValue(forKey: waiterId) {
        return waiter
      }
      if completed == false {
        cancelledBeforeRegistration.insert(waiterId)
      }
      return nil
    }
    waiter?.timeoutItem?.cancel()
    waiter?.continuation.resume(throwing: CancellationError())
  }

  private func timeOut(_ waiterId: UUID) {
    let waiter = lock.withLock {
      waiters.removeValue(forKey: waiterId)
    }
    waiter?.continuation.resume(throwing: NetworkingSetupWaitError.timedOut)
  }
}

/// Central manager for all VM instances
actor VMManager {
  /// Product limit for VMs that consume capacity, including lifecycle transitions and reservations.
  private static let maxConcurrentVMs = 2
  private static let natResolveMaxAttempts = 20
  private static let expiryClockRecheckInterval: TimeInterval = 30
  private static let deletionPendingMetadataKey = "jeballto.deletionPending"
  private static let diskResizeTargetMetadataKey = "jeballto.diskResizeTarget"
  private static let diskResizePhaseMetadataKey = "jeballto.diskResizePhase"
  private static let pendingCreationMarkerFormatVersion = 2
  private static let pendingCreationMarkerSuffix = ".bundle.creation-pending"
  private static let pendingCreationMarkerMaxSize = 64 * 1024

  /// In-memory registry of active VM instances
  private var vmRegistry: [UUID: VMInstance] = [:]

  /// Creation transactions currently owned by this process across actor suspension points.
  private var activeVMCreations: Set<UUID> = []

  /// Tracks current installation progress per VM
  private var installationProgress: [UUID: InstallProgress] = [:]

  /// Active installers (needed to access VZVirtualMachine during installation for keystroke injection)
  private var activeInstallers: [UUID: VMInstaller] = [:]

  /// Background API installations owned by the VM domain rather than the HTTP transport.
  private var installationTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

  /// Reservations held while an installation is being persisted before its task is created.
  private var installationClaims: Set<UUID> = []

  /// Reaps an installer runtime that outlived its callback and retries post-success finalization.
  private var installerRecoveryTasks: [UUID: InstallerRecoveryTaskHandle] = [:]

  /// Tracks when a VM entered RUNNING state using a monotonic clock.
  private var runningSinceByVM: [UUID: TimeInterval] = [:]

  /// Background networking setup tasks, keyed by VM ID, so they can be cancelled on stop/delete
  private var networkingTasks: [UUID: NetworkingSetupTaskHandle] = [:]
  private var networkingGenerations: [UUID: UUID] = [:]

  /// Background SSH readiness probing tasks, keyed by VM ID
  private var sshProbingTasks: [UUID: Task<Void, Never>] = [:]
  private var sshProbeGenerations: [UUID: UUID] = [:]

  /// Lifetime-expiry tasks, keyed by VM ID. Rechecks the wall-clock deadline, then stops the VM.
  private var expiryTasks: [UUID: Task<Void, Never>] = [:]

  /// VM IDs that have claimed one Apple Virtualization slot while transitioning into an active state.
  private var capacityReservations: Set<UUID> = []
  private var runtimeCapacityOwners: Set<UUID> = []

  /// VM IDs currently being exported as OCI images.
  private var imageExportReservations: [UUID: UUID] = [:]

  /// One mutating lifecycle operation may own a VM at a time across actor reentrancy points.
  private var vmOperations: [UUID: String] = [:]

  /// Display operations for the same VM must not reorder keystrokes or replace their target view.
  private let displayOperationGate = KeyedOperationGate()

  /// Ephemeral VMs whose terminal event arrived before their lifecycle operation released ownership.
  private var pendingEphemeralDeletes: Set<UUID> = []

  /// Delayed retries for ephemeral VMs whose automatic deletion failed for a transient reason.
  private var ephemeralDeletionTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]

  /// Prevents expiry and ephemeral cleanup tasks from racing a bulk VM wipe.
  private var bulkWipeInProgress = false

  #if DEBUG
  private var imageExportClaimHookForTesting: (@Sendable () async -> Void)?
  private var startCapacityClaimHookForTesting: (@Sendable () async -> Void)?
  private var vmCreationRegistryHookForTesting: (@Sendable (UUID) async -> Void)?
  private var vmCreationPublishedHookForTesting: (@Sendable (UUID) async -> Void)?
  #endif

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
  private let diskImageResizer: (@Sendable (String, UInt64) async throws -> Void)?
  private let vmBundleRemover: @Sendable (String) throws -> Void
  private let installerRecoveryPollNanoseconds: UInt64
  private let eventProcessor = SerialAsyncProcessor()

  /// Subscription token for event bus (nonisolated(unsafe) to allow assignment in actor init)
  private nonisolated(unsafe) var eventSubscription: EventBus.SubscriptionToken?

  init(
    persistenceStore: PersistenceStore,
    eventBus: EventBus,
    config: Config,
    guiManager: GUIManager? = nil,
    networkManager: NetworkManager? = nil,
    portForwardingManager: PortForwardingManager? = nil,
    diskImageResizer: (@Sendable (String, UInt64) async throws -> Void)? = nil,
    vmBundleRemover: @escaping @Sendable (String) throws -> Void = {
      try FileManager.default.removeItem(atPath: $0)
    },
    installerRecoveryPollNanoseconds: UInt64 = 5_000_000_000
  ) {
    self.persistenceStore = persistenceStore
    self.eventBus = eventBus
    self.config = config
    self.guiManager = guiManager
    self.networkManager = networkManager
    self.portForwardingManager = portForwardingManager
    self.diskImageResizer = diskImageResizer
    self.vmBundleRemover = vmBundleRemover
    self.installerRecoveryPollNanoseconds = max(1, installerRecoveryPollNanoseconds)

    // Subscribe to VM events to persist state changes
    eventSubscription = eventBus.subscribe { [weak self] event in
      guard let self else { return }
      eventProcessor.submit { [weak self] in
        await self?.handleEvent(event)
      }
    }
  }

  deinit {
    eventProcessor.cancel()
    if let token = eventSubscription { eventBus.unsubscribe(token) }
  }

  /// Handles VM events and persists state changes
  private func handleEvent(_ event: VMEvent) async {
    switch event {
    case .vmStarting(let id): await persistState(id, .starting)
    case .vmRunning(let id):
      runtimeCapacityOwners.insert(id)
      await persistState(id, .running)
      guard vmRegistry[id]?.currentState == .running else { return }
      if runningSinceByVM[id] == nil {
        runningSinceByVM[id] = ProcessInfo.processInfo.systemUptime
      }
      await startNetworkingSetup(for: id)
    case .vmStopping(let id): await persistState(id, .stopping)
    case .vmStopped(let id):
      runtimeCapacityOwners.remove(id)
      await persistState(id, .stopped)
      guard vmRegistry[id]?.currentState == .stopped else { return }
      runningSinceByVM.removeValue(forKey: id)
      await cancelNetworkingTasks(for: id)
      cancelExpiry(id)
      await cleanupNetworkingForVM(id)
      scheduleEphemeralDelete(id, delayNanoseconds: nil)
    case .vmPaused(let id):
      runtimeCapacityOwners.insert(id)
      await persistState(id, .paused)
      guard vmRegistry[id]?.currentState == .paused else { return }
      runningSinceByVM.removeValue(forKey: id)
      await cancelNetworkingTasks(for: id)
      await cleanupNetworkingForVM(id)
    case .vmResumed(let id):
      runtimeCapacityOwners.insert(id)
      await persistState(id, .running, label: "after resume")
      guard vmRegistry[id]?.currentState == .running else { return }
      if runningSinceByVM[id] == nil {
        runningSinceByVM[id] = ProcessInfo.processInfo.systemUptime
      }
      await startNetworkingSetup(for: id)
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
    case .installCancelled(let vmId):
      let current = installationProgress[vmId]?.progress ?? 0.0
      installationProgress[vmId] = InstallProgress(
        progress: current, phaseProgress: 0.0, message: "Installation cancelled", phase: "cancelled"
      )
    case .installFailed(let vmId, let error):
      let current = installationProgress[vmId]?.progress ?? 0.0
      installationProgress[vmId] = InstallProgress(
        progress: current, phaseProgress: 0.0, message: "Failed: \(error)", phase: "failed"
      )
    case .errorOccurred(let id, _):
      if let id {
        await synchronizeRuntimeCapacityOwner(id)
        await persistState(id, .error)
        guard vmRegistry[id]?.currentState == .error else { return }
        runningSinceByVM.removeValue(forKey: id)
        cancelExpiry(id)
        await cancelNetworkingTasks(for: id)
        await cleanupNetworkingForVM(id)
        scheduleEphemeralDelete(id, delayNanoseconds: nil)
      }
    default: break
    }
  }

  private func persistNetworkField(_ vmId: UUID, update: VMNetworkFieldUpdate) async throws {
    _ = try await persistenceStore.updateVMNetworkField(vmId, update: update)
    guard let instance = vmRegistry[vmId] else { return }
    await MainActor.run {
      switch update {
      case .sshPort(let port):
        if let port { instance.definition.updateSSHPort(port) } else { instance.definition.clearSSHPort() }
      case .vncPort(let port):
        if let port { instance.definition.updateVNCPort(port) } else { instance.definition.clearVNCPort() }
      case .natIP(let ip):
        if let ip { instance.definition.updateNATIP(ip) } else { instance.definition.clearNATIP() }
      }
    }
  }

  func setSSHPort(_ port: Int?, for vmId: UUID) async throws {
    try await setNetworkField(.sshPort(port), for: vmId)
  }

  func setVNCPort(_ port: Int?, for vmId: UUID) async throws {
    try await setNetworkField(.vncPort(port), for: vmId)
  }

  private func setNetworkField(_ update: VMNetworkFieldUpdate, for vmId: UUID) async throws {
    do {
      try await persistNetworkField(vmId, update: update)
    } catch let error as PersistenceError {
      switch error {
      case .vmNotFound(let id):
        throw VMManagerError.vmNotFound(id)
      default:
        throw VMManagerError.operationFailed(error.localizedDescription)
      }
    }
  }

  /// Auto-deletes ephemeral VMs when they reach a terminal state
  @discardableResult
  private func deleteIfEphemeral(_ id: UUID, deletionTaskToken: UUID? = nil) async -> Bool {
    guard bulkWipeInProgress == false else {
      pendingEphemeralDeletes.remove(id)
      return false
    }
    guard let instance = vmRegistry[id] else {
      pendingEphemeralDeletes.remove(id)
      return false
    }
    let (isEphemeral, hasBooted) = await MainActor.run {
      (instance.definition.ephemeral, instance.definition.hasBooted)
    }
    guard Task.isCancelled == false, bulkWipeInProgress == false else { return false }
    guard isEphemeral, hasBooted else {
      pendingEphemeralDeletes.remove(id)
      return false
    }
    guard instance.currentState == .stopped || instance.currentState == .error else {
      pendingEphemeralDeletes.remove(id)
      if ephemeralDeletionTasks[id]?.token != deletionTaskToken {
        ephemeralDeletionTasks.removeValue(forKey: id)?.task.cancel()
      }
      return false
    }
    guard vmOperations[id] == nil else {
      pendingEphemeralDeletes.insert(id)
      return false
    }
    pendingEphemeralDeletes.remove(id)
    logInfo("Ephemeral VM \(id) reached terminal state - auto-deleting", category: "VMManager")
    do {
      try await deleteVM(id, force: false, owningEphemeralDeletionToken: deletionTaskToken)
      return false
    } catch {
      logWarning("Failed to auto-delete ephemeral VM \(id): \(error)", category: "VMManager")
      if deletionTaskToken == nil {
        scheduleEphemeralDeleteRetry(id)
        return false
      }
      return true
    }
  }

  private func scheduleEphemeralDeleteRetry(_ id: UUID) {
    scheduleEphemeralDelete(id, delayNanoseconds: 1_000_000_000)
  }

  private func scheduleEphemeralDelete(_ id: UUID, delayNanoseconds: UInt64?) {
    guard bulkWipeInProgress == false,
          ephemeralDeletionTasks[id] == nil,
          vmRegistry[id] != nil else { return }
    let token = UUID()
    let task = Task<Void, Never> { [weak self] in
      if let delayNanoseconds {
        do {
          try await Task.sleep(nanoseconds: delayNanoseconds)
        } catch {
          return
        }
      }
      guard let self else { return }
      await runEphemeralDelete(id, token: token)
    }
    ephemeralDeletionTasks[id] = (token, task)
  }

  private func runEphemeralDelete(_ id: UUID, token: UUID) async {
    guard ephemeralDeletionTasks[id]?.token == token else { return }
    let shouldRetry = await deleteIfEphemeral(id, deletionTaskToken: token)
    if ephemeralDeletionTasks[id]?.token == token {
      ephemeralDeletionTasks.removeValue(forKey: id)
    }
    if shouldRetry {
      scheduleEphemeralDeleteRetry(id)
    }
  }

  /// Schedules the deadline atomically recorded with the first durable `.running` state.
  private func scheduleExpiryAfterRun(_ id: UUID) async throws {
    guard let instance = vmRegistry[id] else { return }
    let (lifetime, expiresAt) = await MainActor.run {
      (instance.definition.lifetimeSeconds, instance.definition.expiresAt)
    }
    guard let lifetime else { return }
    guard let expiresAt else {
      throw VMManagerError.operationFailed(
        "VM \(id) reached running with lifetimeSeconds=\(lifetime), but no durable expiry was recorded"
      )
    }
    logInfo("VM \(id) lifetime \(lifetime)s -> expires at \(expiresAt)", category: "VMManager")
    scheduleExpiry(id)
  }

  /// Schedules a background task that fires at `definition.expiresAt`. Replaces any existing task.
  private func scheduleExpiry(_ id: UUID) {
    expiryTasks[id]?.cancel()
    guard bulkWipeInProgress == false else {
      expiryTasks.removeValue(forKey: id)
      return
    }
    guard let instance = vmRegistry[id] else { return }
    let task = Task<Void, Never> { [weak self] in
      guard let self else { return }
      let expiresAt = await MainActor.run { instance.definition.expiresAt }
      guard let expiresAt else { return }
      while let delay = Self.expirySleepInterval(expiresAt: expiresAt, now: Date()) {
        do {
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } catch {
          return
        }
      }
      if Task.isCancelled { return }
      await handleExpiry(id)
    }
    expiryTasks[id] = task
  }

  static func expirySleepInterval(expiresAt: Date, now: Date) -> TimeInterval? {
    let remaining = expiresAt.timeIntervalSince(now)
    guard remaining > 0 else { return nil }
    return min(remaining, expiryClockRecheckInterval)
  }

  private func cancelExpiry(_ id: UUID) {
    expiryTasks[id]?.cancel()
    expiryTasks.removeValue(forKey: id)
  }

  /// Invoked when a VM's lifetime expires. Ephemeral deletion is scheduled after the stopped event is processed.
  private func handleExpiry(_ id: UUID) async {
    expiryTasks.removeValue(forKey: id)
    guard bulkWipeInProgress == false else { return }
    guard let instance = vmRegistry[id] else { return }
    let state = instance.currentState

    if state == .starting || state == .stopping || state == .pausing || state == .resuming
      || vmOperations[id] != nil
    {
      scheduleExpiryRetry(id)
      return
    }

    guard state == .running || state == .paused else {
      logInfo("VM \(id) expiry fired in non-operational state \(state.rawValue); no action", category: "VMManager")
      return
    }
    logInfo("VM \(id) reached lifetime limit - stopping", category: "VMManager")
    do {
      if state == .paused {
        try await forceStopVM(id)
      } else {
        _ = try await stopVM(id)
      }
    } catch {
      logWarning("Failed to stop VM \(id) on expiry: \(error)", category: "VMManager")
      if vmRegistry[id]?.currentState == .running || vmRegistry[id]?.currentState == .paused {
        scheduleExpiryRetry(id)
      }
    }
  }

  private func scheduleExpiryRetry(_ id: UUID) {
    expiryTasks[id]?.cancel()
    expiryTasks[id] = Task<Void, Never> { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 250_000_000)
      } catch {
        return
      }
      await self?.handleExpiry(id)
    }
  }

  /// Persists a VM state change, logging errors without throwing
  private func persistState(_ vmId: UUID, _ state: VMState, label: String? = nil) async {
    guard let instance = vmRegistry[vmId] else { return }
    let definition = await MainActor.run { instance.definition }
    do {
      let persisted = try await persistLifecycle(
        vmId,
        state: state,
        markBooted: state == .running || definition.hasBooted
      )
      await applyPersistedFirstBootFields(persisted, to: instance)
    } catch {
      let suffix = label.map { " \($0)" } ?? ""
      logError(
        "Failed to persist \(definition.state.rawValue)\(suffix) for VM \(vmId) "
          + "after \(state.rawValue) event: \(error)",
        category: "VMManager"
      )
    }
  }

  private func persistCurrentState(
    _ vmId: UUID,
    from instance: VMInstance,
    stateOverride: VMState? = nil
  ) async throws {
    let definition = await MainActor.run { instance.definition }
    let state = stateOverride ?? definition.state
    let persisted = try await persistLifecycle(
      vmId,
      state: state,
      markBooted: state == .running || definition.hasBooted
    )
    await applyPersistedFirstBootFields(persisted, to: instance)
  }

  private func persistLifecycle(_ vmId: UUID, state: VMState, markBooted: Bool) async throws -> VMDefinition {
    if state == .running {
      return try await persistenceStore.updateVMRunning(vmId, runningAt: Date())
    }
    return try await persistenceStore.updateVMLifecycle(
      vmId,
      state: state,
      markBooted: markBooted
    )
  }

  private func applyPersistedFirstBootFields(_ persisted: VMDefinition, to instance: VMInstance) async {
    guard persisted.hasBooted else { return }
    await MainActor.run {
      instance.definition.hasBooted = true
      instance.definition.expiresAt = persisted.expiresAt
      if instance.definition.state == persisted.state {
        instance.definition.updatedAt = persisted.updatedAt
      }
    }
  }

  private func persistCurrentStateAfterFailure(_ vmId: UUID, from instance: VMInstance) async {
    await synchronizeRuntimeCapacityOwner(vmId, instance: instance)
    do {
      try await persistCurrentState(vmId, from: instance)
      synchronizeRuntimeUptime(for: vmId, state: instance.currentState, resetRunningStart: false)
    } catch {
      logError("Failed to persist failure state for VM \(vmId): \(error)", category: "VMManager")
    }
    await drainPublishedEvents()
  }

  private func persistSuccessfulRuntimeState(
    _ vmId: UUID,
    from instance: VMInstance,
    operation: String,
    resetRunningStart: Bool = false,
    stateOverride: VMState? = nil
  ) async throws {
    await synchronizeRuntimeCapacityOwner(vmId, instance: instance)
    do {
      try await persistCurrentState(vmId, from: instance, stateOverride: stateOverride)
      synchronizeRuntimeUptime(
        for: vmId,
        state: instance.currentState,
        resetRunningStart: resetRunningStart
      )
    } catch {
      let state = instance.currentState.rawValue
      logError(
        "VM \(vmId) reached \(state) after \(operation), but persistence failed: \(error)",
        category: "VMManager"
      )
      throw VMManagerError.operationFailed(
        "VM \(vmId) reached \(state) after \(operation), but its durable state could not be saved: "
          + error.localizedDescription
      )
    }
  }

  private func synchronizeRuntimeUptime(
    for vmId: UUID,
    state: VMState,
    resetRunningStart: Bool
  ) {
    guard state == .running else {
      runningSinceByVM.removeValue(forKey: vmId)
      return
    }
    if resetRunningStart || runningSinceByVM[vmId] == nil {
      runningSinceByVM[vmId] = ProcessInfo.processInfo.systemUptime
    }
  }

  private func synchronizeRuntimeCapacityOwner(_ vmId: UUID, instance: VMInstance? = nil) async {
    guard let instance = instance ?? vmRegistry[vmId] else {
      runtimeCapacityOwners.remove(vmId)
      return
    }
    if await MainActor.run(body: { instance.runtimeConsumesCapacity }) {
      runtimeCapacityOwners.insert(vmId)
    } else {
      runtimeCapacityOwners.remove(vmId)
    }
  }

  private func recordInitializationFailure(_ vmId: UUID, instance: VMInstance, error: Error) async {
    if instance.currentState != .error {
      await MainActor.run { instance.forceLifecycleState(.error) }
      eventBus.publish(.errorOccurred(vmId: vmId, error: error.localizedDescription))
    }
    await persistCurrentStateAfterFailure(vmId, from: instance)
  }

  private func startNetworkingSetup(for vmId: UUID) async {
    let generation = UUID()
    networkingGenerations[vmId] = generation
    let previousTask = networkingTasks.removeValue(forKey: vmId)
    previousTask?.cancel()
    _ = await previousTask?.task.value
    guard networkingGenerations[vmId] == generation else { return }
    let completion = NetworkingSetupCompletion()
    let task = Task<Void, Never> {
      await self.setupNetworkingForVM(vmId, generation: generation)
      completion.complete()
    }
    networkingTasks[vmId] = NetworkingSetupTaskHandle(
      task: task,
      completion: completion,
      cancel: { task.cancel() }
    )
  }

  private func cancelNetworkingTasks(for vmId: UUID) async {
    networkingGenerations.removeValue(forKey: vmId)
    let networkingTask = networkingTasks.removeValue(forKey: vmId)
    networkingTask?.cancel()
    _ = await networkingTask?.task.value
    cancelSSHReadinessProbe(vmId: vmId)
  }

  private func drainPublishedEvents() async {
    await eventBus.waitUntilIdle()
    await eventProcessor.waitUntilIdle()
    await guiManager?.waitForEventProcessing()
  }

  // MARK: - Initialization

  /// Loads all persisted VMs and reconciles their states.
  ///
  /// Transitional states (`starting`, `stopping`, `pausing`, `resuming`) are reset to `stopped`
  /// because the `VZVirtualMachine` process does not survive an agent restart. `paused` VMs with
  /// an existing save file on disk are preserved and can be resumed. All other states are kept as-is.
  func loadPersistedVMs() async throws {
    logInfo("Loading persisted VMs from database", category: "VMManager")

    try await persistenceStore.validateLoaded()
    var definitions = try await persistenceStore.listVMs()
    try await recoverInterruptedVMCreations(definitions: definitions)
    definitions = try await persistenceStore.listVMs()
    try validateNoUnindexedManagedBundles(definitions: definitions)

    for persistedDefinition in definitions {
      var definition = persistedDefinition
      try validateManagedPaths(for: definition)
      if try await completePendingDeletionIfNeeded(definition) { continue }
      definition = try await recoverPendingDiskResize(definition)
      let installationRecovery = try recoverPersistedInstallation(definition)
      definition = installationRecovery.definition
      definition = reconcileStateAfterRestart(definition)
      try cleanupOrphanSaveState(for: definition)
      definition = clearStaleNetworkState(definition)

      if definition != persistedDefinition {
        try await persistenceStore.updateVM(definition.id, definition)
      }
      if installationRecovery.removeSuccessMarker {
        removeInstallationSuccessMarkerBestEffort(for: definition)
      }
      await registerLoadedVM(definition)
    }

    logInfo("Loaded \(definitions.count) VMs from persistence", category: "VMManager")
  }

  private func completePendingDeletionIfNeeded(_ definition: VMDefinition) async throws -> Bool {
    guard definition.state == .deleted
      || definition.metadata[Self.deletionPendingMetadataKey] == "true" else { return false }

    if try fileSystemEntryExists(at: definition.paths.bundlePath) {
      do {
        try vmBundleRemover(definition.paths.bundlePath)
      } catch {
        throw VMManagerError.operationFailed(
          "Failed to finish pending deletion for VM \(definition.id) at \(definition.paths.bundlePath): "
            + error.localizedDescription
        )
      }
    }
    try VMInstallationSuccessMarkerStore.removeIfPresent(for: definition)
    try await persistenceStore.deleteVM(definition.id)
    logInfo("Completed pending deletion for VM \(definition.id)", category: "VMManager")
    return true
  }

  private func recoverPendingDiskResize(_ source: VMDefinition) async throws -> VMDefinition {
    guard let targetValue = source.metadata[Self.diskResizeTargetMetadataKey] else { return source }
    guard let targetSize = UInt64(targetValue) else {
      throw VMManagerError.invalidResources(
        "Invalid pending disk resize target for VM \(source.id): \(targetValue)"
      )
    }
    let phase = source.metadata[Self.diskResizePhaseMetadataKey]
    guard phase == "planned" || phase == "applied" else {
      throw VMManagerError.operationFailed(
        "Invalid pending disk resize phase for VM \(source.id): \(phase ?? "missing")"
      )
    }
    var targetResources = source.resources
    targetResources.diskSize = targetSize
    guard targetSize >= source.resources.diskSize, targetResources.validate() else {
      throw VMManagerError.invalidResources("Unsafe pending disk resize target \(targetSize) for VM \(source.id)")
    }
    if phase == "planned" {
      try await resizeDiskImage(at: source.paths.diskImagePath, to: targetSize)
    }

    var definition = source
    definition.resources.diskSize = targetSize
    definition.metadata.removeValue(forKey: Self.diskResizeTargetMetadataKey)
    definition.metadata.removeValue(forKey: Self.diskResizePhaseMetadataKey)
    definition.updatedAt = Date()
    logInfo("Completed pending disk resize for VM \(definition.id)", category: "VMManager")
    return definition
  }

  private func recoverPersistedInstallation(
    _ source: VMDefinition
  ) throws -> (definition: VMDefinition, removeSuccessMarker: Bool) {
    if source.state == .error, source.installation?.state == .failed {
      return (source, false)
    }

    if try VMInstallationSuccessMarkerStore.readIfPresent(for: source) != nil {
      do {
        try validateCompleteVMBundle(at: source.paths.bundlePath)
      } catch {
        throw VMManagerError.operationFailed(
          "VM \(source.id) has a durable installation success marker, but its bundle is incomplete: "
            + error.localizedDescription
        )
      }

      var definition = source
      var installation = definition.installation
        ?? VMInstallation(state: .finalizing, message: "Recovering completed installation")
      installation.finish(
        as: .completed,
        message: "Installation completed; durable success recovered after agent restart"
      )
      definition.updateInstallation(installation)
      definition.updateState(.stopped)
      logInfo("Recovered durable installation success for VM \(definition.id)", category: "VMManager")
      return (definition, true)
    }

    guard var installation = source.installation, installation.state.isActive else { return (source, false) }
    var definition = source
    switch installation.state {
    case .installing:
      installation.finish(
        as: .interrupted,
        message: "Installation was interrupted by an agent restart",
        error: "Agent restarted while installation was in progress"
      )
      definition.updateInstallation(installation)
      definition.updateState(.created)
      try cleanupInterruptedInstallationArtifacts(for: definition)
      logWarning(
        "Recovered interrupted installation for VM \(definition.id); installation can be retried",
        category: "VMManager"
      )
    case .finalizing:
      definition = recoverFinalizingInstallation(definition, installation: installation)
    case .completed, .failed, .cancelled, .interrupted:
      break
    }
    return (definition, false)
  }

  private func removeInstallationSuccessMarkerBestEffort(for definition: VMDefinition) {
    do {
      try VMInstallationSuccessMarkerStore.removeIfPresent(for: definition)
    } catch {
      logWarning(
        "Failed to remove durable installation success marker for VM \(definition.id): "
          + error.localizedDescription,
        category: "VMManager"
      )
    }
  }

  private func recoverFinalizingInstallation(
    _ source: VMDefinition,
    installation sourceInstallation: VMInstallation
  ) -> VMDefinition {
    var definition = source
    var installation = sourceInstallation
    do {
      try validateCompleteVMBundle(at: definition.paths.bundlePath)
      installation.finish(as: .completed, message: "Installation completed; finalization recovered after agent restart")
      definition.updateInstallation(installation)
      definition.updateState(.stopped)
      logInfo("Completed installation finalization recovery for VM \(definition.id)", category: "VMManager")
    } catch {
      installation.finish(
        as: .failed,
        message: "Installation finalization recovery failed",
        error: error.localizedDescription
      )
      definition.updateInstallation(installation)
      definition.updateState(.error)
      logError(
        "Finalizing installation for VM \(definition.id) has an incomplete bundle: \(error.localizedDescription)",
        category: "VMManager"
      )
    }
    return definition
  }

  private func reconcileStateAfterRestart(_ source: VMDefinition) -> VMDefinition {
    let needsReconciliation = source.state != .created && source.state != .stopped
      && source.state != .error && source.state != .deleted
    guard needsReconciliation else { return source }

    let hasSaveFile = FileManager.default.fileExists(atPath: source.paths.saveFilePath)
    guard source.state != .paused || hasSaveFile == false else {
      logInfo(
        "VM \(source.id) was PAUSED with save file. Preserving PAUSED state for resume.",
        category: "VMManager"
      )
      return source
    }

    var definition = source
    logWarning(
      "VM \(definition.id) was \(definition.state.rawValue) but agent restarted, marking STOPPED",
      category: "VMManager"
    )
    definition.updateState(.stopped)
    return definition
  }

  private func cleanupOrphanSaveState(for definition: VMDefinition) throws {
    let saveFilePath = definition.paths.saveFilePath
    guard definition.state != .paused,
          FileManager.default.fileExists(atPath: saveFilePath) else { return }

    try removeFileIfPresent(at: saveFilePath, context: "orphan save state for non-paused VM \(definition.id)")
    logInfo("Cleaned up orphan save file for VM \(definition.id)", category: "VMManager")
  }

  private func clearStaleNetworkState(_ source: VMDefinition) -> VMDefinition {
    guard source.network.sshPort != nil || source.network.vncPort != nil || source.network.natIP != nil else {
      return source
    }
    var definition = source
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
    return definition
  }

  private func registerLoadedVM(_ definition: VMDefinition) async {
    await networkManager?.registerMACAddress(definition.network.macAddress)
    let instance = await MainActor.run { VMInstance(definition: definition, eventBus: eventBus) }
    vmRegistry[definition.id] = instance

    if definition.ephemeral,
       definition.hasBooted,
       definition.state == .stopped || definition.state == .error
    {
      await deleteIfEphemeral(definition.id)
    } else if definition.expiresAt != nil {
      scheduleExpiry(definition.id)
    }
  }

  private func recoverInterruptedVMCreations(definitions: [VMDefinition]) async throws {
    let storagePath = config.storage.vmStorageDir
    guard FileManager.default.fileExists(atPath: storagePath) else { return }

    let entries: [String]
    do {
      entries = try FileManager.default.contentsOfDirectory(atPath: storagePath)
    } catch {
      throw VMManagerError.operationFailed(
        "Failed to inspect VM storage for interrupted creations at \(storagePath): \(error.localizedDescription)"
      )
    }

    let indexedIds = Set(definitions.map(\.id))
    for entry in entries {
      guard let id = Self.pendingCreationMarkerID(from: entry) else { continue }
      let markerPath = (storagePath as NSString).appendingPathComponent(entry)
      guard let marker = try readPendingCreationMarker(at: markerPath, expectedId: id) else { continue }
      guard activeVMCreations.contains(id) == false else { continue }

      if indexedIds.contains(id) {
        removePendingCreationMarkerBestEffort(at: markerPath, vmId: id)
        continue
      }

      let bundlePath = VMPaths.forVM(id: id, baseDir: storagePath).bundlePath
      var status = stat()
      let result = bundlePath.withCString { Darwin.lstat($0, &status) }
      if result != 0 {
        let errorCode = errno
        guard errorCode == ENOENT else {
          throw VMManagerError.operationFailed(
            "Failed to inspect interrupted VM creation target at \(bundlePath) (errno \(errorCode))"
          )
        }
        removePendingCreationMarkerBestEffort(at: markerPath, vmId: id)
        continue
      }

      guard status.st_mode & S_IFMT == S_IFDIR else {
        logWarning(
          "Pending VM creation marker for \(id) points to a non-directory entry at \(bundlePath); preserving it",
          category: "VMManager"
        )
        continue
      }

      switch marker.phase {
      case .creating:
        do {
          try FileManager.default.removeItem(atPath: bundlePath)
        } catch {
          throw VMManagerError.operationFailed(
            "Failed to remove interrupted \(marker.operation.rawValue) VM creation at \(bundlePath): "
              + error.localizedDescription
          )
        }
        logWarning(
          "Recovered interrupted \(marker.operation.rawValue) VM creation for \(id) by removing its uncommitted bundle",
          category: "VMManager"
        )
        removePendingCreationMarkerBestEffort(at: markerPath, vmId: id)

      case .committing, .committed:
        let definition = try validateRecoverableCreation(marker, bundlePath: bundlePath)
        do {
          try await persistenceStore.createVM(definition)
        } catch {
          throw VMManagerError.operationFailed(
            "Failed to reconstruct VM \(id) from its durable \(marker.phase.rawValue) creation marker: "
              + error.localizedDescription
          )
        }
        removePendingCreationMarkerBestEffort(at: markerPath, vmId: id)
        logWarning(
          "Recovered VM \(id) from its durable \(marker.phase.rawValue) creation marker after a database "
            + "commit interruption",
          category: "VMManager"
        )
      }
    }
  }

  private func validateRecoverableCreation(
    _ marker: PendingVMCreationMarker,
    bundlePath: String
  ) throws -> VMDefinition {
    guard let definition = marker.definition else {
      throw VMManagerError.operationFailed(
        "Unindexed VM bundle at \(bundlePath) has an unsupported or incomplete "
          + "\(marker.phase.rawValue) creation marker"
      )
    }
    guard definition.id == marker.vmId else {
      throw VMManagerError.operationFailed(
        "Pending VM creation marker for \(marker.vmId) contains definition \(definition.id)"
      )
    }
    try validateManagedPaths(for: definition)

    switch marker.operation {
    case .blank:
      guard definition.state == .created, definition.installation == nil else {
        throw VMManagerError.operationFailed(
          "Blank VM creation marker for \(marker.vmId) does not describe a newly created VM"
        )
      }
    case .imageImport:
      guard definition.state == .stopped, definition.installation?.state == .completed else {
        throw VMManagerError.operationFailed(
          "Image-import creation marker for \(marker.vmId) does not describe a completed stopped VM"
        )
      }
      try validateCompleteVMBundle(at: bundlePath)
    }
    return definition
  }

  private func readPendingCreationMarker(
    at markerPath: String,
    expectedId: UUID
  ) throws -> PendingVMCreationMarker? {
    do {
      guard let data = try DurableMarkerStore.readDataIfPresent(
        from: markerPath,
        maximumSize: Self.pendingCreationMarkerMaxSize
      ) else { return nil }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let marker = try decoder.decode(PendingVMCreationMarker.self, from: data)
      guard marker.formatVersion == Self.pendingCreationMarkerFormatVersion else {
        throw VMManagerError.operationFailed(
          "Unsupported pending VM creation marker version \(marker.formatVersion) at \(markerPath)"
        )
      }
      guard marker.vmId == expectedId else {
        throw VMManagerError.operationFailed(
          "Pending VM creation marker at \(markerPath) belongs to \(marker.vmId), expected \(expectedId)"
        )
      }
      switch marker.phase {
      case .creating where marker.definition != nil:
        throw VMManagerError.operationFailed(
          "Creating-phase VM marker at \(markerPath) must not contain a committed definition"
        )
      case .committing, .committed:
        guard marker.definition != nil else {
          throw VMManagerError.operationFailed(
            "\(marker.phase.rawValue.capitalized)-phase VM marker at \(markerPath) is missing its definition payload"
          )
        }
      default:
        break
      }
      return marker
    } catch let error as VMManagerError {
      throw error
    } catch {
      throw VMManagerError.operationFailed(
        "Failed to read pending VM creation marker at \(markerPath): \(error.localizedDescription)"
      )
    }
  }

  private func removePendingCreationMarkerBestEffort(at markerPath: String, vmId: UUID) {
    do {
      try DurableMarkerStore.removeIfPresent(at: markerPath)
    } catch {
      logWarning(
        "Failed to remove pending VM creation marker for \(vmId) at \(markerPath): \(error.localizedDescription)",
        category: "VMManager"
      )
    }
  }

  private static func pendingCreationMarkerID(from entry: String) -> UUID? {
    guard entry.hasPrefix("."),
          entry.hasSuffix(pendingCreationMarkerSuffix),
          entry.count > pendingCreationMarkerSuffix.count + 1 else { return nil }
    let idText = String(entry.dropFirst().dropLast(pendingCreationMarkerSuffix.count))
    return UUID(uuidString: idText)
  }

  private func validateNoUnindexedManagedBundles(definitions: [VMDefinition]) throws {
    let storagePath = config.storage.vmStorageDir
    guard FileManager.default.fileExists(atPath: storagePath) else { return }

    let indexedIds = Set(definitions.map(\.id))
    let entries: [String]
    do {
      entries = try FileManager.default.contentsOfDirectory(atPath: storagePath)
    } catch {
      throw VMManagerError.operationFailed(
        "Failed to inspect VM storage at \(storagePath): \(error.localizedDescription)"
      )
    }

    for entry in entries where entry.hasSuffix(".bundle") {
      let idText = String(entry.dropLast(".bundle".count))
      guard let id = UUID(uuidString: idText) else { continue }
      let path = (storagePath as NSString).appendingPathComponent(entry)
      var status = stat()
      guard path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
        throw VMManagerError.operationFailed("Failed to inspect managed VM entry at \(path)")
      }
      guard status.st_mode & S_IFMT == S_IFDIR else {
        throw VMManagerError.operationFailed(
          "Managed VM entry at \(path) is not a regular directory. Refusing to ignore possible database loss"
        )
      }
      guard indexedIds.contains(id) || activeVMCreations.contains(id) else {
        throw VMManagerError.operationFailed(
          "Unindexed VM bundle found at \(path). Refusing to start with an incomplete or missing VM database"
        )
      }
    }
  }

  private func cleanupInterruptedInstallationArtifacts(for definition: VMDefinition) throws {
    try validateManagedPaths(for: definition)
    let paths = [
      definition.paths.diskImagePath,
      definition.paths.auxiliaryStoragePath,
      definition.paths.hardwareModelPath,
      definition.paths.machineIdentifierPath,
      definition.paths.saveFilePath,
    ]

    for path in paths where FileManager.default.fileExists(atPath: path) {
      do {
        try FileManager.default.removeItem(atPath: path)
      } catch {
        throw VMManagerError.operationFailed(
          "Failed to clean interrupted installation artifact \(path): \(error.localizedDescription)"
        )
      }
    }
  }

  private func validateCompleteVMBundle(at bundlePath: String) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: bundlePath, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw VMManagerError.operationFailed("VM bundle directory not found at \(bundlePath)")
    }

    let requiredFiles = ["Disk.img", "AuxiliaryStorage", "HardwareModel", "MachineIdentifier"]
    let invalid = requiredFiles.filter { name in
      let path = (bundlePath as NSString).appendingPathComponent(name)
      var status = stat()
      guard path.withCString({ Darwin.lstat($0, &status) }) == 0,
            status.st_mode & S_IFMT == S_IFREG else { return true }
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber else { return true }
      return size.uint64Value == 0
    }
    guard invalid.isEmpty else {
      throw VMManagerError.operationFailed(
        "VM bundle at \(bundlePath) is incomplete; missing, empty, or invalid: \(invalid.joined(separator: ", "))"
      )
    }
  }

  private func validateManagedPaths(for definition: VMDefinition) throws {
    let expected = VMPaths.forVM(id: definition.id, baseDir: config.storage.vmStorageDir)
    let actualPaths = definition.paths
    let required: [(name: String, actual: String, expected: String)] = [
      ("bundle", actualPaths.bundlePath, expected.bundlePath),
      ("disk image", actualPaths.diskImagePath, expected.diskImagePath),
      ("auxiliary storage", actualPaths.auxiliaryStoragePath, expected.auxiliaryStoragePath),
      ("hardware model", actualPaths.hardwareModelPath, expected.hardwareModelPath),
      ("machine identifier", actualPaths.machineIdentifierPath, expected.machineIdentifierPath),
    ]

    for item in required where Self.standardizedPath(item.actual) != Self.standardizedPath(item.expected) {
      throw VMManagerError.operationFailed(
        "Refusing unsafe \(item.name) path for VM \(definition.id): \(item.actual). Expected \(item.expected)"
      )
    }

    for item in required where Self.pathIsSymbolicLink(item.actual) {
      throw VMManagerError.operationFailed(
        "Refusing symbolic link for VM \(definition.id) \(item.name): \(item.actual)"
      )
    }

    let canonicalRoot = Self.canonicalPath(config.storage.vmStorageDir)
    let canonicalBundle = Self.canonicalPath(actualPaths.bundlePath)
    let bundleURL = URL(fileURLWithPath: canonicalBundle)
    guard bundleURL.deletingLastPathComponent().path == canonicalRoot,
          bundleURL.lastPathComponent == "\(definition.id.uuidString).bundle" else
    {
      throw VMManagerError.operationFailed(
        "Refusing VM \(definition.id) bundle that resolves outside managed storage: \(actualPaths.bundlePath)"
      )
    }

    for item in required.dropFirst() {
      let parent = URL(fileURLWithPath: Self.canonicalPath(item.actual)).deletingLastPathComponent().path
      guard parent == canonicalBundle else {
        throw VMManagerError.operationFailed(
          "Refusing VM \(definition.id) \(item.name) path that resolves outside its bundle: \(item.actual)"
        )
      }
    }

    let actualSavePath = actualPaths.saveFilePath
    let expectedSavePath = expected.saveFilePath
    guard Self.standardizedPath(actualSavePath) == Self.standardizedPath(expectedSavePath) else {
      throw VMManagerError.operationFailed(
        "Refusing unsafe saved-state path for VM \(definition.id): \(actualSavePath)"
      )
    }
    let saveParent = URL(fileURLWithPath: Self.canonicalPath(actualSavePath)).deletingLastPathComponent().path
    guard saveParent == canonicalBundle else {
      throw VMManagerError.operationFailed(
        "Refusing saved-state path that resolves outside VM \(definition.id) bundle: \(actualSavePath)"
      )
    }
    if Self.pathIsSymbolicLink(actualSavePath) {
      throw VMManagerError.operationFailed(
        "Refusing symbolic link for VM \(definition.id) saved state: \(actualSavePath)"
      )
    }
  }

  private static func standardizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
  }

  private static func pathIsSymbolicLink(_ path: String) -> Bool {
    var status = stat()
    return path.withCString { Darwin.lstat($0, &status) } == 0
      && status.st_mode & S_IFMT == S_IFLNK
  }

  private func removeFileIfPresent(at path: String, context: String) throws {
    guard FileManager.default.fileExists(atPath: path) else { return }
    do {
      try FileManager.default.removeItem(atPath: path)
    } catch {
      throw VMManagerError.operationFailed(
        "Failed to remove \(context) at \(path): \(error.localizedDescription)"
      )
    }
  }

  private func beginVMCreation(_ vmId: UUID, operation: VMCreationOperation) throws -> String {
    let storagePath = config.storage.vmStorageDir
    do {
      try FileManager.default.createDirectory(
        atPath: storagePath,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw VMManagerError.operationFailed(
        "Failed to prepare VM storage at \(storagePath) for VM \(vmId): \(error.localizedDescription)"
      )
    }

    let bundlePath = VMPaths.forVM(id: vmId, baseDir: storagePath).bundlePath
    try requireAbsentFileSystemEntry(at: bundlePath, context: "VM creation target")

    let markerPath = pendingCreationMarkerPath(for: vmId)
    try requireAbsentFileSystemEntry(at: markerPath, context: "VM creation marker")
    let marker = PendingVMCreationMarker(
      formatVersion: Self.pendingCreationMarkerFormatVersion,
      vmId: vmId,
      operation: operation,
      phase: .creating,
      definition: nil
    )

    do {
      try writePendingCreationMarker(marker, at: markerPath)
    } catch {
      throw VMManagerError.operationFailed(
        "Failed to begin \(operation.rawValue) VM creation for \(vmId): \(error.localizedDescription)"
      )
    }

    activeVMCreations.insert(vmId)
    return markerPath
  }

  private func prepareVMCreationCommit(
    _ vmId: UUID,
    operation: VMCreationOperation,
    definition: VMDefinition,
    markerPath: String
  ) throws {
    do {
      try replacePendingCreationMarker(
        at: markerPath,
        with: PendingVMCreationMarker(
          formatVersion: Self.pendingCreationMarkerFormatVersion,
          vmId: vmId,
          operation: operation,
          phase: .committing,
          definition: definition
        )
      )
    } catch {
      throw VMManagerError.operationFailed(
        "Failed to prepare durable VM creation commit for \(vmId): \(error.localizedDescription)"
      )
    }
  }

  private func recordVMCreationCommittedBestEffort(
    _ vmId: UUID,
    operation: VMCreationOperation,
    definition: VMDefinition,
    markerPath: String
  ) {
    do {
      try replacePendingCreationMarker(
        at: markerPath,
        with: PendingVMCreationMarker(
          formatVersion: Self.pendingCreationMarkerFormatVersion,
          vmId: vmId,
          operation: operation,
          phase: .committed,
          definition: definition
        )
      )
    } catch {
      logError(
        "VM \(vmId) was persisted, but its creation marker could not be marked committed: "
          + error.localizedDescription,
        category: "VMManager"
      )
    }
  }

  private func replacePendingCreationMarker(
    at markerPath: String,
    with marker: PendingVMCreationMarker
  ) throws {
    guard try DurableMarkerStore.readDataIfPresent(
      from: markerPath,
      maximumSize: Self.pendingCreationMarkerMaxSize
    ) != nil else {
      throw VMManagerError.operationFailed("Pending VM creation marker is missing at \(markerPath)")
    }
    try writePendingCreationMarker(marker, at: markerPath)
  }

  private func writePendingCreationMarker(
    _ marker: PendingVMCreationMarker,
    at markerPath: String
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(marker)
    try DurableMarkerStore.writeDataAtomically(
      data,
      to: markerPath,
      maximumSize: Self.pendingCreationMarkerMaxSize
    )
  }

  private func finishVMCreation(_ vmId: UUID, markerPath: String) {
    activeVMCreations.remove(vmId)
    removePendingCreationMarkerBestEffort(at: markerPath, vmId: vmId)
  }

  private func rollbackVMCreation(_ vmId: UUID, bundlePath: String, markerPath: String) throws {
    defer { activeVMCreations.remove(vmId) }

    if try fileSystemEntryExists(at: bundlePath) {
      try FileManager.default.removeItem(atPath: bundlePath)
    }
    if try fileSystemEntryExists(at: markerPath) {
      try DurableMarkerStore.removeIfPresent(at: markerPath)
    }
  }

  private func pendingCreationMarkerPath(for vmId: UUID) -> String {
    let name = ".\(vmId.uuidString)\(Self.pendingCreationMarkerSuffix)"
    return (config.storage.vmStorageDir as NSString).appendingPathComponent(name)
  }

  private func requireAbsentFileSystemEntry(at path: String, context: String) throws {
    var status = stat()
    let result = path.withCString { Darwin.lstat($0, &status) }
    if result == 0 {
      throw VMManagerError.operationFailed("\(context) already exists at \(path)")
    }
    let errorCode = errno
    guard errorCode == ENOENT else {
      throw VMManagerError.operationFailed("Failed to inspect \(context.lowercased()) at \(path) (errno \(errorCode))")
    }
  }

  private func fileSystemEntryExists(at path: String) throws -> Bool {
    var status = stat()
    let result = path.withCString { Darwin.lstat($0, &status) }
    if result == 0 { return true }
    let errorCode = errno
    if errorCode == ENOENT { return false }
    throw VMManagerError.operationFailed("Failed to inspect filesystem entry at \(path) (errno \(errorCode))")
  }

  // MARK: - VM Creation

  /// Creates a new blank VM with the specified configuration.
  ///
  /// The VM starts in `created` state. macOS must be installed via ``startInstallation(_:ipswSource:)``
  /// before the VM can be started. To create a VM from an OCI image (no install needed),
  /// use ``createVMFromImage(name:imagePath:ephemeral:lifetimeSeconds:resources:)`` instead.
  func createVM(
    name: String,
    resources: VMResources,
    ephemeral: Bool = false,
    lifetimeSeconds: Int? = nil
  ) async throws -> VMDefinition {
    let vmId = UUID()
    let lifetimeDescription = lifetimeSeconds.map(String.init) ?? "none"
    logInfo(
      "Creating new VM: \(name) with ID: \(vmId) (ephemeral: \(ephemeral), lifetime: \(lifetimeDescription))",
      category: "VMManager"
    )

    // Create paths for the VM
    let paths = VMPaths.forVM(id: vmId, baseDir: config.storage.vmStorageDir)

    // Validate resources
    guard resources.validate() else {
      throw VMManagerError.invalidResources("Resources do not meet minimum requirements")
    }
    try validateResourcesForHost(resources)

    let markerPath = try beginVMCreation(vmId, operation: .blank)
    var allocatedMACAddress: String?
    do {
      try FileManager.default.createDirectory(
        atPath: paths.bundlePath,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.bundlePath)

      let macAddress = await networkManager?.generateUniqueMACAddress() ?? VMNetwork.generateMACAddress()
      allocatedMACAddress = macAddress
      let definition = VMDefinition(
        id: vmId,
        name: name,
        state: .created,
        ephemeral: ephemeral,
        resources: resources,
        network: VMNetwork(macAddress: macAddress),
        paths: paths,
        metadata: [:],
        lifetimeSeconds: lifetimeSeconds
      )
      let instance = await MainActor.run { VMInstance(definition: definition, eventBus: eventBus) }

      try prepareVMCreationCommit(
        vmId,
        operation: .blank,
        definition: definition,
        markerPath: markerPath
      )
      vmRegistry[vmId] = instance
      #if DEBUG
      await vmCreationRegistryHookForTesting?(vmId)
      #endif
      try await persistenceStore.createVM(definition)
      allocatedMACAddress = nil
      #if DEBUG
      await vmCreationPublishedHookForTesting?(vmId)
      #endif
      recordVMCreationCommittedBestEffort(
        vmId,
        operation: .blank,
        definition: definition,
        markerPath: markerPath
      )
      finishVMCreation(vmId, markerPath: markerPath)

      eventBus.publish(.vmCreated(vmId: vmId, name: name))
      logInfo("VM \(name) created successfully with ID: \(vmId)", category: "VMManager")
      return definition
    } catch let creationError {
      vmRegistry.removeValue(forKey: vmId)
      if let allocatedMACAddress {
        await networkManager?.releaseMACAddress(allocatedMACAddress)
      }
      do {
        try rollbackVMCreation(vmId, bundlePath: paths.bundlePath, markerPath: markerPath)
      } catch let cleanupError {
        throw VMManagerError.operationFailed(
          "Failed to create VM \(vmId): \(creationError.localizedDescription). "
            + "Cleanup of its pending creation also failed: \(cleanupError.localizedDescription)"
        )
      }
      throw creationError
    }
  }

  /// Creates a VM by cloning an existing image bundle.
  ///
  /// The caller must provide resources from the image metadata or source VM.
  func createVMFromImage(
    name: String,
    imagePath: String,
    ephemeral: Bool = false,
    lifetimeSeconds: Int? = nil,
    resources: VMResources
  ) async throws -> VMDefinition {
    let vmId = UUID()
    let lifetimeDescription = lifetimeSeconds.map(String.init) ?? "none"
    logInfo(
      "Creating VM from image: \(name) with ID: \(vmId) (ephemeral: \(ephemeral), lifetime: \(lifetimeDescription))",
      category: "VMManager"
    )

    let paths = VMPaths.forVM(id: vmId, baseDir: config.storage.vmStorageDir)

    guard resources.validate() else {
      throw VMManagerError.invalidResources("Resources do not meet minimum requirements")
    }
    try validateResourcesForHost(resources)
    try validateCompleteVMBundle(at: imagePath)

    let markerPath = try beginVMCreation(vmId, operation: .imageImport)
    var allocatedMACAddress: String?
    do {
      try await copyVMBundle(from: imagePath, to: paths.bundlePath)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.bundlePath)

      // Regenerate MachineIdentifier for uniqueness (HardwareModel is preserved from source)
      let machineIdentifierURL = URL(fileURLWithPath: paths.machineIdentifierPath)
      let newMachineIdentifier = VZMacMachineIdentifier()
      try newMachineIdentifier.dataRepresentation.write(to: machineIdentifierURL)

      // A copied save state references the source machine identity and must not survive the import.
      try removeFileIfPresent(at: paths.saveFilePath, context: "copied saved state")

      let macAddress = await networkManager?.generateUniqueMACAddress() ?? VMNetwork.generateMACAddress()
      allocatedMACAddress = macAddress
      let definition = VMDefinition(
        id: vmId,
        name: name,
        state: .stopped,
        ephemeral: ephemeral,
        resources: resources,
        network: VMNetwork(macAddress: macAddress),
        paths: paths,
        metadata: ["createdFromImage": imagePath],
        installation: .completed(message: "Created from a complete VM image"),
        lifetimeSeconds: lifetimeSeconds
      )
      let instance = await MainActor.run { VMInstance(definition: definition, eventBus: eventBus) }

      try prepareVMCreationCommit(
        vmId,
        operation: .imageImport,
        definition: definition,
        markerPath: markerPath
      )
      vmRegistry[vmId] = instance
      #if DEBUG
      await vmCreationRegistryHookForTesting?(vmId)
      #endif
      try await persistenceStore.createVM(definition)
      allocatedMACAddress = nil
      #if DEBUG
      await vmCreationPublishedHookForTesting?(vmId)
      #endif
      recordVMCreationCommittedBestEffort(
        vmId,
        operation: .imageImport,
        definition: definition,
        markerPath: markerPath
      )
      finishVMCreation(vmId, markerPath: markerPath)

      eventBus.publish(.vmCreated(vmId: vmId, name: name))

      logInfo("VM \(name) created from image with ID: \(vmId)", category: "VMManager")
      return definition
    } catch let importError {
      vmRegistry.removeValue(forKey: vmId)
      if let allocatedMACAddress {
        await networkManager?.releaseMACAddress(allocatedMACAddress)
      }
      do {
        try rollbackVMCreation(vmId, bundlePath: paths.bundlePath, markerPath: markerPath)
      } catch let cleanupError {
        throw VMManagerError.operationFailed(
          "VM image import failed: \(importError.localizedDescription). "
            + "Cleanup of its pending creation also failed: \(cleanupError.localizedDescription)"
        )
      }
      throw importError
    }
  }

  private func copyVMBundle(from sourcePath: String, to destinationPath: String) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/cp")
    process.arguments = Self.bundleCopyArguments(from: sourcePath, to: destinationPath)
    process.standardInput = FileHandle.nullDevice
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
      let result = try await AsyncProcessRunner.run(
        process: process,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        options: AsyncProcessRunnerOptions(
          timeout: nil,
          timeoutDescription: "copy VM bundle to \(destinationPath)",
          maxOutputSize: 64 * 1024
        )
      )
      guard result.exitCode == 0 else {
        let output = String(data: result.stderr + result.stdout, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw VMManagerError.operationFailed(
          "VM bundle clone copy failed for \(sourcePath) (exit \(result.exitCode)): \(output)"
        )
      }
    } catch is CancellationError {
      try? FileManager.default.removeItem(atPath: destinationPath)
      throw CancellationError()
    } catch let error as AsyncProcessRunnerError {
      try? FileManager.default.removeItem(atPath: destinationPath)
      throw VMManagerError.operationFailed(
        "Failed to copy VM bundle from \(sourcePath) to \(destinationPath): \(error.localizedDescription)"
      )
    } catch {
      try? FileManager.default.removeItem(atPath: destinationPath)
      throw error
    }
  }

  nonisolated static func bundleCopyArguments(from sourcePath: String, to destinationPath: String) -> [String] {
    ["-c", "-R", sourcePath, destinationPath]
  }

  // MARK: - VM Cloning

  /// Creates a clone of an existing VM with a new name and identity
  func cloneVM(
    _ sourceVmId: UUID,
    name: String,
    cpuCount: Int? = nil,
    memorySize: UInt64? = nil,
    diskSize: UInt64? = nil,
    force: Bool = false,
    ephemeral: Bool = false,
    lifetimeSeconds: Int? = nil
  ) async throws -> VMDefinition {
    try claimVMOperation(sourceVmId, operation: "clone")
    defer { releaseVMOperation(sourceVmId, operation: "clone") }
    let sourceInstance = try getVMInstance(sourceVmId)
    try await validateManagedPaths(for: MainActor.run { sourceInstance.definition })

    if force {
      try await forceStopVMOwned(sourceVmId)
    }

    guard sourceInstance.currentState == .stopped else {
      throw VMManagerError.invalidState(
        "Source VM must be stopped before cloning (current: \(sourceInstance.currentState.rawValue), "
          + "use force=true to auto-stop)"
      )
    }

    let sourceDefinition = await MainActor.run { sourceInstance.definition }
    try validateCompleteVMBundle(at: sourceDefinition.paths.bundlePath)
    var cloneResources = sourceDefinition.resources
    if let cpuCount { cloneResources.cpuCount = cpuCount }
    if let memorySize { cloneResources.memorySize = memorySize }
    if let diskSize { cloneResources.diskSize = diskSize }

    guard cloneResources.validate() else {
      throw VMManagerError.invalidResources("Resources do not meet minimum requirements")
    }
    try validateResourcesForHost(cloneResources)
    guard cloneResources.diskSize >= sourceDefinition.resources.diskSize else {
      throw VMManagerError.invalidResources(
        "Clone disk cannot be smaller than source disk \(sourceDefinition.resources.diskSize) bytes"
      )
    }

    logInfo("Cloning VM \(sourceVmId) as '\(name)'", category: "VMManager")

    var initialResources = cloneResources
    initialResources.diskSize = sourceDefinition.resources.diskSize
    var clonedDefinition = try await createVMFromImage(
      name: name,
      imagePath: sourceDefinition.paths.bundlePath,
      ephemeral: ephemeral,
      lifetimeSeconds: lifetimeSeconds,
      resources: initialResources
    )

    if cloneResources.diskSize > sourceDefinition.resources.diskSize {
      do {
        clonedDefinition = try await updateVM(
          clonedDefinition.id,
          name: nil,
          cpuCount: cloneResources.cpuCount,
          memorySize: cloneResources.memorySize,
          diskSize: cloneResources.diskSize
        )
      } catch let resizeError {
        do {
          try await deleteVM(clonedDefinition.id, force: true)
        } catch let rollbackError {
          throw VMManagerError.operationFailed(
            "Clone resize failed: \(resizeError.localizedDescription). "
              + "Cleanup of clone \(clonedDefinition.id) also failed: \(rollbackError.localizedDescription)"
          )
        }
        throw resizeError
      }
    }

    eventBus.publish(.vmCloned(vmId: clonedDefinition.id, sourceVmId: sourceVmId, name: name))

    logInfo("VM \(sourceVmId) cloned as \(clonedDefinition.id)", category: "VMManager")
    return clonedDefinition
  }

  // MARK: - VM Updates

  /// Updates name, CPU, memory, and/or disk for a stopped or created VM.
  /// A created VM stores its future disk size; a stopped installed VM resizes its existing disk.
  func updateVM(
    _ vmId: UUID,
    name: String?,
    cpuCount: Int?,
    memorySize: UInt64?,
    diskSize: UInt64?
  ) async throws -> VMDefinition {
    try claimVMOperation(vmId, operation: "update")
    defer { releaseVMOperation(vmId, operation: "update") }
    let instance = try getVMInstance(vmId)
    try await validateManagedPaths(for: MainActor.run { instance.definition })

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
      if let diskSize { newResources.diskSize = diskSize }

      guard newResources.validate() else {
        throw VMManagerError.invalidResources("Resources do not meet minimum requirements")
      }
      try validateResourcesForHost(newResources)

      if let diskSize {
        guard diskSize >= definition.resources.diskSize else {
          throw VMManagerError.invalidResources(
            "Disk can only be enlarged, not shrunk (current: \(definition.resources.diskGB)GB)"
          )
        }

        if diskSize > definition.resources.diskSize, state == .stopped {
          let diskImagePath = definition.paths.diskImagePath
          guard FileManager.default.fileExists(atPath: diskImagePath) else {
            throw VMManagerError.operationFailed("Disk image not found at \(diskImagePath)")
          }
          _ = try await persistenceStore.updateVMConfiguration(
            vmId,
            metadataUpdates: [
              Self.diskResizeTargetMetadataKey: String(diskSize),
              Self.diskResizePhaseMetadataKey: "planned",
            ]
          )

          do {
            try await resizeDiskImage(at: diskImagePath, to: diskSize)
            _ = try await persistenceStore.updateVMConfiguration(
              vmId,
              metadataUpdates: [Self.diskResizePhaseMetadataKey: "applied"]
            )
          } catch let error as AsyncProcessRunnerError {
            let message = "Disk resize for VM \(vmId) did not finish; it will be reconciled on next launch: "
              + error.localizedDescription
            if case .timeout = error {
              throw VMManagerError.timeout(message)
            }
            throw VMManagerError.operationFailed(message)
          } catch {
            throw VMManagerError.operationFailed(
              "Disk resize for VM \(vmId) did not finish; it will be reconciled on next launch: "
                + error.localizedDescription
            )
          }
          logInfo(
            "Resized disk image for VM \(vmId): \(definition.resources.diskGB)GB -> "
              + "\(Double(diskSize) / (1024 * 1024 * 1024))GB",
            category: "VMManager"
          )
        }
      }

      definition.resources = newResources
      definition.metadata.removeValue(forKey: Self.diskResizeTargetMetadataKey)
      definition.metadata.removeValue(forKey: Self.diskResizePhaseMetadataKey)
    }

    definition.updatedAt = Date()

    let updatedDefinition = try await persistenceStore.updateVMConfiguration(
      vmId,
      name: name,
      resources: hasResourceChanges ? definition.resources : nil,
      metadataUpdates: hasResourceChanges ? [
        Self.diskResizeTargetMetadataKey: nil,
        Self.diskResizePhaseMetadataKey: nil,
      ] : [:]
    )
    let appliedResources = definition.resources
    await MainActor.run {
      if let name { instance.definition.name = name }
      if hasResourceChanges {
        instance.definition.resources = appliedResources
        instance.definition.metadata.removeValue(forKey: Self.diskResizeTargetMetadataKey)
        instance.definition.metadata.removeValue(forKey: Self.diskResizePhaseMetadataKey)
      }
      instance.definition.updatedAt = updatedDefinition.updatedAt
    }

    if hasResourceChanges {
      eventBus.publish(.vmResourcesUpdated(vmId: vmId))
    }

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
  private func resizeDiskImage(at path: String, to newSize: UInt64) async throws {
    if let diskImageResizer {
      try await diskImageResizer(path, newSize)
      return
    }

    let command = Self.diskImageResizeCommand(path: path, newSize: newSize)
    let process = Process()
    process.executableURL = command.executableURL
    process.arguments = command.arguments
    process.standardInput = FileHandle.nullDevice

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let result = try await AsyncProcessRunner.run(
      process: process,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe,
      options: AsyncProcessRunnerOptions(
        timeout: 600,
        timeoutDescription: "resize disk image for VM at \(path)",
        maxOutputSize: 1_048_576
      )
    )

    guard result.exitCode == 0 else {
      let output = String(data: result.stderr + result.stdout, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw VMManagerError.operationFailed(
        "Disk resize failed for \(path) (exit \(result.exitCode)): \(output)"
      )
    }
  }

  // MARK: - VM Lifecycle Operations

  /// Starts a VM.
  ///
  /// Enforces the product's 2-VM concurrent limit. Active count includes running, installing,
  /// paused, transitional VMs, and in-flight start/resume/install reservations.
  /// Throws `VMManagerError.concurrentVMLimitReached` if the limit is exceeded.
  func startVM(_ vmId: UUID) async throws {
    try claimVMOperation(vmId, operation: "start")
    defer { releaseVMOperation(vmId, operation: "start") }
    let instance = try getVMInstance(vmId)
    try ensureNoImageExportReservation(for: vmId, operation: "start")
    let initialState = instance.currentState
    guard initialState != .paused else {
      throw VMManagerError.invalidState("VM is paused; use the resume endpoint")
    }
    guard initialState == .created || initialState == .stopped || initialState == .running else {
      throw VMManagerError.invalidState("Cannot start VM from state \(initialState.rawValue)")
    }
    let reserved = try reserveCapacityIfNeeded(for: vmId, currentState: initialState, operation: "start")
    defer { if reserved { releaseCapacityReservation(for: vmId) } }
    #if DEBUG
    if let startCapacityClaimHookForTesting {
      await startCapacityClaimHookForTesting()
    }
    #endif
    await drainPublishedEvents()
    let definition = await MainActor.run { instance.definition }
    try validateManagedPaths(for: definition)
    try validateInstalledVMForStart(definition)

    logInfo("Starting VM \(vmId)", category: "VMManager")

    // Initialization belongs to the lifecycle transaction so corrupt bundles enter ERROR.
    if await MainActor.run(body: { instance.virtualMachine == nil }) {
      do {
        try await instance.initialize()
      } catch {
        await recordInitializationFailure(vmId, instance: instance, error: error)
        throw error
      }
    }

    do {
      try await instance.start()
    } catch {
      await persistCurrentStateAfterFailure(vmId, from: instance)
      throw error
    }
    try await persistSuccessfulRuntimeState(
      vmId,
      from: instance,
      operation: "start",
      resetRunningStart: initialState != .running,
      stateOverride: .running
    )
    await drainPublishedEvents()
    try await scheduleExpiryAfterRun(vmId)

    logInfo("VM \(vmId) started successfully", category: "VMManager")
  }

  /// Stops a VM
  @discardableResult
  func stopVM(_ vmId: UUID) async throws -> VMDefinition {
    try claimVMOperation(vmId, operation: "stop")
    defer { releaseVMOperation(vmId, operation: "stop") }
    let instance = try getVMInstance(vmId)
    try await validateManagedPaths(for: MainActor.run { instance.definition })
    let initialState = instance.currentState
    guard initialState == .running || initialState == .paused || initialState == .error
      || initialState == .stopped else
    {
      throw VMManagerError.invalidState("Cannot stop VM from state \(initialState.rawValue)")
    }

    if initialState == .error {
      try await recoverVMFromError(vmId, instance: instance)
      await drainPublishedEvents()
      await deleteIfEphemeral(vmId)
      return await MainActor.run { instance.definition }
    }

    if initialState == .stopped {
      await drainPublishedEvents()
      await deleteIfEphemeral(vmId)
      logInfo("VM \(vmId) is already stopped, returning existing state", category: "VMManager")
      return await MainActor.run { instance.definition }
    }

    logInfo("Stopping VM \(vmId)", category: "VMManager")

    do {
      try await instance.stop()
    } catch {
      if instance.currentState == .stopped {
        try await persistSuccessfulRuntimeState(vmId, from: instance, operation: "stop cleanup")
        await drainPublishedEvents()
      } else {
        await persistCurrentStateAfterFailure(vmId, from: instance)
      }
      throw error
    }
    try await persistSuccessfulRuntimeState(vmId, from: instance, operation: "stop")
    await drainPublishedEvents()

    logInfo("VM \(vmId) stopped successfully", category: "VMManager")
    return await MainActor.run { instance.definition }
  }

  private func recoverVMFromError(_ vmId: UUID, instance: VMInstance) async throws {
    try await validateManagedPaths(for: MainActor.run { instance.definition })
    let installerForRecovery = activeInstallers[vmId]
    try await releaseActiveInstallerFiles(vmId, context: "error recovery")
    cancelInstallerRecovery(vmId)

    if await MainActor.run(body: { instance.virtualMachine != nil }) {
      try await instance.forceStopRuntime()
    }
    await synchronizeRuntimeCapacityOwner(vmId, instance: instance)

    var definition = await MainActor.run { instance.definition }
    let hasInstallationSuccessMarker = try VMInstallationSuccessMarkerStore.readIfPresent(for: definition) != nil
    if hasInstallationSuccessMarker, definition.installation?.state == .failed {
      throw VMManagerError.invalidState(
        "VM \(vmId) has a terminal installation finalization failure; its bundle and success marker are preserved"
      )
    }
    if hasInstallationSuccessMarker || definition.installation?.state == .finalizing {
      cancelInstallerRecovery(vmId)
      let installer = installerForRecovery ?? VMInstaller(vmDefinition: definition, eventBus: eventBus)
      try await completeInstallationDuringRecovery(vmId: vmId, instance: instance, installer: installer)
      return
    }
    let installationIncomplete: Bool = if let installation = definition.installation {
      installation.state != .completed
    } else {
      (try? validateCompleteVMBundle(at: definition.paths.bundlePath)) == nil
    }
    let persisted: VMDefinition
    if installationIncomplete {
      try cleanupInterruptedInstallationArtifacts(for: definition)
      var installation = definition.installation
        ?? VMInstallation(state: .interrupted, message: "Installation recovery")
      installation.finish(as: .interrupted, message: "Installation reset for retry")
      definition.updateInstallation(installation)
      definition.updateState(.created)
      persisted = try await persistenceStore.updateVMInstallation(
        vmId,
        state: .created,
        installation: installation
      )
    } else {
      definition.updateState(.stopped)
      persisted = try await persistenceStore.updateVMLifecycle(
        vmId,
        state: .stopped,
        markBooted: definition.hasBooted
      )
    }

    try await MainActor.run {
      if instance.currentState != persisted.state {
        try instance.transitionLifecycle(to: persisted.state)
      }
      instance.cleanup()
      instance.definition = persisted
    }
    logInfo("Recovered VM \(vmId) to \(definition.state.rawValue)", category: "VMManager")
  }

  /// Pauses a VM
  func pauseVM(_ vmId: UUID) async throws {
    try claimVMOperation(vmId, operation: "pause")
    defer { releaseVMOperation(vmId, operation: "pause") }
    let instance = try getVMInstance(vmId)
    try await validateManagedPaths(for: MainActor.run { instance.definition })
    guard instance.currentState == .running else {
      throw VMManagerError.invalidState(
        "VM must be running before it can pause (current: \(instance.currentState.rawValue))"
      )
    }

    logInfo("Pausing VM \(vmId)", category: "VMManager")

    do {
      try await instance.pause()
    } catch {
      await persistCurrentStateAfterFailure(vmId, from: instance)
      throw error
    }
    try await persistSuccessfulRuntimeState(vmId, from: instance, operation: "pause")
    await drainPublishedEvents()

    logInfo("VM \(vmId) paused successfully", category: "VMManager")
  }

  /// Resumes a paused VM
  func resumeVM(_ vmId: UUID) async throws {
    try claimVMOperation(vmId, operation: "resume")
    defer { releaseVMOperation(vmId, operation: "resume") }
    let instance = try getVMInstance(vmId)
    let initialState = instance.currentState
    guard initialState == .paused else {
      throw VMManagerError.invalidState(
        "VM must be paused before it can resume (current: \(initialState.rawValue))"
      )
    }
    let reserved = try reserveCapacityIfNeeded(for: vmId, currentState: initialState, operation: "resume")
    defer { if reserved { releaseCapacityReservation(for: vmId) } }
    await drainPublishedEvents()
    try await validateManagedPaths(for: MainActor.run { instance.definition })

    logInfo("Resuming VM \(vmId)", category: "VMManager")

    // Initialize if not already initialized (needed after agent restart)
    let initializedRuntimeForRestore: Bool
    if await MainActor.run(body: { instance.virtualMachine == nil }) {
      do {
        try await instance.initialize()
        initializedRuntimeForRestore = true
      } catch {
        await recordInitializationFailure(vmId, instance: instance, error: error)
        throw error
      }
    } else {
      initializedRuntimeForRestore = false
    }

    // Check if we need to restore from save file (after agent restart)
    let saveFilePath = await MainActor.run { instance.definition.paths.saveFilePath }
    if initializedRuntimeForRestore,
       FileManager.default.fileExists(atPath: saveFilePath)
    {
      logInfo("Resuming VM \(vmId) from saved state file", category: "VMManager")
      do {
        try await instance.resumeFromSave()
      } catch {
        await persistCurrentStateAfterFailure(vmId, from: instance)
        throw error
      }
      try await persistSuccessfulRuntimeState(
        vmId,
        from: instance,
        operation: "resume from saved state",
        resetRunningStart: true,
        stateOverride: .running
      )
      await drainPublishedEvents()
      logInfo("VM \(vmId) resumed from save file successfully", category: "VMManager")
      return
    }

    // Normal resume (VM already in memory)
    do {
      try await instance.resume()
    } catch {
      await persistCurrentStateAfterFailure(vmId, from: instance)
      throw error
    }
    try await persistSuccessfulRuntimeState(
      vmId,
      from: instance,
      operation: "resume",
      resetRunningStart: true,
      stateOverride: .running
    )
    await drainPublishedEvents()

    logInfo("VM \(vmId) resumed successfully", category: "VMManager")
  }

  private func validateInstalledVMForStart(_ definition: VMDefinition) throws {
    if let installation = definition.installation {
      guard installation.state == .completed else {
        throw VMManagerError.invalidState("VM must finish installation before it can start")
      }
      try validateCompleteVMBundle(at: definition.paths.bundlePath)
      return
    }

    do {
      try validateCompleteVMBundle(at: definition.paths.bundlePath)
    } catch {
      throw VMManagerError.invalidState("VM must be installed before it can start")
    }
  }

  /// Saves a VM's state
  func saveVM(_ vmId: UUID) async throws {
    try claimVMOperation(vmId, operation: "save")
    defer { releaseVMOperation(vmId, operation: "save") }
    let instance = try getVMInstance(vmId)
    try await validateManagedPaths(for: MainActor.run { instance.definition })
    guard instance.currentState == .running else {
      throw VMManagerError.invalidState(
        "VM must be running before it can be saved (current: \(instance.currentState.rawValue))"
      )
    }

    logInfo("Saving VM \(vmId) state", category: "VMManager")

    do {
      try await instance.save()
    } catch {
      await persistCurrentStateAfterFailure(vmId, from: instance)
      throw error
    }
    try await persistSuccessfulRuntimeState(vmId, from: instance, operation: "save")
    await drainPublishedEvents()

    logInfo("VM \(vmId) state saved successfully", category: "VMManager")
  }

  private func savePausedVMForShutdown(_ vmId: UUID, instance: VMInstance) async throws {
    try claimVMOperation(vmId, operation: "shutdown save")
    defer { releaseVMOperation(vmId, operation: "shutdown save") }
    try await validateManagedPaths(for: MainActor.run { instance.definition })
    try await instance.savePausedRuntime()
    try await persistSuccessfulRuntimeState(vmId, from: instance, operation: "paused shutdown save")
    await drainPublishedEvents()
  }

  // MARK: - VM Installation

  /// Starts a tracked background installation and returns after durable state has been recorded.
  func startInstallation(_ vmId: UUID, ipswSource: String? = nil) async throws {
    let normalizedSource = try Self.normalizedIPSWSource(ipswSource)
    try claimVMOperation(vmId, operation: "install")
    guard installationTasks[vmId] == nil,
          installerRecoveryTasks[vmId] == nil,
          installationClaims.insert(vmId).inserted else
    {
      releaseVMOperation(vmId, operation: "install")
      throw VMManagerError.invalidState("Installation is already in progress for VM \(vmId)")
    }

    do {
      try await beginInstallation(vmId)
    } catch {
      installationClaims.remove(vmId)
      releaseVMOperation(vmId, operation: "install")
      throw error
    }

    let token = UUID()
    let task = Task<Void, Never> { [weak self] in
      guard let self else { return }
      do {
        try await runPreparedInstallation(vmId, ipswSource: normalizedSource)
        logInfo("Installation completed for VM \(vmId)", category: "VMManager")
      } catch is CancellationError {
        logInfo("Installation cancelled for VM \(vmId)", category: "VMManager")
      } catch {
        logError("Installation failed for VM \(vmId): \(error)", category: "VMManager")
      }
      await releaseInstallationTask(vmId, token: token)
    }
    installationTasks[vmId] = (token, task)
    installationClaims.remove(vmId)
  }

  func hasInstallationTask(_ vmId: UUID) -> Bool {
    installationClaims.contains(vmId) || installationTasks[vmId] != nil || installerRecoveryTasks[vmId] != nil
  }

  @discardableResult
  func cancelInstallation(_ vmId: UUID) async -> Bool {
    guard let tracked = installationTasks[vmId] else { return false }
    tracked.task.cancel()
    await tracked.task.value
    if installationTasks[vmId]?.token == tracked.token {
      installationTasks.removeValue(forKey: vmId)
    }
    releaseInstallOperationIfIdle(vmId)
    return true
  }

  @discardableResult
  func cancelAllInstallations() async -> Int {
    let tracked = installationTasks
    let recovery = installerRecoveryTasks
    installationTasks.removeAll()
    installerRecoveryTasks.removeAll()
    installationClaims.removeAll()
    for entry in tracked.values {
      entry.task.cancel()
    }
    for entry in recovery.values {
      entry.task.cancel()
    }
    for entry in tracked.values {
      await entry.task.value
    }
    for entry in recovery.values {
      await entry.task.value
    }
    let affectedVMs = Set(tracked.keys).union(Set(recovery.keys))
    for vmId in affectedVMs {
      releaseVMOperation(vmId, operation: "install")
    }
    return affectedVMs.count
  }

  private func releaseInstallationTask(_ vmId: UUID, token: UUID) {
    guard installationTasks[vmId]?.token == token else { return }
    installationTasks.removeValue(forKey: vmId)
    releaseInstallOperationIfIdle(vmId)
  }

  private func releaseInstallOperationIfIdle(_ vmId: UUID) {
    guard installationClaims.contains(vmId) == false,
          installationTasks[vmId] == nil,
          installerRecoveryTasks[vmId] == nil else { return }
    releaseVMOperation(vmId, operation: "install")
  }

  func installVM(_ vmId: UUID, ipswSource: String? = nil) async throws {
    let normalizedSource = try Self.normalizedIPSWSource(ipswSource)
    try claimVMOperation(vmId, operation: "install")
    defer {
      installationClaims.remove(vmId)
      releaseInstallOperationIfIdle(vmId)
    }
    guard installationTasks[vmId] == nil,
          installerRecoveryTasks[vmId] == nil,
          installationClaims.insert(vmId).inserted else
    {
      throw VMManagerError.invalidState("Installation is already in progress for VM \(vmId)")
    }

    let instance = try getVMInstance(vmId)
    guard instance.currentState == .created else {
      throw VMManagerError.invalidState(
        "VM must be in CREATED state for installation (current: \(instance.currentState.rawValue))"
      )
    }

    let reserved = try reserveCapacityIfNeeded(for: vmId, currentState: instance.currentState, operation: "install")
    defer { if reserved { releaseCapacityReservation(for: vmId) } }
    try await validateManagedPaths(for: MainActor.run { instance.definition })

    logInfo("Starting installation for VM \(vmId)", category: "VMManager")

    try await transitionToInstalling(vmId: vmId, instance: instance)

    try await runPreparedInstallation(vmId, ipswSource: normalizedSource)
  }

  /// Moves a VM into installing state before an async API route returns 202.
  func beginInstallation(_ vmId: UUID) async throws {
    let instance = try getVMInstance(vmId)
    guard instance.currentState == .created else {
      throw VMManagerError.invalidState(
        "VM must be in CREATED state for installation (current: \(instance.currentState.rawValue))"
      )
    }

    let reserved = try reserveCapacityIfNeeded(for: vmId, currentState: instance.currentState, operation: "install")
    defer { if reserved { releaseCapacityReservation(for: vmId) } }
    try await validateManagedPaths(for: MainActor.run { instance.definition })

    logInfo("Preparing installation for VM \(vmId)", category: "VMManager")

    try await transitionToInstalling(vmId: vmId, instance: instance)
  }

  func runPreparedInstallation(_ vmId: UUID, ipswSource: String? = nil) async throws {
    let normalizedSource = try Self.normalizedIPSWSource(ipswSource)
    let instance = try getVMInstance(vmId)

    guard instance.currentState == .installing else {
      throw VMManagerError.invalidState(
        "VM must be in INSTALLING state for prepared installation (current: \(instance.currentState.rawValue))"
      )
    }

    let definition = await MainActor.run { instance.definition }
    let installer = VMInstaller(vmDefinition: definition, eventBus: eventBus)
    activeInstallers[vmId] = installer

    do {
      try await runInstallation(installer: installer, ipswSource: normalizedSource)
      try await completeInstallation(vmId: vmId, instance: instance, installer: installer)
    } catch {
      await handleInstallationFailure(vmId: vmId, instance: instance, installer: installer, error: error)
      throw error
    }
  }

  private func transitionToInstalling(vmId: UUID, instance: VMInstance) async throws {
    let originalDefinition = await MainActor.run { instance.definition }
    try instance.stateMachine.transition(to: .installing)
    var updatedDefinition = originalDefinition
    updatedDefinition.updateState(.installing)
    let installation = VMInstallation(state: .installing, message: "Installation is starting")
    updatedDefinition.updateInstallation(installation)

    do {
      let persisted = try await persistenceStore.updateVMInstallation(
        vmId,
        state: updatedDefinition.state,
        installation: installation
      )
      let snapshot = persisted
      await MainActor.run { instance.definition = snapshot }
    } catch {
      instance.stateMachine.forceState(originalDefinition.state)
      throw error
    }
  }

  /// Runs the appropriate installation method based on the IPSW source
  private func runInstallation(installer: VMInstaller, ipswSource: String?) async throws {
    if let ipswSource {
      let scheme = URL(string: ipswSource)?.scheme?.lowercased()
      if scheme == "https" {
        try await installer.downloadAndInstallFromURL(ipswSource)
      } else if scheme == "http" {
        throw VMManagerError
          .operationFailed("HTTP URLs are not allowed for IPSW downloads due to MITM risk. Use HTTPS instead.")
      } else {
        try await installer.installFromIPSW(ipswPath: ipswSource)
      }
    } else {
      try await installer.downloadAndInstall()
    }
  }

  private nonisolated static func normalizedIPSWSource(_ source: String?) throws -> String? {
    do {
      return try IPSWSourceValidator.normalized(source)
    } catch {
      throw VMManagerError.invalidInstallationSource(error.localizedDescription)
    }
  }

  /// Cleans up after successful installation: detaches installer VM, sets state to STOPPED
  func completeInstallation(vmId: UUID, instance: VMInstance, installer: VMInstaller) async throws {
    var finalizingDefinition = await MainActor.run { instance.definition }
    let successMarker: VMInstallationSuccessMarker?
    do {
      successMarker = try VMInstallationSuccessMarkerStore.readIfPresent(for: finalizingDefinition)
    } catch {
      guard Self.isTransientInstallationEvidenceReadFailure(error) else {
        throw InstallationFinalizationFailure.unusableSuccessEvidence(error.localizedDescription)
      }
      throw error
    }
    guard successMarker != nil || finalizingDefinition.installation?.state == .finalizing else {
      throw InstallationFinalizationFailure.missingSuccessEvidence(vmId)
    }
    var installation = finalizingDefinition.installation
      ?? VMInstallation(state: .finalizing, message: "Finalizing installation")
    installation.state = .finalizing
    installation.message = "Waiting for the installer VM to stop"
    installation.updatedAt = Date()
    finalizingDefinition.updateInstallation(installation)
    let pendingFinalization = finalizingDefinition
    await MainActor.run { instance.definition = pendingFinalization }
    let persistedFinalization = try await persistenceStore.updateVMInstallation(
      vmId,
      state: finalizingDefinition.state,
      installation: installation
    )
    await MainActor.run { instance.definition = persistedFinalization }

    // After installation, VZMacOSInstaller auto-boots the VM transiently.
    // We detach and let it shut down on its own - calling stop() is unsafe here
    // due to a race with VZVirtualMachine's precondition check.
    logInfo("Post-installation cleanup for VM \(vmId)", category: "VMManager")

    if let vmState = await installer.virtualMachineState(detachDelegate: true) {
      logInfo("Post-install VM state: \(vmState.rawValue) (detached)", category: "VMManager")

      // The macOS installer auto-boots the VM transiently after installation.
      // Wait for that transient VM to fully stop before releasing, so callers
      // (e.g. Jeballtofile start step) can acquire the auxiliary storage lock.
      if vmState != .stopped, vmState != .error {
        logInfo("Waiting for transient installer VM to release auxiliary storage...", category: "VMManager")
        let didStop = await waitForInstallerFilesToBeReleased(installer)
        guard didStop else {
          throw VMManagerError.operationFailed(
            "Installer VM did not stop within 60 seconds; VM files remain protected until it stops"
          )
        }
      }
    }

    activeInstallers.removeValue(forKey: vmId)
    do {
      try validateCompleteVMBundle(at: finalizingDefinition.paths.bundlePath)
    } catch {
      throw InstallationFinalizationFailure.incompleteBundle(error.localizedDescription)
    }
    var completedDefinition = await MainActor.run { instance.definition }
    var completedInstallation = completedDefinition.installation
      ?? VMInstallation(state: .completed, message: "Installation completed")
    completedInstallation.finish(as: .completed, message: "Installation completed")
    completedDefinition.updateInstallation(completedInstallation)
    completedDefinition.updateState(.stopped)
    let completedSnapshot = completedDefinition
    instance.stateMachine.forceState(.stopped)
    await MainActor.run { instance.definition = completedSnapshot }
    do {
      let persisted = try await persistenceStore.updateVMInstallation(
        vmId,
        state: .stopped,
        installation: completedInstallation
      )
      await MainActor.run { instance.definition = persisted }
    } catch {
      instance.stateMachine.forceState(persistedFinalization.state)
      await MainActor.run { instance.definition = persistedFinalization }
      throw error
    }
    removeInstallationSuccessMarkerBestEffort(for: completedDefinition)
    eventBus.publish(.vmStopped(vmId: vmId))
    eventBus.publish(.installCompleted(vmId: vmId))

    logInfo("Installation completed - VM set to STOPPED (start explicitly to use)", category: "VMManager")
  }

  private nonisolated static func isTransientInstallationEvidenceReadFailure(_ error: Error) -> Bool {
    guard let markerError = error as? DurableMarkerStoreError else { return false }
    let code: Int32
    switch markerError {
    case .readOpenFailed(_, let readCode), .readFailed(_, let readCode):
      code = readCode
    default:
      return false
    }
    return code == EAGAIN || code == EBUSY || code == EINTR || code == EMFILE || code == ENFILE
      || code == ENOMEM || code == ETIMEDOUT
  }

  /// Once AVF has reported a successful install, finalization must finish even if the API task is cancelled.
  /// An unstructured child is deliberate here: it does not inherit the caller's cancellation flag, while all
  /// Virtualization access still hops through the installer's MainActor-isolated accessor.
  private func waitForInstallerFilesToBeReleased(_ installer: VMInstaller) async -> Bool {
    let waiter = Task<Bool, Never> {
      for _ in 0 ..< 120 {
        do {
          try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
          return false
        }
        let state = await installer.virtualMachineState()
        if state == .stopped || state == .error || state == nil {
          return true
        }
      }
      return false
    }
    return await waiter.value
  }

  private func releaseActiveInstallerFiles(_ vmId: UUID, context: String) async throws {
    guard let installer = activeInstallers[vmId] else { return }
    let installerState = await installer.virtualMachineState()
    if let installerState, installerState != .stopped, installerState != .error {
      let didStop = await waitForInstallerFilesToBeReleased(installer)
      guard didStop else {
        throw VMManagerError.operationFailed(
          "Installer VM did not stop during \(context); VM files are still in use"
        )
      }
    }
    activeInstallers.removeValue(forKey: vmId)
  }

  private func recordInstallationFinalizationFailure(
    vmId: UUID,
    instance: VMInstance,
    failure: InstallationFinalizationFailure
  ) async throws {
    let definition = await MainActor.run { instance.definition }
    var installation = definition.installation
      ?? VMInstallation(state: .finalizing, message: "Finalizing installation")
    installation.finish(
      as: .failed,
      message: "Installation finalization failed",
      error: failure.localizedDescription
    )
    let persisted = try await persistenceStore.updateVMInstallation(
      vmId,
      state: .error,
      installation: installation
    )
    instance.stateMachine.forceState(.error)
    await MainActor.run { instance.definition = persisted }
    await synchronizeRuntimeCapacityOwner(vmId, instance: instance)
    eventBus.publish(.installFailed(vmId: vmId, error: failure.localizedDescription))
    logError(
      "Installation finalization failed permanently for VM \(vmId): \(failure.localizedDescription)",
      category: "VMManager"
    )
  }

  private func completeInstallationDuringRecovery(
    vmId: UUID,
    instance: VMInstance,
    installer: VMInstaller
  ) async throws {
    do {
      try await completeInstallation(vmId: vmId, instance: instance, installer: installer)
    } catch let failure as InstallationFinalizationFailure {
      try await recordInstallationFinalizationFailure(vmId: vmId, instance: instance, failure: failure)
      throw failure
    }
  }

  private func handlePermanentInstallationFinalizationFailure(
    vmId: UUID,
    instance: VMInstance,
    installer: VMInstaller,
    failure: InstallationFinalizationFailure,
    protectsFiles: Bool
  ) async {
    do {
      try await recordInstallationFinalizationFailure(
        vmId: vmId,
        instance: instance,
        failure: failure
      )
      if protectsFiles {
        scheduleInstallerRecovery(vmId: vmId, installer: installer, mode: .releaseAfterFailure)
      }
    } catch {
      logError(
        "Failed to persist installation finalization failure for VM \(vmId); retrying durable state update: "
          + error.localizedDescription,
        category: "VMManager"
      )
      scheduleInstallerRecovery(
        vmId: vmId,
        installer: installer,
        mode: .recordFinalizationFailure(failure)
      )
    }
  }

  private func installationSucceededDespiteReportedFailure(
    vmId: UUID,
    definition: VMDefinition,
    installation: VMInstallation,
    error: Error
  ) -> Bool {
    let markerReadFailed: Bool
    let hasSuccessMarker: Bool
    do {
      hasSuccessMarker = try VMInstallationSuccessMarkerStore.readIfPresent(for: definition) != nil
      markerReadFailed = false
    } catch let markerError {
      hasSuccessMarker = false
      markerReadFailed = true
      logError(
        "Failed to inspect durable installation success marker for VM \(vmId); preserving its bundle: "
          + markerError.localizedDescription,
        category: "VMManager"
      )
    }
    let markerWriteReportedSuccess = if let installerError = error as? VMInstallerError,
                                        case .installationSuccessMarkerFailed = installerError
    {
      true
    } else {
      false
    }
    return installation.state == .finalizing || hasSuccessMarker || markerReadFailed || markerWriteReportedSuccess
  }

  private func deferSuccessfulInstallationFinalization(
    vmId: UUID,
    instance: VMInstance,
    installer: VMInstaller,
    context: PendingInstallationFinalizationContext
  ) async {
    var definition = context.definition
    var installation = context.installation
    installation.state = .finalizing
    installation.message = "Installation succeeded, but finalization is pending"
    installation.error = context.errorDescription
    installation.updatedAt = Date()
    definition.updateInstallation(installation)
    definition.updateState(.installing)
    instance.stateMachine.forceState(.installing)
    do {
      let snapshot = try await persistenceStore.updateVMInstallation(
        vmId,
        state: .installing,
        installation: installation
      )
      await MainActor.run { instance.definition = snapshot }
    } catch {
      logError("Failed to persist pending finalization for VM \(vmId): \(error)", category: "VMManager")
    }
    logError("Installation finalization is pending for VM \(vmId): \(context.errorLogValue)", category: "VMManager")
    scheduleInstallerRecovery(vmId: vmId, installer: installer, mode: .finalizeSuccess)
  }

  private func finishFailedOrCancelledInstallation(
    vmId: UUID,
    instance: VMInstance,
    installer: VMInstaller,
    context: InstallationFailureHandlingContext
  ) async {
    var definition = context.definition
    var installation = context.installation
    if context.wasCancelled, context.protectsFiles == false {
      do {
        try cleanupInterruptedInstallationArtifacts(for: definition)
        installation.finish(as: .cancelled, message: "Installation cancelled")
        definition.updateInstallation(installation)
        definition.updateState(.created)
        instance.stateMachine.forceState(.created)
      } catch {
        installation.finish(as: .failed, message: "Installation cleanup failed", error: error.localizedDescription)
        definition.updateInstallation(installation)
        definition.updateState(.error)
        instance.stateMachine.forceState(.error)
      }
    } else {
      installation.finish(as: .failed, message: "Installation failed", error: context.errorDescription)
      definition.updateInstallation(installation)
      definition.updateState(.error)
      instance.stateMachine.forceState(.error)
    }

    do {
      let snapshot = try await persistenceStore.updateVMInstallation(
        vmId,
        state: definition.state,
        installation: installation
      )
      await MainActor.run { instance.definition = snapshot }
    } catch {
      logError("Failed to persist installation failure for VM \(vmId): \(error)", category: "VMManager")
    }

    if context.wasCancelled, context.protectsFiles {
      logInfo(
        "Installation cancellation for VM \(vmId) is waiting for its installer runtime to release files",
        category: "VMManager"
      )
      scheduleInstallerRecovery(vmId: vmId, installer: installer, mode: .cleanupCancellation)
    } else if installation.state == .cancelled {
      eventBus.publish(.installCancelled(vmId: vmId))
      logInfo("Installation cancelled for VM \(vmId)", category: "VMManager")
    } else {
      eventBus.publish(.installFailed(vmId: vmId, error: context.errorDescription))
      logError("Installation failed for VM \(vmId): \(context.errorLogValue)", category: "VMManager")
      if context.protectsFiles {
        scheduleInstallerRecovery(vmId: vmId, installer: installer, mode: .releaseAfterFailure)
      }
    }
  }

  private func trackInstallerFileProtection(vmId: UUID, installer: VMInstaller) async -> Bool {
    let installerState = await installer.virtualMachineState()
    let protectsFiles = installerState != nil && installerState != .stopped && installerState != .error
    if protectsFiles {
      activeInstallers[vmId] = installer
    } else {
      activeInstallers.removeValue(forKey: vmId)
    }
    return protectsFiles
  }

  /// Handles installation failure: transitions to error state and publishes failure event
  func handleInstallationFailure(
    vmId: UUID,
    instance: VMInstance,
    installer: VMInstaller,
    error: Error
  ) async {
    let protectsFiles = await trackInstallerFileProtection(vmId: vmId, installer: installer)

    let definition = await MainActor.run { instance.definition }
    let installation = definition.installation
      ?? VMInstallation(state: .failed, message: "Installation failed")

    if let finalizationFailure = error as? InstallationFinalizationFailure {
      await handlePermanentInstallationFinalizationFailure(
        vmId: vmId,
        instance: instance,
        installer: installer,
        failure: finalizationFailure,
        protectsFiles: protectsFiles
      )
      return
    }

    let wasCancelled = error is CancellationError || Task.isCancelled
    let installationSucceeded = installationSucceededDespiteReportedFailure(
      vmId: vmId,
      definition: definition,
      installation: installation,
      error: error
    )

    if installationSucceeded {
      await deferSuccessfulInstallationFinalization(
        vmId: vmId,
        instance: instance,
        installer: installer,
        context: PendingInstallationFinalizationContext(
          definition: definition,
          installation: installation,
          errorDescription: error.localizedDescription,
          errorLogValue: String(describing: error)
        )
      )
      return
    }

    await finishFailedOrCancelledInstallation(
      vmId: vmId,
      instance: instance,
      installer: installer,
      context: InstallationFailureHandlingContext(
        definition: definition,
        installation: installation,
        errorDescription: error.localizedDescription,
        errorLogValue: String(describing: error),
        protectsFiles: protectsFiles,
        wasCancelled: wasCancelled
      )
    )
  }

  private func scheduleInstallerRecovery(
    vmId: UUID,
    installer: VMInstaller,
    mode: InstallerRecoveryMode
  ) {
    guard installerRecoveryTasks[vmId] == nil else { return }
    let token = UUID()
    let pollNanoseconds = installerRecoveryPollNanoseconds
    let task = Task<Void, Never> { [weak self] in
      while Task.isCancelled == false {
        let state = await installer.virtualMachineState()
        if state == nil || state == .stopped || state == .error {
          guard let self else { return }
          if await attemptInstallerRecovery(
            vmId: vmId,
            installer: installer,
            mode: mode,
            token: token
          ) {
            return
          }
        }

        do {
          try await Task.sleep(nanoseconds: pollNanoseconds)
        } catch {
          return
        }
      }
    }
    installerRecoveryTasks[vmId] = InstallerRecoveryTaskHandle(token: token, task: task)
  }

  private func attemptInstallerRecovery(
    vmId: UUID,
    installer: VMInstaller,
    mode: InstallerRecoveryMode,
    token: UUID
  ) async -> Bool {
    guard installerRecoveryTasks[vmId]?.token == token else { return true }
    activeInstallers.removeValue(forKey: vmId)

    switch mode {
    case .finalizeSuccess:
      guard let instance = vmRegistry[vmId] else {
        finishInstallerRecovery(vmId: vmId, token: token)
        return true
      }
      do {
        try await completeInstallation(vmId: vmId, instance: instance, installer: installer)
        finishInstallerRecovery(vmId: vmId, token: token)
        return true
      } catch let failure as InstallationFinalizationFailure {
        do {
          try await recordInstallationFinalizationFailure(
            vmId: vmId,
            instance: instance,
            failure: failure
          )
          finishInstallerRecovery(vmId: vmId, token: token)
          return true
        } catch {
          logError(
            "Retrying durable finalization failure state for VM \(vmId) after error: "
              + error.localizedDescription,
            category: "VMManager"
          )
          return false
        }
      } catch {
        logError(
          "Retrying installation finalization for VM \(vmId) after error: \(error.localizedDescription)",
          category: "VMManager"
        )
        return false
      }

    case .recordFinalizationFailure(let failure):
      guard let instance = vmRegistry[vmId] else {
        finishInstallerRecovery(vmId: vmId, token: token)
        return true
      }
      do {
        try await recordInstallationFinalizationFailure(
          vmId: vmId,
          instance: instance,
          failure: failure
        )
        finishInstallerRecovery(vmId: vmId, token: token)
        return true
      } catch {
        logError(
          "Retrying durable finalization failure state for VM \(vmId) after error: \(error.localizedDescription)",
          category: "VMManager"
        )
        return false
      }

    case .cleanupCancellation:
      guard let instance = vmRegistry[vmId] else {
        finishInstallerRecovery(vmId: vmId, token: token)
        return true
      }
      do {
        var definition = await MainActor.run { instance.definition }
        try cleanupInterruptedInstallationArtifacts(for: definition)
        var installation = definition.installation
          ?? VMInstallation(state: .installing, message: "Installation cancellation pending")
        installation.finish(as: .cancelled, message: "Installation cancelled")
        definition.updateInstallation(installation)
        definition.updateState(.created)
        let persisted = try await persistenceStore.updateVMInstallation(
          vmId,
          state: .created,
          installation: installation
        )
        instance.stateMachine.forceState(.created)
        await MainActor.run { instance.definition = persisted }
        eventBus.publish(.installCancelled(vmId: vmId))
        finishInstallerRecovery(vmId: vmId, token: token)
        return true
      } catch {
        logError(
          "Retrying cancelled installation cleanup for VM \(vmId) after error: \(error.localizedDescription)",
          category: "VMManager"
        )
        return false
      }

    case .releaseAfterFailure:
      finishInstallerRecovery(vmId: vmId, token: token)
      return true
    }
  }

  private func finishInstallerRecovery(vmId: UUID, token: UUID) {
    guard installerRecoveryTasks[vmId]?.token == token else { return }
    installerRecoveryTasks.removeValue(forKey: vmId)
    releaseInstallOperationIfIdle(vmId)
  }

  private func cancelInstallerRecovery(_ vmId: UUID) {
    installerRecoveryTasks.removeValue(forKey: vmId)?.task.cancel()
    releaseInstallOperationIfIdle(vmId)
  }

  /// Gets the installation status for a VM
  func getInstallationStatus(
    _ vmId: UUID
  ) async throws -> (state: VMState, installation: VMInstallation?, installProgress: InstallProgress?) {
    let instance = try getVMInstance(vmId)
    let progressInfo = installationProgress[vmId]
    let installation = await MainActor.run { instance.definition.installation }
    return (instance.currentState, installation, progressInfo)
  }

  // MARK: - Network Setup

  /// Waits for any pending networking setup task for a VM to complete.
  /// Call before enabling SSH/VNC to avoid race conditions with auto-enable.
  func awaitNetworkingSetup(_ vmId: UUID) async throws {
    try await networkingTasks[vmId]?.completion.wait()
  }

  /// Cancels pending automatic networking and waits until it can no longer mutate VM network state.
  func cancelNetworkingSetup(_ vmId: UUID) async {
    await cancelNetworkingTasks(for: vmId)
  }

  private func awaitNetworkingSetup(_ vmId: UUID, deadline: TimeInterval) async throws {
    try await networkingTasks[vmId]?.completion.wait(until: deadline)
  }

  /// Resolves NAT IP and sets up SSH forwarding after a VM becomes running
  private func setupNetworkingForVM(_ vmId: UUID, generation: UUID) async {
    guard networkingSetupIsCurrent(vmId, generation: generation) else { return }
    guard let ip = await ensureNATIP(vmId, logFailure: false, requiredGeneration: generation) else {
      guard !Task.isCancelled else { return }
      logInfo(
        "NAT IP not yet available for VM \(vmId); SSH/VNC forwarding can be enabled once IP appears",
        category: "VMManager"
      )
      return
    }
    guard networkingSetupIsCurrent(vmId, generation: generation) else { return }

    let definition: VMDefinition
    do {
      definition = try await persistenceStore.getVM(vmId)
    } catch {
      logError("Failed to load VM \(vmId) for network setup: \(error)", category: "VMManager")
      return
    }
    guard networkingSetupIsCurrent(vmId, generation: generation) else { return }

    if config.networking.autoEnableSSHForwarding, definition.network.sshPort == nil, let portForwardingManager {
      do {
        if let sshPort = try await portForwardingManager.allocateAndSetupSSHForwarding(
          vmId: vmId,
          vmIPAddress: ip
        ) {
          guard networkingSetupIsCurrent(vmId, generation: generation) else {
            await portForwardingManager.stopSSHForwarding(vmId: vmId)
            return
          }
          do {
            try await persistNetworkField(vmId, update: .sshPort(sshPort))
          } catch {
            await portForwardingManager.stopSSHForwarding(vmId: vmId)
            throw error
          }
          guard networkingSetupIsCurrent(vmId, generation: generation) else {
            await portForwardingManager.stopSSHForwarding(vmId: vmId)
            try? await persistNetworkField(vmId, update: .sshPort(nil))
            return
          }
          logInfo("Auto-enabled SSH forwarding for VM \(vmId) on port \(sshPort)", category: "VMManager")
          startSSHReadinessProbe(vmId: vmId, sshPort: sshPort)
        }
      } catch {
        logError("Failed to setup SSH forwarding for VM \(vmId): \(error)", category: "VMManager")
      }
    }
  }

  private func networkingSetupIsCurrent(_ vmId: UUID, generation: UUID) -> Bool {
    guard Task.isCancelled == false,
          networkingGenerations[vmId] == generation,
          let instance = vmRegistry[vmId] else { return false }
    return instance.currentState == .running
  }

  /// Probes localhost:sshPort in the background until the SSH daemon responds with its banner,
  /// then publishes sshReady. Stops on task cancellation or if already published for this boot.
  func startSSHReadinessProbe(vmId: UUID, sshPort: Int) {
    sshReadyVMs.remove(vmId)
    sshProbingTasks[vmId]?.cancel()
    let generation = UUID()
    sshProbeGenerations[vmId] = generation
    sshProbingTasks[vmId] = Task<Void, Never> {
      await self.probeSSHReadiness(vmId: vmId, sshPort: sshPort, generation: generation)
    }
  }

  func cancelSSHReadinessProbe(vmId: UUID) {
    sshProbeGenerations.removeValue(forKey: vmId)
    sshProbingTasks.removeValue(forKey: vmId)?.cancel()
    sshReadyVMs.remove(vmId)
  }

  private func probeSSHReadiness(vmId: UUID, sshPort: Int, generation: UUID) async {
    defer {
      if sshProbeGenerations[vmId] == generation {
        sshProbeGenerations.removeValue(forKey: vmId)
        sshProbingTasks.removeValue(forKey: vmId)
      }
    }
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
    guard let rawPort = UInt16(exactly: port),
          let nwPort = NWEndpoint.Port(rawValue: rawPort) else { return false }
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
    await portForwardingManager?.stopSSHForwarding(vmId: vmId)
    await portForwardingManager?.stopVNCForwarding(vmId: vmId)

    let definition: VMDefinition
    do {
      definition = try await persistenceStore.getVM(vmId)
    } catch {
      logError(
        "Failed to load VM \(vmId) while clearing persisted network state: \(error.localizedDescription)",
        category: "VMManager"
      )
      return
    }

    if let sshPort = definition.network.sshPort {
      await portForwardingManager?.releasePort(sshPort)
      do {
        try await persistNetworkField(vmId, update: .sshPort(nil))
      } catch {
        logError("Failed to clear SSH port for VM \(vmId): \(error)", category: "VMManager")
      }
    }
    if let vncPort = definition.network.vncPort {
      await portForwardingManager?.releaseVNCPort(vncPort)
      do {
        try await persistNetworkField(vmId, update: .vncPort(nil))
      } catch {
        logError("Failed to clear VNC port for VM \(vmId): \(error)", category: "VMManager")
      }
    }
    do {
      try await persistNetworkField(vmId, update: .natIP(nil))
    } catch {
      logError("Failed to clear NAT IP for VM \(vmId): \(error)", category: "VMManager")
    }
  }

  /// Resolves and persists NAT IP for a VM if currently unknown.
  /// Returns the known/resolved IP or nil if resolution failed.
  func ensureNATIP(
    _ vmId: UUID,
    maxAttempts: Int = VMManager.natResolveMaxAttempts,
    logFailure: Bool = true,
    requiredGeneration: UUID? = nil
  ) async -> String? {
    guard let networkManager else { return nil }
    if let requiredGeneration, networkingSetupIsCurrent(vmId, generation: requiredGeneration) == false {
      return nil
    }

    let definition: VMDefinition
    do {
      definition = try await persistenceStore.getVM(vmId)
    } catch {
      logError("Failed to load VM \(vmId) for NAT resolution: \(error)", category: "VMManager")
      return nil
    }
    if let requiredGeneration, networkingSetupIsCurrent(vmId, generation: requiredGeneration) == false {
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
    if let requiredGeneration, networkingSetupIsCurrent(vmId, generation: requiredGeneration) == false {
      return nil
    }

    do {
      try await persistNetworkField(vmId, update: .natIP(resolved))
    } catch {
      logError("Failed to persist NAT IP for VM \(vmId): \(error)", category: "VMManager")
      return nil
    }

    if let requiredGeneration, networkingSetupIsCurrent(vmId, generation: requiredGeneration) == false {
      try? await persistNetworkField(vmId, update: .natIP(nil))
      return nil
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
    guard timeout.isFinite, timeout > 0 else {
      throw CommandExecutorError.invalidTimeout(timeout)
    }

    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    if retryOnSSHFailure {
      do {
        try await awaitNetworkingSetup(vmId, deadline: deadline)
      } catch NetworkingSetupWaitError.timedOut {
        throw CommandExecutorError.timeout(command: command, seconds: timeout)
      }
    }
    try Task.checkCancellation()

    let instance = try getVMInstance(vmId)
    guard instance.currentState == .running else {
      throw VMManagerError.invalidState(
        "VM must be RUNNING for command execution (current: \(instance.currentState.rawValue))"
      )
    }

    guard let sshPort = await MainActor.run(body: { instance.definition.network.sshPort }) else {
      throw CommandExecutorError.sshNotConfigured("VM \(vmId) has no assigned SSH port")
    }

    let executionTimeout = retryOnSSHFailure
      ? deadline - ProcessInfo.processInfo.systemUptime
      : timeout
    guard executionTimeout > 0 else {
      throw CommandExecutorError.timeout(command: command, seconds: timeout)
    }

    let executor = CommandExecutor()
    do {
      return try await executor.execute(
        command: command,
        sshPort: sshPort,
        user: user,
        password: password,
        timeout: executionTimeout,
        retryOnSSHFailure: retryOnSSHFailure
      )
    } catch CommandExecutorError.timeout(let timedOutCommand, _) {
      throw CommandExecutorError.timeout(command: timedOutCommand, seconds: timeout)
    }
  }

  func executeKeystrokes(_ vmId: UUID, keystrokes: [String]) async throws -> Int {
    try await withExclusiveDisplayOperation(vmId) {
      try await self.executeKeystrokesExclusively(vmId, keystrokes: keystrokes)
    }
  }

  private func executeKeystrokesExclusively(_ vmId: UUID, keystrokes: [String]) async throws -> Int {
    let instance = try getVMInstance(vmId)
    guard instance.currentState == .running || instance.currentState == .installing else {
      throw VMManagerError.invalidState(
        "VM must be RUNNING or INSTALLING for keystrokes (current: \(instance.currentState.rawValue))"
      )
    }

    guard let guiManager else {
      throw VMManagerError.operationFailed("GUI manager not available")
    }

    let allActions = try Self.parseKeystrokeSequences(keystrokes)

    let injector = KeystrokeInjector()
    let installer = instance.currentState == .installing ? activeInstallers[vmId] : nil
    return try await Self.injectKeystrokes(
      actions: allActions,
      vmId: vmId,
      instance: instance,
      installer: installer,
      injector: injector,
      guiManager: guiManager
    )
  }

  static func parseKeystrokeSequences(_ sequences: [String]) throws -> [KeystrokeAction] {
    var allActions: [KeystrokeAction] = []
    for sequence in sequences {
      let actions = try KeystrokeParser.parse(sequence)
      let total = allActions.count + actions.count
      guard total <= KeystrokeParser.maxActions else {
        throw KeystrokeParserError.tooManyActions(total)
      }
      allActions.append(contentsOf: actions)
    }
    return allActions
  }

  // MARK: - GUI Operations

  func openGUI(_ vmId: UUID) async throws {
    try await withExclusiveDisplayOperation(vmId) {
      try await self.openGUIExclusively(vmId)
    }
  }

  private func openGUIExclusively(_ vmId: UUID) async throws {
    let instance = try getVMInstance(vmId)

    guard instance.currentState == .running else {
      throw VMManagerError.invalidState(
        "VM must be RUNNING to open GUI (current: \(instance.currentState.rawValue))"
      )
    }

    guard let guiManager else {
      throw VMManagerError.operationFailed("GUI manager not available")
    }

    try await MainActor.run {
      guard let vm = instance.virtualMachine else {
        throw VMManagerError.operationFailed("VM has no VZVirtualMachine instance")
      }
      guiManager.openGUI(vmId: vmId, virtualMachine: vm, vmName: instance.definition.name)
    }
  }

  func closeGUI(_ vmId: UUID) async throws {
    try await withExclusiveDisplayOperation(vmId) {
      try await self.closeGUIExclusively(vmId)
    }
  }

  private func closeGUIExclusively(_ vmId: UUID) async throws {
    _ = try getVMInstance(vmId)

    guard let guiManager else {
      throw VMManagerError.operationFailed("GUI manager not available")
    }

    await guiManager.closeGUI(vmId: vmId)
  }

  private func withExclusiveDisplayOperation<T: Sendable>(
    _ vmId: UUID,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await displayOperationGate.withExclusiveAccess(for: vmId.uuidString, operation: operation)
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

    guard let guiManager else {
      throw VMManagerError.operationFailed("GUI manager not available")
    }

    do {
      return try await MainActor.run {
        guard let vm = instance.virtualMachine else {
          throw VMManagerError.operationFailed("VM has no VZVirtualMachine instance")
        }
        return try guiManager.captureScreenshot(vmId: vmId, virtualMachine: vm)
      }
    } catch {
      throw VMManagerError.operationFailed("Screenshot capture failed: \(error.localizedDescription)")
    }
  }

  @MainActor
  private static func injectKeystrokes(
    actions: [KeystrokeAction],
    vmId: UUID,
    instance: VMInstance,
    installer: VMInstaller?,
    injector: KeystrokeInjector,
    guiManager: GUIManager
  ) async throws -> Int {
    let vm: VZVirtualMachine? = if instance.currentState == .installing {
      installer?.virtualMachine
    } else {
      instance.virtualMachine
    }
    guard let vm else {
      throw VMManagerError.operationFailed("VM instance is not available for keystrokes")
    }
    return try await injector.execute(actions: actions, vm: vm, vmId: vmId, guiManager: guiManager)
  }

  // MARK: - VM Deletion

  /// Force-stops a VM regardless of its current state.
  /// State becomes stopped only after the Virtualization runtime confirms it no longer owns VM files.
  func forceStopVM(_ vmId: UUID) async throws {
    try claimVMOperation(vmId, operation: "force-stop")
    defer { releaseVMOperation(vmId, operation: "force-stop") }
    try await forceStopVMOwned(vmId)
  }

  private func forceStopVMOwned(
    _ vmId: UUID,
    allowTerminalInstallationFailure: Bool = false
  ) async throws {
    let instance = try getVMInstance(vmId)
    try await validateManagedPaths(for: MainActor.run { instance.definition })

    switch instance.currentState {
    case .running, .paused, .starting, .stopping, .pausing, .resuming:
      do {
        try await instance.forceStopRuntime()
      } catch {
        if instance.currentState == .stopped {
          try await persistSuccessfulRuntimeState(vmId, from: instance, operation: "forced stop cleanup")
        } else {
          await persistCurrentStateAfterFailure(vmId, from: instance)
        }
        throw error
      }
      try await persistSuccessfulRuntimeState(vmId, from: instance, operation: "forced stop")
    case .installing:
      let installerForRecovery = activeInstallers[vmId]
      if await cancelInstallation(vmId) {
        logInfo("Cancelled tracked installation for VM \(vmId)", category: "VMManager")
      }

      try await releaseActiveInstallerFiles(vmId, context: "installation cancellation")

      if instance.currentState == .error,
         allowTerminalInstallationFailure,
         await isTerminalInstallationFailure(instance)
      {
        await synchronizeRuntimeCapacityOwner(vmId, instance: instance)
      } else if instance.currentState == .error {
        try await recoverVMFromError(vmId, instance: instance)
      } else if instance.currentState == .installing {
        var definition = await MainActor.run { instance.definition }
        let hasSuccessMarker = try VMInstallationSuccessMarkerStore.readIfPresent(for: definition) != nil
        if hasSuccessMarker || definition.installation?.state == .finalizing {
          cancelInstallerRecovery(vmId)
          let installer = installerForRecovery ?? VMInstaller(vmDefinition: definition, eventBus: eventBus)
          do {
            try await completeInstallationDuringRecovery(vmId: vmId, instance: instance, installer: installer)
          } catch let failure as InstallationFinalizationFailure {
            guard allowTerminalInstallationFailure else { throw failure }
            await synchronizeRuntimeCapacityOwner(vmId, instance: instance)
          }
        } else {
          try cleanupInterruptedInstallationArtifacts(for: definition)
          var installation = definition.installation
            ?? VMInstallation(state: .interrupted, message: "Installation interrupted")
          installation.finish(as: .interrupted, message: "Installation interrupted before deletion")
          definition.updateInstallation(installation)
          definition.updateState(.created)
          instance.stateMachine.forceState(.created)
          let snapshot = try await persistenceStore.updateVMInstallation(
            vmId,
            state: .created,
            installation: installation
          )
          await MainActor.run { instance.definition = snapshot }
        }
      }
    case .error:
      if allowTerminalInstallationFailure, await isTerminalInstallationFailure(instance) {
        if await cancelInstallation(vmId) {
          logInfo("Cancelled tracked installation for terminally failed VM \(vmId)", category: "VMManager")
        }
        try await releaseActiveInstallerFiles(vmId, context: "terminal installation deletion")
        cancelInstallerRecovery(vmId)
      }
      do {
        try await instance.forceStopRuntime()
      } catch {
        await persistCurrentStateAfterFailure(vmId, from: instance)
        throw error
      }
      if instance.currentState == .error {
        if allowTerminalInstallationFailure, await isTerminalInstallationFailure(instance) {
          await synchronizeRuntimeCapacityOwner(vmId, instance: instance)
        } else {
          try await recoverVMFromError(vmId, instance: instance)
        }
      } else if instance.currentState == .stopped {
        try await persistSuccessfulRuntimeState(vmId, from: instance, operation: "forced error recovery stop")
      }
    default:
      break // already stopped, created, or deleted
    }
  }

  private func isTerminalInstallationFailure(_ instance: VMInstance) async -> Bool {
    await MainActor.run { instance.definition.installation?.state == .failed }
  }

  /// Deletes a VM and its associated files.
  /// - Parameters:
  ///   - vmId: UUID of the VM to delete
  ///   - force: If true, force-stops the VM before deletion even if running
  func deleteVM(
    _ vmId: UUID,
    force: Bool = false,
    owningEphemeralDeletionToken: UUID? = nil
  ) async throws {
    logInfo("Deleting VM \(vmId) (force: \(force))", category: "VMManager")

    if let operation = vmOperations[vmId] {
      guard force, operation == "install" else {
        throw VMManagerError.invalidState("Cannot delete VM while \(operation) is in progress")
      }
      guard installationClaims.contains(vmId) == false else {
        throw VMManagerError.invalidState(
          "Cannot delete VM while installation startup is being committed; retry after the install request returns"
        )
      }
      try await forceStopVMOwned(vmId, allowTerminalInstallationFailure: true)
    }
    try claimVMOperation(vmId, operation: "delete")
    defer { releaseVMOperation(vmId, operation: "delete") }

    let instance = try getVMInstance(vmId)
    try await validateManagedPaths(for: MainActor.run { instance.definition })
    try ensureNoImageExportReservation(for: vmId, operation: "delete")

    if force || instance.currentState == .error {
      if let guiManager, await guiManager.isGUIOpen(vmId: vmId) {
        await guiManager.closeGUI(vmId: vmId)
      }
      try await forceStopVMOwned(vmId, allowTerminalInstallationFailure: true)
    }
    if let installer = activeInstallers[vmId] {
      let installerState = await installer.virtualMachineState()
      if let installerState, installerState != .stopped, installerState != .error {
        throw VMManagerError.invalidState(
          "Cannot delete VM while the Virtualization installer is \(installerState.rawValue)"
        )
      }
      activeInstallers.removeValue(forKey: vmId)
    }
    await drainPublishedEvents()

    guard instance.currentState == .stopped || instance.currentState == .created
      || instance.currentState == .error || instance.currentState == .deleted else
    {
      throw VMManagerError.invalidState("VM must be stopped before deletion")
    }

    // Persist a tombstone before touching files. A restart can finish any interrupted deletion.
    var deletionDefinition = await MainActor.run { instance.definition }
    let bundlePath = deletionDefinition.paths.bundlePath
    let vmName = deletionDefinition.name
    let macAddress = deletionDefinition.network.macAddress
    deletionDefinition.metadata[Self.deletionPendingMetadataKey] = "true"
    deletionDefinition.updateState(.deleted)
    try await persistenceStore.updateVM(vmId, deletionDefinition)
    instance.stateMachine.forceState(.deleted)
    let deletionSnapshot = deletionDefinition
    await MainActor.run { instance.definition = deletionSnapshot }

    if try fileSystemEntryExists(at: bundlePath) {
      try vmBundleRemover(bundlePath)
      logInfo("Deleted VM bundle at \(bundlePath)", category: "VMManager")
    } else {
      logWarning("VM bundle not found at \(bundlePath)", category: "VMManager")
    }

    await cancelNetworkingTasks(for: vmId)
    cancelExpiry(vmId)
    if ephemeralDeletionTasks[vmId]?.token != owningEphemeralDeletionToken {
      ephemeralDeletionTasks.removeValue(forKey: vmId)?.task.cancel()
    }
    pendingEphemeralDeletes.remove(vmId)
    await cleanupNetworkingForVM(vmId)
    runningSinceByVM.removeValue(forKey: vmId)
    runtimeCapacityOwners.remove(vmId)
    try VMInstallationSuccessMarkerStore.removeIfPresent(for: deletionDefinition)
    try await persistenceStore.deleteVM(vmId)
    await networkManager?.releaseMACAddress(macAddress)
    await instance.cleanup()
    vmRegistry.removeValue(forKey: vmId)
    installationProgress.removeValue(forKey: vmId)
    eventBus.publish(.vmDeleted(vmId: vmId, name: vmName))

    logInfo("VM \(vmId) deleted successfully", category: "VMManager")
  }

  /// Deletes all VMs (force-stopping each) and clears the persistence database.
  /// - Returns: Tuple with count of deleted, failed, and error messages per failure
  func wipeAllVMs() async throws -> (deleted: Int, failed: Int, errors: [String]) {
    logWarning("Wiping all VMs", category: "VMManager")

    guard bulkWipeInProgress == false else {
      throw VMManagerError.invalidState("A bulk VM wipe is already in progress")
    }
    bulkWipeInProgress = true
    let backgroundTasks = Array(expiryTasks.values) + ephemeralDeletionTasks.values.map(\.task)
    expiryTasks.values.forEach { $0.cancel() }
    ephemeralDeletionTasks.values.forEach { $0.task.cancel() }
    expiryTasks.removeAll()
    ephemeralDeletionTasks.removeAll()
    pendingEphemeralDeletes.removeAll()
    defer { bulkWipeInProgress = false }

    for task in backgroundTasks {
      await task.value
    }

    await guiManager?.closeAllGUIs()

    let vmIds = Array(vmRegistry.keys)
    var deleted = 0
    var failed = 0
    var errors: [String] = []

    for vmId in vmIds {
      do {
        try await deleteVM(vmId, force: true)
        deleted += 1
      } catch {
        failed += 1
        errors.append("VM \(vmId): \(error.localizedDescription)")
        logError("Failed to wipe VM \(vmId): \(error)", category: "VMManager")
      }
    }

    if failed == 0 {
      installationProgress.removeAll()
      activeInstallers.removeAll()
    }

    bulkWipeInProgress = false
    await restoreBackgroundPoliciesAfterWipe()

    logInfo("Wipe completed: \(deleted) deleted, \(failed) failed", category: "VMManager")
    return (deleted, failed, errors)
  }

  private func restoreBackgroundPoliciesAfterWipe() async {
    for vmId in Array(vmRegistry.keys) {
      guard let instance = vmRegistry[vmId] else { continue }
      let definition = await MainActor.run { instance.definition }
      if definition.expiresAt != nil {
        scheduleExpiry(vmId)
      }
      if definition.ephemeral,
         definition.hasBooted,
         definition.state == .stopped || definition.state == .error
      {
        await deleteIfEphemeral(vmId)
      }
    }
  }

  // MARK: - VM Queries

  /// Returns all VM definitions from the persistence store.
  ///
  /// This reflects the persisted state, not the in-memory registry. Definitions are the source
  /// of truth for state, resources, and network info across agent restarts.
  func listVMs() async throws -> [VMDefinition] {
    do {
      return try await persistenceStore.listVMs()
    } catch {
      throw VMManagerError.operationFailed("Failed to list persisted VMs: \(error.localizedDescription)")
    }
  }

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

  #if DEBUG
  /// Test-only state replacement for lower-level route and recovery tests.
  func replaceDefinitionForTesting(_ vmId: UUID, definition: VMDefinition) async throws {
    do {
      try await persistenceStore.updateVM(vmId, definition)
      if let instance = vmRegistry[vmId] {
        let previousState = instance.currentState
        await MainActor.run {
          instance.forceLifecycleState(definition.state)
          instance.definition = definition
        }
        synchronizeRuntimeUptime(
          for: vmId,
          state: definition.state,
          resetRunningStart: previousState != definition.state
        )
      }
    } catch let error as PersistenceError {
      switch error {
      case .vmNotFound(let id):
        throw VMManagerError.vmNotFound(id)
      default:
        throw VMManagerError.operationFailed(error.localizedDescription)
      }
    }
  }

  func setNetworkingTaskForTesting(_ task: Task<Void, Never>, vmId: UUID) {
    networkingTasks[vmId]?.cancel()
    let completion = NetworkingSetupCompletion()
    let trackedTask = Task<Void, Never> {
      _ = await task.value
      completion.complete()
    }
    networkingTasks[vmId] = NetworkingSetupTaskHandle(
      task: trackedTask,
      completion: completion,
      cancel: {
        task.cancel()
        trackedTask.cancel()
      }
    )
  }

  func withExclusiveDisplayOperationForTesting<T: Sendable>(
    _ vmId: UUID,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    try await withExclusiveDisplayOperation(vmId, operation: operation)
  }

  func setInstallationTaskForTesting(_ task: Task<Void, Never>, vmId: UUID) throws {
    try claimVMOperation(vmId, operation: "install")
    installationTasks[vmId] = (UUID(), task)
  }

  func setImageExportClaimHookForTesting(_ hook: (@Sendable () async -> Void)?) {
    imageExportClaimHookForTesting = hook
  }

  func setStartCapacityClaimHookForTesting(_ hook: (@Sendable () async -> Void)?) {
    startCapacityClaimHookForTesting = hook
  }

  func setVMCreationPublishedHookForTesting(_ hook: (@Sendable (UUID) async -> Void)?) {
    vmCreationPublishedHookForTesting = hook
  }

  func setVMCreationRegistryHookForTesting(_ hook: (@Sendable (UUID) async -> Void)?) {
    vmCreationRegistryHookForTesting = hook
  }

  func setRuntimeCapacityOwnerForTesting(_ ownsCapacity: Bool, vmId: UUID) {
    if ownsCapacity {
      runtimeCapacityOwners.insert(vmId)
    } else {
      runtimeCapacityOwners.remove(vmId)
    }
  }

  func waitForEventProcessingForTesting() async {
    await drainPublishedEvents()
  }
  #endif

  /// Checks if a VM exists
  func vmExists(_ vmId: UUID) async throws -> Bool {
    do {
      return try await persistenceStore.vmExists(vmId)
    } catch {
      throw VMManagerError.operationFailed("Failed to query persisted VMs: \(error.localizedDescription)")
    }
  }

  /// Returns total number of VMs
  func vmCount() async throws -> Int {
    do {
      return try await persistenceStore.count()
    } catch {
      throw VMManagerError.operationFailed("Failed to count persisted VMs: \(error.localizedDescription)")
    }
  }

  /// Returns number of running VMs
  func runningVMCount() -> Int { vmRegistry.values.filter { $0.currentState == .running }.count }

  /// Returns the number of VMs and reservations that count against the product's concurrent limit.
  func activeVMCount() -> Int {
    let activeIds = Set(vmRegistry.compactMap { vmId, instance in
      isCapacityConsumingState(instance.currentState) ? vmId : nil
    })
    return activeIds
      .union(activeInstallers.keys)
      .union(capacityReservations)
      .union(runtimeCapacityOwners)
      .count
  }

  private func claimVMOperation(_ vmId: UUID, operation: String) throws {
    if let current = vmOperations[vmId] {
      throw VMManagerError.invalidState(
        "Cannot \(operation) VM while \(current) is in progress"
      )
    }
    vmOperations[vmId] = operation
  }

  func withExclusiveVMOperation<T: Sendable>(
    _ vmId: UUID,
    operation: String,
    body: @Sendable () async throws -> T
  ) async throws -> T {
    try claimVMOperation(vmId, operation: operation)
    defer { releaseVMOperation(vmId, operation: operation) }
    return try await body()
  }

  private func validateResourcesForHost(_ resources: VMResources) throws {
    do {
      try AVFConfigurationAssembler().validateHostResources(resources)
    } catch {
      throw VMManagerError.invalidResources(error.localizedDescription)
    }
  }

  private func releaseVMOperation(_ vmId: UUID, operation: String) {
    guard vmOperations[vmId] == operation else { return }
    vmOperations.removeValue(forKey: vmId)
    if pendingEphemeralDeletes.contains(vmId) {
      scheduleEphemeralDelete(vmId, delayNanoseconds: nil)
    }
  }

  private func isCapacityConsumingState(_ state: VMState) -> Bool {
    switch state {
    case .installing, .starting, .running, .stopping, .pausing, .paused, .resuming:
      true
    case .created, .stopped, .error, .deleted:
      false
    }
  }

  @discardableResult
  private func reserveCapacityIfNeeded(for vmId: UUID, currentState: VMState, operation: String) throws -> Bool {
    if isCapacityConsumingState(currentState) {
      return capacityReservations.insert(vmId).inserted
    }

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
  func claimImageExport(_ vmId: UUID) async throws -> UUID {
    let claim = try await claimImageExportWithDefinition(vmId)
    return claim.token
  }

  func claimImageExportWithDefinition(_ vmId: UUID) async throws -> (token: UUID, definition: VMDefinition) {
    let instance = try getVMInstance(vmId)
    try claimVMOperation(vmId, operation: "image export")
    var committed = false
    defer {
      if committed == false {
        releaseVMOperation(vmId, operation: "image export")
      }
    }
    #if DEBUG
    if let imageExportClaimHookForTesting {
      await imageExportClaimHookForTesting()
    }
    #endif
    guard imageExportReservations[vmId] == nil else {
      throw VMManagerError.invalidState("VM image export already in progress")
    }
    let state = instance.currentState
    guard state == .stopped else {
      throw VMManagerError.invalidState(
        "VM must be stopped before image export (current: \(state.rawValue))"
      )
    }
    let definition = await MainActor.run { instance.definition }
    try validateManagedPaths(for: definition)
    try validateCompleteVMBundle(at: definition.paths.bundlePath)

    let token = UUID()
    imageExportReservations[vmId] = token
    committed = true
    return (token, definition)
  }

  func releaseImageExport(_ vmId: UUID, token: UUID) {
    if imageExportReservations[vmId] == token {
      imageExportReservations.removeValue(forKey: vmId)
      releaseVMOperation(vmId, operation: "image export")
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
    return max(0, Int(ProcessInfo.processInfo.systemUptime - runningSince))
  }

  /// Returns state and uptime from one actor-isolated snapshot.
  func getVMStateSnapshot(_ vmId: UUID) throws -> (state: VMState, uptime: Int?) {
    let state = try getVMState(vmId)
    guard state == .running, let runningSince = runningSinceByVM[vmId] else {
      return (state, nil)
    }
    return (state, max(0, Int(ProcessInfo.processInfo.systemUptime - runningSince)))
  }

  // MARK: - Graceful Shutdown

  /// Prepares all VMs for agent shutdown.
  /// - Ephemeral VMs are stopped (if operational) and deleted - they are not intended to survive restart.
  /// - Non-ephemeral running and live paused VMs are saved so they can be resumed on next launch.
  /// Bounded by the 30s timeout in `applicationShouldTerminate`.
  func cleanupForShutdown() async {
    guard bulkWipeInProgress == false else {
      logWarning("Skipping overlapping shutdown cleanup while a bulk VM wipe is active", category: "VMManager")
      return
    }
    bulkWipeInProgress = true
    defer { bulkWipeInProgress = false }

    let expiryTasksToDrain = Array(expiryTasks.values)
    let ephemeralTasksToDrain = ephemeralDeletionTasks.values.map(\.task)
    expiryTasksToDrain.forEach { $0.cancel() }
    ephemeralTasksToDrain.forEach { $0.cancel() }
    expiryTasks.removeAll()
    ephemeralDeletionTasks.removeAll()
    pendingEphemeralDeletes.removeAll()
    for task in expiryTasksToDrain + ephemeralTasksToDrain {
      await task.value
    }

    await guiManager?.closeAllGUIs()

    logInfo("Preparing VMs for shutdown", category: "VMManager")

    let instances = Array(vmRegistry.values)

    for instance in instances {
      let (instanceId, isEphemeral, hasLiveRuntime) = await MainActor.run {
        (instance.definition.id, instance.definition.ephemeral, instance.virtualMachine != nil)
      }
      cancelExpiry(instanceId)
      let state = instance.currentState

      switch Self.shutdownAction(
        isEphemeral: isEphemeral,
        state: state,
        hasLiveRuntime: hasLiveRuntime
      ) {
      case .deleteEphemeral:
        logInfo("Cleaning up ephemeral VM \(instanceId) in state \(state.rawValue)", category: "VMManager")
        do {
          try await deleteVM(instanceId, force: true)
        } catch {
          logError("Failed to delete ephemeral VM \(instanceId) on shutdown: \(error)", category: "VMManager")
        }
      case .saveRunning:
        do {
          logInfo("Saving VM \(instanceId)", category: "VMManager")
          try await saveVM(instanceId)
        } catch {
          logError("Failed to save VM \(instanceId): \(error)", category: "VMManager")
          do {
            try await forceStopVM(instanceId)
          } catch {
            logError("Failed to stop VM \(instanceId) after save failure: \(error)", category: "VMManager")
          }
        }
      case .savePausedRuntime:
        do {
          logInfo("Saving paused VM \(instanceId)", category: "VMManager")
          try await savePausedVMForShutdown(instanceId, instance: instance)
        } catch {
          logError("Failed to save paused VM \(instanceId): \(error)", category: "VMManager")
          do {
            try await forceStopVM(instanceId)
          } catch {
            logError("Failed to stop paused VM \(instanceId) after save failure: \(error)", category: "VMManager")
          }
        }
      case .recoverError:
        do {
          try await forceStopVM(instanceId)
        } catch {
          logError("Failed to recover error-state VM \(instanceId) during shutdown: \(error)", category: "VMManager")
        }
      case .none:
        break
      }
    }

    await eventBus.waitUntilIdle()
    await eventProcessor.waitUntilIdle()
    logInfo("Shutdown VM cleanup complete", category: "VMManager")
  }

  static func shutdownAction(
    isEphemeral: Bool,
    state: VMState,
    hasLiveRuntime: Bool
  ) -> VMShutdownAction {
    if isEphemeral {
      return .deleteEphemeral
    }
    switch state {
    case .running:
      return .saveRunning
    case .paused where hasLiveRuntime:
      return .savePausedRuntime
    case .error:
      return .recoverError
    default:
      return .none
    }
  }
}

// MARK: - Errors

enum VMManagerError: Error, LocalizedError {
  case vmNotFound(UUID)
  case invalidState(String)
  case invalidResources(String)
  case invalidInstallationSource(String)
  case timeout(String)
  case operationFailed(String)
  case concurrentVMLimitReached(String)

  var errorDescription: String? {
    switch self {
    case .vmNotFound(let id): "VM not found: \(id.uuidString)"
    case .invalidState(let message): "Invalid state: \(message)"
    case .invalidResources(let message): "Invalid resources: \(message)"
    case .invalidInstallationSource(let message): message
    case .timeout(let message): "Operation timed out: \(message)"
    case .operationFailed(let message): "Operation failed: \(message)"
    case .concurrentVMLimitReached(let message): "Concurrent VM limit reached: \(message)"
    }
  }
}
