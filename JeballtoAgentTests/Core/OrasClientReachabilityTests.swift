import CryptoKit
import Darwin
import Foundation
import Testing
@testable import JeballtoAgent

// MARK: - URLProtocol stub for OrasClient reachability tests

private class StubURLProtocol: URLProtocol {
  typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

  nonisolated(unsafe) static var handler: Handler?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
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
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
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

private func makeStubSession() -> URLSession {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [StubURLProtocol.self]
  return URLSession(configuration: config)
}

private func makeOrasClient() -> OrasClient {
  OrasClient(config: ImageConfig(
    imageStorageDir: NSTemporaryDirectory(),
    orasPath: nil,
    defaultRegistry: nil,
    insecureRegistries: []
  ))
}

// MARK: - Tests

@Suite(.tags(.core), .serialized)
struct OrasClientReachabilityTests {
  @Test
  func checkRegistryReachableAccepts200() async throws {
    let client = makeOrasClient()
    StubURLProtocol.handler = { _ in
      let url = URL(string: "https://registry.example.com/v2/")!
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, Data())
    }
    try await client.checkRegistryReachable(
      registryHost: "registry.example.com",
      insecure: false,
      session: makeStubSession()
    )
  }

  @Test
  func checkRegistryReachableAccepts401() async throws {
    let client = makeOrasClient()
    StubURLProtocol.handler = { _ in
      let url = URL(string: "https://registry.example.com/v2/")!
      let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
      return (response, Data())
    }
    try await client.checkRegistryReachable(
      registryHost: "registry.example.com",
      insecure: false,
      session: makeStubSession()
    )
  }

  @Test
  func checkRegistryReachableRejectsConnectionFailure() async throws {
    let client = makeOrasClient()
    StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
    await #expect(throws: OrasError.self) {
      try await client.checkRegistryReachable(
        registryHost: "registry.example.com",
        insecure: false,
        session: makeStubSession()
      )
    }
  }

  @Test
  func checkRegistryReachableRejectsTimeout() async throws {
    let client = makeOrasClient()
    StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
    await #expect(throws: OrasError.self) {
      try await client.checkRegistryReachable(
        registryHost: "registry.example.com",
        insecure: false,
        session: makeStubSession()
      )
    }
  }

  @Test
  func checkRegistryReachableRejectsUnexpectedStatusCode() async throws {
    let client = makeOrasClient()
    StubURLProtocol.handler = { _ in
      let url = URL(string: "https://registry.example.com/v2/")!
      let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
      return (response, Data())
    }
    await #expect(throws: OrasError.self) {
      try await client.checkRegistryReachable(
        registryHost: "registry.example.com",
        insecure: false,
        session: makeStubSession()
      )
    }
  }

  @Test
  func checkRegistryReachableUsesHttpForInsecureRegistries() async throws {
    let client = makeOrasClient()
    var capturedURL: URL?
    StubURLProtocol.handler = { request in
      capturedURL = request.url
      let url = URL(string: "http://registry.example.com/v2/")!
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
      return (response, Data())
    }
    try await client.checkRegistryReachable(
      registryHost: "registry.example.com",
      insecure: true,
      session: makeStubSession()
    )
    #expect(capturedURL?.scheme == "http")
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

      let client = OrasClient(config: ImageConfig(
        imageStorageDir: root,
        orasPath: orasPath,
        defaultRegistry: nil,
        insecureRegistries: []
      ))

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

      let client = OrasClient(config: ImageConfig(
        imageStorageDir: root,
        orasPath: orasPath,
        defaultRegistry: nil,
        insecureRegistries: []
      ))
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

      let client = OrasClient(config: ImageConfig(
        imageStorageDir: root,
        orasPath: orasPath,
        defaultRegistry: nil,
        insecureRegistries: []
      ))

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

      let client = OrasClient(config: ImageConfig(
        imageStorageDir: root,
        orasPath: orasPath,
        defaultRegistry: nil,
        insecureRegistries: []
      ))

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
    let client = OrasClient(config: ImageConfig(
      imageStorageDir: NSTemporaryDirectory(),
      orasPath: "/usr/bin/false",
      defaultRegistry: nil,
      insecureRegistries: []
    ))
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
      let client = OrasClient(config: ImageConfig(
        imageStorageDir: root,
        orasPath: orasPath,
        defaultRegistry: nil,
        insecureRegistries: []
      ))

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
      let manifestDigest = "sha256:3333333333333333333333333333333333333333333333333333333333333333"
      try Data("{}".utf8).write(to: URL(fileURLWithPath: manifestPath))
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
      let client = OrasClient(config: ImageConfig(
        imageStorageDir: root,
        orasPath: orasPath,
        defaultRegistry: nil,
        insecureRegistries: []
      ))

      let result = try await client.pushManifest(
        reference: ImageReference.parse("registry.example.com/repo:tag"),
        manifestPath: manifestPath
      )

      #expect(result.digest == manifestDigest)
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
