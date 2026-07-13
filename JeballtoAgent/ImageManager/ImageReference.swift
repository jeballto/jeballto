import Foundation

/// Errors that can occur during OCI reference parsing
enum ImageReferenceError: Error, LocalizedError {
  case invalidFormat(String)
  case invalidRegistry(String)
  case invalidRepository(String)
  case invalidTag(String)
  case invalidDigest(String)

  var errorDescription: String? {
    switch self {
    case .invalidFormat(let msg): "Invalid image reference format: \(msg)"
    case .invalidRegistry(let msg): "Invalid registry: \(msg)"
    case .invalidRepository(let msg): "Invalid repository: \(msg)"
    case .invalidTag(let msg): "Invalid tag: \(msg)"
    case .invalidDigest(let msg): "Invalid digest: \(msg)"
    }
  }
}

/// Parsed OCI image reference (e.g. registry.example.com/repo/name:tag or @sha256:...)
struct ImageReference: Equatable, Sendable {
  let registry: String
  let repository: String
  let tag: String?
  let digest: String?

  /// Reconstructs the full reference string
  var fullReference: String {
    var ref = "\(registry)/\(repository)"
    if let tag {
      ref += ":\(tag)"
    }
    if let digest {
      ref += "@\(digest)"
    }
    return ref
  }

  // MARK: - Validation patterns

  private static let registryPattern = "^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(:[0-9]{1,5})?$"
  private static let repositoryPattern = "^[a-z0-9]+([._/-][a-z0-9]+)*$"
  private static let tagPattern = "^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$"
  private static let digestPattern = "^sha256:[a-f0-9]{64}$"

  static func isValidRegistry(_ registry: String) -> Bool {
    guard registry == registry.lowercased(),
          registry.utf8.count <= 259,
          registry.range(of: registryPattern, options: .regularExpression) != nil else
    {
      return false
    }
    if let colon = registry.lastIndex(of: ":") {
      let portValue = registry[registry.index(after: colon)...]
      guard let port = Int(portValue), (1 ... 65535).contains(port) else { return false }
    }
    let host = registry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)[0]
    guard host.utf8.count <= 253 else { return false }
    return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
      guard label.isEmpty == false, label.utf8.count <= 63,
            let first = label.utf8.first, let last = label.utf8.last,
            Self.isASCIIAlphanumeric(first), Self.isASCIIAlphanumeric(last) else
      {
        return false
      }
      return label.utf8.allSatisfy { Self.isASCIIAlphanumeric($0) || $0 == 0x2D }
    }
  }

  /// Parses an OCI image reference string into its components.
  ///
  /// Supported formats:
  /// - `registry/repo:tag`
  /// - `registry/repo@sha256:...`
  /// - `registry/repo` (no tag or digest)
  /// - `registry:port/repo:tag`
  static func parse(_ reference: String, defaultRegistry: String? = nil) throws -> ImageReference {
    guard reference.utf8.count <= 1024 else {
      throw ImageReferenceError.invalidFormat("Reference exceeds the 1024-byte limit")
    }
    var trimmed = reference.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      throw ImageReferenceError.invalidFormat("Reference is empty")
    }
    let firstComponent = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
    let hasExplicitRegistry = firstComponent.contains(".") || firstComponent.contains(":")
      || firstComponent == "localhost"
    if trimmed.contains("/") == false || hasExplicitRegistry == false {
      guard let defaultRegistry, defaultRegistry.isEmpty == false else {
        throw ImageReferenceError.invalidFormat(
          "Reference must include a registry, or images.defaultRegistry must be configured"
        )
      }
      trimmed = "\(defaultRegistry)/\(trimmed)"
    }

    // Split on @ for digest
    var remaining: String
    var digest: String?
    if let atIndex = trimmed.lastIndex(of: "@") {
      digest = String(trimmed[trimmed.index(after: atIndex)...])
      remaining = String(trimmed[..<atIndex])
    } else {
      remaining = trimmed
    }

    // Split remaining into registry/repository and optional tag
    var tag: String?
    if let firstSlash = remaining.firstIndex(of: "/") {
      let repoAndTag = String(remaining[remaining.index(after: firstSlash)...])
      if let lastColon = repoAndTag.lastIndex(of: ":") {
        tag = String(repoAndTag[repoAndTag.index(after: lastColon)...])
        let repoWithoutTag = String(repoAndTag[..<lastColon])
        remaining = String(remaining[...firstSlash]) + repoWithoutTag
      }
    }

    // Split remaining into registry and repository
    guard let firstSlash = remaining.firstIndex(of: "/") else {
      throw ImageReferenceError.invalidFormat("Reference must contain registry and repository separated by /")
    }

    let registry = String(remaining[..<firstSlash]).lowercased()
    let repository = String(remaining[remaining.index(after: firstSlash)...])

    guard !registry.isEmpty else {
      throw ImageReferenceError.invalidRegistry("Registry is empty")
    }
    guard !repository.isEmpty else {
      throw ImageReferenceError.invalidRepository("Repository is empty")
    }
    guard repository.utf8.count <= 255 else {
      throw ImageReferenceError.invalidRepository("Repository exceeds the 255-byte OCI limit")
    }

    // Validate registry
    guard Self.isValidRegistry(registry) else {
      throw ImageReferenceError.invalidRegistry("'\(registry)' does not match expected hostname[:port] format")
    }

    // Validate repository (each path segment must match)
    guard repository.range(of: repositoryPattern, options: .regularExpression) != nil else {
      throw ImageReferenceError.invalidRepository(
        "'\(repository)' must contain only lowercase alphanumeric, dots, hyphens, underscores, and slashes"
      )
    }

    // Validate tag if present
    if let tag {
      guard tag.range(of: tagPattern, options: .regularExpression) != nil else {
        throw ImageReferenceError.invalidTag("'\(tag)' does not match expected tag format")
      }
    }

    // Validate digest if present
    if let digest {
      guard digest.range(of: digestPattern, options: .regularExpression) != nil else {
        throw ImageReferenceError.invalidDigest("'\(digest)' must be sha256:<64 hex chars>")
      }
    }

    return ImageReference(registry: registry, repository: repository, tag: tag, digest: digest)
  }

  /// Checks if the registry is in the insecure registries list
  func isInsecureAllowed(insecureRegistries: [String]) -> Bool {
    insecureRegistries.contains(registry)
  }

  private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
    (0x30 ... 0x39).contains(byte) || (0x61 ... 0x7A).contains(byte)
  }
}

enum RegistryCredentialValidator {
  static let maximumUsernameLength = 1024
  static let maximumPasswordLength = 16384

  static func loginError(registry: String, username: String, password: String) -> String? {
    if let registryError = registryError(registry) {
      return registryError
    }
    guard username.isEmpty == false else { return "Username is required" }
    guard password.isEmpty == false else { return "Password is required" }
    guard username.utf8.count <= maximumUsernameLength else {
      return "Username is too long (max \(maximumUsernameLength) UTF-8 bytes)"
    }
    guard password.utf8.count <= maximumPasswordLength else {
      return "Password is too long (max \(maximumPasswordLength) UTF-8 bytes)"
    }
    guard username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) == false else {
      return "Username must not contain control characters"
    }
    guard password.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) == false else {
      return "Password must not contain NUL, carriage return, or newline characters"
    }
    return nil
  }

  static func registryError(_ registry: String) -> String? {
    guard ImageReference.isValidRegistry(registry) else {
      return "Registry must be a lowercase hostname with an optional port between 1 and 65535"
    }
    return nil
  }
}
