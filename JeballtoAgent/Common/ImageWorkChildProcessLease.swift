import Darwin
import Foundation

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
