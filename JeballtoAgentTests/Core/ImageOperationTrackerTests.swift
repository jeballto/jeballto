import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct ImageOperationTrackerTests {
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
    #expect(completed.state == .completed)
    #expect(completed.progress == 1.0)
    #expect(completed.digest == record.digest)
    #expect(completed.image == record)
  }

  @Test
  func failureMarksOperationFailed() async throws {
    let tracker = ImageOperationTracker()
    let started = await tracker.start(kind: .push, reference: "registry.example.com/vm/macos:latest")

    await tracker.fail(started.id, error: ImageManagerError.pushFailed("registry rejected upload"))

    let failed = try #require(await tracker.get(started.id))
    #expect(failed.state == .failed)
    #expect(failed.error?.contains("registry rejected upload") == true)
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
    #expect(object["message"] == nil)
    #expect(object["phase"] == nil)
    #expect(object["phaseProgress"] == nil)
    #expect(object["stage"] == nil)
  }

  @Test
  func pushStatusTracksCompressionAndUploadStages() async throws {
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
      stageStartedAt: nil,
      updatedAt: updatedAt,
      completedAt: nil,
      digest: nil,
      image: nil,
      error: nil
    )

    #expect(ImageOperationStatusResponse(from: running).averageSpeedMBps == 2.5)

    var completed = running
    completed.completedAt = startedAt.addingTimeInterval(8)
    #expect(ImageOperationStatusResponse(from: completed).averageSpeedMBps == 1.25)
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
