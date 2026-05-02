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
      network: VMNetwork(macAddress: "02:00:00:00:00:01"),
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
      #expect(await store.count() == 1)
      #expect(await store.vmExists(id))

      vm.updateState(.stopped)
      try await store.updateVM(id, vm)
      let loaded = try await store.getVM(id)
      #expect(loaded.state == .stopped)

      try await store.deleteVM(id)
      #expect(await store.count() == 0)
      #expect(await store.vmExists(id) == false)
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

      let listed = await store.listVMs()
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
      #expect(await store.count() == 2)

      try await store.deleteAllVMs()
      #expect(await store.count() == 0)
      #expect(await store.listVMs().isEmpty)
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
        try await store.getVM(missingID)
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
  func updateVMStatePersistsStateChange() async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let store = PersistenceStore(databasePath: "\(root)/vms.json")
      let id = UUID()
      let vm = makeDefinition(id: id, name: "stateful", basePath: root, createdAt: Date())

      try await store.createVM(vm)
      try await store.updateVMState(id, state: .running)

      let reloaded = try await store.getVM(id)
      #expect(reloaded.state == .running)
    }
  }

  @Test
  func invalidOnDiskDataFallsBackToEmptyDatabase() async throws {
    try await withTemporaryDirectory(prefix: "persistence") { root in
      let dbPath = "\(root)/vms.json"
      try Data("not-json".utf8).write(to: URL(fileURLWithPath: dbPath))

      let store = PersistenceStore(databasePath: dbPath)
      #expect(await store.count() == 0)

      let vm = makeDefinition(name: "after-recovery", basePath: root, createdAt: Date())
      try await store.createVM(vm)
      #expect(await store.count() == 1)
    }
  }
}
