import Foundation

// MARK: - Jeballtofile Request Models

/// A Jeballtofile blueprint for automated VM creation and setup
struct JeballtofileRequest: Codable {
  let name: String
  let source: String?
  let resources: VMResourcesDTO?
  let steps: [JeballtofileStep]

  func validate() -> (valid: Bool, error: String?) {
    guard VMNameValidator.validate(name) else {
      return (false, "Invalid VM name. Must be 1-100 characters, alphanumeric, hyphens, underscores, spaces, and dots")
    }

    if steps.isEmpty {
      return (false, "'steps' array must not be empty")
    }

    let hasInstallStep = steps.contains { $0.type == .install }
    if hasInstallStep {
      guard let source, !source.isEmpty else {
        return (false, "'source' is required when steps contain an 'install' step")
      }
      let installRequest = InstallVMRequest(source: source)
      let sourceValidation = installRequest.validate()
      if !sourceValidation.valid {
        return (false, "Invalid source: \(sourceValidation.error ?? "unknown error")")
      }
    }

    for (index, step) in steps.enumerated() {
      let stepValidation = step.validate()
      if !stepValidation.valid {
        return (false, "Step \(index): \(stepValidation.error ?? "unknown error")")
      }
    }

    return (true, nil)
  }
}

/// A single step in a Jeballtofile blueprint
struct JeballtofileStep: Codable {
  let type: JeballtofileStepType
  let keystrokes: [String]?
  let command: String?
  let user: String?
  let password: String?
  let timeout: Int?
  let seconds: Int?

  func validate() -> (valid: Bool, error: String?) {
    switch type {
    case .install, .start, .stop, .guiOpen, .guiClose:
      return (true, nil)

    case .keystrokes:
      guard let keystrokes, !keystrokes.isEmpty else {
        return (false, "'keystrokes' array is required and must not be empty for 'keystrokes' step")
      }
      if keystrokes.count > 1000 {
        return (false, "Too many keystroke sequences (max 1000)")
      }
      for seq in keystrokes where seq.count > 10000 {
        return (false, "Keystroke sequence too long (max 10000 characters)")
      }
      return (true, nil)

    case .execute:
      guard let command, !command.isEmpty else {
        return (false, "'command' is required and must not be empty for 'execute' step")
      }
      if command.count > CommandExecutor.maxCommandLength {
        return (false, "Command too long (max \(CommandExecutor.maxCommandLength) characters)")
      }
      if let t = timeout {
        if t <= 0 { return (false, "Timeout must be positive") }
        if t > 600 { return (false, "Timeout must not exceed 600 seconds") }
      }
      return (true, nil)

    case .wait:
      guard let seconds else {
        return (false, "'seconds' is required for 'wait' step")
      }
      if seconds < 1 || seconds > 300 {
        return (false, "'seconds' must be between 1 and 300")
      }
      return (true, nil)
    }
  }
}

enum JeballtofileStepType: String, Codable {
  case install
  case start
  case stop
  case guiOpen = "gui-open"
  case guiClose = "gui-close"
  case keystrokes
  case execute
  case wait
}

// MARK: - Jeballtofile Response Models

/// Immediate response when a Jeballtofile execution is created (202 Accepted)
struct JeballtofileResponse: Codable {
  let id: String
  let vmId: String
  let status: String
  let currentStep: Int
  let totalSteps: Int
  let message: String

  init(executionId: UUID, vmId: UUID, totalSteps: Int) {
    id = executionId.uuidString
    self.vmId = vmId.uuidString
    status = "running"
    currentStep = 0
    self.totalSteps = totalSteps
    message = "Jeballtofile execution started"
  }
}

/// Status response for polling a Jeballtofile execution
struct JeballtofileStatusResponse: Codable {
  let id: String
  let vmId: String
  let status: String
  let currentStep: Int
  let totalSteps: Int
  let stepResults: [JeballtofileStepResultDTO]
  let error: String?

  init(from execution: JeballtofileExecution) {
    id = execution.id.uuidString
    vmId = execution.vmId.uuidString
    status = execution.status.rawValue
    currentStep = execution.currentStep
    totalSteps = execution.totalSteps
    stepResults = execution.stepResults.map { JeballtofileStepResultDTO(from: $0) }
    error = execution.error
  }
}

/// Per-step result in the status response
struct JeballtofileStepResultDTO: Codable {
  let step: Int
  let type: String
  let status: String
  let message: String?

  init(from result: JeballtofileStepResult) {
    step = result.step
    type = result.stepType.rawValue
    status = result.status.rawValue
    message = result.message
  }
}

/// List response for Jeballtofile executions
struct JeballtofileListResponse: Codable {
  let executions: [JeballtofileStatusResponse]
  let total: Int
}

// MARK: - Execution State Models (internal, not DTOs)

/// Tracks the state of a single Jeballtofile execution
class JeballtofileExecution: @unchecked Sendable {
  let id: UUID
  let vmId: UUID
  let totalSteps: Int
  private let lock = NSLock()

  private var _status: JeballtofileExecutionStatus = .running
  private var _currentStep: Int = 0
  private var _stepResults: [JeballtofileStepResult] = []
  private var _error: String?
  private var _cancelled: Bool = false

  var status: JeballtofileExecutionStatus {
    lock.lock()
    defer { lock.unlock() }
    return _status
  }

  var currentStep: Int {
    lock.lock()
    defer { lock.unlock() }
    return _currentStep
  }

  var stepResults: [JeballtofileStepResult] {
    lock.lock()
    defer { lock.unlock() }
    return _stepResults
  }

  var error: String? {
    lock.lock()
    defer { lock.unlock() }
    return _error
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _cancelled
  }

  init(id: UUID, vmId: UUID, totalSteps: Int) {
    self.id = id
    self.vmId = vmId
    self.totalSteps = totalSteps
  }

  func startStep(_ index: Int, type: JeballtofileStepType) {
    lock.lock()
    defer { lock.unlock() }
    _currentStep = index
    _stepResults.append(JeballtofileStepResult(step: index, stepType: type, status: .inProgress, message: nil))
  }

  func completeStep(_ index: Int, message: String?) {
    lock.lock()
    defer { lock.unlock() }
    if let i = _stepResults.firstIndex(where: { $0.step == index }) {
      _stepResults[i].status = .completed
      _stepResults[i].message = message
    }
  }

  func failStep(_ index: Int, error: String) {
    lock.lock()
    defer { lock.unlock() }
    if let i = _stepResults.firstIndex(where: { $0.step == index }) {
      _stepResults[i].status = .failed
      _stepResults[i].message = error
    }
    _status = .failed
    _error = "Step \(index) failed: \(error)"
  }

  func cancelStep(_ index: Int, message: String) {
    lock.lock()
    defer { lock.unlock() }
    if let i = _stepResults.firstIndex(where: { $0.step == index }) {
      _stepResults[i].status = .cancelled
      _stepResults[i].message = message
    }
    _cancelled = true
    _status = .cancelled
    _error = nil
  }

  func complete() {
    lock.lock()
    defer { lock.unlock() }
    _status = .completed
  }

  func fail(_ error: String) {
    lock.lock()
    defer { lock.unlock() }
    _status = .failed
    _error = error
  }

  func cancel() {
    lock.lock()
    defer { lock.unlock() }
    if let i = _stepResults.firstIndex(where: { $0.status == .inProgress }) {
      _stepResults[i].status = .cancelled
      _stepResults[i].message = "Cancelled by user"
    }
    _cancelled = true
    _status = .cancelled
  }
}

enum JeballtofileExecutionStatus: String, Codable {
  case running
  case completed
  case failed
  case cancelled
}

struct JeballtofileStepResult {
  let step: Int
  let stepType: JeballtofileStepType
  var status: JeballtofileStepResultStatus
  var message: String?
}

enum JeballtofileStepResultStatus: String, Codable {
  case inProgress = "in_progress"
  case completed
  case cancelled
  case failed
}
