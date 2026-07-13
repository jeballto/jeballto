import Foundation
import Virtualization

/// Wrapper for VZVirtualMachine with state machine and lifecycle management
/// Isolated to @MainActor to ensure thread-safe access to all mutable state,
/// since VZVirtualMachine itself requires main-thread access.
@MainActor final class VMInstance {
  /// VM definition containing configuration and metadata
  var definition: VMDefinition

  /// State machine for enforcing valid transitions
  /// Thread-safe: VMStateMachine uses NSLock internally, safe to access from any actor.
  nonisolated let stateMachine: VMStateMachine

  /// The underlying VZVirtualMachine instance
  private(set) var virtualMachine: VZVirtualMachine?

  var runtimeConsumesCapacity: Bool {
    guard let virtualMachine else { return false }
    return virtualMachine.state != .stopped && virtualMachine.state != .error
  }

  /// Delegate for VM events
  private var delegate: AVFDelegate?

  /// Event bus for publishing events
  nonisolated let eventBus: EventBus

  /// AVF configuration helper
  private var avfConfiguration: AVFConfiguration?

  init(definition: VMDefinition, eventBus: EventBus) {
    self.definition = definition
    stateMachine = VMStateMachine(initialState: definition.state)
    self.eventBus = eventBus
  }

  // MARK: - Lifecycle Management

  /// Initializes the VZVirtualMachine instance with configuration
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtualmachine/3656724-init
  func initialize() async throws {
    guard virtualMachine == nil else {
      logWarning("VM \(definition.id) already initialized", category: "VMInstance")
      return
    }

    logInfo("Initializing VM \(definition.id)", category: "VMInstance")

    // Verify required files exist
    let paths = definition.paths
    let diskExists = FileManager.default.fileExists(atPath: paths.diskImagePath)
    let auxExists = FileManager.default.fileExists(atPath: paths.auxiliaryStoragePath)
    let hwModelExists = FileManager.default.fileExists(atPath: paths.hardwareModelPath)
    let machineIdExists = FileManager.default.fileExists(atPath: paths.machineIdentifierPath)
    logDebug(
      "File check - disk:\(diskExists) aux:\(auxExists) hw:\(hwModelExists) machId:\(machineIdExists)",
      category: "VMInstance"
    )

    // Create AVF configuration and virtual machine
    let configHelper = AVFConfiguration(vmDefinition: definition)
    let vmConfig = try configHelper.createConfiguration()
    let runtime = VirtualizationRuntimeFactory().makeRuntime(
      configuration: vmConfig,
      vmId: definition.id,
      eventBus: eventBus
    )
    let vm = runtime.virtualMachine
    let vmDelegate = runtime.delegate
    vmDelegate.onError = { [weak self] error in
      Task<Void, Never> { [weak self] in self?.handleError(error) }
    }
    vmDelegate.onStop = { [weak self] in
      Task<Void, Never> { [weak self] in self?.handleStop() }
    }

    virtualMachine = vm
    delegate = vmDelegate
    avfConfiguration = configHelper

    logInfo("VM \(definition.id) initialized (VZ state: \(vm.state.rawValue))", category: "VMInstance")
  }

  // MARK: - Start

  /// Starts the virtual machine
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtualmachine/3656729-start
  func start() async throws {
    guard let vm = virtualMachine else { throw VMInstanceError.notInitialized }

    let vmState = vm.state
    let initialState = stateMachine.currentState
    logInfo(
      "start() - stateMachine:\(stateMachine.currentState.rawValue) VZ:\(vmState.rawValue)",
      category: "VMInstance"
    )

    // Reconcile only lifecycle states that can legitimately observe a completed start or resume.
    if vmState == .running {
      switch stateMachine.currentState {
      case .running:
        return
      case .starting:
        try transition(to: .running)
        definition.markBooted()
        eventBus.publish(.vmRunning(vmId: definition.id))
        return
      case .resuming:
        try transition(to: .running)
        definition.markBooted()
        eventBus.publish(.vmResumed(vmId: definition.id))
        return
      default:
        let error = VMInstanceError.invalidState(
          "Logical state \(stateMachine.currentState.rawValue) does not match running virtualization runtime"
        )
        recordFailureIfNeeded(error)
        throw error
      }
    }

    if stateMachine.currentState == .running {
      let error = VMInstanceError.invalidState(
        "Logical state is running but virtualization runtime is \(vmState.rawValue)"
      )
      recordFailureIfNeeded(error)
      throw error
    }
    guard vmState != .paused else {
      throw VMInstanceError.invalidState("A paused VM must be resumed, not started")
    }

    let saveFilePath = definition.paths.saveFilePath
    let shouldRestoreSavedState = Self.shouldRestoreSavedState(
      initialState: initialState,
      saveFileExists: FileManager.default.fileExists(atPath: saveFilePath)
    )

    // Transition to STARTING
    guard stateMachine.canTransition(to: .starting) else {
      throw VMInstanceError.invalidState("Cannot start VM from state \(stateMachine.currentState.rawValue)")
    }
    try transition(to: .starting)
    eventBus.publish(.vmStarting(vmId: definition.id))

    // A save file is meaningful only while the logical VM is PAUSED. A leftover file must never
    // rewind a normal STOPPED boot.
    if shouldRestoreSavedState {
      logInfo("Restoring VM \(definition.id) from saved state", category: "VMInstance")
      try await restoreFromSave(vm: vm, saveFileURL: URL(fileURLWithPath: saveFilePath))
      return
    }

    // Start VM
    logInfo("Starting VM \(definition.id)", category: "VMInstance")
    let startUptime = ProcessInfo.processInfo.systemUptime
    do {
      try await vm.start()
      let durationStr = String(format: "%.1f", ProcessInfo.processInfo.systemUptime - startUptime)
      logDebug("VM \(definition.id) started in \(durationStr)s", category: "VMInstance")
      try transition(to: .running)
      definition.markBooted()
      eventBus.publish(.vmRunning(vmId: definition.id))
    } catch {
      let durationStr = String(format: "%.1f", ProcessInfo.processInfo.systemUptime - startUptime)
      logError(
        "VM \(definition.id) start failed after \(durationStr)s: \(error.localizedDescription)",
        category: "VMInstance"
      )
      recordFailureIfNeeded(error)
      throw error
    }

    logInfo("VM \(definition.id) is now running", category: "VMInstance")
  }

  // MARK: - Stop

  /// Stops the virtual machine runtime without requesting an in-guest shutdown
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtualmachine/3656731-stop
  func stop() async throws {
    guard let vm = virtualMachine else {
      if stateMachine.currentState == .paused {
        try discardSavedStateAndStop()
        return
      }
      throw VMInstanceError.notInitialized
    }

    guard stateMachine.canTransition(to: .stopping) else {
      throw VMInstanceError.invalidState("Cannot stop VM from state \(stateMachine.currentState.rawValue)")
    }
    try transition(to: .stopping)
    eventBus.publish(.vmStopping(vmId: definition.id))

    logInfo("Stopping VM \(definition.id)", category: "VMInstance")

    do {
      try await vm.stop()

      if stateMachine.currentState == .stopped {
        clearVirtualMachine()
        try removeSavedStateIfPresent(context: "after VM stop")
        logInfo("VM \(definition.id) stop completed by delegate", category: "VMInstance")
        return
      }
      guard stateMachine.currentState == .stopping else {
        throw VMInstanceError.invalidState(
          "VM stop completed but lifecycle entered \(stateMachine.currentState.rawValue)"
        )
      }

      clearVirtualMachine()
      try transition(to: .stopped)
      eventBus.publish(.vmStopped(vmId: definition.id))
      try removeSavedStateIfPresent(context: "after VM stop")
    } catch {
      logError("Error stopping VM \(definition.id): \(error)", category: "VMInstance")
      recordFailureIfNeeded(error)
      throw error
    }

    logInfo("VM \(definition.id) is now stopped", category: "VMInstance")
  }

  /// Stops the underlying runtime for forced cleanup without claiming success before AVF confirms it.
  /// This is intentionally separate from logical state recovery: a failed AVF stop must never be
  /// represented as a stopped VM while the runtime may still own its files.
  func forceStopRuntime() async throws {
    let initialLogicalState = stateMachine.currentState
    guard let vm = virtualMachine else {
      switch stateMachine.currentState {
      case .paused:
        try discardSavedStateAndStop()
        return
      case .created, .stopped, .error, .deleted:
        return
      default:
        throw VMInstanceError.notInitialized
      }
    }

    if vm.state == .stopped || vm.state == .error {
      clearVirtualMachine()
      if stateMachine.currentState != .deleted {
        forceState(.stopped)
        eventBus.publish(.vmStopped(vmId: definition.id))
      }
      try removeSavedStateIfPresent(context: "after forced VM stop")
      return
    }

    guard vm.canStop else {
      throw VMInstanceError.invalidState(
        "Virtualization runtime cannot stop from state \(vm.state.rawValue)"
      )
    }

    do {
      try await vm.stop()
    } catch {
      logError("Forced stop failed for VM \(definition.id): \(error)", category: "VMInstance")
      recordFailureIfNeeded(error)
      throw error
    }

    if stateMachine.currentState == .stopped {
      clearVirtualMachine()
      try removeSavedStateIfPresent(context: "after forced VM stop")
      return
    }
    if stateMachine.currentState == .deleted {
      clearVirtualMachine()
      return
    }
    guard stateMachine.currentState != .error || initialLogicalState == .error else {
      clearVirtualMachine()
      throw VMInstanceError.invalidState("Virtualization runtime reported an error while stopping")
    }

    clearVirtualMachine()
    forceState(.stopped)
    eventBus.publish(.vmStopped(vmId: definition.id))
    try removeSavedStateIfPresent(context: "after forced VM stop")
  }

  /// Discards a persisted pause snapshot when no AVF runtime exists, then records a normal stop.
  private func discardSavedStateAndStop() throws {
    guard virtualMachine == nil, stateMachine.currentState == .paused else {
      throw VMInstanceError.invalidState("Saved-state discard requires a runtime-free paused VM")
    }
    try removeSavedStateIfPresent(context: "while stopping a restored paused VM")
    try transition(to: .stopping)
    eventBus.publish(.vmStopping(vmId: definition.id))
    try transition(to: .stopped)
    eventBus.publish(.vmStopped(vmId: definition.id))
  }

  // MARK: - Pause & Resume

  /// Pauses the virtual machine
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtualmachine/3656727-pause
  func pause() async throws {
    guard let vm = virtualMachine else { throw VMInstanceError.notInitialized }
    guard vm.canPause else { throw VMInstanceError.invalidState("VM cannot be paused in current state") }

    guard stateMachine.canTransition(to: .pausing) else {
      throw VMInstanceError.invalidState("Cannot pause VM from state \(stateMachine.currentState.rawValue)")
    }
    try transition(to: .pausing)

    logInfo("Pausing VM \(definition.id)", category: "VMInstance")
    do {
      try await vm.pause()
      try transition(to: .paused)
      eventBus.publish(.vmPaused(vmId: definition.id))
    } catch {
      logError("Error pausing VM \(definition.id): \(error)", category: "VMInstance")
      recordFailureIfNeeded(error)
      throw error
    }

    logInfo("VM \(definition.id) is now paused", category: "VMInstance")
  }

  /// Resumes a paused virtual machine
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtualmachine/3656728-resume
  func resume() async throws {
    guard let vm = virtualMachine else { throw VMInstanceError.notInitialized }

    guard stateMachine.canTransition(to: .resuming) else {
      throw VMInstanceError.invalidState("Cannot resume VM from state \(stateMachine.currentState.rawValue)")
    }
    try transition(to: .resuming)

    logInfo("Resuming VM \(definition.id)", category: "VMInstance")
    do {
      try await vm.resume()
      try transition(to: .running)
      definition.markBooted()
      eventBus.publish(.vmResumed(vmId: definition.id))
    } catch {
      logError("Error resuming VM \(definition.id): \(error)", category: "VMInstance")
      recordFailureIfNeeded(error)
      throw error
    }

    logInfo("VM \(definition.id) resumed", category: "VMInstance")
  }

  /// Resumes a VM from a save file on disk (after agent restart)
  func resumeFromSave() async throws {
    guard let vm = virtualMachine else { throw VMInstanceError.notInitialized }

    let saveFilePath = definition.paths.saveFilePath
    guard FileManager.default.fileExists(atPath: saveFilePath) else {
      throw VMInstanceError.invalidConfiguration("No save file found for resume")
    }

    let saveFileURL = URL(fileURLWithPath: saveFilePath)
    logInfo("Resuming VM \(definition.id) from save file", category: "VMInstance")

    guard stateMachine.canTransition(to: .resuming) else {
      throw VMInstanceError.invalidState("Cannot resume VM from state \(stateMachine.currentState.rawValue)")
    }
    try transition(to: .resuming)

    do {
      try await vm.restoreMachineStateFrom(url: saveFileURL)
      try await vm.resume()
      try transition(to: .running)
      definition.markBooted()
    } catch {
      logError("Error resuming VM \(definition.id) from save: \(error)", category: "VMInstance")
      recordFailureIfNeeded(error)
      throw error
    }

    eventBus.publish(.vmRunning(vmId: definition.id))

    removeConsumedSavedState(at: saveFileURL)
    logInfo("VM \(definition.id) restored from save file and running", category: "VMInstance")
  }

  // MARK: - Save

  /// Saves the virtual machine state to disk
  func save() async throws {
    guard let vm = virtualMachine else { throw VMInstanceError.notInitialized }

    let saveFilePath = definition.paths.saveFilePath
    let saveFileURL = URL(fileURLWithPath: saveFilePath)
    logInfo("Saving VM \(definition.id) state", category: "VMInstance")

    guard vm.state == .running, vm.canPause else {
      throw VMInstanceError.invalidState(
        "VM runtime must be running and pausable before saving (current: \(vm.state.rawValue))"
      )
    }

    guard stateMachine.canTransition(to: .pausing) else {
      throw VMInstanceError.invalidState("Cannot save VM from state \(stateMachine.currentState.rawValue)")
    }
    try removeSavedStateIfPresent(context: "before VM save")
    try transition(to: .pausing)

    do {
      try await vm.pause()
      try await vm.saveMachineStateTo(url: saveFileURL)
      try transition(to: .paused)
    } catch {
      let saveError = error
      var cleanupDescription: String?
      do {
        try removeSavedStateIfPresent(context: "after failed VM save")
      } catch {
        cleanupDescription = error.localizedDescription
      }
      let detail = cleanupDescription.map { "; partial save cleanup also failed: \($0)" } ?? ""
      logError("Error saving VM \(definition.id): \(saveError)\(detail)", category: "VMInstance")
      recordFailureIfNeeded(saveError, detail: detail)
      if let cleanupDescription {
        throw VMInstanceError.savedStateCleanupFailed(
          "Save failed: \(saveError.localizedDescription); partial state cleanup failed: \(cleanupDescription)"
        )
      }
      throw saveError
    }

    eventBus.publish(.vmPaused(vmId: definition.id))

    logDebug("VM \(definition.id) state saved successfully", category: "VMInstance")
  }

  /// Saves an already-paused live runtime during agent shutdown.
  func savePausedRuntime() async throws {
    guard let vm = virtualMachine else { throw VMInstanceError.notInitialized }
    let saveFilePath = definition.paths.saveFilePath
    guard vm.state == .paused, stateMachine.currentState == .paused else {
      throw VMInstanceError.invalidState(
        "VM runtime and lifecycle must both be paused before saving an existing pause"
      )
    }

    let saveFileURL = URL(fileURLWithPath: saveFilePath)
    try removeSavedStateIfPresent(context: "before paused VM save")
    do {
      try await vm.saveMachineStateTo(url: saveFileURL)
    } catch {
      let saveError = error
      var cleanupDescription: String?
      do {
        try removeSavedStateIfPresent(context: "after failed paused VM save")
      } catch {
        cleanupDescription = error.localizedDescription
      }
      let detail = cleanupDescription.map { "; partial save cleanup also failed: \($0)" } ?? ""
      recordFailureIfNeeded(saveError, detail: detail)
      if let cleanupDescription {
        throw VMInstanceError.savedStateCleanupFailed(
          "Paused save failed: \(saveError.localizedDescription); partial state cleanup failed: \(cleanupDescription)"
        )
      }
      throw saveError
    }
    logDebug("Paused VM \(definition.id) state saved successfully", category: "VMInstance")
  }

  // MARK: - Private: Restore from save

  /// Restores the virtual machine from saved state
  private func restoreFromSave(vm: VZVirtualMachine, saveFileURL: URL) async throws {
    logInfo("Restoring VM \(definition.id) from \(saveFileURL.path)", category: "VMInstance")

    // Caller has already transitioned to .starting; walk through .paused and .resuming using
    // validated transitions so any unexpected state surfaces via the state machine rather than
    // being masked by forceState.
    do {
      try await vm.restoreMachineStateFrom(url: saveFileURL)
      try transition(to: .paused)
      try transition(to: .resuming)
      try await vm.resume()
      try transition(to: .running)
      definition.markBooted()
    } catch {
      logError("Error restoring VM \(definition.id) from save: \(error)", category: "VMInstance")
      recordFailureIfNeeded(error)
      throw error
    }

    eventBus.publish(.vmRunning(vmId: definition.id))
    removeConsumedSavedState(at: saveFileURL)
    logInfo("VM \(definition.id) restored and running", category: "VMInstance")
  }

  // MARK: - State Queries

  var canStart: Bool { stateMachine.canTransition(to: .starting) }
  var canStop: Bool { stateMachine.canTransition(to: .stopping) }
  var canPause: Bool { stateMachine.canTransition(to: .pausing) }

  /// Current state of the VM (thread-safe via VMStateMachine's NSLock)
  nonisolated var currentState: VMState { stateMachine.currentState }

  // MARK: - Error Handling

  private func handleError(_ error: Error) {
    guard stateMachine.currentState != .deleted else {
      clearVirtualMachine()
      logInfo("Ignoring late error callback for deleted VM \(definition.id)", category: "VMInstance")
      return
    }
    logError("VM \(definition.id) error: \(error.localizedDescription)", category: "VMInstance")
    recordFailureIfNeeded(error)
    clearVirtualMachine()
  }

  private func recordFailureIfNeeded(_ error: Error, detail: String = "") {
    guard stateMachine.currentState != .error, stateMachine.currentState != .deleted else { return }
    forceState(.error)
    eventBus.publish(.errorOccurred(vmId: definition.id, error: error.localizedDescription + detail))
  }

  private func handleStop() {
    guard stateMachine.currentState != .stopped else { return }
    let vzState = virtualMachine.map { "VZ:\($0.state.rawValue)" } ?? "VZ:nil"
    logInfo(
      "VM \(definition.id) stop callback - \(vzState) sm:\(stateMachine.currentState.rawValue)",
      category: "VMInstance"
    )

    do {
      switch stateMachine.currentState {
      case .running:
        try transition(to: .stopping)
        eventBus.publish(.vmStopping(vmId: definition.id))
      case .stopping:
        break
      case .error, .deleted:
        clearVirtualMachine()
        logInfo(
          "Ignoring late stop callback while VM is \(stateMachine.currentState.rawValue)",
          category: "VMInstance"
        )
        return
      default:
        let error = VMInstanceError.invalidState(
          "Unexpected guest stop while VM was \(stateMachine.currentState.rawValue)"
        )
        recordFailureIfNeeded(error)
        clearVirtualMachine()
        return
      }

      // A stopped VZVirtualMachine cannot be restarted. Recreate it on the next start.
      clearVirtualMachine()
      try transition(to: .stopped)
      eventBus.publish(.vmStopped(vmId: definition.id))
    } catch {
      logError("Failed to finalize guest stop for VM \(definition.id): \(error)", category: "VMInstance")
      recordFailureIfNeeded(error)
    }
  }

  // MARK: - Cleanup

  static func shouldRestoreSavedState(initialState: VMState, saveFileExists: Bool) -> Bool {
    initialState == .paused && saveFileExists
  }

  func transitionLifecycle(to state: VMState) throws {
    try transition(to: state)
  }

  func forceLifecycleState(_ state: VMState) {
    forceState(state)
  }

  func recordLifecycleError(_ error: Error) {
    handleError(error)
  }

  private func transition(to state: VMState) throws {
    let previous = stateMachine.currentState
    try stateMachine.transition(to: state)
    definition.updateState(state)
    eventBus.publish(.stateChanged(vmId: definition.id, from: previous, to: state))
  }

  private func forceState(_ state: VMState) {
    let previous = stateMachine.currentState
    stateMachine.forceState(state)
    definition.updateState(state)
    if previous != state {
      eventBus.publish(.stateChanged(vmId: definition.id, from: previous, to: state))
    }
  }

  /// Clears the VZVirtualMachine and associated objects
  private func clearVirtualMachine() {
    virtualMachine = nil
    delegate = nil
    avfConfiguration = nil
  }

  private func removeSavedStateIfPresent(context: String) throws {
    let saveFilePath = definition.paths.saveFilePath
    guard FileManager.default.fileExists(atPath: saveFilePath) else { return }
    do {
      try FileManager.default.removeItem(atPath: saveFilePath)
    } catch {
      throw VMInstanceError.savedStateCleanupFailed(
        "Failed to remove saved state \(saveFilePath) \(context): \(error.localizedDescription)"
      )
    }
  }

  private func removeConsumedSavedState(at url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      logError(
        "VM \(definition.id) resumed but consumed save file could not be removed at \(url.path): "
          + error.localizedDescription,
        category: "VMInstance"
      )
    }
  }

  /// Cleans up all resources
  func cleanup() {
    clearVirtualMachine()
    logInfo("VM \(definition.id) resources cleaned up", category: "VMInstance")
  }
}

// MARK: - Errors

enum VMInstanceError: Error, LocalizedError {
  case notInitialized
  case invalidState(String)
  case invalidConfiguration(String)
  case savedStateCleanupFailed(String)

  var errorDescription: String? {
    switch self {
    case .notInitialized: "VM instance not initialized"
    case .invalidState(let message): "Invalid state: \(message)"
    case .invalidConfiguration(let message): "Invalid configuration: \(message)"
    case .savedStateCleanupFailed(let message): message
    }
  }
}
