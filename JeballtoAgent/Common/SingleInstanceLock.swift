import Darwin
import Foundation

enum SingleInstanceLockError: Error, LocalizedError {
  case alreadyRunning(String)
  case directoryCreationFailed(path: String, message: String)
  case lockFileOpenFailed(path: String, message: String)
  case lockAcquisitionFailed(path: String, message: String)
  case lockFileUpdateFailed(path: String, message: String)

  var errorDescription: String? {
    switch self {
    case .alreadyRunning(let path):
      "Another JeballtoAgent process already holds the instance lock at \(path)"
    case .directoryCreationFailed(let path, let message):
      "Failed to prepare the instance-lock directory at \(path): \(message)"
    case .lockFileOpenFailed(let path, let message):
      "Failed to open the instance lock at \(path): \(message)"
    case .lockAcquisitionFailed(let path, let message):
      "Failed to acquire the instance lock at \(path): \(message)"
    case .lockFileUpdateFailed(let path, let message):
      "Failed to record the process ID in the instance lock at \(path): \(message)"
    }
  }
}

final class SingleInstanceLock {
  private var descriptor: Int32
  private var identity: SingleInstanceLockIdentity?

  init(path: String = SingleInstanceLock.defaultPath()) throws {
    let directory = (path as NSString).deletingLastPathComponent
    try Self.prepareDirectory(at: directory)

    let openedDescriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard openedDescriptor >= 0 else {
      throw SingleInstanceLockError.lockFileOpenFailed(path: path, message: Self.posixMessage())
    }
    descriptor = openedDescriptor
    identity = nil

    var status = stat()
    guard Darwin.fstat(openedDescriptor, &status) == 0 else {
      let message = Self.posixMessage()
      Darwin.close(openedDescriptor)
      descriptor = -1
      throw SingleInstanceLockError.lockFileOpenFailed(path: path, message: message)
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(openedDescriptor)
      descriptor = -1
      throw SingleInstanceLockError.lockFileOpenFailed(path: path, message: "Lock target is not a regular file")
    }
    let openedIdentity = SingleInstanceLockIdentity(device: status.st_dev, inode: status.st_ino)
    guard SingleInstanceLockRegistry.shared.claim(openedIdentity) else {
      Darwin.close(openedDescriptor)
      descriptor = -1
      throw SingleInstanceLockError.alreadyRunning(path)
    }
    identity = openedIdentity

    var fileLock = Darwin.flock()
    fileLock.l_type = Int16(F_WRLCK)
    fileLock.l_whence = Int16(SEEK_SET)
    fileLock.l_start = 0
    fileLock.l_len = 0
    guard Darwin.fcntl(openedDescriptor, F_SETLK, &fileLock) == 0 else {
      let errorCode = errno
      SingleInstanceLockRegistry.shared.release(openedIdentity)
      identity = nil
      Darwin.close(openedDescriptor)
      descriptor = -1
      if errorCode == EACCES || errorCode == EAGAIN {
        throw SingleInstanceLockError.alreadyRunning(path)
      }
      throw SingleInstanceLockError.lockAcquisitionFailed(
        path: path,
        message: Self.posixMessage(errorCode)
      )
    }

    guard Darwin.fchmod(openedDescriptor, S_IRUSR | S_IWUSR) == 0 else {
      let message = Self.posixMessage()
      release()
      throw SingleInstanceLockError.lockFileUpdateFailed(path: path, message: message)
    }

    do {
      try Self.recordProcessIdentifier(getpid(), in: openedDescriptor)
    } catch {
      release()
      throw SingleInstanceLockError.lockFileUpdateFailed(path: path, message: error.localizedDescription)
    }
  }

  deinit {
    release()
  }

  func release() {
    guard descriptor >= 0 else { return }
    var fileLock = Darwin.flock()
    fileLock.l_type = Int16(F_UNLCK)
    fileLock.l_whence = Int16(SEEK_SET)
    fileLock.l_start = 0
    fileLock.l_len = 0
    _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
    Darwin.close(descriptor)
    descriptor = -1
    if let identity {
      SingleInstanceLockRegistry.shared.release(identity)
      self.identity = nil
    }
  }

  var closesDescriptorOnExec: Bool {
    guard descriptor >= 0 else { return true }
    return Darwin.fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0
  }

  static func defaultPath() -> String {
    "\(NSHomeDirectory())/Library/Application Support/Jeballto/agent.lock"
  }

  private static func prepareDirectory(at path: String) throws {
    var status = stat()
    let result = path.withCString { Darwin.lstat($0, &status) }
    if result == 0 {
      guard status.st_mode & S_IFMT == S_IFDIR else {
        throw SingleInstanceLockError.directoryCreationFailed(
          path: path,
          message: "Instance-lock directory must not be a symbolic link or regular file"
        )
      }
    } else {
      guard errno == ENOENT else {
        throw SingleInstanceLockError.directoryCreationFailed(path: path, message: posixMessage())
      }
      do {
        try FileManager.default.createDirectory(
          atPath: path,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        throw SingleInstanceLockError.directoryCreationFailed(path: path, message: error.localizedDescription)
      }
      guard path.withCString({ Darwin.lstat($0, &status) }) == 0,
            status.st_mode & S_IFMT == S_IFDIR else
      {
        throw SingleInstanceLockError.directoryCreationFailed(
          path: path,
          message: "Created instance-lock path is not a regular directory"
        )
      }
    }

    do {
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    } catch {
      throw SingleInstanceLockError.directoryCreationFailed(path: path, message: error.localizedDescription)
    }
  }

  private static func recordProcessIdentifier(_ processIdentifier: pid_t, in descriptor: Int32) throws {
    guard Darwin.ftruncate(descriptor, 0) == 0,
          Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else
    {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    let data = Data("\(processIdentifier)\n".utf8)
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { buffer -> Int in
        guard let baseAddress = buffer.baseAddress else { return 0 }
        return Darwin.write(descriptor, baseAddress.advanced(by: offset), buffer.count - offset)
      }
      if written > 0 {
        offset += written
      } else if written < 0, errno == EINTR {
        continue
      } else {
        let code = written < 0 ? errno : EIO
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
      }
    }
  }

  private static func posixMessage(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
  }
}

private struct SingleInstanceLockIdentity: Hashable {
  let device: dev_t
  let inode: ino_t
}

private final class SingleInstanceLockRegistry: @unchecked Sendable {
  static let shared = SingleInstanceLockRegistry()

  private let lock = NSLock()
  private var heldIdentities: Set<SingleInstanceLockIdentity> = []

  func claim(_ identity: SingleInstanceLockIdentity) -> Bool {
    lock.withLock { heldIdentities.insert(identity).inserted }
  }

  func release(_ identity: SingleInstanceLockIdentity) {
    lock.withLock { _ = heldIdentities.remove(identity) }
  }
}
