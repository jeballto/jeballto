import Foundation

actor ImageBlobCache {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private var activeDigests: Set<String> = []
  private var waitersByDigest: [String: [Waiter]] = [:]

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

    let waiterID = UUID()
    let acquired = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        waitersByDigest[digest, default: []].append(Waiter(id: waiterID, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterID, for: digest) }
    }

    guard acquired else {
      throw CancellationError()
    }
  }

  private func release(_ digest: String) {
    guard var waiters = waitersByDigest[digest], waiters.isEmpty == false else {
      activeDigests.remove(digest)
      waitersByDigest[digest] = nil
      return
    }

    let next = waiters.removeFirst()
    waitersByDigest[digest] = waiters.isEmpty ? nil : waiters
    next.continuation.resume(returning: true)
  }

  private func cancelWaiter(_ id: UUID, for digest: String) {
    guard var waiters = waitersByDigest[digest],
          let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waitersByDigest[digest] = waiters.isEmpty ? nil : waiters
    waiter.continuation.resume(returning: false)
  }
}
