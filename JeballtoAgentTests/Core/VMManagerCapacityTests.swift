import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core), .serialized)
struct VMManagerCapacityTests {
  @Test
  func startupFailsClosedWhenManagedBundleIsMissingFromDatabase() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)
      let id = UUID()
      let bundlePath = "\(root)/vms/\(id.uuidString).bundle"
      try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
      let sentinel = "\(bundlePath)/Disk.img"
      try Data("must survive".utf8).write(to: URL(fileURLWithPath: sentinel))

      await #expect(throws: VMManagerError.self) {
        try await vmManager.loadPersistedVMs()
      }
      #expect(FileManager.default.fileExists(atPath: sentinel))
    }
  }

  @Test
  func startupFailsClosedForNonDirectoryManagedBundleEntry() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)
      let path = "\(root)/vms/\(UUID().uuidString).bundle"
      try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
      )
      try Data("unexpected managed entry".utf8).write(to: URL(fileURLWithPath: path))

      await #expect(throws: VMManagerError.self) {
        try await vmManager.loadPersistedVMs()
      }
      #expect(FileManager.default.fileExists(atPath: path))
    }
  }

  @Test
  func startupDeletesPreviouslyBootedEphemeralVMInterruptedByAgentCrash() async throws {
    try await withTemporaryDirectory { root in
      let (writer, _, _) = makeManager(root: root)
      var definition = try await writer.createVM(
        name: "crash-ephemeral",
        resources: .default,
        ephemeral: true
      )
      try makeCompleteBundle(definition)
      definition.markBooted()
      definition.updateState(.running)
      try await writer.replaceDefinitionForTesting(definition.id, definition: definition)

      let (restarted, persistenceStore, _) = makeManager(root: root)
      try await restarted.loadPersistedVMs()

      #expect(try await persistenceStore.vmExists(definition.id) == false)
      #expect(FileManager.default.fileExists(atPath: definition.paths.bundlePath) == false)
    }
  }

  @Test
  func startupPreservesEphemeralVMThatHasNeverBooted() async throws {
    try await withTemporaryDirectory { root in
      let (writer, _, _) = makeManager(root: root)
      var definition = try await writer.createVM(
        name: "unused-ephemeral",
        resources: .default,
        ephemeral: true
      )
      try makeCompleteBundle(definition)
      definition.updateState(.stopped)
      try await writer.replaceDefinitionForTesting(definition.id, definition: definition)

      let (restarted, persistenceStore, _) = makeManager(root: root)
      try await restarted.loadPersistedVMs()

      #expect(try await persistenceStore.vmExists(definition.id))
      #expect(try await restarted.getVMState(definition.id) == .stopped)
      #expect(FileManager.default.fileExists(atPath: definition.paths.bundlePath))
    }
  }

  @Test
  func pausedVMsCountAgainstCapacityBeforeStartingAnotherVM() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)

      let first = try await vmManager.createVM(name: "first", resources: .default)
      let second = try await vmManager.createVM(name: "second", resources: .default)
      let third = try await vmManager.createVM(name: "third", resources: .default)
      try makeCompleteBundle(third)

      try await setState(.paused, vmId: first.id, vmManager: vmManager)
      try await setState(.paused, vmId: second.id, vmManager: vmManager)
      try await setState(.stopped, vmId: third.id, vmManager: vmManager)

      await #expect(throws: VMManagerError.self) {
        try await vmManager.startVM(third.id)
      }
      #expect(await vmManager.activeVMCount() == 2)
    }
  }

  @Test
  func failedStartReleasesCapacityReservation() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)

      let active = try await vmManager.createVM(name: "active", resources: .default)
      let failing = try await vmManager.createVM(name: "failing", resources: .default)
      try makeCompleteBundle(failing)

      try await setState(.paused, vmId: active.id, vmManager: vmManager)
      try await setState(.stopped, vmId: failing.id, vmManager: vmManager)
      var networkedFailing = try await vmManager.getVM(failing.id)
      networkedFailing.updateSSHPort(2222)
      networkedFailing.updateVNCPort(5901)
      networkedFailing.updateNATIP("192.168.64.2")
      try await vmManager.replaceDefinitionForTesting(failing.id, definition: networkedFailing)

      await #expect(throws: Error.self) {
        try await vmManager.startVM(failing.id)
      }
      #expect(await vmManager.activeVMCount() == 1)
      let failedDefinition = try await vmManager.getVM(failing.id)
      #expect(failedDefinition.network.sshPort == nil)
      #expect(failedDefinition.network.vncPort == nil)
      #expect(failedDefinition.network.natIP == nil)
    }
  }

  @Test
  func runningStartKeepsItsCapacitySlotAcrossReentrancy() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)
      let restarting = try await vmManager.createVM(name: "restarting", resources: .default)
      let paused = try await vmManager.createVM(name: "paused", resources: .default)
      let waiting = try await vmManager.createVM(name: "waiting", resources: .default)
      try makeCompleteBundle(restarting)
      try await setState(.running, vmId: restarting.id, vmManager: vmManager)
      try await setState(.paused, vmId: paused.id, vmManager: vmManager)
      await vmManager.setRuntimeCapacityOwnerForTesting(true, vmId: restarting.id)

      let gate = ExclusiveOperationGate()
      await vmManager.setStartCapacityClaimHookForTesting {
        await gate.enterAndWait()
      }
      let startTask = Task<Void, Error> {
        try await vmManager.startVM(restarting.id)
      }
      await gate.waitUntilEntered()

      try await setState(.stopped, vmId: restarting.id, vmManager: vmManager)
      await vmManager.setRuntimeCapacityOwnerForTesting(false, vmId: restarting.id)

      #expect(await vmManager.activeVMCount() == 2)
      await #expect(throws: VMManagerError.self) {
        try await vmManager.beginInstallation(waiting.id)
      }
      #expect(try await vmManager.getVMState(waiting.id) == .created)

      await gate.release()
      await vmManager.setStartCapacityClaimHookForTesting(nil)
      await #expect(throws: Error.self) {
        try await startTask.value
      }
    }
  }

  @Test
  func createdVMDiskGrowthOnlyChangesFutureInstallationSize() async throws {
    try await withTemporaryDirectory { root in
      let recorder = DiskResizeRecorder()
      let (vmManager, persistenceStore, _) = makeManager(
        root: root,
        diskImageResizer: { path, size in
          await recorder.record(path: path, size: size)
        }
      )
      let definition = try await vmManager.createVM(name: "future-disk", resources: .default)
      let enlargedSize = 80 * UInt64(1_073_741_824)

      #expect(FileManager.default.fileExists(atPath: definition.paths.diskImagePath) == false)
      let updated = try await vmManager.updateVM(
        definition.id,
        name: nil,
        cpuCount: nil,
        memorySize: nil,
        diskSize: enlargedSize
      )

      #expect(updated.resources.diskSize == enlargedSize)
      #expect(try await persistenceStore.getVM(definition.id).resources.diskSize == enlargedSize)
      #expect(await recorder.calls.isEmpty)
      #expect(updated.metadata["jeballto.diskResizeTarget"] == nil)
      #expect(updated.metadata["jeballto.diskResizePhase"] == nil)
    }
  }

  @Test
  func stoppedInstalledVMDiskGrowthResizesTheExistingImage() async throws {
    try await withTemporaryDirectory { root in
      let recorder = DiskResizeRecorder()
      let (vmManager, persistenceStore, _) = makeManager(
        root: root,
        diskImageResizer: { path, size in
          await recorder.record(path: path, size: size)
        }
      )
      let definition = try await vmManager.createVM(name: "installed-disk", resources: .default)
      try makeCompleteBundle(definition)
      try await setState(.stopped, vmId: definition.id, vmManager: vmManager)
      let enlargedSize = 80 * UInt64(1_073_741_824)

      let updated = try await vmManager.updateVM(
        definition.id,
        name: nil,
        cpuCount: nil,
        memorySize: nil,
        diskSize: enlargedSize
      )

      let calls = await recorder.calls
      let call = try #require(calls.first)
      #expect(calls.count == 1)
      #expect(call.path == definition.paths.diskImagePath)
      #expect(call.size == enlargedSize)
      #expect(updated.resources.diskSize == enlargedSize)
      #expect(try await persistenceStore.getVM(definition.id).resources.diskSize == enlargedSize)
      #expect(updated.metadata["jeballto.diskResizeTarget"] == nil)
      #expect(updated.metadata["jeballto.diskResizePhase"] == nil)
    }
  }

  @Test
  func preparedInstallationsConsumeCapacityBeforeBackgroundWorkStarts() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)
      let first = try await vmManager.createVM(name: "install-one", resources: .default)
      let second = try await vmManager.createVM(name: "install-two", resources: .default)
      let third = try await vmManager.createVM(name: "install-three", resources: .default)

      try await vmManager.beginInstallation(first.id)
      try await vmManager.beginInstallation(second.id)

      await #expect(throws: VMManagerError.self) {
        try await vmManager.beginInstallation(third.id)
      }
      #expect(await vmManager.activeVMCount() == 2)
      #expect(try await vmManager.getVMState(third.id) == .created)
    }
  }

  @Test
  func ephemeralVMWithoutLifetimeDeletesAfterItsFirstRunStops() async throws {
    try await withTemporaryDirectory { root in
      let eventBus = EventBus()
      let (vmManager, persistenceStore, _) = makeManager(root: root, eventBus: eventBus)
      let definition = try await vmManager.createVM(
        name: "ephemeral",
        resources: .default,
        ephemeral: true
      )

      try await setState(.running, vmId: definition.id, vmManager: vmManager)
      eventBus.publish(.vmRunning(vmId: definition.id))
      await vmManager.waitForEventProcessingForTesting()
      #expect(try await persistenceStore.getVM(definition.id).hasBooted)

      try await setState(.stopped, vmId: definition.id, vmManager: vmManager)
      eventBus.publish(.vmStopped(vmId: definition.id))
      await vmManager.waitForEventProcessingForTesting()
      let deleted = await waitUntilAsync(timeout: 3) {
        await (try? persistenceStore.vmExists(definition.id)) == false
      }

      #expect(deleted)
      #expect(FileManager.default.fileExists(atPath: definition.paths.bundlePath) == false)
    }
  }

  @Test
  func runningEventPersistsFirstBootAndLifetimeDeadlineTogether() async throws {
    try await withTemporaryDirectory { root in
      let eventBus = EventBus()
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let vmManager = VMManager(persistenceStore: persistenceStore, eventBus: eventBus, config: config)
      let definition = try await vmManager.createVM(
        name: "first-boot-lifetime",
        resources: .default,
        lifetimeSeconds: 120
      )
      try await setState(.running, vmId: definition.id, vmManager: vmManager)
      let earliestExpiry = Date().addingTimeInterval(120)

      eventBus.publish(.vmRunning(vmId: definition.id))
      await vmManager.waitForEventProcessingForTesting()

      let persisted = try await persistenceStore.getVM(definition.id)
      let expiresAt = try #require(persisted.expiresAt)
      let instance = try await vmManager.getVMInstance(definition.id)
      let inMemory = await MainActor.run { instance.definition }
      #expect(persisted.state == .running)
      #expect(persisted.hasBooted)
      #expect(expiresAt >= earliestExpiry)
      #expect(expiresAt <= Date().addingTimeInterval(120))
      #expect(inMemory.hasBooted)
      #expect(inMemory.expiresAt == expiresAt)
    }
  }

  @Test
  func forceStopRecoversErrorWithoutARuntime() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)
      let definition = try await vmManager.createVM(name: "recover-error", resources: .default)
      try makeCompleteBundle(definition)
      try await setState(.error, vmId: definition.id, vmManager: vmManager)

      try await vmManager.forceStopVM(definition.id)

      let recoveredState = try await vmManager.getVMState(definition.id)
      #expect(recoveredState == .stopped)
    }
  }

  @Test
  func failedErrorRecoveryPersistenceLeavesMemoryInErrorAndCanBeRetried() async throws {
    try await withTemporaryDirectory { root in
      var config = makeTestConfig(root: root)
      let databaseDirectory = "\(root)/database"
      config.storage.databasePath = "\(databaseDirectory)/vms.json"
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let vmManager = VMManager(persistenceStore: persistenceStore, eventBus: EventBus(), config: config)
      let definition = try await vmManager.createVM(name: "retry-recovery", resources: .default)
      try makeCompleteBundle(definition)
      try await setState(.error, vmId: definition.id, vmManager: vmManager)
      await vmManager.setRuntimeCapacityOwnerForTesting(true, vmId: definition.id)
      try FileManager.default.removeItem(atPath: databaseDirectory)

      await #expect(throws: PersistenceError.self) {
        _ = try await vmManager.stopVM(definition.id)
      }

      #expect(try await vmManager.getVMState(definition.id) == .error)
      #expect(try await persistenceStore.getVM(definition.id).state == .error)
      #expect(await vmManager.activeVMCount() == 0)

      try FileManager.default.createDirectory(atPath: databaseDirectory, withIntermediateDirectories: true)
      let recovered = try await vmManager.stopVM(definition.id)
      #expect(recovered.state == .stopped)
      #expect(try await persistenceStore.getVM(definition.id).state == .stopped)
    }
  }

  @Test
  func failedIncompleteInstallationRecoveryRemainsRetryableInMemory() async throws {
    try await withTemporaryDirectory { root in
      var config = makeTestConfig(root: root)
      let databaseDirectory = "\(root)/database"
      config.storage.databasePath = "\(databaseDirectory)/vms.json"
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let vmManager = VMManager(persistenceStore: persistenceStore, eventBus: EventBus(), config: config)
      let definition = try await vmManager.createVM(name: "retry-install-recovery", resources: .default)
      try await setState(.error, vmId: definition.id, vmManager: vmManager)
      try FileManager.default.removeItem(atPath: databaseDirectory)

      await #expect(throws: PersistenceError.self) {
        _ = try await vmManager.stopVM(definition.id)
      }

      #expect(try await vmManager.getVMState(definition.id) == .error)
      #expect(try await persistenceStore.getVM(definition.id).state == .error)

      try FileManager.default.createDirectory(atPath: databaseDirectory, withIntermediateDirectories: true)
      let recovered = try await vmManager.stopVM(definition.id)
      #expect(recovered.state == .created)
      #expect(recovered.installation?.state == .interrupted)
      #expect(try await persistenceStore.getVM(definition.id).state == .created)
    }
  }

  @Test
  func stoppingBootedEphemeralVMFromErrorDeletesIt() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, persistenceStore, _) = makeManager(root: root)
      var definition = try await vmManager.createVM(
        name: "error-ephemeral",
        resources: .default,
        ephemeral: true
      )
      try makeCompleteBundle(definition)
      definition.markBooted()
      definition.updateState(.error)
      try await vmManager.replaceDefinitionForTesting(definition.id, definition: definition)
      let vmId = definition.id

      _ = try await vmManager.stopVM(vmId)
      let deleted = await waitUntilAsync(timeout: 3) {
        await (try? persistenceStore.vmExists(vmId)) == false
      }

      #expect(deleted)
      #expect(FileManager.default.fileExists(atPath: definition.paths.bundlePath) == false)
    }
  }

  @Test
  func partialWipeRestoresEphemeralDeletionPolicyForSurvivors() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, persistenceStore, _) = makeManager(root: root)
      var definition = try await vmManager.createVM(
        name: "wipe-survivor",
        resources: .default,
        ephemeral: true
      )
      try makeCompleteBundle(definition)
      definition.markBooted()
      definition.updateState(.stopped)
      try await vmManager.replaceDefinitionForTesting(definition.id, definition: definition)
      let vmId = definition.id
      let exportToken = try await vmManager.claimImageExport(vmId)

      let result = try await vmManager.wipeAllVMs()

      #expect(result.deleted == 0)
      #expect(result.failed == 1)
      #expect(try await persistenceStore.vmExists(vmId))

      await vmManager.releaseImageExport(vmId, token: exportToken)
      let eventuallyDeleted = await waitUntilAsync(timeout: 3) {
        await (try? persistenceStore.vmExists(vmId)) == false
      }
      #expect(eventuallyDeleted)
    }
  }

  @Test
  func wipeDrainsPendingEphemeralDeletionTaskBeforeDeletingVMs() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, persistenceStore, _) = makeManager(root: root)
      var definition = try await vmManager.createVM(
        name: "pending-ephemeral-wipe",
        resources: .default,
        ephemeral: true
      )
      try makeCompleteBundle(definition)
      definition.markBooted()
      definition.updateState(.stopped)
      try await vmManager.replaceDefinitionForTesting(definition.id, definition: definition)

      _ = try await vmManager.stopVM(definition.id)
      let result = try await vmManager.wipeAllVMs()

      #expect(result.failed == 0)
      #expect(try await persistenceStore.vmExists(definition.id) == false)
      #expect(try await vmManager.vmExists(definition.id) == false)
    }
  }

  @Test
  func imageExportReservationBlocksBundleMutationsUntilReleased() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)
      let definition = try await vmManager.createVM(name: "exporting", resources: .default)
      try makeCompleteBundle(definition)
      try await setState(.stopped, vmId: definition.id, vmManager: vmManager)

      let exportToken = try await vmManager.claimImageExport(definition.id)
      await #expect(throws: VMManagerError.self) {
        try await vmManager.startVM(definition.id)
      }
      await #expect(throws: VMManagerError.self) {
        try await vmManager.updateVM(
          definition.id,
          name: nil,
          cpuCount: 2,
          memorySize: nil,
          diskSize: nil
        )
      }
      await #expect(throws: VMManagerError.self) {
        try await vmManager.deleteVM(definition.id)
      }

      await vmManager.releaseImageExport(definition.id, token: UUID())
      await #expect(throws: VMManagerError.self) {
        try await vmManager.deleteVM(definition.id)
      }

      await vmManager.releaseImageExport(definition.id, token: exportToken)
      try await vmManager.deleteVM(definition.id)
    }
  }

  @Test
  func imageExportRejectsUninstalledCreatedVM() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)
      let definition = try await vmManager.createVM(name: "blank", resources: .default)

      await #expect(throws: VMManagerError.self) {
        _ = try await vmManager.claimImageExport(definition.id)
      }
      await #expect(throws: VMManagerError.self) {
        _ = try await vmManager.cloneVM(definition.id, name: "invalid-clone")
      }
    }
  }

  @Test
  func imageExportClaimBlocksLifecycleMutationBeforeValidationSuspends() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)
      let definition = try await vmManager.createVM(name: "export-claim", resources: .default)
      try makeCompleteBundle(definition)
      try await setState(.stopped, vmId: definition.id, vmManager: vmManager)
      let gate = ExclusiveOperationGate()
      await vmManager.setImageExportClaimHookForTesting {
        await gate.enterAndWait()
      }

      let export = Task<(token: UUID, definition: VMDefinition), Error> {
        try await vmManager.claimImageExportWithDefinition(definition.id)
      }
      await gate.waitUntilEntered()

      await #expect(throws: VMManagerError.self) {
        _ = try await vmManager.updateVM(
          definition.id,
          name: "must-not-win",
          cpuCount: nil,
          memorySize: nil,
          diskSize: nil
        )
      }

      await gate.release()
      let claim = try await export.value
      await vmManager.setImageExportClaimHookForTesting(nil)
      await vmManager.releaseImageExport(definition.id, token: claim.token)
    }
  }

  @Test
  func runtimeCapacityOwnerCountsEvenWhenLogicalStateIsError() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)
      let definition = try await vmManager.createVM(name: "runtime-owner", resources: .default)
      try await setState(.error, vmId: definition.id, vmManager: vmManager)

      await vmManager.setRuntimeCapacityOwnerForTesting(true, vmId: definition.id)

      #expect(await vmManager.activeVMCount() == 1)
      #expect(try await vmManager.getVMState(definition.id) == .error)
    }
  }

  @Test
  func shutdownActionSavesOnlyLivePausedRuntime() {
    #expect(VMManager.shutdownAction(isEphemeral: true, state: .stopped, hasLiveRuntime: false) == .deleteEphemeral)
    #expect(VMManager.shutdownAction(isEphemeral: false, state: .running, hasLiveRuntime: true) == .saveRunning)
    #expect(VMManager.shutdownAction(isEphemeral: false, state: .paused, hasLiveRuntime: true) == .savePausedRuntime)
    #expect(VMManager.shutdownAction(isEphemeral: false, state: .paused, hasLiveRuntime: false) == .none)
    #expect(VMManager.shutdownAction(isEphemeral: false, state: .error, hasLiveRuntime: false) == .recoverError)
    #expect(VMManager.shutdownAction(isEphemeral: false, state: .stopped, hasLiveRuntime: false) == .none)
  }

  @Test
  func exclusiveNetworkOperationBlocksConcurrentVMLifecycleMutation() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)
      let definition = try await vmManager.createVM(name: "exclusive", resources: .default)
      let gate = ExclusiveOperationGate()
      let operationTask = Task<Void, Error> {
        try await vmManager.withExclusiveVMOperation(definition.id, operation: "network update") {
          await gate.enterAndWait()
        }
      }
      await gate.waitUntilEntered()

      do {
        _ = try await vmManager.updateVM(
          definition.id,
          name: "should-not-win",
          cpuCount: nil,
          memorySize: nil,
          diskSize: nil
        )
        Issue.record("Expected concurrent VM mutation to be rejected")
      } catch {
        #expect(error.localizedDescription.contains("network update"))
      }

      await gate.release()
      try await operationTask.value
      let updated = try await vmManager.updateVM(
        definition.id,
        name: "after-release",
        cpuCount: nil,
        memorySize: nil,
        diskSize: nil
      )
      #expect(updated.name == "after-release")
    }
  }

  @Test
  func imageCreationRequiresCompleteBundleAndRecordsCompletedInstallation() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)
      let sourceID = UUID()
      let source = VMDefinition(
        id: sourceID,
        name: "source",
        state: .stopped,
        resources: .default,
        paths: VMPaths.forVM(id: sourceID, baseDir: root)
      )
      try FileManager.default.createDirectory(atPath: source.paths.bundlePath, withIntermediateDirectories: true)

      await #expect(throws: VMManagerError.self) {
        _ = try await vmManager.createVMFromImage(
          name: "invalid",
          imagePath: source.paths.bundlePath,
          resources: .default
        )
      }

      try makeCompleteBundle(source)
      let created = try await vmManager.createVMFromImage(
        name: "valid",
        imagePath: source.paths.bundlePath,
        resources: .default
      )

      #expect(created.state == .stopped)
      #expect(created.installation?.state == .completed)
    }
  }

  @Test
  func deleteReleasesPersistedNetworkPorts() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, persistenceStore, portForwardingManager) = makeManager(root: root)
      let definition = try await vmManager.createVM(name: "networked", resources: .default)
      var updated = definition
      updated.updateSSHPort(2222)
      updated.updateVNCPort(5901)
      updated.updateNATIP("192.168.64.2")
      try await vmManager.replaceDefinitionForTesting(definition.id, definition: updated)
      await portForwardingManager.registerPort(2222)
      await portForwardingManager.registerVNCPort(5901)

      try await vmManager.deleteVM(definition.id)

      #expect(await portForwardingManager.isPortAllocated(2222) == false)
      #expect(await portForwardingManager.isVNCPortAllocated(5901) == false)
      await #expect(throws: PersistenceError.self) {
        try await persistenceStore.getVM(definition.id)
      }
    }
  }

  @Test
  func deleteRefusesPersistedBundlePathOutsideManagedVMDirectory() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)
      var definition = try await vmManager.createVM(name: "unsafe-path", resources: .default)
      let outsideBundle = "\(root)/must-not-delete.bundle"
      try FileManager.default.createDirectory(atPath: outsideBundle, withIntermediateDirectories: true)
      let sentinel = "\(outsideBundle)/sentinel"
      try Data("keep".utf8).write(to: URL(fileURLWithPath: sentinel))
      definition.paths.bundlePath = outsideBundle
      try await vmManager.replaceDefinitionForTesting(definition.id, definition: definition)

      await #expect(throws: VMManagerError.self) {
        try await vmManager.deleteVM(definition.id)
      }

      #expect(FileManager.default.fileExists(atPath: sentinel))
    }
  }

  @Test
  func deleteRefusesManagedBundleSymlinkThatEscapesStorageRoot() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _, _) = makeManager(root: root)
      let definition = try await vmManager.createVM(name: "unsafe-symlink", resources: .default)
      let outsideBundle = "\(root)/outside-target.bundle"
      try FileManager.default.createDirectory(atPath: outsideBundle, withIntermediateDirectories: true)
      let sentinel = "\(outsideBundle)/sentinel"
      try Data("keep".utf8).write(to: URL(fileURLWithPath: sentinel))
      try FileManager.default.removeItem(atPath: definition.paths.bundlePath)
      try FileManager.default.createSymbolicLink(
        atPath: definition.paths.bundlePath,
        withDestinationPath: outsideBundle
      )

      await #expect(throws: VMManagerError.self) {
        try await vmManager.deleteVM(definition.id)
      }

      #expect(FileManager.default.fileExists(atPath: sentinel))
    }
  }

  private func makeManager(
    root: String,
    eventBus: EventBus = EventBus(),
    diskImageResizer: (@Sendable (String, UInt64) async throws -> Void)? = nil
  ) -> (VMManager, PersistenceStore, PortForwardingManager) {
    let config = makeTestConfig(root: root)
    let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
    let networkManager = NetworkManager(eventBus: eventBus)
    let portForwardingManager = PortForwardingManager(config: config.networking, eventBus: eventBus)
    let vmManager = VMManager(
      persistenceStore: persistenceStore,
      eventBus: eventBus,
      config: config,
      guiManager: nil,
      networkManager: networkManager,
      portForwardingManager: portForwardingManager,
      diskImageResizer: diskImageResizer
    )
    return (vmManager, persistenceStore, portForwardingManager)
  }

  private func setState(_ state: VMState, vmId: UUID, vmManager: VMManager) async throws {
    let instance = try await vmManager.getVMInstance(vmId)
    await MainActor.run {
      instance.stateMachine.forceState(state)
      instance.definition.updateState(state)
    }
    let definition = await MainActor.run { instance.definition }
    try await vmManager.replaceDefinitionForTesting(vmId, definition: definition)
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

private actor ExclusiveOperationGate {
  private var entered = false
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func enterAndWait() async {
    entered = true
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilEntered() async {
    while entered == false {
      await Task.yield()
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor DiskResizeRecorder {
  private(set) var calls: [(path: String, size: UInt64)] = []

  func record(path: String, size: UInt64) {
    calls.append((path, size))
  }
}
