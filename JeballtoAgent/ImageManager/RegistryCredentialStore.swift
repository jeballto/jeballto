import Foundation

struct RegistryCredential: Codable, Equatable, Sendable {
  let username: String
  let password: String
}

enum RegistryCredentialStoreError: Error, LocalizedError {
  case invalidCredential(String)
  case invalidStoredCredential(String)
  case encodingFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidCredential(let registry):
      "Registry credential for \(registry) is invalid"
    case .invalidStoredCredential(let registry):
      "Stored registry credential for \(registry) is invalid"
    case .encodingFailed(let registry):
      "Registry credential for \(registry) could not be encoded"
    }
  }
}

actor RegistryCredentialStore {
  static let shared = RegistryCredentialStore()
  nonisolated static let defaultAccessibility = KeychainSecretAccessibility.afterFirstUnlockThisDeviceOnly

  static let service = "com.jeballto.vmagent.registry"
  private let backend: any SecretStoreBackend

  init(
    backend: any SecretStoreBackend = KeychainSecretStoreBackend(
      accessibility: defaultAccessibility
    )
  ) {
    self.backend = backend
  }

  func credential(for registry: String) throws -> RegistryCredential? {
    guard let data = try backend.load(service: Self.service, account: registry) else { return nil }
    let credential: RegistryCredential
    do {
      credential = try JSONDecoder().decode(RegistryCredential.self, from: data)
    } catch {
      throw RegistryCredentialStoreError.invalidStoredCredential(registry)
    }
    guard RegistryCredentialValidator.loginError(
      registry: registry,
      username: credential.username,
      password: credential.password
    ) == nil else {
      throw RegistryCredentialStoreError.invalidStoredCredential(registry)
    }
    return credential
  }

  func save(_ credential: RegistryCredential, for registry: String) throws {
    guard RegistryCredentialValidator.loginError(
      registry: registry,
      username: credential.username,
      password: credential.password
    ) == nil else {
      throw RegistryCredentialStoreError.invalidCredential(registry)
    }
    let data: Data
    do {
      data = try JSONEncoder().encode(credential)
    } catch {
      throw RegistryCredentialStoreError.encodingFailed(registry)
    }
    try backend.save(data, service: Self.service, account: registry)
  }

  func deleteCredential(for registry: String) throws {
    try backend.delete(service: Self.service, account: registry)
  }

  func deleteAllCredentials() throws {
    try backend.deleteAll(service: Self.service)
  }
}
