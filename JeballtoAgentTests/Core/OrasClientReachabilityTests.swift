import CryptoKit
import Darwin
import Foundation
import Testing
@testable import JeballtoAgent

// MARK: - URLProtocol stub for OrasClient reachability tests

private class StubURLProtocol: URLProtocol {
  typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

  nonisolated(unsafe) static var handler: Handler?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let request = request
    guard let handler = Self.handler else {
      client?.urlProtocol(self, didFailWithError: URLError(.unknown))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      DispatchQueue.global().async { [weak self] in
        guard let self else { return }
        client?.urlProtocol(self, didFailWithError: error)
      }
    }
  }

  override func stopLoading() {}
}

private actor StubURLProtocolGate {
  static let shared = StubURLProtocolGate()

  func run(
    handler: @escaping StubURLProtocol.Handler,
    operation: @Sendable () async throws -> Void
  ) async rethrows {
    StubURLProtocol.handler = handler
    defer { StubURLProtocol.handler = nil }
    try await operation()
  }
}

private final class CapturedURLBox: @unchecked Sendable {
  private let lock = NSLock()
  private var value: URL?

  func set(_ url: URL?) {
    lock.lock()
    defer { lock.unlock() }
    value = url
  }

  func get() -> URL? {
    lock.lock()
    defer { lock.unlock() }
    return value
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

private func makeStubSession() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [StubURLProtocol.self]
  config.timeoutIntervalForRequest = 1
  config.timeoutIntervalForResource = 1
  return URLSession(configuration: config)
}

private func makeOrasClient(
  root: String = NSTemporaryDirectory(),
  orasPath: String? = nil,
  temporaryRoot: URL? = nil,
  credentialStore: RegistryCredentialStore = makeTestRegistryCredentialStore()
) -> OrasClient {
  OrasClient(
    config: ImageConfig(
      imageStorageDir: root,
      orasPath: orasPath,
      defaultRegistry: nil,
      insecureRegistries: []
    ),
    temporaryRoot: temporaryRoot ?? URL(fileURLWithPath: root, isDirectory: true),
    credentialStore: credentialStore
  )
}

// MARK: - Tests

@Suite(.tags(.core), .serialized)
struct OrasClientReachabilityTests {
  @Test(arguments: [200, 401, 403])
  func checkRegistryReachableAcceptsAvailableStatus(_ statusCode: Int) async throws {
    let client = makeOrasClient()
    try await StubURLProtocolGate.shared.run(handler: { _ in
      let url = try #require(URL(string: "https://registry.example.com/v2/"))
      let response = try #require(
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
      )
      return (response, Data())
    }) {
      try await client.checkRegistryReachable(
        registryHost: "registry.example.com",
        insecure: false,
        session: makeStubSession()
      )
    }
  }

  @Test
  func checkRegistryReachableRejectsConnectionFailure() async throws {
    let client = makeOrasClient()
    await #expect(throws: OrasError.self) {
      try await StubURLProtocolGate.shared.run(handler: { _ in throw URLError(.cannotConnectToHost) }) {
        try await client.checkRegistryReachable(
          registryHost: "registry.example.com",
          insecure: false,
          session: makeStubSession()
        )
      }
    }
  }

  @Test
  func checkRegistryReachableRejectsTimeout() async throws {
    let client = makeOrasClient()
    await #expect(throws: OrasError.self) {
      try await StubURLProtocolGate.shared.run(handler: { _ in throw URLError(.timedOut) }) {
        try await client.checkRegistryReachable(
          registryHost: "registry.example.com",
          insecure: false,
          session: makeStubSession()
        )
      }
    }
  }

  @Test(arguments: [404, 429, 500])
  func checkRegistryReachableRejectsUnavailableStatus(_ statusCode: Int) async throws {
    let client = makeOrasClient()
    await #expect(throws: OrasError.self) {
      try await StubURLProtocolGate.shared.run(handler: { _ in
        let url = try #require(URL(string: "https://registry.example.com/v2/"))
        let response = try #require(
          HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
        )
        return (response, Data())
      }) {
        try await client.checkRegistryReachable(
          registryHost: "registry.example.com",
          insecure: false,
          session: makeStubSession()
        )
      }
    }
  }

  @Test
  func checkRegistryReachableUsesHttpForInsecureRegistries() async throws {
    let client = makeOrasClient()
    let capturedURL = CapturedURLBox()
    try await StubURLProtocolGate.shared.run(handler: { request in
      capturedURL.set(request.url)
      let url = try #require(URL(string: "http://registry.example.com/v2/"))
      let response = try #require(
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
      )
      return (response, Data())
    }) {
      try await client.checkRegistryReachable(
        registryHost: "registry.example.com",
        insecure: true,
        session: makeStubSession()
      )
    }
    #expect(capturedURL.get()?.scheme == "http")
  }

  @Test
  func dockerHubAvailabilityUsesDistributionRegistryHost() async throws {
    let client = makeOrasClient()
    let capturedURL = CapturedURLBox()
    try await StubURLProtocolGate.shared.run(handler: { request in
      capturedURL.set(request.url)
      let url = try #require(URL(string: "https://registry-1.docker.io/v2/"))
      let response = try #require(
        HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)
      )
      return (response, Data())
    }) {
      try await client.checkRegistryReachable(
        registryHost: "docker.io",
        insecure: false,
        session: makeStubSession()
      )
    }
    #expect(capturedURL.get()?.host == "registry-1.docker.io")
  }

  @Test
  func registryCommandsUseIsolatedConfigAndKeychainCredential() async throws {
    try await withTemporaryDirectory(prefix: "oras-registry-auth") { root in
      let orasPath = "\(root)/oras"
      let capturePath = "\(root)/captures"
      let configCapturePath = "\(root)/config-paths"
      let payload = Data("authenticated blob\n".utf8)
      let digest = "sha256:" + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
      let script = """
      #!/bin/sh
      username=
      registry_config=
      previous=
      for argument in "$@"; do
        if [ "$previous" = "-u" ] || [ "$previous" = "--username" ]; then
          username="$argument"
        fi
        if [ "$previous" = "--registry-config" ]; then
          registry_config="$argument"
        fi
        previous="$argument"
      done
      IFS= read -r password
      printf '%s|%s|%s\n' "$1" "$username" "$password" >> "\(capturePath)"
      printf '%s\n' "$registry_config" >> "\(configCapturePath)"
      case "$1" in
        resolve) printf 'sha256:1111111111111111111111111111111111111111111111111111111111111111\n' ;;
        blob) printf 'authenticated blob\n' ;;
        *) exit 2 ;;
      esac
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)
      let credentialStore = makeTestRegistryCredentialStore()
      try await credentialStore.save(
        RegistryCredential(username: "registry-user", password: "registry-password"),
        for: "registry.example.com"
      )
      let client = makeOrasClient(
        root: root,
        orasPath: orasPath,
        credentialStore: credentialStore
      )
      let outputPath = "\(root)/blob.zst"

      _ = try await client.resolve(reference: ImageReference.parse("registry.example.com/repo:tag"))
      try await client.fetchBlob(
        reference: ImageReference.parse("registry.example.com/repo:tag"),
        digest: digest,
        outputPath: outputPath,
        expectedSize: UInt64(payload.count)
      )

      let captures = try String(contentsOfFile: capturePath, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
      #expect(captures == [
        "resolve|registry-user|registry-password",
        "blob|registry-user|registry-password",
      ])
      let configPaths = try String(contentsOfFile: configCapturePath, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
      #expect(configPaths.count == 2)
      #expect(configPaths.allSatisfy { $0.hasPrefix(root) })
      #expect(configPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) == false })
    }
  }

  @Test
  func fetchBlobStreamsStdoutToOutputFileAndValidatesDigest() async throws {
    try await withTemporaryDirectory(prefix: "oras-blob-fetch") { root in
      let payload = Data("hello blob\n".utf8)
      let digest = "sha256:" + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
      let orasPath = (root as NSString).appendingPathComponent("oras")
      let outputPath = (root as NSString).appendingPathComponent("blob.zst")
      let script = """
      #!/bin/sh
      if [ "$1" != "blob" ] || [ "$2" != "fetch" ] || [ "$3" != "--output" ] || [ "$4" != "-" ]; then
        echo "unexpected args: $*" >&2
        exit 2
      fi
      printf 'hello blob\\n'
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)

      let client = makeOrasClient(root: root, orasPath: orasPath)

      try await client.fetchBlob(
        reference: ImageReference.parse("registry.example.com/repo:tag"),
        digest: digest,
        outputPath: outputPath,
        expectedSize: UInt64(payload.count)
      )
      let output = try Data(contentsOf: URL(fileURLWithPath: outputPath))
      #expect(output == payload)
    }
  }

  @Test
  func fetchBlobReportsDescriptorMismatchesSeparatelyFromToolFailures() async throws {
    try await withTemporaryDirectory(prefix: "oras-blob-mismatch") { root in
      let payload = Data("wrong blob\n".utf8)
      let actualDigest = "sha256:" + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
      let expectedDigest = "sha256:\(String(repeating: "1", count: 64))"
      let orasPath = (root as NSString).appendingPathComponent("oras")
      let outputPath = (root as NSString).appendingPathComponent("blob.zst")
      let script = """
      #!/bin/sh
      printf 'wrong blob\n'
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)

      let client = makeOrasClient(root: root, orasPath: orasPath)

      do {
        try await client.fetchBlob(
          reference: ImageReference.parse("registry.example.com/repo:tag"),
          digest: expectedDigest,
          outputPath: outputPath,
          expectedSize: UInt64(payload.count + 1)
        )
        Issue.record("Expected the blob size mismatch to fail")
      } catch let error as OrasBlobValidationError {
        #expect(error == .sizeMismatch(
          digest: expectedDigest,
          expected: UInt64(payload.count + 1),
          actual: UInt64(payload.count)
        ))
      }

      do {
        try await client.fetchBlob(
          reference: ImageReference.parse("registry.example.com/repo:tag"),
          digest: expectedDigest,
          outputPath: outputPath,
          expectedSize: UInt64(payload.count)
        )
        Issue.record("Expected the blob digest mismatch to fail")
      } catch let error as OrasBlobValidationError {
        #expect(error == .digestMismatch(expected: expectedDigest, actual: actualDigest))
      }

      #expect(FileManager.default.fileExists(atPath: outputPath) == false)
    }
  }

  @Test
  func fetchBlobDoesNotHangWhenDescendantKeepsStderrOpen() async throws {
    try await withTemporaryDirectory(prefix: "oras-blob-inherited-stderr") { root in
      let payload = Data("hello blob\n".utf8)
      let digest = "sha256:" + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
      let orasPath = (root as NSString).appendingPathComponent("oras")
      let outputPath = (root as NSString).appendingPathComponent("blob.zst")
      let childPIDPath = (root as NSString).appendingPathComponent("child.pid")
      let script = """
      #!/bin/sh
      sleep 10 >&2 &
      echo "$!" > "\(childPIDPath)"
      printf 'hello blob\\n'
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)
      let client = makeOrasClient(root: root, orasPath: orasPath)
      var childPID: pid_t?
      defer {
        if let childPID {
          _ = kill(childPID, SIGTERM)
        }
      }
      let clock = ContinuousClock()
      let startedAt = clock.now

      do {
        try await client.fetchBlob(
          reference: ImageReference.parse("registry.example.com/repo:tag"),
          digest: digest,
          outputPath: outputPath,
          expectedSize: UInt64(payload.count)
        )
        Issue.record("Expected inherited stderr to make the output incomplete")
      } catch let error as OrasError {
        guard case .invalidOutput = error else {
          Issue.record("Expected invalidOutput, got \(error.localizedDescription)")
          return
        }
      }

      childPID = try await waitForPid(atPath: childPIDPath)
      #expect(startedAt.duration(to: clock.now) < .seconds(5))
      #expect(FileManager.default.fileExists(atPath: outputPath) == false)
    }
  }

  @Test
  func fetchBlobCancellationTerminatesOrasProcessAndPreservesExistingOutput() async throws {
    try await withTemporaryDirectory(prefix: "oras-blob-cancel") { root in
      let orasPath = (root as NSString).appendingPathComponent("oras")
      let outputPath = (root as NSString).appendingPathComponent("blob.zst")
      let pidPath = (root as NSString).appendingPathComponent("oras.pid")
      let existing = Data("existing blob\n".utf8)
      try existing.write(to: URL(fileURLWithPath: outputPath))
      let script = """
      #!/bin/sh
      echo "$$" > "\(pidPath)"
      sleep 30
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)

      let client = makeOrasClient(root: root, orasPath: orasPath)
      let task = Task {
        try await client.fetchBlob(
          reference: ImageReference.parse("registry.example.com/repo:tag"),
          digest: "sha256:\(String(repeating: "1", count: 64))",
          outputPath: outputPath
        )
      }

      let pid = try await waitForPid(atPath: pidPath)
      task.cancel()

      await #expect(throws: CancellationError.self) {
        try await task.value
      }
      try await waitUntilProcessStops(pid)
      let output = try Data(contentsOf: URL(fileURLWithPath: outputPath))
      #expect(output == existing)
    }
  }

  @Test
  func blobPresenceDistinguishesExistingAndMissingBlobs() async throws {
    try await withTemporaryDirectory(prefix: "oras-blob-exists") { root in
      let orasPath = (root as NSString).appendingPathComponent("oras")
      let script = """
      #!/bin/sh
      if [ "$1" != "blob" ] || [ "$2" != "fetch" ] || [ "$3" != "--descriptor" ]; then
        echo "unexpected args: $*" >&2
        exit 2
      fi
      case "$4" in
        *@sha256:1111111111111111111111111111111111111111111111111111111111111111) exit 0 ;;
        *) echo "not found" >&2; exit 1 ;;
      esac
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)

      let client = makeOrasClient(root: root, orasPath: orasPath)

      let existing = try await client.blobPresence(
        repositoryReference: "registry.example.com/repo",
        digest: "sha256:1111111111111111111111111111111111111111111111111111111111111111"
      )
      let missing = try await client.blobPresence(
        repositoryReference: "registry.example.com/repo",
        digest: "sha256:2222222222222222222222222222222222222222222222222222222222222222"
      )

      #expect(existing == .exists)
      #expect(missing == .missing)
    }
  }

  @Test
  func blobPresenceThrowsForNonMissingRegistryFailures() async throws {
    try await withTemporaryDirectory(prefix: "oras-blob-auth-failure") { root in
      let orasPath = (root as NSString).appendingPathComponent("oras")
      let script = """
      #!/bin/sh
      echo "unauthorized" >&2
      exit 1
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)

      let client = makeOrasClient(root: root, orasPath: orasPath)

      await #expect(throws: OrasError.self) {
        _ = try await client.blobPresence(
          repositoryReference: "registry.example.com/repo",
          digest: "sha256:1111111111111111111111111111111111111111111111111111111111111111"
        )
      }
    }
  }

  @Test
  func blobPresencePropagatesCancellation() async throws {
    let client = makeOrasClient(orasPath: "/usr/bin/false")
    let gate = CancellationGate()
    let task = Task {
      await gate.wait()
      _ = try await client.blobPresence(
        repositoryReference: "registry.example.com/repo",
        digest: "sha256:1111111111111111111111111111111111111111111111111111111111111111"
      )
    }
    task.cancel()
    await gate.open()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  @Test
  func pushBlobReturnsDescriptorFromOrasOutput() async throws {
    try await withTemporaryDirectory(prefix: "oras-blob-push") { root in
      let payload = Data("blob to push".utf8)
      let digest = "sha256:" + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
      let blobPath = "\(root)/blob"
      let orasPath = "\(root)/oras"
      try payload.write(to: URL(fileURLWithPath: blobPath))
      let script = """
      #!/bin/sh
      if [ "$1" != "blob" ] || [ "$2" != "push" ]; then
        echo "unexpected args: $*" >&2
        exit 2
      fi
      printf '{"mediaType":"application/test","digest":"\(digest)","size":\(payload.count)}'
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)
      let client = makeOrasClient(root: root, orasPath: orasPath)

      let descriptor = try await client.pushBlob(
        repositoryReference: "registry.example.com/repo",
        digest: digest,
        filePath: blobPath,
        mediaType: "application/test",
        expectedSize: UInt64(payload.count)
      )

      #expect(descriptor == OrasDescriptor(mediaType: "application/test", digest: digest, size: UInt64(payload.count)))
    }
  }

  @Test
  func pushManifestReturnsPushedDigest() async throws {
    try await withTemporaryDirectory(prefix: "oras-manifest-push") { root in
      let manifestPath = "\(root)/manifest.json"
      let orasPath = "\(root)/oras"
      let manifestData = Data("{}".utf8)
      let manifestDigest = "sha256:" + SHA256.hash(data: manifestData)
        .map { String(format: "%02x", $0) }
        .joined()
      try manifestData.write(to: URL(fileURLWithPath: manifestPath))
      let script = """
      #!/bin/sh
      if [ "$1" != "manifest" ] || [ "$2" != "push" ]; then
        echo "unexpected args: $*" >&2
        exit 2
      fi
      printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"\(manifestDigest)","size":2}'
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)
      let client = makeOrasClient(root: root, orasPath: orasPath)

      let result = try await client.pushManifest(
        reference: ImageReference.parse("registry.example.com/repo:tag"),
        manifestPath: manifestPath
      )

      #expect(result.digest == manifestDigest)
    }
  }

  @Test
  func cancelledRunningManifestPushHasAnUnknownCommitOutcome() async throws {
    try await withTemporaryDirectory(prefix: "oras-manifest-cancel") { root in
      let manifestPath = "\(root)/manifest.json"
      let orasPath = "\(root)/oras"
      let pidPath = "\(root)/oras.pid"
      try Data("{}".utf8).write(to: URL(fileURLWithPath: manifestPath))
      let script = """
      #!/bin/sh
      echo "$$" > "\(pidPath)"
      sleep 30
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)
      let client = makeOrasClient(root: root, orasPath: orasPath)
      let task = Task {
        try await client.pushManifest(
          reference: ImageReference.parse("registry.example.com/repo:tag"),
          manifestPath: manifestPath
        )
      }

      let pid = try await waitForPid(atPath: pidPath)
      task.cancel()
      do {
        _ = try await task.value
        Issue.record("Expected the cancelled manifest push to have an unknown commit outcome")
      } catch let error as OrasError {
        guard case .manifestCommitOutcomeUnknown(let reason) = error else {
          Issue.record("Expected manifestCommitOutcomeUnknown, got \(error.localizedDescription)")
          return
        }
        #expect(reason.isEmpty == false)
      }
      try await waitUntilProcessStops(pid)
    }
  }

  @Test
  func manifestProcessLaunchFailureIsNotAnUnknownCommitOutcome() async throws {
    try await withTemporaryDirectory(prefix: "oras-manifest-launch-failure") { root in
      let manifestPath = "\(root)/manifest.json"
      let orasPath = "\(root)/oras"
      try Data("{}".utf8).write(to: URL(fileURLWithPath: manifestPath))
      try Data("not executable".utf8).write(to: URL(fileURLWithPath: orasPath))
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: orasPath)
      let client = makeOrasClient(root: root, orasPath: orasPath)

      do {
        _ = try await client.pushManifest(
          reference: ImageReference.parse("registry.example.com/repo:tag"),
          manifestPath: manifestPath
        )
        Issue.record("Expected the manifest process launch to fail")
      } catch let error as OrasError {
        guard case .commandFailed(let exitCode, _) = error else {
          Issue.record("Expected commandFailed, got \(error.localizedDescription)")
          return
        }
        #expect(exitCode == -1)
      }
    }
  }

  @Test
  func missingManifestFailsBeforeOrasStarts() async throws {
    try await withTemporaryDirectory(prefix: "oras-manifest-missing") { root in
      let manifestPath = "\(root)/missing-manifest.json"
      let orasPath = "\(root)/oras"
      let startedPath = "\(root)/oras-started"
      let script = """
      #!/bin/sh
      touch "\(startedPath)"
      exit 0
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)
      let client = makeOrasClient(root: root, orasPath: orasPath)

      do {
        _ = try await client.pushManifest(
          reference: ImageReference.parse("registry.example.com/repo:tag"),
          manifestPath: manifestPath
        )
        Issue.record("Expected the missing manifest to fail before ORAS starts")
      } catch let error as OrasError {
        guard case .invalidOutput(let message) = error else {
          Issue.record("Expected invalidOutput, got \(error.localizedDescription)")
          return
        }
        #expect(message.contains(manifestPath))
      }

      #expect(FileManager.default.fileExists(atPath: startedPath) == false)
    }
  }

  @Test
  func orasOperationRemovesItsPrivateTemporaryDirectory() async throws {
    try await withTemporaryDirectory(prefix: "oras-temp-cleanup") { root in
      let orasPath = "\(root)/oras"
      let capturedTempPath = "\(root)/captured-temp-path"
      let temporaryRoot = URL(fileURLWithPath: "\(root)/temporary-root", isDirectory: true)
      let script = """
      #!/bin/sh
      printf '%s' "$TMPDIR" > "\(capturedTempPath)"
      printf 'sha256:1111111111111111111111111111111111111111111111111111111111111111\n'
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)
      let client = makeOrasClient(
        root: root,
        orasPath: orasPath,
        temporaryRoot: temporaryRoot
      )

      _ = try await client.resolve(reference: ImageReference.parse("registry.example.com/repo:tag"))
      let operationTempPath = try String(contentsOfFile: capturedTempPath, encoding: .utf8)

      #expect(operationTempPath.hasPrefix(temporaryRoot.path))
      #expect(FileManager.default.fileExists(atPath: operationTempPath) == false)
    }
  }
}

private actor CancellationGate {
  private var isOpen = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    if isOpen {
      return
    }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}
