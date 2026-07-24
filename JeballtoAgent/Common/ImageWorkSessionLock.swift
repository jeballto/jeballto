import Darwin
import Foundation

enum ImageWorkSessionLockError: Error, LocalizedError {
  case invalidSessionPath(String)
  case directoryPreparationFailed(path: String, message: String)
  case lockFileOpenFailed(path: String, message: String)
  case unsafeLockFile(path: String, message: String)
  case lockUnavailable(path: String)
  case lockAcquisitionFailed(path: String, message: String)

  var errorDescription: String? {
    switch self {
    case .invalidSessionPath(let path):
      "Invalid image work session path: \(path)"
    case .directoryPreparationFailed(let path, let message):
      "Failed to prepare image work session directory at \(path): \(message)"
    case .lockFileOpenFailed(let path, let message):
      "Failed to open image work session lock at \(path): \(message)"
    case .unsafeLockFile(let path, let message):
      "Unsafe image work session lock at \(path): \(message)"
    case .lockUnavailable(let path):
      "Another process already owns the image work session at \(path)"
    case .lockAcquisitionFailed(let path, let message):
      "Failed to acquire image work session lock at \(path): \(message)"
    }
  }
}

enum ImageWorkSessionCleanupResult: Equatable {
  case removed
  case active
  case childLaunchInProgress
  case legacyWithoutLock
  case preserved(reason: String)
  case removalFailed(message: String)
}

/// Owns the advisory lock for one process-scoped image work directory.
///
/// The shared session descriptor is kept open for the lifetime of this object. Image child processes acquire their
/// own shared lease through ``ImageWorkChildProcessLease`` before executing the requested tool. Cleanup requires an
/// exclusive lease, so a child keeps the session alive even if the agent exits unexpectedly.
final class ImageWorkSessionLock: @unchecked Sendable {
  static let lockFileName = ".session.lock"
  static let ownerLockFileName = ".session.owner.lock"
  static let protectedEntryNames: Set<String> = [lockFileName, ownerLockFileName]

  let sessionURL: URL

  private let descriptorLock = NSLock()
  private var sessionDescriptor: Int32
  private var ownerDescriptor: Int32

  init(sessionURL: URL) throws {
    let standardizedSessionURL = sessionURL.standardizedFileURL
    let sessionsURL = standardizedSessionURL.deletingLastPathComponent()
    let imageWorkURL = sessionsURL.deletingLastPathComponent()
    guard sessionsURL.lastPathComponent == "sessions",
          imageWorkURL.path != sessionsURL.path,
          sessionsURL.path != standardizedSessionURL.path else
    {
      throw ImageWorkSessionLockError.invalidSessionPath(standardizedSessionURL.path)
    }

    try Self.prepareDirectory(at: imageWorkURL, withIntermediateDirectories: true)
    try Self.prepareDirectory(at: sessionsURL, withIntermediateDirectories: false)
    try Self.prepareDirectory(at: standardizedSessionURL, withIntermediateDirectories: false)

    let lockPath = standardizedSessionURL.appendingPathComponent(Self.lockFileName).path
    let ownerLockPath = standardizedSessionURL.appendingPathComponent(Self.ownerLockFileName).path
    var openedSessionDescriptor: Int32 = -1
    var openedOwnerDescriptor: Int32 = -1

    do {
      openedSessionDescriptor = try Self.openLockFile(at: lockPath, create: true)
      guard imageWorkFlock(openedSessionDescriptor, LOCK_SH | LOCK_NB) == 0 else {
        let errorCode = errno
        if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
          throw ImageWorkSessionLockError.lockUnavailable(path: standardizedSessionURL.path)
        }
        throw ImageWorkSessionLockError.lockAcquisitionFailed(
          path: lockPath,
          message: Self.posixMessage(errorCode)
        )
      }
      openedOwnerDescriptor = try Self.openLockFile(at: ownerLockPath, create: true)
      guard imageWorkFlock(openedOwnerDescriptor, LOCK_EX | LOCK_NB) == 0 else {
        let errorCode = errno
        if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
          throw ImageWorkSessionLockError.lockUnavailable(path: standardizedSessionURL.path)
        }
        throw ImageWorkSessionLockError.lockAcquisitionFailed(
          path: ownerLockPath,
          message: Self.posixMessage(errorCode)
        )
      }
      guard Darwin.fchmod(openedSessionDescriptor, S_IRUSR | S_IWUSR) == 0 else {
        throw ImageWorkSessionLockError.unsafeLockFile(path: lockPath, message: Self.posixMessage())
      }
      guard Darwin.fchmod(openedOwnerDescriptor, S_IRUSR | S_IWUSR) == 0 else {
        throw ImageWorkSessionLockError.unsafeLockFile(path: ownerLockPath, message: Self.posixMessage())
      }
    } catch {
      if openedOwnerDescriptor >= 0 {
        _ = imageWorkFlock(openedOwnerDescriptor, LOCK_UN)
        Darwin.close(openedOwnerDescriptor)
      }
      if openedSessionDescriptor >= 0 {
        _ = imageWorkFlock(openedSessionDescriptor, LOCK_UN)
        Darwin.close(openedSessionDescriptor)
      }
      throw error
    }

    self.sessionURL = standardizedSessionURL
    sessionDescriptor = openedSessionDescriptor
    ownerDescriptor = openedOwnerDescriptor
  }

  deinit {
    release()
  }

  func release() {
    descriptorLock.withLock {
      if ownerDescriptor >= 0 {
        _ = imageWorkFlock(ownerDescriptor, LOCK_UN)
        Darwin.close(ownerDescriptor)
        ownerDescriptor = -1
      }
      if sessionDescriptor >= 0 {
        _ = imageWorkFlock(sessionDescriptor, LOCK_UN)
        Darwin.close(sessionDescriptor)
        sessionDescriptor = -1
      }
    }
  }

  func childProcessLease(wrapperExecutableURL: URL) throws -> ImageWorkChildProcessLease {
    try descriptorLock.withLock {
      guard sessionDescriptor >= 0, ownerDescriptor >= 0 else {
        throw ImageWorkSessionLockError.lockUnavailable(path: sessionURL.path)
      }
      return ImageWorkChildProcessLease(
        sessionURL: sessionURL,
        wrapperExecutableURL: wrapperExecutableURL
      )
    }
  }

  static func removeSessionIfInactive(at sessionURL: URL) -> ImageWorkSessionCleanupResult {
    let standardizedSessionURL = sessionURL.standardizedFileURL
    guard isRealDirectory(at: standardizedSessionURL.path) else {
      return .preserved(reason: "session path is missing, symbolic, or not a directory")
    }

    let lockPath = standardizedSessionURL.appendingPathComponent(lockFileName).path
    let descriptor: Int32
    do {
      descriptor = try openLockFile(at: lockPath, create: false)
    } catch {
      var status = stat()
      if lockPath.withCString({ Darwin.lstat($0, &status) }) != 0, errno == ENOENT {
        return .legacyWithoutLock
      }
      return .preserved(reason: "session lock cannot be opened safely: \(error.localizedDescription)")
    }
    defer { Darwin.close(descriptor) }

    guard imageWorkFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let errorCode = errno
      if errorCode == EWOULDBLOCK || errorCode == EAGAIN {
        return .active
      }
      return .preserved(reason: "session lock probe failed: \(posixMessage(errorCode))")
    }
    defer { _ = imageWorkFlock(descriptor, LOCK_UN) }

    if ImageWorkChildProcessLease.hasValidLaunchMarker(in: standardizedSessionURL) {
      return .childLaunchInProgress
    }

    do {
      try FileManager.default.removeItem(at: standardizedSessionURL)
      return .removed
    } catch {
      return .removalFailed(message: error.localizedDescription)
    }
  }

  static func containsLiveWork(at sessionURL: URL) -> Bool {
    let standardizedSessionURL = sessionURL.standardizedFileURL
    guard isRealDirectory(at: standardizedSessionURL.path) else { return false }
    let lockPath = standardizedSessionURL.appendingPathComponent(lockFileName).path
    guard let descriptor = try? openLockFile(at: lockPath, create: false) else { return false }
    defer { Darwin.close(descriptor) }

    guard imageWorkFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      return code == EWOULDBLOCK || code == EAGAIN
    }
    defer { _ = imageWorkFlock(descriptor, LOCK_UN) }
    return ImageWorkChildProcessLease.hasValidLaunchMarker(in: standardizedSessionURL)
  }

  static func isRealDirectory(at path: String) -> Bool {
    var status = stat()
    return path.withCString { Darwin.lstat($0, &status) } == 0
      && status.st_mode & S_IFMT == S_IFDIR
  }

  private static func prepareDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
    var status = stat()
    let initialResult = url.path.withCString { Darwin.lstat($0, &status) }
    if initialResult == 0 {
      guard status.st_mode & S_IFMT == S_IFDIR else {
        throw ImageWorkSessionLockError.directoryPreparationFailed(
          path: url.path,
          message: "path is a symbolic link or not a directory"
        )
      }
    } else {
      guard errno == ENOENT else {
        throw ImageWorkSessionLockError.directoryPreparationFailed(path: url.path, message: posixMessage())
      }
      do {
        try FileManager.default.createDirectory(
          at: url,
          withIntermediateDirectories: withIntermediateDirectories,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        throw ImageWorkSessionLockError.directoryPreparationFailed(
          path: url.path,
          message: error.localizedDescription
        )
      }
    }

    guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0,
          status.st_mode & S_IFMT == S_IFDIR else
    {
      throw ImageWorkSessionLockError.directoryPreparationFailed(
        path: url.path,
        message: "created path is a symbolic link or not a directory"
      )
    }

    do {
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    } catch {
      throw ImageWorkSessionLockError.directoryPreparationFailed(path: url.path, message: error.localizedDescription)
    }
  }

  static func openLockFile(at path: String, create: Bool) throws -> Int32 {
    let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0)
    let descriptor = Darwin.open(path, flags, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw ImageWorkSessionLockError.lockFileOpenFailed(path: path, message: posixMessage())
    }
    do {
      try validateLockFile(descriptor: descriptor, path: path)
      return descriptor
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  static func validateLockFile(descriptor: Int32, path: String) throws {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
      throw ImageWorkSessionLockError.unsafeLockFile(path: path, message: posixMessage())
    }
    guard status.st_mode & S_IFMT == S_IFREG,
          status.st_nlink == 1,
          status.st_uid == geteuid() else
    {
      throw ImageWorkSessionLockError.unsafeLockFile(
        path: path,
        message: "lock target must be an owned regular file with one link"
      )
    }
  }

  private static func posixMessage(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
  }
}
