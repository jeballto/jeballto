import CryptoKit
import Darwin
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
struct OrasPullResult: Sendable {
  let digest: String
  let rawOutput: String
}

/// Result of an oras push operation
struct OrasPushResult: Sendable {
  let digest: String
  let rawOutput: String
}

private let ociImageManifestMediaType = "application/vnd.oci.image.manifest.v1+json"

/// Metadata from an OCI manifest
struct OrasDescriptor: Codable, Equatable, Sendable {
  let mediaType: String
  let digest: String
  let size: UInt64
}

struct OrasManifestInfo: Sendable {
  let schemaVersion: Int?
  let mediaType: String?
  let artifactType: String?
  let configMediaType: String?
  let configDescriptor: OrasDescriptor?
  let layers: [OrasDescriptor]
  let rawManifest: String

  var isJeballtoImage: Bool {
    (try? validateJeballtoImage()) != nil
  }

  var formatSummary: String {
    let layerSummary = Dictionary(grouping: layers, by: \.mediaType)
      .map { mediaType, descriptors in "\(mediaType) x\(descriptors.count)" }
      .sorted()
      .joined(separator: ", ")
    return [
      "schemaVersion=\(schemaVersion.map(String.init) ?? "nil")",
      "mediaType=\(mediaType ?? "nil")",
      "artifactType=\(artifactType ?? "nil")",
      "configMediaType=\(configMediaType ?? "nil")",
      "layerMediaTypes=\(layerSummary)",
    ].joined(separator: ", ")
  }

  init(rawManifest: String) throws {
    struct Manifest: Decodable {
      let schemaVersion: Int?
      let mediaType: String?
      let artifactType: String?
      let config: OrasDescriptor?
      let layers: [OrasDescriptor]?
    }

    let data = Data(rawManifest.utf8)
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    schemaVersion = manifest.schemaVersion
    mediaType = manifest.mediaType
    artifactType = manifest.artifactType
    configMediaType = manifest.config?.mediaType
    configDescriptor = manifest.config
    layers = manifest.layers ?? []
    self.rawManifest = rawManifest
  }

  func validateJeballtoImage(reference: String? = nil) throws {
    let subject = reference ?? "image"

    guard schemaVersion == 2 else {
      throw OrasError.invalidOutput("\(subject) manifest must use OCI schemaVersion 2")
    }
    if let mediaType, mediaType != ociImageManifestMediaType {
      throw OrasError.invalidOutput("\(subject) manifest has unsupported media type \(mediaType)")
    }
    guard artifactType == jeballtoImageArtifactType else {
      throw OrasError.invalidOutput("\(subject) manifest has unsupported artifact type \(artifactType ?? "nil")")
    }
    guard let configDescriptor else {
      throw OrasError.invalidOutput("\(subject) manifest is missing a config descriptor")
    }
    guard configDescriptor.mediaType == jeballtoImageConfigMediaType else {
      throw OrasError
        .invalidOutput("\(subject) manifest has unsupported config media type \(configDescriptor.mediaType)")
    }
    try Self.validateDescriptor(configDescriptor, role: "config", subject: subject)
    guard layers.isEmpty == false else {
      throw OrasError.invalidOutput("\(subject) manifest must include at least one layer")
    }
    for layer in layers {
      guard layer.mediaType == jeballtoImageChunkMediaType else {
        throw OrasError.invalidOutput("\(subject) manifest has unsupported layer media type \(layer.mediaType)")
      }
      try Self.validateDescriptor(layer, role: "layer", subject: subject)
    }
  }

  private static func validateDescriptor(_ descriptor: OrasDescriptor, role: String, subject: String) throws {
    guard descriptor.digest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil else {
      throw OrasError.invalidOutput("\(subject) \(role) descriptor has invalid digest \(descriptor.digest)")
    }
    guard descriptor.size > 0 else {
      throw OrasError.invalidOutput("\(subject) \(role) descriptor must have a positive size")
    }
  }
}

enum OrasBlobPresence: Equatable, Sendable {
  case exists
  case missing
}

/// Swift wrapper around the oras CLI binary.
/// Uses Process with array arguments (no shell) to prevent command injection.
struct OrasClient: Sendable {
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
      _ = try await execute(arguments: args, timeout: Self.shortTimeout)
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

    let result = try await execute(arguments: args, timeout: timeout ?? Self.defaultTimeout)
    let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
    return parseDescriptorFromJSON(stdout) ?? OrasDescriptor(mediaType: mediaType, digest: digest, size: expectedSize)
  }

  /// Pushes an OCI image manifest and returns the pushed manifest digest.
  func pushManifest(
    reference: ImageReference,
    manifestPath: String,
    insecure: Bool = false,
    timeout: TimeInterval? = nil
  ) async throws -> OrasPushResult {
    var args = [
      "manifest", "push",
      "--descriptor",
      "--media-type", ociImageManifestMediaType,
      reference.fullReference,
      manifestPath,
    ]
    args.append(contentsOf: Self.transportSecurityArguments(plainHTTP: insecure))

    let result = try await execute(arguments: args, timeout: timeout ?? Self.defaultTimeout)
    let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
    let digest: String = if let descriptorDigest = parseDescriptorFromJSON(stdout)?.digest {
      descriptorDigest
    } else {
      try sha256File(atPath: manifestPath)
    }
    return OrasPushResult(digest: digest, rawOutput: stdout)
  }

  /// Fetches the raw OCI manifest so callers can verify the Jeballto image format.
  func fetchManifest(reference: ImageReference, insecure: Bool = false) async throws -> OrasManifestInfo {
    var args = ["manifest", "fetch", reference.fullReference]
    args.append(contentsOf: Self.transportSecurityArguments(plainHTTP: insecure))

    let result = try await execute(arguments: args, timeout: Self.shortTimeout)
    let stdout = String(data: result.stdout, encoding: .utf8) ?? ""
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
        timeout: timeout ?? Self.defaultTimeout
      )
      if let expectedSize {
        let actualSize = try fileSize(atPath: tempOutputPath)
        guard actualSize == expectedSize else {
          throw OrasError.invalidOutput("Blob \(digest) size mismatch: expected \(expectedSize), got \(actualSize)")
        }
      }
      let actualDigest = try sha256File(atPath: tempOutputPath)
      guard actualDigest == digest else {
        throw OrasError.invalidOutput("Blob \(digest) digest mismatch: got \(actualDigest)")
      }
      if FileManager.default.fileExists(atPath: outputPath) {
        try FileManager.default.removeItem(atPath: outputPath)
      }
      try FileManager.default.moveItem(atPath: tempOutputPath, toPath: outputPath)
    } catch {
      try? FileManager.default.removeItem(atPath: tempOutputPath)
      try? FileManager.default.removeItem(atPath: outputPath)
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

  /// Authenticates to an OCI registry.
  /// Password is passed via stdin to avoid exposure in process listings.
  func login(registry: String, username: String, password: String, insecure: Bool = false) async throws {
    var args = ["login", registry, "-u", username, "--password-stdin"]
    args.append(contentsOf: Self.transportSecurityArguments(plainHTTP: insecure))

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
    args.append(contentsOf: Self.transportSecurityArguments(plainHTTP: insecure))

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
    let orasTmpDir = JeballtoCachePaths.imageWork
      .appendingPathComponent("oras-tmp-\(UUID().uuidString)", isDirectory: true)
      .path
    try FileManager.default.createDirectory(atPath: orasTmpDir, withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: orasPath)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment
      .merging(["TMPDIR": orasTmpDir]) { _, new in new }
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

  private func executeToFile(
    arguments: [String],
    outputPath: String,
    timeout: TimeInterval?
  ) async throws {
    let orasPath = try resolveOrasPath()

    logDebug("oras \(arguments.joined(separator: " "))", category: "OrasClient")

    let outputParent = (outputPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: outputParent, withIntermediateDirectories: true)
    let outputHandle = try Self.openOutputFile(atPath: outputPath)
    defer { try? outputHandle.close() }

    let orasTmpDir = JeballtoCachePaths.imageWork
      .appendingPathComponent("oras-tmp-\(UUID().uuidString)", isDirectory: true)
      .path
    try FileManager.default.createDirectory(atPath: orasTmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: orasTmpDir) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: orasPath)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment
      .merging(["TMPDIR": orasTmpDir]) { _, new in new }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = outputHandle

    let stderrPipe = Pipe()
    process.standardError = stderrPipe

    let exitObserver = OrasProcessExitObserver()
    let stderrCollector = OrasLimitedPipeCollector(maxOutputSize: Self.maxOutputSize)

    process.terminationHandler = { process in
      exitObserver.finish(process.terminationStatus)
    }
    stderrCollector.start(stderrPipe.fileHandleForReading)

    do {
      try process.run()
    } catch {
      stderrCollector.stop()
      throw OrasError.commandFailed(exitCode: -1, stderr: "Failed to launch oras: \(error.localizedDescription)")
    }

    ChildProcessTracker.shared.track(process)
    defer { ChildProcessTracker.shared.untrack(process) }

    let exitCode: Int32
    do {
      exitCode = try await withTaskCancellationHandler {
        try await Self.waitForProcess(
          exitObserver: exitObserver,
          process: process,
          timeout: timeout,
          timeoutDescription: "oras \(arguments.first ?? "command")"
        )
      } onCancel: {
        ChildProcessTracker.shared.terminateIfRunning(process)
      }
    } catch {
      stderrCollector.stop()
      throw error
    }

    let stderr = stderrCollector.stopAndReadRemaining()
    guard exitCode == 0 else {
      let stderrText = String(data: stderr, encoding: .utf8) ?? ""
      throw OrasError.commandFailed(exitCode: exitCode, stderr: stderrText)
    }
  }

  private func mapProcessRunnerError(_ error: AsyncProcessRunnerError) -> OrasError {
    switch error {
    case .launchFailed(let message):
      .commandFailed(exitCode: -1, stderr: "Failed to launch oras: \(message)")
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

  private func parseDescriptorFromJSON(_ output: String) -> OrasDescriptor? {
    guard let data = output.data(using: .utf8), !data.isEmpty else { return nil }
    return try? JSONDecoder().decode(OrasDescriptor.self, from: data)
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
    return attrs[.size] as? UInt64 ?? UInt64(attrs[.size] as? Int64 ?? 0)
  }

  private func sha256File(atPath path: String) throws -> String {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
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
          try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
          return .timedOut
        }
      }

      while let event = try await group.next() {
        switch event {
        case .exited(let status):
          group.cancelAll()
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

private final class OrasLimitedPipeCollector: @unchecked Sendable {
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
