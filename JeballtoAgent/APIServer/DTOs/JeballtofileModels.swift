import Foundation

// MARK: - Jeballtofile Request Models

/// A Jeballtofile blueprint for automated VM creation and setup
struct JeballtofileRequest: Codable {
  static let maximumSteps = 1000

  let name: String
  let source: String?
  let resources: VMResourcesDTO?
  let steps: [JeballtofileStep]

  func validate() -> (valid: Bool, error: String?) {
    let error = structureValidationError()
      ?? sourceValidationError()
      ?? resourceValidationError()
      ?? stepValidationError()
      ?? lifecycleValidationError()
    return (error == nil, error)
  }

  private func structureValidationError() -> String? {
    guard VMNameValidator.validate(name) else {
      return "Invalid VM name. Must be 1-100 characters, alphanumeric, hyphens, underscores, spaces, and dots"
    }
    if steps.isEmpty {
      return "'steps' array must not be empty"
    }
    if steps.count > Self.maximumSteps {
      return "Too many steps (max \(Self.maximumSteps))"
    }
    if steps.count(where: { $0.type == .install }) > 1 {
      return "A Jeballtofile can contain at most one 'install' step"
    }
    return nil
  }

  private func sourceValidationError() -> String? {
    guard let source else { return nil }
    guard source.isEmpty == false else {
      return "'source' must not be empty when provided; omit it to download the latest macOS"
    }
    guard steps.count(where: { $0.type == .install }) == 1 else {
      return "'source' requires an 'install' step"
    }
    let validation = InstallVMRequest(source: source).validate()
    return validation.valid ? nil : "Invalid source: \(validation.error ?? "unknown error")"
  }

  private func resourceValidationError() -> String? {
    guard let resources, resources.toVMResources().validate() == false else { return nil }
    return "Invalid resources: CPU count 1-32, memory 2GB-128GB, disk 20GB-8TB"
  }

  private func stepValidationError() -> String? {
    for (index, step) in steps.enumerated() {
      let validation = step.validate()
      if validation.valid == false {
        return "Step \(index): \(validation.error ?? "unknown error")"
      }
    }
    return nil
  }

  private func lifecycleValidationError() -> String? {
    var state = JeballtofileValidationState.created
    for (index, step) in steps.enumerated() {
      let rule = step.type.lifecycleRule
      if let requiredState = rule.requiredState, requiredState != state {
        return "Step \(index): \(rule.errorMessage)"
      }
      if let resultingState = rule.resultingState {
        state = resultingState
      }
    }
    return nil
  }
}

private struct JeballtofileLifecycleRule {
  let requiredState: JeballtofileValidationState?
  let resultingState: JeballtofileValidationState?
  let errorMessage: String
}

private extension JeballtofileStepType {
  var lifecycleRule: JeballtofileLifecycleRule {
    switch self {
    case .install:
      JeballtofileLifecycleRule(
        requiredState: .created,
        resultingState: .stopped,
        errorMessage: "'install' requires a newly created VM"
      )
    case .start:
      JeballtofileLifecycleRule(
        requiredState: .stopped,
        resultingState: .running,
        errorMessage: "'start' requires an installed, stopped VM"
      )
    case .stop:
      JeballtofileLifecycleRule(
        requiredState: .running,
        resultingState: .stopped,
        errorMessage: "'stop' requires a running VM"
      )
    case .guiOpen, .keystrokes, .execute:
      JeballtofileLifecycleRule(
        requiredState: .running,
        resultingState: nil,
        errorMessage: "'\(rawValue)' requires a running VM"
      )
    case .guiClose, .wait:
      JeballtofileLifecycleRule(requiredState: nil, resultingState: nil, errorMessage: "")
    }
  }
}

private enum JeballtofileValidationState {
  case created
  case stopped
  case running
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
      return rejectUnexpectedFields(allowed: [])

    case .keystrokes:
      let fieldValidation = rejectUnexpectedFields(allowed: ["keystrokes"])
      guard fieldValidation.valid else { return fieldValidation }
      guard let keystrokes, !keystrokes.isEmpty else {
        return (false, "'keystrokes' array is required and must not be empty for 'keystrokes' step")
      }
      return KeystrokeSequenceValidator.validate(keystrokes)

    case .execute:
      let fieldValidation = rejectUnexpectedFields(allowed: ["command", "user", "password", "timeout"])
      guard fieldValidation.valid else { return fieldValidation }
      guard let command, !command.isEmpty else {
        return (false, "'command' is required and must not be empty for 'execute' step")
      }
      if command.utf8.count > CommandExecutor.maxCommandLength {
        return (false, "Command too long (max \(CommandExecutor.maxCommandLength) UTF-8 bytes)")
      }
      if let t = timeout {
        if t <= 0 { return (false, "Timeout must be positive") }
        if t > 600 { return (false, "Timeout must not exceed 600 seconds") }
      }
      if let user, !SSHUsernameValidator.validate(user) {
        return (false, SSHUsernameValidator.validationError)
      }
      if let password, let validationError = CommandExecutor.passwordValidationError(password) {
        return (false, validationError)
      }
      return (true, nil)

    case .wait:
      let fieldValidation = rejectUnexpectedFields(allowed: ["seconds"])
      guard fieldValidation.valid else { return fieldValidation }
      guard let seconds else {
        return (false, "'seconds' is required for 'wait' step")
      }
      if seconds < 1 || seconds > 300 {
        return (false, "'seconds' must be between 1 and 300")
      }
      return (true, nil)
    }
  }

  private func rejectUnexpectedFields(allowed: Set<String>) -> (valid: Bool, error: String?) {
    let suppliedFields: [(String, Bool)] = [
      ("keystrokes", keystrokes != nil),
      ("command", command != nil),
      ("user", user != nil),
      ("password", password != nil),
      ("timeout", timeout != nil),
      ("seconds", seconds != nil),
    ]
    let unexpected = suppliedFields.compactMap { field, supplied in
      supplied && allowed.contains(field) == false ? field : nil
    }
    guard unexpected.isEmpty else {
      return (false, "Field(s) \(unexpected.joined(separator: ", ")) are not valid for '\(type.rawValue)' step")
    }
    return (true, nil)
  }
}

enum JeballtofileStepType: String, Codable, Sendable {
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
    let snapshot = execution.snapshot()
    id = execution.id.uuidString
    vmId = execution.vmId.uuidString
    status = snapshot.status.rawValue
    currentStep = snapshot.currentStep
    totalSteps = execution.totalSteps
    stepResults = snapshot.stepResults.map { JeballtofileStepResultDTO(from: $0) }
    error = snapshot.error
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
  struct Snapshot: Sendable {
    let status: JeballtofileExecutionStatus
    let currentStep: Int
    let stepResults: [JeballtofileStepResult]
    let error: String?
  }

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

  func snapshot() -> Snapshot {
    lock.lock()
    defer { lock.unlock() }
    return Snapshot(
      status: _status,
      currentStep: _currentStep,
      stepResults: _stepResults,
      error: _error
    )
  }

  @discardableResult
  func startStep(_ index: Int, type: JeballtofileStepType) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard _status == .running else { return false }
    _currentStep = index
    _stepResults.append(JeballtofileStepResult(step: index, stepType: type, status: .inProgress, message: nil))
    return true
  }

  @discardableResult
  func completeStep(_ index: Int, message: String?) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard _status == .running else { return false }
    if let i = _stepResults.firstIndex(where: { $0.step == index }) {
      _stepResults[i].status = .completed
      _stepResults[i].message = message
    }
    return true
  }

  @discardableResult
  func failStep(_ index: Int, error: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard _status == .running else { return false }
    if let i = _stepResults.firstIndex(where: { $0.step == index }) {
      _stepResults[i].status = .failed
      _stepResults[i].message = error
    }
    _status = .failed
    _error = "Step \(index) failed: \(error)"
    return true
  }

  @discardableResult
  func cancelStep(_ index: Int, message: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard _status == .running else { return false }
    if let i = _stepResults.firstIndex(where: { $0.step == index }) {
      _stepResults[i].status = .cancelled
      _stepResults[i].message = message
    }
    _cancelled = true
    _status = .cancelled
    _error = nil
    return true
  }

  @discardableResult
  func complete() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard _status == .running else { return false }
    _status = .completed
    return true
  }

  @discardableResult
  func fail(_ error: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard _status == .running else { return false }
    _status = .failed
    _error = error
    return true
  }

  @discardableResult
  func cancel() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard _status == .running else { return false }
    if let i = _stepResults.firstIndex(where: { $0.status == .inProgress }) {
      _stepResults[i].status = .cancelled
      _stepResults[i].message = "Cancelled by user"
    }
    _cancelled = true
    _status = .cancelled
    _error = nil
    return true
  }
}

enum JeballtofileExecutionStatus: String, Codable, Sendable {
  case running
  case completed
  case failed
  case cancelled
}

struct JeballtofileStepResult: Sendable {
  let step: Int
  let stepType: JeballtofileStepType
  var status: JeballtofileStepResultStatus
  var message: String?
}

enum JeballtofileStepResultStatus: String, Codable, Sendable {
  case inProgress = "in_progress"
  case completed
  case cancelled
  case failed
}
