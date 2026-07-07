import Foundation

actor ImageOperationCache {
  private var activeKeys: Set<String> = []
  private let retryDelay: UInt64 = 1_000_000

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
    while true {
      try Task.checkCancellation()
      if activeKeys.contains(key) == false {
        activeKeys.insert(key)
        return
      }
      try await Task.sleep(nanoseconds: retryDelay)
    }
  }

  private func release(_ key: String) {
    activeKeys.remove(key)
  }
}
