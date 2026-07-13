import Foundation
import Network

final class HTTPConnectionSlot: @unchecked Sendable {
  private let lock = NSLock()
  private var didRelease = false
  private let onRelease: @Sendable () -> Void

  init(onRelease: @escaping @Sendable () -> Void) {
    self.onRelease = onRelease
  }

  func release() {
    lock.lock()
    guard didRelease == false else {
      lock.unlock()
      return
    }
    didRelease = true
    lock.unlock()
    onRelease()
  }
}

final class HTTPConnectionContext: @unchecked Sendable {
  private let lock = NSLock()
  private let connection: NWConnection
  private let cancelConnection: @Sendable () -> Void
  private let slot: HTTPConnectionSlot
  private let onFinish: @Sendable () -> Void
  private var cancellationRequested = false
  private var connectionCancelled = false
  private var finished = false
  private var handlerTask: Task<Void, Never>?

  init(
    connection: NWConnection,
    slot: HTTPConnectionSlot,
    cancelConnection: (@Sendable () -> Void)? = nil,
    onFinish: @escaping @Sendable () -> Void
  ) {
    self.connection = connection
    self.cancelConnection = cancelConnection ?? { connection.cancel() }
    self.slot = slot
    self.onFinish = onFinish
  }

  var isCancellationRequested: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancellationRequested
  }

  /// Installs a handler atomically with cancellation. The task may start immediately,
  /// but its first cancellation check waits for this method to release `lock`.
  func installHandlerTask(_ create: () -> Task<Void, Never>) -> Task<Void, Never>? {
    lock.lock()
    defer { lock.unlock() }
    guard cancellationRequested == false, finished == false, handlerTask == nil else { return nil }
    let task = create()
    handlerTask = task
    return task
  }

  /// Cancels connection I/O and the route task. A route task owns final cleanup until it returns.
  @discardableResult
  func requestCancellation() -> Task<Void, Never>? {
    lock.lock()
    guard finished == false else {
      lock.unlock()
      return nil
    }
    cancellationRequested = true
    let task = handlerTask
    let shouldCancelConnection = connectionCancelled == false
    connectionCancelled = true
    lock.unlock()

    task?.cancel()
    if shouldCancelConnection { cancelConnection() }
    if task == nil { finish() }
    return task
  }

  func finish() {
    lock.lock()
    guard finished == false else {
      lock.unlock()
      return
    }
    finished = true
    handlerTask = nil
    let shouldCancelConnection = connectionCancelled == false
    connectionCancelled = true
    lock.unlock()

    slot.release()
    if shouldCancelConnection { cancelConnection() }
    onFinish()
  }
}
