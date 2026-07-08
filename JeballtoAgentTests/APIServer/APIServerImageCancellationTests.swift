import Darwin
import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes), .serialized)
struct APIServerImageCancellationTests {
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
      let cancelStatus = try JSONDecoder().decode(ImageOperationStatusResponse.self, from: #require(cancelResponse.body))
      #expect(cancelStatus.status == "cancelled")

      try await waitUntilProcessStops(pid)
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

private func waitUntilProcessStops(_ pid: pid_t) async throws {
  for _ in 0 ..< 200 {
    if kill(pid, 0) == -1 {
      return
    }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
  Issue.record("Process \(pid) was still running")
}
