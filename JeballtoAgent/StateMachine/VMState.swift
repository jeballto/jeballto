import Foundation

/// Durable VM lifecycle state, including states that have no direct Virtualization framework equivalent.
enum VMState: String, Codable, CaseIterable, Sendable {
  /// Definition and empty bundle created, but installation artifacts and macOS are not present yet.
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
  /// Pause operation in progress.
  case pausing
  /// VM execution is paused. A save file exists only for shutdown recovery pauses.
  case paused
  /// Resuming live paused execution or restoring a shutdown recovery save.
  case resuming
  /// VM encountered an error. Recovery returns an installed VM to stopped or an incomplete install to created.
  case error
  /// VM files removed. Terminal state - no further transitions are possible.
  case deleted
}

/// Represents a validated state transition for logging and event publishing.
struct VMStateTransition: Equatable, Sendable {
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
    case .error: [.created, .stopped, .deleted]
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
