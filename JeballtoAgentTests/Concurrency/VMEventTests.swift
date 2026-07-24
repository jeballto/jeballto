import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.concurrency))
struct VMEventTests {
  @Test(arguments: [
    (VMEvent.vmCreated(vmId: UUID(), name: "test"), "VM_CREATED"),
    (VMEvent.vmDeleted(vmId: UUID(), name: "test"), "VM_DELETED"),
    (VMEvent.vmStarting(vmId: UUID()), "VM_STARTING"),
    (VMEvent.vmRunning(vmId: UUID()), "VM_RUNNING"),
    (VMEvent.vmStopping(vmId: UUID()), "VM_STOPPING"),
    (VMEvent.vmStopped(vmId: UUID()), "VM_STOPPED"),
    (VMEvent.vmPaused(vmId: UUID()), "VM_PAUSED"),
    (VMEvent.vmResumed(vmId: UUID()), "VM_RESUMED"),
    (VMEvent.stateChanged(vmId: UUID(), from: .created, to: .stopped), "STATE_CHANGED"),
    (VMEvent.errorOccurred(vmId: UUID(), error: "oops"), "ERROR_OCCURRED"),
    (VMEvent.sshPortAssigned(vmId: UUID(), port: 2222), "SSH_PORT_ASSIGNED"),
    (VMEvent.sshPortReleased(vmId: UUID()), "SSH_PORT_RELEASED"),
    (VMEvent.vncPortAssigned(vmId: UUID(), port: 5901), "VNC_PORT_ASSIGNED"),
    (VMEvent.vncPortReleased(vmId: UUID()), "VNC_PORT_RELEASED"),
    (VMEvent.installStarted(vmId: UUID()), "INSTALL_STARTED"),
    (
      VMEvent.installProgress(
        vmId: UUID(), progress: 0.5, phaseProgress: 0.5,
        message: "downloading", phase: "download",
        bytesDownloaded: nil, bytesTotal: nil, downloadSpeed: nil
      ),
      "INSTALL_PROGRESS"
    ),
    (VMEvent.installCompleted(vmId: UUID()), "INSTALL_COMPLETED"),
    (VMEvent.installCancelled(vmId: UUID()), "INSTALL_CANCELLED"),
    (VMEvent.installFailed(vmId: UUID(), error: "fail"), "INSTALL_FAILED"),
    (VMEvent.vmCloned(vmId: UUID(), sourceVmId: UUID(), name: "clone"), "VM_CLONED"),
    (VMEvent.vmResourcesUpdated(vmId: UUID()), "VM_RESOURCES_UPDATED"),
    (VMEvent.guiOpened(vmId: UUID()), "GUI_OPENED"),
    (VMEvent.guiClosed(vmId: UUID()), "GUI_CLOSED"),
  ])
  func vmLifecycleEventTypeStrings(_ input: (event: VMEvent, expected: String)) {
    #expect(input.event.eventType == input.expected)
  }

  @Test(arguments: [
    (VMEvent.imagePullStarted(reference: "r"), "IMAGE_PULL_STARTED"),
    (VMEvent.imagePulled(reference: "r"), "IMAGE_PULLED"),
    (VMEvent.imagePullFailed(reference: "r", error: "e"), "IMAGE_PULL_FAILED"),
    (VMEvent.imagePushStarted(reference: "r"), "IMAGE_PUSH_STARTED"),
    (VMEvent.imagePushed(reference: "r"), "IMAGE_PUSHED"),
    (VMEvent.imagePushFailed(reference: "r", error: "e"), "IMAGE_PUSH_FAILED"),
    (VMEvent.imageDeleted(reference: "r"), "IMAGE_DELETED"),
  ])
  func imageEventTypeStrings(_ input: (event: VMEvent, expected: String)) {
    #expect(input.event.eventType == input.expected)
  }

  @Test(arguments: [
    (VMEvent.jeballtofileStarted(executionId: UUID(), vmId: UUID()), "JEBALLTOFILE_STARTED"),
    (
      VMEvent.jeballtofileStepStarted(executionId: UUID(), vmId: UUID(), step: 0, stepType: "execute"),
      "JEBALLTOFILE_STEP_STARTED"
    ),
    (
      VMEvent.jeballtofileStepCompleted(executionId: UUID(), vmId: UUID(), step: 0, stepType: "execute"),
      "JEBALLTOFILE_STEP_COMPLETED"
    ),
    (
      VMEvent.jeballtofileStepFailed(
        executionId: UUID(), vmId: UUID(), step: 0, stepType: "execute", error: "e"
      ),
      "JEBALLTOFILE_STEP_FAILED"
    ),
    (VMEvent.jeballtofileCompleted(executionId: UUID(), vmId: UUID()), "JEBALLTOFILE_COMPLETED"),
    (VMEvent.jeballtofileCancelled(executionId: UUID(), vmId: UUID(), step: 0), "JEBALLTOFILE_CANCELLED"),
    (VMEvent.jeballtofileFailed(executionId: UUID(), vmId: UUID(), step: 0, error: "e"), "JEBALLTOFILE_FAILED"),
  ])
  func jeballtofileEventTypeStrings(_ input: (event: VMEvent, expected: String)) {
    #expect(input.event.eventType == input.expected)
  }

  @Test
  func vmIdIsExtractedFromVmLifecycleEvents() {
    let id = UUID()
    let sourceId = UUID()

    #expect(VMEvent.vmCreated(vmId: id, name: "x").vmId == id)
    #expect(VMEvent.vmDeleted(vmId: id, name: "x").vmId == id)
    #expect(VMEvent.vmStarting(vmId: id).vmId == id)
    #expect(VMEvent.vmRunning(vmId: id).vmId == id)
    #expect(VMEvent.vmStopping(vmId: id).vmId == id)
    #expect(VMEvent.vmStopped(vmId: id).vmId == id)
    #expect(VMEvent.vmPaused(vmId: id).vmId == id)
    #expect(VMEvent.vmResumed(vmId: id).vmId == id)
    #expect(VMEvent.stateChanged(vmId: id, from: .stopped, to: .running).vmId == id)
    #expect(VMEvent.errorOccurred(vmId: id, error: "e").vmId == id)
    #expect(VMEvent.sshPortAssigned(vmId: id, port: 2222).vmId == id)
    #expect(VMEvent.sshPortReleased(vmId: id).vmId == id)
    #expect(VMEvent.vncPortAssigned(vmId: id, port: 5901).vmId == id)
    #expect(VMEvent.vncPortReleased(vmId: id).vmId == id)
    #expect(VMEvent.installStarted(vmId: id).vmId == id)
    #expect(
      VMEvent.installProgress(
        vmId: id, progress: 0.5, phaseProgress: 0.5,
        message: "downloading", phase: "download",
        bytesDownloaded: nil, bytesTotal: nil, downloadSpeed: nil
      ).vmId == id
    )
    #expect(VMEvent.installCompleted(vmId: id).vmId == id)
    #expect(VMEvent.installCancelled(vmId: id).vmId == id)
    #expect(VMEvent.installFailed(vmId: id, error: "e").vmId == id)
    #expect(VMEvent.vmCloned(vmId: id, sourceVmId: sourceId, name: "c").vmId == id)
    #expect(VMEvent.vmResourcesUpdated(vmId: id).vmId == id)
    #expect(VMEvent.guiOpened(vmId: id).vmId == id)
    #expect(VMEvent.guiClosed(vmId: id).vmId == id)
  }

  @Test
  func vmIdIsNilForImageEvents() {
    let events: [VMEvent] = [
      .imagePullStarted(reference: "r"),
      .imagePulled(reference: "r"),
      .imagePullFailed(reference: "r", error: "e"),
      .imagePushStarted(reference: "r"),
      .imagePushed(reference: "r"),
      .imagePushFailed(reference: "r", error: "e"),
      .imageDeleted(reference: "r"),
    ]

    for event in events {
      #expect(event.vmId == nil, "Expected nil vmId for \(event.eventType)")
    }
  }

  @Test
  func jeballtofileStepEventsExposeVmId() {
    let executionId = UUID()
    let vmId = UUID()

    #expect(VMEvent.jeballtofileStepStarted(
      executionId: executionId,
      vmId: vmId,
      step: 0,
      stepType: "execute"
    ).vmId == vmId)
    #expect(VMEvent.jeballtofileStepCompleted(
      executionId: executionId,
      vmId: vmId,
      step: 0,
      stepType: "execute"
    ).vmId == vmId)
    #expect(VMEvent.jeballtofileStepFailed(
      executionId: executionId,
      vmId: vmId,
      step: 0,
      stepType: "execute",
      error: "e"
    ).vmId == vmId)
  }

  @Test
  func jeballtofileStartedCompletedAndFailedExposeVmId() {
    let execId = UUID()
    let vmId = UUID()

    #expect(VMEvent.jeballtofileStarted(executionId: execId, vmId: vmId).vmId == vmId)
    #expect(VMEvent.jeballtofileCompleted(executionId: execId, vmId: vmId).vmId == vmId)
    #expect(VMEvent.jeballtofileCancelled(executionId: execId, vmId: vmId, step: 0).vmId == vmId)
    #expect(VMEvent.jeballtofileFailed(executionId: execId, vmId: vmId, step: 0, error: "e").vmId == vmId)
  }
}
