import Foundation

/// Errors that can occur during state transitions
enum VMStateMachineError: Error, LocalizedError {
  case invalidTransition(from: VMState, to: VMState)
  case terminalStateReached(VMState)
  case alreadyInTargetState(VMState)

  var errorDescription: String? {
    switch self {
    case .invalidTransition(let from, let to): "Invalid state transition from \(from.rawValue) to \(to.rawValue)"
    case .terminalStateReached(let state): "Cannot transition from terminal state \(state.rawValue)"
    case .alreadyInTargetState(let state): "VM is already in state \(state.rawValue)"
    }
  }
}

/// State machine that manages and enforces VM state transitions
/// Thread-safe: all state access is synchronized via an internal lock.
final class VMStateMachine {
  /// Lock for thread-safe state access
  private let lock = NSRecursiveLock()

  /// Current state of the VM (access synchronized via lock)
  private var _currentState: VMState

  /// Thread-safe accessor for current state
  var currentState: VMState {
    lock.lock()
    defer { lock.unlock() }
    return _currentState
  }

  /// History of state transitions for debugging and auditing
  private var _transitionHistory: [VMStateTransition] = []

  /// Thread-safe accessor for transition history
  var transitionHistory: [VMStateTransition] {
    lock.lock()
    defer { lock.unlock() }
    return _transitionHistory
  }

  /// Maximum number of transitions to keep in history
  private let maxHistorySize: Int

  init(initialState: VMState = .created, maxHistorySize: Int = 100) {
    _currentState = initialState
    self.maxHistorySize = max(0, maxHistorySize)
  }

  /// Attempts to transition to a new state
  /// - Parameter targetState: The desired state to transition to
  /// - Throws: VMStateMachineError if the transition is invalid
  /// - Returns: The new current state after successful transition
  @discardableResult func transition(to targetState: VMState) throws -> VMState {
    lock.lock()
    defer { lock.unlock() }

    // Check if already in target state
    guard _currentState != targetState else { throw VMStateMachineError.alreadyInTargetState(targetState) }

    // Check if current state is terminal
    guard !_currentState.isTerminal else { throw VMStateMachineError.terminalStateReached(_currentState) }

    // Validate transition
    guard _currentState.canTransition(to: targetState) else {
      throw VMStateMachineError.invalidTransition(from: _currentState, to: targetState)
    }

    // Perform transition
    let transition = VMStateTransition(from: _currentState, to: targetState)
    _currentState = targetState

    // Record in history
    addToHistoryLocked(transition)

    return _currentState
  }

  /// Forces a state change without validation (use with caution, primarily for error recovery)
  /// - Parameter newState: The state to force
  func forceState(_ newState: VMState) {
    lock.lock()
    defer { lock.unlock() }
    guard _currentState != newState else { return }
    let transition = VMStateTransition(from: _currentState, to: newState)
    _currentState = newState
    addToHistoryLocked(transition)
  }

  /// Checks if a transition to the target state is valid
  /// - Parameter targetState: The state to check
  /// - Returns: true if the transition is allowed, false otherwise
  func canTransition(to targetState: VMState) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard _currentState != targetState else { return false }
    guard !_currentState.isTerminal else { return false }
    return _currentState.canTransition(to: targetState)
  }

  /// Resets the state machine to a specific state (primarily for testing)
  /// - Parameter state: The state to reset to
  func reset(to state: VMState = .created) {
    lock.lock()
    defer { lock.unlock() }
    _currentState = state
    _transitionHistory.removeAll()
  }

  // MARK: - Private Methods

  /// Must be called while holding the lock
  private func addToHistoryLocked(_ transition: VMStateTransition) {
    _transitionHistory.append(transition)

    // Trim history if it exceeds max size
    if _transitionHistory.count > maxHistorySize {
      _transitionHistory.removeFirst(_transitionHistory.count - maxHistorySize)
    }
  }

  /// Returns a formatted string of the transition history
  func getTransitionHistoryDescription() -> String {
    lock.lock()
    defer { lock.unlock() }
    return _transitionHistory.map { "\($0.from.rawValue) -> \($0.to.rawValue)" }.joined(separator: "\n")
  }
}

extension VMStateMachine: @unchecked Sendable {}
