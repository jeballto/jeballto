import Foundation

struct CommandResult {
  let exitCode: Int32
  let stdout: String
  let stderr: String
}

enum CommandExecutorError: Error, LocalizedError {
  case sshNotConfigured(String)
  case timeout(command: String, seconds: TimeInterval)
  case processLaunchFailed(String)
  case askpassScriptFailed(String)

  var errorDescription: String? {
    switch self {
    case .sshNotConfigured(let msg): "SSH not configured: \(msg)"
    case .timeout(let command, let seconds):
      "Command timed out after \(Int(seconds))s: \(command.prefix(100))"
    case .processLaunchFailed(let msg): "Failed to launch SSH process: \(msg)"
    case .askpassScriptFailed(let msg): "Failed to create SSH_ASKPASS script: \(msg)"
    }
  }

  var isTimeout: Bool {
    if case .timeout = self { return true }
    return false
  }
}

class CommandExecutor {
  /// Maximum allowed output size per stream (stdout/stderr)  - 5 MB
  private static let maxOutputSize = 5 * 1024 * 1024

  /// Maximum allowed command length  - 64 KB
  static let maxCommandLength = 65536

  func execute(
    command: String,
    sshPort: Int,
    user: String,
    password: String?,
    timeout: TimeInterval,
    retryOnSSHFailure: Bool = false
  ) async throws -> CommandResult {
    guard command.count <= Self.maxCommandLength else {
      throw CommandExecutorError
        .processLaunchFailed("Command too long (\(command.count) characters, max \(Self.maxCommandLength))")
    }

    let result = try await executeOnce(
      command: command,
      sshPort: sshPort,
      user: user,
      password: password,
      timeout: timeout
    )

    // Retry on SSH connection failure (exit code 255) if requested.
    // This handles cases where SSH daemon is not yet ready after being enabled.
    // macOS SSH daemon startup inside a guest VM takes 30-60s, so 20 retries covers the full window.
    if retryOnSSHFailure, result.exitCode == 255 {
      let maxRetries = 20
      let retryDelay: UInt64 = 3_000_000_000 // 3 seconds
      for attempt in 1 ... maxRetries {
        logInfo(
          "SSH connection failed (exit 255), retry \(attempt)/\(maxRetries) in 3s",
          category: "CommandExecutor"
        )
        try await Task.sleep(nanoseconds: retryDelay)

        let retryResult = try await executeOnce(
          command: command,
          sshPort: sshPort,
          user: user,
          password: password,
          timeout: timeout
        )
        if retryResult.exitCode != 255 {
          return retryResult
        }
      }
      logWarning("SSH connection failed after \(maxRetries) retries", category: "CommandExecutor")
    }

    return result
  }

  /// Single SSH execution attempt (no retry). Used by retry loop to create a fresh Process.
  private func executeOnce(
    command: String,
    sshPort: Int,
    user: String,
    password: String?,
    timeout: TimeInterval
  ) async throws -> CommandResult {
    var askpassPath: String?
    defer {
      if let path = askpassPath {
        try? FileManager.default.removeItem(atPath: path)
      }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

    var args = [
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null",
      "-o", "ConnectTimeout=5",
      "-o", "LogLevel=ERROR",
      "-p", "\(sshPort)",
      "\(user)@127.0.0.1",
      command,
    ]

    if let password {
      let scriptPath: String
      do {
        scriptPath = try createAskpassScript(password: password)
      } catch {
        throw CommandExecutorError.askpassScriptFailed(error.localizedDescription)
      }
      askpassPath = scriptPath

      var env = ProcessInfo.processInfo.environment
      env["SSH_ASKPASS"] = scriptPath
      env["SSH_ASKPASS_REQUIRE"] = "force"
      env["DISPLAY"] = ":0"
      process.environment = env

      args.insert(contentsOf: ["-o", "BatchMode=no"], at: 0)
    }

    process.arguments = args

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = FileHandle.nullDevice

    return try await runSSHProcess(
      process: process,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe,
      command: command,
      timeout: timeout
    )
  }

  private func runSSHProcess(
    process: Process,
    stdoutPipe: Pipe,
    stderrPipe: Pipe,
    command: String,
    timeout: TimeInterval
  ) async throws -> CommandResult {
    do {
      let result = try await AsyncProcessRunner.run(
        process: process,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        options: AsyncProcessRunnerOptions(
          timeout: timeout,
          timeoutDescription: command,
          maxOutputSize: Self.maxOutputSize
        )
      )
      return CommandResult(
        exitCode: result.exitCode,
        stdout: String(data: result.stdout, encoding: .utf8) ?? "",
        stderr: String(data: result.stderr, encoding: .utf8) ?? ""
      )
    } catch let error as AsyncProcessRunnerError {
      switch error {
      case .launchFailed(let message):
        throw CommandExecutorError.processLaunchFailed(message)
      case .timeout:
        throw CommandExecutorError.timeout(command: command, seconds: timeout)
      }
    }
  }

  private func createAskpassScript(password: String) throws -> String {
    let tempDir = NSTemporaryDirectory()
    let scriptPath = "\(tempDir)jeballto_askpass_\(UUID().uuidString).sh"
    let escapedPassword = password
      .replacingOccurrences(of: "'", with: "'\\''")
      .replacingOccurrences(of: "\n", with: "")
      .replacingOccurrences(of: "\r", with: "")
    let content = "#!/bin/sh\necho '\(escapedPassword)'\n"

    // Create file with 0o700 permissions atomically to avoid TOCTOU race
    // (no window where file exists with default permissions)
    let data = content.data(using: .utf8) ?? Data()
    guard FileManager.default.createFile(
      atPath: scriptPath,
      contents: data,
      attributes: [.posixPermissions: 0o700]
    ) else {
      throw CommandExecutorError.askpassScriptFailed("Failed to create askpass script at \(scriptPath)")
    }

    return scriptPath
  }
}
