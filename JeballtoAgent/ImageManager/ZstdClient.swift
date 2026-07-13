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

private struct ZstdDecompressionContext: @unchecked Sendable {
  let process: Process
  let exitObserver: ZstdProcessExitObserver
  let stderrCollector: LimitedPipeOutputCollector
  let stdoutPipe: Pipe
  let destinationPath: String
  let offset: UInt64
  let expectedSize: UInt64
  let diskWriteLimiter: ImageConcurrencyLimiter?
  let timeout: TimeInterval?
}

struct ZstdClient: Sendable {
  private let configuredPath: String?
  private let childProcessLease: ImageWorkChildProcessLease?
  private static let defaultTimeout: TimeInterval? = nil
  private static let maxOutputSize = 1024 * 1024
  private static let bufferSize = 1024 * 1024

  init(configuredPath: String? = nil, childProcessLease: ImageWorkChildProcessLease? = nil) {
    self.configuredPath = configuredPath
    self.childProcessLease = childProcessLease
  }

  init(config: ImageConfig, childProcessLease: ImageWorkChildProcessLease? = nil) {
    configuredPath = config.zstdPath
    self.childProcessLease = childProcessLease
  }

  func scanRange(inputPath: String, offset: UInt64, size: UInt64) throws -> ZstdRangeDigest {
    guard size > 0 else {
      return ZstdRangeDigest(size: 0, digest: Self.emptyDigest, isZero: true)
    }

    let inputHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
    Self.disableFileCache(for: inputHandle)
    defer { try? inputHandle.close() }
    try inputHandle.seek(toOffset: offset)

    guard let boundedSize = Int(exactly: size) else {
      throw ZstdError.streamingFailed("Requested range is too large to process")
    }
    var hasher = SHA256()
    var remaining = boundedSize
    var bytesRead: UInt64 = 0
    var isZero = true

    while remaining > 0 {
      try Task.checkCancellation()
      let readSize = min(Self.bufferSize, remaining)
      guard let data = try readFileChunk(from: inputHandle, upToCount: readSize), !data.isEmpty else {
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
    process.arguments = configuredPath == nil
      ? ["-q", "--single-thread", "-f", "-\(level)", "-", "-o", outputPath]
      : ["-q", "-f", "-\(level)", "-", "-o", outputPath]
    if configuredPath == nil {
      process.environment = bundledToolEnvironment()
    }

    let stdinPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderrPipe
    let childLaunchReservation = try childProcessLease?.prepare(process)
    defer { childLaunchReservation?.processDidExit() }

    let exitObserver = ZstdProcessExitObserver()
    let stderrCollector = LimitedPipeOutputCollector(maxOutputSize: Self.maxOutputSize)
    process.terminationHandler = { process in
      exitObserver.finish(process.terminationStatus)
    }
    stderrCollector.start(stderrPipe.fileHandleForReading)

    do {
      try process.run()
      childLaunchReservation?.processDidLaunch()
    } catch {
      childLaunchReservation?.cancelBeforeLaunch()
      stderrCollector.stop()
      throw ZstdError.commandFailed(exitCode: -1, stderr: "Failed to launch zstd: \(error.localizedDescription)")
    }
    try? stdinPipe.fileHandleForReading.close()
    try? stderrPipe.fileHandleForWriting.close()

    ChildProcessTracker.shared.track(process)

    do {
      let digest = try await withTaskCancellationHandler {
        try await Self.collectCompressionResult(
          process: process,
          exitObserver: exitObserver,
          stderrCollector: stderrCollector,
          stdinPipe: stdinPipe,
          inputPath: inputPath,
          offset: offset,
          size: size,
          timeout: timeout ?? Self.defaultTimeout
        )
      } onCancel: {
        ChildProcessTracker.shared.terminateIfRunning(process)
      }
      ChildProcessTracker.shared.untrack(process)
      return digest
    } catch {
      ChildProcessTracker.shared.untrack(process)
      ChildProcessTracker.shared.terminateIfRunning(process)
      stderrCollector.stop()
      try? stdinPipe.fileHandleForWriting.close()
      throw error
    }
  }

  private static func collectCompressionResult(
    process: Process,
    exitObserver: ZstdProcessExitObserver,
    stderrCollector: LimitedPipeOutputCollector,
    stdinPipe: Pipe,
    inputPath: String,
    offset: UInt64,
    size: UInt64,
    timeout: TimeInterval?
  ) async throws -> ZstdRangeDigest {
    try await withThrowingTaskGroup(of: ZstdCompressionEvent.self) { group in
      group.addTask {
        defer { try? stdinPipe.fileHandleForWriting.close() }
        do {
          let digest = try writeRangeToPipe(
            inputPath: inputPath,
            offset: offset,
            size: size,
            pipe: stdinPipe
          )
          return .streamed(digest)
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as ZstdError {
          throw error
        } catch {
          throw ZstdError.streamingFailed(
            "Failed to stream \(size)-byte range at offset \(offset) from \(inputPath) into zstd: "
              + error.localizedDescription
          )
        }
      }
      group.addTask {
        let status = try await waitForProcess(
          exitObserver: exitObserver,
          process: process,
          timeout: timeout,
          timeoutDescription: "zstd compress"
        )
        return .exited(status)
      }

      var streamedDigest: ZstdRangeDigest?
      var exitCode: Int32?
      do {
        while let event = try await group.next() {
          switch event {
          case .streamed(let digest):
            streamedDigest = digest
          case .exited(let status):
            exitCode = status
          }

          if let streamedDigest, let exitCode {
            group.cancelAll()
            let stderr = await stderrCollector.finish()
            guard exitCode == 0 else {
              let suffix = stderr.wasTruncated ? " (output truncated)" : ""
              let stderrText = String(decoding: stderr.data, as: UTF8.self) + suffix
              throw ZstdError.commandFailed(exitCode: exitCode, stderr: stderrText)
            }
            guard stderr.wasTruncated == false else {
              throw ZstdError.streamingFailed("zstd standard error exceeded the 1MB limit or did not close after exit")
            }
            return streamedDigest
          }
        }
      } catch {
        ChildProcessTracker.shared.terminateIfRunning(process)
        group.cancelAll()
        try? stdinPipe.fileHandleForWriting.close()
        if Task.isCancelled {
          throw CancellationError()
        }
        throw error
      }

      throw ZstdError.streamingFailed("zstd compress ended without complete stream state")
    }
  }

  func decompressToFileRange(
    inputPath: String,
    destinationPath: String,
    offset: UInt64,
    expectedSize: UInt64,
    diskWriteLimiter: ImageConcurrencyLimiter? = nil,
    timeout: TimeInterval? = nil
  ) async throws -> ZstdRangeDigest {
    let zstdPath = try resolveZstdPath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: zstdPath)
    process.arguments = ["-q", "-d", "-c", inputPath]
    if configuredPath == nil {
      process.environment = bundledToolEnvironment()
    }
    process.standardInput = FileHandle.nullDevice

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let childLaunchReservation = try childProcessLease?.prepare(process)
    defer { childLaunchReservation?.processDidExit() }

    let exitObserver = ZstdProcessExitObserver()
    let stderrCollector = LimitedPipeOutputCollector(maxOutputSize: Self.maxOutputSize)

    process.terminationHandler = { process in
      exitObserver.finish(process.terminationStatus)
    }
    stderrCollector.start(stderrPipe.fileHandleForReading)

    do {
      try process.run()
      childLaunchReservation?.processDidLaunch()
    } catch {
      childLaunchReservation?.cancelBeforeLaunch()
      stderrCollector.stop()
      throw ZstdError.commandFailed(exitCode: -1, stderr: "Failed to launch zstd: \(error.localizedDescription)")
    }
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForWriting.close()

    ChildProcessTracker.shared.track(process)

    do {
      let digest = try await withTaskCancellationHandler {
        let context = ZstdDecompressionContext(
          process: process,
          exitObserver: exitObserver,
          stderrCollector: stderrCollector,
          stdoutPipe: stdoutPipe,
          destinationPath: destinationPath,
          offset: offset,
          expectedSize: expectedSize,
          diskWriteLimiter: diskWriteLimiter,
          timeout: timeout ?? Self.defaultTimeout
        )
        return try await Self.collectDecompressionResult(context)
      } onCancel: {
        ChildProcessTracker.shared.terminateIfRunning(process)
      }
      ChildProcessTracker.shared.untrack(process)
      return digest
    } catch {
      ChildProcessTracker.shared.untrack(process)
      stderrCollector.stop()
      ChildProcessTracker.shared.terminateIfRunning(process)
      throw error
    }
  }

  private static func collectDecompressionResult(
    _ context: ZstdDecompressionContext
  ) async throws -> ZstdRangeDigest {
    try await withThrowingTaskGroup(of: ZstdDecompressionEvent.self) { group in
      group.addTask {
        do {
          let digest = try await writePipeToFileRange(
            pipe: context.stdoutPipe,
            destinationPath: context.destinationPath,
            offset: context.offset,
            expectedSize: context.expectedSize,
            diskWriteLimiter: context.diskWriteLimiter
          )
          return .streamed(digest)
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as ZstdError {
          throw error
        } catch {
          throw ZstdError.streamingFailed(
            "Failed to write decompressed \(context.expectedSize)-byte range at offset \(context.offset) to "
              + "\(context.destinationPath): \(error.localizedDescription)"
          )
        }
      }
      group.addTask {
        let status = try await waitForProcess(
          exitObserver: context.exitObserver,
          process: context.process,
          timeout: context.timeout,
          timeoutDescription: "zstd decompress"
        )
        return .exited(status)
      }

      var streamedDigest: ZstdRangeDigest?
      var exitCode: Int32?
      do {
        while let event = try await group.next() {
          switch event {
          case .streamed(let digest):
            streamedDigest = digest
          case .exited(let status):
            exitCode = status
          }

          if let streamedDigest, let exitCode {
            group.cancelAll()
            let stderr = await context.stderrCollector.finish()
            guard exitCode == 0 else {
              let suffix = stderr.wasTruncated ? " (output truncated)" : ""
              let stderrText = String(decoding: stderr.data, as: UTF8.self) + suffix
              throw ZstdError.commandFailed(exitCode: exitCode, stderr: stderrText)
            }
            guard stderr.wasTruncated == false else {
              throw ZstdError.streamingFailed("zstd standard error exceeded the 1MB limit or did not close after exit")
            }
            return streamedDigest
          }
        }
      } catch {
        ChildProcessTracker.shared.terminateIfRunning(context.process)
        group.cancelAll()
        if Task.isCancelled {
          throw CancellationError()
        }
        throw error
      }

      throw ZstdError.streamingFailed("zstd decompress ended without complete stream state")
    }
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
    guard let boundedSize = Int(exactly: size) else {
      throw ZstdError.streamingFailed("Requested range is too large to process")
    }

    let inputHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
    disableFileCache(for: inputHandle)
    defer { try? inputHandle.close() }
    try inputHandle.seek(toOffset: offset)

    var hasher = SHA256()
    var remaining = boundedSize
    var bytesWritten: UInt64 = 0
    var isZero = true

    while remaining > 0 {
      try Task.checkCancellation()
      let readSize = min(Self.bufferSize, remaining)
      guard let data = try readFileChunk(from: inputHandle, upToCount: readSize), !data.isEmpty else {
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
    offset: UInt64,
    expectedSize: UInt64,
    diskWriteLimiter: ImageConcurrencyLimiter?
  ) async throws -> ZstdRangeDigest {
    let inputHandle = pipe.fileHandleForReading
    let outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: destinationPath))
    disableFileCache(for: outputHandle)
    defer { try? outputHandle.close() }
    try outputHandle.seek(toOffset: offset)

    var hasher = SHA256()
    var bytesWritten: UInt64 = 0
    var isZero = true

    while true {
      try Task.checkCancellation()
      let data = try readFileChunk(from: inputHandle, upToCount: Self.bufferSize) ?? Data()
      guard !data.isEmpty else { break }
      guard bytesWritten <= expectedSize,
            UInt64(data.count) <= expectedSize - bytesWritten else
      {
        throw ZstdError.streamingFailed(
          "Decompressed output exceeds the declared chunk size of \(expectedSize) bytes"
        )
      }
      hasher.update(data: data)
      if isZero, data.contains(where: { $0 != 0 }) {
        isZero = false
      }
      if let diskWriteLimiter {
        try await diskWriteLimiter.withPermit {
          try outputHandle.write(contentsOf: data)
        }
      } else {
        try outputHandle.write(contentsOf: data)
      }
      bytesWritten += UInt64(data.count)
    }

    guard bytesWritten == expectedSize else {
      throw ZstdError.streamingFailed(
        "Decompressed output size mismatch: expected \(expectedSize) bytes, got \(bytesWritten)"
      )
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
          try await Task.sleep(nanoseconds: timeoutNanoseconds(timeout))
          return .timedOut
        }
      }

      while let event = try await group.next() {
        switch event {
        case .exited(let status):
          group.cancelAll()
          try Task.checkCancellation()
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

  private static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64 {
    guard timeout.isFinite, timeout > 0 else { return 0 }
    let maxSeconds = TimeInterval(UInt64.max / 1_000_000_000)
    return UInt64(min(timeout, maxSeconds) * 1_000_000_000)
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

private enum ZstdCompressionEvent {
  case streamed(ZstdRangeDigest)
  case exited(Int32)
}

private enum ZstdDecompressionEvent {
  case streamed(ZstdRangeDigest)
  case exited(Int32)
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
