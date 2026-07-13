import Foundation

// FileHandle can autorelease every Data returned by a long read loop until its surrounding
// worker drains. Bound each chunk to its own pool so large image and log files keep constant memory use.
func readFileChunk(from handle: FileHandle, upToCount count: Int) throws -> Data? {
  try autoreleasepool {
    try handle.read(upToCount: count)
  }
}

// Bundled tools must not inherit debugger-injected dynamic libraries from the app process.
// Custom tools keep the caller environment because their dependencies may rely on DYLD settings.
func bundledToolEnvironment(
  from environment: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
  environment.filter { key, _ in
    key.hasPrefix("DYLD_") == false
  }
}

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
    guard !trimmed.isEmpty, trimmed == name else { return false }
    return trimmed.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
  }
}

// MARK: - Date Formatting

/// Formats a date for API responses without sharing formatter instances across threads.
func iso8601String(from date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  return formatter.string(from: date)
}
