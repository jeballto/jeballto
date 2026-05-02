import Foundation

// MARK: - Token Masking

/// Masks a token for safe logging, showing only first 4 and last 4 characters
func maskToken(_ token: String) -> String {
  guard token.count > 8 else { return "****" }
  let prefix = token.prefix(4)
  let suffix = token.suffix(4)
  return "\(prefix)****\(suffix)"
}

// MARK: - VM Name Validation

enum VMNameValidator {
  /// Allowed characters for VM names: alphanumeric, hyphens, underscores, spaces, dots
  private static let allowedCharacters = CharacterSet.alphanumerics
    .union(CharacterSet(charactersIn: "-_. "))

  /// Validates a VM name: non-empty, max 100 chars, allowed characters only
  static func validate(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 100 else { return false }
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    return trimmed.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
  }
}

// MARK: - Shared Date Formatter

/// Thread-safe ISO8601 date formatter for API responses
let iso8601Formatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  return formatter
}()
