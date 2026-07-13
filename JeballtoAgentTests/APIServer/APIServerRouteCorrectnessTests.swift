import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes), .serialized)
struct APIServerRouteCorrectnessTests {
  @Test
  func installStatusWithoutInstallationHistoryUsesDocumentedNotStartedValue() {
    #expect(InstallStatusResponse.wireStatus(for: nil) == "not_started")
    #expect(InstallStatusResponse.wireStatus(for: .completed(message: "Imported")) == "completed")
  }

  private func decodedError(_ response: HTTPResponse) throws -> ErrorResponse {
    try JSONDecoder().decode(ErrorResponse.self, from: #require(response.body))
  }

  @Test
  func networkingStatusRoutesDistinguishPersistenceFailureFromMissingVM() async throws {
    try await withTemporaryDirectory { root in
      try Data("{".utf8).write(to: URL(fileURLWithPath: "\(root)/vms.json"))
      let server = makeTestAPIServer(root: root)
      let vmId = UUID()

      let sshResponse = await server.handleGetSSH(
        HTTPRequest(
          method: "GET",
          path: "/v1/vms/\(vmId.uuidString)/ssh",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )
      let vncResponse = await server.handleGetVNC(
        HTTPRequest(
          method: "GET",
          path: "/v1/vms/\(vmId.uuidString)/vnc",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )

      let sshError = try decodedError(sshResponse)
      let vncError = try decodedError(vncResponse)
      #expect(sshResponse.statusCode == 500)
      #expect(sshError.error.code == "SSH_STATUS_FAILED")
      #expect(vncResponse.statusCode == 500)
      #expect(vncError.error.code == "VNC_STATUS_FAILED")
    }
  }

  @Test
  func networkingStatusRoutesStillReturnNotFoundForMissingVM() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let vmId = UUID()

      let sshResponse = await server.handleGetSSH(
        HTTPRequest(
          method: "GET",
          path: "/v1/vms/\(vmId.uuidString)/ssh",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )
      let vncResponse = await server.handleGetVNC(
        HTTPRequest(
          method: "GET",
          path: "/v1/vms/\(vmId.uuidString)/vnc",
          headers: [:],
          body: nil,
          queryParameters: [:]
        )
      )

      let sshError = try decodedError(sshResponse)
      let vncError = try decodedError(vncResponse)
      #expect(sshResponse.statusCode == 404)
      #expect(sshError.error.code == "NOT_FOUND")
      #expect(vncResponse.statusCode == 404)
      #expect(vncError.error.code == "NOT_FOUND")
    }
  }

  @Test
  func disablingSSHWaitsForAutomaticNetworkingBeforeClearingFinalPort() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let definition = try await server.vmManager.createVM(name: "disable-ssh", resources: .default)
      let instance = try await server.vmManager.getVMInstance(definition.id)
      await MainActor.run {
        instance.stateMachine.forceState(.running)
        instance.definition.updateState(.running)
      }

      let networkingTask = Task<Void, Never> {
        while Task.isCancelled == false {
          await Task.yield()
        }
        try? await server.vmManager.setSSHPort(2222, for: definition.id)
      }
      await server.vmManager.setNetworkingTaskForTesting(networkingTask, vmId: definition.id)
      let watchdog = Task<Void, Never> {
        try? await Task.sleep(for: .milliseconds(500))
        networkingTask.cancel()
      }

      let response = await server.handleDisableSSH(HTTPRequest(
        method: "DELETE",
        path: "/v1/vms/\(definition.id.uuidString)/ssh",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))
      _ = await networkingTask.value
      watchdog.cancel()
      let finalDefinition = try await server.vmManager.getVM(definition.id)

      #expect(response.statusCode == 200)
      #expect(finalDefinition.network.sshPort == nil)
    }
  }

  @Test
  func lifecycleStateConflictsReturn409InsteadOfInternalErrors() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let definition = try await server.vmManager.createVM(name: "created-vm", resources: .default)
      let stopRequest = HTTPRequest(
        method: "POST",
        path: "/v1/vms/\(definition.id.uuidString)/stop",
        headers: [:],
        body: nil,
        queryParameters: [:]
      )
      let pauseRequest = HTTPRequest(
        method: "POST",
        path: "/v1/vms/\(definition.id.uuidString)/pause",
        headers: [:],
        body: nil,
        queryParameters: [:]
      )

      let stopResponse = await server.handleStopVM(stopRequest)
      let pauseResponse = await server.handlePauseVM(pauseRequest)

      #expect(stopResponse.statusCode == 409)
      #expect(try decodedError(stopResponse).error.code == "INVALID_STATE")
      #expect(pauseResponse.statusCode == 409)
      #expect(try decodedError(pauseResponse).error.code == "INVALID_STATE")
    }
  }

  @Test
  func clonePartialResourceOverridePreservesUnspecifiedSourceResources() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      var source = try await server.vmManager.createVM(
        name: "source",
        resources: VMResources(
          cpuCount: 4,
          memorySize: 16 * 1024 * 1024 * 1024,
          diskSize: 256 * 1024 * 1024 * 1024
        )
      )
      for path in [
        source.paths.diskImagePath,
        source.paths.auxiliaryStoragePath,
        source.paths.hardwareModelPath,
        source.paths.machineIdentifierPath,
      ] {
        try Data([0x01]).write(to: URL(fileURLWithPath: path))
      }
      source.updateState(.stopped)
      try await server.vmManager.replaceDefinitionForTesting(source.id, definition: source)

      let response = await server.handleCloneVM(HTTPRequest(
        method: "POST",
        path: "/v1/vms/\(source.id.uuidString)/clone",
        headers: ["content-type": "application/json"],
        body: Data(#"{"name":"clone","resources":{"cpuCount":6}}"#.utf8),
        queryParameters: [:]
      ))
      try #require(
        response.statusCode == 201,
        "Unexpected response: \(String(decoding: response.body ?? Data(), as: UTF8.self))"
      )
      let clone = try JSONDecoder().decode(VMResponse.self, from: #require(response.body))

      #expect(clone.resources.cpuCount == 6)
      #expect(clone.resources.memorySize == 16 * 1024 * 1024 * 1024)
      #expect(clone.resources.diskSize == 256 * 1024 * 1024 * 1024)
    }
  }

  @Test
  func stoppingEphemeralVMReturnsStableSnapshotBeforeAutomaticDeletion() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      var definition = try await server.vmManager.createVM(
        name: "ephemeral",
        resources: .default,
        ephemeral: true
      )
      definition.markBooted()
      definition.updateState(.stopped)
      try await server.vmManager.replaceDefinitionForTesting(definition.id, definition: definition)
      let vmId = definition.id

      let response = await server.handleStopVM(HTTPRequest(
        method: "POST",
        path: "/v1/vms/\(vmId.uuidString)/stop",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))
      try #require(
        response.statusCode == 200,
        "Unexpected response: \(String(decoding: response.body ?? Data(), as: UTF8.self))"
      )
      let snapshot = try JSONDecoder().decode(VMResponse.self, from: #require(response.body))
      let deleted = await waitUntilAsync {
        await (try? server.vmManager.vmExists(vmId)) == false
      }

      #expect(snapshot.id == vmId.uuidString)
      #expect(snapshot.state == "stopped")
      #expect(deleted)
    }
  }

  @Test
  func deletedVMEventHistoryRemainsQueryable() async throws {
    try await withTemporaryDirectory { root in
      let server = makeTestAPIServer(root: root)
      let definition = try await server.vmManager.createVM(name: "deleted", resources: .default)
      try await server.vmManager.deleteVM(definition.id)
      await server.eventBus.waitUntilIdle()

      let response = await server.handleGetEvents(HTTPRequest(
        method: "GET",
        path: "/v1/vms/\(definition.id.uuidString)/events",
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))
      let events = try JSONDecoder().decode(EventListResponse.self, from: #require(response.body))

      #expect(response.statusCode == 200)
      #expect(events.events.contains { $0.type == "VM_DELETED" })
    }
  }

  @Test
  func jeballtofileYAMLContentTypeIsCaseInsensitiveAndAcceptsParameters() async throws {
    try await withTemporaryDirectory { root in
      let capabilities = VirtualizationCapabilities(
        probe: VirtualizationHostProbe(
          architecture: "arm64",
          operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0),
          virtualizationSupported: true,
          entitlements: ["com.apple.security.virtualization"]
        ),
        featureFlags: VirtualizationFeatureFlags(overrides: [.jeballtofileExecution: false])
      )
      let server = makeTestAPIServer(root: root, capabilityProvider: { capabilities })
      let yaml = Data("name: workflow\nsteps:\n  - type: wait\n    seconds: 1\n".utf8)

      for contentType in [
        "Application/YAML; Charset=UTF-8",
        "TEXT/YAML ; charset=utf-8",
        "application/X-YAML; charset=\"utf-8\"",
      ] {
        let response = await server.handleCreateJeballtofile(
          HTTPRequest(
            method: "POST",
            path: "/v1/jeballtofiles",
            headers: ["content-type": contentType],
            body: yaml,
            queryParameters: [:]
          )
        )
        let error = try decodedError(response)

        #expect(response.statusCode == 409)
        #expect(error.error.code == "CAPABILITY_UNAVAILABLE")
      }
    }
  }

  @Test
  func malformedBodiesRemainBadRequestsWhenHostCapabilitiesAreDisabled() async throws {
    try await withTemporaryDirectory { root in
      let capabilities = VirtualizationCapabilities(
        probe: VirtualizationHostProbe(
          architecture: "arm64",
          operatingSystemVersion: OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0),
          virtualizationSupported: true,
          entitlements: ["com.apple.security.virtualization"]
        ),
        featureFlags: VirtualizationFeatureFlags(overrides: [
          .commandExecution: false,
          .keystrokeInjection: false,
          .macOSInstallation: false,
          .ociImagePackaging: false,
        ])
      )
      let server = makeTestAPIServer(root: root, capabilityProvider: { capabilities })
      let vmId = UUID().uuidString
      let malformed = Data("{".utf8)
      let requests: [HTTPResponse] = await [
        server.handleExecuteCommand(HTTPRequest(
          method: "POST",
          path: "/v1/vms/\(vmId)/execute",
          headers: [:],
          body: malformed,
          queryParameters: [:]
        )),
        server.handleKeystrokes(HTTPRequest(
          method: "POST",
          path: "/v1/vms/\(vmId)/keystrokes",
          headers: [:],
          body: malformed,
          queryParameters: [:]
        )),
        server.handleInstallVM(HTTPRequest(
          method: "POST",
          path: "/v1/vms/\(vmId)/install",
          headers: [:],
          body: malformed,
          queryParameters: [:]
        )),
        server.handlePullImage(HTTPRequest(
          method: "POST",
          path: "/v1/images/pull",
          headers: [:],
          body: malformed,
          queryParameters: [:]
        )),
        server.handlePushImage(HTTPRequest(
          method: "POST",
          path: "/v1/images/push",
          headers: [:],
          body: malformed,
          queryParameters: [:]
        )),
      ]

      for response in requests {
        let error = try decodedError(response)
        #expect(response.statusCode == 400)
        #expect(error.error.code == "INVALID_REQUEST")
      }
    }
  }
}
