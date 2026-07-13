import Foundation

func waitUntil(
  timeout: TimeInterval = 1.0,
  pollInterval: TimeInterval = 0.01,
  condition: @escaping @Sendable () -> Bool
) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)

  while Date() < deadline {
    if condition() {
      return true
    }
    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
  }

  return condition()
}

func waitUntilAsync(
  timeout: TimeInterval = 1.0,
  pollInterval: TimeInterval = 0.01,
  condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)

  while Date() < deadline {
    if await condition() {
      return true
    }
    try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
  }

  return await condition()
}
