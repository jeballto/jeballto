// swiftlint:disable file_length

import CryptoKit
import Foundation
@preconcurrency import Virtualization

/// Handles macOS installation into VMs
class VMInstaller: NSObject, @unchecked Sendable { // swiftlint:disable:this type_body_length
  private let stateLock = NSLock()

  /// The VM definition containing paths and configuration
  private let vmDefinition: VMDefinition

  /// Event bus for publishing installation progress
  private let eventBus: EventBus

  /// The virtual machine used for installation
  private(set) var virtualMachine: VZVirtualMachine?

  /// Installation observer for progress tracking
  private var installationObserver: NSKeyValueObservation?

  /// Delegate for VM events during installation
  private(set) var delegate: AVFDelegate?

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

  // Progress: first half (0%→50%) is setup/download, second half (50%→100%) is macOS installation
  fileprivate static let installStart: Double = 0.50

  init(vmDefinition: VMDefinition, eventBus: EventBus) {
    self.vmDefinition = vmDefinition
    self.eventBus = eventBus
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

  // MARK: - Public Installation Methods

  /// Downloads latest macOS restore image and installs it
  func downloadAndInstall() async throws {
    logInfo("Starting auto-download and installation for VM \(vmDefinition.id)", category: "VMInstaller")

    // Publish installation started event
    eventBus.publish(.installStarted(vmId: vmDefinition.id))
    statusMessage = "Fetching restore image info..."
    publishProgress(0.0)

    // Fetch latest restore image
    do {
      let restoreImage = try await fetchLatestRestoreImage()

      statusMessage = "Preparing installation..."

      // Install from the restore image
      try await installMacOS(restoreImage: restoreImage)
    } catch {
      // Provide helpful error message
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
      - Use a local IPSW file instead: POST /v1/vms/{id}/install with {"ipswPath": "/path/to/file.ipsw"}
      """

      logError(errorMsg, category: "VMInstaller")
      throw VMInstallerError.restoreImageFetchFailed(errorMsg)
    }
  }

  /// Installs macOS from a local IPSW file
  func installFromIPSW(ipswPath: String) async throws {
    logInfo("Starting installation from IPSW for VM \(vmDefinition.id): \(ipswPath)", category: "VMInstaller")

    let ipswURL = URL(fileURLWithPath: ipswPath)
    guard ipswURL.isFileURL else { throw VMInstallerError.invalidIPSWPath("Path is not a valid file URL") }

    guard FileManager.default.fileExists(atPath: ipswPath) else {
      throw VMInstallerError.invalidIPSWPath("IPSW file does not exist at path")
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
    logInfo("Starting installation from remote URL for VM \(vmDefinition.id): \(urlString)", category: "VMInstaller")

    guard let remoteURL = URL(string: urlString) else {
      throw VMInstallerError.invalidIPSWPath("Invalid URL: \(urlString)")
    }

    eventBus.publish(.installStarted(vmId: vmDefinition.id))
    statusMessage = "Downloading IPSW..."
    publishProgress(0.0)

    let localIPSWURL = try await downloadIPSW(from: remoteURL)

    statusMessage = "Download complete, loading restore image..."
    publishProgress(Self.installStart)

    let restoreImage = try await loadRestoreImage(from: localIPSWURL)

    try await installMacOS(restoreImage: restoreImage)
  }

  // MARK: - Internal Installation Steps

  /// Fetches the latest macOS restore image with retry logic
  private func fetchLatestRestoreImage() async throws -> VZMacOSRestoreImage {
    logInfo("Fetching latest macOS restore image from Apple...", category: "VMInstaller")

    // Retry up to 3 times with exponential backoff
    var lastError: Error?
    for attempt in 1 ... 3 {
      do {
        let image = try await fetchRestoreImageAttempt()
        logInfo("Successfully fetched restore image on attempt \(attempt)", category: "VMInstaller")
        return image
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
  private func fetchRestoreImageAttempt() async throws -> VZMacOSRestoreImage {
    try await withCheckedThrowingContinuation { continuation in
      VZMacOSRestoreImage.fetchLatestSupported { result in
        switch result {
        case .success(let restoreImage):
          logInfo("Restore image fetched: \(restoreImage.url.lastPathComponent)", category: "VMInstaller")
          continuation.resume(returning: restoreImage)
        case .failure(let error):
          logError("Restore image fetch failed: \(error.localizedDescription)", category: "VMInstaller")
          continuation.resume(throwing: error)
        }
      }
    }
  }

  /// Loads a restore image from an IPSW file
  private func loadRestoreImage(from url: URL) async throws -> VZMacOSRestoreImage {
    try await withCheckedThrowingContinuation { continuation in
      VZMacOSRestoreImage.load(from: url) { result in
        switch result {
        case .success(let restoreImage): continuation.resume(returning: restoreImage)
        case .failure(let error):
          continuation.resume(throwing: VMInstallerError.invalidIPSW(error.localizedDescription))
        }
      }
    }
  }

  /// Downloads IPSW file from remote URL to local cache
  private func downloadIPSW(from remoteURL: URL) async throws -> URL {
    // Create cache directory
    let cacheDir = JeballtoCachePaths.ipswCache

    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

    let filename = Self.cacheFilename(for: remoteURL)
    let localURL = cacheDir.appendingPathComponent(filename)
    let partialURL = cacheDir.appendingPathComponent("\(filename).partial")

    if FileManager.default.fileExists(atPath: localURL.path) {
      logInfo("IPSW already cached at \(localURL.path)", category: "VMInstaller")
      return localURL
    }

    // Clean up any stale partial file from a previous interrupted run
    if FileManager.default.fileExists(atPath: partialURL.path) {
      logWarning("Removing stale partial IPSW at \(partialURL.path)", category: "VMInstaller")
      try? FileManager.default.removeItem(at: partialURL)
    }

    logInfo("Downloading IPSW from \(remoteURL) to \(localURL.path)", category: "VMInstaller")

    // Publish initial download state with 0 bytes so fields appear in API response
    updateDownloadProgress(
      0.0, phaseProgress: 0.0, message: "Downloading macOS restore image...",
      bytesDownloaded: 0, bytesTotal: 0, downloadSpeed: 0
    )

    // Create session with delegate for progress tracking and completion
    // IMPORTANT: Must use downloadTask WITHOUT completion handler  - using a completion
    // handler bypasses delegate methods (didWriteData) so progress would never update.
    let delegate = DownloadDelegate(installer: self, destinationURL: partialURL)
    let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    let downloadedURL: URL = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        delegate.startDownload(from: remoteURL, session: session, continuation: continuation)
      }
    } onCancel: {
      delegate.cancel()
    }

    // Promote partial to final with an atomic rename; on failure, leave partial for cleanup next run.
    do {
      try FileManager.default.moveItem(at: downloadedURL, to: localURL)
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

    let rawFilename = remoteURL.lastPathComponent.isEmpty ? "restore.ipsw" : remoteURL.lastPathComponent
    let filename = rawFilename.replacingOccurrences(of: "/", with: "_")
    let nsFilename = filename as NSString
    let ext = nsFilename.pathExtension
    let rawStem = nsFilename.deletingPathExtension.isEmpty ? "restore" : nsFilename.deletingPathExtension
    let stem = String(rawStem.prefix(180))

    if ext.isEmpty {
      return "\(stem)-\(digest)"
    }
    return "\(stem)-\(digest).\(ext)"
  }

  /// Installs macOS from a restore image
  private func installMacOS(restoreImage: VZMacOSRestoreImage) async throws {
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
    try createDiskImage()
    let vmConfig = try assembler.createConfiguration(
      from: installSpec,
      installationRequirements: macOSConfiguration
    )

    // Create virtual machine on main queue (required by Virtualization framework)
    statusMessage = "Creating virtual machine..."
    logInfo("Creating VZVirtualMachine for installation on main queue", category: "VMInstaller")
    let runtime = await createInstallationRuntime(configuration: vmConfig)
    let vm = runtime.virtualMachine
    let vmDelegate = runtime.delegate

    virtualMachine = vm
    delegate = vmDelegate
    logInfo("VZVirtualMachine created successfully on main queue", category: "VMInstaller")

    statusMessage = "Preparing IPSW..."
    publishProgress(0.0)

    // Run installation
    logInfo("Starting macOS installation from restore image: \(restoreImage.url)", category: "VMInstaller")
    try await runInstallation(vm: vm, restoreImageURL: restoreImage.url)

    statusMessage = "Installation completed"
    publishProgress(1.0)
    eventBus.publish(.installCompleted(vmId: vmDefinition.id))

    logInfo("Installation completed for VM \(vmDefinition.id)", category: "VMInstaller")
  }

  @MainActor
  private func createInstallationRuntime(
    configuration: sending VZVirtualMachineConfiguration
  ) -> VirtualizationRuntime {
    VirtualizationRuntimeFactory().makeRuntime(
      configuration: configuration,
      vmId: vmDefinition.id,
      eventBus: eventBus
    )
  }

  /// Creates the VM bundle directory structure
  private func createVMBundle() throws {
    let bundlePath = vmDefinition.paths.bundlePath

    try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)

    logInfo("Created VM bundle at \(bundlePath)", category: "VMInstaller")
  }

  /// Creates the disk image for the VM
  private func createDiskImage() throws {
    let diskImageURL = URL(fileURLWithPath: vmDefinition.paths.diskImagePath)
    let diskSize = vmDefinition.resources.diskSize

    try createASIFDiskImage(at: diskImageURL, size: diskSize)

    logInfo(
      "Created disk image: \(diskSize / (1024 * 1024 * 1024)) GB at \(diskImageURL.path)",
      category: "VMInstaller"
    )
  }

  /// Creates ASIF disk image
  private func createASIFDiskImage(at url: URL, size: UInt64) throws {
    logInfo("Creating ASIF disk image", category: "VMInstaller")
    let sizeGB = size / (1024 * 1024 * 1024)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = [
      "image", "create", "blank", "--fs", "none", "--format", "ASIF", "--size", "\(sizeGB)GiB", url.path,
    ]

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      throw VMInstallerError.diskCreationFailed("diskutil failed with status \(process.terminationStatus)")
    }
  }

  /// Runs the installation process
  private func runInstallation(vm: VZVirtualMachine, restoreImageURL: URL) async throws {
    // swiftlint:disable:previous function_body_length
    // Download IPSW if it's a remote URL
    let localIPSWURL: URL
    if restoreImageURL.scheme == "https" || restoreImageURL.scheme == "http" {
      logInfo("Restore image is remote URL, downloading to local cache...", category: "VMInstaller")
      statusMessage = "Downloading macOS restore image..."
      publishProgress(0.0)

      localIPSWURL = try await downloadIPSW(from: restoreImageURL)

      statusMessage = "Download complete"
      publishProgress(Self.installStart)
    } else {
      localIPSWURL = restoreImageURL
    }

    // Virtualization framework requires running on main thread
    logInfo("Switching to main thread for VZMacOSInstaller operations", category: "VMInstaller")

    try await installOnMainActor(vm: vm, localIPSWURL: localIPSWURL)
  }

  @MainActor
  private func installOnMainActor(vm: sending VZVirtualMachine, localIPSWURL: URL) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      logInfo("Creating VZMacOSInstaller with local IPSW URL: \(localIPSWURL)", category: "VMInstaller")
      let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: localIPSWURL)

      logInfo("Setting up installation progress observer", category: "VMInstaller")
      let installStart = Self.installStart
      let installRange = 1.0 - installStart
      let observer = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) {
        [weak self] _, change in // swiftlint:disable:this closure_parameter_position
        guard let self, let newProgress = change.newValue else { return }

        if newProgress == 0.0 {
          publishIndeterminateProgress("Preparing macOS installation...")
          return
        }

        let scaledProgress = installStart + (newProgress * installRange)
        progress = scaledProgress

        statusMessage = "Installing macOS: \(Int(newProgress * 100))%"
        publishProgress(scaledProgress)

        let percent = Int(newProgress * 100)
        if shouldLogInstallProgress(percent: percent) {
          logInfo("Installation progress: \(percent)%", category: "VMInstaller")
        }
      }
      setInstallationObserver(observer)

      logInfo("Calling installer.install()", category: "VMInstaller")
      installer.install { [weak self] result in
        self?.clearInstallationObserver()

        switch result {
        case .success:
          logInfo("Installation completed successfully", category: "VMInstaller")
          continuation.resume()
        case .failure(let error):
          logError("Installation failed: \(error.localizedDescription)", category: "VMInstaller")
          continuation.resume(throwing: VMInstallerError.installationFailed(error.localizedDescription))
        }
      }
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

// MARK: - Download Delegate

class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
  weak var installer: VMInstaller?
  private let lock = NSLock()
  private var continuation: CheckedContinuation<URL, Error>?
  private var downloadTask: URLSessionDownloadTask?
  private var isCancelled = false
  private let destinationURL: URL
  private var lastLoggedPercent: Int = -1
  private var lastProgressUpdateTime: Date = .distantPast
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
    takeContinuation()?.resume(throwing: VMInstallerError.restoreImageFetchFailed(
      "Failed to download IPSW: \(error.localizedDescription)"
    ))
    clearTask()
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
    let now = Date()
    let timeDelta = now.timeIntervalSince(lastProgressUpdateTime)
    guard timeDelta >= 0.5 else { return }

    // Calculate instantaneous download speed
    let bytesDelta = totalBytesWritten - lastSpeedCheckBytes
    if bytesDelta > 0 {
      lastCalculatedSpeed = UInt64(Double(bytesDelta) / timeDelta)
    }
    lastProgressUpdateTime = now
    lastSpeedCheckBytes = totalBytesWritten

    let progressUpdate = Self.makeProgressUpdate(
      totalBytesWritten: totalBytesWritten,
      totalBytesExpectedToWrite: totalBytesExpectedToWrite,
      speedBytesPerSecond: lastCalculatedSpeed
    )
    DispatchQueue.main.async {
      installer.updateDownloadProgress(
        progressUpdate.scaledProgress,
        phaseProgress: progressUpdate.phaseProgress,
        message: progressUpdate.message,
        bytesDownloaded: progressUpdate.bytesDownloaded,
        bytesTotal: progressUpdate.bytesTotal,
        downloadSpeed: self.lastCalculatedSpeed
      )

      if let percent = progressUpdate.percent, percent != self.lastLoggedPercent {
        self.lastLoggedPercent = percent
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

  var errorDescription: String? {
    switch self {
    case .invalidIPSWPath(let msg): "Invalid IPSW path: \(msg)"
    case .invalidIPSW(let msg): "Invalid IPSW file: \(msg)"
    case .restoreImageFetchFailed(let msg): "Failed to fetch restore image: \(msg)"
    case .noSupportedConfiguration: "No supported macOS configuration available"
    case .unsupportedHardware(let msg): "Unsupported hardware: \(msg)"
    case .diskCreationFailed(let msg): "Failed to create disk image: \(msg)"
    case .installationFailed(let msg): "Installation failed: \(msg)"
    }
  }
}
