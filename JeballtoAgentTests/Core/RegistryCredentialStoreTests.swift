import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct RegistryCredentialStoreTests {
  @Test
  func storesUpdatesDeletesAndClearsCredentials() async throws {
    let backend = InMemorySecretStoreBackend()
    let store = RegistryCredentialStore(backend: backend)
    let first = RegistryCredential(username: "first", password: "first-password")
    let updated = RegistryCredential(username: "updated", password: "updated-password")
    let second = RegistryCredential(username: "second", password: "second-password")

    try await store.save(first, for: "first.example.com")
    #expect(try await store.credential(for: "first.example.com") == first)

    try await store.save(updated, for: "first.example.com")
    try await store.save(second, for: "second.example.com")
    #expect(try await store.credential(for: "first.example.com") == updated)
    #expect(try await store.credential(for: "second.example.com") == second)

    try await store.deleteCredential(for: "first.example.com")
    #expect(try await store.credential(for: "first.example.com") == nil)
    #expect(try await store.credential(for: "second.example.com") == second)

    try await store.deleteAllCredentials()
    #expect(try await store.credential(for: "second.example.com") == nil)
  }

  @Test(arguments: [
    Data("not-json".utf8),
    Data(#"{"username":"bad\nname","password":"password"}"#.utf8),
    Data(#"{"username":"name","password":"bad\npassword"}"#.utf8),
  ])
  func rejectsMalformedOrInvalidStoredCredentials(_ data: Data) async throws {
    let backend = InMemorySecretStoreBackend()
    try backend.save(data, service: RegistryCredentialStore.service, account: "registry.example.com")
    let store = RegistryCredentialStore(backend: backend)

    await #expect(throws: RegistryCredentialStoreError.self) {
      _ = try await store.credential(for: "registry.example.com")
    }
  }

  @Test
  func defaultsToBackgroundSafeDeviceBoundAccessibility() {
    #expect(RegistryCredentialStore.defaultAccessibility == .afterFirstUnlockThisDeviceOnly)
  }
}
