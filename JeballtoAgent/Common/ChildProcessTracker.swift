import Darwin
import Foundation

/// Tracks running child processes (oras, tar, etc.) so they can be terminated
/// on app shutdown or Task cancellation.
///
/// Usage:
/// - Register a process immediately after a successful launch: `ChildProcessTracker.shared.track(process)`
/// - Unregister from its termination handler: `ChildProcessTracker.shared.untrack(process)`
/// - On shutdown: `ChildProcessTracker.shared.terminateAll()`
final class ChildProcessTracker: @unchecked Sendable {
  static let shared = ChildProcessTracker()

  private static let forceKillDelayNanoseconds: UInt64 = 1_000_000_000

  private enum ShutdownState: Equatable {
    case running
    case terminating
    case forceKilling
  }

  private let lock = NSLock()
  private var processes: Set<ObjectWrapper> = []
  private var shutdownState = ShutdownState.running

  init() {}

  var trackedProcessCount: Int {
    lock.withLock { processes.count }
  }

  /// Registers a running process for tracking.
  /// Processes launched during shutdown are terminated immediately.
  func track(_ process: Process) {
    let wrapper = ObjectWrapper(process)
    let state = lock.withLock {
      processes.insert(wrapper)
      return shutdownState
    }

    guard process.isRunning else {
      untrack(process)
      return
    }

    switch state {
    case .running:
      break
    case .terminating:
      terminate(process, scheduleForceKill: false)
    case .forceKilling:
      forceKill(process)
    }
  }

  /// Removes a process after its termination handler has observed process exit.
  func untrack(_ process: Process) {
    let wrapper = ObjectWrapper(process)
    lock.withLock { () in
      _ = processes.remove(wrapper)
    }
  }

  /// Starts shutdown and sends SIGTERM to all tracked child processes.
  /// Processes remain tracked until their termination handlers call `untrack`.
  func terminateAll() {
    let current = lock.withLock { () -> Set<ObjectWrapper> in
      if shutdownState == .running {
        shutdownState = .terminating
      }
      return processes
    }

    for wrapper in current {
      terminate(wrapper.process, scheduleForceKill: false)
    }
  }

  /// Synchronously sends SIGKILL to every process that is still tracked.
  /// New processes tracked after this point are also killed immediately.
  func forceKillAll() {
    let current = lock.withLock { () -> Set<ObjectWrapper> in
      shutdownState = .forceKilling
      return processes
    }

    for wrapper in current {
      forceKill(wrapper.process)
    }
  }

  /// Terminates a specific tracked process, for example on Task cancellation.
  /// The process remains tracked until its termination handler observes exit.
  func terminateIfRunning(_ process: Process) {
    terminate(process, scheduleForceKill: true)
  }

  private func terminate(_ process: Process, scheduleForceKill: Bool) {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    logInfo("Terminating child process (pid \(pid))", category: "ChildProcessTracker")
    process.terminate()
    if scheduleForceKill {
      scheduleForceKillIfNeeded(process)
    }
  }

  private func forceKill(_ process: Process) {
    guard process.isRunning else { return }
    let pid = process.processIdentifier
    logWarning("Force killing child process (pid \(pid))", category: "ChildProcessTracker")
    guard kill(pid, SIGKILL) != -1 || errno == ESRCH else {
      logWarning(
        "Failed to force kill child process (pid \(pid)): \(String(cString: strerror(errno)))",
        category: "ChildProcessTracker"
      )
      return
    }
  }

  private func scheduleForceKillIfNeeded(_ process: Process) {
    Task<Void, Never>.detached { [self] in
      try? await Task.sleep(nanoseconds: Self.forceKillDelayNanoseconds)
      forceKill(process)
    }
  }
}

// MARK: - Hashable wrapper for Process (reference identity)

private final class ObjectWrapper: Hashable {
  let process: Process

  init(_ process: Process) {
    self.process = process
  }

  static func == (lhs: ObjectWrapper, rhs: ObjectWrapper) -> Bool {
    lhs.process === rhs.process
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(process))
  }
}
