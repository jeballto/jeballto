import Foundation

struct ProcessExecutionResult {
  let exitCode: Int32
  let stdout: Data
  let stderr: Data
}

struct AsyncProcessRunnerOptions: Sendable {
  let timeout: TimeInterval?
  let timeoutDescription: String
  let maxOutputSize: Int
}

enum AsyncProcessRunnerError: Error, LocalizedError {
  case launchFailed(String)
  case timeout(String)

  var errorDescription: String? {
    switch self {
    case .launchFailed(let message): "Process launch failed: \(message)"
    case .timeout(let command): "Process timed out: \(command)"
    }
  }
}

enum AsyncProcessRunner {
  private enum ProcessEvent {
    case exited(Int32)
    case timedOut
  }

  static func run(
    process: Process,
    stdoutPipe: Pipe,
    stderrPipe: Pipe,
    options: AsyncProcessRunnerOptions,
    afterLaunch: ((Process) throws -> Void)? = nil
  ) async throws -> ProcessExecutionResult {
    let tracker = ChildProcessTracker.shared
    let stdoutCollector = PipeOutputCollector(maxOutputSize: options.maxOutputSize)
    let stderrCollector = PipeOutputCollector(maxOutputSize: options.maxOutputSize)
    let terminationObserver = ProcessTerminationObserver()
    let context = ProcessRunContext(
      process: process,
      tracker: tracker,
      options: options,
      stdoutCollector: stdoutCollector,
      stderrCollector: stderrCollector,
      terminationObserver: terminationObserver
    )
    stdoutCollector.start(stdoutPipe.fileHandleForReading)
    stderrCollector.start(stderrPipe.fileHandleForReading)
    process.terminationHandler = { process in
      terminationObserver.finish(process.terminationStatus)
    }

    do {
      try process.run()
    } catch {
      stdoutCollector.stop()
      stderrCollector.stop()
      throw AsyncProcessRunnerError.launchFailed(error.localizedDescription)
    }

    tracker.track(process)

    do {
      try afterLaunch?(process)
      let result = try await withTaskCancellationHandler {
        try await collectOutput(context)
      } onCancel: {
        tracker.terminateIfRunning(process)
      }
      tracker.untrack(process)
      return result
    } catch {
      tracker.terminateIfRunning(process)
      tracker.untrack(process)
      stdoutCollector.stop()
      stderrCollector.stop()
      throw error
    }
  }

  private static func collectOutput(_ context: ProcessRunContext) async throws -> ProcessExecutionResult {
    let options = context.options
    return try await withThrowingTaskGroup(of: ProcessEvent.self) { group in
      group.addTask {
        await .exited(context.terminationObserver.wait())
      }
      if let timeout = options.timeout {
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
          return ProcessExecutionResult(
            exitCode: status,
            stdout: context.stdoutCollector.stopAndReadRemaining(),
            stderr: context.stderrCollector.stopAndReadRemaining()
          )
        case .timedOut:
          context.tracker.terminateIfRunning(context.process)
          group.cancelAll()
          throw AsyncProcessRunnerError.timeout(options.timeoutDescription)
        }
      }

      throw AsyncProcessRunnerError.launchFailed("Process ended without complete output")
    }
  }

  private static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64 {
    guard timeout.isFinite, timeout > 0 else { return 0 }
    let maxSeconds = TimeInterval(UInt64.max / 1_000_000_000)
    return UInt64(min(timeout, maxSeconds) * 1_000_000_000)
  }
}

private struct ProcessRunContext: @unchecked Sendable {
  let process: Process
  let tracker: ChildProcessTracker
  let options: AsyncProcessRunnerOptions
  let stdoutCollector: PipeOutputCollector
  let stderrCollector: PipeOutputCollector
  let terminationObserver: ProcessTerminationObserver
}

private final class ProcessTerminationObserver: @unchecked Sendable {
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

private final class PipeOutputCollector: @unchecked Sendable {
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
