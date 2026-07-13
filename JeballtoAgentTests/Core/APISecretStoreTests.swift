import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct APISecretStoreTests {
  @Test
  func configIgnoresTokenAndDoesNotWriteItBack() throws {
    let exposedToken = "legacy-secret-token-value-1234567890"
    let json = """
    {
      "port": 8011,
      "host": "0.0.0.0",
      "token": "\(exposedToken)",
      "enableHTTPS": false,
      "maxConcurrentRequests": 100
    }
    """
    let decoded = try JSONDecoder().decode(APIConfig.self, from: Data(json.utf8))
    #expect(decoded.token != exposedToken)
    #expect(APIToken.isValid(decoded.token))

    let encoded = try JSONEncoder().encode(decoded)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["token"] == nil)
  }

  @Test
  func firstResolutionStoresCandidateAndLaterResolutionUsesStoredToken() async throws {
    let backend = MockSecretStoreBackend()
    let store = APISecretStore(backend: backend)

    let firstCandidate = "first-token-value-1234567890-abcdef"
    let secondCandidate = "different-token-value-1234567890-ab"
    let rotatedCandidate = "rotated-token-value-1234567890-abc"
    let first = try await store.resolveToken(configurationCandidate: firstCandidate)
    let second = try await store.resolveToken(configurationCandidate: secondCandidate)

    #expect(first == firstCandidate)
    #expect(second == firstCandidate)
    #expect(backend.saveCount == 1)

    try await store.deleteToken()
    let third = try await store.resolveToken(configurationCandidate: rotatedCandidate)
    #expect(third == rotatedCandidate)
    #expect(backend.deleteCount == 1)
  }

  @Test
  func truncatedStoredTokenIsRotated() async throws {
    let backend = MockSecretStoreBackend(initialData: Data("DCB64A92-".utf8))
    let store = APISecretStore(backend: backend)
    let candidate = "replacement-token-value-1234567890-ab"

    let resolved = try await store.resolveToken(configurationCandidate: candidate)

    #expect(resolved == candidate)
    #expect(backend.saveCount == 1)
    #expect(APIToken.isValid(resolved))
  }

  @Test
  func maximumLengthTokenRoundTripsWithoutTruncation() async throws {
    let backend = MockSecretStoreBackend()
    let store = APISecretStore(backend: backend)
    let token = String(repeating: "A", count: APIToken.maximumLength)

    let first = try await store.resolveToken(configurationCandidate: token)
    let second = try await store.resolveToken(configurationCandidate: APIToken.generate())

    #expect(first == token)
    #expect(second == token)
    #expect(first.utf8.count == APIToken.maximumLength)
  }

  @Test
  func invalidConfigTokenIsIgnored() throws {
    let json = """
    {
      "port": 8011,
      "host": "0.0.0.0",
      "token": "DCB64A92-",
      "maxConcurrentRequests": 100
    }
    """

    let decoded = try JSONDecoder().decode(APIConfig.self, from: Data(json.utf8))

    #expect(APIToken.isValid(decoded.token))
    #expect(decoded.token != "DCB64A92-")
  }

  @Test
  func keychainTargetRequiresAnAvailableAccessGroup() {
    #expect(KeychainSecretStoreBackend.storageTarget(accessGroup: nil) == .fileBased)
    #expect(KeychainSecretStoreBackend.storageTarget(accessGroup: "") == .fileBased)
    #expect(
      KeychainSecretStoreBackend.storageTarget(accessGroup: "TEAMID.com.jeballto.vmagent") ==
        .dataProtection
    )
  }

  @Test
  func realKeychainBackendRoundTripsForCurrentCodeSignature() throws {
    let backend = KeychainSecretStoreBackend()
    let service = "com.jeballto.vmagent.tests.\(UUID().uuidString)"
    let account = "round-trip"
    defer {
      do {
        try backend.delete(service: service, account: account)
      } catch {
        Issue.record("Failed to clean up test Keychain item: \(error.localizedDescription)")
      }
    }

    try backend.save(Data("first-value".utf8), service: service, account: account)
    #expect(try backend.load(service: service, account: account) == Data("first-value".utf8))

    try backend.save(Data("updated-value".utf8), service: service, account: account)
    #expect(try backend.load(service: service, account: account) == Data("updated-value".utf8))

    let maximumToken = Data(String(repeating: "T", count: APIToken.maximumLength).utf8)
    try backend.save(maximumToken, service: service, account: account)
    #expect(try backend.load(service: service, account: account) == maximumToken)

    try backend.delete(service: service, account: account)
    #expect(try backend.load(service: service, account: account) == nil)
  }
}

private final class MockSecretStoreBackend: SecretStoreBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var storedData: Data?
  private var _saveCount = 0
  private var _deleteCount = 0

  init(initialData: Data? = nil) {
    storedData = initialData
  }

  var saveCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return _saveCount
  }

  var deleteCount: Int {
    lock.withLock { _deleteCount }
  }

  func load(service: String, account: String) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return storedData
  }

  func save(_ data: Data, service: String, account: String) throws {
    lock.lock()
    storedData = data
    _saveCount += 1
    lock.unlock()
  }

  func delete(service: String, account: String) throws {
    lock.withLock {
      storedData = nil
      _deleteCount += 1
    }
  }

  func deleteAll(service: String) throws {
    lock.withLock {
      storedData = nil
      _deleteCount += 1
    }
  }
}
