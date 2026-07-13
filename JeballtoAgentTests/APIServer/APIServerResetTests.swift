import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes), .serialized)
struct APIServerResetTests {
  @Test
  func cacheCleanupRemovesOnlyOwnedChildrenAndPreservesOverrideRootContents() throws {
    try withTemporaryDirectory(prefix: "reset-cache-root") { root in
      let cacheRoot = URL(fileURLWithPath: root, isDirectory: true)
      let ipsw = cacheRoot.appendingPathComponent("IPSWCache", isDirectory: true)
      let imageWork = cacheRoot.appendingPathComponent("ImageWork", isDirectory: true)
      let imageWorkSession = imageWork
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let sentinel = cacheRoot.appendingPathComponent("unrelated.txt")
      try FileManager.default.createDirectory(at: ipsw, withIntermediateDirectories: true)
      let sessionLock = try ImageWorkSessionLock(sessionURL: imageWorkSession)
      let workItem = imageWorkSession.appendingPathComponent("work")
      try Data("remove".utf8).write(to: workItem)
      try Data("keep".utf8).write(to: sentinel)
      var errors: [String] = []

      let ipswCleared = APIServer.clearOwnedCacheDirectories(
        root: cacheRoot,
        imageWorkSession: imageWorkSession,
        errors: &errors
      )

      #expect(ipswCleared)
      #expect(errors.isEmpty)
      #expect(FileManager.default.fileExists(atPath: ipsw.path) == false)
      #expect(FileManager.default.fileExists(atPath: workItem.path) == false)
      #expect(FileManager.default.fileExists(atPath: imageWorkSession.path))
      #expect(FileManager.default.fileExists(atPath: sentinel.path))
      #expect(FileManager.default.fileExists(atPath: cacheRoot.path))
      withExtendedLifetime(sessionLock) {}
    }
  }

  @Test
  func hardResetCleanupPreservesTheActiveInstanceLock() throws {
    try withTemporaryDirectory(prefix: "reset-app-support") { root in
      let lockPath = "\(root)/agent.lock"
      let dataPath = "\(root)/config.json"
      let lock = try SingleInstanceLock(path: lockPath)
      try Data("remove".utf8).write(to: URL(fileURLWithPath: dataPath))
      var errors: [String] = []

      APIServer.clearApplicationSupportContents(
        at: root,
        preserving: ["agent.lock"],
        errors: &errors
      )

      #expect(errors.isEmpty)
      #expect(FileManager.default.fileExists(atPath: dataPath) == false)
      #expect(FileManager.default.fileExists(atPath: lockPath))
      #expect(throws: SingleInstanceLockError.self) {
        _ = try SingleInstanceLock(path: lockPath)
      }
      lock.release()
    }
  }

  @Test
  func applicationSupportCleanupDoesNotTraverseSymbolicLink() throws {
    try withTemporaryDirectory(prefix: "reset-app-support-symlink") { root in
      let target = "\(root)/outside"
      let link = "\(root)/app-support"
      let sentinel = "\(target)/keep.txt"
      try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: URL(fileURLWithPath: sentinel))
      try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
      var errors: [String] = []

      APIServer.clearApplicationSupportContents(at: link, preserving: [], errors: &errors)

      #expect(FileManager.default.fileExists(atPath: sentinel))
      #expect(errors.contains { $0.contains("Refusing to traverse application support directory") })
    }
  }

  @Test
  func cacheCleanupDoesNotTraverseSymbolicRoot() throws {
    try withTemporaryDirectory(prefix: "reset-cache-symlink") { root in
      let target = "\(root)/outside"
      let cacheLink = "\(root)/cache"
      let ipsw = "\(target)/IPSWCache"
      let sentinel = "\(ipsw)/keep.ipsw"
      try FileManager.default.createDirectory(atPath: ipsw, withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: URL(fileURLWithPath: sentinel))
      try FileManager.default.createSymbolicLink(atPath: cacheLink, withDestinationPath: target)
      var errors: [String] = []

      let cleared = APIServer.clearOwnedCacheDirectories(
        root: URL(fileURLWithPath: cacheLink),
        imageWorkSession: URL(fileURLWithPath: "\(cacheLink)/ImageWork/sessions/owned"),
        errors: &errors
      )

      #expect(cleared == false)
      #expect(FileManager.default.fileExists(atPath: sentinel))
      #expect(errors.contains { $0.contains("Refusing to traverse cache root") })
    }
  }

  @Test
  func logCleanupDoesNotTraverseSymbolicDirectory() throws {
    try withTemporaryDirectory(prefix: "reset-logs-symlink") { root in
      let target = "\(root)/outside"
      let logLink = "\(root)/logs"
      let log = "\(target)/agent.log"
      try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: URL(fileURLWithPath: log))
      try FileManager.default.createSymbolicLink(atPath: logLink, withDestinationPath: target)
      var errors: [String] = []

      let cleared = APIServer.clearLogFiles(in: [logLink], errors: &errors)

      #expect(cleared == false)
      #expect(FileManager.default.fileExists(atPath: log))
      #expect(errors.contains { $0.contains("Refusing to traverse log directory") })
    }
  }

  @Test
  func logCleanupDoesNotTraverseSymbolicParentComponent() throws {
    try withTemporaryDirectory(prefix: "reset-logs-parent-symlink") { root in
      let outside = "\(root)/outside"
      let linkedParent = "\(root)/linked"
      let logs = "\(outside)/logs"
      let log = "\(logs)/agent.log"
      try FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: URL(fileURLWithPath: log))
      try FileManager.default.createSymbolicLink(atPath: linkedParent, withDestinationPath: outside)
      var errors: [String] = []

      let cleared = APIServer.clearLogFiles(in: ["\(linkedParent)/logs"], errors: &errors)

      #expect(cleared == false)
      #expect(FileManager.default.fileExists(atPath: log))
      #expect(errors.contains { $0.contains("path contains a symbolic link") })
    }
  }

  @Test
  func logCleanupDoesNotRecursivelyDeleteMatchingDirectory() throws {
    try withTemporaryDirectory(prefix: "reset-log-directory") { root in
      let matchingDirectory = "\(root)/agent-2026-01-01.log"
      let sentinel = "\(matchingDirectory)/keep"
      try FileManager.default.createDirectory(atPath: matchingDirectory, withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: URL(fileURLWithPath: sentinel))
      var errors: [String] = []

      let cleared = APIServer.clearLogFiles(in: [root], errors: &errors)

      #expect(cleared == false)
      #expect(FileManager.default.fileExists(atPath: sentinel))
      #expect(errors.contains { $0.contains("unsafe log entry") })
    }
  }

  @Test
  func logCleanupPreservesUnrelatedAgentPrefixedFiles() throws {
    try withTemporaryDirectory(prefix: "reset-unrelated-log") { root in
      let unrelated = "\(root)/agent-private.log"
      let generated = "\(root)/agent-2026-01-01.log"
      try Data("keep".utf8).write(to: URL(fileURLWithPath: unrelated))
      try Data("delete".utf8).write(to: URL(fileURLWithPath: generated))
      var errors: [String] = []

      let cleared = APIServer.clearLogFiles(in: [root], errors: &errors)

      #expect(cleared)
      #expect(errors.isEmpty)
      #expect(FileManager.default.fileExists(atPath: unrelated))
      #expect(FileManager.default.fileExists(atPath: generated) == false)
    }
  }

  @Test
  func hardResetPreservesIndexesAndKeepsRunningWhenAResourceCannotBeDeleted() async throws {
    try await withTemporaryDirectory(prefix: "reset-failure") { root in
      let server = makeTestAPIServer(root: root)
      let configPath = "\(root)/config.json"
      try Data("keep config".utf8).write(to: URL(fileURLWithPath: configPath))
      let definition = try await server.vmManager.createVM(name: "unsafe", resources: .default)
      let outside = "\(root)/outside.bundle"
      let sentinel = "\(outside)/keep"
      try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: URL(fileURLWithPath: sentinel))
      try FileManager.default.removeItem(atPath: definition.paths.bundlePath)
      try FileManager.default.createSymbolicLink(
        atPath: definition.paths.bundlePath,
        withDestinationPath: outside
      )

      let response = await server.handleSystemReset(HTTPRequest(
        method: "POST",
        path: "/v1/system/reset",
        headers: ["content-type": "application/json"],
        body: Data(#"{"mode":"hard"}"#.utf8),
        queryParameters: ["confirm": "true"]
      ))
      let body = try JSONDecoder().decode(SystemResetResponse.self, from: #require(response.body))

      #expect(response.statusCode == 500)
      #expect(body.vmsFailed == 1)
      #expect(body.configDeleted == false)
      #expect(body.willTerminate == false)
      #expect(FileManager.default.fileExists(atPath: configPath))
      #expect(FileManager.default.fileExists(atPath: sentinel))
      #expect(try await server.vmManager.vmExists(definition.id))
    }
  }

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

  @Test
  func deletingACancelledJeballtofileWaitsForItsTaskToFinish() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let createResponse = await server.handleCreateJeballtofile(
        HTTPRequest(
          method: "POST",
          path: "/v1/jeballtofiles",
          headers: ["content-type": "application/json"],
          body: Data(#"{"name":"delete-blueprint","steps":[{"type":"wait","seconds":5}]}"#.utf8),
          queryParameters: [:]
        )
      )
      let created = try JSONDecoder().decode(JeballtofileResponse.self, from: #require(createResponse.body))
      let executionId = try #require(UUID(uuidString: created.id))
      let executor = try #require(server.getJeballtofileExecutor(executionId))
      _ = await waitUntil { executor.execution.stepResults.first?.status == .inProgress }

      let cancelResponse = await server.handleCancelJeballtofile(HTTPRequest(
        method: "POST",
        path: "/v1/jeballtofiles/\(executionId.uuidString)/cancel",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))
      let deleteResponse = await server.handleDeleteJeballtofile(HTTPRequest(
        method: "DELETE",
        path: "/v1/jeballtofiles/\(executionId.uuidString)",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))

      #expect(cancelResponse.statusCode == 200)
      #expect(deleteResponse.statusCode == 200)
      #expect(executor.isFinished)
      #expect(server.getJeballtofileExecutor(executionId) == nil)
    }
  }
}
