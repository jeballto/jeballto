import Foundation

struct SystemResetRequest: Codable {
  let mode: String

  private static let validModes = ["soft", "hard"]

  func validate() -> (valid: Bool, error: String?) {
    guard Self.validModes.contains(mode) else {
      return (false, "Invalid mode '\(mode)'. Must be one of: \(Self.validModes.joined(separator: ", "))")
    }
    return (true, nil)
  }
}

struct SystemResetResponse: Codable {
  let mode: String
  let vmsDeleted: Int
  let vmsFailed: Int
  let imagesDeleted: Int
  let imagesFailed: Int
  let ipswCacheCleared: Bool
  let configDeleted: Bool
  let logsDeleted: Bool
  let willTerminate: Bool
  let errors: [String]?
}
