import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.concurrency))
struct EventMappingAndExecutionStateTests {
  @Test
  func vmEventTypeAndVmIdAreExposed() {
    let vmId = UUID()
    let stateChanged = VMEvent.stateChanged(vmId: vmId, from: .created, to: .running)
    let imageEvent = VMEvent.imagePullStarted(reference: "registry/repo:latest")

    #expect(stateChanged.eventType == "STATE_CHANGED")
    #expect(stateChanged.vmId == vmId)
    #expect(imageEvent.eventType == "IMAGE_PULL_STARTED")
    #expect(imageEvent.vmId == nil)
  }

  @Test
  func eventResponseContainsMappedData() {
    let vmId = UUID()
    let timestamp = Date(timeIntervalSince1970: 10)
    let stateEvent = RecordedEvent(timestamp: timestamp, event: .stateChanged(vmId: vmId, from: .created, to: .running))

    let response = EventResponse(from: stateEvent)

    #expect(response.type == "STATE_CHANGED")
    #expect(response.vmId == vmId.uuidString)
    #expect(response.data?["from"] == "created")
    #expect(response.data?["to"] == "running")
  }

  @Test
  func eventResponseMapsImageAndJeballtofilePayloads() {
    let executionID = UUID()
    let vmID = UUID()

    let imageFailed = EventResponse(
      from: RecordedEvent(
        timestamp: Date(timeIntervalSince1970: 20),
        event: .imagePushFailed(reference: "registry/repo:latest", error: "denied")
      )
    )
    let stepFailed = EventResponse(
      from: RecordedEvent(
        timestamp: Date(timeIntervalSince1970: 30),
        event: .jeballtofileStepFailed(
          executionId: executionID,
          vmId: vmID,
          step: 2,
          stepType: "execute",
          error: "boom"
        )
      )
    )
    let completed = EventResponse(
      from: RecordedEvent(
        timestamp: Date(timeIntervalSince1970: 40),
        event: .jeballtofileCompleted(executionId: executionID, vmId: vmID)
      )
    )
    let cancelled = EventResponse(
      from: RecordedEvent(
        timestamp: Date(timeIntervalSince1970: 50),
        event: .jeballtofileCancelled(executionId: executionID, vmId: vmID, step: 3)
      )
    )

    #expect(imageFailed.data?["reference"] == "registry/repo:latest")
    #expect(imageFailed.data?["error"] == "denied")
    #expect(stepFailed.data?["executionId"] == executionID.uuidString)
    #expect(stepFailed.data?["step"] == "2")
    #expect(stepFailed.data?["stepType"] == "execute")
    #expect(stepFailed.vmId == vmID.uuidString)
    #expect(completed.data?["vmId"] == vmID.uuidString)
    #expect(completed.vmId == vmID.uuidString)
    #expect(cancelled.data?["step"] == "3")
    #expect(cancelled.vmId == vmID.uuidString)
  }

  @Test
  func eventResponsePreservesInstallationProgressAndFailureDetails() throws {
    let vmID = UUID()
    let progress = EventResponse(
      from: RecordedEvent(
        timestamp: Date(timeIntervalSince1970: 60),
        event: .installProgress(
          vmId: vmID,
          progress: 0.5,
          phaseProgress: 0.25,
          message: "Downloading",
          phase: "downloading",
          bytesDownloaded: 10,
          bytesTotal: 40,
          downloadSpeed: 5
        )
      )
    )
    let failed = EventResponse(
      from: RecordedEvent(
        timestamp: Date(timeIntervalSince1970: 70),
        event: .installFailed(vmId: vmID, error: "invalid IPSW")
      )
    )

    #expect(progress.data?["progress"] == "0.5")
    #expect(progress.data?["phaseProgress"] == "0.25")
    #expect(progress.data?["bytesTotal"] == "40")
    #expect(failed.data?["error"] == "invalid IPSW")

    let noData = EventResponse(
      from: RecordedEvent(timestamp: Date(timeIntervalSince1970: 80), event: .vmRunning(vmId: vmID))
    )
    let data = try JSONEncoder().encode(noData)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["data"] is NSNull)
    #expect(json["vmId"] as? String == vmID.uuidString)
  }

  @Test
  func eventListResponseReportsTotals() {
    let vmID = UUID()
    let events = [
      RecordedEvent(timestamp: Date(timeIntervalSince1970: 1), event: .vmCreated(vmId: vmID, name: "one")),
      RecordedEvent(timestamp: Date(timeIntervalSince1970: 2), event: .vmRunning(vmId: vmID)),
    ]

    let response = EventListResponse(events: events)

    #expect(response.total == 2)
    #expect(response.events.count == 2)
    #expect(response.events[0].type == "VM_CREATED")
    #expect(response.events[1].type == "VM_RUNNING")
  }

  @Test
  func jeballtofileExecutionTracksLifecycleAndCancellation() {
    let execution = JeballtofileExecution(id: UUID(), vmId: UUID(), totalSteps: 2)

    execution.startStep(0, type: .start)
    execution.completeStep(0, message: "ok")
    execution.startStep(1, type: .execute)
    execution.failStep(1, error: "boom")

    #expect(execution.status == .failed)
    #expect(execution.currentStep == 1)
    #expect(execution.stepResults.count == 2)
    #expect(execution.stepResults[1].status == .failed)
    #expect(execution.error?.contains("Step 1 failed") == true)

    #expect(execution.cancel() == false)
    #expect(execution.status == .failed)
    #expect(execution.isCancelled == false)
  }

  @Test
  func jeballtofileExecutionMarksCancelledStepWithoutFailure() {
    let execution = JeballtofileExecution(id: UUID(), vmId: UUID(), totalSteps: 1)

    execution.startStep(0, type: .wait)
    execution.cancelStep(0, message: "Cancelled by user")

    #expect(execution.status == .cancelled)
    #expect(execution.stepResults[0].status == .cancelled)
    #expect(execution.stepResults[0].message == "Cancelled by user")
    #expect(execution.error == nil)
  }

  @Test
  func jeballtofileExecutionSupportsCompleteAndFailTransitions() {
    let execution = JeballtofileExecution(id: UUID(), vmId: UUID(), totalSteps: 1)
    execution.complete()

    #expect(execution.status == .completed)
    #expect(execution.error == nil)

    #expect(execution.fail("terminal failure") == false)
    #expect(execution.status == .completed)
    #expect(execution.error == nil)
  }

  @Test
  func failStepWithoutTrackedStepStillMarksExecutionFailed() {
    let execution = JeballtofileExecution(id: UUID(), vmId: UUID(), totalSteps: 1)

    execution.failStep(99, error: "missing step")

    #expect(execution.status == .failed)
    #expect(execution.stepResults.isEmpty)
    #expect(execution.error?.contains("Step 99 failed") == true)
  }

  @Test
  func jeballtofileTerminalTransitionsHaveExactlyOneWinner() async {
    for _ in 0 ..< 100 {
      let execution = JeballtofileExecution(id: UUID(), vmId: UUID(), totalSteps: 0)
      let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
        group.addTask { execution.complete() }
        group.addTask { execution.cancel() }

        var count = 0
        for await won in group where won {
          count += 1
        }
        return count
      }

      #expect(winners == 1)
      #expect(execution.status == .completed || execution.status == .cancelled)
      #expect(execution.fail("late failure") == false)
    }
  }

  @Test
  func jeballtofileStatusResponseUsesOneAtomicExecutionSnapshot() throws {
    let execution = StatusGetterMutationExecution(id: UUID(), vmId: UUID(), totalSteps: 1)
    #expect(execution.startStep(0, type: .execute))

    let response = JeballtofileStatusResponse(from: execution)
    let result = try #require(response.stepResults.first)

    #expect(response.status == "running")
    #expect(result.status == "in_progress")
    #expect(result.message == nil)
    #expect(response.error == nil)
  }
}

private final class StatusGetterMutationExecution: JeballtofileExecution, @unchecked Sendable {
  override var status: JeballtofileExecutionStatus {
    let observedStatus = super.status
    _ = failStep(0, error: "concurrent failure")
    return observedStatus
  }
}
