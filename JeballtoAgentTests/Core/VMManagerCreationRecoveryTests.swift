import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct VMManagerCreationRecoveryTests {
  @Test
  func bundleCopyRequiresAPFSCloneSemantics() {
    #expect(
      VMManager.bundleCopyArguments(from: "/source.bundle", to: "/destination.bundle")
        == ["-c", "-R", "/source.bundle", "/destination.bundle"]
    )
  }

  @Test
  func durableCreationIsNeverVisibleWithoutItsInMemoryInstance() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, persistenceStore) = makeManager(root: root)
      let gate = VMCreationPublicationGate()
      await vmManager.setVMCreationPublishedHookForTesting { vmId in
        await gate.enterAndWait(vmId)
      }
      let creation = Task<VMDefinition, Error> {
        try await vmManager.createVM(name: "atomic-publication", resources: .default)
      }
      let vmId = await gate.waitUntilEntered()

      #expect(await (try? persistenceStore.vmExists(vmId)) == true)
      #expect(await (try? vmManager.getVMInstance(vmId)) != nil)

      await gate.release()
      let definition = try await creation.value
      #expect(definition.id == vmId)
      #expect(FileManager.default.fileExists(atPath: pendingCreationMarkerPath(root: root, vmId: vmId)) == false)
    }
  }

  @Test
  func persistenceFailureAfterRegistryInsertionRollsBackEveryCreationResource() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let databaseDirectory = "\(root)/database"
      let persistenceStore = PersistenceStore(databasePath: "\(databaseDirectory)/vms.json")
      try await persistenceStore.validateLoaded()
      let eventBus = EventBus()
      let networkManager = NetworkManager(eventBus: eventBus)
      let vmManager = VMManager(
        persistenceStore: persistenceStore,
        eventBus: eventBus,
        config: config,
        networkManager: networkManager
      )
      let gate = VMCreationPublicationGate()
      await vmManager.setVMCreationRegistryHookForTesting { vmId in
        await gate.enterAndWait(vmId)
      }
      let creation = Task<VMDefinition, Error> {
        try await vmManager.createVM(name: "rollback-publication", resources: .default)
      }
      let vmId = await gate.waitUntilEntered()
      #expect(await networkManager.allocatedMACCount == 1)
      #expect(await (try? vmManager.getVMInstance(vmId)) != nil)
      try FileManager.default.removeItem(atPath: databaseDirectory)

      await gate.release()
      await #expect(throws: Error.self) {
        _ = try await creation.value
      }

      await #expect(throws: VMManagerError.self) {
        _ = try await vmManager.getVMInstance(vmId)
      }
      #expect(try await persistenceStore.count() == 0)
      #expect(await networkManager.allocatedMACCount == 0)
      let paths = VMPaths.forVM(id: vmId, baseDir: config.storage.vmStorageDir)
      #expect(FileManager.default.fileExists(atPath: paths.bundlePath) == false)
      #expect(FileManager.default.fileExists(atPath: pendingCreationMarkerPath(root: root, vmId: vmId)) == false)
    }
  }

  @Test
  func startupRecoversInterruptedBlankVMCreationWithOwnedMarker() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _) = makeManager(root: root)
      let id = UUID()
      let bundlePath = "\(root)/vms/\(id.uuidString).bundle"
      try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
      try Data("partial blank VM".utf8).write(to: URL(fileURLWithPath: "\(bundlePath)/partial"))
      let markerPath = try writePendingCreationMarker(
        root: root,
        vmId: id,
        operation: "blank",
        phase: "creating"
      )

      try await vmManager.loadPersistedVMs()

      #expect(FileManager.default.fileExists(atPath: bundlePath) == false)
      #expect(FileManager.default.fileExists(atPath: markerPath) == false)
    }
  }

  @Test
  func startupRecoversInterruptedImageImportWithOwnedMarker() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _) = makeManager(root: root)
      let id = UUID()
      let definition = VMDefinition(
        id: id,
        name: "uncommitted-image-import",
        state: .stopped,
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: "\(root)/vms")
      )
      try makeCompleteBundle(definition)
      let markerPath = try writePendingCreationMarker(
        root: root,
        vmId: id,
        operation: "imageImport",
        phase: "creating"
      )

      try await vmManager.loadPersistedVMs()

      #expect(FileManager.default.fileExists(atPath: definition.paths.bundlePath) == false)
      #expect(FileManager.default.fileExists(atPath: markerPath) == false)
    }
  }

  @Test
  func startupPreservesUnindexedBundleWhenPendingMarkerIsInvalid() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _) = makeManager(root: root)
      let id = UUID()
      let bundlePath = "\(root)/vms/\(id.uuidString).bundle"
      try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
      let sentinelPath = "\(bundlePath)/Disk.img"
      try Data("must survive".utf8).write(to: URL(fileURLWithPath: sentinelPath))
      let markerPath = pendingCreationMarkerPath(root: root, vmId: id)
      try Data("not a Jeballto marker".utf8).write(to: URL(fileURLWithPath: markerPath))

      await #expect(throws: VMManagerError.self) {
        try await vmManager.loadPersistedVMs()
      }

      #expect(FileManager.default.fileExists(atPath: sentinelPath))
      #expect(FileManager.default.fileExists(atPath: markerPath))
    }
  }

  @Test
  func startupPreservesIndexedVMAndRemovesItsStaleCreationMarker() async throws {
    try await withTemporaryDirectory { root in
      let (writer, _) = makeManager(root: root)
      let definition = try await writer.createVM(name: "committed", resources: .default)
      let markerPath = pendingCreationMarkerPath(root: root, vmId: definition.id)
      #expect(FileManager.default.fileExists(atPath: markerPath) == false)
      try writePendingCreationMarker(
        at: markerPath,
        vmId: definition.id,
        operation: "blank",
        phase: "committed",
        definition: definition
      )

      let (restarted, persistenceStore) = makeManager(root: root)
      try await restarted.loadPersistedVMs()

      #expect(try await persistenceStore.vmExists(definition.id))
      #expect(FileManager.default.fileExists(atPath: definition.paths.bundlePath))
      #expect(FileManager.default.fileExists(atPath: markerPath) == false)
    }
  }

  @Test(arguments: ["committing", "committed"])
  func startupReconstructsUnindexedBundleWhenDatabaseCommitMayHaveStarted(phase: String) async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _) = makeManager(root: root)
      let id = UUID()
      let definition = VMDefinition(
        id: id,
        name: "ambiguous-commit",
        state: .stopped,
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: "\(root)/vms"),
        installation: .completed(message: "Imported from image")
      )
      try makeCompleteBundle(definition)
      let markerPath = try writePendingCreationMarker(
        root: root,
        vmId: id,
        operation: "imageImport",
        phase: phase,
        definition: definition
      )

      try await vmManager.loadPersistedVMs()

      #expect(FileManager.default.fileExists(atPath: definition.paths.bundlePath))
      #expect(FileManager.default.fileExists(atPath: markerPath) == false)
      #expect(try await vmManager.vmExists(id))
      let persistedDefinition = try iso8601RoundTrip(definition)
      #expect(try await vmManager.getVM(id) == persistedDefinition)
    }
  }

  @Test(arguments: ["committing", "committed"])
  func startupFailsClosedWhenCommitMarkerHasNoDefinition(phase: String) async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _) = makeManager(root: root)
      let id = UUID()
      let bundlePath = "\(root)/vms/\(id.uuidString).bundle"
      try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
      let sentinelPath = "\(bundlePath)/sentinel"
      try Data("must survive".utf8).write(to: URL(fileURLWithPath: sentinelPath))
      let markerPath = try writePendingCreationMarker(
        root: root,
        vmId: id,
        operation: "blank",
        phase: phase
      )

      await #expect(throws: VMManagerError.self) {
        try await vmManager.loadPersistedVMs()
      }

      #expect(FileManager.default.fileExists(atPath: sentinelPath))
      #expect(FileManager.default.fileExists(atPath: markerPath))
    }
  }

  @Test
  func startupKeepsDeletionTombstoneWhenBundleRemovalFails() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, persistenceStore) = makeManager(
        root: root,
        vmBundleRemover: { _ in throw TestBundleRemovalError.denied }
      )
      let id = UUID()
      var definition = VMDefinition(
        id: id,
        name: "pending-deletion",
        state: .deleted,
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: "\(root)/vms")
      )
      definition.metadata["jeballto.deletionPending"] = "true"
      try FileManager.default.createDirectory(
        atPath: definition.paths.bundlePath,
        withIntermediateDirectories: true
      )
      try await persistenceStore.createVM(definition)

      await #expect(throws: VMManagerError.self) {
        try await vmManager.loadPersistedVMs()
      }

      #expect(try await persistenceStore.vmExists(id))
      #expect(FileManager.default.fileExists(atPath: definition.paths.bundlePath))
    }
  }

  @Test
  func startupCompletesDeletionWhenEntireVMStorageDirectoryIsAlreadyGone() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, persistenceStore) = makeManager(root: root)
      let id = UUID()
      var definition = VMDefinition(
        id: id,
        name: "missing-storage-deletion",
        state: .deleted,
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: "\(root)/vms")
      )
      definition.metadata["jeballto.deletionPending"] = "true"
      try await persistenceStore.createVM(definition)

      try await vmManager.loadPersistedVMs()

      #expect(try await persistenceStore.vmExists(id) == false)
    }
  }

  @Test
  func staleBackupCannotDeleteCommittedVMWhenPrimaryDatabaseIsCorrupt() async throws {
    try await withTemporaryDirectory { root in
      let (writer, _) = makeManager(root: root)
      _ = try await writer.createVM(name: "backup-baseline", resources: .default)
      let committed = try await writer.createVM(name: "committed-after-backup", resources: .default)
      let markerPath = try writePendingCreationMarker(
        root: root,
        vmId: committed.id,
        operation: "blank",
        phase: "committed",
        definition: committed
      )
      try Data("corrupt primary".utf8).write(to: URL(fileURLWithPath: "\(root)/vms.json"))

      let (restarted, persistenceStore) = makeManager(root: root)
      try await restarted.loadPersistedVMs()

      #expect(try await persistenceStore.vmExists(committed.id))
      #expect(FileManager.default.fileExists(atPath: committed.paths.bundlePath))
      #expect(FileManager.default.fileExists(atPath: markerPath) == false)
    }
  }

  @Test
  func startupFailsClosedForSymbolicLinkCreationMarker() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _) = makeManager(root: root)
      let id = UUID()
      let bundlePath = "\(root)/vms/\(id.uuidString).bundle"
      try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
      let sentinelPath = "\(bundlePath)/Disk.img"
      try Data("must survive".utf8).write(to: URL(fileURLWithPath: sentinelPath))
      let externalMarkerPath = "\(root)/external-marker"
      try writePendingCreationMarker(
        at: externalMarkerPath,
        vmId: id,
        operation: "blank",
        phase: "creating"
      )
      let markerPath = pendingCreationMarkerPath(root: root, vmId: id)
      try FileManager.default.createSymbolicLink(atPath: markerPath, withDestinationPath: externalMarkerPath)

      await #expect(throws: VMManagerError.self) {
        try await vmManager.loadPersistedVMs()
      }

      #expect(FileManager.default.fileExists(atPath: sentinelPath))
      #expect(FileManager.default.fileExists(atPath: markerPath))
      #expect(FileManager.default.fileExists(atPath: externalMarkerPath))
    }
  }

  private func makeManager(
    root: String,
    vmBundleRemover: @escaping @Sendable (String) throws -> Void = {
      try FileManager.default.removeItem(atPath: $0)
    }
  ) -> (VMManager, PersistenceStore) {
    let config = makeTestConfig(root: root)
    let eventBus = EventBus()
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
      vmBundleRemover: vmBundleRemover
    )
    return (vmManager, persistenceStore)
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

  private func writePendingCreationMarker(
    root: String,
    vmId: UUID,
    operation: String,
    phase: String,
    definition: VMDefinition? = nil
  ) throws -> String {
    let markerPath = pendingCreationMarkerPath(root: root, vmId: vmId)
    try writePendingCreationMarker(
      at: markerPath,
      vmId: vmId,
      operation: operation,
      phase: phase,
      definition: definition
    )
    return markerPath
  }

  private func writePendingCreationMarker(
    at markerPath: String,
    vmId: UUID,
    operation: String,
    phase: String,
    definition: VMDefinition? = nil
  ) throws {
    let payload = CreationMarkerPayload(
      formatVersion: 2,
      vmId: vmId,
      operation: operation,
      phase: phase,
      definition: definition
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(payload)
    try data.write(to: URL(fileURLWithPath: markerPath))
  }

  private func pendingCreationMarkerPath(root: String, vmId: UUID) -> String {
    "\(root)/vms/.\(vmId.uuidString).bundle.creation-pending"
  }
}

private enum TestBundleRemovalError: Error {
  case denied
}

private actor VMCreationPublicationGate {
  private var vmId: UUID?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func enterAndWait(_ vmId: UUID) async {
    self.vmId = vmId
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilEntered() async -> UUID {
    while true {
      if let vmId { return vmId }
      await Task.yield()
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private struct CreationMarkerPayload: Encodable {
  let formatVersion: Int
  let vmId: UUID
  let operation: String
  let phase: String
  let definition: VMDefinition?
}

private func iso8601RoundTrip(_ definition: VMDefinition) throws -> VMDefinition {
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  return try decoder.decode(VMDefinition.self, from: encoder.encode(definition))
}
