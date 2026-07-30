import Foundation
import Testing
@testable import JeballtoAgent

/// Admission, capacity, cancellation, drain and retention for `ImageOperationCoordinator`,
/// which owns image-operation bookkeeping end to end.
@Suite(.tags(.core), .serialized)
struct ImageOperationCoordinatorTests {
  private func makeRecord(_ fill: String = "a") -> ImageRecord {
    ImageRecord(
      reference: testImageOperationReference,
      digest: "sha256:\(String(repeating: fill, count: 64))",
      localPath: "/tmp/image.bundle"
    )
  }

  private func start(
    on coordinator: ImageOperationCoordinator,
    kind: ImageOperationKind = .pull,
    reference: String = testImageOperationReference,
    source: String? = nil,
    run: @escaping @Sendable (ImageOperationProgressReporter) async throws -> ImageRecord
  ) async throws -> ImageOperationStatus {
    try await coordinator.start(kind: kind, reference: reference, source: source) {
      ImageOperationPreparedWork(run: run)
    }.status
  }

  @Test
  func capacityLimitRejectsOperationsBeyondTheConfiguredMaximum() async throws {
    let coordinator = ImageOperationCoordinator(maxActiveOperations: 2)
    let first = try await start(on: coordinator, run: runUntilCancelled)
    _ = try await start(on: coordinator, kind: .push, run: runUntilCancelled)

    await #expect(throws: ImageOperationCoordinatorError.self) {
      _ = try await start(on: coordinator, run: runUntilCancelled)
    }

    // Reaching a terminal state must hand the slot back.
    await coordinator.cancelAndWait(first.id)
    let replacement = try await start(on: coordinator, run: runUntilCancelled)
    #expect(await coordinator.status(for: replacement.id) != nil)

    _ = await coordinator.cancelAll()
  }

  /// Preparation runs after registration, so accepted operations are visible and consume
  /// capacity while source lookup or reservation is still in progress.
  @Test
  func preparingOperationsAreVisibleAndCountTowardCapacity() async throws {
    let coordinator = ImageOperationCoordinator(maxActiveOperations: 2)
    let firstPreparing = AsyncTestSignal()
    let secondPreparing = AsyncTestSignal()
    let releasePreparation = AsyncTestSignal()

    let first = Task {
      try await coordinator.start(kind: .pull, reference: testImageOperationReference) {
        await firstPreparing.signal()
        await releasePreparation.wait()
        return ImageOperationPreparedWork(run: runUntilCancelled)
      }
    }
    let second = Task {
      try await coordinator.start(kind: .pull, reference: testImageOperationReference) {
        await secondPreparing.signal()
        await releasePreparation.wait()
        return ImageOperationPreparedWork(run: runUntilCancelled)
      }
    }

    await firstPreparing.wait()
    await secondPreparing.wait()

    #expect(await coordinator.list(activeOnly: true).count == 2)
    await #expect(throws: ImageOperationCoordinatorError.self) {
      _ = try await start(on: coordinator, run: runUntilCancelled)
    }

    await releasePreparation.signal()
    _ = try await first.value
    _ = try await second.value
    #expect(await coordinator.list(activeOnly: true).count == 2)

    _ = await coordinator.cancelAll()
  }

  @Test
  func preparationFailureStartsAsynchronouslyThenBecomesTerminal() async throws {
    let coordinator = ImageOperationCoordinator()

    let registration = try await coordinator.start(kind: .pull, reference: testImageOperationReference) {
      throw ImageManagerError.registryUnavailable("offline")
    }

    #expect(registration.status.state == .started)
    #expect(registration.status.errorCode == nil)
    _ = await coordinator.wait(for: registration.status.id)
    let status = try #require(await coordinator.status(for: registration.status.id))
    #expect(status.state == .failed)
    #expect(status.errorCode == .imagePullRegistryUnavailable)
    // A failed admission must not hold a slot.
    #expect(await coordinator.list(activeOnly: true).isEmpty)
  }

  /// Cancellation during preparation must release prepared work if the preparation callback
  /// completes after observing cancellation, because it may have acquired a source reservation.
  @Test
  func cancellationAfterPreparationReleasesPreparedWork() async throws {
    let coordinator = ImageOperationCoordinator()
    let preparing = AsyncTestSignal()
    let releasePreparation = AsyncTestSignal()
    let released = AsyncTestSignal()

    let registration = try await coordinator.start(kind: .push, reference: testImageOperationReference) {
      await preparing.signal()
      await releasePreparation.wait()
      return ImageOperationPreparedWork(
        run: runUntilCancelled,
        release: { await released.signal() }
      )
    }

    await preparing.wait()
    let cancellation = Task {
      await coordinator.cancelAndWait(registration.status.id)
    }
    await releasePreparation.signal()

    #expect(await cancellation.value)
    await released.wait()
    #expect(await released.hasBeenSignalled())
    #expect(await coordinator.status(for: registration.status.id)?.state == .cancelled)
  }

  @Test
  func closedAdmissionsRejectNewOperationsUntilResumed() async throws {
    let coordinator = ImageOperationCoordinator()

    _ = await coordinator.closeAdmissionsAndDrain()

    await #expect(throws: ImageOperationCoordinatorError.self) {
      _ = try await start(on: coordinator) { _ in self.makeRecord() }
    }

    await coordinator.resumeAdmissions()
    let resumed = try await start(on: coordinator) { _ in makeRecord() }
    _ = await coordinator.wait(for: resumed.id)
    #expect(await coordinator.status(for: resumed.id)?.state == .completed)
  }

  @Test
  func drainCancelsEveryActiveOperation() async throws {
    let coordinator = ImageOperationCoordinator()
    let first = try await start(on: coordinator, run: runUntilCancelled)
    let second = try await start(on: coordinator, kind: .push, run: runUntilCancelled)

    let drained = await coordinator.closeAdmissionsAndDrain()

    #expect(drained == 2)
    #expect(await coordinator.status(for: first.id)?.state == .cancelled)
    #expect(await coordinator.status(for: second.id)?.state == .cancelled)
  }

  @Test
  func terminalOperationRetentionIsCapped() async throws {
    let coordinator = ImageOperationCoordinator(maxTerminalOperations: 3)

    for index in 0 ..< 6 {
      let operation = try await start(on: coordinator) { _ in makeRecord() }
      _ = await coordinator.wait(for: operation.id)
      #expect(index >= 0)
    }

    let retained = await coordinator.list(activeOnly: false)
    #expect(retained.count == 3)
    #expect(retained.allSatisfy { $0.state == .completed })
  }

  @Test
  func operationCompletingImmediatelyIsObservableAsTerminal() async throws {
    let coordinator = ImageOperationCoordinator()
    let record = makeRecord("f")

    let operation = try await start(on: coordinator) { _ in record }
    let result = try #require(await coordinator.wait(for: operation.id))

    switch result {
    case .success(let completed):
      #expect(completed.digest == record.digest)
    case .failure(let error):
      Issue.record("Expected a completed operation, got \(error)")
    }

    let status = try #require(await coordinator.status(for: operation.id))
    #expect(status.state == .completed)
    #expect(status.digest == record.digest)
    #expect(status.progress == 1.0)
  }

  @Test
  func listFiltersByKindAndActiveState() async throws {
    let coordinator = ImageOperationCoordinator()
    let pull = try await start(on: coordinator, run: runUntilCancelled)
    let push = try await start(on: coordinator, kind: .push) { _ in throw CancellationError() }
    _ = await coordinator.wait(for: push.id)

    #expect(await coordinator.list(activeOnly: true).map(\.id) == [pull.id])
    #expect(await coordinator.list(kind: .push, activeOnly: false).map(\.id) == [push.id])

    _ = await coordinator.cancelAll()
  }

  @Test
  func activeSourceIsReportedWhileTheOperationRuns() async throws {
    let coordinator = ImageOperationCoordinator()
    let source = "image:\(UUID().uuidString)"
    let operation = try await start(on: coordinator, kind: .push, source: source, run: runUntilCancelled)

    #expect(await coordinator.hasActiveOperation(source: source))

    await coordinator.cancelAndWait(operation.id)
    #expect(await coordinator.hasActiveOperation(source: source) == false)
  }

  @Test
  func progressUpdatesFlowFromTheOperationBodyToStatus() async throws {
    let coordinator = ImageOperationCoordinator()
    let record = makeRecord("b")

    let operation = try await start(on: coordinator) { reporter in
      await reporter.sink(
        ImageOperationProgressUpdate(
          chunksCompletedDelta: 1,
          chunksTotal: 2,
          bytesCompletedDelta: 50,
          bytesTotal: 100
        )
      )
      return record
    }
    _ = await coordinator.wait(for: operation.id)

    let status = try #require(await coordinator.status(for: operation.id))
    #expect(status.state == .completed)
    #expect(status.chunksCompleted == 1)
    #expect(status.bytesCompleted == 50)
  }
}
