import Foundation
import Testing
@testable import JeballtoAgent

/// Status, progress and error-code semantics for image operations. These drive
/// `ImageOperationStatusReducer` directly: it is the pure state machine that
/// `ImageOperationCoordinator` applies to every operation entry.
@Suite(.tags(.core))
struct ImageOperationStatusReducerTests {
  private struct InfrastructureFailureCase {
    let kind: ImageOperationKind
    let error: ImageManagerError
    let expectedCode: ImageOperationErrorCode
  }

  private func makeStatus(
    kind: ImageOperationKind,
    reference: String = "registry.example.com/vm/macos:latest",
    source: String? = nil
  ) -> ImageOperationStatus {
    ImageOperationStatusReducer.makeStatus(id: UUID(), kind: kind, reference: reference, source: source)
  }

  @Test
  func updateComputesProgressFromBytesAndCompletesWithImageRecord() throws {
    var status = makeStatus(kind: .pull)

    ImageOperationStatusReducer.update(
      &status,
      update: ImageOperationProgressUpdate(
        chunksCompletedDelta: 2,
        chunksTotal: 4,
        bytesCompletedDelta: 512,
        bytesTotal: 1024
      )
    )

    #expect(status.state == .running)
    #expect(status.chunksCompleted == 2)
    #expect(status.chunksTotal == 4)
    #expect(status.bytesCompleted == 512)
    #expect(status.progress == 0.5)

    let record = ImageRecord(
      reference: status.reference,
      digest: "sha256:\(String(repeating: "a", count: 64))",
      localPath: "/tmp/image.bundle"
    )
    ImageOperationStatusReducer.complete(&status, record: record)

    let response = ImageOperationStatusResponse(from: status)
    #expect(status.state == .completed)
    #expect(status.progress == 1.0)
    #expect(status.digest == record.digest)
    #expect(status.image == record)
    #expect(status.errorCode == nil)
    #expect(response.status == "completed")
    #expect(response.statusUrl == "/v1/images/pull/operations/\(status.id.uuidString)")
    #expect(response.image?.id == record.id.uuidString)
  }

  @Test
  func failureMarksOperationFailed() {
    var status = makeStatus(kind: .push)

    ImageOperationStatusReducer.fail(&status, error: ImageManagerError.pushFailed("registry rejected upload"))

    #expect(status.state == .failed)
    #expect(status.errorCode == .imagePushFailed)
    #expect(status.error?.contains("registry rejected upload") == true)
    #expect(ImageOperationStatusResponse(from: status).errorCode == "IMAGE_PUSH_FAILED")
  }

  @Test
  func partialRegistryCommitHasADedicatedAsyncErrorCode() {
    var status = makeStatus(kind: .push)
    let digest = "sha256:\(String(repeating: "a", count: 64))"

    ImageOperationStatusReducer.fail(
      &status,
      error: ImageManagerError.pushPartiallyCommitted(
        reference: status.reference,
        digest: digest,
        reason: "atomic rename failed"
      )
    )

    #expect(status.errorCode == .imagePushPartiallyCommitted)
    #expect(status.digest == digest)
    #expect(ImageOperationStatusResponse(from: status).digest == digest)
    #expect(ImageOperationStatusResponse(from: status).errorCode == "IMAGE_PUSH_PARTIALLY_COMMITTED")
  }

  @Test
  func unknownRegistryCommitOutcomeHasADedicatedAsyncErrorCode() {
    var status = makeStatus(kind: .push)
    let digest = "sha256:\(String(repeating: "a", count: 64))"

    ImageOperationStatusReducer.fail(
      &status,
      error: ImageManagerError.pushCommitOutcomeUnknown(
        reference: status.reference,
        digest: digest,
        reason: "manifest process was interrupted"
      )
    )

    #expect(status.errorCode == .imagePushCommitOutcomeUnknown)
    #expect(status.digest == digest)
    #expect(ImageOperationStatusResponse(from: status).digest == digest)
    #expect(ImageOperationStatusResponse(from: status).errorCode == "IMAGE_PUSH_COMMIT_OUTCOME_UNKNOWN")
  }

  @Test
  func activeProgressStaysBelowCompletionUntilTheOperationCompletes() {
    var pull = makeStatus(kind: .pull, reference: "registry.example.com/vm/pull:latest")
    ImageOperationStatusReducer.update(
      &pull,
      update: ImageOperationProgressUpdate(bytesCompletedDelta: 100, bytesTotal: 100)
    )

    #expect(pull.progress == 0.99)
    #expect(ImageOperationStatusResponse(from: pull).progress == 0.99)

    var push = makeStatus(kind: .push, reference: "registry.example.com/vm/push:latest")
    ImageOperationStatusReducer.update(
      &push,
      update: ImageOperationProgressUpdate(stage: .uploading, stageProgress: 1.0)
    )

    #expect(push.stageProgress == 1.0)
    #expect(push.progress == 0.99)

    let record = ImageRecord(
      reference: pull.reference,
      digest: "sha256:\(String(repeating: "c", count: 64))",
      localPath: "/tmp/image.bundle"
    )
    ImageOperationStatusReducer.complete(&pull, record: record)

    #expect(pull.progress == 1.0)
  }

  @Test
  func failuresExposeSpecificMachineReadableErrorCodes() {
    let cases: [(ImageManagerError, ImageOperationErrorCode)] = [
      (.invalidReference("missing repository"), .invalidReference),
      (.invalidImage("missing Disk.img"), .invalidImage),
      (.unsupportedImageFormat("formatVersion 2"), .unsupportedImageFormat),
      (.imageNotFound("registry.example.com/vm:missing"), .imageNotFound),
      (.imageInUse("image is being deleted"), .imageInUse),
    ]

    for (error, expectedCode) in cases {
      var status = makeStatus(kind: .pull, reference: "registry.example.com/vm:latest")
      ImageOperationStatusReducer.fail(&status, error: error)

      #expect(status.errorCode == expectedCode)
      #expect(ImageOperationStatusResponse(from: status).errorCode == expectedCode.rawValue)
      #expect(status.error == error.localizedDescription)
    }
  }

  @Test
  func infrastructureFailuresUseOperationSpecificCodes() {
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
      var status = makeStatus(kind: testCase.kind, reference: "registry.example.com/vm:latest")
      ImageOperationStatusReducer.fail(&status, error: testCase.error)

      #expect(status.errorCode == testCase.expectedCode)
      #expect(ImageOperationStatusResponse(from: status).errorCode == testCase.expectedCode.rawValue)
    }
  }

  @Test
  func statusResponseRoundsProgressAndOmitsLabels() throws {
    var status = makeStatus(kind: .pull)
    ImageOperationStatusReducer.update(
      &status,
      update: ImageOperationProgressUpdate(
        bytesCompletedDelta: 3_060_910_946,
        bytesTotal: 41_790_509_309
      )
    )

    let response = ImageOperationStatusResponse(from: status)
    let data = try JSONEncoder().encode(response)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(response.progress == 0.07)
    #expect(response.statusUrl == "/v1/images/pull/operations/\(status.id.uuidString)")
    #expect(object["message"] == nil)
    #expect(object["phase"] == nil)
    #expect(object["phaseProgress"] == nil)
    #expect(object["stage"] == nil)
  }

  @Test
  func pushStatusTracksCompressionUploadAndFinalizationStages() {
    var status = makeStatus(kind: .push)

    ImageOperationStatusReducer.update(
      &status,
      update: ImageOperationProgressUpdate(stage: .compressing, chunksTotal: 4, bytesTotal: 100)
    )
    ImageOperationStatusReducer.update(
      &status,
      update: ImageOperationProgressUpdate(
        stage: .compressing,
        chunksCompletedDelta: 1,
        bytesCompletedDelta: 25
      )
    )

    let compressingResponse = ImageOperationStatusResponse(from: status)
    #expect(status.stage == .compressing)
    #expect(status.stageProgress == 0.25)
    #expect(compressingResponse.stage == "compressing")
    #expect(compressingResponse.stageProgress == 0.25)
    #expect(compressingResponse.progress == 0.13)
    #expect(compressingResponse.chunksCompleted == 1)
    #expect(compressingResponse.bytesCompleted == 25)

    ImageOperationStatusReducer.update(
      &status,
      update: ImageOperationProgressUpdate(
        stage: .uploading,
        progress: 0.5,
        stageProgress: 0,
        setChunksCompleted: 0,
        chunksTotal: 2,
        setBytesCompleted: 0,
        bytesTotal: 50
      )
    )

    #expect(status.stage == .uploading)
    #expect(status.stageProgress == 0)
    #expect(status.progress == 0.5)
    #expect(status.chunksCompleted == 0)
    #expect(status.bytesCompleted == 0)

    ImageOperationStatusReducer.update(
      &status,
      update: ImageOperationProgressUpdate(
        stage: .uploading,
        chunksCompletedDelta: 1,
        bytesCompletedDelta: 25
      )
    )

    let uploadingResponse = ImageOperationStatusResponse(from: status)
    #expect(uploadingResponse.stage == "uploading")
    #expect(uploadingResponse.stageProgress == 0.5)
    #expect(uploadingResponse.progress == 0.75)
    #expect(uploadingResponse.chunksCompleted == 1)
    #expect(uploadingResponse.bytesCompleted == 25)

    ImageOperationStatusReducer.update(
      &status,
      update: ImageOperationProgressUpdate(stage: .finalizing, progress: 0.99, stageProgress: 0)
    )

    let finalizingResponse = ImageOperationStatusResponse(from: status)
    #expect(finalizingResponse.stage == "finalizing")
    #expect(finalizingResponse.stageProgress == 0)
    #expect(finalizingResponse.progress == 0.99)
    #expect(finalizingResponse.chunksCompleted == 0)
    #expect(finalizingResponse.chunksTotal == nil)
    #expect(finalizingResponse.bytesCompleted == 0)
    #expect(finalizingResponse.bytesTotal == nil)
    #expect(finalizingResponse.averageSpeedMBps == nil)

    let record = ImageRecord(
      reference: status.reference,
      digest: "sha256:\(String(repeating: "d", count: 64))",
      localPath: "/tmp/finalized.bundle"
    )
    ImageOperationStatusReducer.complete(&status, record: record)

    #expect(status.progress == 1.0)
    #expect(status.stageProgress == 1.0)
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
  func progressUpdatesClampInvalidValuesAndSaturateCounters() {
    var status = makeStatus(kind: .pull)

    ImageOperationStatusReducer.update(
      &status,
      update: ImageOperationProgressUpdate(
        progress: .nan,
        setChunksCompleted: Int.max,
        chunksTotal: -1,
        setBytesCompleted: UInt64.max
      )
    )
    ImageOperationStatusReducer.update(
      &status,
      update: ImageOperationProgressUpdate(chunksCompletedDelta: 1, bytesCompletedDelta: 1)
    )

    #expect(status.progress == 0)
    #expect(status.chunksCompleted == Int.max)
    #expect(status.chunksTotal == 0)
    #expect(status.bytesCompleted == UInt64.max)

    ImageOperationStatusReducer.update(
      &status,
      update: ImageOperationProgressUpdate(chunksCompletedDelta: Int.min)
    )
    #expect(status.chunksCompleted == 0)
  }

  @Test
  func cancellationRequestBecomesTerminalAfterTaskReportsCancellation() {
    var status = makeStatus(kind: .pull)
    ImageOperationStatusReducer.requestCancellation(&status)

    #expect(status.state == .cancelling)
    #expect(status.state.isTerminal == false)
    #expect(status.completedAt == nil)
    #expect(status.errorCode == nil)

    ImageOperationStatusReducer.fail(&status, error: CancellationError())

    // A completion arriving after terminalization must not resurrect the operation.
    let record = ImageRecord(
      reference: status.reference,
      digest: "sha256:\(String(repeating: "b", count: 64))",
      localPath: "/tmp/image.bundle"
    )
    ImageOperationStatusReducer.complete(&status, record: record)

    #expect(status.state == .cancelled)
    #expect(status.digest == nil)
    #expect(status.errorCode == .imagePullCancelled)
    #expect(ImageOperationStatusResponse(from: status).errorCode == "IMAGE_PULL_CANCELLED")
  }

  @Test
  func committedCompletionWinsLateCancellationRequest() {
    var status = makeStatus(kind: .pull)
    let record = ImageRecord(
      reference: status.reference,
      digest: "sha256:\(String(repeating: "c", count: 64))",
      localPath: "/tmp/image.bundle"
    )

    ImageOperationStatusReducer.requestCancellation(&status)
    ImageOperationStatusReducer.complete(&status, record: record)

    #expect(status.state == .completed)
    #expect(status.digest == record.digest)
    #expect(status.completedAt != nil)
    #expect(status.errorCode == nil)
  }

  @Test
  func progressAfterCancellationKeepsCancellingState() {
    var status = makeStatus(kind: .push)

    ImageOperationStatusReducer.requestCancellation(&status)
    ImageOperationStatusReducer.update(
      &status,
      update: ImageOperationProgressUpdate(
        stage: .uploading,
        chunksCompletedDelta: 1,
        chunksTotal: 4,
        bytesCompletedDelta: 256,
        bytesTotal: 1024
      )
    )

    #expect(status.state == .cancelling)
    #expect(status.stage == .uploading)
    #expect(status.chunksCompleted == 1)
    #expect(status.bytesCompleted == 256)
    #expect(status.progress == 0.625)
  }
}
