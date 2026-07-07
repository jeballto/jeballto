import Darwin
import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes), .serialized)
struct APIServerImageCancellationTests {
  @Test
  func cancellingAsyncPullTerminatesOrasProcess() async throws {
    try await withTemporaryDirectory { root in
      let orasPath = "\(root)/oras"
      let pidPath = "\(root)/oras.pid"
      let script = """
      #!/bin/sh
      echo $$ > "\(pidPath)"
      sleep 30
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)

      let server = makeTestAPIServer(root: root) { config in
        config.images.orasPath = orasPath
      }
      let body = Data(#"{"reference":"registry.example.com/repo:tag","async":true}"#.utf8)

      let response = await server.handlePullImage(
        HTTPRequest(method: "POST", path: "/v1/images/pull", headers: [:], body: body, queryParameters: [:])
      )
      let decoded = try JSONDecoder().decode(ImagePullResponse.self, from: #require(response.body))
      let operationId = try #require(decoded.operationId)
      let processStarted = await waitUntil(timeout: 5.0) {
        FileManager.default.fileExists(atPath: pidPath)
      }
      try #require(processStarted)

      let cancelResponse = await server.handleCancelImagePull(
        HTTPRequest(
          method: "DELETE",
          path: "/v1/images/pull/\(operationId)",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )
      let cancelStatus = try JSONDecoder().decode(ImageOperationStatusResponse.self, from: #require(cancelResponse.body))
      let pidText = try String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
      let pid = try #require(Int32(pidText))

      #expect(cancelResponse.statusCode == 200)
      #expect(cancelStatus.status == "cancelled")
      let processStopped = await waitUntil {
        kill(pid, 0) == -1
      }
      #expect(processStopped)
    }
  }
}
