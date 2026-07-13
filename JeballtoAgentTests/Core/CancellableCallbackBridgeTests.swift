import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct CancellableCallbackBridgeTests {
  @Test
  func cancellationBeforeRegistrationResumesImmediatelyAndIgnoresLateResult() async {
    let bridge = CancellableCallbackBridge<Int>()
    bridge.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await awaitBridge(bridge)
    }
    bridge.resolve(.success(42))
  }

  @Test
  func cancellationAfterRegistrationResumesExactlyOnce() async throws {
    let bridge = CancellableCallbackBridge<Int>()
    let registered = CallbackRegistrationFlag()
    let task = Task<Int, Error> {
      try await withCheckedThrowingContinuation { continuation in
        _ = bridge.register(continuation)
        registered.markRegistered()
      }
    }
    #expect(await waitUntil { registered.isRegistered })

    bridge.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    bridge.resolve(.failure(TestCallbackError.lateFailure))
  }

  @Test
  func resultBeforeRegistrationIsDelivered() async throws {
    let bridge = CancellableCallbackBridge<Int>()
    bridge.resolve(.success(7))

    #expect(try await awaitBridge(bridge) == 7)
  }
}

private enum TestCallbackError: Error {
  case lateFailure
}

private final class CallbackRegistrationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var registered = false

  var isRegistered: Bool {
    lock.withLock { registered }
  }

  func markRegistered() {
    lock.withLock { registered = true }
  }
}

private func awaitBridge(_ bridge: CancellableCallbackBridge<Int>) async throws -> Int {
  try await withCheckedThrowingContinuation { continuation in
    _ = bridge.register(continuation)
  }
}
