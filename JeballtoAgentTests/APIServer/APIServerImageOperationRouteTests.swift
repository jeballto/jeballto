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
      #expect(secondCancelResponse.statusCode == 409)
      #expect(secondCancelError.error.code == "IMAGE_OPERATION_NOT_RUNNING")
    }
  }

  @Test
  func asyncPushFromVMReturnsOperationStatusAndCanBeCancelled() async throws {
    try await withTemporaryDirectory { root in
      let registryPort = UInt16.random(in: 28000 ... 30000)
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
}

private func waitForPid(atPath path: String) async throws -> pid_t {
  for _ in 0 ..< 200 {
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
  for _ in 0 ..< 200 {
    if kill(pid, 0) == -1 {
      return true
    }
    try? await Task.sleep(nanoseconds: 5_000_000)
  }
  return false
}
