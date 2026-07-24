import Foundation

actor ImageConcurrencyLimiter {
  private var limit: Int
  private var inUse = 0
  private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func updateLimit(_ newLimit: Int) {
    limit = max(1, newLimit)
    resumeWaitersIfPossible()
  }

  func withPermit<T: Sendable>(
    _ operation: @Sendable () async throws -> T
  ) async throws -> T {
    try await acquire()
    defer { release() }
    try Task.checkCancellation()
    return try await operation()
  }

  private func acquire() async throws {
    try Task.checkCancellation()
    if inUse < limit {
      inUse += 1
      return
    }

    let waiterId = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters.append((waiterId, continuation))
        }
      }
    } onCancel: {
      Task<Void, Never> { await self.cancelWaiter(waiterId) }
    }
  }

  private func release() {
    precondition(inUse > 0, "Image concurrency permit released without being acquired")
    inUse -= 1
    resumeWaitersIfPossible()
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
  }

  private func resumeWaitersIfPossible() {
    while inUse < limit, waiters.isEmpty == false {
      let waiter = waiters.removeFirst()
      inUse += 1
      waiter.continuation.resume()
    }
  }
}
