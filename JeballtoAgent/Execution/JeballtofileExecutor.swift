import Foundation

/// Orchestrates the execution of a Jeballtofile blueprint step by step
class JeballtofileExecutor {
  let execution: JeballtofileExecution
  private let steps: [JeballtofileStep]
  private let source: String?
  private let vmManager: VMManager
  private let eventBus: EventBus
  private var task: Task<Void, Never>?

  init(
    execution: JeballtofileExecution,
    steps: [JeballtofileStep],
    source: String?,
    vmManager: VMManager,
    eventBus: EventBus
  ) {
    self.execution = execution
    self.steps = steps
    self.source = source
    self.vmManager = vmManager
    self.eventBus = eventBus
  }

  /// Starts asynchronous execution of all steps
  func start() {
    task = Task<Void, Never> { [weak self] in
      await self?.run()
    }
  }

  /// Cancels execution and marks the current step as cancelled when the task observes cancellation.
  func cancel() {
    execution.cancel()
    task?.cancel()
  }

  func waitUntilFinished() async {
    await task?.value
  }

  private func run() async {
    let executionId = execution.id
    let vmId = execution.vmId

    eventBus.publish(.jeballtofileStarted(executionId: executionId, vmId: vmId))
    logInfo("Jeballtofile execution \(executionId) started for VM \(vmId)", category: "Jeballtofile")

    for (index, step) in steps.enumerated() {
      if execution.isCancelled {
        publishCancellation(executionId: executionId, vmId: vmId, step: index)
        return
      }

      execution.startStep(index, type: step.type)
      eventBus.publish(.jeballtofileStepStarted(executionId: executionId, step: index, stepType: step.type.rawValue))
      logInfo(
        "Jeballtofile \(executionId) step \(index): \(step.type.rawValue)",
        category: "Jeballtofile"
      )

      do {
        let message = try await executeStep(step, vmId: vmId)
        execution.completeStep(index, message: message)
        eventBus.publish(.jeballtofileStepCompleted(
          executionId: executionId, step: index, stepType: step.type.rawValue
        ))
      } catch is CancellationError {
        execution.cancelStep(index, message: "Cancelled by user")
        publishCancellation(executionId: executionId, vmId: vmId, step: index)
        return
      } catch {
        let errorMessage = error.localizedDescription
        execution.failStep(index, error: errorMessage)
        eventBus.publish(.jeballtofileStepFailed(
          executionId: executionId, step: index, stepType: step.type.rawValue, error: errorMessage
        ))
        eventBus.publish(.jeballtofileFailed(
          executionId: executionId, vmId: vmId, step: index, error: errorMessage
        ))
        logError(
          "Jeballtofile \(executionId) failed at step \(index) (\(step.type.rawValue)): \(errorMessage)",
          category: "Jeballtofile"
        )
        return
      }
    }

    execution.complete()
    eventBus.publish(.jeballtofileCompleted(executionId: executionId, vmId: vmId))
    logInfo("Jeballtofile execution \(executionId) completed successfully", category: "Jeballtofile")
  }

  private func publishCancellation(executionId: UUID, vmId: UUID, step: Int) {
    logInfo("Jeballtofile execution \(executionId) cancelled at step \(step)", category: "Jeballtofile")
    eventBus.publish(.jeballtofileCancelled(executionId: executionId, vmId: vmId, step: step))
  }

  private func executeStep(_ step: JeballtofileStep, vmId: UUID) async throws -> String {
    switch step.type {
    case .install:
      let effectiveSource = resolveIPSWSource(source)
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
      let password = step.password ?? "admin"
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
  private func resolveIPSWSource(_ source: String?) -> String? {
    guard let source, !source.isEmpty else { return nil }
    if let url = URL(string: source), url.scheme?.lowercased() == "file" {
      return url.path
    }
    return source
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
