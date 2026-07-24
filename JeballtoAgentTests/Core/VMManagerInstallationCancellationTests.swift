import Foundation
import Testing
import Virtualization
@testable import JeballtoAgent

@Suite(.tags(.core), .serialized)
struct VMManagerInstallationCancellationTests {
  @Test
  func successfulInstallerCallbackWinsConcurrentCancellationAfterRecordingSuccess() {
    var didRecordSuccess = false

    let result = VMInstaller.resolveInstallationCompletion(
      .success(()),
      cancellationRequested: true,
      recordSuccess: { didRecordSuccess = true }
    )

    #expect(didRecordSuccess)
    if case .failure(let error) = result {
      Issue.record("Expected success, got \(error.localizedDescription)")
    }
  }

  @Test
  func installerSuccessIsNotReportedBeforeDurableMarkerWrite() {
    let result = VMInstaller.resolveInstallationCompletion(
      .success(()),
      cancellationRequested: false,
      recordSuccess: { throw InstallationCallbackTestError.markerWriteFailed }
    )

    guard case .failure(let error) = result,
          let installerError = error as? VMInstallerError,
          case .installationSuccessMarkerFailed = installerError else
    {
      Issue.record("Expected installationSuccessMarkerFailed")
      return
    }
  }

  @Test
  func failedInstallerCallbackMapsRequestedCancellationToCancellationError() {
    let result = VMInstaller.resolveInstallationCompletion(
      .failure(InstallationCallbackTestError.installFailed),
      cancellationRequested: true,
      recordSuccess: { Issue.record("Failure must not write a success marker") }
    )

    guard case .failure(let error) = result else {
      Issue.record("Expected callback failure")
      return
    }
    #expect(error is CancellationError)
  }

  @Test
  func downloadDelegateCancellationResumesAsCancellation() async throws {
    try await withTemporaryDirectory { root in
      let id = UUID()
      let definition = VMDefinition(
        id: id,
        name: "download-cancel",
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: root)
      )
      let installer = VMInstaller(vmDefinition: definition, eventBus: EventBus())
      let delegate = DownloadDelegate(
        installer: installer,
        destinationURL: URL(fileURLWithPath: root).appendingPathComponent("download.ipsw")
      )
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [SuspendedDownloadURLProtocol.self]
      let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      defer { session.invalidateAndCancel() }

      let downloadTask = Task<URL, Error> {
        try await withCheckedThrowingContinuation { continuation in
          delegate.startDownload(
            from: URL(string: "https://example.invalid/download.ipsw")!,
            session: session,
            continuation: continuation
          )
        }
      }

      await Task.yield()
      delegate.cancel()

      await #expect(throws: CancellationError.self) {
        try await downloadTask.value
      }
    }
  }

  @Test
  func downloadDelegateCancellationBeforeStartResumesAsCancellation() async throws {
    try await withTemporaryDirectory { root in
      let id = UUID()
      let definition = VMDefinition(
        id: id,
        name: "download-cancel-before-start",
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: root)
      )
      let installer = VMInstaller(vmDefinition: definition, eventBus: EventBus())
      let delegate = DownloadDelegate(
        installer: installer,
        destinationURL: URL(fileURLWithPath: root).appendingPathComponent("download.ipsw")
      )
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [SuspendedDownloadURLProtocol.self]
      let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
      defer { session.invalidateAndCancel() }

      delegate.cancel()

      await #expect(throws: CancellationError.self) {
        try await withCheckedThrowingContinuation { continuation in
          delegate.startDownload(
            from: URL(string: "https://example.invalid/download.ipsw")!,
            session: session,
            continuation: continuation
          )
        }
      }
    }
  }

  @Test
  func cancelledInstallationReturnsVMToRetryableCreatedState() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let eventBus = EventBus()
      let networkManager = NetworkManager(eventBus: eventBus)
      let portForwardingManager = PortForwardingManager(config: config.networking, eventBus: eventBus)
      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: eventBus,
        config: config,
        guiManager: nil,
        networkManager: networkManager,
        portForwardingManager: portForwardingManager
      )

      let definition = try await vmManager.createVM(name: "cancelled-install", resources: .default)
      let vmId = definition.id
      let instance = try await vmManager.getVMInstance(vmId)
      let recorder = EventTypeRecorder()
      let subscription = eventBus.subscribe { event in recorder.append(event.eventType) }
      defer { eventBus.unsubscribe(subscription) }

      try await MainActor.run {
        try instance.stateMachine.transition(to: .installing)
        instance.definition.updateState(.installing)
        instance.definition.updateInstallation(
          VMInstallation(state: .installing, message: "Installing")
        )
      }
      try await vmManager.replaceDefinitionForTesting(vmId, definition: MainActor.run { instance.definition })

      let installer = VMInstaller(vmDefinition: definition, eventBus: eventBus)
      let failureTask = Task<Void, Never> {
        await vmManager.handleInstallationFailure(
          vmId: vmId,
          instance: instance,
          installer: installer,
          error: CancellationError()
        )
      }
      failureTask.cancel()
      await failureTask.value
      await eventBus.waitUntilIdle()
      #expect(instance.currentState == .created)

      let persisted = try await persistenceStore.getVM(vmId)
      #expect(persisted.state == .created)
      #expect(persisted.installation?.state == .cancelled)
      #expect(recorder.values.contains("INSTALL_CANCELLED"))
      #expect(recorder.values.contains("INSTALL_FAILED") == false)
    }
  }

  @Test
  func forceDeleteCancelsTrackedInstallationBeforeRemovingBundle() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: EventBus(),
        config: config
      )
      let definition = try await vmManager.createVM(name: "delete-install", resources: .default)
      let instance = try await vmManager.getVMInstance(definition.id)
      try await MainActor.run {
        try instance.stateMachine.transition(to: .installing)
        instance.definition.updateState(.installing)
        instance.definition.updateInstallation(
          VMInstallation(state: .installing, message: "Installing")
        )
      }
      try await vmManager.replaceDefinitionForTesting(
        definition.id,
        definition: MainActor.run { instance.definition }
      )
      let cancellation = InstallationCancellationRecorder()
      let task = Task<Void, Never> {
        do {
          try await Task.sleep(for: .seconds(30))
        } catch {
          cancellation.record()
        }
      }
      try await vmManager.setInstallationTaskForTesting(task, vmId: definition.id)

      try await vmManager.deleteVM(definition.id, force: true)

      #expect(cancellation.wasObserved)
      #expect(try await vmManager.vmExists(definition.id) == false)
      #expect(FileManager.default.fileExists(atPath: definition.paths.bundlePath) == false)
    }
  }

  @Test
  func finalizingInstallationRecoversAsCompletedAfterRestart() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let definition = try makeFinalizingDefinition(config: config)
      try await persistenceStore.createVM(definition)

      let eventBus = EventBus()
      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: eventBus,
        config: config
      )
      try await vmManager.loadPersistedVMs()

      let recovered = try await vmManager.getVM(definition.id)
      #expect(recovered.state == .stopped)
      #expect(recovered.installation?.state == .completed)
    }
  }

  @Test
  func durableSuccessMarkerRecoversInstallingVMWithoutDeletingCompletedBundle() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let id = UUID()
      let definition = VMDefinition(
        id: id,
        name: "durable-install-success",
        state: .installing,
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: config.storage.vmStorageDir),
        installation: VMInstallation(state: .installing, message: "Installing")
      )
      try makeCompleteBundle(definition)
      try VMInstallationSuccessMarkerStore.recordSuccess(for: definition)
      try await persistenceStore.createVM(definition)

      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: EventBus(),
        config: config
      )
      try await vmManager.loadPersistedVMs()

      let recovered = try await vmManager.getVM(id)
      #expect(recovered.state == .stopped)
      #expect(recovered.installation?.state == .completed)
      #expect(FileManager.default.fileExists(atPath: definition.paths.diskImagePath))
      let markerPath = VMInstallationSuccessMarkerStore.markerPath(for: definition)
      #expect(FileManager.default.fileExists(atPath: markerPath) == false)
    }
  }

  @Test
  func durableSuccessMarkerWithIncompleteBundleFailsClosedAndPreservesEvidence() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let id = UUID()
      let definition = VMDefinition(
        id: id,
        name: "incomplete-install-success",
        state: .installing,
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: config.storage.vmStorageDir),
        installation: VMInstallation(state: .installing, message: "Installing")
      )
      try FileManager.default.createDirectory(
        atPath: definition.paths.bundlePath,
        withIntermediateDirectories: true
      )
      let sentinelPath = "\(definition.paths.bundlePath)/sentinel"
      try Data("preserve".utf8).write(to: URL(fileURLWithPath: sentinelPath))
      try VMInstallationSuccessMarkerStore.recordSuccess(for: definition)
      try await persistenceStore.createVM(definition)

      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: EventBus(),
        config: config
      )
      await #expect(throws: VMManagerError.self) {
        try await vmManager.loadPersistedVMs()
      }

      #expect(FileManager.default.fileExists(atPath: sentinelPath))
      let markerPath = VMInstallationSuccessMarkerStore.markerPath(for: definition)
      #expect(FileManager.default.fileExists(atPath: markerPath))
      #expect(try await persistenceStore.getVM(id).state == .installing)
    }
  }

  @Test
  func finalizationReaperCompletesBundleAfterSuccessMarkerWriteFailure() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let eventBus = EventBus()
      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: eventBus,
        config: config
      )
      let definition = try await vmManager.createVM(name: "reap-finalization", resources: .default)
      try makeCompleteBundle(definition)
      let instance = try await vmManager.getVMInstance(definition.id)
      try await MainActor.run {
        try instance.stateMachine.transition(to: .installing)
        instance.definition.updateState(.installing)
        instance.definition.updateInstallation(
          VMInstallation(state: .installing, message: "Installing")
        )
      }
      try await vmManager.replaceDefinitionForTesting(
        definition.id,
        definition: MainActor.run { instance.definition }
      )
      let installer = VMInstaller(vmDefinition: definition, eventBus: eventBus)

      await vmManager.handleInstallationFailure(
        vmId: definition.id,
        instance: instance,
        installer: installer,
        error: VMInstallerError.installationSuccessMarkerFailed("injected")
      )

      #expect(await waitUntilAsync(timeout: 2.0) {
        guard await (try? vmManager.getVMState(definition.id)) == .stopped else { return false }
        return await vmManager.hasInstallationTask(definition.id) == false
      })
      let persisted = try await persistenceStore.getVM(definition.id)
      #expect(persisted.state == .stopped)
      #expect(persisted.installation?.state == .completed)
    }
  }

  @Test
  func finalizationReaperPreservesPermanentFailureAcrossRestartUntilForceDelete() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let eventBus = EventBus()
      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: eventBus,
        config: config,
        installerRecoveryPollNanoseconds: 10_000_000
      )
      let definition = try await vmManager.createVM(name: "incomplete-live-finalization", resources: .default)
      try makeCompleteBundle(definition)
      try FileManager.default.removeItem(atPath: definition.paths.machineIdentifierPath)
      let sentinelPath = "\(definition.paths.bundlePath)/sentinel"
      try Data("preserve".utf8).write(to: URL(fileURLWithPath: sentinelPath))
      let instance = try await vmManager.getVMInstance(definition.id)
      try await MainActor.run {
        try instance.stateMachine.transition(to: .installing)
        instance.definition.updateState(.installing)
        instance.definition.updateInstallation(
          VMInstallation(state: .installing, message: "Installing")
        )
      }
      let installingDefinition = await MainActor.run { instance.definition }
      try await vmManager.replaceDefinitionForTesting(definition.id, definition: installingDefinition)
      try VMInstallationSuccessMarkerStore.recordSuccess(for: installingDefinition)
      let markerPath = VMInstallationSuccessMarkerStore.markerPath(for: installingDefinition)
      let recorder = EventTypeRecorder()
      let subscription = eventBus.subscribe { event in recorder.append(event.eventType) }
      defer { eventBus.unsubscribe(subscription) }
      let installer = VMInstaller(vmDefinition: definition, eventBus: eventBus)

      await vmManager.handleInstallationFailure(
        vmId: definition.id,
        instance: instance,
        installer: installer,
        error: InstallationCallbackTestError.installFailed
      )

      #expect(await waitUntilAsync(timeout: 2.0) {
        guard let persisted = try? await persistenceStore.getVM(definition.id) else { return false }
        guard persisted.state == .error, persisted.installation?.state == .failed else { return false }
        return await vmManager.hasInstallationTask(definition.id) == false
      })
      await eventBus.waitUntilIdle()

      let persisted = try await persistenceStore.getVM(definition.id)
      #expect(instance.currentState == .error)
      #expect(persisted.installation?.error?.contains("incomplete") == true)
      #expect(await vmManager.activeVMCount() == 0)
      #expect(recorder.values.filter { $0 == "INSTALL_FAILED" }.count == 1)
      #expect(FileManager.default.fileExists(atPath: markerPath))
      #expect(FileManager.default.fileExists(atPath: sentinelPath))
      #expect(FileManager.default.fileExists(atPath: definition.paths.diskImagePath))
      #expect(FileManager.default.fileExists(atPath: definition.paths.machineIdentifierPath) == false)

      let reloadedPersistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let reloadedManager = VMManager(
        persistenceStore: reloadedPersistenceStore,
        eventBus: EventBus(),
        config: config
      )
      try await reloadedManager.loadPersistedVMs()

      let reloaded = try await reloadedManager.getVM(definition.id)
      #expect(reloaded.state == .error)
      #expect(reloaded.installation?.state == .failed)
      #expect(FileManager.default.fileExists(atPath: markerPath))
      #expect(FileManager.default.fileExists(atPath: sentinelPath))

      try await reloadedManager.deleteVM(definition.id, force: true)

      #expect(try await reloadedManager.vmExists(definition.id) == false)
      #expect(FileManager.default.fileExists(atPath: definition.paths.bundlePath) == false)
      #expect(FileManager.default.fileExists(atPath: markerPath) == false)
    }
  }

  @Test
  func failedInstallerRuntimeReleasesCapacityAfterItStops() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let eventBus = EventBus()
      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: eventBus,
        config: config,
        installerRecoveryPollNanoseconds: 10_000_000
      )
      let definition = try await vmManager.createVM(name: "installer-capacity", resources: .default)
      let instance = try await vmManager.getVMInstance(definition.id)
      try await MainActor.run {
        try instance.stateMachine.transition(to: .installing)
        instance.definition.updateState(.installing)
        instance.definition.updateInstallation(
          VMInstallation(state: .installing, message: "Installing")
        )
      }
      try await vmManager.replaceDefinitionForTesting(
        definition.id,
        definition: MainActor.run { instance.definition }
      )
      let runtimeState = InstallerRuntimeState(.running)
      let installer = VMInstaller(
        vmDefinition: definition,
        eventBus: eventBus,
        virtualMachineStateProvider: { runtimeState.value }
      )

      await vmManager.handleInstallationFailure(
        vmId: definition.id,
        instance: instance,
        installer: installer,
        error: InstallationCallbackTestError.installFailed
      )

      #expect(await vmManager.activeVMCount() == 1)
      runtimeState.value = .stopped
      #expect(await waitUntilAsync(timeout: 1.0) {
        await vmManager.hasInstallationTask(definition.id) == false
      })
      #expect(await vmManager.activeVMCount() == 0)
    }
  }

  @Test
  func completionEventIsPublishedOnlyAfterDurableStoppedState() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let eventBus = EventBus()
      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: eventBus,
        config: config
      )
      let created = try await vmManager.createVM(name: "complete", resources: .default)
      try makeCompleteBundle(created)
      let instance = try await vmManager.getVMInstance(created.id)
      try await MainActor.run {
        try instance.stateMachine.transition(to: .installing)
        instance.definition.updateState(.installing)
        instance.definition.updateInstallation(
          VMInstallation(state: .installing, message: "Installing")
        )
      }
      try await vmManager.replaceDefinitionForTesting(created.id, definition: MainActor.run { instance.definition })

      let recorder = EventTypeRecorder()
      let subscription = eventBus.subscribe { event in recorder.append(event.eventType) }
      defer { eventBus.unsubscribe(subscription) }
      let installer = VMInstaller(vmDefinition: created, eventBus: eventBus)
      let installingDefinition = await MainActor.run { instance.definition }
      try VMInstallationSuccessMarkerStore.recordSuccess(for: installingDefinition)

      try await vmManager.completeInstallation(vmId: created.id, instance: instance, installer: installer)
      await eventBus.waitUntilIdle()

      let persisted = try await persistenceStore.getVM(created.id)
      let events = recorder.values
      let stoppedIndex = try #require(events.firstIndex(of: "VM_STOPPED"))
      let completedIndex = try #require(events.firstIndex(of: "INSTALL_COMPLETED"))
      #expect(persisted.state == .stopped)
      #expect(persisted.installation?.state == .completed)
      #expect(stoppedIndex < completedIndex)
    }
  }

  @Test
  func startupRemovesSavedStateFromStoppedVM() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let id = UUID()
      let definition = VMDefinition(
        id: id,
        name: "stopped-with-save",
        state: .stopped,
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: config.storage.vmStorageDir),
        installation: .completed(message: "Installed")
      )
      try makeCompleteBundle(definition)
      let savePath = definition.paths.saveFilePath
      try Data("stale-state".utf8).write(to: URL(fileURLWithPath: savePath))
      try await persistenceStore.createVM(definition)

      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: EventBus(),
        config: config
      )
      try await vmManager.loadPersistedVMs()

      let recovered = try await vmManager.getVM(id)
      #expect(FileManager.default.fileExists(atPath: savePath) == false)
      #expect(recovered.state == .stopped)
    }
  }

  @Test
  func persistedPausedVMCanBeStoppedWithoutRecreatingRuntime() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let id = UUID()
      let definition = VMDefinition(
        id: id,
        name: "saved-paused",
        state: .paused,
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: config.storage.vmStorageDir),
        installation: .completed(message: "Installed")
      )
      try makeCompleteBundle(definition)
      let savePath = definition.paths.saveFilePath
      try Data("saved-state".utf8).write(to: URL(fileURLWithPath: savePath))
      try await persistenceStore.createVM(definition)
      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: EventBus(),
        config: config
      )
      try await vmManager.loadPersistedVMs()

      try await vmManager.stopVM(id)

      #expect(try await vmManager.getVMState(id) == .stopped)
      #expect(FileManager.default.fileExists(atPath: savePath) == false)
      #expect(try await persistenceStore.getVM(id).state == .stopped)
    }
  }

  @Test
  func startingBlankVMIsRejectedWithoutLeavingCreatedState() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: EventBus(),
        config: config
      )
      let definition = try await vmManager.createVM(name: "blank", resources: .default)

      await #expect(throws: VMManagerError.self) {
        try await vmManager.startVM(definition.id)
      }

      #expect(try await vmManager.getVMState(definition.id) == .created)
      #expect(try await persistenceStore.getVM(definition.id).state == .created)
    }
  }

  @Test
  func invalidPendingResizeIsRejectedBeforeDiskMutation() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let id = UUID()
      var definition = VMDefinition(
        id: id,
        name: "unsafe-resize",
        state: .stopped,
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: config.storage.vmStorageDir),
        metadata: [
          "jeballto.diskResizeTarget": "1",
          "jeballto.diskResizePhase": "planned",
        ]
      )
      definition.updateState(.stopped)
      try FileManager.default.createDirectory(atPath: definition.paths.bundlePath, withIntermediateDirectories: true)
      let originalDisk = Data("do-not-resize".utf8)
      try originalDisk.write(to: URL(fileURLWithPath: definition.paths.diskImagePath))
      try await persistenceStore.createVM(definition)
      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: EventBus(),
        config: config
      )

      await #expect(throws: VMManagerError.self) {
        try await vmManager.loadPersistedVMs()
      }

      #expect(try Data(contentsOf: URL(fileURLWithPath: definition.paths.diskImagePath)) == originalDisk)
    }
  }

  private func makeFinalizingDefinition(config: Config) throws -> VMDefinition {
    let id = UUID()
    var definition = VMDefinition(
      id: id,
      name: "finalizing",
      state: .installing,
      resources: .default,
      paths: VMPaths.forVM(id: id, baseDir: config.storage.vmStorageDir),
      installation: VMInstallation(state: .finalizing, message: "Finalizing")
    )
    definition.updateState(.installing)
    try makeCompleteBundle(definition)
    return definition
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

private enum InstallationCallbackTestError: Error {
  case markerWriteFailed
  case installFailed
}

private final class InstallerRuntimeState: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: VZVirtualMachine.State?

  init(_ state: VZVirtualMachine.State?) {
    storage = state
  }

  var value: VZVirtualMachine.State? {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }
}

private final class EventTypeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  var values: [String] { lock.withLock { storage } }

  func append(_ value: String) {
    lock.withLock { storage.append(value) }
  }
}

private final class InstallationCancellationRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var observed = false

  var wasObserved: Bool { lock.withLock { observed } }

  func record() {
    lock.withLock { observed = true }
  }
}

private final class SuspendedDownloadURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {}

  override func stopLoading() {}
}
