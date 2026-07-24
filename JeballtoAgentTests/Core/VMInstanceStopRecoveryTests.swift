import Foundation
import Testing
import Virtualization
@testable import JeballtoAgent

private enum StopRecoveryTestError: Error, LocalizedError, Equatable {
  case stopFailed

  var errorDescription: String? { "simulated stop failure" }
}

@Suite(.tags(.core))
@MainActor
struct VMInstanceStopRecoveryTests {
  @Test
  func failedStopRecoveryDecisionRequiresInactiveRuntimeAndAllowedLifecycle() {
    let normallyRecoverable: Set<VMState> = [.stopping, .error, .stopped]
    for runtimeState in [VZVirtualMachine.State.stopped, .error] {
      for logicalState in VMState.allCases {
        #expect(VMInstance.shouldCompleteFailedStop(
          runtimeState: runtimeState,
          logicalState: logicalState,
          forceLifecycle: false
        ) == normallyRecoverable.contains(logicalState))
        #expect(VMInstance.shouldCompleteFailedStop(
          runtimeState: runtimeState,
          logicalState: logicalState,
          forceLifecycle: true
        ))
      }
    }

    for runtimeState in [
      VZVirtualMachine.State.running,
      .stopping,
      .paused,
      .starting,
      .pausing,
      .resuming,
    ] {
      #expect(VMInstance.shouldCompleteFailedStop(
        runtimeState: runtimeState,
        logicalState: .stopping,
        forceLifecycle: false
      ) == false)
      #expect(VMInstance.shouldCompleteFailedStop(
        runtimeState: runtimeState,
        logicalState: .running,
        forceLifecycle: true
      ) == false)
    }
  }

  @Test
  func inactiveRuntimeFailureCompletesStopAndRemovesSavedState() async throws {
    try await withTemporaryDirectory(prefix: "vm-stop-recovery") { root in
      let eventBus = EventBus()
      let instance = try makeInstance(root: root, state: .stopping, eventBus: eventBus)
      try Data("saved state".utf8).write(to: URL(fileURLWithPath: instance.definition.paths.saveFilePath))

      try instance.recoverInactiveRuntimeStopOrRethrow(
        StopRecoveryTestError.stopFailed,
        runtimeState: .stopped,
        forceLifecycle: false
      )
      await eventBus.waitUntilIdle()

      #expect(instance.currentState == .stopped)
      #expect(instance.definition.state == .stopped)
      #expect(FileManager.default.fileExists(atPath: instance.definition.paths.saveFilePath) == false)
      #expect(eventBus.getEvents(forVM: instance.definition.id).map(\.event) == [
        .stateChanged(vmId: instance.definition.id, from: .stopping, to: .stopped),
        .vmStopped(vmId: instance.definition.id),
      ])
    }
  }

  @Test
  func delegateCompletedStopIsNotPublishedTwice() async throws {
    try await withTemporaryDirectory(prefix: "vm-stop-delegate-wins") { root in
      let eventBus = EventBus()
      let instance = try makeInstance(root: root, state: .stopped, eventBus: eventBus)
      try Data("saved state".utf8).write(to: URL(fileURLWithPath: instance.definition.paths.saveFilePath))

      try instance.recoverInactiveRuntimeStopOrRethrow(
        StopRecoveryTestError.stopFailed,
        runtimeState: .stopped,
        forceLifecycle: false
      )
      await eventBus.waitUntilIdle()

      #expect(instance.currentState == .stopped)
      #expect(FileManager.default.fileExists(atPath: instance.definition.paths.saveFilePath) == false)
      #expect(eventBus.getEvents(forVM: instance.definition.id).isEmpty)
    }
  }

  @Test
  func activeRuntimeFailureIsRethrownAndRecorded() async throws {
    try await withTemporaryDirectory(prefix: "vm-stop-active-failure") { root in
      let eventBus = EventBus()
      let instance = try makeInstance(root: root, state: .stopping, eventBus: eventBus)
      try Data("saved state".utf8).write(to: URL(fileURLWithPath: instance.definition.paths.saveFilePath))

      do {
        try instance.recoverInactiveRuntimeStopOrRethrow(
          StopRecoveryTestError.stopFailed,
          runtimeState: .running,
          forceLifecycle: false
        )
        Issue.record("Expected active runtime stop failure to be rethrown")
      } catch let error as StopRecoveryTestError {
        #expect(error == .stopFailed)
      }
      await eventBus.waitUntilIdle()

      #expect(instance.currentState == .error)
      #expect(instance.definition.state == .error)
      #expect(FileManager.default.fileExists(atPath: instance.definition.paths.saveFilePath))
      #expect(eventBus.getEvents(forVM: instance.definition.id).map(\.event) == [
        .stateChanged(vmId: instance.definition.id, from: .stopping, to: .error),
        .errorOccurred(vmId: instance.definition.id, error: "simulated stop failure"),
      ])
    }
  }

  @Test
  func forcedStopAcceptsInactiveRuntimeFromRunningLifecycle() async throws {
    try await withTemporaryDirectory(prefix: "vm-force-stop-recovery") { root in
      let eventBus = EventBus()
      let instance = try makeInstance(root: root, state: .running, eventBus: eventBus)
      try Data("saved state".utf8).write(to: URL(fileURLWithPath: instance.definition.paths.saveFilePath))

      try instance.recoverInactiveRuntimeStopOrRethrow(
        StopRecoveryTestError.stopFailed,
        runtimeState: .error,
        forceLifecycle: true
      )
      await eventBus.waitUntilIdle()

      #expect(instance.currentState == .stopped)
      #expect(instance.definition.state == .stopped)
      #expect(FileManager.default.fileExists(atPath: instance.definition.paths.saveFilePath) == false)
      #expect(eventBus.getEvents(forVM: instance.definition.id).map(\.event) == [
        .stateChanged(vmId: instance.definition.id, from: .running, to: .stopped),
        .vmStopped(vmId: instance.definition.id),
      ])
    }
  }

  @Test
  func callbacksFromRetiredRuntimeAreIgnored() async throws {
    try await withTemporaryDirectory(prefix: "vm-retired-runtime") { root in
      let eventBus = EventBus()
      let instance = try makeInstance(root: root, state: .running, eventBus: eventBus)

      instance.handleErrorCallback(StopRecoveryTestError.stopFailed, from: UUID())
      instance.handleStopCallback(from: UUID())
      await eventBus.waitUntilIdle()

      #expect(instance.currentState == .running)
      #expect(instance.definition.state == .running)
      #expect(eventBus.getEvents(forVM: instance.definition.id).isEmpty)
    }
  }

  private func makeInstance(root: String, state: VMState, eventBus: EventBus) throws -> VMInstance {
    let id = UUID()
    let paths = VMPaths.forVM(id: id, baseDir: root)
    try FileManager.default.createDirectory(atPath: paths.bundlePath, withIntermediateDirectories: true)
    return VMInstance(
      definition: VMDefinition(
        id: id,
        name: "stop-recovery-test",
        state: state,
        resources: .default,
        paths: paths
      ),
      eventBus: eventBus
    )
  }
}
