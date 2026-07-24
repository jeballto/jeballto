import Foundation
import Security

protocol SecretStoreBackend: Sendable {
  func load(service: String, account: String) throws -> Data?
  func save(_ data: Data, service: String, account: String) throws
  func delete(service: String, account: String) throws
  func deleteAll(service: String) throws
}

enum KeychainStorageTarget: Sendable, Equatable {
  case dataProtection
  case fileBased
}

enum KeychainSecretAccessibility: Sendable, Equatable {
  case whenUnlockedThisDeviceOnly
  case afterFirstUnlockThisDeviceOnly

  var securityValue: CFString {
    switch self {
    case .whenUnlockedThisDeviceOnly:
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    case .afterFirstUnlockThisDeviceOnly:
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }
  }
}

struct KeychainSecretStoreBackend: SecretStoreBackend {
  private static let applicationIdentifierEntitlement = "com.apple.application-identifier"
  private static let accessGroupsEntitlement = "keychain-access-groups"
  private let target: KeychainStorageTarget
  private let accessGroup: String?
  private let accessibility: KeychainSecretAccessibility

  init(
    target: KeychainStorageTarget? = nil,
    accessibility: KeychainSecretAccessibility = .whenUnlockedThisDeviceOnly
  ) {
    let currentAccessGroup = Self.currentDataProtectionAccessGroup()
    #if DEBUG
    self.target = target ?? Self.storageTarget(accessGroup: currentAccessGroup)
    #else
    // Release builds must use the data protection Keychain. Falling back would hide a broken
    // signature or provisioning profile and silently weaken the credential storage contract.
    self.target = target ?? .dataProtection
    #endif
    accessGroup = self.target == .dataProtection ? currentAccessGroup : nil
    self.accessibility = accessibility
    if self.target == .fileBased {
      logWarning(
        "Application Keychain access group is unavailable; using the login Keychain for this Debug build",
        category: "Security"
      )
    }
  }

  func load(service: String, account: String) throws -> Data? {
    var query = baseQuery(service: service, account: account)
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    switch status {
    case errSecSuccess:
      guard let data = result as? Data else { throw KeychainSecretStoreError.invalidResult }
      return data
    case errSecItemNotFound:
      return nil
    case errSecInteractionNotAllowed:
      throw KeychainSecretStoreError.interactionNotAllowed
    case errSecMissingEntitlement:
      throw KeychainSecretStoreError.missingEntitlement
    default:
      throw KeychainSecretStoreError.unexpectedStatus(status)
    }
  }

  func save(_ data: Data, service: String, account: String) throws {
    let searchQuery = baseQuery(service: service, account: account)
    var addQuery = searchQuery
    addQuery[kSecValueData] = data
    if target == .dataProtection {
      addQuery[kSecAttrAccessible] = accessibility.securityValue
    }

    let status = SecItemAdd(addQuery as CFDictionary, nil)
    switch status {
    case errSecSuccess:
      return
    case errSecDuplicateItem:
      var updateAttributes: [CFString: Any] = [kSecValueData: data]
      if target == .dataProtection {
        updateAttributes[kSecAttrAccessible] = accessibility.securityValue
      }
      let updateStatus = SecItemUpdate(
        searchQuery as CFDictionary,
        updateAttributes as CFDictionary
      )
      switch updateStatus {
      case errSecSuccess:
        return
      case errSecItemNotFound:
        throw KeychainSecretStoreError.itemDisappearedDuringUpdate
      case errSecInteractionNotAllowed:
        throw KeychainSecretStoreError.interactionNotAllowed
      case errSecMissingEntitlement:
        throw KeychainSecretStoreError.missingEntitlement
      default:
        throw KeychainSecretStoreError.unexpectedStatus(updateStatus)
      }
    case errSecInteractionNotAllowed:
      throw KeychainSecretStoreError.interactionNotAllowed
    case errSecMissingEntitlement:
      throw KeychainSecretStoreError.missingEntitlement
    default:
      throw KeychainSecretStoreError.unexpectedStatus(status)
    }
  }

  func delete(service: String, account: String) throws {
    let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    switch status {
    case errSecSuccess, errSecItemNotFound:
      return
    case errSecInteractionNotAllowed:
      throw KeychainSecretStoreError.interactionNotAllowed
    case errSecMissingEntitlement:
      throw KeychainSecretStoreError.missingEntitlement
    default:
      throw KeychainSecretStoreError.unexpectedStatus(status)
    }
  }

  func deleteAll(service: String) throws {
    let status = SecItemDelete(serviceQuery(service: service) as CFDictionary)
    switch status {
    case errSecSuccess, errSecItemNotFound:
      return
    case errSecInteractionNotAllowed:
      throw KeychainSecretStoreError.interactionNotAllowed
    case errSecMissingEntitlement:
      throw KeychainSecretStoreError.missingEntitlement
    default:
      throw KeychainSecretStoreError.unexpectedStatus(status)
    }
  }

  private func baseQuery(service: String, account: String) -> [CFString: Any] {
    var query = serviceQuery(service: service)
    query[kSecAttrAccount] = account
    return query
  }

  private func serviceQuery(service: String) -> [CFString: Any] {
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
    ]
    if target == .dataProtection {
      query[kSecUseDataProtectionKeychain] = true
      if let accessGroup {
        query[kSecAttrAccessGroup] = accessGroup
      }
    }
    return query
  }

  static func storageTarget(accessGroup: String?) -> KeychainStorageTarget {
    accessGroup?.isEmpty == false ? .dataProtection : .fileBased
  }

  private static func currentDataProtectionAccessGroup() -> String? {
    guard let task = SecTaskCreateFromSelf(nil) else { return nil }
    let applicationIdentifierValue = SecTaskCopyValueForEntitlement(
      task,
      applicationIdentifierEntitlement as CFString,
      nil
    )
    let accessGroupsValue = SecTaskCopyValueForEntitlement(
      task,
      accessGroupsEntitlement as CFString,
      nil
    )
    guard let applicationIdentifier = applicationIdentifierValue as? String,
          let accessGroups = accessGroupsValue as? [String],
          accessGroups.contains(applicationIdentifier) else
    {
      return nil
    }
    return applicationIdentifier
  }
}

enum KeychainSecretStoreError: Error, LocalizedError {
  case invalidResult
  case interactionNotAllowed
  case itemDisappearedDuringUpdate
  case missingEntitlement
  case unexpectedStatus(OSStatus)

  var errorDescription: String? {
    switch self {
    case .invalidResult:
      return "Keychain returned success without secret data"
    case .interactionNotAllowed:
      return "Keychain is locked or interaction is not currently allowed"
    case .itemDisappearedDuringUpdate:
      return "Keychain item disappeared while it was being updated"
    case .missingEntitlement:
      return "Data protection Keychain requires a provisioning-profile-backed application identifier and access group"
    case .unexpectedStatus(let status):
      let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
      return "Keychain operation failed with status \(status): \(message)"
    }
  }
}

actor APISecretStore {
  static let shared = APISecretStore()

  private static let service = "com.jeballto.vmagent.api"
  private static let tokenAccount = "bearer-token"
  private let backend: any SecretStoreBackend

  init(backend: any SecretStoreBackend = KeychainSecretStoreBackend()) {
    self.backend = backend
  }

  /// Returns the existing token or atomically stores the configuration candidate on first use.
  func resolveToken(configurationCandidate: String) throws -> String {
    if let stored = try backend.load(service: Self.service, account: Self.tokenAccount) {
      if let token = String(data: stored, encoding: .utf8), APIToken.isValid(token) {
        return token
      }
      logWarning("Invalid API token found in Keychain; rotating it", category: "Security")
    }

    let replacement = APIToken.isValid(configurationCandidate) ? configurationCandidate : APIToken.generate()
    try backend.save(Data(replacement.utf8), service: Self.service, account: Self.tokenAccount)
    return replacement
  }

  func deleteToken() throws {
    try backend.delete(service: Self.service, account: Self.tokenAccount)
  }
}
