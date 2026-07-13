import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct ImageOperationTrackerTests {
  private struct InfrastructureFailureCase {
    let kind: ImageOperationKind
    let error: ImageManagerError
    let expectedCode: ImageOperationErrorCode
  }

  @Test
  func updateComputesProgressFromBytesAndCompletesWithImageRecord() async throws {
    let tracker = ImageOperationTracker()
    let started = await tracker.start(kind: .pull, reference: "registry.example.com/vm/macos:latest")

    await tracker.update(
      started.id,
      ImageOperationProgressUpdate(
        chunksCompletedDelta: 2,
        chunksTotal: 4,
        bytesCompletedDelta: 512,
        bytesTotal: 1024
      )
    )

    let running = try #require(await tracker.get(started.id))
    #expect(running.state == .running)
    #expect(running.chunksCompleted == 2)
    #expect(running.chunksTotal == 4)
    #expect(running.bytesCompleted == 512)
    #expect(running.progress == 0.5)

    let record = ImageRecord(
      reference: "registry.example.com/vm/macos:latest",
      digest: "sha256:\(String(repeating: "a", count: 64))",
      localPath: "/tmp/image.bundle"
    )
    await tracker.complete(started.id, record: record)

    let completed = try #require(await tracker.get(started.id))
    let response = ImageOperationStatusResponse(from: completed)
    #expect(completed.state == .completed)
    #expect(completed.progress == 1.0)
    #expect(completed.digest == record.digest)
    #expect(completed.image == record)
    #expect(completed.errorCode == nil)
    #expect(response.status == "completed")
    #expect(response.statusUrl == "/v1/images/pull/operations/\(started.id.uuidString)")
    #expect(response.image?.id == record.id.uuidString)
  }

  @Test
  func failureMarksOperationFailed() async throws {
    let tracker = ImageOperationTracker()
    let started = await tracker.start(kind: .push, reference: "registry.example.com/vm/macos:latest")

    await tracker.fail(started.id, error: ImageManagerError.pushFailed("registry rejected upload"))

    let failed = try #require(await tracker.get(started.id))
    #expect(failed.state == .failed)
    #expect(failed.errorCode == .imagePushFailed)
    #expect(failed.error?.contains("registry rejected upload") == true)
    #expect(ImageOperationStatusResponse(from: failed).errorCode == "IMAGE_PUSH_FAILED")
  }

  @Test
  func partialRegistryCommitHasADedicatedAsyncErrorCode() async throws {
    let tracker = ImageOperationTracker()
    let started = await tracker.start(kind: .push, reference: "registry.example.com/vm/macos:latest")
    let digest = "sha256:\(String(repeating: "a", count: 64))"
    await tracker.fail(
      started.id,
      error: ImageManagerError.pushPartiallyCommitted(
        reference: started.reference,
        digest: digest,
        reason: "atomic rename failed"
      )
    )

    let failed = try #require(await tracker.get(started.id))
    #expect(failed.errorCode == .imagePushPartiallyCommitted)
    #expect(failed.digest == digest)
    #expect(ImageOperationStatusResponse(from: failed).digest == digest)
    #expect(ImageOperationStatusResponse(from: failed).errorCode == "IMAGE_PUSH_PARTIALLY_COMMITTED")
  }

  @Test
  func unknownRegistryCommitOutcomeHasADedicatedAsyncErrorCode() async throws {
    let tracker = ImageOperationTracker()
    let started = await tracker.start(kind: .push, reference: "registry.example.com/vm/macos:latest")
    let digest = "sha256:\(String(repeating: "a", count: 64))"
    await tracker.fail(
      started.id,
      error: ImageManagerError.pushCommitOutcomeUnknown(
        reference: started.reference,
        digest: digest,
        reason: "manifest process was interrupted"
      )
    )

    let failed = try #require(await tracker.get(started.id))
    #expect(failed.errorCode == .imagePushCommitOutcomeUnknown)
    #expect(failed.digest == digest)
    #expect(ImageOperationStatusResponse(from: failed).digest == digest)
    #expect(ImageOperationStatusResponse(from: failed).errorCode == "IMAGE_PUSH_COMMIT_OUTCOME_UNKNOWN")
  }

  @Test
  func activeProgressStaysBelowCompletionUntilTheOperationCompletes() async throws {
    let tracker = ImageOperationTracker()
    let pull = await tracker.start(kind: .pull, reference: "registry.example.com/vm/pull:latest")
    await tracker.update(
      pull.id,
      ImageOperationProgressUpdate(
        bytesCompletedDelta: 100,
        bytesTotal: 100
      )
    )

    let activePull = try #require(await tracker.get(pull.id))
    #expect(activePull.progress == 0.99)
    #expect(ImageOperationStatusResponse(from: activePull).progress == 0.99)

    let push = await tracker.start(kind: .push, reference: "registry.example.com/vm/push:latest")
    await tracker.update(
      push.id,
      ImageOperationProgressUpdate(
        stage: .uploading,
        stageProgress: 1.0
      )
    )

    let activePush = try #require(await tracker.get(push.id))
    #expect(activePush.stageProgress == 1.0)
    #expect(activePush.progress == 0.99)

    let record = ImageRecord(
      reference: pull.reference,
      digest: "sha256:\(String(repeating: "c", count: 64))",
      localPath: "/tmp/image.bundle"
    )
    await tracker.complete(pull.id, record: record)

    let completedPull = try #require(await tracker.get(pull.id))
    #expect(completedPull.progress == 1.0)
  }

  @Test
  func failuresExposeSpecificMachineReadableErrorCodes() async throws {
    let tracker = ImageOperationTracker()
    let cases: [(ImageManagerError, ImageOperationErrorCode)] = [
      (.invalidReference("missing repository"), .invalidReference),
      (.invalidImage("missing Disk.img"), .invalidImage),
      (.unsupportedImageFormat("formatVersion 2"), .unsupportedImageFormat),
      (.imageNotFound("registry.example.com/vm:missing"), .imageNotFound),
      (.imageInUse("image is being deleted"), .imageInUse),
    ]

    for (error, expectedCode) in cases {
      let operation = await tracker.start(kind: .pull, reference: "registry.example.com/vm:latest")
      await tracker.fail(operation.id, error: error)

      let failed = try #require(await tracker.get(operation.id))
      #expect(failed.errorCode == expectedCode)
      #expect(ImageOperationStatusResponse(from: failed).errorCode == expectedCode.rawValue)
      #expect(failed.error == error.localizedDescription)
    }
  }

  @Test
  func infrastructureFailuresUseOperationSpecificCodes() async throws {
    let tracker = ImageOperationTracker()
    let cases = [
      InfrastructureFailureCase(
        kind: .pull,
        error: .registryUnavailable("offline"),
        expectedCode: .imagePullRegistryUnavailable
      ),
      InfrastructureFailureCase(
        kind: .push,
        error: .registryUnavailable("offline"),
        expectedCode: .imagePushRegistryUnavailable
      ),
      InfrastructureFailureCase(kind: .pull, error: .timeout("deadline exceeded"), expectedCode: .imagePullTimeout),
      InfrastructureFailureCase(kind: .push, error: .timeout("deadline exceeded"), expectedCode: .imagePushTimeout),
    ]

    for testCase in cases {
      let operation = await tracker.start(kind: testCase.kind, reference: "registry.example.com/vm:latest")
      await tracker.fail(operation.id, error: testCase.error)

      let failed = try #require(await tracker.get(operation.id))
      #expect(failed.errorCode == testCase.expectedCode)
      #expect(ImageOperationStatusResponse(from: failed).errorCode == testCase.expectedCode.rawValue)
    }
  }

  @Test
  func statusResponseRoundsProgressAndOmitsLabels() async throws {
    let tracker = ImageOperationTracker()
    let started = await tracker.start(kind: .pull, reference: "registry.example.com/vm/macos:latest")
    await tracker.update(
      started.id,
      ImageOperationProgressUpdate(
        bytesCompletedDelta: 3_060_910_946,
        bytesTotal: 41_790_509_309
      )
    )

    let status = try #require(await tracker.get(started.id))
    let response = ImageOperationStatusResponse(from: status)
    let data = try JSONEncoder().encode(response)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(response.progress == 0.07)
    #expect(response.statusUrl == "/v1/images/pull/operations/\(started.id.uuidString)")
    #expect(object["message"] == nil)
    #expect(object["phase"] == nil)
    #expect(object["phaseProgress"] == nil)
    #expect(object["stage"] == nil)
  }

  @Test
  func pushStatusTracksCompressionUploadAndFinalizationStages() async throws {
    let tracker = ImageOperationTracker()
    let started = await tracker.start(kind: .push, reference: "registry.example.com/vm/macos:latest")

    await tracker.update(
      started.id,
      ImageOperationProgressUpdate(
        stage: .compressing,
        chunksTotal: 4,
        bytesTotal: 100
      )
    )
    await tracker.update(
      started.id,
      ImageOperationProgressUpdate(
        stage: .compressing,
        chunksCompletedDelta: 1,
        bytesCompletedDelta: 25
      )
    )

    let compressing = try #require(await tracker.get(started.id))
    let compressingResponse = ImageOperationStatusResponse(from: compressing)
    #expect(compressing.stage == .compressing)
    #expect(compressing.stageProgress == 0.25)
    #expect(compressingResponse.stage == "compressing")
    #expect(compressingResponse.stageProgress == 0.25)
    #expect(compressingResponse.progress == 0.13)
    #expect(compressingResponse.chunksCompleted == 1)
    #expect(compressingResponse.bytesCompleted == 25)

    await tracker.update(
      started.id,
      ImageOperationProgressUpdate(
        stage: .uploading,
        progress: 0.5,
        stageProgress: 0,
        setChunksCompleted: 0,
        chunksTotal: 2,
        setBytesCompleted: 0,
        bytesTotal: 50
      )
    )

    let uploadStarted = try #require(await tracker.get(started.id))
    #expect(uploadStarted.stage == .uploading)
    #expect(uploadStarted.stageProgress == 0)
    #expect(uploadStarted.progress == 0.5)
    #expect(uploadStarted.chunksCompleted == 0)
    #expect(uploadStarted.bytesCompleted == 0)

    await tracker.update(
      started.id,
      ImageOperationProgressUpdate(
        stage: .uploading,
        chunksCompletedDelta: 1,
        bytesCompletedDelta: 25
      )
    )

    let uploading = try #require(await tracker.get(started.id))
    let uploadingResponse = ImageOperationStatusResponse(from: uploading)
    #expect(uploadingResponse.stage == "uploading")
    #expect(uploadingResponse.stageProgress == 0.5)
    #expect(uploadingResponse.progress == 0.75)
    #expect(uploadingResponse.chunksCompleted == 1)
    #expect(uploadingResponse.bytesCompleted == 25)

    await tracker.update(
      started.id,
      ImageOperationProgressUpdate(
        stage: .finalizing,
        progress: 0.99,
        stageProgress: 0
      )
    )

    let finalizing = try #require(await tracker.get(started.id))
    let finalizingResponse = ImageOperationStatusResponse(from: finalizing)
    #expect(finalizingResponse.stage == "finalizing")
    #expect(finalizingResponse.stageProgress == 0)
    #expect(finalizingResponse.progress == 0.99)
    #expect(finalizingResponse.chunksCompleted == 0)
    #expect(finalizingResponse.chunksTotal == nil)
    #expect(finalizingResponse.bytesCompleted == 0)
    #expect(finalizingResponse.bytesTotal == nil)
    #expect(finalizingResponse.averageSpeedMBps == nil)

    let record = ImageRecord(
      reference: started.reference,
      digest: "sha256:\(String(repeating: "d", count: 64))",
      localPath: "/tmp/finalized.bundle"
    )
    await tracker.complete(started.id, record: record)

    let completed = try #require(await tracker.get(started.id))
    #expect(completed.progress == 1.0)
    #expect(completed.stageProgress == 1.0)
  }

  @Test
  func statusResponseReportsAverageSpeedInMBps() {
    let operationId = UUID()
    let startedAt = Date(timeIntervalSince1970: 1000)
    let updatedAt = startedAt.addingTimeInterval(4)
    let running = ImageOperationStatus(
      id: operationId,
      kind: .push,
      reference: "registry.example.com/vm/macos:latest",
      source: "image:\(UUID().uuidString)",
      state: .running,
      stage: nil,
      progress: nil,
      stageProgress: nil,
      chunksCompleted: 0,
      chunksTotal: nil,
      bytesCompleted: 10_000_000,
      bytesTotal: nil,
      startedAt: startedAt,
      startedUptime: 1000,
      stageStartedAt: nil,
      stageStartedUptime: nil,
      updatedAt: updatedAt,
      updatedUptime: 1004,
      completedAt: nil,
      completedUptime: nil,
      digest: nil,
      image: nil,
      errorCode: nil,
      error: nil
    )

    #expect(ImageOperationStatusResponse(from: running).averageSpeedMBps == 2.5)

    var completed = running
    completed.completedAt = startedAt.addingTimeInterval(8)
    completed.completedUptime = 1008
    #expect(ImageOperationStatusResponse(from: completed).averageSpeedMBps == 1.25)
  }

  @Test
  func progressUpdatesClampInvalidValuesAndSaturateCounters() async throws {
    let tracker = ImageOperationTracker()
    let started = await tracker.start(kind: .pull, reference: "registry.example.com/vm/macos:latest")

    await tracker.update(
      started.id,
      ImageOperationProgressUpdate(
        progress: .nan,
        setChunksCompleted: Int.max,
        chunksTotal: -1,
        setBytesCompleted: UInt64.max
      )
    )
    await tracker.update(
      started.id,
      ImageOperationProgressUpdate(
        chunksCompletedDelta: 1,
        bytesCompletedDelta: 1
      )
    )

    var status = try #require(await tracker.get(started.id))
    #expect(status.progress == 0)
    #expect(status.chunksCompleted == Int.max)
    #expect(status.chunksTotal == 0)
    #expect(status.bytesCompleted == UInt64.max)

    await tracker.update(started.id, ImageOperationProgressUpdate(chunksCompletedDelta: Int.min))
    status = try #require(await tracker.get(started.id))
    #expect(status.chunksCompleted == 0)
  }

  @Test
  func cancellationRequestBecomesTerminalAfterTaskReportsCancellation() async throws {
    let tracker = ImageOperationTracker()
    let started = await tracker.start(kind: .pull, reference: "registry.example.com/vm/macos:latest")
    let cancellationRequested = await tracker.cancel(started.id)

    #expect(cancellationRequested)

    let cancelling = try #require(await tracker.get(started.id))
    #expect(cancelling.state == .cancelling)
    #expect(cancelling.state.isTerminal == false)
    #expect(cancelling.completedAt == nil)
    #expect(cancelling.errorCode == nil)

    await tracker.fail(started.id, error: CancellationError())

    let record = ImageRecord(
      reference: "registry.example.com/vm/macos:latest",
      digest: "sha256:\(String(repeating: "b", count: 64))",
      localPath: "/tmp/image.bundle"
    )
    await tracker.complete(started.id, record: record)

    let status = try #require(await tracker.get(started.id))
    #expect(status.state == .cancelled)
    #expect(status.digest == nil)
    #expect(status.errorCode == .imagePullCancelled)
    #expect(ImageOperationStatusResponse(from: status).errorCode == "IMAGE_PULL_CANCELLED")
  }

  @Test
  func committedCompletionWinsLateCancellationRequest() async throws {
    let tracker = ImageOperationTracker()
    let started = await tracker.start(kind: .pull, reference: "registry.example.com/vm/macos:latest")
    let record = ImageRecord(
      reference: "registry.example.com/vm/macos:latest",
      digest: "sha256:\(String(repeating: "c", count: 64))",
      localPath: "/tmp/image.bundle"
    )

    await tracker.cancel(started.id)
    await tracker.complete(started.id, record: record)

    let completed = try #require(await tracker.get(started.id))
    #expect(completed.state == .completed)
    #expect(completed.digest == record.digest)
    #expect(completed.completedAt != nil)
    #expect(completed.errorCode == nil)
  }

  @Test
  func admissionCapsActiveOperationsAndReleasesCapacityAtTerminalState() async throws {
    let tracker = ImageOperationTracker(maxActiveOperations: 2)
    let first = try await tracker.admit(
      id: UUID(),
      kind: .pull,
      reference: "registry.example.com/vm/first:latest"
    )
    _ = try await tracker.admit(
      id: UUID(),
      kind: .push,
      reference: "registry.example.com/vm/second:latest"
    )

    await #expect(throws: ImageOperationTrackerError.self) {
      _ = try await tracker.admit(
        id: UUID(),
        kind: .pull,
        reference: "registry.example.com/vm/overflow:latest"
      )
    }

    await tracker.fail(first.id, error: CancellationError())
    let replacement = try await tracker.admit(
      id: UUID(),
      kind: .pull,
      reference: "registry.example.com/vm/replacement:latest"
    )
    #expect(replacement.state == .started)
  }

  @Test
  func listFiltersByTypeAndActiveState() async throws {
    let tracker = ImageOperationTracker()
    let pull = await tracker.start(kind: .pull, reference: "registry.example.com/vm/macos:latest")
    let push = await tracker.start(kind: .push, reference: "registry.example.com/vm/macos:latest")
    await tracker.fail(push.id, error: CancellationError())

    let active = await tracker.list(activeOnly: true)
    #expect(active.map(\.id) == [pull.id])

    let pushes = await tracker.list(kind: .push, activeOnly: false)
    #expect(pushes.map(\.id) == [push.id])
  }

  @Test
  func progressAfterCancellationKeepsCancellingState() async throws {
    let tracker = ImageOperationTracker()
    let started = await tracker.start(kind: .push, reference: "registry.example.com/vm/macos:latest")

    await tracker.cancel(started.id)
    await tracker.update(
      started.id,
      ImageOperationProgressUpdate(
        stage: .uploading,
        chunksCompletedDelta: 1,
        chunksTotal: 4,
        bytesCompletedDelta: 256,
        bytesTotal: 1024
      )
    )

    let status = try #require(await tracker.get(started.id))
    #expect(status.state == .cancelling)
    #expect(status.stage == .uploading)
    #expect(status.chunksCompleted == 1)
    #expect(status.bytesCompleted == 256)
    #expect(status.progress == 0.625)
  }
}
