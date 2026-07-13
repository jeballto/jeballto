import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.persistence))
struct PersistenceStoreTests {
  private func makeDefinition(id: UUID = UUID(), name: String, basePath: String, createdAt: Date) -> VMDefinition {
    VMDefinition(
      id: id,
      name: name,
      state: .created,
      resources: .default,
      network: VMNetwork(),
      paths: VMPaths.forVM(id: id, baseDir: basePath),
      createdAt: createdAt,
      updatedAt: createdAt
    )
  }

  @Test
  func createGetUpdateDeleteLifecycle() async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let dbPath = "\(root)/vms.json"
      let store = PersistenceStore(databasePath: dbPath)
      let id = UUID()
      var vm = makeDefinition(id: id, name: "vm-one", basePath: root, createdAt: Date())

      try await store.createVM(vm)
      #expect(try await store.count() == 1)
      #expect(try await store.vmExists(id))

      vm.updateState(.stopped)
      try await store.updateVM(id, vm)
      let loaded = try await store.getVM(id)
      #expect(loaded.state == .stopped)

      try await store.deleteVM(id)
      #expect(try await store.count() == 0)
      #expect(try await store.vmExists(id) == false)
    }
  }

  @Test
  func listVMsReturnsCreatedAtOrder() async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let store = PersistenceStore(databasePath: "\(root)/vms.json")
      let old = makeDefinition(name: "old", basePath: root, createdAt: Date(timeIntervalSince1970: 1))
      let new = makeDefinition(name: "new", basePath: root, createdAt: Date(timeIntervalSince1970: 2))

      try await store.createVM(new)
      try await store.createVM(old)

      let listed = try await store.listVMs()
      #expect(listed.map(\.name) == ["old", "new"])
    }
  }

  @Test
  func reloadingFromDiskKeepsData() async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let dbPath = "\(root)/vms.json"
      let id = UUID()
      let vm = makeDefinition(id: id, name: "reload", basePath: root, createdAt: Date())

      let firstStore = PersistenceStore(databasePath: dbPath)
      try await firstStore.createVM(vm)

      let secondStore = PersistenceStore(databasePath: dbPath)
      let loaded = try await secondStore.getVM(id)
      #expect(loaded.name == "reload")
    }
  }

  @Test
  func deleteAllVMsClearsDatabase() async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let store = PersistenceStore(databasePath: "\(root)/vms.json")
      let first = makeDefinition(name: "one", basePath: root, createdAt: Date())
      let second = makeDefinition(name: "two", basePath: root, createdAt: Date().addingTimeInterval(1))

      try await store.createVM(first)
      try await store.createVM(second)
      #expect(try await store.count() == 2)

      try await store.deleteAllVMs()
      #expect(try await store.count() == 0)
      #expect(try await store.listVMs().isEmpty)
    }
  }

  @Test
  func duplicateCreateThrowsAlreadyExists() async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let store = PersistenceStore(databasePath: "\(root)/vms.json")
      let id = UUID()
      let vm = makeDefinition(id: id, name: "dup", basePath: root, createdAt: Date())

      try await store.createVM(vm)

      do {
        try await store.createVM(vm)
        Issue.record("Expected duplicate create to throw")
      } catch let error as PersistenceError {
        switch error {
        case .vmAlreadyExists(let duplicateID):
          #expect(duplicateID == id)
        default:
          Issue.record("Expected vmAlreadyExists, got \(error.localizedDescription)")
        }
      }
    }
  }

  @Test
  func missingVMOperationsThrowNotFound() async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let store = PersistenceStore(databasePath: "\(root)/vms.json")
      let missingID = UUID()
      let replacement = makeDefinition(id: missingID, name: "missing", basePath: root, createdAt: Date())

      do {
        _ = try await store.getVM(missingID)
        Issue.record("Expected getVM to throw")
      } catch let error as PersistenceError {
        if case .vmNotFound(let id) = error {
          #expect(id == missingID)
        } else {
          Issue.record("Expected vmNotFound, got \(error.localizedDescription)")
        }
      }

      do {
        try await store.updateVM(missingID, replacement)
        Issue.record("Expected updateVM to throw")
      } catch let error as PersistenceError {
        if case .vmNotFound(let id) = error {
          #expect(id == missingID)
        } else {
          Issue.record("Expected vmNotFound, got \(error.localizedDescription)")
        }
      }

      do {
        try await store.deleteVM(missingID)
        Issue.record("Expected deleteVM to throw")
      } catch let error as PersistenceError {
        if case .vmNotFound(let id) = error {
          #expect(id == missingID)
        } else {
          Issue.record("Expected vmNotFound, got \(error.localizedDescription)")
        }
      }
    }
  }

  @Test
  func updateVMStateUsesAtomicFirstBootPathForRunning() async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let store = PersistenceStore(databasePath: "\(root)/vms.json")
      let id = UUID()
      let vm = makeDefinition(id: id, name: "stateful", basePath: root, createdAt: Date())

      try await store.createVM(vm)
      try await store.updateVMState(id, state: .running)

      let reloaded = try await store.getVM(id)
      #expect(reloaded.state == .running)
      #expect(reloaded.hasBooted)
    }
  }

  @Test
  func invalidOnDiskDataBlocksReadsAndMutationAndPreservesFile() async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let dbPath = "\(root)/vms.json"
      let originalData = Data("not-json".utf8)
      try originalData.write(to: URL(fileURLWithPath: dbPath))

      let store = PersistenceStore(databasePath: dbPath)
      await #expect(throws: PersistenceError.self) {
        _ = try await store.count()
      }
      await #expect(throws: PersistenceError.self) {
        _ = try await store.listVMs()
      }
      await #expect(throws: PersistenceError.self) {
        _ = try await store.vmExists(UUID())
      }

      let vm = makeDefinition(name: "after-recovery", basePath: root, createdAt: Date())
      do {
        try await store.createVM(vm)
        Issue.record("Expected corrupt database to block writes")
      } catch let error as PersistenceError {
        if case .invalidData(let reason) = error {
          #expect(reason.contains("Refusing to overwrite it"))
        } else {
          Issue.record("Expected invalidData, got \(error.localizedDescription)")
        }
      }

      let preservedData = try Data(contentsOf: URL(fileURLWithPath: dbPath))
      #expect(preservedData == originalData)
    }
  }

  @Test
  func failedWriteDoesNotMutateInMemoryDatabase() async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let storage = "\(root)/storage"
      try FileManager.default.createDirectory(atPath: storage, withIntermediateDirectories: true)
      let store = PersistenceStore(databasePath: "\(storage)/vms.json")
      let original = makeDefinition(name: "original", basePath: root, createdAt: Date())
      try await store.createVM(original)

      try FileManager.default.removeItem(atPath: storage)
      var changed = original
      changed.name = "must-not-stick"

      do {
        try await store.updateVM(original.id, changed)
        Issue.record("Expected write to a removed storage directory to fail")
      } catch {
        let retained = try await store.getVM(original.id)
        #expect(retained.name == "original")
      }
    }
  }

  @Test
  func postPublishDirectorySyncFailureDoesNotSplitMemoryFromPublishedDatabase() async throws {
    try await withTemporaryDirectory(prefix: "persistence-post-publish") { root in
      let databasePath = "\(root)/vms.json"
      let store = PersistenceStore(
        databasePath: databasePath,
        postPublishSync: { _ in throw PersistenceSyncTestError.injected }
      )
      let first = makeDefinition(name: "first", basePath: root, createdAt: Date(timeIntervalSince1970: 1))
      let second = makeDefinition(name: "second", basePath: root, createdAt: Date(timeIntervalSince1970: 2))

      try await store.createVM(first)
      try await store.createVM(second)

      #expect(try await store.count() == 2)
      let reloaded = PersistenceStore(databasePath: databasePath)
      #expect(try await reloaded.vmExists(first.id))
      #expect(try await reloaded.vmExists(second.id))
    }
  }

  @Test
  func networkFieldUpdatesPreserveUnrelatedDefinitionChanges() async throws {
    try await withTemporaryDirectory(prefix: "persistence-network-merge") { root in
      let store = PersistenceStore(databasePath: "\(root)/vms.json")
      var definition = makeDefinition(name: "original", basePath: root, createdAt: Date())
      try await store.createVM(definition)

      definition.name = "renamed"
      definition.updateVNCPort(5901)
      try await store.updateVM(definition.id, definition)
      _ = try await store.updateVMNetworkField(definition.id, update: .sshPort(2222))
      _ = try await store.updateVMNetworkField(definition.id, update: .natIP("192.168.64.2"))

      let updated = try await store.getVM(definition.id)
      #expect(updated.name == "renamed")
      #expect(updated.network.sshPort == 2222)
      #expect(updated.network.vncPort == 5901)
      #expect(updated.network.natIP == "192.168.64.2")
    }
  }

  @Test
  func configurationPatchPreservesConcurrentLifecycleAndNetworkFields() async throws {
    try await withTemporaryDirectory(prefix: "persistence-config-merge") { root in
      let store = PersistenceStore(databasePath: "\(root)/vms.json")
      let definition = makeDefinition(name: "original", basePath: root, createdAt: Date())
      try await store.createVM(definition)
      _ = try await store.updateVMLifecycle(definition.id, state: .stopped, markBooted: true)
      _ = try await store.updateVMNetworkField(definition.id, update: .sshPort(2222))

      var resources = definition.resources
      resources.cpuCount = 2
      let updated = try await store.updateVMConfiguration(
        definition.id,
        name: "renamed",
        resources: resources,
        metadataUpdates: ["operation": "complete"]
      )

      #expect(updated.name == "renamed")
      #expect(updated.resources.cpuCount == 2)
      #expect(updated.state == .stopped)
      #expect(updated.hasBooted)
      #expect(updated.network.sshPort == 2222)
      #expect(updated.metadata["operation"] == "complete")
    }
  }

  @Test
  func runningUpdateAtomicallyRecordsFirstBootAndLifetimeDeadline() async throws {
    try await withTemporaryDirectory(prefix: "persistence-first-boot") { root in
      let store = PersistenceStore(databasePath: "\(root)/vms.json")
      var definition = makeDefinition(name: "lifetime", basePath: root, createdAt: Date())
      definition.lifetimeSeconds = 300
      try await store.createVM(definition)
      let firstRunningAt = Date(timeIntervalSince1970: 1_700_000_000)

      await #expect(throws: PersistenceError.self) {
        _ = try await store.updateVMLifecycle(definition.id, state: .running, markBooted: true)
      }

      let running = try await store.updateVMRunning(definition.id, runningAt: firstRunningAt)

      #expect(running.state == .running)
      #expect(running.hasBooted)
      #expect(running.expiresAt == firstRunningAt.addingTimeInterval(300))

      let repeated = try await store.updateVMRunning(
        definition.id,
        runningAt: firstRunningAt.addingTimeInterval(1000)
      )
      #expect(repeated.expiresAt == running.expiresAt)
    }
  }

  @Test
  func unbootedVMWithLifetimeAndNoDeadlineIsValid() async throws {
    try await withTemporaryDirectory(prefix: "persistence-preboot-lifetime") { root in
      let store = PersistenceStore(databasePath: "\(root)/vms.json")
      var definition = makeDefinition(name: "preboot-lifetime", basePath: root, createdAt: Date())
      definition.lifetimeSeconds = 300

      try await store.createVM(definition)

      let persisted = try await store.getVM(definition.id)
      #expect(persisted.hasBooted == false)
      #expect(persisted.expiresAt == nil)
      #expect(persisted.lifetimeSeconds == 300)
    }
  }

  @Test
  func bootedVMWithLifetimeAndNoDeadlineIsRejected() async throws {
    try await withTemporaryDirectory(prefix: "persistence-missing-deadline") { root in
      let store = PersistenceStore(databasePath: "\(root)/vms.json")
      var definition = makeDefinition(name: "missing-deadline", basePath: root, createdAt: Date())
      definition.updateState(.stopped)
      definition.hasBooted = true
      definition.lifetimeSeconds = 300

      await #expect(throws: PersistenceError.self) {
        try await store.createVM(definition)
      }
      let retainedCount = try await store.count()
      #expect(retainedCount == 0)
    }
  }

  @Test
  func failedRunningUpdateLeavesAllFirstBootFieldsUnchanged() async throws {
    try await withTemporaryDirectory(prefix: "persistence-first-boot-failure") { root in
      let storage = "\(root)/database"
      let store = PersistenceStore(databasePath: "\(storage)/vms.json")
      var definition = makeDefinition(name: "lifetime", basePath: root, createdAt: Date())
      definition.lifetimeSeconds = 300
      try await store.createVM(definition)
      try FileManager.default.removeItem(atPath: storage)

      await #expect(throws: PersistenceError.self) {
        _ = try await store.updateVMRunning(
          definition.id,
          runningAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
      }

      let retained = try await store.getVM(definition.id)
      #expect(retained.state == .created)
      #expect(retained.hasBooted == false)
      #expect(retained.expiresAt == nil)
    }
  }

  @Test
  func corruptPrimaryRecoversFromBackup() async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let dbPath = "\(root)/vms.json"
      let firstStore = PersistenceStore(databasePath: dbPath)
      let vm = makeDefinition(name: "recoverable", basePath: root, createdAt: Date())
      try await firstStore.createVM(vm)
      try FileManager.default.copyItem(atPath: dbPath, toPath: dbPath + ".bak")
      try Data("corrupt".utf8).write(to: URL(fileURLWithPath: dbPath))

      let recoveredStore = PersistenceStore(databasePath: dbPath)
      let recovered = try await recoveredStore.getVM(vm.id)
      #expect(recovered.name == "recoverable")

      let reloadedStore = PersistenceStore(databasePath: dbPath)
      #expect(try await reloadedStore.getVM(vm.id).name == "recoverable")
    }
  }

  @Test
  func missingPrimaryRecoversFromBackup() async throws {
    try await withTemporaryDirectory(prefix: "persistence-missing-primary") { root in
      let dbPath = "\(root)/vms.json"
      let firstStore = PersistenceStore(databasePath: dbPath)
      let first = makeDefinition(name: "first", basePath: root, createdAt: Date(timeIntervalSince1970: 1))
      let second = makeDefinition(name: "second", basePath: root, createdAt: Date(timeIntervalSince1970: 2))
      try await firstStore.createVM(first)
      try await firstStore.createVM(second)
      #expect(FileManager.default.fileExists(atPath: dbPath + ".bak"))
      try FileManager.default.removeItem(atPath: dbPath)

      let recoveredStore = PersistenceStore(databasePath: dbPath)

      #expect(try await recoveredStore.getVM(first.id).id == first.id)
      await #expect(throws: PersistenceError.self) {
        _ = try await recoveredStore.getVM(second.id)
      }
      #expect(FileManager.default.fileExists(atPath: dbPath))
    }
  }

  @Test
  func unsupportedDatabaseVersionBlocksAccess() async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let dbPath = "\(root)/vms.json"
      let encoder = JSONEncoder()
      let unsupportedData = try encoder.encode(VMDatabase(version: 999))
      try unsupportedData.write(to: URL(fileURLWithPath: dbPath))
      try encoder.encode(VMDatabase.empty).write(to: URL(fileURLWithPath: dbPath + ".bak"))
      let store = PersistenceStore(databasePath: dbPath)

      do {
        _ = try await store.getVM(UUID())
        Issue.record("Expected unsupported database version to fail")
      } catch let error as PersistenceError {
        #expect(error.localizedDescription.contains("version 999"))
      }
      #expect(try Data(contentsOf: URL(fileURLWithPath: dbPath)) == unsupportedData)
    }
  }

  @Test(arguments: ["hasBooted", "saveFilePath"])
  func versionOneDatabaseWithoutRequiredFieldIsRejected(field: String) async throws {
    try await withTemporaryDirectory(prefix: "persistence-required-fields") { root in
      let databasePath = "\(root)/vms.json"
      let definition = makeDefinition(name: "missing-required-field", basePath: root, createdAt: Date())
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let encoded = try encoder.encode(VMDatabase(vms: [definition.id: definition]))
      var databaseObject = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
      )
      if var keyedDefinitions = databaseObject["vms"] as? [String: Any] {
        let definitionKey = try #require(keyedDefinitions.keys.first)
        var definitionObject = try #require(keyedDefinitions[definitionKey] as? [String: Any])
        try removeRequiredField(field, from: &definitionObject)
        keyedDefinitions[definitionKey] = definitionObject
        databaseObject["vms"] = keyedDefinitions
      } else if var unkeyedDefinitions = databaseObject["vms"] as? [Any] {
        let definitionIndex = try #require(unkeyedDefinitions.firstIndex {
          ($0 as? [String: Any])?["hasBooted"] != nil
        })
        var definitionObject = try #require(unkeyedDefinitions[definitionIndex] as? [String: Any])
        try removeRequiredField(field, from: &definitionObject)
        unkeyedDefinitions[definitionIndex] = definitionObject
        databaseObject["vms"] = unkeyedDefinitions
      } else {
        Issue.record("Encoded VM database has an unexpected vms representation")
        return
      }
      let malformed = try JSONSerialization.data(withJSONObject: databaseObject)
      try malformed.write(to: URL(fileURLWithPath: databasePath))

      await #expect(throws: PersistenceError.self) {
        try await PersistenceStore(databasePath: databasePath).validateLoaded()
      }
    }
  }

  @Test
  func databaseRejectsMismatchedDictionaryAndDefinitionIDs() async throws {
    try await withTemporaryDirectory(prefix: "persistence-invalid-id") { root in
      let dbPath = "\(root)/vms.json"
      let definition = makeDefinition(name: "valid", basePath: root, createdAt: Date())
      try writeDatabase(VMDatabase(vms: [UUID(): definition]), to: dbPath)
      let store = PersistenceStore(databasePath: dbPath)

      await #expect(throws: PersistenceError.self) {
        try await store.validateLoaded()
      }
    }
  }

  @Test
  func databaseRejectsInvalidDefinitionSemantics() async throws {
    try await withTemporaryDirectory(prefix: "persistence-invalid-semantics") { root in
      let base = makeDefinition(name: "valid", basePath: root, createdAt: Date())
      var invalidDefinitions: [VMDefinition] = []

      var invalidName = base
      invalidName.name = " invalid"
      invalidDefinitions.append(invalidName)

      var invalidResources = base
      invalidResources.resources.cpuCount = 0
      invalidDefinitions.append(invalidResources)

      var invalidMAC = base
      invalidMAC.network.macAddress = "not-a-mac"
      invalidDefinitions.append(invalidMAC)

      var globallyAdministeredMAC = base
      globallyAdministeredMAC.network.macAddress = "00:11:22:33:44:55"
      invalidDefinitions.append(globallyAdministeredMAC)

      var multicastMAC = base
      multicastMAC.network.macAddress = "03:11:22:33:44:55"
      invalidDefinitions.append(multicastMAC)

      var invalidNATIP = base
      invalidNATIP.network.natIP = "registry.example.com"
      invalidDefinitions.append(invalidNATIP)

      var invalidPort = base
      invalidPort.network.sshPort = 65536
      invalidDefinitions.append(invalidPort)

      var duplicatePort = base
      duplicatePort.network.sshPort = 5901
      duplicatePort.network.vncPort = 5901
      invalidDefinitions.append(duplicatePort)

      var invalidLifetime = base
      invalidLifetime.lifetimeSeconds = 0
      invalidDefinitions.append(invalidLifetime)

      var orphanExpiry = base
      orphanExpiry.expiresAt = Date()
      invalidDefinitions.append(orphanExpiry)

      for (index, definition) in invalidDefinitions.enumerated() {
        let dbPath = "\(root)/invalid-\(index).json"
        try writeDatabase(VMDatabase(vms: [definition.id: definition]), to: dbPath)
        let store = PersistenceStore(databasePath: dbPath)
        do {
          try await store.validateLoaded()
          Issue.record("Expected invalid persisted VM definition at index \(index) to be rejected")
        } catch is PersistenceError {
          // Expected.
        }
      }
    }
  }

  @Test
  func databaseRejectsDuplicateMACAddressesAndForwardingPortsAcrossVMs() async throws {
    try await withTemporaryDirectory(prefix: "persistence-duplicate-network") { root in
      let first = makeDefinition(name: "first", basePath: root, createdAt: Date())
      var duplicateMAC = makeDefinition(name: "duplicate-mac", basePath: root, createdAt: Date())
      duplicateMAC.network.macAddress = first.network.macAddress.uppercased()

      let duplicateMACPath = "\(root)/duplicate-mac.json"
      try writeDatabase(VMDatabase(vms: [first.id: first, duplicateMAC.id: duplicateMAC]), to: duplicateMACPath)
      await #expect(throws: PersistenceError.self) {
        try await PersistenceStore(databasePath: duplicateMACPath).validateLoaded()
      }

      var firstWithPort = first
      firstWithPort.network.sshPort = 2222
      var duplicatePort = makeDefinition(name: "duplicate-port", basePath: root, createdAt: Date())
      duplicatePort.network.vncPort = 2222
      let duplicatePortPath = "\(root)/duplicate-port.json"
      try writeDatabase(
        VMDatabase(vms: [firstWithPort.id: firstWithPort, duplicatePort.id: duplicatePort]),
        to: duplicatePortPath
      )
      await #expect(throws: PersistenceError.self) {
        try await PersistenceStore(databasePath: duplicatePortPath).validateLoaded()
      }
    }
  }

  @Test
  func oversizedCandidateIsRejectedBeforeItCanBreakTheNextStartup() async throws {
    try await withTemporaryDirectory(prefix: "persistence-candidate-size") { root in
      let path = "\(root)/vms.json"
      let store = PersistenceStore(databasePath: path)
      var oversized = makeDefinition(name: "oversized", basePath: root, createdAt: Date())
      oversized.metadata["payload"] = String(repeating: "x", count: PersistenceStore.maxDatabaseSize + 1)

      await #expect(throws: PersistenceError.self) {
        try await store.createVM(oversized)
      }
      #expect(try await store.count() == 0)
      try await PersistenceStore(databasePath: path).validateLoaded()
    }
  }

  @Test
  func parentPathThatIsAFileFailsDatabaseInitialization() async throws {
    try await withTemporaryDirectory(prefix: "persistence-parent-file") { root in
      let parent = "\(root)/not-a-directory"
      try Data("file".utf8).write(to: URL(fileURLWithPath: parent))
      let store = PersistenceStore(databasePath: "\(parent)/vms.json")

      await #expect(throws: PersistenceError.self) {
        try await store.validateLoaded()
      }
    }
  }

  @Test
  func oversizedDatabaseIsRejectedBeforeDecode() async throws {
    try await withTemporaryDirectory(prefix: "persistence-oversized") { root in
      let dbPath = "\(root)/vms.json"
      try Data(repeating: 0x20, count: PersistenceStore.maxDatabaseSize + 1)
        .write(to: URL(fileURLWithPath: dbPath))
      let store = PersistenceStore(databasePath: dbPath)

      await #expect(throws: PersistenceError.self) {
        try await store.validateLoaded()
      }
    }
  }

  @Test
  func databaseAndBackupSymbolicLinksAreRejectedWithoutChangingTheirTargets() async throws {
    try await withTemporaryDirectory(prefix: "persistence-symlinks") { root in
      let databasePath = "\(root)/vms.json"
      let databaseTarget = "\(root)/external-database.json"
      try writeDatabase(.empty, to: databaseTarget)
      let originalDatabaseTarget = try Data(contentsOf: URL(fileURLWithPath: databaseTarget))
      try FileManager.default.createSymbolicLink(atPath: databasePath, withDestinationPath: databaseTarget)

      await #expect(throws: PersistenceError.self) {
        try await PersistenceStore(databasePath: databasePath).validateLoaded()
      }
      #expect(try Data(contentsOf: URL(fileURLWithPath: databaseTarget)) == originalDatabaseTarget)

      try FileManager.default.removeItem(atPath: databasePath)
      try FileManager.default.createSymbolicLink(
        atPath: databasePath,
        withDestinationPath: "\(root)/missing-database"
      )
      await #expect(throws: PersistenceError.self) {
        try await PersistenceStore(databasePath: databasePath).validateLoaded()
      }
      try FileManager.default.removeItem(atPath: databasePath)

      let store = PersistenceStore(databasePath: databasePath)
      let first = makeDefinition(name: "first", basePath: root, createdAt: Date())
      try await store.createVM(first)

      let backupTarget = "\(root)/external-backup"
      let originalBackupTarget = Data("preserve".utf8)
      try originalBackupTarget.write(to: URL(fileURLWithPath: backupTarget))
      try FileManager.default.createSymbolicLink(
        atPath: databasePath + ".bak",
        withDestinationPath: backupTarget
      )
      let second = makeDefinition(name: "second", basePath: root, createdAt: Date())

      await #expect(throws: PersistenceError.self) {
        try await store.createVM(second)
      }
      #expect(try await store.count() == 1)
      #expect(try Data(contentsOf: URL(fileURLWithPath: backupTarget)) == originalBackupTarget)
    }
  }

  private func writeDatabase(_ database: VMDatabase, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(database).write(to: URL(fileURLWithPath: path))
  }

  private func removeRequiredField(_ field: String, from definition: inout [String: Any]) throws {
    switch field {
    case "hasBooted":
      definition.removeValue(forKey: field)
    case "saveFilePath":
      var paths = try #require(definition["paths"] as? [String: Any])
      paths.removeValue(forKey: field)
      definition["paths"] = paths
    default:
      Issue.record("Unknown required field \(field)")
    }
  }
}

private enum PersistenceSyncTestError: Error {
  case injected
}
