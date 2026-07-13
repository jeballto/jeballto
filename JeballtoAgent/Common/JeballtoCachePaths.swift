import Darwin
import Foundation

@_silgen_name("flock")
private func imageWorkFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Shared cache locations for disposable Jeballto data.
enum JeballtoCachePaths {
  private static let imageWorkSessionId = UUID().uuidString

  static var root: URL {
    if let override = ProcessInfo.processInfo.environment["JEBALLTO_CACHE_DIR"],
       let overrideURL = validatedOverrideURL(for: override)
    {
      return overrideURL
    }
    return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Jeballto", isDirectory: true)
  }

  static func validatedOverrideURL(for path: String) -> URL? {
    guard path.isEmpty == false, path.hasPrefix("/") else { return nil }

    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    let homeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL.path
    guard url.path != "/", url.path != homeDirectory else { return nil }
    return url
  }

  static var ipswCache: URL {
    root.appendingPathComponent("IPSWCache", isDirectory: true)
  }

  static var imageWork: URL {
    root.appendingPathComponent("ImageWork", isDirectory: true)
  }

  static var imageWorkSession: URL {
    imageWork
      .appendingPathComponent("sessions", isDirectory: true)
      .appendingPathComponent(imageWorkSessionId, isDirectory: true)
  }
}

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

enum ImageWorkChildProcessLeaseError: Error, LocalizedError {
  case missingExecutable
  case invalidWrapperExecutable(String)
  case markerCreationFailed(path: String, message: String)
  case invalidInvocation(String)
  case lockFailed(path: String, message: String)
  case markerValidationFailed(String)
  case markerRemovalFailed(path: String, message: String)
  case descriptorInheritanceFailed(String)
  case executionFailed(path: String, message: String)

  var errorDescription: String? {
    switch self {
    case .missingExecutable:
      "Cannot create an image child lease for a process without an executable"
    case .invalidWrapperExecutable(let path):
      "Image child wrapper executable is invalid: \(path)"
    case .markerCreationFailed(let path, let message):
      "Failed to create image child launch marker at \(path): \(message)"
    case .invalidInvocation(let message):
      "Invalid image child wrapper invocation: \(message)"
    case .lockFailed(let path, let message):
      "Failed to acquire image child session lease at \(path): \(message)"
    case .markerValidationFailed(let path):
      "Image child launch marker is invalid: \(path)"
    case .markerRemovalFailed(let path, let message):
      "Failed to remove image child launch marker at \(path): \(message)"
    case .descriptorInheritanceFailed(let message):
      "Failed to preserve the image child session lease across exec: \(message)"
    case .executionFailed(let path, let message):
      "Failed to execute image child tool at \(path): \(message)"
    }
  }
}

/// Wraps an image tool so it holds a kernel-managed shared lease on the work session across `exec`.
struct ImageWorkChildProcessLease: Sendable {
  static let wrapperArgument = "--jeballto-image-child-v1"
  static let markerPrefix = ".child-launch-"
  private static let markerMagic = "jeballto-image-child-launch-v1:"
  private static let maximumMarkerAge: TimeInterval = 300

  let sessionURL: URL
  let wrapperExecutableURL: URL

  func prepare(_ process: Process) throws -> ImageWorkChildLaunchReservation {
    guard let targetExecutableURL = process.executableURL else {
      throw ImageWorkChildProcessLeaseError.missingExecutable
    }
    guard wrapperExecutableURL.isFileURL, wrapperExecutableURL.path.isEmpty == false else {
      throw ImageWorkChildProcessLeaseError.invalidWrapperExecutable(wrapperExecutableURL.path)
    }

    let markerId = UUID()
    let markerURL = sessionURL.appendingPathComponent(Self.markerPrefix + markerId.uuidString)
    try Self.createMarker(at: markerURL, id: markerId)
    let targetArguments = process.arguments ?? []
    process.executableURL = wrapperExecutableURL
    process.arguments = [
      Self.wrapperArgument,
      sessionURL.appendingPathComponent(ImageWorkSessionLock.lockFileName).path,
      markerURL.path,
      targetExecutableURL.path,
    ] + targetArguments
    return ImageWorkChildLaunchReservation(markerURL: markerURL)
  }

  static func runWrapperIfRequested(arguments: [String]) -> Int32? {
    guard arguments.count >= 2, arguments[1] == wrapperArgument else { return nil }
    guard arguments.count >= 5 else {
      writeWrapperError(ImageWorkChildProcessLeaseError.invalidInvocation("missing required arguments"))
      return 126
    }

    let lockPath = arguments[2]
    let markerPath = arguments[3]
    let targetPath = arguments[4]
    let targetArguments = Array(arguments.dropFirst(5))
    do {
      let lockURL = URL(fileURLWithPath: lockPath).standardizedFileURL
      let markerURL = URL(fileURLWithPath: markerPath).standardizedFileURL
      guard lockURL.lastPathComponent == ImageWorkSessionLock.lockFileName,
            markerURL.deletingLastPathComponent() == lockURL.deletingLastPathComponent(),
            targetPath.hasPrefix("/") else
      {
        throw ImageWorkChildProcessLeaseError.invalidInvocation("paths do not identify one image work session")
      }
      let lease = try acquireKernelLease(lockPath: lockPath, blocking: true)
      guard validateMarker(atPath: markerPath) else {
        throw ImageWorkChildProcessLeaseError.markerValidationFailed(markerPath)
      }
      guard Darwin.unlink(markerPath) == 0 else {
        throw ImageWorkChildProcessLeaseError.markerRemovalFailed(
          path: markerPath,
          message: posixMessage()
        )
      }
      try lease.preserveAcrossExec()
      try execute(path: targetPath, arguments: targetArguments)
    } catch {
      writeWrapperError(error)
      return 126
    }
  }

  static func acquireKernelLeaseForTesting(sessionURL: URL) throws -> ImageWorkChildKernelLease {
    try acquireKernelLease(
      lockPath: sessionURL.appendingPathComponent(ImageWorkSessionLock.lockFileName).path,
      blocking: false
    )
  }

  static func hasValidLaunchMarker(in sessionURL: URL) -> Bool {
    let entries = (try? FileManager.default.contentsOfDirectory(
      at: sessionURL,
      includingPropertiesForKeys: nil
    )) ?? []
    return entries.contains { entry in
      guard entry.lastPathComponent.hasPrefix(markerPrefix) else { return false }
      return validateMarker(atPath: entry.path)
    }
  }

  private static func createMarker(at markerURL: URL, id: UUID) throws {
    let payload = Data((markerMagic + id.uuidString + "\n").utf8)
    let descriptor = Darwin.open(
      markerURL.path,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR
    )
    guard descriptor >= 0 else {
      throw ImageWorkChildProcessLeaseError.markerCreationFailed(
        path: markerURL.path,
        message: posixMessage()
      )
    }
    defer { Darwin.close(descriptor) }

    do {
      try payload.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
          let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
          if written < 0 {
            if errno == EINTR { continue }
            throw ImageWorkChildProcessLeaseError.markerCreationFailed(
              path: markerURL.path,
              message: posixMessage()
            )
          }
          guard written > 0 else {
            throw ImageWorkChildProcessLeaseError.markerCreationFailed(
              path: markerURL.path,
              message: posixMessage(EIO)
            )
          }
          offset += written
        }
      }
    } catch {
      _ = Darwin.unlink(markerURL.path)
      throw error
    }
  }

  private static func validateMarker(atPath path: String) -> Bool {
    let markerURL = URL(fileURLWithPath: path)
    let name = markerURL.lastPathComponent
    guard name.hasPrefix(markerPrefix),
          let id = UUID(uuidString: String(name.dropFirst(markerPrefix.count))) else
    {
      return false
    }

    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }

    var status = stat()
    let expected = Data((markerMagic + id.uuidString + "\n").utf8)
    guard Darwin.fstat(descriptor, &status) == 0,
          status.st_mode & S_IFMT == S_IFREG,
          status.st_nlink == 1,
          status.st_uid == geteuid(),
          status.st_size == off_t(expected.count) else
    {
      return false
    }
    let age = Date().timeIntervalSince1970 - TimeInterval(status.st_mtimespec.tv_sec)
    guard age >= -5, age <= maximumMarkerAge else { return false }

    var payload = Data(count: expected.count)
    let count = payload.withUnsafeMutableBytes { bytes in
      Darwin.read(descriptor, bytes.baseAddress, bytes.count)
    }
    return count == expected.count && payload == expected
  }

  private static func acquireKernelLease(
    lockPath: String,
    blocking: Bool
  ) throws -> ImageWorkChildKernelLease {
    let descriptor = try ImageWorkSessionLock.openLockFile(at: lockPath, create: false)
    let operation = LOCK_SH | (blocking ? 0 : LOCK_NB)
    while imageWorkFlock(descriptor, operation) != 0 {
      let code = errno
      if code == EINTR { continue }
      Darwin.close(descriptor)
      throw ImageWorkChildProcessLeaseError.lockFailed(path: lockPath, message: posixMessage(code))
    }
    return ImageWorkChildKernelLease(descriptor: descriptor)
  }

  private static func execute(path: String, arguments: [String]) throws -> Never {
    var pointers: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { argument in
      argument.withCString { strdup($0) }
    }
    guard pointers.allSatisfy({ $0 != nil }) else {
      pointers.compactMap { $0 }.forEach { free($0) }
      throw ImageWorkChildProcessLeaseError.executionFailed(path: path, message: "argument allocation failed")
    }
    pointers.append(nil)
    defer { pointers.compactMap { $0 }.forEach { free($0) } }
    let result: Int32 = path.withCString { executable in
      pointers.withUnsafeMutableBufferPointer { buffer in
        guard let baseAddress = buffer.baseAddress else { return Int32(-1) }
        return Darwin.execv(executable, baseAddress)
      }
    }
    precondition(result == -1)
    throw ImageWorkChildProcessLeaseError.executionFailed(path: path, message: posixMessage())
  }

  private static func writeWrapperError(_ error: Error) {
    let message = "Jeballto image child wrapper failed: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
  }

  private static func posixMessage(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
  }
}

final class ImageWorkChildLaunchReservation: @unchecked Sendable {
  private let lock = NSLock()
  private let markerURL: URL
  private var processWasLaunched = false

  init(markerURL: URL) {
    self.markerURL = markerURL
  }

  deinit {
    cancelBeforeLaunch()
  }

  func processDidLaunch() {
    lock.withLock {
      processWasLaunched = true
    }
  }

  func cancelBeforeLaunch() {
    let shouldRemove = lock.withLock { () -> Bool in
      guard processWasLaunched == false else { return false }
      processWasLaunched = true
      return true
    }
    if shouldRemove {
      _ = Darwin.unlink(markerURL.path)
    }
  }

  func processDidExit() {
    _ = Darwin.unlink(markerURL.path)
  }
}

final class ImageWorkChildKernelLease: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptor: Int32

  init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    release()
  }

  func preserveAcrossExec() throws {
    try lock.withLock {
      guard descriptor >= 0 else {
        throw ImageWorkChildProcessLeaseError.descriptorInheritanceFailed("lease is already closed")
      }
      let flags = Darwin.fcntl(descriptor, F_GETFD)
      guard flags >= 0, Darwin.fcntl(descriptor, F_SETFD, flags & ~FD_CLOEXEC) == 0 else {
        throw ImageWorkChildProcessLeaseError.descriptorInheritanceFailed(String(cString: strerror(errno)))
      }
    }
  }

  func release() {
    lock.withLock {
      guard descriptor >= 0 else { return }
      _ = imageWorkFlock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
      descriptor = -1
    }
  }
}
