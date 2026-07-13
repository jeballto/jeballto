import Foundation

/// Orchestrates the execution of a Jeballtofile blueprint step by step
final class JeballtofileExecutor: @unchecked Sendable {
  let execution: JeballtofileExecution
  private let steps: [JeballtofileStep]
  private let source: String?
  private let vmManager: VMManager
  private let eventBus: EventBus
  private let onTerminal: @Sendable (UUID) -> Void
  private let taskLock = NSLock()
  private var task: Task<Void, Never>?
  private var finished = false

  var isFinished: Bool {
    taskLock.withLock { finished }
  }

  init(
    execution: JeballtofileExecution,
    steps: [JeballtofileStep],
    source: String?,
    vmManager: VMManager,
    eventBus: EventBus,
    onTerminal: @escaping @Sendable (UUID) -> Void
  ) {
    self.execution = execution
    self.steps = steps
    self.source = source
    self.vmManager = vmManager
    self.eventBus = eventBus
    self.onTerminal = onTerminal
  }

  /// Starts asynchronous execution of all steps
  func start() {
    taskLock.lock()
    guard task == nil, finished == false else {
      taskLock.unlock()
      return
    }
    let executionId = execution.id
    let vmId = execution.vmId
    guard execution.status == .running else {
      finished = true
      taskLock.unlock()
      onTerminal(executionId)
      return
    }
    eventBus.publish(.jeballtofileStarted(executionId: executionId, vmId: vmId))
    logInfo("Jeballtofile execution \(executionId) started for VM \(vmId)", category: "Jeballtofile")
    let newTask = Task<Void, Never> { [weak self] in
      await self?.run()
    }
    task = newTask
    taskLock.unlock()
  }

  /// Cancels execution and marks the current step as cancelled when the task observes cancellation.
  @discardableResult
  func cancel() -> Bool {
    guard execution.cancel() else { return false }
    taskLock.withLock { task }?.cancel()
    publishCancellation(executionId: execution.id, vmId: execution.vmId, step: execution.currentStep)
    return true
  }

  func waitUntilFinished() async {
    let current = taskLock.withLock { task }
    await current?.value
  }

  private func run() async {
    let executionId = execution.id
    let vmId = execution.vmId
    defer {
      taskLock.withLock { finished = true }
      if execution.status != .running {
        onTerminal(executionId)
      }
    }

    for (index, step) in steps.enumerated() {
      if execution.isCancelled { return }

      guard execution.startStep(index, type: step.type) else { return }

      do {
        try Task.checkCancellation()
        eventBus.publish(.jeballtofileStepStarted(
          executionId: executionId,
          vmId: vmId,
          step: index,
          stepType: step.type.rawValue
        ))
        logInfo(
          "Jeballtofile \(executionId) step \(index): \(step.type.rawValue)",
          category: "Jeballtofile"
        )
        let message = try await executeStep(step, vmId: vmId)
        try Task.checkCancellation()
        if execution.isCancelled { throw CancellationError() }
        guard execution.completeStep(index, message: message) else { return }
        eventBus.publish(.jeballtofileStepCompleted(
          executionId: executionId, vmId: vmId, step: index, stepType: step.type.rawValue
        ))
      } catch is CancellationError {
        if execution.cancelStep(index, message: "Cancelled by user") {
          publishCancellation(executionId: executionId, vmId: vmId, step: index)
        }
        return
      } catch {
        let errorMessage = error.localizedDescription
        if execution.failStep(index, error: errorMessage) {
          eventBus.publish(.jeballtofileStepFailed(
            executionId: executionId,
            vmId: vmId,
            step: index,
            stepType: step.type.rawValue,
            error: errorMessage
          ))
          eventBus.publish(.jeballtofileFailed(
            executionId: executionId, vmId: vmId, step: index, error: errorMessage
          ))
          logError(
            "Jeballtofile \(executionId) failed at step \(index) (\(step.type.rawValue)): \(errorMessage)",
            category: "Jeballtofile"
          )
        }
        return
      }
    }

    if execution.complete() {
      eventBus.publish(.jeballtofileCompleted(executionId: executionId, vmId: vmId))
      logInfo("Jeballtofile execution \(executionId) completed successfully", category: "Jeballtofile")
    }
  }

  private func publishCancellation(executionId: UUID, vmId: UUID, step: Int) {
    logInfo("Jeballtofile execution \(executionId) cancelled at step \(step)", category: "Jeballtofile")
    eventBus.publish(.jeballtofileCancelled(executionId: executionId, vmId: vmId, step: step))
  }

  private func executeStep(_ step: JeballtofileStep, vmId: UUID) async throws -> String {
    switch step.type {
    case .install:
      let effectiveSource = try IPSWSourceValidator.normalized(source)
      try await vmManager.installVM(vmId, ipswSource: effectiveSource)
      return "macOS installation completed"

    case .start:
      try await vmManager.startVM(vmId)
      return "VM started"

    case .stop:
      try await vmManager.stopVM(vmId)
      return "VM stopped"

    case .guiOpen:
      try await vmManager.openGUI(vmId)
      return "GUI window opened"

    case .guiClose:
      try await vmManager.closeGUI(vmId)
      return "GUI window closed"

    case .keystrokes:
      guard let keystrokes = step.keystrokes else {
        throw JeballtofileExecutorError.invalidStep("Missing keystrokes")
      }
      let count = try await vmManager.executeKeystrokes(vmId, keystrokes: keystrokes)
      return "Injected \(count) keystroke actions"

    case .execute:
      guard let command = step.command else {
        throw JeballtofileExecutorError.invalidStep("Missing command")
      }
      let user = step.user ?? "admin"
      let password = step.password
      let timeout = TimeInterval(step.timeout ?? 30)
      let result = try await vmManager.executeCommand(
        vmId,
        command: command,
        user: user,
        password: password,
        timeout: timeout,
        retryOnSSHFailure: true
      )
      if result.exitCode != 0 {
        throw JeballtofileExecutorError.commandFailed(
          command: command, exitCode: result.exitCode, stderr: result.stderr
        )
      }
      return "Command completed (exit code 0)"

    case .wait:
      let seconds = step.seconds ?? 1
      try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
      return "Waited \(seconds) seconds"
    }
  }

  /// Resolves source field to the effective IPSW source path/URL (strips file:// scheme)
  static func resolveIPSWSource(_ source: String?) -> String? {
    try? IPSWSourceValidator.normalized(source)
  }
}

enum JeballtofileExecutorError: Error, LocalizedError {
  case invalidStep(String)
  case commandFailed(command: String, exitCode: Int32, stderr: String)

  var errorDescription: String? {
    switch self {
    case .invalidStep(let message):
      return "Invalid step: \(message)"
    case .commandFailed(let command, let exitCode, let stderr):
      let prefix = command.prefix(100)
      let truncated = command.count > 100 ? "\(prefix)..." : String(prefix)
      return "Command '\(truncated)' failed with exit code \(exitCode): \(stderr.prefix(500))"
    }
  }
}
