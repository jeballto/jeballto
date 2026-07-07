import Foundation

actor ImageBlobCache {
  private var activeDigests: Set<String> = []
  private let retryDelay: UInt64 = 1_000_000

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
    while true {
      try Task.checkCancellation()
      if activeDigests.contains(digest) == false {
        activeDigests.insert(digest)
        return
      }
      try await Task.sleep(nanoseconds: retryDelay)
    }
  }

  private func release(_ digest: String) {
    activeDigests.remove(digest)
  }
}
