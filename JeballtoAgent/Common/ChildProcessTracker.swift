import Darwin
import Foundation

/// Tracks running child processes (oras, tar, etc.) so they can be terminated
/// on app shutdown or Task cancellation.
///
/// Usage:
/// - Register a process before it runs: `ChildProcessTracker.shared.track(process)`
/// - Unregister when done: `ChildProcessTracker.shared.untrack(process)`
/// - On shutdown: `ChildProcessTracker.shared.terminateAll()`
final class ChildProcessTracker: @unchecked Sendable {
  static let shared = ChildProcessTracker()

  private static let forceKillDelayNanoseconds: UInt64 = 1_000_000_000

  private let lock = NSLock()
  private var processes: Set<ObjectWrapper> = []

  private init() {}

  /// Registers a running process for tracking
  func track(_ process: Process) {
    let wrapper = ObjectWrapper(process)
    lock.lock()
    processes.insert(wrapper)
    lock.unlock()
  }

  /// Removes a process from tracking (call when process completes normally)
  func untrack(_ process: Process) {
    let wrapper = ObjectWrapper(process)
    lock.lock()
    processes.remove(wrapper)
    lock.unlock()
  }

  /// Terminates all tracked child processes. Called on app shutdown.
  func terminateAll() {
    lock.lock()
    let current = processes
    processes.removeAll()
    lock.unlock()

    for wrapper in current where wrapper.process.isRunning {
      logInfo("Terminating child process (pid \(wrapper.process.processIdentifier))", category: "ChildProcessTracker")
      wrapper.process.terminate()
      scheduleForceKillIfNeeded(wrapper.process)
    }
  }

  /// Terminates a specific tracked process (e.g. on Task cancellation)
  func terminateIfRunning(_ process: Process) {
    if process.isRunning {
      logInfo("Cancelling child process (pid \(process.processIdentifier))", category: "ChildProcessTracker")
      process.terminate()
      scheduleForceKillIfNeeded(process)
    }
    untrack(process)
  }

  private func scheduleForceKillIfNeeded(_ process: Process) {
    let pid = process.processIdentifier
    Task<Void, Never>.detached {
      try? await Task.sleep(nanoseconds: Self.forceKillDelayNanoseconds)
      guard process.isRunning else { return }
      logWarning("Force killing child process (pid \(pid))", category: "ChildProcessTracker")
      kill(pid, SIGKILL)
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
