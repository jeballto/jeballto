import Foundation
import Testing
@testable import JeballtoAgent

/// Route-level coverage for image operations now that admission, task ownership and status
/// all live in `ImageOperationCoordinator`. Operations are seeded through the coordinator
/// so the routes exercise a real task rather than a hand-built status record.
@Suite(.tags(.apiRoutes), .serialized)
struct APIServerImageOperationRegistryTests {
  @Test(arguments: [ImageOperationKind.pull, .push])
  func cancelImageOperationCancelsTaskAndMarksOperationCancelled(_ kind: ImageOperationKind) async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let operation = try await seedImageOperation(
        on: server.imageOperationCoordinator,
        kind: kind,
        run: runUntilCancelled
      )

      let request = HTTPRequest(
        method: "DELETE",
        path: "/v1/images/\(kind.rawValue)/operations/\(operation.id.uuidString)",
        headers: [:],
        body: nil,
        queryParameters: [:]
      )
      let response: HTTPResponse = switch kind {
      case .pull:
        await server.handleCancelImagePullOperation(request)
      case .push:
        await server.handleCancelImagePushOperation(request)
      }

      #expect(response.statusCode == 200)
      let cancelledStatus = try JSONDecoder().decode(ImageOperationStatusResponse.self, from: #require(response.body))
      #expect(cancelledStatus.status == "cancelled")
      let status = try #require(await server.imageOperationCoordinator.status(for: operation.id))
      #expect(status.state == .cancelled)
      // Terminal operations stay terminal, so a second cancel is a no-op rather than a re-cancel.
      #expect(await server.imageOperationCoordinator.cancelAndWait(operation.id) == false)
    }
  }

  @Test
  func finishedImageOperationIsTerminalAndRejectsLateCancellation() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let record = makeTestImageRecord(root: root, digestFill: "c")
      let operation = try await seedImageOperation(
        on: server.imageOperationCoordinator,
        kind: .pull
      ) { _ in record }

      _ = await server.imageOperationCoordinator.wait(for: operation.id)

      let status = try #require(await server.imageOperationCoordinator.status(for: operation.id))
      #expect(status.state == .completed)

      let cancelResponse = await server.handleCancelImagePullOperation(HTTPRequest(
        method: "DELETE",
        path: "/v1/images/pull/operations/\(operation.id.uuidString)",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))
      #expect(cancelResponse.statusCode == 409)
    }
  }

  /// Once the work has durably committed, a cancellation that arrives afterwards must not
  /// rewrite the operation as cancelled.
  @Test
  func cancellationDoesNotOverwriteDurableImageSuccess() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let record = makeTestImageRecord(root: root, digestFill: "d")
      let committed = AsyncTestSignal()
      let operation = try await seedImageOperation(
        on: server.imageOperationCoordinator,
        kind: .pull
      ) { _ in
        // Ignores cancellation: models work that has already been committed downstream.
        await committed.signal()
        return record
      }

      await committed.wait()

      let response = await server.handleCancelImagePullOperation(HTTPRequest(
        method: "DELETE",
        path: "/v1/images/pull/operations/\(operation.id.uuidString)",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))

      let status = try #require(await server.imageOperationCoordinator.status(for: operation.id))
      #expect(status.state == .completed)
      #expect(status.digest == record.digest)
      #expect(response.statusCode == 200 || response.statusCode == 409)
    }
  }

  @Test
  func concurrentCancellationWaitersShareTheAuthoritativeCompletion() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let started = AsyncTestSignal()
      let allowCompletion = AsyncTestSignal()
      let operation = try await seedImageOperation(
        on: server.imageOperationCoordinator,
        kind: .push
      ) { _ in
        await started.signal()
        await allowCompletion.wait()
        throw CancellationError()
      }
      await started.wait()

      let firstWaiter = Task { await server.imageOperationCoordinator.cancelAndWait(operation.id) }
      let secondWaiter = Task { await server.imageOperationCoordinator.cancelAndWait(operation.id) }
      await allowCompletion.signal()

      _ = await firstWaiter.value
      _ = await secondWaiter.value

      let status = try #require(await server.imageOperationCoordinator.status(for: operation.id))
      #expect(status.state == .cancelled)
      // Exactly one terminalization: further cancels find a terminal operation.
      #expect(await server.imageOperationCoordinator.cancelAndWait(operation.id) == false)
    }
  }

  @Test
  func wipeAllImagesCancelsActiveImageOperations() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let pull = try await seedImageOperation(
        on: server.imageOperationCoordinator,
        kind: .pull,
        run: runUntilCancelled
      )
      let push = try await seedImageOperation(
        on: server.imageOperationCoordinator,
        kind: .push,
        run: runUntilCancelled
      )

      let response = await server.handleWipeAllImages(HTTPRequest(
        method: "DELETE",
        path: "/v1/images",
        headers: [:],
        body: nil,
        queryParameters: ["confirm": "true"]
      ))

      #expect(response.statusCode == 200)
      let pullStatus = try #require(await server.imageOperationCoordinator.status(for: pull.id))
      let pushStatus = try #require(await server.imageOperationCoordinator.status(for: push.id))
      #expect(pullStatus.state == .cancelled)
      #expect(pushStatus.state == .cancelled)
    }
  }

  @Test
  func listImageOperationsDefaultsToActiveOnTypedActionRoutes() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let pull = try await seedImageOperation(
        on: server.imageOperationCoordinator,
        kind: .pull,
        run: runUntilCancelled
      )
      let push = try await seedImageOperation(on: server.imageOperationCoordinator, kind: .push) { _ in
        throw CancellationError()
      }
      _ = await server.imageOperationCoordinator.wait(for: push.id)

      let activeResponse = await server.handleListImagePullOperations(HTTPRequest(
        method: "GET",
        path: "/v1/images/pull/operations",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))
      #expect(activeResponse.statusCode == 200)
      let activeList = try JSONDecoder().decode(ImageOperationListResponse.self, from: #require(activeResponse.body))
      #expect(activeList.activeOnly)
      #expect(activeList.total == 1)
      #expect(activeList.type == "pull")
      #expect(activeList.operations.map(\.operationId) == [pull.id.uuidString])

      let pushResponse = await server.handleListImagePushOperations(HTTPRequest(
        method: "GET",
        path: "/v1/images/push/operations",
        headers: [:],
        body: nil,
        queryParameters: ["activeOnly": "false"]
      ))
      #expect(pushResponse.statusCode == 200)
      let pushList = try JSONDecoder().decode(ImageOperationListResponse.self, from: #require(pushResponse.body))
      #expect(pushList.activeOnly == false)
      #expect(pushList.type == "push")
      #expect(pushList.total == 1)
      #expect(pushList.operations.map(\.operationId) == [push.id.uuidString])
    }
  }

  @Test
  func cancelImageOperationsCancelsEveryActiveOperation() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let first = try await seedImageOperation(
        on: server.imageOperationCoordinator,
        kind: .pull,
        run: runUntilCancelled
      )
      let second = try await seedImageOperation(
        on: server.imageOperationCoordinator,
        kind: .pull,
        run: runUntilCancelled
      )

      let response = await server.handleCancelImagePullOperations(HTTPRequest(
        method: "DELETE",
        path: "/v1/images/pull/operations",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))

      #expect(response.statusCode == 200)
      let cancelResponse = try JSONDecoder().decode(
        ImageOperationCancelAllResponse.self,
        from: #require(response.body)
      )
      #expect(cancelResponse.cancelled == 2)
      #expect(cancelResponse.tasksCancelled == 2)
      #expect(Set(cancelResponse.operations.map(\.operationId)) == [
        first.id.uuidString,
        second.id.uuidString,
      ])
      #expect(cancelResponse.operations.allSatisfy { $0.status == "cancelled" })
    }
  }

  @Test
  func imageOperationTypedRoutesGetAndCancelById() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let operation = try await seedImageOperation(
        on: server.imageOperationCoordinator,
        kind: .push,
        run: runUntilCancelled
      )

      let statusResponse = await server.handleGetImagePushOperation(HTTPRequest(
        method: "GET",
        path: "/v1/images/push/operations/\(operation.id.uuidString)",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))
      #expect(statusResponse.statusCode == 200)
      let status = try JSONDecoder().decode(ImageOperationStatusResponse.self, from: #require(statusResponse.body))
      #expect(status.operationId == operation.id.uuidString)
      #expect(status.type == "push")

      let cancelResponse = await server.handleCancelImagePushOperation(HTTPRequest(
        method: "DELETE",
        path: "/v1/images/push/operations/\(operation.id.uuidString)",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))
      #expect(cancelResponse.statusCode == 200)
      let cancelled = try JSONDecoder().decode(ImageOperationStatusResponse.self, from: #require(cancelResponse.body))
      #expect(cancelled.status == "cancelled")
    }
  }

  /// A push reserves its source image during `prepare`, before the operation becomes visible.
  /// Deleting that image while the reservation is held must conflict rather than race.
  @Test
  func deleteImageConflictsWithActiveSourceImagePush() async throws {
    try await withTemporaryDirectory { root in
      let imageId = UUID()
      let imageStorage = "\(root)/images"
      let bundlePath = "\(imageStorage)/\(imageId.uuidString).bundle"
      try FileManager.default.createDirectory(atPath: imageStorage, withIntermediateDirectories: true)

      // Write the index before the bundle exists: the store refuses to load an absent index
      // while managed bundles are already on disk.
      let store = ImageStore(storagePath: imageStorage, indexPath: "\(root)/images.json")
      try await store.addImage(ImageRecord(
        id: imageId,
        reference: testImageOperationReference,
        localPath: bundlePath,
        metadata: ["ownsLocalPath": "true"]
      ))
      try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)

      let server = makeTestAPIServer(root: root)
      let claim = try await server.imageManager.claimImageExportWithRecord(imageId)

      let request = HTTPRequest(
        method: "DELETE",
        path: "/v1/images/\(imageId.uuidString)",
        headers: [:],
        body: nil,
        queryParameters: [:]
      )
      let response = await server.handleDeleteImage(request)

      #expect(response.statusCode == 409)
      let errorResponse = try JSONDecoder().decode(ErrorResponse.self, from: #require(response.body))
      #expect(errorResponse.error.code == "IMAGE_IN_USE")

      // Releasing the reservation clears the conflict.
      await server.imageManager.releaseImageExport(imageId, token: claim.token)
      #expect(await server.handleDeleteImage(request).statusCode == 204)
    }
  }
}
