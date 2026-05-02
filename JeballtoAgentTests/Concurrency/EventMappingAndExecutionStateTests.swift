import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.concurrency))
struct EventMappingAndExecutionStateTests {
  @Test
  func vmEventTypeAndVmIdAreExposed() {
    let vmId = UUID()
    let stateChanged = VMEvent.stateChanged(vmId: vmId, from: .created, to: .running)
    let imageEvent = VMEvent.imagePullStarted(reference: "registry/repo:v1")

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
        event: .imagePushFailed(reference: "registry/repo:v1", error: "denied")
      )
    )
    let stepFailed = EventResponse(
      from: RecordedEvent(
        timestamp: Date(timeIntervalSince1970: 30),
        event: .jeballtofileStepFailed(executionId: executionID, step: 2, stepType: "execute", error: "boom")
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

    #expect(imageFailed.data?["reference"] == "registry/repo:v1")
    #expect(imageFailed.data?["error"] == "denied")
    #expect(stepFailed.data?["executionId"] == executionID.uuidString)
    #expect(stepFailed.data?["step"] == "2")
    #expect(stepFailed.data?["stepType"] == "execute")
    #expect(stepFailed.vmId == nil)
    #expect(completed.data?["vmId"] == vmID.uuidString)
    #expect(completed.vmId == vmID.uuidString)
    #expect(cancelled.data?["step"] == "3")
    #expect(cancelled.vmId == vmID.uuidString)
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

    execution.cancel()
    #expect(execution.status == .cancelled)
    #expect(execution.isCancelled)
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

    execution.fail("terminal failure")
    #expect(execution.status == .failed)
    #expect(execution.error == "terminal failure")
  }

  @Test
  func failStepWithoutTrackedStepStillMarksExecutionFailed() {
    let execution = JeballtofileExecution(id: UUID(), vmId: UUID(), totalSteps: 1)

    execution.failStep(99, error: "missing step")

    #expect(execution.status == .failed)
    #expect(execution.stepResults.isEmpty)
    #expect(execution.error?.contains("Step 99 failed") == true)
  }
}
