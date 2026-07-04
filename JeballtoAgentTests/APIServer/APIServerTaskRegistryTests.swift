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

  @Test(arguments: [ImageOperationKind.pull, .push])
  func cancelImageOperationCancelsTaskAndMarksOperationCancelled(_ kind: ImageOperationKind) async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let operation = await server.imageManager.startImageOperation(
        kind: kind,
        reference: "registry.example.com/vm/macos:latest"
      )
      let task = server.startImageOperationTask(operation.id) {
        Task<Void, Never> {
          while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
          }
          try? await Task.sleep(nanoseconds: 50_000_000)
          await server.imageManager.failImageOperation(operation.id, error: CancellationError())
        }
      }

      let request = HTTPRequest(
        method: "DELETE",
        path: "/v1/images/\(kind.rawValue)/\(operation.id.uuidString)",
        headers: [:],
        body: nil,
        queryParameters: [:]
      )
      let response = switch kind {
      case .pull:
        await server.handleCancelImagePull(request)
      case .push:
        await server.handleCancelImagePush(request)
      }

      #expect(response.statusCode == 200)
      #expect(task.isCancelled)
      let cancellingStatus = try JSONDecoder().decode(ImageOperationStatusResponse.self, from: #require(response.body))
      #expect(cancellingStatus.status == "cancelling")
      await task.value
      let status = try #require(await server.imageManager.getImageOperationStatus(operation.id))
      #expect(status.state == .cancelled)
      #expect(server.cancelImageOperationTask(operation.id) == false)
    }
  }

  @Test
  func immediateImageOperationReleaseDoesNotLeaveStaleTask() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let operationId = UUID()
      let task = server.startImageOperationTask(operationId) {
        Task<Void, Never> {
          server.releaseImageOperationTask(operationId)
        }
      }

      await task.value

      #expect(server.cancelImageOperationTask(operationId) == false)
    }
  }

  @Test
  func finishedImageOperationIsTerminalBeforeTaskRelease() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let operation = await server.imageManager.startImageOperation(
        kind: .pull,
        reference: "registry.example.com/vm/macos:latest"
      )
      let record = ImageRecord(
        reference: operation.reference,
        digest: "sha256:\(String(repeating: "c", count: 64))",
        localPath: "\(root)/image.bundle"
      )

      let task = server.startImageOperationTask(operation.id) {
        Task<Void, Never> {
          await server.finishImageOperationTask(operation.id, result: .success(record))
        }
      }

      await task.value
      #expect(server.cancelImageOperationTask(operation.id) == false)

      let status = try #require(await server.imageManager.getImageOperationStatus(operation.id))
      #expect(status.state == .completed)

      let cancelResponse = await server.handleCancelImagePull(HTTPRequest(
        method: "DELETE",
        path: "/v1/images/pull/\(operation.id.uuidString)",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))
      #expect(cancelResponse.statusCode == 409)
    }
  }

  @Test
  func wipeAllImagesCancelsActiveImageOperationTasks() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let operation = await server.imageManager.startImageOperation(
        kind: .pull,
        reference: "registry.example.com/vm/macos:latest"
      )
      let task = server.startImageOperationTask(operation.id) {
        Task<Void, Never> {
          do {
            while true {
              try await Task.sleep(nanoseconds: 1_000_000_000)
            }
          } catch is CancellationError {
            await server.finishImageOperationTask(operation.id, result: .failure(CancellationError()))
          } catch {
            await server.finishImageOperationTask(operation.id, result: .failure(error))
          }
        }
      }

      let response = await server.handleWipeAllImages(HTTPRequest(
        method: "DELETE",
        path: "/v1/images",
        headers: [:],
        body: nil,
        queryParameters: ["confirm": "true"]
      ))

      #expect(response.statusCode == 200)
      #expect(task.isCancelled)
      await task.value

      let status = try #require(await server.imageManager.getImageOperationStatus(operation.id))
      #expect(status.state == .cancelled)
      #expect(server.cancelImageOperationTask(operation.id) == false)
    }
  }

  @Test
  func deleteImageConflictsWithActiveSourceImagePush() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let imageId = UUID()
      let operation = await server.imageManager.startImageOperation(
        kind: .push,
        reference: "registry.example.com/vm/macos:latest",
        source: "image:\(imageId.uuidString)"
      )

      let response = await server.handleDeleteImage(HTTPRequest(
        method: "DELETE",
        path: "/v1/images/\(imageId.uuidString)",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))

      #expect(response.statusCode == 409)
      let errorResponse = try JSONDecoder().decode(ErrorResponse.self, from: #require(response.body))
      #expect(errorResponse.error.code == "IMAGE_IN_USE")
      await server.imageManager.failImageOperation(operation.id, error: CancellationError())
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
