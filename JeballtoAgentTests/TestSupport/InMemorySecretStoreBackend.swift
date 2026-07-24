import Foundation
@testable import JeballtoAgent

final class InMemorySecretStoreBackend: SecretStoreBackend, @unchecked Sendable {
  private struct Key: Hashable {
    let service: String
    let account: String
  }

  private let lock = NSLock()
  private var values: [Key: Data] = [:]

  func load(service: String, account: String) throws -> Data? {
    lock.withLock { values[Key(service: service, account: account)] }
  }

  func save(_ data: Data, service: String, account: String) throws {
    lock.withLock {
      values[Key(service: service, account: account)] = data
    }
  }

  func delete(service: String, account: String) throws {
    _ = lock.withLock {
      values.removeValue(forKey: Key(service: service, account: account))
    }
  }

  func deleteAll(service: String) throws {
    lock.withLock {
      values = values.filter { $0.key.service != service }
    }
  }
}

func makeTestRegistryCredentialStore() -> RegistryCredentialStore {
  RegistryCredentialStore(backend: InMemorySecretStoreBackend())
}
