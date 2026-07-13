import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes), .serialized)
struct APIServerHardResetTests {
  @Test
  func successfulHardResetDeletesSecretsAndTerminatesOnlyAfterSend() async throws {
    try await withTemporaryDirectory(prefix: "hard-reset-success") { root in
      let probe = HardResetProbe()
      let environment = makeHardResetEnvironment(root: root, probe: probe)
      let server = makeTestAPIServer(root: root, systemResetEnvironment: environment)
      try prepareHardResetFiles(root: root)

      let response = await server.handleSystemReset(hardResetRequest())
      let body = try JSONDecoder().decode(SystemResetResponse.self, from: #require(response.body))

      #expect(response.statusCode == 200)
      #expect(body.willTerminate)
      #expect(body.errors == nil)
      #expect(probe.events == ["deleteSecrets"])
      #expect(FileManager.default.fileExists(atPath: "\(root)/config.json") == false)
      #expect(FileManager.default.fileExists(atPath: "\(root)/app-support/state") == false)
      #expect(FileManager.default.fileExists(atPath: "\(root)/cache/IPSWCache") == false)
      #expect(FileManager.default.fileExists(atPath: "\(root)/logs/agent-2026-01-01.log") == false)

      response.runAfterSendAction()
      #expect(probe.events == ["deleteSecrets", "terminate"])
    }
  }

  @Test
  func lateCleanupFailureDoesNotDeleteSecretsOrTerminate() async throws {
    try await withTemporaryDirectory(prefix: "hard-reset-cleanup-failure") { root in
      let probe = HardResetProbe()
      let environment = makeHardResetEnvironment(root: root, probe: probe)
      let server = makeTestAPIServer(root: root, systemResetEnvironment: environment)
      try prepareHardResetFiles(root: root)
      let unsafeLogDirectory = "\(root)/logs/agent-2026-01-02.log"
      try FileManager.default.createDirectory(atPath: unsafeLogDirectory, withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: URL(fileURLWithPath: "\(unsafeLogDirectory)/sentinel"))

      let response = await server.handleSystemReset(hardResetRequest())
      let body = try JSONDecoder().decode(SystemResetResponse.self, from: #require(response.body))

      #expect(response.statusCode == 500)
      #expect(body.willTerminate == false)
      #expect(body.errors?.contains { $0.contains("unsafe log entry") } == true)
      #expect(probe.events.isEmpty)
      #expect(FileManager.default.fileExists(atPath: "\(unsafeLogDirectory)/sentinel"))

      response.runAfterSendAction()
      #expect(probe.events.isEmpty)
    }
  }

  @Test
  func secretDeletionFailureKeepsAgentRunning() async throws {
    try await withTemporaryDirectory(prefix: "hard-reset-secret-failure") { root in
      let probe = HardResetProbe()
      let environment = makeHardResetEnvironment(root: root, probe: probe, failSecretDeletion: true)
      let server = makeTestAPIServer(root: root, systemResetEnvironment: environment)
      try prepareHardResetFiles(root: root)

      let response = await server.handleSystemReset(hardResetRequest())
      let body = try JSONDecoder().decode(SystemResetResponse.self, from: #require(response.body))

      #expect(response.statusCode == 500)
      #expect(body.willTerminate == false)
      #expect(body.errors?.contains { $0.contains("Failed to delete credentials from Keychain") } == true)
      #expect(probe.events == ["deleteSecrets"])

      response.runAfterSendAction()
      #expect(probe.events == ["deleteSecrets"])
    }
  }
}

private enum HardResetTestError: Error {
  case secretDeletionFailed
}

private final class HardResetProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedEvents: [String] = []

  var events: [String] {
    lock.withLock { recordedEvents }
  }

  func record(_ event: String) {
    lock.withLock { recordedEvents.append(event) }
  }
}

private func makeHardResetEnvironment(
  root: String,
  probe: HardResetProbe,
  failSecretDeletion: Bool = false
) -> SystemResetEnvironment {
  SystemResetEnvironment(
    appSupportDirectory: "\(root)/app-support",
    defaultLogDirectory: "\(root)/default-logs",
    cacheRoot: URL(fileURLWithPath: "\(root)/cache", isDirectory: true),
    deleteSecrets: {
      probe.record("deleteSecrets")
      if failSecretDeletion {
        throw HardResetTestError.secretDeletionFailed
      }
    },
    terminate: {
      probe.record("terminate")
    }
  )
}

private func prepareHardResetFiles(root: String) throws {
  let directories = [
    "\(root)/app-support",
    "\(root)/cache/IPSWCache",
    "\(root)/cache/ImageWork",
    "\(root)/logs",
    "\(root)/default-logs",
  ]
  for directory in directories {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  }
  try Data("config".utf8).write(to: URL(fileURLWithPath: "\(root)/config.json"))
  try Data("state".utf8).write(to: URL(fileURLWithPath: "\(root)/app-support/state"))
  try Data("ipsw".utf8).write(to: URL(fileURLWithPath: "\(root)/cache/IPSWCache/image.ipsw"))
  try Data("work".utf8).write(to: URL(fileURLWithPath: "\(root)/cache/ImageWork/work"))
  try Data("log".utf8).write(to: URL(fileURLWithPath: "\(root)/logs/agent-2026-01-01.log"))
  try Data("log".utf8).write(to: URL(fileURLWithPath: "\(root)/default-logs/agent-2026-01-01.log"))
}

private func hardResetRequest() -> HTTPRequest {
  HTTPRequest(
    method: "POST",
    path: "/v1/system/reset",
    headers: ["content-type": "application/json"],
    body: Data(#"{"mode":"hard"}"#.utf8),
    queryParameters: ["confirm": "true"]
  )
}
