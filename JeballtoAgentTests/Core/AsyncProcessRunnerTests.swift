import Darwin
import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core), .serialized)
struct AsyncProcessRunnerTests {
  @Test
  func drainsStdoutAndStderrConcurrently() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      "i=0; while [ $i -lt 4000 ]; do printf 'oooooooooooooooooooooooooooooooooooooooooooooooooo'; " +
        "printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' >&2; i=$((i + 1)); done",
    ]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let result = try await AsyncProcessRunner.run(
      process: process,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe,
      options: AsyncProcessRunnerOptions(
        timeout: 5,
        timeoutDescription: "large output",
        maxOutputSize: 300_000
      )
    )

    #expect(result.exitCode == 0)
    #expect(result.stdout.count == 200_000)
    #expect(result.stderr.count == 200_000)
    #expect(result.stdoutTruncated == false)
    #expect(result.stderrTruncated == false)
  }

  @Test
  func reportsOutputTruncationPerStream() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "printf '0123456789'; printf 'err' >&2"]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let result = try await AsyncProcessRunner.run(
      process: process,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe,
      options: AsyncProcessRunnerOptions(
        timeout: 1,
        timeoutDescription: "truncated output",
        maxOutputSize: 4
      )
    )

    #expect(result.exitCode == 0)
    #expect(String(decoding: result.stdout, as: UTF8.self) == "0123")
    #expect(String(decoding: result.stderr, as: UTF8.self) == "err")
    #expect(result.stdoutTruncated)
    #expect(result.stderrTruncated == false)
  }

  @Test
  func timeoutTerminatesProcess() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "sleep 5"]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    await #expect(throws: AsyncProcessRunnerError.self) {
      try await AsyncProcessRunner.run(
        process: process,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        options: AsyncProcessRunnerOptions(
          timeout: 0.1,
          timeoutDescription: "sleep",
          maxOutputSize: 1024
        )
      )
    }
    #expect(!process.isRunning)
  }

  @Test
  func cancellationTerminatesProcessAndThrowsCancellation() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "sleep 30"]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let task = Task {
      try await AsyncProcessRunner.run(
        process: process,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        options: AsyncProcessRunnerOptions(
          timeout: nil,
          timeoutDescription: "sleep",
          maxOutputSize: 1024
        )
      )
    }

    while !process.isRunning {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    let processStopped = await waitUntilProcessStops(process)
    #expect(processStopped)
  }

  @Test
  func standardInputIsWrittenAndClosed() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/cat")

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let standardInput = AsyncProcessStandardInput(data: Data("secret with spaces\n".utf8))

    let result = try await AsyncProcessRunner.run(
      process: process,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe,
      options: AsyncProcessRunnerOptions(
        timeout: 1,
        timeoutDescription: "read standard input",
        maxOutputSize: 1024
      ),
      standardInput: standardInput
    )

    #expect(result.exitCode == 0)
    #expect(String(data: result.stdout, encoding: .utf8) == "secret with spaces\n")
  }

  @Test
  func timeoutInterruptsBlockedStandardInputWrite() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["30"]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let standardInput = AsyncProcessStandardInput(data: Data(repeating: 0x41, count: 4 * 1024 * 1024))

    do {
      _ = try await AsyncProcessRunner.run(
        process: process,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        options: AsyncProcessRunnerOptions(
          timeout: 0.1,
          timeoutDescription: "blocked standard input",
          maxOutputSize: 1024
        ),
        standardInput: standardInput
      )
      Issue.record("Expected the blocked standard input write to time out")
    } catch let error as AsyncProcessRunnerError {
      guard case .timeout(let description) = error else {
        Issue.record("Expected a timeout, got \(error.localizedDescription)")
        return
      }
      #expect(description == "blocked standard input")
    }
    let processStopped = await waitUntilProcessStops(process)
    #expect(processStopped)
  }

  @Test
  func processSuccessDoesNotHideAnIncompleteStandardInputWrite() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let standardInput = AsyncProcessStandardInput(data: Data(repeating: 0x41, count: 4 * 1024 * 1024))

    await #expect(throws: AsyncProcessRunnerError.self) {
      _ = try await AsyncProcessRunner.run(
        process: process,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        options: AsyncProcessRunnerOptions(
          timeout: 1,
          timeoutDescription: "closed standard input",
          maxOutputSize: 1024
        ),
        standardInput: standardInput
      )
    }
  }

  @Test
  func processExitDoesNotWaitForDescendantHoldingStandardInputOpen() async throws {
    try await withTemporaryDirectory(prefix: "process-inherited-stdin") { root in
      let childPIDPath = "\(root)/child.pid"
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = [
        "-c",
        "sleep 10 >/dev/null 2>&1 & echo $! > '\(childPIDPath)'; exit 0",
      ]
      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe
      let standardInput = AsyncProcessStandardInput(data: Data(repeating: 0x41, count: 4 * 1024 * 1024))
      var childPID: pid_t?
      defer {
        if let childPID {
          _ = kill(childPID, SIGTERM)
        }
      }
      let clock = ContinuousClock()
      let startedAt = clock.now

      await #expect(throws: AsyncProcessRunnerError.self) {
        _ = try await AsyncProcessRunner.run(
          process: process,
          stdoutPipe: stdoutPipe,
          stderrPipe: stderrPipe,
          options: AsyncProcessRunnerOptions(
            timeout: 2,
            timeoutDescription: "inherited standard input",
            maxOutputSize: 1024
          ),
          standardInput: standardInput
        )
      }
      childPID = try await waitForProcessPID(atPath: childPIDPath)
      #expect(startedAt.duration(to: clock.now) < .seconds(3))
    }
  }

  @Test
  func drainsManyConcurrentProcessStreamsWithoutTruncation() async throws {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWX")
    try await withThrowingTaskGroup(of: Void.self) { group in
      for (index, stdoutCharacter) in alphabet.enumerated() {
        group.addTask {
          let stderrCharacter = Character(String(stdoutCharacter).lowercased())
          let stdoutBlock = String(repeating: stdoutCharacter, count: 64)
          let stderrBlock = String(repeating: stderrCharacter, count: 64)
          let process = Process()
          process.executableURL = URL(fileURLWithPath: "/bin/sh")
          process.arguments = [
            "-c",
            "i=0; while [ $i -lt 2048 ]; do printf '\(stdoutBlock)'; "
              + "printf '\(stderrBlock)' >&2; i=$((i + 1)); done",
          ]
          let stdoutPipe = Pipe()
          let stderrPipe = Pipe()
          process.standardOutput = stdoutPipe
          process.standardError = stderrPipe

          let result = try await AsyncProcessRunner.run(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            options: AsyncProcessRunnerOptions(
              timeout: 10,
              timeoutDescription: "concurrent output \(index)",
              maxOutputSize: 256 * 1024
            )
          )
          let stdoutByte = try #require(stdoutCharacter.asciiValue)
          let stderrByte = try #require(stderrCharacter.asciiValue)

          #expect(result.exitCode == 0)
          #expect(result.stdout == Data(repeating: stdoutByte, count: 128 * 1024))
          #expect(result.stderr == Data(repeating: stderrByte, count: 128 * 1024))
          #expect(result.stdoutTruncated == false)
          #expect(result.stderrTruncated == false)
        }
      }
      try await group.waitForAll()
    }
  }

  @Test
  func processExitBoundsDrainWhenDescendantInheritsOutputPipes() async throws {
    try await withTemporaryDirectory(prefix: "process-inherited-output") { root in
      let childPIDPath = "\(root)/child.pid"
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/sh")
      process.arguments = [
        "-c",
        "sleep 10 & echo $! > '\(childPIDPath)'; printf parent; printf error >&2; exit 0",
      ]
      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe
      var childPID: pid_t?
      defer {
        if let childPID {
          _ = kill(childPID, SIGTERM)
        }
      }
      let clock = ContinuousClock()
      let startedAt = clock.now

      let result = try await AsyncProcessRunner.run(
        process: process,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        options: AsyncProcessRunnerOptions(
          timeout: 5,
          timeoutDescription: "inherited output",
          maxOutputSize: 1024
        )
      )
      childPID = try await waitForProcessPID(atPath: childPIDPath)

      #expect(result.stdout == Data("parent".utf8))
      #expect(result.stderr == Data("error".utf8))
      #expect(result.stdoutTruncated)
      #expect(result.stderrTruncated)
      #expect(startedAt.duration(to: clock.now) < .seconds(3))
    }
  }
}

private func waitUntilProcessStops(_ process: Process) async -> Bool {
  for _ in 0 ..< 100 {
    if !process.isRunning {
      return true
    }
    try? await Task.sleep(nanoseconds: 10_000_000)
  }
  return false
}

private func waitForProcessPID(atPath path: String) async throws -> pid_t {
  for _ in 0 ..< 500 {
    if let text = try? String(contentsOfFile: path, encoding: .utf8),
       let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return pid
    }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
  Issue.record("Timed out waiting for descendant pid file")
  throw CancellationError()
}
