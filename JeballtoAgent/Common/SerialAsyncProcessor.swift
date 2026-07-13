import Foundation

/// Executes submitted asynchronous operations in submission order.
final class SerialAsyncProcessor: @unchecked Sendable {
  private let lock = NSLock()
  private var tail: Task<Void, Never>?

  func submit(_ operation: @escaping @Sendable () async -> Void) {
    lock.withLock {
      let previous = tail
      let next = Task<Void, Never> {
        if let previous {
          await previous.value
        }
        guard Task.isCancelled == false else { return }
        await operation()
      }
      tail = next
    }
  }

  func waitUntilIdle() async {
    let current = lock.withLock { tail }
    await current?.value
  }

  func cancel() {
    let current = lock.withLock {
      let current = tail
      tail = nil
      return current
    }
    current?.cancel()
  }
}
