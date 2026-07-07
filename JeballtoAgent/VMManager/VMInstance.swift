import Foundation
import Virtualization

/// Wrapper for VZVirtualMachine with state machine and lifecycle management
/// Isolated to @MainActor to ensure thread-safe access to all mutable state,
/// since VZVirtualMachine itself requires main-thread access.
@MainActor class VMInstance {
  /// VM definition containing configuration and metadata
  var definition: VMDefinition

  /// State machine for enforcing valid transitions
  /// Thread-safe: VMStateMachine uses NSLock internally, safe to access from any actor.
  nonisolated let stateMachine: VMStateMachine

  /// The underlying VZVirtualMachine instance
  private(set) var virtualMachine: VZVirtualMachine?

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

  /// Adopts an existing VZVirtualMachine (e.g., from installer)
  /// - Parameter vm: The running VZVirtualMachine to adopt
  /// - Parameter existingDelegate: Optional existing delegate to reuse
  func adoptVirtualMachine(_ vm: VZVirtualMachine, delegate existingDelegate: AVFDelegate? = nil) {
    guard virtualMachine == nil else {
      logWarning("VM \(definition.id) already has a virtual machine", category: "VMInstance")
      return
    }

    let vmDelegate: AVFDelegate
    if let existingDelegate {
      vmDelegate = existingDelegate
      vmDelegate.onError = { [weak self] error in Task { [weak self] in self?.handleError(error) } }
      vmDelegate.onStop = { [weak self] in Task { [weak self] in self?.handleStop() } }
      logInfo("VM \(definition.id) adopted VM with existing delegate", category: "VMInstance")
    } else {
      vmDelegate = AVFDelegate(vmId: definition.id, eventBus: eventBus)
      vmDelegate.onError = { [weak self] error in Task { [weak self] in self?.handleError(error) } }
      vmDelegate.onStop = { [weak self] in Task { [weak self] in self?.handleStop() } }
      vm.delegate = vmDelegate
      logInfo("VM \(definition.id) adopted VM with new delegate", category: "VMInstance")
    }

    virtualMachine = vm
    delegate = vmDelegate
  }

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
    vmDelegate.onError = { [weak self] error in Task { [weak self] in self?.handleError(error) } }
    vmDelegate.onStop = { [weak self] in Task { [weak self] in self?.handleStop() } }

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
    logInfo(
      "start() - stateMachine:\(stateMachine.currentState.rawValue) VZ:\(vmState.rawValue)",
      category: "VMInstance"
    )

    // Sync state machine if VZ is already running
    if vmState == .running {
      if stateMachine.currentState != .running {
        logWarning("State machine out of sync, forcing to RUNNING", category: "VMInstance")
        stateMachine.forceState(.running)
        definition.updateState(.running)
        eventBus.publish(.vmRunning(vmId: definition.id))
      }
      return
    }

    if stateMachine.currentState == .running { return }

    // Transition to STARTING
    guard stateMachine.canTransition(to: .starting) else {
      throw VMInstanceError.invalidState("Cannot start VM from state \(stateMachine.currentState.rawValue)")
    }
    try stateMachine.transition(to: .starting)
    definition.updateState(.starting)
    eventBus.publish(.vmStarting(vmId: definition.id))

    // Restore from save file if available
    if let saveFilePath = definition.paths.saveFilePath, FileManager.default.fileExists(atPath: saveFilePath) {
      logInfo("Restoring VM \(definition.id) from saved state", category: "VMInstance")
      try await restoreFromSave(vm: vm, saveFileURL: URL(fileURLWithPath: saveFilePath))
      return
    }

    // Start VM
    logInfo("Starting VM \(definition.id)", category: "VMInstance")
    let startTime = Date()
    do {
      try await vm.start()
      let durationStr = String(format: "%.1f", Date().timeIntervalSince(startTime))
      logDebug("VM \(definition.id) started in \(durationStr)s", category: "VMInstance")
    } catch {
      let durationStr = String(format: "%.1f", Date().timeIntervalSince(startTime))
      logError(
        "VM \(definition.id) start failed after \(durationStr)s: \(error.localizedDescription)",
        category: "VMInstance"
      )
      stateMachine.forceState(.error)
      definition.updateState(.error)
      eventBus.publish(.errorOccurred(vmId: definition.id, error: error.localizedDescription))
      throw error
    }

    try stateMachine.transition(to: .running)
    definition.updateState(.running)
    eventBus.publish(.vmRunning(vmId: definition.id))

    logInfo("VM \(definition.id) is now running", category: "VMInstance")
  }

  // MARK: - Stop

  /// Stops the virtual machine gracefully
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtualmachine/3656731-stop
  func stop() async throws {
    guard let vm = virtualMachine else { throw VMInstanceError.notInitialized }

    guard stateMachine.canTransition(to: .stopping) else {
      throw VMInstanceError.invalidState("Cannot stop VM from state \(stateMachine.currentState.rawValue)")
    }
    try stateMachine.transition(to: .stopping)
    definition.updateState(.stopping)
    eventBus.publish(.vmStopping(vmId: definition.id))

    logInfo("Stopping VM \(definition.id)", category: "VMInstance")

    do {
      try await vm.stop()
    } catch {
      logError("Error stopping VM \(definition.id): \(error)", category: "VMInstance")
      stateMachine.forceState(.error)
      definition.updateState(.error)
      eventBus.publish(.errorOccurred(vmId: definition.id, error: error.localizedDescription))
      throw error
    }

    clearVirtualMachine()

    try stateMachine.transition(to: .stopped)
    definition.updateState(.stopped)
    eventBus.publish(.vmStopped(vmId: definition.id))

    logInfo("VM \(definition.id) is now stopped", category: "VMInstance")
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
    try stateMachine.transition(to: .pausing)
    definition.updateState(.pausing)

    logInfo("Pausing VM \(definition.id)", category: "VMInstance")
    do {
      try await vm.pause()
    } catch {
      logError("Error pausing VM \(definition.id): \(error)", category: "VMInstance")
      stateMachine.forceState(.error)
      definition.updateState(.error)
      eventBus.publish(.errorOccurred(vmId: definition.id, error: error.localizedDescription))
      throw error
    }

    try stateMachine.transition(to: .paused)
    definition.updateState(.paused)
    eventBus.publish(.vmPaused(vmId: definition.id))

    logInfo("VM \(definition.id) is now paused", category: "VMInstance")
  }

  /// Resumes a paused virtual machine
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtualmachine/3656728-resume
  func resume() async throws {
    guard let vm = virtualMachine else { throw VMInstanceError.notInitialized }

    guard stateMachine.canTransition(to: .resuming) else {
      throw VMInstanceError.invalidState("Cannot resume VM from state \(stateMachine.currentState.rawValue)")
    }
    try stateMachine.transition(to: .resuming)
    definition.updateState(.resuming)

    logInfo("Resuming VM \(definition.id)", category: "VMInstance")
    do {
      try await vm.resume()
    } catch {
      logError("Error resuming VM \(definition.id): \(error)", category: "VMInstance")
      stateMachine.forceState(.error)
      definition.updateState(.error)
      eventBus.publish(.errorOccurred(vmId: definition.id, error: error.localizedDescription))
      throw error
    }

    try stateMachine.transition(to: .running)
    definition.updateState(.running)
    eventBus.publish(.vmResumed(vmId: definition.id))

    logInfo("VM \(definition.id) resumed", category: "VMInstance")
  }

  /// Resumes a VM from a save file on disk (after agent restart)
  func resumeFromSave() async throws {
    guard let vm = virtualMachine else { throw VMInstanceError.notInitialized }

    guard let saveFilePath = definition.paths.saveFilePath,
          FileManager.default.fileExists(atPath: saveFilePath) else
    {
      throw VMInstanceError.invalidConfiguration("No save file found for resume")
    }

    let saveFileURL = URL(fileURLWithPath: saveFilePath)
    logInfo("Resuming VM \(definition.id) from save file", category: "VMInstance")

    guard stateMachine.canTransition(to: .resuming) else {
      throw VMInstanceError.invalidState("Cannot resume VM from state \(stateMachine.currentState.rawValue)")
    }
    try stateMachine.transition(to: .resuming)
    definition.updateState(.resuming)

    do {
      try await vm.restoreMachineStateFrom(url: saveFileURL)
      try await vm.resume()
      try stateMachine.transition(to: .running)
      definition.updateState(.running)
    } catch {
      logError("Error resuming VM \(definition.id) from save: \(error)", category: "VMInstance")
      stateMachine.forceState(.error)
      definition.updateState(.error)
      eventBus.publish(.errorOccurred(vmId: definition.id, error: error.localizedDescription))
      throw error
    }

    eventBus.publish(.vmRunning(vmId: definition.id))

    try? FileManager.default.removeItem(at: saveFileURL)
    logInfo("VM \(definition.id) restored from save file and running", category: "VMInstance")
  }

  // MARK: - Save

  /// Saves the virtual machine state to disk
  func save() async throws {
    guard let vm = virtualMachine else { throw VMInstanceError.notInitialized }

    guard let saveFilePath = definition.paths.saveFilePath else {
      throw VMInstanceError.invalidConfiguration("Save file path not configured")
    }

    let saveFileURL = URL(fileURLWithPath: saveFilePath)
    logInfo("Saving VM \(definition.id) state", category: "VMInstance")

    guard stateMachine.canTransition(to: .pausing) else {
      throw VMInstanceError.invalidState("Cannot save VM from state \(stateMachine.currentState.rawValue)")
    }
    try stateMachine.transition(to: .pausing)
    definition.updateState(.pausing)

    do {
      try await vm.pause()
      try await vm.saveMachineStateTo(url: saveFileURL)
      try stateMachine.transition(to: .paused)
      definition.updateState(.paused)
    } catch {
      logError("Error saving VM \(definition.id): \(error)", category: "VMInstance")
      stateMachine.forceState(.error)
      definition.updateState(.error)
      eventBus.publish(.errorOccurred(vmId: definition.id, error: error.localizedDescription))
      throw error
    }

    eventBus.publish(.vmPaused(vmId: definition.id))

    logDebug("VM \(definition.id) state saved successfully", category: "VMInstance")
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
      try stateMachine.transition(to: .paused)
      definition.updateState(.paused)
      try stateMachine.transition(to: .resuming)
      definition.updateState(.resuming)
      try await vm.resume()
      try stateMachine.transition(to: .running)
      definition.updateState(.running)
    } catch {
      logError("Error restoring VM \(definition.id) from save: \(error)", category: "VMInstance")
      stateMachine.forceState(.error)
      definition.updateState(.error)
      eventBus.publish(.errorOccurred(vmId: definition.id, error: error.localizedDescription))
      throw error
    }

    eventBus.publish(.vmRunning(vmId: definition.id))
    try? FileManager.default.removeItem(at: saveFileURL)
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
    logError("VM \(definition.id) error: \(error.localizedDescription)", category: "VMInstance")
    stateMachine.forceState(.error)
    definition.updateState(.error)
    eventBus.publish(.errorOccurred(vmId: definition.id, error: error.localizedDescription))
  }

  private func handleStop() {
    guard stateMachine.currentState != .stopped else { return }
    let vzState = virtualMachine.map { "VZ:\($0.state.rawValue)" } ?? "VZ:nil"
    logInfo(
      "VM \(definition.id) stop callback - \(vzState) sm:\(stateMachine.currentState.rawValue)",
      category: "VMInstance"
    )

    // VZVirtualMachine cannot be restarted after stopping - clear for fresh init on next start
    clearVirtualMachine()

    do {
      try stateMachine.transition(to: .stopped)
      definition.updateState(.stopped)
      eventBus.publish(.vmStopped(vmId: definition.id))
    } catch {
      logDebug("Forcing STOPPED state: \(error)", category: "VMInstance")
      stateMachine.forceState(.stopped)
      definition.updateState(.stopped)
      eventBus.publish(.vmStopped(vmId: definition.id))
    }
  }

  // MARK: - Cleanup

  /// Clears the VZVirtualMachine and associated objects
  private func clearVirtualMachine() {
    virtualMachine = nil
    delegate = nil
    avfConfiguration = nil
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

  var errorDescription: String? {
    switch self {
    case .notInitialized: "VM instance not initialized"
    case .invalidState(let message): "Invalid state: \(message)"
    case .invalidConfiguration(let message): "Invalid configuration: \(message)"
    }
  }
}
