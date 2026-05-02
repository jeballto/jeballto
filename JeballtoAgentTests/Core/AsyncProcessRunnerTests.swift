import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
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
}
