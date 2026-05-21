import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes), .serialized)
struct APIServerValidationPathTests {
  private func decodedError(_ response: HTTPResponse) throws -> ErrorResponse {
    try JSONDecoder().decode(ErrorResponse.self, from: #require(response.body))
  }

  @Test
  func handlersReturn400ForInvalidIdentifiersOrMissingBody() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)

      let badIDResponse = await server.handleGetVM(
        HTTPRequest(method: "GET", path: "/v1/vms/not-a-uuid", headers: [:], body: nil, queryParameters: [:])
      )
      let missingBodyResponse = await server.handleCreateVM(
        HTTPRequest(method: "POST", path: "/v1/vms", headers: [:], body: nil, queryParameters: [:])
      )
      let badJSONResponse = await server.handleExecuteCommand(
        HTTPRequest(
          method: "POST",
          path: "/v1/vms/not-a-uuid/execute",
          headers: [:],
          body: Data("{".utf8),
          queryParameters: [:]
        )
      )

      let badIDError = try decodedError(badIDResponse)
      let missingBodyError = try decodedError(missingBodyResponse)

      #expect(badIDResponse.statusCode == 400)
      #expect(badIDError.error.code == "INVALID_ID")
      #expect(missingBodyResponse.statusCode == 400)
      #expect(missingBodyError.error.code == "INVALID_REQUEST")
      #expect(badJSONResponse.statusCode == 400)
    }
  }

  @Test
  func destructiveEndpointsRequireConfirmation() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)

      let wipeResponse = await server.handleWipeAllVMs(
        HTTPRequest(method: "DELETE", path: "/v1/vms", headers: [:], body: nil, queryParameters: [:])
      )
      let resetResponse = await server.handleSystemReset(
        HTTPRequest(method: "POST", path: "/v1/system/reset", headers: [:], body: nil, queryParameters: [:])
      )

      let wipeError = try decodedError(wipeResponse)
      let resetError = try decodedError(resetResponse)

      #expect(wipeResponse.statusCode == 400)
      #expect(wipeError.error.code == "CONFIRMATION_REQUIRED")
      #expect(resetResponse.statusCode == 400)
      #expect(resetError.error.code == "CONFIRMATION_REQUIRED")
    }
  }

  @Test
  func createAndExecuteValidationFailuresMapTo400() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let vmId = UUID()

      let invalidResourcesResponse = await server.handleCreateVM(
        HTTPRequest(
          method: "POST",
          path: "/v1/vms",
          headers: [:],
          body: Data(#"{"name":"vm","resources":{"cpuCount":0}}"#.utf8),
          queryParameters: [:]
        )
      )

      let invalidExecuteResponse = await server.handleExecuteCommand(
        HTTPRequest(
          method: "POST",
          path: "/v1/vms/\(vmId.uuidString)/execute",
          headers: [:],
          body: Data(#"{"command":"echo hi","timeout":0}"#.utf8),
          queryParameters: [:]
        )
      )

      let resourcesError = try decodedError(invalidResourcesResponse)
      let executeError = try decodedError(invalidExecuteResponse)

      #expect(invalidResourcesResponse.statusCode == 400)
      #expect(resourcesError.error.code == "INVALID_RESOURCES")
      #expect(invalidExecuteResponse.statusCode == 400)
      #expect(executeError.error.code == "INVALID_REQUEST")
    }
  }

  @Test
  func updateVMValidationFailuresMapTo400() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let vmId = UUID()

      let badIDResponse = await server.handleUpdateVM(
        HTTPRequest(method: "PATCH", path: "/v1/vms/not-a-uuid", headers: [:], body: nil, queryParameters: [:])
      )
      let missingBodyResponse = await server.handleUpdateVM(
        HTTPRequest(
          method: "PATCH",
          path: "/v1/vms/\(vmId.uuidString)",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )
      let emptyBodyResponse = await server.handleUpdateVM(
        HTTPRequest(
          method: "PATCH",
          path: "/v1/vms/\(vmId.uuidString)",
          headers: [:],
          body: Data(#"{}"#.utf8),
          queryParameters: [:]
        )
      )
      let invalidResourcesResponse = await server.handleUpdateVM(
        HTTPRequest(
          method: "PATCH",
          path: "/v1/vms/\(vmId.uuidString)",
          headers: [:],
          body: Data(#"{"resources": {"cpuCount": 0}}"#.utf8),
          queryParameters: [:]
        )
      )

      let badIDError = try decodedError(badIDResponse)
      let missingBodyError = try decodedError(missingBodyResponse)
      let emptyBodyError = try decodedError(emptyBodyResponse)
      let invalidResourcesError = try decodedError(invalidResourcesResponse)

      #expect(badIDResponse.statusCode == 400)
      #expect(badIDError.error.code == "INVALID_ID")
      #expect(missingBodyResponse.statusCode == 400)
      #expect(missingBodyError.error.code == "INVALID_REQUEST")
      #expect(emptyBodyResponse.statusCode == 400)
      #expect(emptyBodyError.error.code == "INVALID_REQUEST")
      #expect(invalidResourcesResponse.statusCode == 400)
      #expect(invalidResourcesError.error.code == "INVALID_REQUEST")
    }
  }

  @Test
  func systemResetValidationAndJSONErrorsMapTo400() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)

      let invalidModeResponse = await server.handleSystemReset(
        HTTPRequest(
          method: "POST",
          path: "/v1/system/reset",
          headers: [:],
          body: Data(#"{"mode":"nuke"}"#.utf8),
          queryParameters: ["confirm": "true"]
        )
      )

      let invalidJSONResponse = await server.handleSystemReset(
        HTTPRequest(
          method: "POST",
          path: "/v1/system/reset",
          headers: [:],
          body: Data("{".utf8),
          queryParameters: ["confirm": "true"]
        )
      )

      let invalidModeError = try decodedError(invalidModeResponse)
      let invalidJSONError = try decodedError(invalidJSONResponse)

      #expect(invalidModeResponse.statusCode == 400)
      #expect(invalidModeError.error.code == "INVALID_REQUEST")
      #expect(invalidJSONResponse.statusCode == 400)
      #expect(invalidJSONError.error.code == "INVALID_REQUEST")
    }
  }

  @Test
  func handleVerifyAuthReturns200() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let response = await server.handleVerifyAuth()

      #expect(response.statusCode == 200)
      let body = try #require(response.body)
      let json = try JSONDecoder().decode([String: String].self, from: body)
      #expect(json["status"] == "ok")
    }
  }

  @Test
  func stoppingStoppedVMReturnsExistingState() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let definition = try await server.vmManager.createVM(name: "stopped-vm", resources: .default)
      let instance = try await server.vmManager.getVMInstance(definition.id)

      await MainActor.run {
        instance.stateMachine.forceState(.stopped)
        instance.definition.updateState(.stopped)
      }
      try await server.vmManager.updateVMDefinition(definition.id, definition: MainActor.run { instance.definition })

      let response = await server.handleStopVM(
        HTTPRequest(
          method: "POST",
          path: "/v1/vms/\(definition.id.uuidString)/stop",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )

      #expect(response.statusCode == 200)
      let body = try #require(response.body)
      let decoded = try JSONDecoder().decode(VMResponse.self, from: body)
      #expect(decoded.id == definition.id.uuidString)
      #expect(decoded.state == "stopped")
    }
  }

  @Test
  func forceStoppingInstallingVMCancelsTrackedInstallationTask() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let definition = try await server.vmManager.createVM(name: "installing-vm", resources: .default)
      let instance = try await server.vmManager.getVMInstance(definition.id)

      try await MainActor.run {
        try instance.stateMachine.transition(to: .installing)
        instance.definition.updateState(.installing)
      }
      try await server.vmManager.updateVMDefinition(definition.id, definition: MainActor.run { instance.definition })

      let installTask = Task<Void, Never> {
        do {
          try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {}
      }
      let claimedTask = server.claimInstallationTask(definition.id) { _ in installTask }
      #expect(claimedTask != nil)

      try await server.vmManager.forceStopVM(definition.id)

      await Task.yield()

      #expect(installTask.isCancelled)
      #expect(server.cancelInstallationTask(definition.id) == false)
    }
  }

  @Test
  func pushImageFromErrorStateVMReturns409() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let persistenceStore = PersistenceStore(databasePath: config.storage.databasePath)
      let vmId = UUID()
      var definition = VMDefinition(
        id: vmId,
        name: "error-vm",
        state: .error,
        resources: .default,
        network: VMNetwork(macAddress: "02:00:00:00:00:01"),
        paths: VMPaths.forVM(id: vmId, baseDir: config.storage.vmStorageDir),
        createdAt: Date(),
        updatedAt: Date()
      )
      definition.updateState(.error)
      try await persistenceStore.createVM(definition)

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
      try await vmManager.loadPersistedVMs()

      let imageStore = ImageStore(storagePath: config.images.imageStorageDir)
      let orasClient = OrasClient(config: config.images)
      let imageManager = ImageManager(
        imageStore: imageStore,
        orasClient: orasClient,
        eventBus: eventBus,
        config: config
      )
      let server = APIServer(
        vmManager: vmManager,
        portForwardingManager: portForwardingManager,
        imageManager: imageManager,
        eventBus: eventBus,
        config: config
      )

      let pushBody = Data(#"{"source":"vm:\#(vmId.uuidString)","reference":"registry.example.com/repo:tag"}"#.utf8)
      let response = await server.handlePushImage(
        HTTPRequest(method: "POST", path: "/v1/images/push", headers: [:], body: pushBody, queryParameters: [:])
      )
      let decoded = try decodedError(response)

      #expect(response.statusCode == 409)
      #expect(decoded.error.code == "INVALID_STATE")
    }
  }

  @Test
  func cancellingJeballtofileWaitStepReturnsCancelledStatusAndEvent() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let createBody = Data(#"{"name":"cancelvm","steps":[{"type":"wait","seconds":5}]}"#.utf8)

      let createResponse = await server.handleCreateJeballtofile(
        HTTPRequest(
          method: "POST",
          path: "/v1/jeballtofiles",
          headers: ["content-type": "application/json"],
          body: createBody,
          queryParameters: [:]
        )
      )
      #expect(createResponse.statusCode == 202)
      let created = try JSONDecoder().decode(JeballtofileResponse.self, from: #require(createResponse.body))
      let executionId = try #require(UUID(uuidString: created.id))

      let stepStarted = await waitUntil {
        server.getJeballtofileExecutor(executionId)?.execution.stepResults.first?.status == .inProgress
      }
      #expect(stepStarted)

      let cancelResponse = await server.handleCancelJeballtofile(
        HTTPRequest(
          method: "POST",
          path: "/v1/jeballtofiles/\(executionId.uuidString)/cancel",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )
      #expect(cancelResponse.statusCode == 200)

      let cancelled = await waitUntil {
        guard let execution = server.getJeballtofileExecutor(executionId)?.execution else {
          return false
        }
        return execution.status == .cancelled && execution.stepResults.first?.status == .cancelled
      }
      #expect(cancelled)

      let statusResponse = await server.handleGetJeballtofileStatus(
        HTTPRequest(
          method: "GET",
          path: "/v1/jeballtofiles/\(executionId.uuidString)",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )
      let status = try JSONDecoder().decode(JeballtofileStatusResponse.self, from: #require(statusResponse.body))
      #expect(status.status == "cancelled")
      #expect(status.stepResults.first?.status == "cancelled")

      let eventPublished = await waitUntil {
        server.eventBus.getAllEvents(limit: 20).contains {
          $0.event.eventType == "JEBALLTOFILE_CANCELLED"
        }
      }
      #expect(eventPublished)
    }
  }

  @Test
  func pushMissingSourceImageReturns404() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let imageId = UUID()
      let body = Data(#"{"source":"image:\#(imageId.uuidString)","reference":"registry.example.com/repo:tag"}"#.utf8)

      let response = await server.handlePushImage(
        HTTPRequest(method: "POST", path: "/v1/images/push", headers: [:], body: body, queryParameters: [:])
      )
      let decoded = try decodedError(response)

      #expect(response.statusCode == 404)
      #expect(decoded.error.code == "IMAGE_NOT_FOUND")
    }
  }
}
