import Darwin
import Foundation
import Testing
@testable import JeballtoAgent

struct ChildProcessTrackerTests {
  @Test
  func terminateAllKeepsProcessTrackedUntilExplicitUntrack() async throws {
    let tracker = ChildProcessTracker()
    let observer = ProcessExitObserver()
    let process = makeProcess(executable: "/bin/sleep", arguments: ["60"], observer: observer)
    try process.run()
    defer { killIfRunning(process) }
    tracker.track(process)

    tracker.terminateAll()
    _ = await observer.wait()

    #expect(tracker.trackedProcessCount == 1)
    tracker.untrack(process)
    #expect(tracker.trackedProcessCount == 0)
  }

  @Test
  func processTrackedDuringShutdownIsTerminatedImmediately() async throws {
    let tracker = ChildProcessTracker()
    tracker.terminateAll()
    let observer = ProcessExitObserver()
    let process = makeProcess(executable: "/bin/sleep", arguments: ["60"], observer: observer)
    try process.run()
    defer { killIfRunning(process) }

    tracker.track(process)
    let status = await observer.wait()

    #expect(status == SIGTERM)
    #expect(process.isRunning == false)
    #expect(tracker.trackedProcessCount == 1)
    tracker.untrack(process)
  }

  @Test
  func forceKillAllKillsProcessThatIgnoresTermination() async throws {
    let tracker = ChildProcessTracker()
    let observer = ProcessExitObserver()
    let readyPipe = Pipe()
    let process = makeProcess(
      executable: "/bin/sh",
      arguments: ["-c", "trap '' TERM; printf R; while :; do :; done"],
      observer: observer
    )
    process.standardOutput = readyPipe
    try process.run()
    defer { killIfRunning(process) }
    try? readyPipe.fileHandleForWriting.close()
    let ready = try #require(try readyPipe.fileHandleForReading.read(upToCount: 1))
    #expect(ready == Data("R".utf8))
    tracker.track(process)

    tracker.terminateAll()
    #expect(process.isRunning)
    tracker.forceKillAll()
    let status = await observer.wait()

    #expect(status == SIGKILL)
    #expect(process.isRunning == false)
    #expect(tracker.trackedProcessCount == 1)
    tracker.untrack(process)
  }

  @Test
  func processTrackedAfterForceKillPhaseIsKilledImmediately() async throws {
    let tracker = ChildProcessTracker()
    tracker.forceKillAll()
    let observer = ProcessExitObserver()
    let process = makeProcess(executable: "/bin/sleep", arguments: ["60"], observer: observer)
    try process.run()
    defer { killIfRunning(process) }

    tracker.track(process)
    let status = await observer.wait()

    #expect(status == SIGKILL)
    #expect(process.isRunning == false)
    tracker.untrack(process)
  }

  @Test
  func alreadyExitedProcessIsNotRetained() async throws {
    let tracker = ChildProcessTracker()
    let observer = ProcessExitObserver()
    let process = makeProcess(executable: "/usr/bin/true", arguments: [], observer: observer)
    try process.run()
    _ = await observer.wait()

    tracker.track(process)

    #expect(tracker.trackedProcessCount == 0)
  }
}

private func makeProcess(
  executable: String,
  arguments: [String],
  observer: ProcessExitObserver
) -> Process {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  process.terminationHandler = { process in
    observer.finish(process.terminationStatus)
  }
  return process
}

private func killIfRunning(_ process: Process) {
  guard process.isRunning else { return }
  _ = kill(process.processIdentifier, SIGKILL)
}
