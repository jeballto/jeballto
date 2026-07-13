import Darwin
import Foundation

struct ProcessExecutionResult: Sendable {
  let exitCode: Int32
  let stdout: Data
  let stderr: Data
  let stdoutTruncated: Bool
  let stderrTruncated: Bool
}

struct LimitedPipeOutput: Sendable {
  let data: Data
  let wasTruncated: Bool
}

struct AsyncProcessRunnerOptions: Sendable {
  let timeout: TimeInterval?
  let timeoutDescription: String
  let maxOutputSize: Int
}

enum AsyncProcessRunnerError: Error, LocalizedError {
  case launchFailed(String)
  case inputWriteFailed(String)
  case timeout(String)

  var errorDescription: String? {
    switch self {
    case .launchFailed(let message): "Process launch failed: \(message)"
    case .inputWriteFailed(let message): "Process standard input write failed: \(message)"
    case .timeout(let command): "Process timed out: \(command)"
    }
  }
}

final class AsyncProcessStandardInput: @unchecked Sendable {
  let pipe: Pipe

  private let data: Data
  private let lock = NSLock()
  private var readHandle: FileHandle?
  private var writeHandle: FileHandle?
  private var writeCompleted = false

  init(data: Data) {
    pipe = Pipe()
    self.data = data
    readHandle = pipe.fileHandleForReading
    writeHandle = pipe.fileHandleForWriting
  }

  func close() {
    let handles = lock.withLock { () -> (FileHandle?, FileHandle?) in
      let handles = (readHandle, writeHandle)
      readHandle = nil
      writeHandle = nil
      return handles
    }
    try? handles.0?.close()
    try? handles.1?.close()
  }

  func closeParentReadEnd() {
    let handle = lock.withLock { () -> FileHandle? in
      let handle = readHandle
      readHandle = nil
      return handle
    }
    try? handle?.close()
  }

  func write() async throws {
    guard let descriptor = lock.withLock({ writeHandle?.fileDescriptor }) else {
      throw AsyncProcessRunnerError.inputWriteFailed("Standard input was closed before writing")
    }
    defer { closeWriteEnd() }

    _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
    let flags = fcntl(descriptor, F_GETFL)
    guard flags != -1 else {
      throw AsyncProcessRunnerError.inputWriteFailed(Self.posixErrorMessage())
    }
    guard fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
      throw AsyncProcessRunnerError.inputWriteFailed(Self.posixErrorMessage())
    }

    var offset = 0
    while offset < data.count {
      try Task.checkCancellation()
      let bytesWritten = data.withUnsafeBytes { buffer -> Int in
        guard let baseAddress = buffer.baseAddress else { return 0 }
        return Darwin.write(
          descriptor,
          baseAddress.advanced(by: offset),
          buffer.count - offset
        )
      }

      if bytesWritten > 0 {
        offset += bytesWritten
        continue
      }
      if bytesWritten == 0 {
        throw AsyncProcessRunnerError.inputWriteFailed("Writing standard input returned zero bytes")
      }

      let errorCode = errno
      if errorCode == EINTR {
        continue
      }
      if errorCode == EAGAIN || errorCode == EWOULDBLOCK {
        try await Task.sleep(for: .milliseconds(10))
        continue
      }
      throw AsyncProcessRunnerError.inputWriteFailed(Self.posixErrorMessage(errorCode))
    }
    lock.withLock { writeCompleted = true }
  }

  fileprivate var wasFullyWritten: Bool {
    lock.withLock { writeCompleted }
  }

  private static func posixErrorMessage(_ errorCode: Int32 = errno) -> String {
    String(cString: strerror(errorCode))
  }

  private func closeWriteEnd() {
    let handle = lock.withLock { () -> FileHandle? in
      let handle = writeHandle
      writeHandle = nil
      return handle
    }
    try? handle?.close()
  }
}

enum AsyncProcessRunner {
  private enum ProcessEvent {
    case exited(Int32)
    case timedOut
  }

  private enum ProcessIOEvent: Sendable {
    case output(ProcessExecutionResult)
    case inputWritten
    case inputGraceExpired
  }

  private static let inputCompletionGraceNanoseconds: UInt64 = 500_000_000

  static func run(
    process: Process,
    stdoutPipe: Pipe,
    stderrPipe: Pipe,
    options: AsyncProcessRunnerOptions,
    standardInput: AsyncProcessStandardInput? = nil,
    childLaunchReservation: ImageWorkChildLaunchReservation? = nil,
    onProcessStarted: (@Sendable () -> Void)? = nil
  ) async throws -> ProcessExecutionResult {
    defer { childLaunchReservation?.processDidExit() }
    let tracker = ChildProcessTracker.shared
    let stdoutCollector = LimitedPipeOutputCollector(maxOutputSize: options.maxOutputSize)
    let stderrCollector = LimitedPipeOutputCollector(maxOutputSize: options.maxOutputSize)
    let terminationObserver = ProcessTerminationObserver()
    let context = ProcessRunContext(
      process: process,
      tracker: tracker,
      options: options,
      stdoutCollector: stdoutCollector,
      stderrCollector: stderrCollector,
      terminationObserver: terminationObserver,
      timeoutObserver: ProcessTimeoutObserver()
    )
    if let standardInput {
      process.standardInput = standardInput.pipe
    }
    defer { standardInput?.close() }
    stdoutCollector.start(stdoutPipe.fileHandleForReading)
    stderrCollector.start(stderrPipe.fileHandleForReading)
    process.terminationHandler = { process in
      terminationObserver.finish(process.terminationStatus)
    }

    do {
      try process.run()
      childLaunchReservation?.processDidLaunch()
    } catch {
      childLaunchReservation?.cancelBeforeLaunch()
      try? stdoutPipe.fileHandleForWriting.close()
      try? stderrPipe.fileHandleForWriting.close()
      stdoutCollector.stop()
      stderrCollector.stop()
      throw AsyncProcessRunnerError.launchFailed(error.localizedDescription)
    }
    onProcessStarted?()
    standardInput?.closeParentReadEnd()
    // Process owns duplicated write descriptors after launch. Closing the parent's copies lets
    // the reader tasks observe EOF deterministically when the child exits.
    try? stdoutPipe.fileHandleForWriting.close()
    try? stderrPipe.fileHandleForWriting.close()

    tracker.track(process)

    do {
      let result = try await withTaskCancellationHandler {
        try await collectOutput(context, standardInput: standardInput)
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

  private static func collectOutput(
    _ context: ProcessRunContext,
    standardInput: AsyncProcessStandardInput?
  ) async throws -> ProcessExecutionResult {
    guard let standardInput else {
      return try await collectProcessOutput(context)
    }

    return try await withThrowingTaskGroup(of: ProcessIOEvent.self) { group in
      group.addTask {
        try await .output(collectProcessOutput(context))
      }
      group.addTask {
        try await standardInput.write()
        return .inputWritten
      }

      do {
        var output: ProcessExecutionResult?
        var inputWasWritten = false
        while let event = try await group.next() {
          switch event {
          case .output(let result):
            output = result
            if inputWasWritten == false, standardInput.wasFullyWritten {
              inputWasWritten = true
            }
            if inputWasWritten == false {
              group.addTask {
                try await Task.sleep(nanoseconds: Self.inputCompletionGraceNanoseconds)
                return .inputGraceExpired
              }
            }
          case .inputWritten:
            inputWasWritten = true
          case .inputGraceExpired:
            guard output != nil, inputWasWritten == false else { continue }
            group.cancelAll()
            throw AsyncProcessRunnerError.inputWriteFailed(
              "Process exited before standard input was written completely"
            )
          }
          if let output, inputWasWritten {
            group.cancelAll()
            return output
          }
        }
      } catch {
        context.tracker.terminateIfRunning(context.process)
        group.cancelAll()
        if context.timeoutObserver.didTimeout {
          throw AsyncProcessRunnerError.timeout(context.options.timeoutDescription)
        }
        if Task.isCancelled {
          throw CancellationError()
        }
        throw error
      }

      throw AsyncProcessRunnerError.launchFailed("Process ended without complete input and output state")
    }
  }

  private static func collectProcessOutput(_ context: ProcessRunContext) async throws -> ProcessExecutionResult {
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
          async let stdoutResult = context.stdoutCollector.finish()
          async let stderrResult = context.stderrCollector.finish()
          let (stdout, stderr) = await (stdoutResult, stderrResult)
          return ProcessExecutionResult(
            exitCode: status,
            stdout: stdout.data,
            stderr: stderr.data,
            stdoutTruncated: stdout.wasTruncated,
            stderrTruncated: stderr.wasTruncated
          )
        case .timedOut:
          context.timeoutObserver.markTimedOut()
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
  let stdoutCollector: LimitedPipeOutputCollector
  let stderrCollector: LimitedPipeOutputCollector
  let terminationObserver: ProcessTerminationObserver
  let timeoutObserver: ProcessTimeoutObserver
}

private final class ProcessTimeoutObserver: @unchecked Sendable {
  private let lock = NSLock()
  private var timedOut = false

  var didTimeout: Bool {
    lock.withLock { timedOut }
  }

  func markTimedOut() {
    lock.withLock { timedOut = true }
  }
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

final class LimitedPipeOutputCollector: @unchecked Sendable {
  private struct Completion {
    let observer: PipeCollectionObserver
    let output: LimitedPipeOutput
    let source: DispatchSourceRead?
    let handle: FileHandle?
  }

  private static let drainGrace: DispatchTimeInterval = .milliseconds(500)
  private static let readBufferSize = 64 * 1024

  private let lock = NSLock()
  private let readQueue = DispatchQueue(label: "com.jeballto.pipe-output-collector", qos: .userInitiated)
  private let maxOutputSize: Int
  private var collectionObserver: PipeCollectionObserver?
  private var handle: FileHandle?
  private var source: DispatchSourceRead?
  private var output = Data()
  private var wasTruncated = false
  private var isFinished = false

  init(maxOutputSize: Int) {
    self.maxOutputSize = max(0, maxOutputSize)
  }

  func start(_ handle: FileHandle) {
    let observer = PipeCollectionObserver()
    let descriptor = handle.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
      observer.finish(LimitedPipeOutput(data: Data(), wasTruncated: true))
      try? handle.close()
      lock.withLock { collectionObserver = observer }
      return
    }

    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readQueue)
    lock.withLock {
      self.handle = handle
      collectionObserver = observer
      self.source = source
      output.removeAll(keepingCapacity: false)
      wasTruncated = false
      isFinished = false
    }
    source.setEventHandler { [weak self] in
      self?.drainAvailableBytes(descriptor: descriptor)
    }
    source.resume()
  }

  func stop() {
    readQueue.async { [weak self] in
      self?.completeCollection(forceTruncated: true)
    }
  }

  func finish() async -> LimitedPipeOutput {
    guard let observer = lock.withLock({ collectionObserver }) else {
      return LimitedPipeOutput(data: Data(), wasTruncated: false)
    }

    readQueue.asyncAfter(deadline: .now() + Self.drainGrace) { [weak self] in
      self?.completeCollection(forceTruncated: true)
    }
    let output = await observer.wait()
    lock.withLock {
      handle = nil
      collectionObserver = nil
    }
    return output
  }

  private func drainAvailableBytes(descriptor: Int32) {
    var buffer = [UInt8](repeating: 0, count: Self.readBufferSize)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count > 0 {
        append(buffer, count: count)
        continue
      }
      if count == 0 {
        completeCollection(forceTruncated: false)
        return
      }

      let errorCode = errno
      if errorCode == EINTR { continue }
      if errorCode == EAGAIN || errorCode == EWOULDBLOCK { return }
      completeCollection(forceTruncated: true)
      return
    }
  }

  private func append(_ buffer: [UInt8], count: Int) {
    lock.withLock {
      guard isFinished == false else { return }
      let remainingCapacity = max(0, maxOutputSize - output.count)
      if remainingCapacity > 0 {
        output.append(contentsOf: buffer.prefix(min(count, remainingCapacity)))
      }
      if count > remainingCapacity {
        wasTruncated = true
      }
    }
  }

  private func completeCollection(forceTruncated: Bool) {
    let completion = lock.withLock { () -> Completion? in
      guard isFinished == false, let observer = collectionObserver else { return nil }
      isFinished = true
      let completion = Completion(
        observer: observer,
        output: LimitedPipeOutput(data: output, wasTruncated: wasTruncated || forceTruncated),
        source: source,
        handle: handle
      )
      source = nil
      handle = nil
      return completion
    }
    guard let completion else { return }
    completion.source?.cancel()
    try? completion.handle?.close()
    completion.observer.finish(completion.output)
  }
}

private final class PipeCollectionObserver: @unchecked Sendable {
  private let lock = NSLock()
  private var output: LimitedPipeOutput?
  private var continuations: [CheckedContinuation<LimitedPipeOutput, Never>] = []

  func finish(_ output: LimitedPipeOutput) {
    let continuations = lock.withLock { () -> [CheckedContinuation<LimitedPipeOutput, Never>] in
      guard self.output == nil else { return [] }
      self.output = output
      let continuations = self.continuations
      self.continuations.removeAll()
      return continuations
    }
    for continuation in continuations {
      continuation.resume(returning: output)
    }
  }

  func wait() async -> LimitedPipeOutput {
    await withCheckedContinuation { continuation in
      let existingOutput = lock.withLock { () -> LimitedPipeOutput? in
        if let output = self.output {
          return output
        }
        continuations.append(continuation)
        return nil
      }
      if let output = existingOutput {
        continuation.resume(returning: output)
      }
    }
  }
}
