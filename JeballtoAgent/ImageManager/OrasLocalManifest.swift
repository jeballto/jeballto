import CryptoKit
import Darwin
import Foundation

/// Reads and validates the local OCI manifest used for registry publication.
enum OrasLocalManifest {
  private static let maximumSize = 16 * 1024 * 1024

  /// Returns the SHA-256 digest and byte size of a validated local manifest.
  static func metadata(atPath path: String) throws -> (digest: String, size: UInt64) {
    try Task.checkCancellation()
    let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else {
      throw OrasError.invalidOutput(
        "Failed to open local manifest at \(path): \(String(cString: strerror(errno)))"
      )
    }
    defer { _ = Darwin.close(descriptor) }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
      throw OrasError.invalidOutput(
        "Failed to inspect local manifest at \(path): \(String(cString: strerror(errno)))"
      )
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw OrasError.invalidOutput("Local manifest at \(path) must be a regular file")
    }
    guard status.st_size > 0, UInt64(status.st_size) <= UInt64(maximumSize) else {
      throw OrasError.invalidOutput(
        "Local manifest at \(path) must contain 1...\(maximumSize) bytes"
      )
    }

    let expectedSize = UInt64(status.st_size)
    var bytesRead: UInt64 = 0
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
      try Task.checkCancellation()
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw OrasError.invalidOutput(
          "Failed to read local manifest at \(path): \(String(cString: strerror(errno)))"
        )
      }
      let (newBytesRead, overflow) = bytesRead.addingReportingOverflow(UInt64(count))
      guard overflow == false, newBytesRead <= UInt64(maximumSize) else {
        throw OrasError.invalidOutput(
          "Local manifest at \(path) exceeds the \(maximumSize)-byte limit"
        )
      }
      hasher.update(data: Data(buffer.prefix(count)))
      bytesRead = newBytesRead
    }
    guard bytesRead == expectedSize else {
      throw OrasError.invalidOutput(
        "Local manifest at \(path) changed while it was being read: expected \(expectedSize) bytes, got \(bytesRead)"
      )
    }
    let digest = "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (digest, bytesRead)
  }
}
