import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core), .serialized)
struct VMManagerInstallationOperationTests {
  @Test
  func forceDeleteWaitsForTrackedInstallationTaskTailBeforeRemovingBundle() async throws {
    try await withTemporaryDirectory(prefix: "installation-tail-delete") { root in
      let config = makeTestConfig(root: root)
      let bundleRemoval = InstallationBundleRemovalRecorder()
      let vmManager = VMManager(
        persistenceStore: PersistenceStore(databasePath: config.storage.databasePath),
        eventBus: EventBus(),
        config: config,
        vmBundleRemover: { path in
          bundleRemoval.record()
          try FileManager.default.removeItem(atPath: path)
        }
      )
      let definition = try await vmManager.createVM(name: "delete-install-tail", resources: .default)
      let taskStarted = InstallationOperationSignal()
      let cancellationObserved = InstallationOperationSignal()
      let allowTaskExit = InstallationOperationExitGate()
      let installationTask = Task<Void, Never> {
        taskStarted.signal()
        await withTaskCancellationHandler {
          await allowTaskExit.wait()
        } onCancel: {
          cancellationObserved.signal()
        }
      }
      await taskStarted.wait()
      try await vmManager.setInstallationTaskForTesting(installationTask, vmId: definition.id)

      let deleteTask = Task {
        try await vmManager.deleteVM(definition.id, force: true)
      }
      await cancellationObserved.wait()

      #expect(await vmManager.currentVMOperationForTesting(definition.id) == "delete")
      #expect(bundleRemoval.wasCalled == false)

      await allowTaskExit.open()
      try await deleteTask.value

      #expect(bundleRemoval.wasCalled)
      #expect(try await vmManager.vmExists(definition.id) == false)
    }
  }

  @Test
  func forceDeleteWaitsForCancelledInstallerRecoveryBeforeRemovingBundle() async throws {
    try await withTemporaryDirectory(prefix: "installer-recovery-delete") { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let bundleRemoval = InstallationBundleRemovalRecorder()
      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: EventBus(),
        config: config,
        vmBundleRemover: { path in
          bundleRemoval.record()
          try FileManager.default.removeItem(atPath: path)
        }
      )
      var definition = try await vmManager.createVM(name: "delete-recovery", resources: .default)
      definition.updateState(.installing)
      definition.updateInstallation(VMInstallation(
        state: .finalizing,
        message: "Installation finalization pending"
      ))
      try makeCompleteBundle(definition)
      try await vmManager.replaceDefinitionForTesting(definition.id, definition: definition)

      let recoveryStarted = InstallationOperationSignal()
      let cancellationObserved = InstallationOperationSignal()
      let allowRecoveryExit = InstallationOperationExitGate()
      let recoveryTask = Task<Void, Never> {
        recoveryStarted.signal()
        await withTaskCancellationHandler {
          await allowRecoveryExit.wait()
        } onCancel: {
          cancellationObserved.signal()
        }
      }
      await recoveryStarted.wait()
      try await vmManager.setInstallerRecoveryTaskForTesting(recoveryTask, vmId: definition.id)

      let deleteTask = Task {
        try await vmManager.deleteVM(definition.id, force: true)
      }
      await cancellationObserved.wait()

      #expect(await vmManager.currentVMOperationForTesting(definition.id) == "delete")
      #expect(bundleRemoval.wasCalled == false)

      await allowRecoveryExit.open()
      try await deleteTask.value

      #expect(bundleRemoval.wasCalled)
      #expect(try await vmManager.vmExists(definition.id) == false)
    }
  }

  private func makeCompleteBundle(_ definition: VMDefinition) throws {
    try FileManager.default.createDirectory(atPath: definition.paths.bundlePath, withIntermediateDirectories: true)
    for path in [
      definition.paths.diskImagePath,
      definition.paths.auxiliaryStoragePath,
      definition.paths.hardwareModelPath,
      definition.paths.machineIdentifierPath,
    ] {
      try Data([0x01]).write(to: URL(fileURLWithPath: path))
    }
  }
}

private final class InstallationBundleRemovalRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var called = false

  var wasCalled: Bool { lock.withLock { called } }

  func record() {
    lock.withLock { called = true }
  }
}

private final class InstallationOperationSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var signalled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func signal() {
    let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      signalled = true
      defer { waiters.removeAll() }
      return waiters
    }
    continuations.forEach { $0.resume() }
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock {
        if signalled { return true }
        waiters.append(continuation)
        return false
      }
      if shouldResume { continuation.resume() }
    }
  }
}

private actor InstallationOperationExitGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard isOpen == false else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let continuations = waiters
    waiters.removeAll()
    continuations.forEach { $0.resume() }
  }
}
