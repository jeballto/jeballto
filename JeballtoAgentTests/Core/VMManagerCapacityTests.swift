import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core), .serialized)
struct VMManagerCapacityTests {
  @Test
  func pausedVMsCountAgainstCapacityBeforeStartingAnotherVM() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _) = makeManager(root: root)

      let first = try await vmManager.createVM(name: "first", resources: .default)
      let second = try await vmManager.createVM(name: "second", resources: .default)
      let third = try await vmManager.createVM(name: "third", resources: .default)

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
      let (vmManager, _) = makeManager(root: root)

      let active = try await vmManager.createVM(name: "active", resources: .default)
      let failing = try await vmManager.createVM(name: "failing", resources: .default)

      try await setState(.paused, vmId: active.id, vmManager: vmManager)
      try await setState(.stopped, vmId: failing.id, vmManager: vmManager)

      await #expect(throws: Error.self) {
        try await vmManager.startVM(failing.id)
      }
      #expect(await vmManager.activeVMCount() == 1)
    }
  }

  @Test
  func imageExportReservationBlocksBundleMutationsUntilReleased() async throws {
    try await withTemporaryDirectory { root in
      let (vmManager, _) = makeManager(root: root)
      let definition = try await vmManager.createVM(name: "exporting", resources: .default)

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

  private func makeManager(root: String) -> (VMManager, PersistenceStore) {
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
    return (vmManager, persistenceStore)
  }

  private func setState(_ state: VMState, vmId: UUID, vmManager: VMManager) async throws {
    let instance = try await vmManager.getVMInstance(vmId)
    await MainActor.run {
      instance.stateMachine.forceState(state)
      instance.definition.updateState(state)
    }
    let definition = await MainActor.run { instance.definition }
    try await vmManager.updateVMDefinition(vmId, definition: definition)
  }
}
