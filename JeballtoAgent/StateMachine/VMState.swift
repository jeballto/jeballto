import Foundation

/// VM state - maps 1:1 with VZVirtualMachine states plus lifecycle states
enum VMState: String, Codable, CaseIterable {
  /// Created with disk and config files but macOS not yet installed.
  case created
  /// macOS installation in progress. VM is booted into the installer.
  case installing
  /// macOS is installed and the VM is not running.
  case stopped
  /// VM boot in progress.
  case starting
  /// VM is fully booted and operational.
  case running
  /// Shutdown in progress.
  case stopping
  /// State save in progress.
  case pausing
  /// VM state saved to disk. Can be resumed from exactly this point.
  case paused
  /// Restoring VM from saved state.
  case resuming
  /// VM encountered an unrecoverable error. Can transition to stopped or deleted.
  case error
  /// VM files removed. Terminal state - no further transitions are possible.
  case deleted
}

/// Represents a validated state transition for logging and event publishing.
struct VMStateTransition: Equatable {
  let from: VMState
  let to: VMState
}

extension VMState {
  var validTransitions: [VMState] {
    switch self {
    case .created: [.installing, .starting, .error, .deleted]
    case .installing: [.stopped, .starting, .error, .deleted]
    case .stopped: [.starting, .deleted, .error]
    case .starting: [.running, .paused, .error]
    case .running: [.stopping, .pausing, .error]
    case .stopping: [.stopped, .error]
    case .pausing: [.paused, .error]
    case .paused: [.resuming, .starting, .stopping, .error]
    case .resuming: [.running, .error]
    case .error: [.stopped, .deleted]
    case .deleted: []
    }
  }

  /// Returns true if transitioning to `targetState` is permitted from the current state.
  func canTransition(to targetState: VMState) -> Bool { validTransitions.contains(targetState) }

  /// True only for `deleted`. Once deleted, no further state changes are possible.
  var isTerminal: Bool { self == .deleted }

  /// True when the VM is usable: `running` or `paused`.
  var isOperational: Bool { self == .running || self == .paused }
}
