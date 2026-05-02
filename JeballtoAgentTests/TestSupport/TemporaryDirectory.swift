import Foundation

func withTemporaryDirectory<T>(
  prefix: String = "jeballto-tests",
  body: (String) async throws -> T
) async throws -> T {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  return try await body(directory.path)
}

func withTemporaryDirectory<T>(
  prefix: String = "jeballto-tests",
  body: (String) throws -> T
) throws -> T {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  return try body(directory.path)
}
