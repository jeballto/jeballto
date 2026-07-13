import Darwin
import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes), .serialized)
struct APIServerImageOperationRouteTests {
  private func decodedError(_ response: HTTPResponse) throws -> ErrorResponse {
    try JSONDecoder().decode(ErrorResponse.self, from: #require(response.body))
  }

  private func decodedImageOperationStatus(_ response: HTTPResponse) throws -> ImageOperationStatusResponse {
    try JSONDecoder().decode(ImageOperationStatusResponse.self, from: #require(response.body))
  }

  @Test
  func asyncPullReturnsOperationStatusFromActionRoute() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let body = Data(#"{"reference":"registry.example.com/repo:tag","async":true}"#.utf8)

      let response = await server.handlePullImage(
        HTTPRequest(method: "POST", path: "/v1/images/pull", headers: [:], body: body, queryParameters: [:])
      )
      let decoded = try decodedImageOperationStatus(response)
      let operationId = decoded.operationId

      #expect(response.statusCode == 202)
      #expect(decoded.status == "started")
      #expect(decoded.type == "pull")
      #expect(decoded.image == nil)
      #expect(decoded.errorCode == nil)
      #expect(decoded.statusUrl == "/v1/images/pull/operations/\(operationId)")

      let statusResponse = await server.handleGetImagePullOperation(
        HTTPRequest(
          method: "GET",
          path: "/v1/images/pull/operations/\(operationId)",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )
      let status = try decodedImageOperationStatus(statusResponse)

      #expect(statusResponse.statusCode == 200)
      #expect(status.type == "pull")
      #expect(status.operationId == operationId)

      if ["started", "running"].contains(status.status) {
        _ = await server.handleCancelImagePullOperation(
          HTTPRequest(
            method: "DELETE",
            path: "/v1/images/pull/operations/\(operationId)",
            headers: [:],
            body: nil,
            queryParameters: [:]
          )
        )
      }
    }
  }

  @Test
  func imageOperationStatusAndTerminalCancellationUseOperationCollection() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let operation = await server.imageManager.startImageOperation(
        kind: .pull,
        reference: "registry.example.com/repo:tag"
      )

      let statusResponse = await server.handleGetImagePullOperation(
        HTTPRequest(
          method: "GET",
          path: "/v1/images/pull/operations/\(operation.id.uuidString)",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )
      let cancelResponse = await server.handleCancelImagePullOperation(
        HTTPRequest(
          method: "DELETE",
          path: "/v1/images/pull/operations/\(operation.id.uuidString)",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )
      let secondCancelResponse = await server.handleCancelImagePullOperation(
        HTTPRequest(
          method: "DELETE",
          path: "/v1/images/pull/operations/\(operation.id.uuidString)",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )

      let status = try decodedImageOperationStatus(statusResponse)
      let cancelStatus = try decodedImageOperationStatus(cancelResponse)
      let secondCancelError = try decodedError(secondCancelResponse)

      #expect(statusResponse.statusCode == 200)
      #expect(status.type == "pull")
      #expect(cancelResponse.statusCode == 200)
      #expect(cancelStatus.status == "cancelled")
      #expect(cancelStatus.errorCode == "IMAGE_PULL_CANCELLED")
      #expect(secondCancelResponse.statusCode == 409)
      #expect(secondCancelError.error.code == "IMAGE_OPERATION_NOT_RUNNING")
    }
  }

  @Test
  func asyncPullFormatFailureExposesStructuredErrorCode() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let operation = await server.imageManager.startImageOperation(
        kind: .pull,
        reference: "registry.example.com/repo:legacy"
      )
      await server.finishImageOperationTask(
        operation.id,
        result: .failure(ImageManagerError.unsupportedImageFormat("unversioned image"))
      )

      let response = await server.handleGetImagePullOperation(
        HTTPRequest(
          method: "GET",
          path: "/v1/images/pull/operations/\(operation.id.uuidString)",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )
      let status = try decodedImageOperationStatus(response)

      #expect(response.statusCode == 200)
      #expect(status.status == "failed")
      #expect(status.errorCode == "UNSUPPORTED_IMAGE_FORMAT")
      #expect(status.error?.contains("Unsupported image format") == true)
    }
  }

  @Test
  func asyncPullTimeoutExposesStructuredErrorCode() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let operation = await server.imageManager.startImageOperation(
        kind: .pull,
        reference: "registry.example.com/repo:slow"
      )
      await server.finishImageOperationTask(
        operation.id,
        result: .failure(ImageManagerError.timeout("manifest fetch exceeded its deadline"))
      )

      let response = await server.handleGetImagePullOperation(
        HTTPRequest(
          method: "GET",
          path: "/v1/images/pull/operations/\(operation.id.uuidString)",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )
      let status = try decodedImageOperationStatus(response)

      #expect(response.statusCode == 200)
      #expect(status.status == "failed")
      #expect(status.errorCode == "IMAGE_PULL_TIMEOUT")
    }
  }

  @Test
  func asyncPushFromVMReturnsOperationStatusAndCanBeCancelled() async throws {
    try await withTemporaryDirectory { root in
      let registryPort = try freeLocalTCPPort()
      let registryHost = "127.0.0.1:\(registryPort)"
      let registryServer = SimpleHTTPServer(port: registryPort, host: "127.0.0.1")
      registryServer.get("/v2/") { _ in HTTPResponse(statusCode: 200) }
      try registryServer.start()
      defer { registryServer.stop() }
      try await Task.sleep(nanoseconds: 50_000_000)

      let zstdPath = (root as NSString).appendingPathComponent("zstd")
      let pidPath = (root as NSString).appendingPathComponent("zstd.pid")
      let script = """
      #!/bin/sh
      echo "$$" > "\(pidPath)"
      sleep 30
      """
      try script.write(toFile: zstdPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zstdPath)

      let server = makeTestAPIServer(root: root) { config in
        config.images = ImageConfig(
          imageStorageDir: config.images.imageStorageDir,
          orasPath: "/usr/bin/false",
          zstdPath: zstdPath,
          defaultRegistry: nil,
          insecureRegistries: [registryHost]
        )
      }
      let definition = try await server.vmManager.createVM(name: "push-vm", resources: .default)
      try await prepareVMForImageExport(definition, server: server)
      let payloadPath = (definition.paths.bundlePath as NSString).appendingPathComponent("payload.bin")
      try Data(repeating: 0x7F, count: 1_048_576).write(to: URL(fileURLWithPath: payloadPath))
      let body = Data(
        #"{"source":"vm:\#(definition.id.uuidString)","reference":"\#(registryHost)/repo:tag","async":true}"#.utf8
      )

      let response = await server.handlePushImage(
        HTTPRequest(method: "POST", path: "/v1/images/push", headers: [:], body: body, queryParameters: [:])
      )
      let decoded = try decodedImageOperationStatus(response)
      let operationId = decoded.operationId

      #expect(response.statusCode == 202)
      #expect(decoded.status == "started")
      #expect(decoded.type == "push")
      #expect(decoded.image == nil)
      #expect(decoded.errorCode == nil)
      #expect(decoded.statusUrl == "/v1/images/push/operations/\(operationId)")

      let pid = try await waitForPid(atPath: pidPath)
      let cancelResponse = await server.handleCancelImagePushOperation(
        HTTPRequest(
          method: "DELETE",
          path: "/v1/images/push/operations/\(operationId)",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )
      let cancelStatus = try decodedImageOperationStatus(cancelResponse)

      #expect(cancelResponse.statusCode == 200)
      #expect(cancelStatus.status == "cancelled")
      #expect(cancelStatus.errorCode == "IMAGE_PUSH_CANCELLED")
      let processStopped = await waitUntilProcessStops(pid)
      #expect(processStopped)

      let operationUUID = try #require(UUID(uuidString: operationId))
      var finalStatus: ImageOperationStatus?
      for _ in 0 ..< 100 {
        if let status = await server.imageManager.getImageOperationStatus(operationUUID), status.state.isTerminal {
          finalStatus = status
          break
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
      }

      let terminalStatus = try #require(finalStatus)
      #expect(terminalStatus.state.isTerminal)
      #expect(terminalStatus.state != .completed)
      try await server.vmManager.deleteVM(definition.id)
    }
  }

  @Test
  func successfulAsyncPushRoutePublishesCompletedStatusAfterFinalizing() async throws {
    try await withTemporaryDirectory { root in
      let orasPath = "\(root)/oras"
      let zstdPath = "\(root)/zstd"
      try makeImageManagerFakePushOras(at: orasPath)
      try makeImageManagerFakeZstd(at: zstdPath)
      let server = makeTestAPIServer(root: root) { config in
        config.images = ImageConfig(
          imageStorageDir: config.images.imageStorageDir,
          orasPath: orasPath,
          zstdPath: zstdPath,
          defaultRegistry: nil,
          insecureRegistries: []
        )
      }
      let definition = try await server.vmManager.createVM(name: "completed-push-vm", resources: .default)
      try await prepareVMForImageExport(definition, server: server)
      let body = Data(
        #"{"source":"vm:\#(definition.id.uuidString)","reference":"registry.example.com/repo:done","async":true}"#.utf8
      )

      let acceptedResponse = await server.handlePushImage(
        HTTPRequest(method: "POST", path: "/v1/images/push", headers: [:], body: body, queryParameters: [:])
      )
      let accepted = try decodedImageOperationStatus(acceptedResponse)
      let operationId = try #require(UUID(uuidString: accepted.operationId))
      var terminalResponse: HTTPResponse?
      var terminalStatus: ImageOperationStatusResponse?
      for _ in 0 ..< 1000 {
        let response = await server.handleGetImagePushOperation(
          HTTPRequest(
            method: "GET",
            path: "/v1/images/push/operations/\(operationId.uuidString)",
            headers: [:],
            body: nil,
            queryParameters: [:]
          )
        )
        let status = try decodedImageOperationStatus(response)
        if ["completed", "failed", "cancelled"].contains(status.status) {
          terminalResponse = response
          terminalStatus = status
          break
        }
        try await Task.sleep(nanoseconds: 5_000_000)
      }

      let response = try #require(terminalResponse)
      let completed = try #require(terminalStatus)
      #expect(acceptedResponse.statusCode == 202)
      #expect(accepted.status == "started")
      #expect(response.statusCode == 200)
      #expect(completed.status == "completed")
      #expect(completed.stage == "finalizing")
      #expect(completed.stageProgress == 1)
      #expect(completed.progress == 1)
      #expect(completed.bytesCompleted == 0)
      #expect(completed.bytesTotal == nil)
      #expect(completed.averageSpeedMBps == nil)
      #expect(completed.image?.reference == "registry.example.com/repo:done")
      #expect(completed.image?.formatVersion == VMImagePackager.currentFormatVersion)
      #expect(server.cancelImageOperationTask(operationId) == false)
      try await server.vmManager.deleteVM(definition.id)
    }
  }

  @Test
  func asyncPushRecordsFailureWhenRegistryPreflightFails() async throws {
    try await withTemporaryDirectory { root in
      let registryPort = try freeLocalTCPPort()
      let registryHost = "127.0.0.1:\(registryPort)"
      let registryServer = SimpleHTTPServer(port: registryPort, host: "127.0.0.1")
      registryServer.get("/v2/") { _ in HTTPResponse(statusCode: 500) }
      try registryServer.start()
      defer { registryServer.stop() }
      try await Task.sleep(nanoseconds: 50_000_000)

      let server = makeTestAPIServer(
        root: root,
        configure: { config in
          config.images = ImageConfig(
            imageStorageDir: config.images.imageStorageDir,
            orasPath: "/usr/bin/false",
            defaultRegistry: nil,
            insecureRegistries: [registryHost]
          )
        },
        useLiveRegistryAvailabilityCheck: true
      )
      let definition = try await server.vmManager.createVM(name: "push-preflight-vm", resources: .default)
      try await prepareVMForImageExport(definition, server: server)
      let body = Data(
        #"{"source":"vm:\#(definition.id.uuidString)","reference":"\#(registryHost)/repo:tag","async":true}"#.utf8
      )

      let response = await server.handlePushImage(
        HTTPRequest(method: "POST", path: "/v1/images/push", headers: [:], body: body, queryParameters: [:])
      )
      let accepted = try decodedImageOperationStatus(response)
      let operationId = try #require(UUID(uuidString: accepted.operationId))
      var terminalStatus: ImageOperationStatus?
      for _ in 0 ..< 200 {
        if let status = await server.imageManager.getImageOperationStatus(operationId), status.state.isTerminal {
          terminalStatus = status
          break
        }
        try await Task.sleep(nanoseconds: 5_000_000)
      }
      let failed = try #require(terminalStatus)

      #expect(response.statusCode == 202)
      #expect(accepted.status == "started")
      #expect(failed.state == .failed)
      #expect(failed.errorCode == .imagePushRegistryUnavailable)
      #expect(failed.error?.contains("Registry") == true)
      try await server.vmManager.deleteVM(definition.id)
    }
  }

  @Test
  func blockingPushTimeoutIncludesVMSourceReservation() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let definition = try await server.vmManager.createVM(name: "push-timeout-vm", resources: .default)
      try await prepareVMForImageExport(definition, server: server)
      let claimEntered = AsyncTestSignal()
      let claimCancelled = AsyncTestSignal()
      let releaseClaim = AsyncTestSignal()
      await server.vmManager.setImageExportClaimHookForTesting {
        await claimEntered.signal()
        await withTaskCancellationHandler {
          await releaseClaim.wait()
        } onCancel: {
          Task<Void, Never> {
            await claimCancelled.signal()
          }
        }
      }
      let body = Data(
        #"{"source":"vm:\#(definition.id.uuidString)","reference":"registry.example.com/repo:tag","timeout":1}"#.utf8
      )

      let requestTask = Task {
        await server.handlePushImage(
          HTTPRequest(method: "POST", path: "/v1/images/push", headers: [:], body: body, queryParameters: [:])
        )
      }
      await claimEntered.wait()
      await claimCancelled.wait()
      await releaseClaim.signal()
      let response = await requestTask.value
      let error = try decodedError(response)

      #expect(response.statusCode == 504)
      #expect(error.error.code == "IMAGE_PUSH_FAILED")
      #expect(error.error.message.contains("timed out"))
      await server.vmManager.setImageExportClaimHookForTesting(nil)
      try await server.vmManager.deleteVM(definition.id)
    }
  }
}

private func prepareVMForImageExport(_ definition: VMDefinition, server: APIServer) async throws {
  for path in [
    definition.paths.diskImagePath,
    definition.paths.auxiliaryStoragePath,
    definition.paths.hardwareModelPath,
    definition.paths.machineIdentifierPath,
  ] {
    try Data([0x01]).write(to: URL(fileURLWithPath: path))
  }

  let instance = try await server.vmManager.getVMInstance(definition.id)
  let readyDefinition = await MainActor.run {
    instance.stateMachine.forceState(.stopped)
    instance.definition.updateState(.stopped)
    instance.definition.updateInstallation(.completed(message: "Test VM image is complete"))
    return instance.definition
  }
  try await server.vmManager.replaceDefinitionForTesting(definition.id, definition: readyDefinition)
}

private func waitForPid(atPath path: String) async throws -> pid_t {
  for _ in 0 ..< 1000 {
    if let text = try? String(contentsOfFile: path, encoding: .utf8),
       let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return pid
    }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
  Issue.record("Timed out waiting for pid file")
  throw CancellationError()
}

private func waitUntilProcessStops(_ pid: pid_t) async -> Bool {
  for _ in 0 ..< 1000 {
    if kill(pid, 0) == -1 {
      return true
    }
    try? await Task.sleep(nanoseconds: 5_000_000)
  }
  return false
}
