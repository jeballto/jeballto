import Foundation

actor KeyedOperationGate {
  private var activeKeys: Set<String> = []
  private var waiters: [String: [(id: UUID, continuation: CheckedContinuation<Void, Error>)]] = [:]

  func withExclusiveAccess<T: Sendable>(
    for key: String,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    try await acquire(key)
    defer { release(key) }
    try Task.checkCancellation()
    return try await operation()
  }

  private func acquire(_ key: String) async throws {
    try Task.checkCancellation()
    if activeKeys.contains(key) == false {
      activeKeys.insert(key)
      return
    }

    let waiterId = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters[key, default: []].append((waiterId, continuation))
        }
      }
    } onCancel: {
      Task<Void, Never> { await self.cancelWaiter(waiterId, for: key) }
    }
  }

  private func release(_ key: String) {
    if var keyWaiters = waiters[key], keyWaiters.isEmpty == false {
      let waiter = keyWaiters.removeFirst()
      if keyWaiters.isEmpty {
        waiters.removeValue(forKey: key)
      } else {
        waiters[key] = keyWaiters
      }
      waiter.continuation.resume()
      return
    }
    activeKeys.remove(key)
  }

  private func cancelWaiter(_ id: UUID, for key: String) {
    guard var keyWaiters = waiters[key],
          let index = keyWaiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = keyWaiters.remove(at: index)
    if keyWaiters.isEmpty {
      waiters.removeValue(forKey: key)
    } else {
      waiters[key] = keyWaiters
    }
    waiter.continuation.resume(throwing: CancellationError())
  }
}
