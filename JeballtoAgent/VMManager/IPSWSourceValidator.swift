import Foundation

enum IPSWSourceValidationError: Error, LocalizedError {
  case invalid(String)

  var errorDescription: String? {
    switch self {
    case .invalid(let message): "Invalid IPSW source: \(message)"
    }
  }
}

enum IPSWSourceValidator {
  static let maximumSourceLength = 8192
  static let maximumLocalPathLength = 4096

  static func normalized(_ source: String?) throws -> String? {
    guard let source else { return nil }
    guard source.isEmpty == false else {
      throw IPSWSourceValidationError.invalid("source must not be empty; omit it to download the latest macOS")
    }
    guard source.utf8.count <= maximumSourceLength else {
      throw IPSWSourceValidationError.invalid("source exceeds \(maximumSourceLength) UTF-8 bytes")
    }
    guard containsControlCharacters(source) == false else {
      throw IPSWSourceValidationError.invalid("source must not contain control characters")
    }

    let lowered = source.lowercased()
    if lowered.hasPrefix("http://") {
      throw IPSWSourceValidationError.invalid("HTTP is not supported; use HTTPS or a local file path")
    }

    if let components = URLComponents(string: source), let scheme = components.scheme?.lowercased() {
      switch scheme {
      case "https":
        guard let host = components.host, host.isEmpty == false else {
          throw IPSWSourceValidationError.invalid("HTTPS URL must include a host")
        }
        guard components.user == nil, components.password == nil else {
          throw IPSWSourceValidationError.invalid("HTTPS URL must not contain embedded credentials")
        }
        guard components.fragment == nil else {
          throw IPSWSourceValidationError.invalid("HTTPS URL must not contain a fragment")
        }
        if let port = components.port, (1 ... 65535).contains(port) == false {
          throw IPSWSourceValidationError.invalid("HTTPS URL contains an invalid port")
        }
        guard URL(string: source) != nil else {
          throw IPSWSourceValidationError.invalid("HTTPS URL is malformed")
        }
        return source

      case "file":
        guard lowered.hasPrefix("file://") else {
          throw IPSWSourceValidationError.invalid("file URL must use the file:// form")
        }
        guard components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else
        {
          throw IPSWSourceValidationError.invalid("file URL must not contain credentials, a port, query, or fragment")
        }
        if let host = components.host, host.isEmpty == false, host.lowercased() != "localhost" {
          throw IPSWSourceValidationError.invalid("file URL host must be empty or localhost")
        }
        guard let url = URL(string: source), url.isFileURL else {
          throw IPSWSourceValidationError.invalid("file URL is malformed")
        }
        return try validateLocalPath(url.path)

      case "http":
        throw IPSWSourceValidationError.invalid("HTTP is not supported; use HTTPS or a local file path")

      default:
        throw IPSWSourceValidationError.invalid("unsupported URL scheme '\(scheme)'")
      }
    }

    return try validateLocalPath(source)
  }

  static func logDescription(_ source: String) -> String {
    guard var components = URLComponents(string: source), components.scheme?.lowercased() == "https" else {
      return source
    }
    let hadQuery = components.query != nil
    components.query = nil
    let sanitized = components.string ?? source
    return hadQuery ? "\(sanitized) [query omitted]" : sanitized
  }

  private static func validateLocalPath(_ path: String) throws -> String {
    guard path.hasPrefix("/") else {
      throw IPSWSourceValidationError.invalid("local path must be absolute")
    }
    guard path.utf8.count <= maximumLocalPathLength else {
      throw IPSWSourceValidationError.invalid("local path exceeds \(maximumLocalPathLength) UTF-8 bytes")
    }
    guard containsControlCharacters(path) == false else {
      throw IPSWSourceValidationError.invalid("local path must not contain control characters")
    }
    return path
  }

  private static func containsControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}
