import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes), .serialized)
struct APIServerResetTests {
  @Test
  func softSystemResetClearsJeballtofileExecutions() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let createBody = Data(#"{"name":"reset-blueprint","steps":[{"type":"wait","seconds":5}]}"#.utf8)
      let createResponse = await server.handleCreateJeballtofile(
        HTTPRequest(
          method: "POST",
          path: "/v1/jeballtofiles",
          headers: ["content-type": "application/json"],
          body: createBody,
          queryParameters: [:]
        )
      )
      let created = try JSONDecoder().decode(JeballtofileResponse.self, from: #require(createResponse.body))
      let executionId = try #require(UUID(uuidString: created.id))
      let stepStarted = await waitUntil {
        server.getJeballtofileExecutor(executionId)?.execution.stepResults.first?.status == .inProgress
      }
      #expect(stepStarted)

      let resetResponse = await server.handleSystemReset(
        HTTPRequest(
          method: "POST",
          path: "/v1/system/reset",
          headers: [:],
          body: Data(#"{"mode":"soft"}"#.utf8),
          queryParameters: ["confirm": "true"]
        )
      )
      let listResponse = await server.handleListJeballtofiles(
        HTTPRequest(method: "GET", path: "/v1/jeballtofiles", headers: [:], body: nil, queryParameters: [:])
      )
      let list = try JSONDecoder().decode(JeballtofileListResponse.self, from: #require(listResponse.body))

      #expect(resetResponse.statusCode == 200)
      #expect(server.getJeballtofileExecutor(executionId) == nil)
      #expect(list.total == 0)
      #expect(list.executions.isEmpty)
    }
  }
}
