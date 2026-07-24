import Foundation
import Testing
@testable import JeballtoAgent

/// Version-gate and backup behaviour for the VM database: the version is validated before the
/// payload is decoded, and neither an incompatible primary nor an incompatible backup is rewritten.
@Suite(.tags(.persistence))
struct PersistenceStoreVersioningTests {
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

  @Test(arguments: [1, 999])
  func unsupportedDatabaseVersionBlocksAccess(version: Int) async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let dbPath = "\(root)/vms.json"
      let encoder = JSONEncoder()
      let unsupportedData = try encoder.encode(VMDatabase(version: version))
      try unsupportedData.write(to: URL(fileURLWithPath: dbPath))
      try encoder.encode(VMDatabase.empty).write(to: URL(fileURLWithPath: dbPath + ".bak"))
      let store = PersistenceStore(databasePath: dbPath)

      do {
        _ = try await store.getVM(UUID())
        Issue.record("Expected unsupported database version to fail")
      } catch let error as PersistenceError {
        guard case .unsupportedDatabaseVersion(let found, let expected) = error else {
          Issue.record("Expected unsupportedDatabaseVersion, got \(error.localizedDescription)")
          return
        }
        #expect(found == version)
        #expect(expected == 2)
      }
      #expect(try Data(contentsOf: URL(fileURLWithPath: dbPath)) == unsupportedData)
    }
  }

  @Test
  func missingDatabaseVersionDoesNotRestoreCurrentBackup() async throws {
    try await withTemporaryDirectory(prefix: "persistence-missing-version") { root in
      let databasePath = "\(root)/vms.json"
      let backupPath = databasePath + ".bak"
      let primaryData = try JSONSerialization.data(withJSONObject: ["vms": [:]])
      let backupData = try JSONEncoder().encode(VMDatabase.empty)
      try primaryData.write(to: URL(fileURLWithPath: databasePath))
      try backupData.write(to: URL(fileURLWithPath: backupPath))

      do {
        try await PersistenceStore(databasePath: databasePath).validateLoaded()
        Issue.record("Expected a missing database version to fail")
      } catch let error as PersistenceError {
        guard case .missingDatabaseVersion(let path, let expected) = error else {
          Issue.record("Expected missingDatabaseVersion, got \(error.localizedDescription)")
          return
        }
        #expect(path == databasePath)
        #expect(expected == 2)
      }

      #expect(try Data(contentsOf: URL(fileURLWithPath: databasePath)) == primaryData)
      #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == backupData)
    }
  }

  @Test
  func nonIntegerDatabaseVersionIsRejectedExplicitly() async throws {
    try await withTemporaryDirectory(prefix: "persistence-invalid-version") { root in
      let databasePath = "\(root)/vms.json"
      let primaryData = try JSONSerialization.data(
        withJSONObject: ["version": "2", "vms": [:]]
      )
      try primaryData.write(to: URL(fileURLWithPath: databasePath))

      do {
        try await PersistenceStore(databasePath: databasePath).validateLoaded()
        Issue.record("Expected a non-integer database version to fail")
      } catch let error as PersistenceError {
        guard case .invalidDatabaseVersion(let path, let expected) = error else {
          Issue.record("Expected invalidDatabaseVersion, got \(error.localizedDescription)")
          return
        }
        #expect(path == databasePath)
        #expect(expected == 2)
      }

      #expect(try Data(contentsOf: URL(fileURLWithPath: databasePath)) == primaryData)
    }
  }

  @Test(arguments: ["hasBooted", "saveFilePath"])
  func versionOneDatabaseIsRejectedBeforeRequiredFieldDecode(field: String) async throws {
    try await withTemporaryDirectory(prefix: "persistence-required-fields") { root in
      let databasePath = "\(root)/vms.json"
      let definition = makeDefinition(name: "missing-required-field", basePath: root, createdAt: Date())
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let encoded = try encoder.encode(VMDatabase(version: 1, vms: [definition.id: definition]))
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

      do {
        try await PersistenceStore(databasePath: databasePath).validateLoaded()
        Issue.record("Expected the v1 database to be rejected before schema decoding")
      } catch let error as PersistenceError {
        guard case .unsupportedDatabaseVersion(let found, let expected) = error else {
          Issue.record("Expected unsupportedDatabaseVersion, got \(error.localizedDescription)")
          return
        }
        #expect(found == 1)
        #expect(expected == 2)
      }
    }
  }

  @Test
  func incompatibleBackupIsNotOverwrittenByMutation() async throws {
    try await withTemporaryDirectory(prefix: "persistence-incompatible-backup") { root in
      let databasePath = "\(root)/vms.json"
      let backupPath = databasePath + ".bak"
      let store = PersistenceStore(databasePath: databasePath)
      let existing = makeDefinition(name: "existing", basePath: root, createdAt: Date())
      try await store.createVM(existing)

      let primaryData = try Data(contentsOf: URL(fileURLWithPath: databasePath))
      let incompatibleBackup = try JSONEncoder().encode(VMDatabase(version: 1))
      try incompatibleBackup.write(to: URL(fileURLWithPath: backupPath))
      let additional = makeDefinition(name: "additional", basePath: root, createdAt: Date())

      do {
        try await store.createVM(additional)
        Issue.record("Expected an incompatible backup to block mutation")
      } catch let error as PersistenceError {
        guard case .unsupportedDatabaseVersion(let found, let expected) = error else {
          Issue.record("Expected unsupportedDatabaseVersion, got \(error.localizedDescription)")
          return
        }
        #expect(found == 1)
        #expect(expected == 2)
      }

      #expect(try await store.count() == 1)
      #expect(try Data(contentsOf: URL(fileURLWithPath: databasePath)) == primaryData)
      #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == incompatibleBackup)
    }
  }

  @Test
  func missingPrimaryDoesNotRestoreVersionOneBackup() async throws {
    try await withTemporaryDirectory(prefix: "persistence-incompatible-backup-recovery") { root in
      let databasePath = "\(root)/vms.json"
      let backupPath = databasePath + ".bak"
      let incompatibleBackup = try JSONEncoder().encode(VMDatabase(version: 1))
      try incompatibleBackup.write(to: URL(fileURLWithPath: backupPath))

      do {
        try await PersistenceStore(databasePath: databasePath).validateLoaded()
        Issue.record("Expected a v1 backup to be rejected")
      } catch let error as PersistenceError {
        guard case .unsupportedDatabaseVersion(let found, let expected) = error else {
          Issue.record("Expected unsupportedDatabaseVersion, got \(error.localizedDescription)")
          return
        }
        #expect(found == 1)
        #expect(expected == 2)
      }

      #expect(FileManager.default.fileExists(atPath: databasePath) == false)
      #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == incompatibleBackup)
    }
  }
}
