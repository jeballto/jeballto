import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes))
struct APIMutationGateTests {
  @Test
  func maintenanceRejectsLateMutationsAndWaitsForExistingLease() async throws {
    let gate = APIMutationGate()
    let probe = MutationDrainProbe()
    let lease = try #require(await gate.acquireMutation())

    #expect(await gate.beginMaintenance())
    #expect(await gate.beginMaintenance() == false)
    #expect(await gate.acquireMutation() == nil)

    let drained = Task<Void, Never> {
      await probe.markEntered()
      await gate.waitUntilDrained()
      await probe.markCompleted()
    }
    #expect(await waitUntilAsync { await probe.entered })
    #expect(await waitUntilAsync { await gate.hasDrainWaiterForTesting() })
    #expect(await probe.completed == false)

    await gate.releaseMutation(lease)
    await drained.value
    #expect(await probe.completed)

    await gate.endMaintenance()
    let nextLease = try #require(await gate.acquireMutation())
    await gate.releaseMutation(nextLease)
  }
}

private actor MutationDrainProbe {
  private(set) var entered = false
  private(set) var completed = false

  func markEntered() {
    entered = true
  }

  func markCompleted() {
    completed = true
  }
}
