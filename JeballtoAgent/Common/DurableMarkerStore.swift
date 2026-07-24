import Darwin
import Foundation

enum DurableMarkerStoreError: Error, LocalizedError {
  case invalidPath(String)
  case invalidMaximumSize(Int)
  case parentOpenFailed(path: String, code: Int32)
  case parentIsNotDirectory(String)
  case invalidTarget(path: String, reason: String)
  case temporaryOpenFailed(path: String, code: Int32)
  case permissionUpdateFailed(path: String, code: Int32)
  case writeFailed(path: String, code: Int32)
  case prePublishSyncFailed(path: String, code: Int32)
  case closeFailed(path: String, code: Int32)
  case publishFailed(path: String, code: Int32)
  case readOpenFailed(path: String, code: Int32)
  case readFailed(path: String, code: Int32)
  case payloadTooLarge(path: String, maximum: Int)
  case removeFailed(path: String, code: Int32)

  var errorDescription: String? {
    switch self {
    case .invalidPath(let path):
      "Durable file path must include a parent directory and file name: \(path)"
    case .invalidMaximumSize(let maximum):
      "Durable file maximum size must not be negative: \(maximum)"
    case .parentOpenFailed(let path, let code):
      "Failed to open durable file parent directory at \(path): \(Self.posixMessage(code))"
    case .parentIsNotDirectory(let path):
      "Durable file parent path is not a directory: \(path)"
    case .invalidTarget(let path, let reason):
      "Invalid durable file target at \(path): \(reason)"
    case .temporaryOpenFailed(let path, let code):
      "Failed to create durable temporary file for \(path): \(Self.posixMessage(code))"
    case .permissionUpdateFailed(let path, let code):
      "Failed to secure durable temporary file for \(path): \(Self.posixMessage(code))"
    case .writeFailed(let path, let code):
      "Failed to write durable file data for \(path): \(Self.posixMessage(code))"
    case .prePublishSyncFailed(let path, let code):
      "Failed to sync durable temporary file for \(path): \(Self.posixMessage(code))"
    case .closeFailed(let path, let code):
      "Failed to close durable temporary file for \(path): \(Self.posixMessage(code))"
    case .publishFailed(let path, let code):
      "Failed to atomically publish durable file at \(path): \(Self.posixMessage(code))"
    case .readOpenFailed(let path, let code):
      "Failed to open durable file at \(path): \(Self.posixMessage(code))"
    case .readFailed(let path, let code):
      "Failed to read durable file at \(path): \(Self.posixMessage(code))"
    case .payloadTooLarge(let path, let maximum):
      "Durable file at \(path) exceeds the \(maximum)-byte limit"
    case .removeFailed(let path, let code):
      "Failed to remove durable file at \(path): \(Self.posixMessage(code))"
    }
  }

  private static func posixMessage(_ code: Int32) -> String {
    String(cString: strerror(code))
  }
}

struct DurableFilePublication: Sendable {
  let postPublishWarning: String?
}

/// Crash-safe IO for small transaction markers and other bounded JSON state files.
///
/// Every failure that can prevent publication is reported before `renameat`. Once rename succeeds,
/// the new state is visible and post-publish sync failures are returned only as warnings so callers
/// never roll back an already-published transaction.
enum DurableMarkerStore {
  typealias PostPublishSync = @Sendable (_ parentDescriptor: Int32) throws -> Void

  @discardableResult
  static func writeDataAtomically(
    _ data: Data,
    to path: String,
    maximumSize: Int,
    permissions: mode_t = 0o600,
    postPublishSync: PostPublishSync? = nil
  ) throws -> DurableFilePublication {
    guard maximumSize >= 0 else {
      throw DurableMarkerStoreError.invalidMaximumSize(maximumSize)
    }
    guard data.count <= maximumSize else {
      throw DurableMarkerStoreError.payloadTooLarge(path: path, maximum: maximumSize)
    }

    let target = try split(path)
    let parentDescriptor = try openParentDirectory(target.parentPath)
    defer { _ = Darwin.close(parentDescriptor) }
    try validateTarget(parentDescriptor: parentDescriptor, name: target.name, path: path)

    let temporaryName = ".\(target.name).\(UUID().uuidString).tmp"
    let temporaryDescriptor = temporaryName.withCString { name in
      Darwin.openat(parentDescriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, permissions)
    }
    guard temporaryDescriptor >= 0 else {
      throw DurableMarkerStoreError.temporaryOpenFailed(path: path, code: errno)
    }

    var descriptorIsOpen = true
    var temporaryExists = true
    defer {
      if descriptorIsOpen { _ = Darwin.close(temporaryDescriptor) }
      if temporaryExists {
        temporaryName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) }
      }
    }

    guard Darwin.fchmod(temporaryDescriptor, permissions) == 0 else {
      throw DurableMarkerStoreError.permissionUpdateFailed(path: path, code: errno)
    }
    try writeAll(data, descriptor: temporaryDescriptor, path: path)
    try syncBeforePublish(temporaryDescriptor, path: path)

    if Darwin.close(temporaryDescriptor) != 0 {
      descriptorIsOpen = false
      throw DurableMarkerStoreError.closeFailed(path: path, code: errno)
    }
    descriptorIsOpen = false

    let renameResult = temporaryName.withCString { temporary in
      target.name.withCString { destination in
        Darwin.renameat(parentDescriptor, temporary, parentDescriptor, destination)
      }
    }
    guard renameResult == 0 else {
      throw DurableMarkerStoreError.publishFailed(path: path, code: errno)
    }
    temporaryExists = false

    do {
      if let postPublishSync {
        try postPublishSync(parentDescriptor)
      } else {
        try syncDescriptor(parentDescriptor)
      }
      return DurableFilePublication(postPublishWarning: nil)
    } catch {
      let warning = "Durable file at \(path) was published, but its parent directory sync failed: "
        + error.localizedDescription
      logWarning(warning, category: "DurableMarkerStore")
      return DurableFilePublication(postPublishWarning: warning)
    }
  }

  static func readDataIfPresent(from path: String, maximumSize: Int) throws -> Data? {
    guard maximumSize >= 0 else {
      throw DurableMarkerStoreError.invalidMaximumSize(maximumSize)
    }
    let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else {
      let code = errno
      if code == ENOENT { return nil }
      throw DurableMarkerStoreError.readOpenFailed(path: path, code: code)
    }
    defer { _ = Darwin.close(descriptor) }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
      throw DurableMarkerStoreError.readFailed(path: path, code: errno)
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw DurableMarkerStoreError.invalidTarget(path: path, reason: "expected a regular file")
    }
    guard status.st_size >= 0, UInt64(status.st_size) <= UInt64(maximumSize) else {
      throw DurableMarkerStoreError.payloadTooLarge(path: path, maximum: maximumSize)
    }

    var result = Data()
    result.reserveCapacity(Int(status.st_size))
    var buffer = [UInt8](repeating: 0, count: max(1, min(64 * 1024, maximumSize)))
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw DurableMarkerStoreError.readFailed(path: path, code: errno)
      }
      guard count <= maximumSize, result.count <= maximumSize - count else {
        throw DurableMarkerStoreError.payloadTooLarge(path: path, maximum: maximumSize)
      }
      result.append(contentsOf: buffer.prefix(count))
    }
    return result
  }

  @discardableResult
  static func removeIfPresent(
    at path: String,
    postPublishSync: PostPublishSync? = nil
  ) throws -> DurableFilePublication? {
    let target = try split(path)
    let parentDescriptor: Int32
    do {
      parentDescriptor = try openParentDirectory(target.parentPath)
    } catch let error as DurableMarkerStoreError {
      if case .parentOpenFailed(_, let code) = error, code == ENOENT {
        return nil
      }
      throw error
    }
    defer { _ = Darwin.close(parentDescriptor) }

    var status = stat()
    let inspectResult = target.name.withCString {
      Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    if inspectResult != 0 {
      let code = errno
      if code == ENOENT { return nil }
      throw DurableMarkerStoreError.readFailed(path: path, code: code)
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw DurableMarkerStoreError.invalidTarget(path: path, reason: "expected a regular file")
    }

    let removeResult = target.name.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
    guard removeResult == 0 else {
      throw DurableMarkerStoreError.removeFailed(path: path, code: errno)
    }

    do {
      if let postPublishSync {
        try postPublishSync(parentDescriptor)
      } else {
        try syncDescriptor(parentDescriptor)
      }
      return DurableFilePublication(postPublishWarning: nil)
    } catch {
      let warning = "Durable file at \(path) was removed, but its parent directory sync failed: "
        + error.localizedDescription
      logWarning(warning, category: "DurableMarkerStore")
      return DurableFilePublication(postPublishWarning: warning)
    }
  }

  static func syncDescriptorForTesting(_ descriptor: Int32) throws {
    try syncDescriptor(descriptor)
  }

  private static func split(_ path: String) throws -> (parentPath: String, name: String) {
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    let parentPath = url.deletingLastPathComponent().path
    guard name.isEmpty == false, name != ".", name != "..", parentPath.isEmpty == false else {
      throw DurableMarkerStoreError.invalidPath(path)
    }
    return (parentPath, name)
  }

  private static func openParentDirectory(_ path: String) throws -> Int32 {
    let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else {
      throw DurableMarkerStoreError.parentOpenFailed(path: path, code: errno)
    }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
      _ = Darwin.close(descriptor)
      throw DurableMarkerStoreError.parentIsNotDirectory(path)
    }
    return descriptor
  }

  private static func validateTarget(parentDescriptor: Int32, name: String, path: String) throws {
    var status = stat()
    let result = name.withCString {
      Darwin.fstatat(parentDescriptor, $0, &status, AT_SYMLINK_NOFOLLOW)
    }
    if result == 0 {
      guard status.st_mode & S_IFMT == S_IFREG else {
        throw DurableMarkerStoreError.invalidTarget(path: path, reason: "expected a regular file or absent target")
      }
      return
    }
    let code = errno
    guard code == ENOENT else {
      throw DurableMarkerStoreError.readFailed(path: path, code: code)
    }
  }

  private static func writeAll(_ data: Data, descriptor: Int32, path: String) throws {
    try data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          throw DurableMarkerStoreError.writeFailed(path: path, code: errno)
        }
        guard written > 0 else {
          throw DurableMarkerStoreError.writeFailed(path: path, code: EIO)
        }
        offset += written
      }
    }
  }

  private static func syncBeforePublish(_ descriptor: Int32, path: String) throws {
    do {
      try syncDescriptor(descriptor)
    } catch {
      let code = (error as? POSIXSyncError)?.code ?? EIO
      throw DurableMarkerStoreError.prePublishSyncFailed(path: path, code: code)
    }
  }

  private static func syncDescriptor(_ descriptor: Int32) throws {
    while true {
      if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return }
      let code = errno
      if code == EINTR { continue }
      let canFallBack = code == EINVAL || code == ENOTSUP || code == EOPNOTSUPP
      guard canFallBack else {
        throw POSIXSyncError(code: code)
      }
      break
    }
    while Darwin.fsync(descriptor) != 0 {
      if errno == EINTR { continue }
      throw POSIXSyncError(code: errno)
    }
  }
}

private struct POSIXSyncError: Error, LocalizedError {
  let code: Int32

  var errorDescription: String? {
    String(cString: strerror(code))
  }
}
