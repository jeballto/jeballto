import Foundation

actor ImageOperationCache {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private var activeKeys: Set<String> = []
  private var waitersByKey: [String: [Waiter]] = [:]

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

    let waiterID = UUID()
    let acquired = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        waitersByKey[key, default: []].append(Waiter(id: waiterID, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterID, for: key) }
    }

    guard acquired else {
      throw CancellationError()
    }
  }

  private func release(_ key: String) {
    guard var waiters = waitersByKey[key], waiters.isEmpty == false else {
      activeKeys.remove(key)
      waitersByKey[key] = nil
      return
    }

    let next = waiters.removeFirst()
    waitersByKey[key] = waiters.isEmpty ? nil : waiters
    next.continuation.resume(returning: true)
  }

  private func cancelWaiter(_ id: UUID, for key: String) {
    guard var waiters = waitersByKey[key],
          let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waitersByKey[key] = waiters.isEmpty ? nil : waiters
    waiter.continuation.resume(returning: false)
  }
}
