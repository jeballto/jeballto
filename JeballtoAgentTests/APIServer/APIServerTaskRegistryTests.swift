import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes), .serialized)
struct APIServerTaskRegistryTests {
  @Test
  func cancelledImageOperationWaitsForAdmissionGate() async {
    let gate = ImageOperationStartGate()
    let task = Task<Bool, Never> {
      await gate.wait()
      return Task.isCancelled
    }

    task.cancel()
    gate.open()
    #expect(await task.value)
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
          await server.finishImageOperationTask(operation.id, result: .failure(CancellationError()))
        }
      }
      let registeredTask = try #require(task)

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
      #expect(registeredTask.isCancelled)
      let cancelledStatus = try JSONDecoder().decode(ImageOperationStatusResponse.self, from: #require(response.body))
      #expect(cancelledStatus.status == "cancelled")
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
      let registeredTask = try #require(task)

      await registeredTask.value

      #expect(server.cancelImageOperationTask(operationId) == false)
    }
  }

  @Test
  func suspendedImageTaskRegistryRejectsLateRegistrationAtomically() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      await server.suspendImageOperationTaskRegistrationForTesting()

      let rejected = server.startImageOperationTask(UUID()) {
        Task<Void, Never> {
          Issue.record("Suspended image task must not start")
        }
      }
      #expect(rejected == nil)

      server.resumeImageOperationTaskRegistrationForTesting()
      let accepted = server.startImageOperationTask(UUID()) {
        Task<Void, Never> {}
      }
      let task = try #require(accepted)
      await task.value
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
      let registeredTask = try #require(task)

      await registeredTask.value
      #expect(server.cancelImageOperationTask(operation.id) == false)

      let status = try #require(await server.imageManager.getImageOperationStatus(operation.id))
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

  @Test
  func cancellationDoesNotOverwriteDurableImageSuccess() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let operation = await server.imageManager.startImageOperation(
        kind: .pull,
        reference: "registry.example.com/vm/macos:latest"
      )
      let record = ImageRecord(
        reference: operation.reference,
        digest: "sha256:\(String(repeating: "d", count: 64))",
        localPath: "\(root)/image.bundle"
      )
      let gate = ImageOperationStartGate()
      let task = server.startImageOperationTask(operation.id) {
        Task<Void, Never> {
          await withTaskCancellationHandler {
            await gate.wait()
          } onCancel: {
            gate.open()
          }
          await server.finishImageOperationTask(operation.id, result: .success(record))
        }
      }
      _ = try #require(task)

      let response = await server.handleCancelImagePullOperation(HTTPRequest(
        method: "DELETE",
        path: "/v1/images/pull/operations/\(operation.id.uuidString)",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))

      #expect(response.statusCode == 200)
      let status = try JSONDecoder().decode(ImageOperationStatusResponse.self, from: #require(response.body))
      #expect(status.status == "completed")
      #expect(status.digest == record.digest)
      #expect(status.image?.id == record.id.uuidString)
    }
  }

  @Test
  func concurrentCancellationWaitersShareTheAuthoritativeTaskCompletion() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let operation = await server.imageManager.startImageOperation(
        kind: .push,
        reference: "registry.example.com/vm/macos:latest"
      )
      let record = ImageRecord(
        reference: operation.reference,
        digest: "sha256:\(String(repeating: "e", count: 64))",
        localPath: "\(root)/image.bundle"
      )
      let started = AsyncTestSignal()
      let allowCompletion = AsyncTestSignal()
      let task = server.startImageOperationTask(operation.id) {
        Task<Void, Never> {
          await started.signal()
          await allowCompletion.wait()
          await server.finishImageOperationTask(operation.id, result: .success(record))
        }
      }
      let registeredTask = try #require(task)
      await started.wait()

      let firstWaiter = Task {
        await server.cancelAndWaitImageOperationTask(operation.id)
      }
      #expect(await waitUntil { registeredTask.isCancelled })

      let secondWaiter = Task {
        await server.cancelAndWaitImageOperationTask(operation.id)
      }
      await allowCompletion.signal()

      #expect(await firstWaiter.value)
      #expect(await secondWaiter.value)
      let status = try #require(await server.imageManager.getImageOperationStatus(operation.id))
      #expect(status.state == .completed)
      #expect(status.digest == record.digest)
      #expect(server.cancelImageOperationTask(operation.id) == false)
    }
  }

  @Test
  func maintenanceAndCancellationWaitersShareTheAuthoritativeTaskCompletion() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let operation = await server.imageManager.startImageOperation(
        kind: .pull,
        reference: "registry.example.com/vm/macos:latest"
      )
      let record = ImageRecord(
        reference: operation.reference,
        digest: "sha256:\(String(repeating: "f", count: 64))",
        localPath: "\(root)/image.bundle"
      )
      let started = AsyncTestSignal()
      let allowCompletion = AsyncTestSignal()
      let task = server.startImageOperationTask(operation.id) {
        Task<Void, Never> {
          await started.signal()
          await allowCompletion.wait()
          await server.finishImageOperationTask(operation.id, result: .success(record))
        }
      }
      let registeredTask = try #require(task)
      await started.wait()

      let maintenance = Task {
        await server.suspendImageOperationTaskRegistrationForTesting()
      }
      #expect(await waitUntil { registeredTask.isCancelled })
      let cancellationWaiter = Task {
        await server.cancelAndWaitImageOperationTask(operation.id)
      }
      await allowCompletion.signal()

      await maintenance.value
      #expect(await cancellationWaiter.value)
      let status = try #require(await server.imageManager.getImageOperationStatus(operation.id))
      #expect(status.state == .completed)
      #expect(status.digest == record.digest)
      #expect(server.cancelImageOperationTask(operation.id) == false)
      server.resumeImageOperationTaskRegistrationForTesting()
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
      let orphaned = await server.imageManager.startImageOperation(
        kind: .push,
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
      let registeredTask = try #require(task)

      let response = await server.handleWipeAllImages(HTTPRequest(
        method: "DELETE",
        path: "/v1/images",
        headers: [:],
        body: nil,
        queryParameters: ["confirm": "true"]
      ))

      #expect(response.statusCode == 200)
      #expect(registeredTask.isCancelled)
      await registeredTask.value

      let status = try #require(await server.imageManager.getImageOperationStatus(operation.id))
      let orphanedStatus = try #require(await server.imageManager.getImageOperationStatus(orphaned.id))
      #expect(status.state == .cancelled)
      #expect(orphanedStatus.state == .cancelled)
      #expect(server.cancelImageOperationTask(operation.id) == false)
    }
  }

  @Test
  func listImageOperationsDefaultsToActiveOnTypedActionRoutes() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let pull = await server.imageManager.startImageOperation(
        kind: .pull,
        reference: "registry.example.com/vm/macos:latest"
      )
      let push = await server.imageManager.startImageOperation(
        kind: .push,
        reference: "registry.example.com/vm/macos:latest"
      )
      await server.imageManager.failImageOperation(push.id, error: CancellationError())

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
  func cancelImageOperationsCancelsTasksAndOrphanStatuses() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let taskBacked = await server.imageManager.startImageOperation(
        kind: .pull,
        reference: "registry.example.com/vm/macos:latest"
      )
      let orphaned = await server.imageManager.startImageOperation(
        kind: .pull,
        reference: "registry.example.com/vm/macos:latest"
      )
      let task = server.startImageOperationTask(taskBacked.id) {
        Task<Void, Never> {
          do {
            while true {
              try await Task.sleep(nanoseconds: 1_000_000_000)
            }
          } catch is CancellationError {
            await server.finishImageOperationTask(taskBacked.id, result: .failure(CancellationError()))
          } catch {
            await server.finishImageOperationTask(taskBacked.id, result: .failure(error))
          }
        }
      }
      let registeredTask = try #require(task)

      let response = await server.handleCancelImagePullOperations(HTTPRequest(
        method: "DELETE",
        path: "/v1/images/pull/operations",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))

      #expect(response.statusCode == 200)
      #expect(registeredTask.isCancelled)
      let cancelResponse = try JSONDecoder().decode(
        ImageOperationCancelAllResponse.self,
        from: #require(response.body)
      )
      #expect(cancelResponse.cancelled == 2)
      #expect(cancelResponse.tasksCancelled == 1)
      #expect(Set(cancelResponse.operations.map(\.operationId)) == [
        taskBacked.id.uuidString,
        orphaned.id.uuidString,
      ])
      #expect(cancelResponse.operations.allSatisfy { $0.status == "cancelled" })

      let taskBackedStatus = try #require(await server.imageManager.getImageOperationStatus(taskBacked.id))
      let orphanedStatus = try #require(await server.imageManager.getImageOperationStatus(orphaned.id))
      #expect(taskBackedStatus.state == .cancelled)
      #expect(orphanedStatus.state == .cancelled)
      #expect(server.cancelImageOperationTask(taskBacked.id) == false)
    }
  }

  @Test
  func imageOperationTypedRoutesGetAndCancelById() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let operation = await server.imageManager.startImageOperation(
        kind: .push,
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
      let registeredTask = try #require(task)

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
      #expect(registeredTask.isCancelled)
      let cancelled = try JSONDecoder().decode(ImageOperationStatusResponse.self, from: #require(cancelResponse.body))
      #expect(cancelled.status == "cancelled")
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

  @Test
  func jeballtofileHistoryRetainsOnlyNewestTerminalExecutions() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let limit = APIServer.maximumRetainedTerminalJeballtofileExecutions
      let executionIds = (0 ..< limit + 2).map { _ in UUID() }

      for executionId in executionIds {
        await registerCompletedJeballtofileExecution(executionId, on: server)
      }

      let retainedIds = Set(server.listJeballtofileExecutors().map(\.execution.id))
      #expect(retainedIds == Set(executionIds.suffix(limit)))
      #expect(server.getJeballtofileExecutor(executionIds[0]) == nil)
      #expect(server.getJeballtofileExecutor(executionIds[1]) == nil)
    }
  }

  @Test
  func jeballtofileHistoryNeverPrunesActiveExecutions() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let limit = APIServer.maximumRetainedTerminalJeballtofileExecutions
      let activeIds = [UUID(), UUID(), UUID()]

      for executionId in activeIds {
        let executor = makeJeballtofileExecutor(executionId: executionId, server: server)
        server.setJeballtofileExecutor(executionId, executor: executor)
      }

      let terminalIds = (0 ..< limit + 1).map { _ in UUID() }
      for executionId in terminalIds {
        await registerCompletedJeballtofileExecution(executionId, on: server)
      }

      let retainedExecutors = server.listJeballtofileExecutors()
      let retainedIds = Set(retainedExecutors.map(\.execution.id))
      #expect(retainedExecutors.count == limit + activeIds.count)
      #expect(retainedIds.isSuperset(of: activeIds))
      #expect(retainedIds.intersection(terminalIds) == Set(terminalIds.suffix(limit)))
      #expect(activeIds.allSatisfy { server.getJeballtofileExecutor($0)?.execution.status == .running })
    }
  }

  @Test
  func cancellationBeforeStartCannotPublishAStartedEvent() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let executionId = UUID()
      let executor = makeJeballtofileExecutor(executionId: executionId, server: server)
      server.setJeballtofileExecutor(executionId, executor: executor)

      #expect(executor.cancel())
      executor.start()
      await executor.waitUntilFinished()
      await server.eventBus.waitUntilIdle()

      #expect(executor.isFinished)
      #expect(server.eventBus.getEvents(forVM: executor.execution.vmId).map(\.event) == [
        .jeballtofileCancelled(
          executionId: executionId,
          vmId: executor.execution.vmId,
          step: 0
        ),
      ])
    }
  }

  private func registerCompletedJeballtofileExecution(_ executionId: UUID, on server: APIServer) async {
    let executor = makeJeballtofileExecutor(executionId: executionId, server: server)
    server.setJeballtofileExecutor(executionId, executor: executor)
    executor.start()
    await executor.waitUntilFinished()
  }

  private func makeJeballtofileExecutor(executionId: UUID, server: APIServer) -> JeballtofileExecutor {
    JeballtofileExecutor(
      execution: JeballtofileExecution(id: executionId, vmId: UUID(), totalSteps: 0),
      steps: [],
      source: nil,
      vmManager: server.vmManager,
      eventBus: server.eventBus,
      onTerminal: { [weak server] executionId in
        server?.recordTerminalJeballtofileExecutor(executionId)
      }
    )
  }
}
