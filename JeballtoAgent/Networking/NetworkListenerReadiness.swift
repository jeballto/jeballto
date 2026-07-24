import Foundation
import Network

/// Bridges `NWListener` state callbacks to synchronous startup APIs.
final class NetworkListenerReadiness: @unchecked Sendable {
  enum ReadinessError: Error, LocalizedError {
    case failed(NWError)
    case cancelled
    case timedOut(TimeInterval)

    var errorDescription: String? {
      switch self {
      case .failed(let error): "Listener failed before becoming ready: \(error.localizedDescription)"
      case .cancelled: "Listener was cancelled before becoming ready"
      case .timedOut(let seconds): "Listener did not become ready within \(seconds) seconds"
      }
    }
  }

  private let lock = NSLock()
  private let resolutionGroup = DispatchGroup()
  private var result: Result<Void, ReadinessError>?

  init() {
    resolutionGroup.enter()
  }

  func observe(_ state: NWListener.State) {
    switch state {
    case .ready: resolve(.success(()))
    case .failed(let error): resolve(.failure(.failed(error)))
    case .cancelled: resolve(.failure(.cancelled))
    default: break
    }
  }

  func wait(timeout: TimeInterval) throws {
    if let result = lock.withLock({ result }) {
      return try result.get()
    }
    let boundedTimeout = max(0, timeout)
    guard resolutionGroup.wait(timeout: .now() + boundedTimeout) == .success else {
      throw ReadinessError.timedOut(boundedTimeout)
    }
    guard let result = lock.withLock({ result }) else {
      throw ReadinessError.timedOut(boundedTimeout)
    }
    try result.get()
  }

  func cancel() {
    resolve(.failure(.cancelled))
  }

  private func resolve(_ result: Result<Void, ReadinessError>) {
    let didResolve = lock.withLock { () -> Bool in
      guard self.result == nil else { return false }
      self.result = result
      return true
    }
    if didResolve { resolutionGroup.leave() }
  }
}
