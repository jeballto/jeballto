import Foundation

struct CommandResult: Sendable {
  let exitCode: Int32
  let stdout: String
  let stderr: String
  let stdoutTruncated: Bool
  let stderrTruncated: Bool

  init(
    exitCode: Int32,
    stdout: String,
    stderr: String,
    stdoutTruncated: Bool = false,
    stderrTruncated: Bool = false
  ) {
    self.exitCode = exitCode
    self.stdout = stdout
    self.stderr = stderr
    self.stdoutTruncated = stdoutTruncated
    self.stderrTruncated = stderrTruncated
  }
}

enum CommandExecutorError: Error, LocalizedError {
  case sshNotConfigured(String)
  case invalidUsername(String)
  case invalidCommand(String)
  case invalidPassword(String)
  case invalidTimeout(TimeInterval)
  case timeout(command: String, seconds: TimeInterval)
  case processLaunchFailed(String)
  case askpassScriptFailed(String)

  var errorDescription: String? {
    switch self {
    case .sshNotConfigured(let msg): "SSH not configured: \(msg)"
    case .invalidUsername(let username): "Invalid SSH username: '\(username)'"
    case .invalidCommand(let message): "Invalid command: \(message)"
    case .invalidPassword(let message): "Invalid SSH password: \(message)"
    case .invalidTimeout(let seconds): "Invalid command timeout: \(seconds) seconds"
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

enum SSHUsernameValidator {
  static let maximumLength = 255

  static var validationError: String {
    "Invalid SSH username. Use 1-\(maximumLength) ASCII letters, digits, dots, hyphens, or underscores; "
      + "the first character cannot be a dot or hyphen"
  }

  static func validate(_ username: String) -> Bool {
    let bytes = Array(username.utf8)
    guard !bytes.isEmpty, bytes.count <= maximumLength, isLeadingByte(bytes[0]) else { return false }
    return bytes.allSatisfy(isAllowedByte)
  }

  private static func isLeadingByte(_ byte: UInt8) -> Bool {
    isASCIILetter(byte) || isASCIIDigit(byte) || byte == 0x5F
  }

  private static func isAllowedByte(_ byte: UInt8) -> Bool {
    isLeadingByte(byte) || byte == 0x2D || byte == 0x2E
  }

  private static func isASCIILetter(_ byte: UInt8) -> Bool {
    (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte)
  }

  private static func isASCIIDigit(_ byte: UInt8) -> Bool {
    (0x30 ... 0x39).contains(byte)
  }
}

final class CommandExecutor {
  /// Maximum allowed output size per stream (stdout/stderr)  - 5 MB
  private static let maxOutputSize = 5 * 1024 * 1024

  /// Maximum allowed command length  - 64 KB
  static let maxCommandLength = 65536
  static let maxPasswordLength = 16384

  func execute(
    command: String,
    sshPort: Int,
    user: String,
    password: String?,
    timeout: TimeInterval,
    retryOnSSHFailure: Bool = false
  ) async throws -> CommandResult {
    guard SSHUsernameValidator.validate(user) else {
      throw CommandExecutorError.invalidUsername(user)
    }
    guard command.isEmpty == false else {
      throw CommandExecutorError.invalidCommand("Command must not be empty")
    }
    let commandByteCount = command.utf8.count
    guard commandByteCount <= Self.maxCommandLength else {
      throw CommandExecutorError.invalidCommand(
        "Command is too long (\(commandByteCount) UTF-8 bytes, max \(Self.maxCommandLength))"
      )
    }
    if let password, let validationError = Self.passwordValidationError(password) {
      throw CommandExecutorError.invalidPassword(validationError)
    }
    guard timeout.isFinite, timeout > 0 else {
      throw CommandExecutorError.invalidTimeout(timeout)
    }

    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var result = try await executeOnce(
      command: command,
      sshPort: sshPort,
      user: user,
      password: password,
      timeout: timeout
    )

    // Retry only transient connection failures, bounded by the caller's overall deadline.
    if retryOnSSHFailure, Self.isTransientSSHConnectionFailure(result) {
      var attempt = 0
      while Self.isTransientSSHConnectionFailure(result) {
        attempt += 1
        let remainingBeforeDelay = deadline - ProcessInfo.processInfo.systemUptime
        guard remainingBeforeDelay > 0 else {
          throw CommandExecutorError.timeout(command: command, seconds: timeout)
        }
        logInfo(
          "SSH connection is not ready, retry \(attempt) in 3s",
          category: "CommandExecutor"
        )
        try await Task.sleep(for: .seconds(min(3, remainingBeforeDelay)))

        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
          throw CommandExecutorError.timeout(command: command, seconds: timeout)
        }
        result = try await executeOnce(
          command: command,
          sshPort: sshPort,
          user: user,
          password: password,
          timeout: remaining
        )
      }
    }

    return result
  }

  static func isTransientSSHConnectionFailure(_ result: CommandResult) -> Bool {
    guard result.exitCode == 255 else { return false }
    let message = result.stderr.lowercased()
    return [
      "connection refused",
      "connection timed out",
      "operation timed out",
      "no route to host",
      "connection reset",
      "kex_exchange_identification",
    ].contains { message.contains($0) }
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
        do {
          try FileManager.default.removeItem(atPath: path)
        } catch {
          logWarning("Failed to remove SSH_ASKPASS script at \(path): \(error)", category: "CommandExecutor")
        }
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
      "--",
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
        stdout: String(decoding: result.stdout, as: UTF8.self),
        stderr: String(decoding: result.stderr, as: UTF8.self),
        stdoutTruncated: result.stdoutTruncated,
        stderrTruncated: result.stderrTruncated
      )
    } catch let error as AsyncProcessRunnerError {
      switch error {
      case .launchFailed(let message):
        throw CommandExecutorError.processLaunchFailed(message)
      case .inputWriteFailed(let message):
        throw CommandExecutorError.processLaunchFailed("Failed to write process standard input: \(message)")
      case .timeout:
        throw CommandExecutorError.timeout(command: command, seconds: timeout)
      }
    }
  }

  static func askpassScriptContent(for password: String) -> String {
    let escapedPassword = password
      .replacingOccurrences(of: "'", with: "'\\''")
    return "#!/bin/sh\nprintf '%s\\n' '\(escapedPassword)'\n"
  }

  static func passwordValidationError(_ password: String) -> String? {
    let byteCount = password.utf8.count
    if byteCount > maxPasswordLength {
      return "Password is too long (\(byteCount) UTF-8 bytes, max \(maxPasswordLength))"
    }
    if password.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) {
      return "Password must not contain NUL, carriage return, or newline characters"
    }
    return nil
  }

  private func createAskpassScript(password: String) throws -> String {
    let tempDir = NSTemporaryDirectory()
    let scriptPath = "\(tempDir)jeballto_askpass_\(UUID().uuidString).sh"
    let content = Self.askpassScriptContent(for: password)

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
