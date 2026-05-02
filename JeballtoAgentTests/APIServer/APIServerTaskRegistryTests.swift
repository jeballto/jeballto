import Foundation
import Testing
@testable import JeballtoAgent

/// Regression coverage for the install-task registry. Before the fix, releases went through a
/// `var`-computed property that lowered to get-modify-set and could evict a freshly-claimed
/// replacement when a stale task completed during a concurrent reclaim.
@Suite(.tags(.apiRoutes), .serialized)
struct APIServerTaskRegistryTests {
  @Test
  func releaseWithStaleTokenDoesNotEvictReclaim() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let vmId = UUID()

      let first = claimUnending(server: server, vmId: vmId)
      let firstToken = try #require(first.token)

      // A second claim for the same VM is rejected while the first is live.
      #expect(claimUnending(server: server, vmId: vmId).token == nil)

      // Cancelling the first task allows a reclaim (claim skips cancelled entries).
      first.task.cancel()
      _ = await first.task.value

      let second = claimUnending(server: server, vmId: vmId)
      let secondToken = try #require(second.token)
      #expect(secondToken != firstToken)

      // Simulate the stale completion path: the superseded first task tries to release using
      // its own token. This must NOT evict the second claim.
      server.releaseInstallationTask(vmId, token: firstToken)
      #expect(claimUnending(server: server, vmId: vmId).token == nil)

      // Releasing with the live token clears the slot.
      second.task.cancel()
      server.releaseInstallationTask(vmId, token: secondToken)
      let third = claimUnending(server: server, vmId: vmId)
      #expect(third.token != nil)
      third.task.cancel()
    }
  }

  @Test
  func concurrentClaimsForSameVMOnlyOneWins() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let vmId = UUID()

      let results = await withTaskGroup(of: UUID?.self, returning: [UUID].self) { group in
        for _ in 0 ..< 16 {
          group.addTask {
            claimUnending(server: server, vmId: vmId).token
          }
        }
        var tokens: [UUID] = []
        for await result in group {
          if let token = result { tokens.append(token) }
        }
        return tokens
      }

      #expect(results.count == 1)
    }
  }
}

private func claimUnending(server: APIServer, vmId: UUID) -> (token: UUID?, task: Task<Void, Never>) {
  var capturedToken: UUID?
  var capturedTask: Task<Void, Never>?
  _ = server.claimInstallationTask(vmId) { token in
    capturedToken = token
    let task = Task<Void, Never> {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
    }
    capturedTask = task
    return task
  }
  return (capturedToken, capturedTask ?? Task<Void, Never> {})
}
