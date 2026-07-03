import Foundation

actor ImageConcurrencyLimiter {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private let limit: Int
  private var available: Int
  private var waiters: [Waiter] = []

  init(limit: Int) {
    let boundedLimit = max(1, limit)
    self.limit = boundedLimit
    available = boundedLimit
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
    if available > 0 {
      available -= 1
      return
    }

    let waiterID = UUID()
    let acquired = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        waiters.append(Waiter(id: waiterID, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterID) }
    }

    guard acquired else {
      throw CancellationError()
    }
  }

  private func release() {
    guard waiters.isEmpty == false else {
      available = min(limit, available + 1)
      return
    }

    let next = waiters.removeFirst()
    next.continuation.resume(returning: true)
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(returning: false)
  }
}
