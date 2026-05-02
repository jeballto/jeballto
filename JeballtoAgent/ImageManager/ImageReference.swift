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
struct ImageReference: Equatable {
  let registry: String
  let repository: String
  let tag: String?
  let digest: String?

  /// Reconstructs the full reference string
  var fullReference: String {
    var ref = "\(registry)/\(repository)"
    if let digest {
      ref += "@\(digest)"
    } else if let tag {
      ref += ":\(tag)"
    }
    return ref
  }

  // MARK: - Validation patterns

  private static let registryPattern = "^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(:[0-9]{1,5})?$"
  private static let repositoryPattern = "^[a-z0-9]+([._/-][a-z0-9]+)*$"
  private static let tagPattern = "^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$"
  private static let digestPattern = "^sha256:[a-f0-9]{64}$"

  /// Parses an OCI image reference string into its components.
  ///
  /// Supported formats:
  /// - `registry/repo:tag`
  /// - `registry/repo@sha256:...`
  /// - `registry/repo` (no tag or digest)
  /// - `registry:port/repo:tag`
  static func parse(_ reference: String) throws -> ImageReference {
    let trimmed = reference.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      throw ImageReferenceError.invalidFormat("Reference is empty")
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
    if digest == nil {
      // Only parse tag if no digest. Find the last colon that is NOT part of a port number.
      // Registry ports look like: registry.example.com:5000/repo
      // Tags look like: registry.example.com/repo:tag
      // Strategy: split on first slash to separate registry from repo path,
      // then look for colon in the repo path for the tag.
      if let firstSlash = remaining.firstIndex(of: "/") {
        let repoAndTag = String(remaining[remaining.index(after: firstSlash)...])
        if let lastColon = repoAndTag.lastIndex(of: ":") {
          tag = String(repoAndTag[repoAndTag.index(after: lastColon)...])
          let repoWithoutTag = String(repoAndTag[..<lastColon])
          remaining = String(remaining[...firstSlash]) + repoWithoutTag
        }
      }
    }

    // Split remaining into registry and repository
    guard let firstSlash = remaining.firstIndex(of: "/") else {
      throw ImageReferenceError.invalidFormat("Reference must contain registry and repository separated by /")
    }

    let registry = String(remaining[..<firstSlash])
    let repository = String(remaining[remaining.index(after: firstSlash)...])

    guard !registry.isEmpty else {
      throw ImageReferenceError.invalidRegistry("Registry is empty")
    }
    guard !repository.isEmpty else {
      throw ImageReferenceError.invalidRepository("Repository is empty")
    }

    // Validate registry
    guard registry.range(of: registryPattern, options: .regularExpression) != nil else {
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
}
