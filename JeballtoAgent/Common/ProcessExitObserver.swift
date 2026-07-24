import Foundation

final class ProcessExitObserver: @unchecked Sendable {
  private let lock = NSLock()
  private var status: Int32?
  private var continuations: [CheckedContinuation<Int32, Never>] = []

  var pendingWaiterCount: Int {
    lock.withLock { continuations.count }
  }

  func finish(_ status: Int32) {
    let continuations = lock.withLock { () -> [CheckedContinuation<Int32, Never>] in
      guard self.status == nil else { return [] }
      self.status = status
      let continuations = self.continuations
      self.continuations.removeAll()
      return continuations
    }
    for continuation in continuations {
      continuation.resume(returning: status)
    }
  }

  func wait() async -> Int32 {
    await withCheckedContinuation { continuation in
      let existingStatus = lock.withLock { () -> Int32? in
        if let status {
          return status
        }
        continuations.append(continuation)
        return nil
      }
      if let existingStatus {
        continuation.resume(returning: existingStatus)
      }
    }
  }
}
