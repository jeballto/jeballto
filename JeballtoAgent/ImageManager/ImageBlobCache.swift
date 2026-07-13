import Foundation

actor ImageBlobCache {
  private var activeDigests: Set<String> = []
  private var waiters: [String: [(id: UUID, continuation: CheckedContinuation<Void, Error>)]] = [:]

  func withExclusiveAccess<T: Sendable>(
    for digest: String,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    try await acquire(digest)
    defer { release(digest) }
    try Task.checkCancellation()
    return try await operation()
  }

  private func acquire(_ digest: String) async throws {
    try Task.checkCancellation()
    if activeDigests.contains(digest) == false {
      activeDigests.insert(digest)
      return
    }

    let waiterId = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters[digest, default: []].append((waiterId, continuation))
        }
      }
    } onCancel: {
      Task<Void, Never> { await self.cancelWaiter(waiterId, for: digest) }
    }
  }

  private func release(_ digest: String) {
    if var digestWaiters = waiters[digest], digestWaiters.isEmpty == false {
      let waiter = digestWaiters.removeFirst()
      if digestWaiters.isEmpty {
        waiters.removeValue(forKey: digest)
      } else {
        waiters[digest] = digestWaiters
      }
      waiter.continuation.resume()
      return
    }
    activeDigests.remove(digest)
  }

  private func cancelWaiter(_ id: UUID, for digest: String) {
    guard var digestWaiters = waiters[digest],
          let index = digestWaiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = digestWaiters.remove(at: index)
    if digestWaiters.isEmpty {
      waiters.removeValue(forKey: digest)
    } else {
      waiters[digest] = digestWaiters
    }
    waiter.continuation.resume(throwing: CancellationError())
  }
}
