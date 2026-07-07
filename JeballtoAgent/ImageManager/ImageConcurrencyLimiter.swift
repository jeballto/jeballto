import Foundation

actor ImageConcurrencyLimiter {
  private let limit: Int
  private var available: Int
  private let retryDelay: UInt64 = 1_000_000

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
    while true {
      try Task.checkCancellation()
      if available > 0 {
        available -= 1
        return
      }
      try await Task.sleep(nanoseconds: retryDelay)
    }
  }

  private func release() {
    available = min(limit, available + 1)
  }
}
