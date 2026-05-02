import Foundation

/// Errors from oras CLI operations
enum OrasError: Error, LocalizedError {
  case orasNotFound(String)
  case commandFailed(exitCode: Int32, stderr: String)
  case invalidOutput(String)
  case timeout(String)

  var errorDescription: String? {
    switch self {
    case .orasNotFound(let msg): "oras binary not found: \(msg)"
    case .commandFailed(let code, let stderr): "oras command failed (exit \(code)): \(stderr)"
    case .invalidOutput(let msg): "Invalid oras output: \(msg)"
    case .timeout(let msg): "oras command timed out: \(msg)"
    }
  }
}

/// Result of an oras pull operation
struct OrasPullResult {
  let digest: String
  let rawOutput: String
}

/// Result of an oras push operation
struct OrasPushResult {
  let digest: String
  let rawOutput: String
}

/// OCI artifact type for Jeballto VM bundles
let jeballtoArtifactType = "application/vnd.jeballto.vm.bundle.v1"

/// Swift wrapper around the oras CLI binary.
/// Uses Process with array arguments (no shell) to prevent command injection.
struct OrasClient {
  private let config: ImageConfig

  /// Maximum output size per stream (stdout/stderr)
  private static let maxOutputSize = 5 * 1024 * 1024

  /// Default timeout for oras push/pull: nil means unlimited
  private static let defaultTimeout: TimeInterval? = nil

  /// Timeout for short commands (login, logout, resolve)
  private static let shortTimeout: TimeInterval = 30

  init(config: ImageConfig) {
    self.config = config
  }

  // MARK: - Public API

  /// Pulls an OCI artifact to a local directory
  func pull(
    reference: ImageReference,
    outputDir: String,
    insecure: Bool = false,
    timeout: TimeInterval? = nil
  ) async throws -> OrasPullResult {
    var args = ["pull", reference.fullReference, "-o", outputDir, "--format", "json"]
    if insecure { args.append("--insecure") }

    let result = try await execute(arguments: args, timeout: timeout ?? Self.defaultTimeout)
    let stdout = String(data: result.stdout, encoding: .utf8) ?? ""

    // Parse digest from JSON output
    let digest = parseDigestFromJSON(stdout) ?? "unknown"

    return OrasPullResult(digest: digest, rawOutput: stdout)
  }

  /// Pushes files as an OCI artifact
  func push(
    reference: ImageReference,
    files: [String],
    artifactType: String = jeballtoArtifactType,
    insecure: Bool = false,
    timeout: TimeInterval? = nil
  ) async throws -> OrasPushResult {
    // Use relative paths from a common parent directory so oras stores
    // portable layer annotations. This prevents path traversal on pull.
    let (workDir, relativeFiles) = resolveRelativePaths(files)

    var args = ["push", reference.fullReference]
    args.append(contentsOf: relativeFiles)
    args.append(contentsOf: ["--artifact-type", artifactType, "--format", "json", "--disable-path-validation"])
    if insecure { args.append("--insecure") }

    let result = try await execute(arguments: args, timeout: timeout ?? Self.defaultTimeout, workingDirectory: workDir)
    let stdout = String(data: result.stdout, encoding: .utf8) ?? ""

    let digest = parseDigestFromJSON(stdout) ?? "unknown"

    return OrasPushResult(digest: digest, rawOutput: stdout)
  }

  /// Given a list of absolute file paths, returns a common parent directory
  /// and the paths rewritten as relative to that parent.
  private func resolveRelativePaths(_ files: [String]) -> (workDir: String?, relativeFiles: [String]) {
    guard !files.isEmpty else { return (nil, files) }
    // Use the parent of the first file as the working directory
    let parent = (files[0] as NSString).deletingLastPathComponent
    let relative = files.map { path -> String in
      if path.hasPrefix(parent + "/") {
        return String(path.dropFirst(parent.count + 1))
      }
      return path
    }
    return (parent, relative)
  }

  /// Authenticates to an OCI registry.
  /// Password is passed via stdin to avoid exposure in process listings.
  func login(registry: String, username: String, password: String, insecure: Bool = false) async throws {
    var args = ["login", registry, "-u", username, "--password-stdin"]
    if insecure { args.append("--insecure") }

    let orasPath = try resolveOrasPath()

    let process = Process()
    process.executableURL = URL(fileURLWithPath: orasPath)
    process.arguments = args

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let result: ProcessExecutionResult
    do {
      result = try await AsyncProcessRunner.run(
        process: process,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        options: AsyncProcessRunnerOptions(
          timeout: Self.shortTimeout,
          timeoutDescription: "login to \(registry)",
          maxOutputSize: Self.maxOutputSize
        ),
        afterLaunch: { _ in
          let passwordData = Data((password + "\n").utf8)
          stdinPipe.fileHandleForWriting.write(passwordData)
          stdinPipe.fileHandleForWriting.closeFile()
        }
      )
    } catch let error as AsyncProcessRunnerError {
      throw mapProcessRunnerError(error)
    }

    if result.exitCode != 0 {
      let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
      throw OrasError.commandFailed(exitCode: result.exitCode, stderr: stderr)
    }
  }

  /// Checks if the registry endpoint is reachable before starting a long push.
  /// Hits the OCI distribution spec health endpoint at <scheme>://registryHost/v2/.
  /// Accepts HTTP 200 or 401 (auth required but registry alive). Uses a 5-second timeout.
  /// Pass a custom `session` to override the default ephemeral URLSession (used in tests).
  func checkRegistryReachable(registryHost: String, insecure: Bool, session: URLSession? = nil) async throws {
    let scheme = insecure ? "http" : "https"
    guard let url = URL(string: "\(scheme)://\(registryHost)/v2/") else {
      throw OrasError.commandFailed(exitCode: -1, stderr: "Invalid registry URL for host: \(registryHost)")
    }

    let effectiveSession: URLSession
    if let session {
      effectiveSession = session
    } else {
      let sessionConfig = URLSessionConfiguration.ephemeral
      sessionConfig.timeoutIntervalForRequest = 5
      sessionConfig.timeoutIntervalForResource = 5
      effectiveSession = URLSession(configuration: sessionConfig)
    }

    do {
      let (_, response) = try await effectiveSession.data(from: url)
      guard let http = response as? HTTPURLResponse else {
        throw OrasError.commandFailed(exitCode: -1, stderr: "Non-HTTP response from \(registryHost)")
      }
      guard http.statusCode == 200 || http.statusCode == 401 else {
        throw OrasError.commandFailed(
          exitCode: -1,
          stderr: "Registry \(registryHost) returned unexpected status \(http.statusCode)"
        )
      }
    } catch let error as OrasError {
      throw error
    } catch {
      throw OrasError.commandFailed(
        exitCode: -1,
        stderr: "Cannot reach registry \(registryHost): \(error.localizedDescription)"
      )
    }
  }

  /// Removes stored credentials for a registry
  func logout(registry: String) async throws {
    let args = ["logout", registry]
    _ = try await execute(arguments: args, timeout: Self.shortTimeout)
  }

  /// Resolves the digest for a reference without downloading
  func resolve(reference: ImageReference, insecure: Bool = false) async throws -> String {
    var args = ["resolve", reference.fullReference]
    if insecure { args.append("--insecure") }

    let result = try await execute(arguments: args, timeout: Self.shortTimeout)
    let stdout = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !stdout.isEmpty else {
      throw OrasError.invalidOutput("Empty digest from resolve")
    }

    return stdout
  }

  // MARK: - Core Execution

  /// Resolves the path to the oras binary.
  /// Checks config override first, then falls back to the bundled binary in .app Resources.
  private func resolveOrasPath() throws -> String {
    if let customPath = config.orasPath {
      guard FileManager.default.fileExists(atPath: customPath) else {
        throw OrasError.orasNotFound("Custom path does not exist: \(customPath)")
      }
      return customPath
    }

    if let bundledPath = Bundle.main.resourceURL?.appendingPathComponent("oras").path,
       FileManager.default.fileExists(atPath: bundledPath)
    {
      return bundledPath
    }

    throw OrasError.orasNotFound(
      "No oras binary found. Set images.orasPath in config or place oras in the app bundle Resources."
    )
  }

  /// Executes an oras command with optional timeout protection.
  /// When timeout is nil, the process runs until completion (unlimited).
  /// Terminates the child process on Task cancellation or app shutdown.
  /// Redirects oras temp files to a controlled directory for cleanup.
  /// Uses Process with arguments array - no shell invocation.
  private func execute(
    arguments: [String],
    timeout: TimeInterval?,
    workingDirectory: String? = nil
  ) async throws -> (stdout: Data, stderr: Data) {
    let orasPath = try resolveOrasPath()

    logDebug("oras \(arguments.joined(separator: " "))", category: "OrasClient")

    // Create a per-operation temp dir so oras intermediate files don't leak
    // into the system temp on interruption. Cleaned up in defer below.
    let orasTmpDir = "\(config.imageStorageDir)/oras-tmp-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: orasTmpDir, withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: orasPath)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(["TMPDIR": orasTmpDir]) { _, new in new }
    if let workDir = workingDirectory {
      process.currentDirectoryURL = URL(fileURLWithPath: workDir)
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = FileHandle.nullDevice

    defer { try? FileManager.default.removeItem(atPath: orasTmpDir) }

    let result: ProcessExecutionResult
    do {
      result = try await AsyncProcessRunner.run(
        process: process,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        options: AsyncProcessRunnerOptions(
          timeout: timeout,
          timeoutDescription: "oras \(arguments.first ?? "command")",
          maxOutputSize: Self.maxOutputSize
        )
      )
    } catch let error as AsyncProcessRunnerError {
      throw mapProcessRunnerError(error)
    }

    if result.exitCode != 0 {
      let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
      throw OrasError.commandFailed(exitCode: result.exitCode, stderr: stderr)
    }

    return (stdout: result.stdout, stderr: result.stderr)
  }

  private func mapProcessRunnerError(_ error: AsyncProcessRunnerError) -> OrasError {
    switch error {
    case .launchFailed(let message):
      .commandFailed(exitCode: -1, stderr: "Failed to launch oras: \(message)")
    case .timeout(let command):
      .timeout(command)
    }
  }

  // MARK: - Output Parsing

  /// Attempts to extract digest from oras JSON output
  private func parseDigestFromJSON(_ output: String) -> String? {
    guard let data = output.data(using: .utf8) else { return nil }

    // oras --format json outputs a JSON object with a "digest" field
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let digest = json["digest"] as? String
    {
      return digest
    }

    return nil
  }
}
