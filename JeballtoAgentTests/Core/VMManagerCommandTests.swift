import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct VMManagerCommandTests {
  @Test
  func managerReportsMissingSSHPortAsConfigurationConflict() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let eventBus = EventBus()
      let manager = VMManager(
        persistenceStore: PersistenceStore(databasePath: config.storage.databasePath),
        eventBus: eventBus,
        config: config
      )
      let definition = try await manager.createVM(name: "running", resources: .default)
      let instance = try await manager.getVMInstance(definition.id)
      await MainActor.run {
        instance.stateMachine.forceState(.running)
        instance.definition.updateState(.running)
      }

      do {
        _ = try await manager.executeCommand(
          definition.id,
          command: "true",
          user: "admin",
          password: nil,
          timeout: 1
        )
        Issue.record("Expected missing SSH port to be rejected")
      } catch let error as CommandExecutorError {
        guard case .sshNotConfigured = error else {
          Issue.record("Expected sshNotConfigured, got \(error)")
          return
        }
      }
    }
  }

  @Test
  func retryingExecutionWaitsForPendingNetworkingSetup() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let manager = VMManager(
        persistenceStore: PersistenceStore(databasePath: config.storage.databasePath),
        eventBus: EventBus(),
        config: config
      )
      let definition = try await manager.createVM(name: "networking", resources: .default)
      let instance = try await manager.getVMInstance(definition.id)
      await MainActor.run {
        instance.stateMachine.forceState(.running)
        instance.definition.updateState(.running)
      }
      let gate = NetworkingSetupTestGate()
      let networkingTask = Task<Void, Never> {
        await gate.wait()
        await MainActor.run {
          instance.definition.network.sshPort = 2222
        }
      }
      await manager.setNetworkingTaskForTesting(networkingTask, vmId: definition.id)
      let execution = Task {
        try await manager.executeCommand(
          definition.id,
          command: "true",
          user: "-invalid",
          password: nil,
          timeout: 1,
          retryOnSSHFailure: true
        )
      }
      try await Task.sleep(for: .milliseconds(20))
      await gate.open()

      do {
        _ = try await execution.value
        Issue.record("Expected invalid SSH username")
      } catch let error as CommandExecutorError {
        guard case .invalidUsername = error else {
          Issue.record("Pending networking setup was not awaited: \(error.localizedDescription)")
          return
        }
      }
    }
  }

  @Test
  func retryingExecutionTimeoutIncludesPendingNetworkingSetup() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let manager = VMManager(
        persistenceStore: PersistenceStore(databasePath: config.storage.databasePath),
        eventBus: EventBus(),
        config: config
      )
      let definition = try await manager.createVM(name: "network-timeout", resources: .default)
      let instance = try await manager.getVMInstance(definition.id)
      await MainActor.run {
        instance.stateMachine.forceState(.running)
        instance.definition.updateState(.running)
      }
      let gate = NetworkingSetupTestGate()
      let networkingTask = Task<Void, Never> {
        await gate.wait()
      }
      await manager.setNetworkingTaskForTesting(networkingTask, vmId: definition.id)

      let started = ProcessInfo.processInfo.systemUptime
      let result: Result<CommandResult, Error>
      do {
        result = try await .success(manager.executeCommand(
          definition.id,
          command: "true",
          user: "admin",
          password: nil,
          timeout: 0.05,
          retryOnSSHFailure: true
        ))
      } catch {
        result = .failure(error)
      }
      let elapsed = ProcessInfo.processInfo.systemUptime - started

      await gate.open()
      _ = await networkingTask.value
      try await manager.awaitNetworkingSetup(definition.id)

      switch result {
      case .success:
        Issue.record("Expected networking setup to consume the command timeout")
      case .failure(let error as CommandExecutorError):
        guard case .timeout(let command, let seconds) = error else {
          Issue.record("Expected command timeout, got \(error)")
          return
        }
        #expect(command == "true")
        #expect(seconds == 0.05)
      case .failure(let error):
        Issue.record("Expected CommandExecutorError.timeout, got \(error)")
      }
      #expect(elapsed < 0.3)
    }
  }

  @Test
  func cancellingRetryingExecutionDoesNotWaitForSharedNetworkingTask() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let manager = VMManager(
        persistenceStore: PersistenceStore(databasePath: config.storage.databasePath),
        eventBus: EventBus(),
        config: config
      )
      let definition = try await manager.createVM(name: "network-cancel", resources: .default)
      let instance = try await manager.getVMInstance(definition.id)
      await MainActor.run {
        instance.stateMachine.forceState(.running)
        instance.definition.updateState(.running)
      }
      let gate = NetworkingSetupTestGate()
      let networkingTask = Task<Void, Never> {
        await gate.wait()
      }
      await manager.setNetworkingTaskForTesting(networkingTask, vmId: definition.id)
      let execution = Task {
        try await manager.executeCommand(
          definition.id,
          command: "true",
          user: "admin",
          password: nil,
          timeout: 60,
          retryOnSSHFailure: true
        )
      }
      #expect(await waitUntilAsync { await gate.hasWaiter })

      let watchdog = Task<Void, Never> {
        try? await Task.sleep(for: .milliseconds(500))
        await gate.open()
      }
      let started = ProcessInfo.processInfo.systemUptime
      execution.cancel()
      let result: Result<CommandResult, Error>
      do {
        result = try await .success(execution.value)
      } catch {
        result = .failure(error)
      }
      let elapsed = ProcessInfo.processInfo.systemUptime - started

      watchdog.cancel()
      await gate.open()
      _ = await networkingTask.value
      try await manager.awaitNetworkingSetup(definition.id)

      switch result {
      case .success:
        Issue.record("Expected cancellation while waiting for networking setup")
      case .failure(is CancellationError):
        break
      case .failure(let error):
        Issue.record("Expected CancellationError, got \(error)")
      }
      #expect(elapsed < 0.3)
    }
  }

  @Test
  func displayOperationsForOneVMAreSerialized() async throws {
    try await withTemporaryDirectory { root in
      let config = makeTestConfig(root: root)
      let manager = VMManager(
        persistenceStore: PersistenceStore(databasePath: config.storage.databasePath),
        eventBus: EventBus(),
        config: config
      )
      let vmId = UUID()
      let probe = DisplayOperationProbe()

      let first = Task {
        try await manager.withExclusiveDisplayOperationForTesting(vmId) {
          await probe.runFirst()
        }
      }
      #expect(await waitUntilAsync { await probe.firstEntered })

      let second = Task {
        try await manager.withExclusiveDisplayOperationForTesting(vmId) {
          await probe.runSecond()
        }
      }
      try await Task.sleep(for: .milliseconds(30))
      #expect(await probe.secondEntered == false)

      await probe.releaseFirst()
      try await first.value
      try await second.value
      #expect(await probe.order == [1, 2])
    }
  }

  @Test
  func commandExecutorRejectsUnsafeUsernameBeforeLaunchingSSH() async {
    await #expect(throws: CommandExecutorError.self) {
      _ = try await CommandExecutor().execute(
        command: "true",
        sshPort: 22,
        user: "-oProxyCommand=whoami",
        password: nil,
        timeout: 1
      )
    }
  }

  @Test
  func commandExecutorRejectsInvalidInputBeforeLaunchingSSH() async {
    await #expect(throws: CommandExecutorError.self) {
      _ = try await CommandExecutor().execute(
        command: "",
        sshPort: 22,
        user: "admin",
        password: nil,
        timeout: 1
      )
    }
    await #expect(throws: CommandExecutorError.self) {
      _ = try await CommandExecutor().execute(
        command: "true",
        sshPort: 22,
        user: "admin",
        password: "invalid\npassword",
        timeout: 1
      )
    }
    await #expect(throws: CommandExecutorError.self) {
      _ = try await CommandExecutor().execute(
        command: "true",
        sshPort: 22,
        user: "admin",
        password: nil,
        timeout: 0
      )
    }
  }

  @Test
  func diskImageResizeCommandUsesDiskutilImageResizeForASIFImages() {
    let command = VMManager.diskImageResizeCommand(
      path: "/tmp/Test.bundle/Disk.img",
      newSize: 107_374_182_400
    )

    #expect(command.executableURL.path == "/usr/sbin/diskutil")
    #expect(command.arguments == ["image", "resize", "--size", "107374182400", "/tmp/Test.bundle/Disk.img"])
  }

  @Test(arguments: ["-n", "pa'ss", #"pa\cword"#])
  func askpassScriptPrintsPasswordLiterally(password: String) throws {
    let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jeballto-askpass-test-\(UUID().uuidString).sh")
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let content = CommandExecutor.askpassScriptContent(for: password)
    try content.write(to: scriptURL, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [scriptURL.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()

    try process.run()
    process.waitUntilExit()

    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8)
    #expect(process.terminationStatus == 0)
    #expect(text == "\(password)\n")
  }

  @Test(arguments: [
    ("ssh: connect to host 127.0.0.1 port 22: Connection refused", true),
    ("ssh: connect to host 127.0.0.1 port 22: Operation timed out", true),
    ("admin@127.0.0.1: Permission denied (publickey,password).", false),
    ("Host key verification failed.", false),
  ])
  func sshRetryClassification(input: (stderr: String, expectedTransient: Bool)) {
    let result = CommandResult(exitCode: 255, stdout: "", stderr: input.stderr)
    #expect(CommandExecutor.isTransientSSHConnectionFailure(result) == input.expectedTransient)
  }
}

private actor NetworkingSetupTestGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard isOpen == false else { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true
    let continuations = waiters
    waiters.removeAll()
    continuations.forEach { $0.resume() }
  }

  var hasWaiter: Bool {
    waiters.isEmpty == false
  }
}

private actor DisplayOperationProbe {
  private(set) var firstEntered = false
  private(set) var secondEntered = false
  private(set) var order: [Int] = []
  private var firstContinuation: CheckedContinuation<Void, Never>?

  func runFirst() async {
    firstEntered = true
    order.append(1)
    await withCheckedContinuation { continuation in
      firstContinuation = continuation
    }
  }

  func runSecond() {
    secondEntered = true
    order.append(2)
  }

  func releaseFirst() {
    let continuation = firstContinuation
    firstContinuation = nil
    continuation?.resume()
  }
}
