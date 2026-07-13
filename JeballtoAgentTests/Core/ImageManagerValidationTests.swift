import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct ImageManagerValidationTests {
  @Test
  func pushDeadlineIncludesDiskImageInspection() async throws {
    try await withTemporaryDirectory(prefix: "image-inspection-timeout") { root in
      let bundlePath = "\(root)/source.bundle"
      try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
      for fileName in ["Disk.img", "AuxiliaryStorage", "HardwareModel", "MachineIdentifier"] {
        try Data(fileName.utf8).write(to: URL(fileURLWithPath: "\(bundlePath)/\(fileName)"))
      }
      var config = makeTestConfig(root: root)
      config.images.orasPath = "/usr/bin/false"
      let manager = ImageManager(
        imageStore: ImageStore(
          storagePath: config.images.imageStorageDir,
          indexPath: config.storage.imageIndexPath
        ),
        orasClient: OrasClient(
          config: config.images,
          temporaryRoot: URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("cache/ImageWork/sessions/test", isDirectory: true),
          credentialStore: makeTestRegistryCredentialStore()
        ),
        eventBus: EventBus(),
        config: config,
        diskImageCapacityValidator: { _, _ in
          try await Task.sleep(for: .seconds(10))
        },
        registryAvailabilityChecker: { _, _ in }
      )
      let clock = ContinuousClock()
      let startedAt = clock.now

      do {
        _ = try await manager.pushImageFromVM(
          reference: "registry.example.com/repo:tag",
          vmBundlePath: bundlePath,
          resources: .default,
          timeout: 0.05
        )
        Issue.record("Expected disk image inspection to honor the image operation deadline")
      } catch let error as ImageManagerError {
        guard case .timeout = error else {
          Issue.record("Expected image timeout, got \(error.localizedDescription)")
          return
        }
      }
      #expect(startedAt.duration(to: clock.now) < .seconds(5))
    }
  }

  @Test
  func deadlineReturnsSuccessWhenOperationCommittedBeforeTimeoutWonRace() async throws {
    let gate = DeadlineCancellationGate()

    let value = try await ImageManager.withImageOperationDeadline(
      timeout: 0.01,
      operationName: "durable image commit"
    ) {
      ImageManager.markCurrentImageOperationCommitted()
      await withTaskCancellationHandler {
        await gate.waitUntilCancelled()
      } onCancel: {
        gate.cancel()
      }
      return 42
    }

    #expect(value == 42)
    #expect(gate.wasCancelled)
  }

  @Test
  func deadlineStillTimesOutCancellationInsensitiveWorkBeforeCommit() async {
    let gate = DeadlineCancellationGate()

    await #expect(throws: OrasError.self) {
      let _: Int = try await ImageManager.withImageOperationDeadline(
        timeout: 0.01,
        operationName: "uncommitted image work"
      ) {
        await withTaskCancellationHandler {
          await gate.waitUntilCancelled()
        } onCancel: {
          gate.cancel()
        }
        return 42
      }
    }
    #expect(gate.wasCancelled)
  }

  @Test
  func deadlineKeepsTimeoutWhenPrecommitWorkFailsAfterCancellation() async {
    let gate = DeadlineCancellationGate()

    do {
      _ = try await ImageManager.withImageOperationDeadline(
        timeout: 0.01,
        operationName: "late precommit failure"
      ) {
        await withTaskCancellationHandler {
          await gate.waitUntilCancelled()
        } onCancel: {
          gate.cancel()
        }
        throw DeadlineTestError.lateFailure
      }
      Issue.record("Expected deadline timeout")
    } catch let error as OrasError {
      guard case .timeout(let operation) = error else {
        Issue.record("Expected timeout, got \(error.localizedDescription)")
        return
      }
      #expect(operation == "late precommit failure")
    } catch {
      Issue.record("Expected OrasError.timeout, got \(error)")
    }
    #expect(gate.wasCancelled)
  }

  @Test
  func unknownManifestCommitOutcomeWinsAConcurrentDeadline() async {
    let gate = DeadlineCancellationGate()
    let reference = "registry.example.com/repo:tag"
    let digest = "sha256:\(String(repeating: "a", count: 64))"

    do {
      let _: Int = try await ImageManager.withImageOperationDeadline(
        timeout: 0.01,
        operationName: "manifest commit"
      ) {
        await withTaskCancellationHandler {
          await gate.waitUntilCancelled()
        } onCancel: {
          gate.cancel()
        }
        throw ImageManagerError.pushCommitOutcomeUnknown(
          reference: reference,
          digest: digest,
          reason: "manifest process was interrupted"
        )
      }
      Issue.record("Expected an unknown manifest commit outcome")
    } catch let error as ImageManagerError {
      guard case .pushCommitOutcomeUnknown(let actualReference, let actualDigest, _) = error else {
        Issue.record("Expected pushCommitOutcomeUnknown, got \(error.localizedDescription)")
        return
      }
      #expect(actualReference == reference)
      #expect(actualDigest == digest)
    } catch {
      Issue.record("Expected ImageManagerError.pushCommitOutcomeUnknown, got \(error)")
    }
    #expect(gate.wasCancelled)
  }

  @Test
  func unknownManifestCommitOutcomeWinsExplicitCallerCancellation() async {
    let gate = DeadlineCancellationGate()
    let started = DeadlineOperationStartSignal()
    let reference = "registry.example.com/repo:tag"
    let digest = "sha256:\(String(repeating: "b", count: 64))"
    let task = Task<Int, Error> {
      try await ImageManager.withImageOperationDeadline(
        timeout: 60,
        operationName: "manifest commit"
      ) {
        await started.markStarted()
        await withTaskCancellationHandler {
          await gate.waitUntilCancelled()
        } onCancel: {
          gate.cancel()
        }
        throw ImageManagerError.pushCommitOutcomeUnknown(
          reference: reference,
          digest: digest,
          reason: "manifest process was interrupted"
        )
      }
    }

    await started.waitUntilStarted()
    task.cancel()

    do {
      let _: Int = try await task.value
      Issue.record("Expected an unknown manifest commit outcome")
    } catch let error as ImageManagerError {
      guard case .pushCommitOutcomeUnknown(let actualReference, let actualDigest, _) = error else {
        Issue.record("Expected pushCommitOutcomeUnknown, got \(error.localizedDescription)")
        return
      }
      #expect(actualReference == reference)
      #expect(actualDigest == digest)
    } catch {
      Issue.record("Expected ImageManagerError.pushCommitOutcomeUnknown, got \(error)")
    }
    #expect(gate.wasCancelled)
  }
}

private enum DeadlineTestError: Error {
  case lateFailure
}

private final class DeadlineCancellationGate: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var continuation: CheckedContinuation<Void, Never>?

  var wasCancelled: Bool {
    lock.withLock { cancelled }
  }

  func waitUntilCancelled() async {
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock { () -> Bool in
        guard cancelled == false else { return true }
        self.continuation = continuation
        return false
      }
      if shouldResume {
        continuation.resume()
      }
    }
  }

  func cancel() {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      cancelled = true
      let continuation = self.continuation
      self.continuation = nil
      return continuation
    }
    continuation?.resume()
  }
}

private actor DeadlineOperationStartSignal {
  private var started = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func markStarted() {
    started = true
    let waiters = waiters
    self.waiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func waitUntilStarted() async {
    guard started == false else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}
