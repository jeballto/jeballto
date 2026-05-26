import CryptoKit
import Darwin
import Foundation

enum ZstdError: Error, LocalizedError {
  case zstdNotFound(String)
  case commandFailed(exitCode: Int32, stderr: String)
  case timeout(String)
  case streamingFailed(String)

  var errorDescription: String? {
    switch self {
    case .zstdNotFound(let message): "zstd binary not found: \(message)"
    case .commandFailed(let code, let stderr): "zstd command failed (exit \(code)): \(stderr)"
    case .timeout(let message): "zstd command timed out: \(message)"
    case .streamingFailed(let message): "zstd streaming failed: \(message)"
    }
  }
}

struct ZstdRangeDigest: Equatable, Sendable {
  let size: UInt64
  let digest: String
  let isZero: Bool
}

struct ZstdClient: Sendable {
  private let configuredPath: String?
  private static let defaultTimeout: TimeInterval? = nil
  private static let maxOutputSize = 1024 * 1024
  private static let bufferSize = 1024 * 1024

  init(configuredPath: String? = nil) {
    self.configuredPath = configuredPath
  }

  init(config: ImageConfig) {
    configuredPath = config.zstdPath
  }

  func scanRange(inputPath: String, offset: UInt64, size: UInt64) throws -> ZstdRangeDigest {
    guard size > 0 else {
      return ZstdRangeDigest(size: 0, digest: Self.emptyDigest, isZero: true)
    }

    let inputHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
    Self.disableFileCache(for: inputHandle)
    defer { try? inputHandle.close() }
    try inputHandle.seek(toOffset: offset)

    var hasher = SHA256()
    var remaining = Int(size)
    var bytesRead: UInt64 = 0
    var isZero = true

    while remaining > 0 {
      let readSize = min(Self.bufferSize, remaining)
      guard let data = try inputHandle.read(upToCount: readSize), !data.isEmpty else {
        throw ZstdError.streamingFailed("Unexpected EOF in \(inputPath)")
      }
      hasher.update(data: data)
      if isZero, data.contains(where: { $0 != 0 }) {
        isZero = false
      }
      remaining -= data.count
      bytesRead += UInt64(data.count)
    }

    return ZstdRangeDigest(size: bytesRead, digest: Self.hexDigest(hasher.finalize()), isZero: isZero)
  }

  func compressRange(
    inputPath: String,
    offset: UInt64,
    size: UInt64,
    outputPath: String,
    level: Int = 3,
    timeout: TimeInterval? = nil
  ) async throws -> ZstdRangeDigest {
    let zstdPath = try resolveZstdPath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: zstdPath)
    process.arguments = ["-q", "-f", "-\(level)", "-", "-o", outputPath]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let streamState = ZstdStreamingState()

    let result: ProcessExecutionResult
    do {
      result = try await AsyncProcessRunner.run(
        process: process,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        options: AsyncProcessRunnerOptions(
          timeout: timeout ?? Self.defaultTimeout,
          timeoutDescription: "zstd compress",
          maxOutputSize: Self.maxOutputSize
        ),
        afterLaunch: { _ in
          DispatchQueue.global(qos: .userInitiated).async {
            do {
              let digest = try Self.writeRangeToPipe(
                inputPath: inputPath,
                offset: offset,
                size: size,
                pipe: stdinPipe
              )
              streamState.finish(digest)
            } catch {
              streamState.fail(error)
              ChildProcessTracker.shared.terminateIfRunning(process)
            }
            try? stdinPipe.fileHandleForWriting.close()
          }
        }
      )
    } catch let error as AsyncProcessRunnerError {
      switch error {
      case .launchFailed(let message):
        throw ZstdError.commandFailed(exitCode: -1, stderr: "Failed to launch zstd: \(message)")
      case .timeout(let message):
        throw ZstdError.timeout(message)
      }
    }

    guard result.exitCode == 0 else {
      let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
      throw ZstdError.commandFailed(exitCode: result.exitCode, stderr: stderr)
    }

    return try await streamState.result()
  }

  func decompressToFileRange(
    inputPath: String,
    destinationPath: String,
    offset: UInt64,
    timeout: TimeInterval? = nil
  ) async throws -> ZstdRangeDigest {
    let zstdPath = try resolveZstdPath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: zstdPath)
    process.arguments = ["-q", "-d", "-c", inputPath]
    process.standardInput = FileHandle.nullDevice

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let exitObserver = ZstdProcessExitObserver()
    let stderrCollector = ZstdLimitedPipeCollector(maxOutputSize: Self.maxOutputSize)
    let streamState = ZstdStreamingState()

    process.terminationHandler = { process in
      exitObserver.finish(process.terminationStatus)
    }
    stderrCollector.start(stderrPipe.fileHandleForReading)

    do {
      try process.run()
    } catch {
      stderrCollector.stop()
      throw ZstdError.commandFailed(exitCode: -1, stderr: "Failed to launch zstd: \(error.localizedDescription)")
    }

    ChildProcessTracker.shared.track(process)

    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let digest = try Self.writePipeToFileRange(
          pipe: stdoutPipe,
          destinationPath: destinationPath,
          offset: offset
        )
        streamState.finish(digest)
      } catch {
        streamState.fail(error)
        ChildProcessTracker.shared.terminateIfRunning(process)
      }
    }

    let exitCode: Int32
    do {
      exitCode = try await withTaskCancellationHandler {
        try await Self.waitForProcess(
          exitObserver: exitObserver,
          process: process,
          timeout: timeout ?? Self.defaultTimeout,
          timeoutDescription: "zstd decompress"
        )
      } onCancel: {
        ChildProcessTracker.shared.terminateIfRunning(process)
      }
    } catch {
      stderrCollector.stop()
      ChildProcessTracker.shared.untrack(process)
      throw error
    }

    let stderr = stderrCollector.stopAndReadRemaining()
    ChildProcessTracker.shared.untrack(process)

    guard exitCode == 0 else {
      let stderrText = String(data: stderr, encoding: .utf8) ?? ""
      throw ZstdError.commandFailed(exitCode: exitCode, stderr: stderrText)
    }

    return try await streamState.result()
  }

  private func resolveZstdPath() throws -> String {
    if let configuredPath {
      guard FileManager.default.fileExists(atPath: configuredPath) else {
        throw ZstdError.zstdNotFound("Custom path does not exist: \(configuredPath)")
      }
      return configuredPath
    }

    if let bundledPath = Bundle.main.resourceURL?.appendingPathComponent("zstd").path,
       FileManager.default.fileExists(atPath: bundledPath)
    {
      return bundledPath
    }

    throw ZstdError.zstdNotFound(
      "No zstd binary found. Set images.zstdPath in config or place zstd in the app bundle Resources."
    )
  }

  private static func writeRangeToPipe(
    inputPath: String,
    offset: UInt64,
    size: UInt64,
    pipe: Pipe
  ) throws -> ZstdRangeDigest {
    let outputHandle = pipe.fileHandleForWriting
    _ = fcntl(outputHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
    guard size > 0 else {
      return ZstdRangeDigest(size: 0, digest: emptyDigest, isZero: true)
    }

    let inputHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
    disableFileCache(for: inputHandle)
    defer { try? inputHandle.close() }
    try inputHandle.seek(toOffset: offset)

    var hasher = SHA256()
    var remaining = Int(size)
    var bytesWritten: UInt64 = 0
    var isZero = true

    while remaining > 0 {
      let readSize = min(Self.bufferSize, remaining)
      guard let data = try inputHandle.read(upToCount: readSize), !data.isEmpty else {
        throw ZstdError.streamingFailed("Unexpected EOF in \(inputPath)")
      }
      hasher.update(data: data)
      if isZero, data.contains(where: { $0 != 0 }) {
        isZero = false
      }
      try outputHandle.write(contentsOf: data)
      remaining -= data.count
      bytesWritten += UInt64(data.count)
    }

    return ZstdRangeDigest(size: bytesWritten, digest: hexDigest(hasher.finalize()), isZero: isZero)
  }

  private static func writePipeToFileRange(
    pipe: Pipe,
    destinationPath: String,
    offset: UInt64
  ) throws -> ZstdRangeDigest {
    let inputHandle = pipe.fileHandleForReading
    let outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: destinationPath))
    disableFileCache(for: outputHandle)
    defer { try? outputHandle.close() }
    try outputHandle.seek(toOffset: offset)

    var hasher = SHA256()
    var bytesWritten: UInt64 = 0
    var isZero = true

    while true {
      let data = try inputHandle.read(upToCount: Self.bufferSize) ?? Data()
      guard !data.isEmpty else { break }
      hasher.update(data: data)
      if isZero, data.contains(where: { $0 != 0 }) {
        isZero = false
      }
      try outputHandle.write(contentsOf: data)
      bytesWritten += UInt64(data.count)
    }

    return ZstdRangeDigest(size: bytesWritten, digest: hexDigest(hasher.finalize()), isZero: isZero)
  }

  private static func waitForProcess(
    exitObserver: ZstdProcessExitObserver,
    process: Process,
    timeout: TimeInterval?,
    timeoutDescription: String
  ) async throws -> Int32 {
    try await withThrowingTaskGroup(of: ZstdProcessEvent.self) { group in
      group.addTask {
        await .exited(exitObserver.wait())
      }
      if let timeout {
        group.addTask {
          try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
          return .timedOut
        }
      }

      while let event = try await group.next() {
        switch event {
        case .exited(let status):
          group.cancelAll()
          return status
        case .timedOut:
          ChildProcessTracker.shared.terminateIfRunning(process)
          group.cancelAll()
          throw ZstdError.timeout(timeoutDescription)
        }
      }

      throw ZstdError.commandFailed(exitCode: -1, stderr: "Process ended without status")
    }
  }

  private static func hexDigest(_ digest: some Sequence<UInt8>) -> String {
    "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }

  private static var emptyDigest: String {
    hexDigest(SHA256.hash(data: Data()))
  }

  private static func disableFileCache(for handle: FileHandle) {
    _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
  }
}

private enum ZstdProcessEvent {
  case exited(Int32)
  case timedOut
}

private final class ZstdStreamingState: @unchecked Sendable {
  private let lock = NSLock()
  private var value: ZstdRangeDigest?
  private var error: Error?
  private var continuation: CheckedContinuation<Result<ZstdRangeDigest, Error>, Never>?

  func finish(_ value: ZstdRangeDigest) {
    let continuation: CheckedContinuation<Result<ZstdRangeDigest, Error>, Never>?
    lock.lock()
    self.value = value
    continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: .success(value))
  }

  func fail(_ error: Error) {
    let continuation: CheckedContinuation<Result<ZstdRangeDigest, Error>, Never>?
    lock.lock()
    self.error = error
    continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: .failure(error))
  }

  func result() async throws -> ZstdRangeDigest {
    if let immediate = currentResult() {
      return try immediate.get()
    }

    return try await withCheckedContinuation {
      (continuation: CheckedContinuation<Result<ZstdRangeDigest, Error>, Never>) in
      if let immediate = installContinuationOrReturnResult(continuation) {
        continuation.resume(returning: immediate)
      }
    }.get()
  }

  private func currentResult() -> Result<ZstdRangeDigest, Error>? {
    lock.lock()
    defer { lock.unlock() }

    if let value {
      return .success(value)
    }
    if let error {
      return .failure(error)
    }
    return nil
  }

  private func installContinuationOrReturnResult(
    _ continuation: CheckedContinuation<Result<ZstdRangeDigest, Error>, Never>
  ) -> Result<ZstdRangeDigest, Error>? {
    lock.lock()
    defer { lock.unlock() }

    if let value {
      return .success(value)
    }
    if let error {
      return .failure(error)
    }
    self.continuation = continuation
    return nil
  }
}

private final class ZstdProcessExitObserver: @unchecked Sendable {
  private let lock = NSLock()
  private var status: Int32?
  private var continuation: CheckedContinuation<Int32, Never>?

  func finish(_ status: Int32) {
    let continuation: CheckedContinuation<Int32, Never>?
    lock.lock()
    if self.status == nil {
      self.status = status
      continuation = self.continuation
      self.continuation = nil
    } else {
      continuation = nil
    }
    lock.unlock()
    continuation?.resume(returning: status)
  }

  func wait() async -> Int32 {
    await withCheckedContinuation { continuation in
      let existingStatus: Int32?
      lock.lock()
      if let status {
        existingStatus = status
      } else {
        existingStatus = nil
        self.continuation = continuation
      }
      lock.unlock()

      if let existingStatus {
        continuation.resume(returning: existingStatus)
      }
    }
  }
}

private final class ZstdLimitedPipeCollector: @unchecked Sendable {
  private let lock = NSLock()
  private let maxOutputSize: Int
  private var data = Data()
  private weak var handle: FileHandle?

  init(maxOutputSize: Int) {
    self.maxOutputSize = maxOutputSize
  }

  func start(_ handle: FileHandle) {
    lock.lock()
    self.handle = handle
    lock.unlock()

    handle.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      self?.append(chunk)
    }
  }

  func stop() {
    lock.lock()
    let handle = handle
    self.handle = nil
    lock.unlock()
    handle?.readabilityHandler = nil
  }

  func stopAndReadRemaining() -> Data {
    lock.lock()
    let handle = handle
    self.handle = nil
    lock.unlock()

    handle?.readabilityHandler = nil
    if let remaining = handle?.availableData, !remaining.isEmpty {
      append(remaining)
    }

    lock.lock()
    let output = data
    lock.unlock()
    return output
  }

  private func append(_ chunk: Data) {
    lock.lock()
    defer { lock.unlock() }

    guard data.count < maxOutputSize else { return }
    let remainingCapacity = maxOutputSize - data.count
    if chunk.count <= remainingCapacity {
      data.append(chunk)
    } else {
      data.append(chunk.prefix(remainingCapacity))
    }
  }
}
