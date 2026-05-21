import CryptoKit
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
}
