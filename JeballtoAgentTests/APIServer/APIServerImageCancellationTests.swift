import Darwin
import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes), .serialized)
struct APIServerImageCancellationTests {
  @Test
  func cancellingBlockingPullTerminatesRegisteredOrasProcess() async throws {
    try await withTemporaryDirectory(prefix: "api-blocking-image-cancel") { root in
      let orasPath = (root as NSString).appendingPathComponent("oras")
      let pidPath = (root as NSString).appendingPathComponent("oras.pid")
      let script = """
      #!/bin/sh
      echo "$$" > "\(pidPath)"
      sleep 30
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)

      let server = makeTestAPIServer(root: root) { config in
        config.images = ImageConfig(
          imageStorageDir: config.images.imageStorageDir,
          orasPath: orasPath,
          defaultRegistry: nil,
          insecureRegistries: []
        )
      }
      let body = Data(#"{"reference":"registry.example.com/repo:tag"}"#.utf8)
      let requestTask = Task {
        await server.handlePullImage(
          HTTPRequest(method: "POST", path: "/v1/images/pull", headers: [:], body: body, queryParameters: [:])
        )
      }

      let pid = try await waitForPid(atPath: pidPath)
      let operations = await server.imageManager.listImageOperationStatuses(kind: .pull, activeOnly: true)
      let operation = try #require(operations.first)
      let cancelResponse = await server.handleCancelImagePullOperation(HTTPRequest(
        method: "DELETE",
        path: "/v1/images/pull/operations/\(operation.id.uuidString)",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))
      let blockingResponse = await requestTask.value

      #expect(cancelResponse.statusCode == 200)
      #expect(blockingResponse.statusCode == 499)
      try await waitUntilProcessStops(pid)
    }
  }

  @Test
  func cancellingAsyncPullTerminatesOrasProcess() async throws {
    try await withTemporaryDirectory(prefix: "api-image-cancel") { root in
      let orasPath = (root as NSString).appendingPathComponent("oras")
      let pidPath = (root as NSString).appendingPathComponent("oras.pid")
      let script = """
      #!/bin/sh
      echo "$$" > "\(pidPath)"
      sleep 30
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)

      let server = makeTestAPIServer(root: root) { config in
        config.images = ImageConfig(
          imageStorageDir: config.images.imageStorageDir,
          orasPath: orasPath,
          defaultRegistry: nil,
          insecureRegistries: []
        )
      }
      let body = Data(#"{"reference":"registry.example.com/repo:tag","async":true}"#.utf8)

      let response = await server.handlePullImage(
        HTTPRequest(method: "POST", path: "/v1/images/pull", headers: [:], body: body, queryParameters: [:])
      )
      #expect(response.statusCode == 202)
      let decoded = try JSONDecoder().decode(ImageOperationStatusResponse.self, from: #require(response.body))
      let operationId = decoded.operationId
      #expect(decoded.statusUrl == "/v1/images/pull/operations/\(operationId)")

      let pid = try await waitForPid(atPath: pidPath)
      let cancelResponse = await server.handleCancelImagePullOperation(HTTPRequest(
        method: "DELETE",
        path: "/v1/images/pull/operations/\(operationId)",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))
      #expect(cancelResponse.statusCode == 200)
      let cancelStatus = try JSONDecoder().decode(
        ImageOperationStatusResponse.self,
        from: #require(cancelResponse.body)
      )
      #expect(cancelStatus.status == "cancelled")

      try await waitUntilProcessStops(pid)
    }
  }

  @Test
  func softResetCancelsImplicitPullStartedByVMCreation() async throws {
    try await withTemporaryDirectory(prefix: "api-create-vm-image-cancel") { root in
      let orasPath = (root as NSString).appendingPathComponent("oras")
      let pidPath = (root as NSString).appendingPathComponent("oras.pid")
      let script = """
      #!/bin/sh
      echo "$$" > "\(pidPath)"
      sleep 30
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)
      let server = makeTestAPIServer(root: root) { config in
        config.images = ImageConfig(
          imageStorageDir: config.images.imageStorageDir,
          orasPath: orasPath,
          defaultRegistry: nil,
          insecureRegistries: []
        )
      }
      let createTask = Task {
        await server.handleCreateVM(HTTPRequest(
          method: "POST",
          path: "/v1/vms",
          headers: ["content-type": "application/json"],
          body: Data(#"{"name":"from-image","image":"registry.example.com/repo:tag"}"#.utf8),
          queryParameters: [:]
        ))
      }

      let pid = try await waitForPid(atPath: pidPath)
      let resetResponse = await server.handleSystemReset(HTTPRequest(
        method: "POST",
        path: "/v1/system/reset",
        headers: ["content-type": "application/json"],
        body: Data(#"{"mode":"soft"}"#.utf8),
        queryParameters: ["confirm": "true"]
      ))
      let createResponse = await createTask.value

      #expect(resetResponse.statusCode == 200)
      #expect(createResponse.statusCode == 499)
      let operations = await server.imageManager.listImageOperationStatuses(kind: .pull, activeOnly: false)
      #expect(operations.count == 1)
      #expect(operations.first?.state == .cancelled)
      try await waitUntilProcessStops(pid)
    }
  }

  @Test
  func stoppingServerCancelsBlockingImageRouteBeforeDrainingHandlers() async throws {
    try await withTemporaryDirectory(prefix: "api-image-stop-cancel") { root in
      let orasPath = (root as NSString).appendingPathComponent("oras")
      let pidPath = (root as NSString).appendingPathComponent("oras.pid")
      let script = """
      #!/bin/sh
      echo "$$" > "\(pidPath)"
      sleep 30
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)

      let server = makeTestAPIServer(root: root) { config in
        config.images = ImageConfig(
          imageStorageDir: config.images.imageStorageDir,
          orasPath: orasPath,
          defaultRegistry: nil,
          insecureRegistries: []
        )
      }
      let body = Data(#"{"reference":"registry.example.com/repo:tag"}"#.utf8)
      let requestTask = Task {
        await server.handlePullImage(
          HTTPRequest(method: "POST", path: "/v1/images/pull", headers: [:], body: body, queryParameters: [:])
        )
      }

      let pid = try await waitForPid(atPath: pidPath)
      await server.stop()
      let response = await requestTask.value

      #expect(response.statusCode == 499)
      try await waitUntilProcessStops(pid)
    }
  }

  @Test
  func wipingVMsCancelsOrphanImageOperations() async throws {
    try await withTemporaryDirectory(prefix: "api-image-wipe-cancel") { root in
      let server = makeTestAPIServer(root: root)
      let operation = await server.imageManager.startImageOperation(
        kind: .push,
        reference: "registry.example.com/repo:tag",
        source: "vm:\(UUID().uuidString)"
      )

      let response = await server.handleWipeAllVMs(HTTPRequest(
        method: "DELETE",
        path: "/v1/vms",
        headers: [:],
        body: nil,
        queryParameters: ["confirm": "true"]
      ))
      let status = try #require(await server.imageManager.getImageOperationStatus(operation.id))

      #expect(response.statusCode == 200)
      #expect(status.state == .cancelled)
      #expect(status.completedAt != nil)
    }
  }
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

private func waitUntilProcessStops(_ pid: pid_t) async throws {
  for _ in 0 ..< 1000 {
    if kill(pid, 0) == -1 {
      return
    }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
  Issue.record("Process \(pid) was still running")
}
