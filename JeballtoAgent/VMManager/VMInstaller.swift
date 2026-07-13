// swiftlint:disable file_length

import CryptoKit
import Darwin
import Foundation
@preconcurrency import Virtualization

/// Explicit ownership boundary for immutable Virtualization objects passed between callback,
/// worker, and MainActor contexts. Values are consumed sequentially by the installer workflow.
private final class AVFTransfer<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}

enum IPSWSourceValidationError: Error, LocalizedError {
  case invalid(String)

  var errorDescription: String? {
    switch self {
    case .invalid(let message): "Invalid IPSW source: \(message)"
    }
  }
}

enum IPSWSourceValidator {
  static let maximumSourceLength = 8192
  static let maximumLocalPathLength = 4096

  static func normalized(_ source: String?) throws -> String? {
    guard let source else { return nil }
    guard source.isEmpty == false else {
      throw IPSWSourceValidationError.invalid("source must not be empty; omit it to download the latest macOS")
    }
    guard source.utf8.count <= maximumSourceLength else {
      throw IPSWSourceValidationError.invalid("source exceeds \(maximumSourceLength) UTF-8 bytes")
    }
    guard containsControlCharacters(source) == false else {
      throw IPSWSourceValidationError.invalid("source must not contain control characters")
    }

    let lowered = source.lowercased()
    if lowered.hasPrefix("http://") {
      throw IPSWSourceValidationError.invalid("HTTP is not supported; use HTTPS or a local file path")
    }

    if let components = URLComponents(string: source), let scheme = components.scheme?.lowercased() {
      switch scheme {
      case "https":
        guard let host = components.host, host.isEmpty == false else {
          throw IPSWSourceValidationError.invalid("HTTPS URL must include a host")
        }
        guard components.user == nil, components.password == nil else {
          throw IPSWSourceValidationError.invalid("HTTPS URL must not contain embedded credentials")
        }
        guard components.fragment == nil else {
          throw IPSWSourceValidationError.invalid("HTTPS URL must not contain a fragment")
        }
        if let port = components.port, (1 ... 65535).contains(port) == false {
          throw IPSWSourceValidationError.invalid("HTTPS URL contains an invalid port")
        }
        guard URL(string: source) != nil else {
          throw IPSWSourceValidationError.invalid("HTTPS URL is malformed")
        }
        return source

      case "file":
        guard lowered.hasPrefix("file://") else {
          throw IPSWSourceValidationError.invalid("file URL must use the file:// form")
        }
        guard components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil else
        {
          throw IPSWSourceValidationError.invalid("file URL must not contain credentials, a port, query, or fragment")
        }
        if let host = components.host, host.isEmpty == false, host.lowercased() != "localhost" {
          throw IPSWSourceValidationError.invalid("file URL host must be empty or localhost")
        }
        guard let url = URL(string: source), url.isFileURL else {
          throw IPSWSourceValidationError.invalid("file URL is malformed")
        }
        return try validateLocalPath(url.path)

      case "http":
        throw IPSWSourceValidationError.invalid("HTTP is not supported; use HTTPS or a local file path")

      default:
        throw IPSWSourceValidationError.invalid("unsupported URL scheme '\(scheme)'")
      }
    }

    return try validateLocalPath(source)
  }

  static func logDescription(_ source: String) -> String {
    guard var components = URLComponents(string: source), components.scheme?.lowercased() == "https" else {
      return source
    }
    let hadQuery = components.query != nil
    components.query = nil
    let sanitized = components.string ?? source
    return hadQuery ? "\(sanitized) [query omitted]" : sanitized
  }

  private static func validateLocalPath(_ path: String) throws -> String {
    guard path.hasPrefix("/") else {
      throw IPSWSourceValidationError.invalid("local path must be absolute")
    }
    guard path.utf8.count <= maximumLocalPathLength else {
      throw IPSWSourceValidationError.invalid("local path exceeds \(maximumLocalPathLength) UTF-8 bytes")
    }
    guard containsControlCharacters(path) == false else {
      throw IPSWSourceValidationError.invalid("local path must not contain control characters")
    }
    return path
  }

  private static func containsControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}

struct VMInstallationSuccessMarker: Codable, Equatable, Sendable {
  let formatVersion: Int
  let vmId: UUID
  let completedAt: Date
}

enum VMInstallationSuccessMarkerError: Error, LocalizedError {
  case unsupportedVersion(found: Int, expected: Int)
  case mismatchedVM(found: UUID, expected: UUID)

  var errorDescription: String? {
    switch self {
    case .unsupportedVersion(let found, let expected):
      "Unsupported installation success marker version \(found), expected \(expected)"
    case .mismatchedVM(let found, let expected):
      "Installation success marker belongs to VM \(found), expected \(expected)"
    }
  }
}

enum VMInstallationSuccessMarkerStore {
  static let currentFormatVersion = 1
  static let maximumSize = 4 * 1024
  private static let suffix = ".installation-succeeded"

  static func markerPath(for definition: VMDefinition) -> String {
    let storagePath = URL(fileURLWithPath: definition.paths.bundlePath).deletingLastPathComponent().path
    return (storagePath as NSString).appendingPathComponent(
      ".\(definition.id.uuidString)\(suffix)"
    )
  }

  static func recordSuccess(for definition: VMDefinition, at completedAt: Date = Date()) throws {
    let marker = VMInstallationSuccessMarker(
      formatVersion: currentFormatVersion,
      vmId: definition.id,
      completedAt: completedAt
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(marker)
    try DurableMarkerStore.writeDataAtomically(
      data,
      to: markerPath(for: definition),
      maximumSize: maximumSize
    )
  }

  static func readIfPresent(for definition: VMDefinition) throws -> VMInstallationSuccessMarker? {
    guard let data = try DurableMarkerStore.readDataIfPresent(
      from: markerPath(for: definition),
      maximumSize: maximumSize
    ) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let marker = try decoder.decode(VMInstallationSuccessMarker.self, from: data)
    guard marker.formatVersion == currentFormatVersion else {
      throw VMInstallationSuccessMarkerError.unsupportedVersion(
        found: marker.formatVersion,
        expected: currentFormatVersion
      )
    }
    guard marker.vmId == definition.id else {
      throw VMInstallationSuccessMarkerError.mismatchedVM(found: marker.vmId, expected: definition.id)
    }
    return marker
  }

  static func removeIfPresent(for definition: VMDefinition) throws {
    try DurableMarkerStore.removeIfPresent(at: markerPath(for: definition))
  }
}

/// Handles macOS installation into VMs
final class VMInstaller: NSObject, @unchecked Sendable { // swiftlint:disable:this type_body_length
  typealias InstallationSuccessRecorder = @Sendable () throws -> Void
  typealias VirtualMachineStateProvider = @Sendable () -> VZVirtualMachine.State?

  private static let downloadGate = KeyedOperationGate()
  private let stateLock = NSLock()

  /// The VM definition containing paths and configuration
  private let vmDefinition: VMDefinition

  /// Event bus for publishing installation progress
  private let eventBus: EventBus

  /// The virtual machine used for installation
  @MainActor private(set) var virtualMachine: VZVirtualMachine?

  /// Installation observer for progress tracking
  private var installationObserver: NSKeyValueObservation?

  /// Delegate for VM events during installation
  @MainActor private(set) var delegate: AVFDelegate?

  /// Current installation progress (0.0 to 1.0)
  private var _progress: Double = 0.0

  var progress: Double {
    get {
      stateLock.lock()
      defer { stateLock.unlock() }
      return _progress
    }
    set {
      stateLock.lock()
      defer { stateLock.unlock() }
      _progress = newValue
    }
  }

  /// Current installation status message
  private var _statusMessage: String = ""

  var statusMessage: String {
    get {
      stateLock.lock()
      defer { stateLock.unlock() }
      return _statusMessage
    }
    set {
      stateLock.lock()
      defer { stateLock.unlock() }
      _statusMessage = newValue
    }
  }

  /// Last logged integer percentage (to avoid duplicate log entries)
  private var lastLoggedPercent: Int = -1
  private let installationSuccessRecorder: InstallationSuccessRecorder
  private let virtualMachineStateProvider: VirtualMachineStateProvider?

  // Progress: first half (0%→50%) is setup/download, second half (50%→100%) is macOS installation
  fileprivate static let installStart: Double = 0.50

  init(
    vmDefinition: VMDefinition,
    eventBus: EventBus,
    installationSuccessRecorder: InstallationSuccessRecorder? = nil,
    virtualMachineStateProvider: VirtualMachineStateProvider? = nil
  ) {
    self.vmDefinition = vmDefinition
    self.eventBus = eventBus
    self.installationSuccessRecorder = installationSuccessRecorder ?? {
      try VMInstallationSuccessMarkerStore.recordSuccess(for: vmDefinition)
    }
    self.virtualMachineStateProvider = virtualMachineStateProvider
    super.init()
  }

  private func shouldLogInstallProgress(percent: Int) -> Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    guard percent != lastLoggedPercent else { return false }
    lastLoggedPercent = percent
    return true
  }

  private func setInstallationObserver(_ observer: NSKeyValueObservation?) {
    stateLock.lock()
    defer { stateLock.unlock() }
    installationObserver = observer
  }

  private func clearInstallationObserver() {
    stateLock.lock()
    let observer = installationObserver
    installationObserver = nil
    stateLock.unlock()
    observer?.invalidate()
  }

  @MainActor
  func virtualMachineState(detachDelegate: Bool = false) -> VZVirtualMachine.State? {
    if let virtualMachineStateProvider {
      return virtualMachineStateProvider()
    }
    if detachDelegate {
      delegate?.onStop = nil
      delegate?.onError = nil
      virtualMachine?.delegate = nil
    }
    return virtualMachine?.state
  }

  // MARK: - Public Installation Methods

  /// Downloads latest macOS restore image and installs it
  func downloadAndInstall() async throws {
    logInfo("Starting auto-download and installation for VM \(vmDefinition.id)", category: "VMInstaller")

    // Publish installation started event
    eventBus.publish(.installStarted(vmId: vmDefinition.id))
    statusMessage = "Fetching restore image info..."
    publishProgress(0.0)

    // Fetch latest restore image. Installation errors below must retain their own type and context.
    let restoreImage: AVFTransfer<VZMacOSRestoreImage>
    do {
      restoreImage = try await fetchLatestRestoreImage()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      let errorMsg = """
      Failed to fetch macOS restore image from Apple's servers.

      Error: \(error.localizedDescription)

      This can happen due to:
      1. Network connectivity issues
      2. Apple's restore image service being temporarily unavailable
      3. Firewall or proxy blocking the connection

      Please either:
      - Try again later
      - Check your network connection
      - Use a local IPSW file instead: POST /v1/vms/{id}/install with {"source": "/path/to/file.ipsw"}
      """

      logError(errorMsg, category: "VMInstaller")
      throw VMInstallerError.restoreImageFetchFailed(errorMsg)
    }

    statusMessage = "Preparing installation..."
    try await installMacOS(restoreImage: restoreImage)
  }

  /// Installs macOS from a local IPSW file
  func installFromIPSW(ipswPath: String) async throws {
    let normalizedPath: String
    do {
      guard let source = try IPSWSourceValidator.normalized(ipswPath), source.hasPrefix("/") else {
        throw IPSWSourceValidationError.invalid("local IPSW path must be absolute")
      }
      normalizedPath = source
    } catch {
      throw VMInstallerError.invalidIPSWPath(error.localizedDescription)
    }
    logInfo("Starting installation from IPSW for VM \(vmDefinition.id): \(normalizedPath)", category: "VMInstaller")

    let ipswURL = URL(fileURLWithPath: normalizedPath)
    guard Self.cachedIPSWIsUsable(at: ipswURL) else {
      throw VMInstallerError.invalidIPSWPath("IPSW path must reference a non-empty regular file")
    }

    // Publish installation started event
    eventBus.publish(.installStarted(vmId: vmDefinition.id))
    statusMessage = "Loading IPSW file..."
    publishProgress(0.0)

    // Load restore image from IPSW
    let restoreImage = try await loadRestoreImage(from: ipswURL)

    statusMessage = "Configuring VM for installation..."
    publishProgress(Self.installStart)

    // Install from the restore image
    try await installMacOS(restoreImage: restoreImage)
  }

  /// Downloads IPSW from a remote URL and installs it
  func downloadAndInstallFromURL(_ urlString: String) async throws {
    let normalizedSource: String
    do {
      guard let source = try IPSWSourceValidator.normalized(urlString) else {
        throw IPSWSourceValidationError.invalid("remote URL is missing")
      }
      normalizedSource = source
    } catch {
      throw VMInstallerError.invalidIPSWPath(error.localizedDescription)
    }
    logInfo(
      "Starting installation from remote URL for VM \(vmDefinition.id): "
        + IPSWSourceValidator.logDescription(normalizedSource),
      category: "VMInstaller"
    )

    guard let remoteURL = URL(string: normalizedSource), remoteURL.scheme?.lowercased() == "https" else {
      throw VMInstallerError.invalidIPSWPath("Remote IPSW source must be an HTTPS URL")
    }

    eventBus.publish(.installStarted(vmId: vmDefinition.id))
    statusMessage = "Downloading IPSW..."
    publishProgress(0.0)

    let (_, restoreImage) = try await downloadAndLoadIPSW(from: remoteURL)

    statusMessage = "Download complete, configuring VM for installation..."
    publishProgress(Self.installStart)

    try await installMacOS(restoreImage: restoreImage)
  }

  // MARK: - Internal Installation Steps

  /// Fetches the latest macOS restore image with retry logic
  private func fetchLatestRestoreImage() async throws -> AVFTransfer<VZMacOSRestoreImage> {
    logInfo("Fetching latest macOS restore image from Apple...", category: "VMInstaller")

    // Retry up to 3 times with exponential backoff
    var lastError: Error?
    for attempt in 1 ... 3 {
      do {
        let image = try await fetchRestoreImageAttempt()
        logInfo("Successfully fetched restore image on attempt \(attempt)", category: "VMInstaller")
        return image
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        lastError = error
        logWarning("Fetch attempt \(attempt) failed: \(error.localizedDescription)", category: "VMInstaller")

        if attempt < 3 {
          let delay = UInt64(pow(2.0, Double(attempt))) // 2, 4 seconds
          logInfo("Retrying in \(delay) seconds...", category: "VMInstaller")
          try await Task.sleep(nanoseconds: delay * 1_000_000_000)
        }
      }
    }

    throw VMInstallerError.restoreImageFetchFailed(lastError?.localizedDescription ?? "Unknown error after 3 attempts")
  }

  /// Single attempt to fetch restore image
  private func fetchRestoreImageAttempt() async throws -> AVFTransfer<VZMacOSRestoreImage> {
    try Task.checkCancellation()
    let bridge = CancellableCallbackBridge<AVFTransfer<VZMacOSRestoreImage>>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard bridge.register(continuation) else { return }
        VZMacOSRestoreImage.fetchLatestSupported { result in
          switch result {
          case .success(let restoreImage):
            logInfo("Restore image fetched: \(restoreImage.url.lastPathComponent)", category: "VMInstaller")
            bridge.resolve(.success(AVFTransfer(restoreImage)))
          case .failure(let error):
            logError("Restore image fetch failed: \(error.localizedDescription)", category: "VMInstaller")
            bridge.resolve(.failure(error))
          }
        }
      }
    } onCancel: {
      bridge.cancel()
    }
  }

  /// Loads a restore image from an IPSW file
  private func loadRestoreImage(from url: URL) async throws -> AVFTransfer<VZMacOSRestoreImage> {
    try Task.checkCancellation()
    let bridge = CancellableCallbackBridge<AVFTransfer<VZMacOSRestoreImage>>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard bridge.register(continuation) else { return }
        VZMacOSRestoreImage.load(from: url) { result in
          switch result {
          case .success(let restoreImage): bridge.resolve(.success(AVFTransfer(restoreImage)))
          case .failure(let error):
            bridge.resolve(.failure(VMInstallerError.invalidIPSW(error.localizedDescription)))
          }
        }
      }
    } onCancel: {
      bridge.cancel()
    }
  }

  /// Downloads IPSW file from remote URL to local cache.
  private func downloadIPSWWithoutCoordination(from remoteURL: URL) async throws -> URL {
    // Create cache directory
    let cacheDir = JeballtoCachePaths.ipswCache

    try FileManager.default.createDirectory(
      at: cacheDir,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDir.path)

    let filename = Self.cacheFilename(for: remoteURL)
    let localURL = cacheDir.appendingPathComponent(filename)
    let partialURL = cacheDir.appendingPathComponent("\(filename).partial")

    if FileManager.default.fileExists(atPath: localURL.path) {
      if Self.cachedIPSWIsUsable(at: localURL) {
        logInfo("IPSW already cached at \(localURL.path)", category: "VMInstaller")
        return localURL
      }
      logWarning("Removing invalid cached IPSW at \(localURL.path)", category: "VMInstaller")
      do {
        try FileManager.default.removeItem(at: localURL)
      } catch {
        throw VMInstallerError.restoreImageFetchFailed(
          "Failed to remove invalid cached IPSW at \(localURL.path): \(error.localizedDescription)"
        )
      }
    }

    // Clean up any stale partial file from a previous interrupted run
    if FileManager.default.fileExists(atPath: partialURL.path) {
      logWarning("Removing stale partial IPSW at \(partialURL.path)", category: "VMInstaller")
      do {
        try FileManager.default.removeItem(at: partialURL)
      } catch {
        throw VMInstallerError.restoreImageFetchFailed(
          "Failed to remove stale partial IPSW at \(partialURL.path): \(error.localizedDescription)"
        )
      }
    }

    logInfo(
      "Downloading IPSW from \(IPSWSourceValidator.logDescription(remoteURL.absoluteString)) to \(localURL.path)",
      category: "VMInstaller"
    )

    // Publish initial download state with 0 bytes so fields appear in API response
    updateDownloadProgress(
      0.0, phaseProgress: 0.0, message: "Downloading macOS restore image...",
      bytesDownloaded: 0, bytesTotal: 0, downloadSpeed: 0
    )

    // Create session with delegate for progress tracking and completion
    // IMPORTANT: Must use downloadTask WITHOUT completion handler  - using a completion
    // handler bypasses delegate methods (didWriteData) so progress would never update.
    let delegate = DownloadDelegate(installer: self, destinationURL: partialURL)
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.urlCache = nil
    sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    let downloadedURL: URL = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        delegate.startDownload(from: remoteURL, session: session, continuation: continuation)
      }
    } onCancel: {
      delegate.cancel()
    }
    try Task.checkCancellation()

    // Promote partial to final with an atomic rename; on failure, leave partial for cleanup next run.
    do {
      try FileManager.default.moveItem(at: downloadedURL, to: localURL)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: localURL.path)
    } catch {
      throw VMInstallerError.restoreImageFetchFailed(
        "Failed to promote downloaded IPSW: \(error.localizedDescription)"
      )
    }

    logInfo("IPSW downloaded successfully to \(localURL.path)", category: "VMInstaller")
    return localURL
  }

  static func cacheFilename(for remoteURL: URL) -> String {
    let urlData = Data(remoteURL.absoluteString.utf8)
    let digest = SHA256.hash(data: urlData)
      .prefix(12)
      .map { String(format: "%02x", $0) }
      .joined()

    return "restore-\(digest).ipsw"
  }

  static func cachedIPSWIsUsable(at url: URL) -> Bool {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
    return info.st_size > 0
  }

  private func downloadAndLoadIPSW(
    from remoteURL: URL
  ) async throws -> (url: URL, restoreImage: AVFTransfer<VZMacOSRestoreImage>) {
    try await Self.downloadGate.withExclusiveAccess(for: remoteURL.absoluteString) {
      try await self.downloadAndLoadIPSWWithoutCoordination(from: remoteURL)
    }
  }

  private func downloadAndLoadIPSWWithoutCoordination(
    from remoteURL: URL
  ) async throws -> (url: URL, restoreImage: AVFTransfer<VZMacOSRestoreImage>) {
    for attempt in 1 ... 2 {
      let localURL = try await downloadIPSWWithoutCoordination(from: remoteURL)
      do {
        return try await (localURL, loadRestoreImage(from: localURL))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        guard attempt == 1 else { throw error }
        logWarning(
          "Cached IPSW validation failed, downloading a fresh copy: \(error.localizedDescription)",
          category: "VMInstaller"
        )
        do {
          try FileManager.default.removeItem(at: localURL)
        } catch {
          throw VMInstallerError.restoreImageFetchFailed(
            "Failed to remove invalid IPSW at \(localURL.path): \(error.localizedDescription)"
          )
        }
      }
    }
    throw VMInstallerError.restoreImageFetchFailed("IPSW validation ended without a result")
  }

  /// Installs macOS from a restore image
  private func installMacOS(restoreImage: AVFTransfer<VZMacOSRestoreImage>) async throws {
    try Task.checkCancellation()
    let restoreImage = restoreImage.value
    guard let macOSConfiguration = restoreImage.mostFeaturefulSupportedConfiguration else {
      throw VMInstallerError.noSupportedConfiguration
    }

    guard macOSConfiguration.hardwareModel.isSupported else {
      throw VMInstallerError.unsupportedHardware("Hardware model not supported on this host")
    }

    // Create VM bundle and required files
    statusMessage = "Creating VM bundle..."
    try createVMBundle()

    statusMessage = "Configuring VM hardware..."
    let installSpec = MacVMConfigurationBuilder().makeInstallationSpec(for: vmDefinition)
    let assembler = AVFConfigurationAssembler()
    try assembler.validateResources(
      in: installSpec,
      installationRequirements: macOSConfiguration
    )
    try Task.checkCancellation()
    try await createDiskImage()
    let vmConfig = try assembler.createConfiguration(
      from: installSpec,
      installationRequirements: macOSConfiguration
    )

    // Create virtual machine on main queue (required by Virtualization framework)
    statusMessage = "Creating virtual machine..."
    logInfo("Creating VZVirtualMachine for installation on main queue", category: "VMInstaller")
    let vm = await createAndStoreInstallationRuntime(configuration: AVFTransfer(vmConfig))
    logInfo("VZVirtualMachine created successfully on main queue", category: "VMInstaller")
    try Task.checkCancellation()

    statusMessage = "Preparing IPSW..."
    publishProgress(0.0)

    // Run installation
    logInfo("Starting macOS installation from restore image: \(restoreImage.url)", category: "VMInstaller")
    try await runInstallation(vm: vm, restoreImageURL: restoreImage.url)

    statusMessage = "Installation completed"
    publishProgress(1.0)

    logInfo("Installation completed for VM \(vmDefinition.id)", category: "VMInstaller")
  }

  @MainActor
  private func createAndStoreInstallationRuntime(
    configuration: AVFTransfer<VZVirtualMachineConfiguration>
  ) -> AVFTransfer<VZVirtualMachine> {
    let runtime = VirtualizationRuntimeFactory().makeRuntime(
      configuration: configuration.value,
      vmId: vmDefinition.id,
      eventBus: eventBus
    )
    virtualMachine = runtime.virtualMachine
    delegate = runtime.delegate
    return AVFTransfer(runtime.virtualMachine)
  }

  /// Creates the VM bundle directory structure
  private func createVMBundle() throws {
    let bundlePath = vmDefinition.paths.bundlePath

    try FileManager.default.createDirectory(
      atPath: bundlePath,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundlePath)

    logInfo("Created VM bundle at \(bundlePath)", category: "VMInstaller")
  }

  /// Creates the disk image for the VM
  private func createDiskImage() async throws {
    let diskImageURL = URL(fileURLWithPath: vmDefinition.paths.diskImagePath)
    let diskSize = vmDefinition.resources.diskSize

    try await createASIFDiskImage(at: diskImageURL, size: diskSize)

    logInfo(
      "Created disk image: \(diskSize / (1024 * 1024 * 1024)) GB at \(diskImageURL.path)",
      category: "VMInstaller"
    )
  }

  /// Creates ASIF disk image
  private func createASIFDiskImage(at url: URL, size: UInt64) async throws {
    logInfo("Creating ASIF disk image", category: "VMInstaller")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = Self.diskImageCreationArguments(url: url, size: size)
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = FileHandle.nullDevice

    do {
      let result = try await AsyncProcessRunner.run(
        process: process,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe,
        options: AsyncProcessRunnerOptions(
          timeout: 600,
          timeoutDescription: "diskutil image create for \(url.lastPathComponent)",
          maxOutputSize: 64 * 1024
        )
      )
      guard result.exitCode == 0 else {
        let stderr = String(decoding: result.stderr, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = result.stderrTruncated ? " (output truncated)" : ""
        let detail = stderr.isEmpty ? suffix : ": \(stderr)\(suffix)"
        throw VMInstallerError.diskCreationFailed("diskutil exited with status \(result.exitCode)\(detail)")
      }
    } catch let error as VMInstallerError {
      throw error
    } catch {
      throw VMInstallerError.diskCreationFailed(error.localizedDescription)
    }
  }

  static func diskImageCreationArguments(url: URL, size: UInt64) -> [String] {
    ["image", "create", "blank", "--fs", "none", "--format", "ASIF", "--size", "\(size)B", url.path]
  }

  /// Runs the installation process
  private func runInstallation(vm: AVFTransfer<VZVirtualMachine>, restoreImageURL: URL) async throws {
    // swiftlint:disable:previous function_body_length
    // Download IPSW if it's a remote URL
    let localIPSWURL: URL
    if restoreImageURL.scheme?.lowercased() == "https" {
      logInfo("Restore image is remote URL, downloading to local cache...", category: "VMInstaller")
      statusMessage = "Downloading macOS restore image..."
      publishProgress(0.0)

      let validatedDownload = try await downloadAndLoadIPSW(from: restoreImageURL)
      localIPSWURL = validatedDownload.url

      statusMessage = "Download complete"
      publishProgress(Self.installStart)
    } else if restoreImageURL.scheme?.lowercased() == "http" {
      throw VMInstallerError.restoreImageFetchFailed("Refusing to download a restore image over HTTP")
    } else {
      localIPSWURL = restoreImageURL
    }

    // Virtualization framework requires running on main thread
    logInfo("Switching to main thread for VZMacOSInstaller operations", category: "VMInstaller")

    try await installOnMainActor(vm: vm, localIPSWURL: localIPSWURL)
  }

  @MainActor
  private func installOnMainActor(vm: AVFTransfer<VZVirtualMachine>, localIPSWURL: URL) async throws {
    let cancellationController = InstallationProgressCancellationController()
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        logInfo("Creating VZMacOSInstaller with local IPSW URL: \(localIPSWURL)", category: "VMInstaller")
        let installer = VZMacOSInstaller(virtualMachine: vm.value, restoringFromImageAt: localIPSWURL)
        cancellationController.register(installer.progress)

        logInfo("Setting up installation progress observer", category: "VMInstaller")
        let installStart = Self.installStart
        let installRange = 1.0 - installStart
        let observer = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) {
          [weak self] _, change in // swiftlint:disable:this closure_parameter_position
          guard let self, let newProgress = change.newValue else { return }
          guard newProgress.isFinite else {
            logWarning("Ignoring non-finite macOS installation progress", category: "VMInstaller")
            return
          }
          let boundedProgress = min(1.0, max(0.0, newProgress))

          if boundedProgress == 0.0 {
            publishIndeterminateProgress("Preparing macOS installation...")
            return
          }

          let scaledProgress = installStart + (boundedProgress * installRange)
          progress = scaledProgress

          statusMessage = "Installing macOS: \(Int(boundedProgress * 100))%"
          publishProgress(scaledProgress)

          let percent = Int(boundedProgress * 100)
          if shouldLogInstallProgress(percent: percent) {
            logInfo("Installation progress: \(percent)%", category: "VMInstaller")
          }
        }
        setInstallationObserver(observer)

        logInfo("Calling installer.install()", category: "VMInstaller")
        let successRecorder = installationSuccessRecorder
        installer.install { [weak self] result in
          self?.clearInstallationObserver()

          let completion = Self.resolveInstallationCompletion(
            result,
            cancellationRequested: cancellationController.isCancellationRequested,
            recordSuccess: successRecorder
          )
          switch completion {
          case .success:
            logInfo("Installation completed successfully", category: "VMInstaller")
          case .failure(let error):
            logError("Installation failed: \(error.localizedDescription)", category: "VMInstaller")
          }
          continuation.resume(with: completion)
        }
      }
    } onCancel: {
      cancellationController.cancel()
    }
  }

  static func resolveInstallationCompletion(
    _ result: Result<Void, Error>,
    cancellationRequested: Bool,
    recordSuccess: () throws -> Void
  ) -> Result<Void, Error> {
    switch result {
    case .success:
      do {
        try recordSuccess()
        return .success(())
      } catch {
        return .failure(VMInstallerError.installationSuccessMarkerFailed(error.localizedDescription))
      }
    case .failure(let error):
      if cancellationRequested {
        return .failure(CancellationError())
      }
      return .failure(VMInstallerError.installationFailed(error.localizedDescription))
    }
  }

  /// Publishes installation progress event with phase detection
  private func publishProgress(_ progress: Double) {
    let rounded = (progress * 100).rounded() / 100
    self.progress = rounded

    let phase: String
    let phaseProgress: Double
    if rounded >= Self.installStart {
      phase = "installing"
      phaseProgress = ((rounded - Self.installStart) / (1.0 - Self.installStart) * 100).rounded() / 100
    } else {
      phase = "setup"
      phaseProgress = (rounded / Self.installStart * 100).rounded() / 100
    }

    eventBus.publish(.installProgress(
      vmId: vmDefinition.id, progress: rounded, phaseProgress: phaseProgress,
      message: statusMessage, phase: phase,
      bytesDownloaded: nil, bytesTotal: nil, downloadSpeed: nil
    ))
  }

  /// Publishes indeterminate progress (no percentage, just a status message)
  /// Uses -1.0 as sentinel value  - VMManager translates this to nil in the API response
  private func publishIndeterminateProgress(_ message: String) {
    statusMessage = message
    eventBus.publish(.installProgress(
      vmId: vmDefinition.id, progress: -1.0, phaseProgress: -1.0,
      message: message, phase: "setup",
      bytesDownloaded: nil, bytesTotal: nil, downloadSpeed: nil
    ))
  }

  /// Updates progress and status message (called from download delegate)
  fileprivate func updateDownloadProgress(
    _ progress: Double, phaseProgress: Double, message: String,
    bytesDownloaded: UInt64? = nil, bytesTotal: UInt64? = nil, downloadSpeed: UInt64? = nil
  ) {
    self.progress = progress
    statusMessage = message
    eventBus.publish(.installProgress(
      vmId: vmDefinition.id, progress: progress, phaseProgress: phaseProgress,
      message: message, phase: "downloading",
      bytesDownloaded: bytesDownloaded, bytesTotal: bytesTotal, downloadSpeed: downloadSpeed
    ))
  }
}

final class InstallationProgressCancellationController: @unchecked Sendable {
  private let lock = NSLock()
  private var progress: Progress?
  private var cancellationRequested = false

  var isCancellationRequested: Bool {
    lock.withLock { cancellationRequested }
  }

  func register(_ progress: Progress) {
    let shouldCancel = lock.withLock { () -> Bool in
      self.progress = progress
      return cancellationRequested
    }
    if shouldCancel { progress.cancel() }
  }

  func cancel() {
    let progress = lock.withLock { () -> Progress? in
      cancellationRequested = true
      return self.progress
    }
    progress?.cancel()
  }
}

final class CancellableCallbackBridge<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var result: Result<Value, Error>?

  func register(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
    let existingResult = lock.withLock { () -> Result<Value, Error>? in
      if let result { return result }
      self.continuation = continuation
      return nil
    }
    if let existingResult {
      continuation.resume(with: existingResult)
      return false
    }
    return true
  }

  func resolve(_ result: Result<Value, Error>) {
    let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
      guard self.result == nil else { return nil }
      self.result = result
      let continuation = self.continuation
      self.continuation = nil
      return continuation
    }
    continuation?.resume(with: result)
  }

  func cancel() {
    resolve(.failure(CancellationError()))
  }
}

// MARK: - Download Delegate

/// URLSession invokes delegate callbacks on its serial delegate queue. Cross-thread cancellation
/// and continuation ownership are protected by `lock`.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  weak var installer: VMInstaller?
  private let lock = NSLock()
  private var continuation: CheckedContinuation<URL, Error>?
  private var downloadTask: URLSessionDownloadTask?
  private var isCancelled = false
  private let destinationURL: URL
  private var lastLoggedPercent: Int = -1
  private var lastProgressUpdateUptime: TimeInterval?
  private var lastSpeedCheckBytes: Int64 = 0
  private var lastCalculatedSpeed: UInt64 = 0

  init(installer: VMInstaller, destinationURL: URL) {
    self.installer = installer
    self.destinationURL = destinationURL
  }

  func startDownload(
    from url: URL,
    session: URLSession,
    continuation: CheckedContinuation<URL, Error>
  ) {
    lock.lock()
    guard !isCancelled else {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    let task = session.downloadTask(with: url)
    self.continuation = continuation
    downloadTask = task
    lock.unlock()
    task.resume()
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let task = downloadTask
    let continuation = continuation
    downloadTask = nil
    self.continuation = nil
    lock.unlock()
    task?.cancel()
    continuation?.resume(throwing: CancellationError())
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    do {
      try Self.validateHTTPResponse(downloadTask.response)
    } catch {
      takeContinuation()?.resume(throwing: error)
      clearTask()
      return
    }

    // Move downloaded file to cache before temp is cleaned up
    do {
      try FileManager.default.moveItem(at: location, to: destinationURL)
      takeContinuation()?.resume(returning: destinationURL)
    } catch {
      takeContinuation()?.resume(throwing: VMInstallerError.restoreImageFetchFailed(
        "Failed to move downloaded file: \(error.localizedDescription)"
      ))
    }
    clearTask()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    // Called on transport errors. HTTP status failures are handled before moving the downloaded file.
    guard let error else { return } // success is handled in didFinishDownloadingTo
    if isCancellation(error) {
      takeContinuation()?.resume(throwing: CancellationError())
    } else {
      takeContinuation()?.resume(throwing: VMInstallerError.restoreImageFetchFailed(
        "Failed to download IPSW: \(error.localizedDescription)"
      ))
    }
    clearTask()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    do {
      try Self.validateRedirectTarget(request)
      completionHandler(request)
    } catch {
      takeContinuation()?.resume(throwing: error)
      clearTask()
      task.cancel()
      completionHandler(nil)
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard let installer else { return }

    // Throttle progress updates to every 0.5s to avoid flooding the event bus
    let now = ProcessInfo.processInfo.systemUptime
    let progressState = lock.withLock { () -> (speed: UInt64, shouldPublish: Bool) in
      let timeDelta = lastProgressUpdateUptime.map { now - $0 } ?? .infinity
      guard timeDelta >= 0.5 else { return (lastCalculatedSpeed, false) }

      let bytesDelta = totalBytesWritten - lastSpeedCheckBytes
      if bytesDelta > 0 {
        lastCalculatedSpeed = Self.safeBytesPerSecond(bytesDelta: bytesDelta, timeDelta: timeDelta)
      }
      lastProgressUpdateUptime = now
      lastSpeedCheckBytes = totalBytesWritten
      return (lastCalculatedSpeed, true)
    }
    guard progressState.shouldPublish else { return }

    let progressUpdate = Self.makeProgressUpdate(
      totalBytesWritten: totalBytesWritten,
      totalBytesExpectedToWrite: totalBytesExpectedToWrite,
      speedBytesPerSecond: progressState.speed
    )
    installer.updateDownloadProgress(
      progressUpdate.scaledProgress,
      phaseProgress: progressUpdate.phaseProgress,
      message: progressUpdate.message,
      bytesDownloaded: progressUpdate.bytesDownloaded,
      bytesTotal: progressUpdate.bytesTotal,
      downloadSpeed: progressState.speed
    )

    if let percent = progressUpdate.percent {
      let shouldLog = lock.withLock { () -> Bool in
        guard percent != lastLoggedPercent else { return false }
        lastLoggedPercent = percent
        return true
      }
      if shouldLog {
        logInfo("Download progress: \(percent)%", category: "VMInstaller")
      }
    }
  }

  static func validateHTTPResponse(_ response: URLResponse?) throws {
    guard let httpResponse = response as? HTTPURLResponse else {
      throw VMInstallerError.restoreImageFetchFailed("Download did not return an HTTP response")
    }

    guard (200 ... 299).contains(httpResponse.statusCode) else {
      throw VMInstallerError.restoreImageFetchFailed(
        "IPSW download failed with HTTP \(httpResponse.statusCode)"
      )
    }
    guard let finalURL = httpResponse.url else {
      throw VMInstallerError.restoreImageFetchFailed("IPSW download response is missing its final URL")
    }
    do {
      guard try IPSWSourceValidator.normalized(finalURL.absoluteString) != nil,
            finalURL.scheme?.lowercased() == "https" else
      {
        throw IPSWSourceValidationError.invalid("final URL is not HTTPS")
      }
    } catch {
      throw VMInstallerError.restoreImageFetchFailed(
        "IPSW download ended on an unsafe URL: \(error.localizedDescription)"
      )
    }
  }

  static func validateRedirectTarget(_ request: URLRequest) throws {
    guard let targetURL = request.url else {
      throw VMInstallerError.restoreImageFetchFailed("Refusing an IPSW redirect without a target URL")
    }
    do {
      guard try IPSWSourceValidator.normalized(targetURL.absoluteString) != nil,
            targetURL.scheme?.lowercased() == "https" else
      {
        throw IPSWSourceValidationError.invalid("redirect target is not HTTPS")
      }
    } catch {
      throw VMInstallerError.restoreImageFetchFailed(
        "Refusing an IPSW redirect to an unsafe URL: \(error.localizedDescription)"
      )
    }
  }

  static func makeProgressUpdate(
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64,
    speedBytesPerSecond: UInt64
  ) -> DownloadProgressUpdate {
    let bytesDownloaded = UInt64(max(0, totalBytesWritten))
    let downloadedMB = max(0, totalBytesWritten) / 1_000_000
    let speedMBps = Double(speedBytesPerSecond) / 1_000_000.0

    guard totalBytesExpectedToWrite > 0 else {
      let message = String(
        format: "Downloading: %lldMB downloaded %.1f MB/s",
        downloadedMB,
        speedMBps
      )
      return DownloadProgressUpdate(
        scaledProgress: -1.0,
        phaseProgress: -1.0,
        percent: nil,
        message: message,
        bytesDownloaded: bytesDownloaded,
        bytesTotal: nil
      )
    }

    let rawProgress = min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    let phaseProgress = (rawProgress * 100).rounded() / 100
    let scaledProgress = (rawProgress * VMInstaller.installStart * 100).rounded() / 100
    let totalMB = totalBytesExpectedToWrite / 1_000_000
    let percent = Int(phaseProgress * 100)
    let message = String(
      format: "Downloading: %d%% (%lldMB / %lldMB) %.1f MB/s",
      percent,
      downloadedMB,
      totalMB,
      speedMBps
    )

    return DownloadProgressUpdate(
      scaledProgress: scaledProgress,
      phaseProgress: phaseProgress,
      percent: percent,
      message: message,
      bytesDownloaded: bytesDownloaded,
      bytesTotal: UInt64(totalBytesExpectedToWrite)
    )
  }

  static func safeBytesPerSecond(bytesDelta: Int64, timeDelta: TimeInterval) -> UInt64 {
    guard bytesDelta > 0, timeDelta > 0, timeDelta.isFinite else { return 0 }
    let value = Double(bytesDelta) / timeDelta
    guard value > 0 else { return 0 }
    guard value.isFinite, value < Double(UInt64.max) else { return UInt64.max }
    return UInt64(value)
  }

  private func takeContinuation() -> CheckedContinuation<URL, Error>? {
    lock.lock()
    defer { lock.unlock() }
    let existing = continuation
    continuation = nil
    return existing
  }

  private func clearTask() {
    lock.lock()
    defer { lock.unlock() }
    downloadTask = nil
  }

  private func isCancellation(_ error: Error) -> Bool {
    lock.withLock {
      isCancelled || (error as? URLError)?.code == .cancelled
    }
  }
}

struct DownloadProgressUpdate: Equatable {
  let scaledProgress: Double
  let phaseProgress: Double
  let percent: Int?
  let message: String
  let bytesDownloaded: UInt64
  let bytesTotal: UInt64?
}

// MARK: - Errors

enum VMInstallerError: Error, LocalizedError {
  case invalidIPSWPath(String)
  case invalidIPSW(String)
  case restoreImageFetchFailed(String)
  case noSupportedConfiguration
  case unsupportedHardware(String)
  case diskCreationFailed(String)
  case installationFailed(String)
  case installationSuccessMarkerFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidIPSWPath(let msg): "Invalid IPSW path: \(msg)"
    case .invalidIPSW(let msg): "Invalid IPSW file: \(msg)"
    case .restoreImageFetchFailed(let msg): "Failed to fetch restore image: \(msg)"
    case .noSupportedConfiguration: "No supported macOS configuration available"
    case .unsupportedHardware(let msg): "Unsupported hardware: \(msg)"
    case .diskCreationFailed(let msg): "Failed to create disk image: \(msg)"
    case .installationFailed(let msg): "Installation failed: \(msg)"
    case .installationSuccessMarkerFailed(let msg):
      "macOS installation succeeded, but its durable success marker could not be saved: \(msg)"
    }
  }
}
