import CryptoKit
import Darwin
import Foundation

/// Errors from oras CLI operations
enum OrasError: Error, LocalizedError {
  case invalidInput(String)
  case orasNotFound(String)
  case commandFailed(exitCode: Int32, stderr: String)
  case invalidOutput(String)
  case timeout(String)
  case manifestCommitOutcomeUnknown(String)

  var errorDescription: String? {
    switch self {
    case .invalidInput(let msg): "Invalid oras input: \(msg)"
    case .orasNotFound(let msg): "oras binary not found: \(msg)"
    case .commandFailed(let code, let stderr): "oras command failed (exit \(code)): \(stderr)"
    case .invalidOutput(let msg): "Invalid oras output: \(msg)"
    case .timeout(let msg): "oras command timed out: \(msg)"
    case .manifestCommitOutcomeUnknown(let msg):
      "OCI manifest publication started, but its commit outcome is unknown: \(msg)"
    }
  }
}

private final class OrasManifestPushAttempt: @unchecked Sendable {
  private let lock = NSLock()
  private var processStarted = false

  var didStart: Bool {
    lock.withLock { processStarted }
  }

  func markStarted() {
    lock.withLock { processStarted = true }
  }
}

/// Swift wrapper around the oras CLI binary.
/// Uses Process with array arguments (no shell) to prevent command injection.
struct OrasClient: Sendable {
  private let config: ImageConfig
  private let temporaryRoot: URL
  private let credentialStore: RegistryCredentialStore
  private let childProcessLease: ImageWorkChildProcessLease?

  /// Maximum output size per stream (stdout/stderr)
  private static let maxOutputSize = 8 * 1024 * 1024

  /// Default timeout for oras push/pull: nil means unlimited
  private static let defaultTimeout: TimeInterval? = nil

  /// Timeout for short commands (login, logout, resolve)
  private static let shortTimeout: TimeInterval = 30

  init(
    config: ImageConfig,
    temporaryRoot: URL,
    credentialStore: RegistryCredentialStore = .shared,
    childProcessLease: ImageWorkChildProcessLease? = nil
  ) {
    self.config = config
    self.temporaryRoot = temporaryRoot
    self.credentialStore = credentialStore
    self.childProcessLease = childProcessLease
  }

  var imageWorkSessionURL: URL {
    temporaryRoot
  }

  var imageWorkChildProcessLease: ImageWorkChildProcessLease? {
    childProcessLease
  }

  func updatingConfig(_ config: ImageConfig) -> OrasClient {
    OrasClient(
      config: config,
      temporaryRoot: temporaryRoot,
      credentialStore: credentialStore,
      childProcessLease: childProcessLease
    )
  }

  // MARK: - Public API

  /// Checks if a blob digest exists in a repository.
  func blobPresence(
    repositoryReference: String,
    digest: String,
    insecure: Bool = false
  ) async throws -> OrasBlobPresence {
    try Task.checkCancellation()

    var args = ["blob", "fetch", "--descriptor", "\(repositoryReference)@\(digest)"]
    args.append(contentsOf: Self.transportSecurityArguments(plainHTTP: insecure))

    do {
      _ = try await execute(
        arguments: args,
        timeout: Self.shortTimeout,
        registryHost: Self.registryHost(fromRepositoryReference: repositoryReference)
      )
      return .exists
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as OrasError {
      if Self.isMissingBlobError(error) {
        return .missing
      }
      throw error
    } catch {
      throw error
    }
  }

  /// Uploads one OCI blob and returns its descriptor.
  func pushBlob(
    repositoryReference: String,
    digest: String,
    filePath: String,
    mediaType: String,
    expectedSize: UInt64,
    insecure: Bool = false,
    timeout: TimeInterval? = nil
  ) async throws -> OrasDescriptor {
    let actualSize = try fileSize(atPath: filePath)
    guard actualSize == expectedSize else {
      throw OrasError.invalidOutput("Blob \(digest) size mismatch: expected \(expectedSize), got \(actualSize)")
    }
    let actualDigest = try sha256File(atPath: filePath)
    guard actualDigest == digest else {
      throw OrasError.invalidOutput("Blob \(digest) digest mismatch: got \(actualDigest)")
    }

    var args = [
      "blob", "push",
      "--descriptor",
      "--media-type", mediaType,
      "--size", String(expectedSize),
      "\(repositoryReference)@\(digest)",
      filePath,
    ]
    args.append(contentsOf: Self.transportSecurityArguments(plainHTTP: insecure))

    let result = try await execute(
      arguments: args,
      timeout: timeout ?? Self.defaultTimeout,
      registryHost: Self.registryHost(fromRepositoryReference: repositoryReference)
    )
    let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
    guard let descriptor = parseDescriptorFromJSON(stdout) else {
      throw OrasError.invalidOutput("blob push did not return a valid descriptor")
    }
    try Self.validateReturnedDescriptor(
      descriptor,
      expectedMediaType: mediaType,
      expectedDigest: digest,
      expectedSize: expectedSize,
      operation: "blob push"
    )
    return descriptor
  }

  /// Pushes an OCI image manifest and returns the pushed manifest digest.
  func pushManifest(
    reference: ImageReference,
    manifestPath: String,
    insecure: Bool = false,
    timeout: TimeInterval? = nil
  ) async throws -> OrasPushResult {
    let expectedManifest = try OrasLocalManifest.metadata(atPath: manifestPath)
    var args = [
      "manifest", "push",
      "--descriptor",
      "--media-type", ociImageManifestMediaType,
      reference.fullReference,
      manifestPath,
    ]
    args.append(contentsOf: Self.transportSecurityArguments(plainHTTP: insecure))

    let attempt = OrasManifestPushAttempt()
    do {
      let result = try await execute(
        arguments: args,
        timeout: timeout ?? Self.defaultTimeout,
        registryHost: reference.registry,
        onProcessStarted: { attempt.markStarted() }
      )
      let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
      guard let descriptor = parseDescriptorFromJSON(stdout) else {
        throw OrasError.invalidOutput("manifest push did not return a valid descriptor")
      }
      try Self.validateReturnedDescriptor(
        descriptor,
        expectedMediaType: ociImageManifestMediaType,
        expectedDigest: expectedManifest.digest,
        expectedSize: expectedManifest.size,
        operation: "manifest push"
      )
      return OrasPushResult(digest: descriptor.digest)
    } catch {
      guard attempt.didStart else { throw error }
      if case OrasError.manifestCommitOutcomeUnknown = error {
        throw error
      }
      throw OrasError.manifestCommitOutcomeUnknown(error.localizedDescription)
    }
  }

  /// Fetches the raw OCI manifest so callers can verify the Jeballto image format.
  func fetchManifest(reference: ImageReference, insecure: Bool = false) async throws -> OrasManifestInfo {
    var args = ["manifest", "fetch", reference.fullReference]
    args.append(contentsOf: Self.transportSecurityArguments(plainHTTP: insecure))

    let result = try await execute(
      arguments: args,
      timeout: Self.shortTimeout,
      registryHost: reference.registry
    )
    guard let stdout = String(data: result.stdout, encoding: .utf8) else {
      throw OrasError.invalidOutput("Manifest output is not valid UTF-8")
    }
    do {
      return try OrasManifestInfo(rawManifest: stdout)
    } catch {
      throw OrasError
        .invalidOutput("Failed to decode manifest for \(reference.fullReference): \(error.localizedDescription)")
    }
  }

  /// Fetches a single OCI blob by digest.
  func fetchBlob(
    reference: ImageReference,
    digest: String,
    outputPath: String,
    expectedSize: UInt64? = nil,
    insecure: Bool = false,
    timeout: TimeInterval? = nil
  ) async throws {
    let outputParent = (outputPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: outputParent, withIntermediateDirectories: true)

    let tempOutputPath = "\(outputPath).partial-\(UUID().uuidString)"
    var args = ["blob", "fetch", "--output", "-", blobReference(reference, digest: digest)]
    args.append(contentsOf: Self.transportSecurityArguments(plainHTTP: insecure))

    do {
      try await executeToFile(
        arguments: args,
        outputPath: tempOutputPath,
        timeout: timeout ?? Self.defaultTimeout,
        registryHost: reference.registry
      )
      if let expectedSize {
        let actualSize = try fileSize(atPath: tempOutputPath)
        guard actualSize == expectedSize else {
          throw OrasBlobValidationError.sizeMismatch(
            digest: digest,
            expected: expectedSize,
            actual: actualSize
          )
        }
      }
      let actualDigest = try sha256File(atPath: tempOutputPath)
      guard actualDigest == digest else {
        throw OrasBlobValidationError.digestMismatch(expected: digest, actual: actualDigest)
      }
      if FileManager.default.fileExists(atPath: outputPath) {
        try FileManager.default.removeItem(atPath: outputPath)
      }
      try FileManager.default.moveItem(atPath: tempOutputPath, toPath: outputPath)
    } catch {
      try? FileManager.default.removeItem(atPath: tempOutputPath)
      throw error
    }
  }

  private func blobReference(_ reference: ImageReference, digest: String) -> String {
    "\(reference.registry)/\(reference.repository)@\(digest)"
  }

  static func repositoryReference(_ reference: ImageReference) -> String {
    "\(reference.registry)/\(reference.repository)"
  }

  static func transportSecurityArguments(plainHTTP: Bool) -> [String] {
    plainHTTP ? ["--plain-http"] : []
  }

  static func reachabilityHost(for registryHost: String) -> String {
    registryHost == "docker.io" ? "registry-1.docker.io" : registryHost
  }

  private static func registryHost(fromRepositoryReference reference: String) throws -> String {
    guard let separator = reference.firstIndex(of: "/"), separator != reference.startIndex else {
      throw OrasError.invalidInput("Repository reference must include a registry host")
    }
    let registry = String(reference[..<separator])
    guard RegistryCredentialValidator.registryError(registry) == nil else {
      throw OrasError.invalidInput("Repository reference has an invalid registry host")
    }
    return registry
  }

  /// Authenticates to an OCI registry.
  /// Password is passed via stdin to avoid exposure in process listings.
  func login(registry: String, username: String, password: String, insecure: Bool = false) async throws {
    if let error = RegistryCredentialValidator.loginError(
      registry: registry,
      username: username,
      password: password
    ) {
      throw OrasError.invalidInput(error)
    }
    var args = ["login", registry, "-u", username, "--password-stdin"]
    args.append(contentsOf: Self.transportSecurityArguments(plainHTTP: insecure))
    _ = try await execute(
      arguments: args,
      timeout: Self.shortTimeout,
      standardInputData: Data((password + "\n").utf8)
    )
    try await credentialStore.save(
      RegistryCredential(username: username, password: password),
      for: registry
    )
  }

  /// Checks if the registry endpoint is reachable before starting a long push.
  /// Hits the OCI distribution spec health endpoint at <scheme>://registryHost/v2/.
  /// Accepts success, an authentication challenge, or an authorization denial.
  /// Other status codes report the registry as unavailable. Uses a 5-second timeout.
  /// Pass a custom `session` to override the default ephemeral URLSession (used in tests).
  func checkRegistryReachable(registryHost: String, insecure: Bool, session: URLSession? = nil) async throws {
    try Task.checkCancellation()
    if let error = RegistryCredentialValidator.registryError(registryHost) {
      throw OrasError.invalidInput(error)
    }
    let scheme = insecure ? "http" : "https"
    let reachabilityHost = Self.reachabilityHost(for: registryHost)
    guard let url = URL(string: "\(scheme)://\(reachabilityHost)/v2/") else {
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
      let (bytes, response) = try await effectiveSession.bytes(from: url)
      defer { bytes.task.cancel() }
      guard let http = response as? HTTPURLResponse else {
        throw OrasError.commandFailed(exitCode: -1, stderr: "Non-HTTP response from \(registryHost)")
      }
      guard [200, 401, 403].contains(http.statusCode) else {
        throw OrasError.commandFailed(
          exitCode: -1,
          stderr: "Registry \(registryHost) availability check returned HTTP \(http.statusCode)"
        )
      }
    } catch let error as OrasError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw OrasError.commandFailed(
        exitCode: -1,
        stderr: "Cannot reach registry \(registryHost): \(error.localizedDescription)"
      )
    }
  }

  /// Removes stored credentials for a registry
  func logout(registry: String) async throws {
    if let error = RegistryCredentialValidator.registryError(registry) {
      throw OrasError.invalidInput(error)
    }
    try await credentialStore.deleteCredential(for: registry)
  }

  /// Resolves the digest for a reference without downloading
  func resolve(reference: ImageReference, insecure: Bool = false) async throws -> String {
    var args = ["resolve", reference.fullReference]
    args.append(contentsOf: Self.transportSecurityArguments(plainHTTP: insecure))

    let result = try await execute(
      arguments: args,
      timeout: Self.shortTimeout,
      registryHost: reference.registry
    )
    let stdout = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard stdout.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil else {
      throw OrasError.invalidOutput("Resolve returned an invalid digest: \(stdout.prefix(100))")
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
    workingDirectory: String? = nil,
    registryHost: String? = nil,
    standardInputData: Data? = nil,
    onProcessStarted: (@Sendable () -> Void)? = nil
  ) async throws -> ProcessExecutionResult {
    let orasPath = try resolveOrasPath()

    // Create a per-operation temp dir so oras intermediate files don't leak
    // into the system temp on interruption. Cleaned up in defer below.
    let orasTmpDir = temporaryRoot
      .appendingPathComponent("oras-tmp-\(UUID().uuidString)", isDirectory: true)
      .path
    try Self.createPrivateDirectory(atPath: orasTmpDir)
    defer { try? FileManager.default.removeItem(atPath: orasTmpDir) }

    let prepared = try await prepareExecution(
      arguments: arguments,
      registryHost: registryHost,
      registryConfigPath: "\(orasTmpDir)/registry-config.json",
      standardInputData: standardInputData
    )
    try Task.checkCancellation()
    logDebug("oras \(Self.sanitizedArguments(prepared.arguments))", category: "OrasClient")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: orasPath)
    process.arguments = prepared.arguments
    let processEnvironment = config.orasPath == nil
      ? bundledToolEnvironment()
      : ProcessInfo.processInfo.environment
    process.environment = processEnvironment
      .merging(["TMPDIR": orasTmpDir]) { _, new in new }
    if let workDir = workingDirectory {
      process.currentDirectoryURL = URL(fileURLWithPath: workDir)
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    if prepared.standardInput == nil {
      process.standardInput = FileHandle.nullDevice
    }
    let childLaunchReservation = try childProcessLease?.prepare(process)

    let result: ProcessExecutionResult
    do {
      result = try await AsyncProcessRunner.run(
        process: process,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        options: AsyncProcessRunnerOptions(
          timeout: timeout,
          timeoutDescription: "oras \(prepared.arguments.first ?? "command")",
          maxOutputSize: Self.maxOutputSize
        ),
        standardInput: prepared.standardInput,
        childLaunchReservation: childLaunchReservation,
        onProcessStarted: onProcessStarted
      )
    } catch let error as AsyncProcessRunnerError {
      throw mapProcessRunnerError(error)
    }

    if result.exitCode != 0 {
      let suffix = result.stderrTruncated ? " (output truncated)" : ""
      let stderr = String(decoding: result.stderr, as: UTF8.self) + suffix
      throw OrasError.commandFailed(exitCode: result.exitCode, stderr: stderr)
    }
    guard result.stdoutTruncated == false else {
      throw OrasError.invalidOutput("oras standard output exceeded the 8MB limit")
    }
    guard result.stderrTruncated == false else {
      throw OrasError.invalidOutput("oras standard error exceeded the 8MB limit")
    }

    return result
  }

  private func executeToFile(
    arguments: [String],
    outputPath: String,
    timeout: TimeInterval?,
    registryHost: String
  ) async throws {
    let orasPath = try resolveOrasPath()

    let outputParent = (outputPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: outputParent, withIntermediateDirectories: true)
    let outputHandle = try Self.openOutputFile(atPath: outputPath)
    defer { try? outputHandle.close() }

    let orasTmpDir = temporaryRoot
      .appendingPathComponent("oras-tmp-\(UUID().uuidString)", isDirectory: true)
      .path
    try Self.createPrivateDirectory(atPath: orasTmpDir)
    defer { try? FileManager.default.removeItem(atPath: orasTmpDir) }
    let prepared = try await prepareExecution(
      arguments: arguments,
      registryHost: registryHost,
      registryConfigPath: "\(orasTmpDir)/registry-config.json"
    )
    logDebug("oras \(Self.sanitizedArguments(prepared.arguments))", category: "OrasClient")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: orasPath)
    process.arguments = prepared.arguments
    let processEnvironment = config.orasPath == nil
      ? bundledToolEnvironment()
      : ProcessInfo.processInfo.environment
    process.environment = processEnvironment
      .merging(["TMPDIR": orasTmpDir]) { _, new in new }
    if let standardInput = prepared.standardInput {
      process.standardInput = standardInput.pipe
    } else {
      process.standardInput = FileHandle.nullDevice
    }
    process.standardOutput = outputHandle

    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    let exitObserver = OrasProcessExitObserver()
    let stderrCollector = LimitedPipeOutputCollector(maxOutputSize: Self.maxOutputSize)
    let childLaunchReservation = try childProcessLease?.prepare(process)
    defer { childLaunchReservation?.processDidExit() }

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
      prepared.standardInput?.close()
      throw OrasError.commandFailed(exitCode: -1, stderr: "Failed to launch oras: \(error.localizedDescription)")
    }
    prepared.standardInput?.closeParentReadEnd()
    let inputTask = prepared.standardInput.map { standardInput in
      Task<Void, Error> {
        try await standardInput.write()
      }
    }
    defer {
      inputTask?.cancel()
      prepared.standardInput?.close()
    }
    try? stderrPipe.fileHandleForWriting.close()

    ChildProcessTracker.shared.track(process)
    defer { ChildProcessTracker.shared.untrack(process) }

    let exitCode: Int32
    do {
      exitCode = try await withTaskCancellationHandler {
        try await Self.waitForProcess(
          exitObserver: exitObserver,
          process: process,
          timeout: timeout,
          timeoutDescription: "oras \(prepared.arguments.first ?? "command")"
        )
      } onCancel: {
        ChildProcessTracker.shared.terminateIfRunning(process)
      }
    } catch {
      stderrCollector.stop()
      throw error
    }

    do {
      try await inputTask?.value
    } catch let error as AsyncProcessRunnerError {
      stderrCollector.stop()
      throw mapProcessRunnerError(error)
    }

    let stderr = await stderrCollector.finish()
    guard exitCode == 0 else {
      let suffix = stderr.wasTruncated ? " (output truncated)" : ""
      let stderrText = String(decoding: stderr.data, as: UTF8.self) + suffix
      throw OrasError.commandFailed(exitCode: exitCode, stderr: stderrText)
    }
    guard stderr.wasTruncated == false else {
      throw OrasError.invalidOutput("oras standard error exceeded the 8MB limit or did not close after exit")
    }
  }

  private func prepareExecution(
    arguments: [String],
    registryHost: String?,
    registryConfigPath: String,
    standardInputData: Data? = nil
  ) async throws -> (arguments: [String], standardInput: AsyncProcessStandardInput?) {
    var preparedArguments = arguments
    preparedArguments.append(contentsOf: ["--registry-config", registryConfigPath])

    if let standardInputData {
      return (preparedArguments, AsyncProcessStandardInput(data: standardInputData))
    }
    guard let registryHost,
          let credential = try await credentialStore.credential(for: registryHost) else
    {
      return (preparedArguments, nil)
    }
    preparedArguments.append(contentsOf: ["-u", credential.username, "--password-stdin"])
    return (
      preparedArguments,
      AsyncProcessStandardInput(data: Data((credential.password + "\n").utf8))
    )
  }

  static func sanitizedArguments(_ arguments: [String]) -> String {
    var redactNext = false
    return arguments.map { argument in
      if redactNext {
        redactNext = false
        return "<redacted>"
      }
      if argument == "-u" || argument == "--username" {
        redactNext = true
        return argument
      }
      if argument.hasPrefix("--username=") {
        return "--username=<redacted>"
      }
      return argument
    }.joined(separator: " ")
  }

  private func mapProcessRunnerError(_ error: AsyncProcessRunnerError) -> OrasError {
    switch error {
    case .launchFailed(let message):
      .commandFailed(exitCode: -1, stderr: "Failed to launch oras: \(message)")
    case .inputWriteFailed(let message):
      .commandFailed(exitCode: -1, stderr: "Failed to write oras standard input: \(message)")
    case .timeout(let command):
      .timeout(command)
    }
  }

  private static func openOutputFile(atPath path: String) throws -> FileHandle {
    let descriptor = open(path, O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      let message = String(cString: strerror(errno))
      throw OrasError.invalidOutput("Failed to open output file at \(path): \(message)")
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  private static func createPrivateDirectory(atPath path: String) throws {
    try FileManager.default.createDirectory(
      atPath: path,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
  }

  // MARK: - Output Parsing

  private func parseDescriptorFromJSON(_ output: String) -> OrasDescriptor? {
    guard let data = output.data(using: .utf8), !data.isEmpty else { return nil }
    return try? JSONDecoder().decode(OrasDescriptor.self, from: data)
  }

  private static func validateReturnedDescriptor(
    _ descriptor: OrasDescriptor,
    expectedMediaType: String,
    expectedDigest: String,
    expectedSize: UInt64,
    operation: String
  ) throws {
    guard descriptor.mediaType == expectedMediaType else {
      throw OrasError.invalidOutput(
        "\(operation) returned media type \(descriptor.mediaType), expected \(expectedMediaType)"
      )
    }
    guard descriptor.digest == expectedDigest else {
      throw OrasError.invalidOutput(
        "\(operation) returned digest \(descriptor.digest), expected \(expectedDigest)"
      )
    }
    guard descriptor.size == expectedSize else {
      throw OrasError.invalidOutput(
        "\(operation) returned size \(descriptor.size), expected \(expectedSize)"
      )
    }
  }

  private static func isMissingBlobError(_ error: OrasError) -> Bool {
    guard case .commandFailed(_, let stderr) = error else { return false }
    let normalized = stderr.uppercased()
    return normalized.contains("404")
      || normalized.contains("NOT FOUND")
      || normalized.contains("NOT_FOUND")
      || normalized.contains("BLOB_UNKNOWN")
      || normalized.contains("NAME_UNKNOWN")
      || normalized.contains("MANIFEST_UNKNOWN")
  }

  private func fileSize(atPath path: String) throws -> UInt64 {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    guard let number = attrs[.size] as? NSNumber, number.doubleValue >= 0 else {
      throw OrasError.invalidOutput("Invalid file size metadata for \(path)")
    }
    return number.uint64Value
  }

  private func sha256File(atPath path: String) throws -> String {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      try Task.checkCancellation()
      let data = try readFileChunk(from: handle, upToCount: 4 * 1024 * 1024) ?? Data()
      guard !data.isEmpty else { break }
      hasher.update(data: data)
    }
    return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func waitForProcess(
    exitObserver: OrasProcessExitObserver,
    process: Process,
    timeout: TimeInterval?,
    timeoutDescription: String
  ) async throws -> Int32 {
    try await withThrowingTaskGroup(of: OrasProcessEvent.self) { group in
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
          throw OrasError.timeout(timeoutDescription)
        }
      }

      throw OrasError.commandFailed(exitCode: -1, stderr: "Process ended without status")
    }
  }

  private static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64 {
    guard timeout.isFinite, timeout > 0 else { return 0 }
    let maxSeconds = TimeInterval(UInt64.max / 1_000_000_000)
    return UInt64(min(timeout, maxSeconds) * 1_000_000_000)
  }
}

private enum OrasProcessEvent {
  case exited(Int32)
  case timedOut
}

private final class OrasProcessExitObserver: @unchecked Sendable {
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
