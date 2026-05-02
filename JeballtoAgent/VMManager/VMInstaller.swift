// swiftlint:disable file_length

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
    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(
      "Jeballto/IPSWCache"
    )

    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

    // Use filename from URL. The final path's presence = fully downloaded (renames are atomic on same
    // volume). Partial downloads live at `<filename>.partial` and only get promoted on success.
    let filename = remoteURL.lastPathComponent
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

    // Create platform configuration and save artifacts
    statusMessage = "Creating platform configuration..."
    let platformConfig = try createPlatformConfiguration(macOSConfiguration: macOSConfiguration)

    // Create full VM configuration for installation
    statusMessage = "Configuring VM hardware..."
    let vmConfig = try createInstallationConfiguration(
      platformConfig: platformConfig,
      macOSConfiguration: macOSConfiguration
    )

    // Create virtual machine on main queue (required by Virtualization framework)
    statusMessage = "Creating virtual machine..."
    logInfo("Creating VZVirtualMachine for installation on main queue", category: "VMInstaller")
    let (vm, vmDelegate) = await MainActor.run {
      let vm = VZVirtualMachine(configuration: vmConfig)
      let vmDelegate = AVFDelegate(vmId: vmDefinition.id, eventBus: eventBus)
      vm.delegate = vmDelegate
      return (vm, vmDelegate)
    }

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

  /// Creates the VM bundle directory structure
  private func createVMBundle() throws {
    let bundlePath = vmDefinition.paths.bundlePath

    try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)

    logInfo("Created VM bundle at \(bundlePath)", category: "VMInstaller")
  }

  /// Creates the Mac platform configuration with hardware model and machine identifier
  private func createPlatformConfiguration(macOSConfiguration: VZMacOSConfigurationRequirements) throws
    -> VZMacPlatformConfiguration
  {
    let platformConfig = VZMacPlatformConfiguration()
    let auxiliaryStorageURL = URL(fileURLWithPath: vmDefinition.paths.auxiliaryStoragePath)

    logDebug("Creating auxiliary storage at \(auxiliaryStorageURL.path)", category: "VMInstaller")

    let auxiliaryStorage: VZMacAuxiliaryStorage
    do {
      auxiliaryStorage = try VZMacAuxiliaryStorage(
        creatingStorageAt: auxiliaryStorageURL,
        hardwareModel: macOSConfiguration.hardwareModel,
        options: []
      )
    } catch {
      logError(
        "Failed to create auxiliary storage at \(auxiliaryStorageURL.path): \(error.localizedDescription)",
        category: "VMInstaller"
      )
      throw VMInstallerError.auxiliaryStorageCreationFailed(error.localizedDescription)
    }

    logDebug("Auxiliary storage created successfully", category: "VMInstaller")

    platformConfig.auxiliaryStorage = auxiliaryStorage
    platformConfig.hardwareModel = macOSConfiguration.hardwareModel
    platformConfig.machineIdentifier = VZMacMachineIdentifier()

    let hardwareModelURL = URL(fileURLWithPath: vmDefinition.paths.hardwareModelPath)
    let machineIdentifierURL = URL(fileURLWithPath: vmDefinition.paths.machineIdentifierPath)

    try platformConfig.hardwareModel.dataRepresentation.write(to: hardwareModelURL)
    try platformConfig.machineIdentifier.dataRepresentation.write(to: machineIdentifierURL)

    logDebug("Created and saved platform configuration artifacts", category: "VMInstaller")

    return platformConfig
  }

  /// Creates the full VM configuration for installation
  private func createInstallationConfiguration(
    platformConfig: VZMacPlatformConfiguration,
    macOSConfiguration: VZMacOSConfigurationRequirements
  ) throws -> VZVirtualMachineConfiguration {
    let config = VZVirtualMachineConfiguration()

    config.platform = platformConfig

    let cpuCount = computeCPUCount(requested: vmDefinition.resources.cpuCount)
    if cpuCount < macOSConfiguration.minimumSupportedCPUCount {
      throw VMInstallerError.insufficientResources(
        "CPU count \(cpuCount) is below minimum \(macOSConfiguration.minimumSupportedCPUCount)"
      )
    }
    config.cpuCount = cpuCount

    let memorySize = computeMemorySize(requested: vmDefinition.resources.memorySize)
    if memorySize < macOSConfiguration.minimumSupportedMemorySize {
      throw VMInstallerError.insufficientResources("Memory size is below minimum required")
    }
    config.memorySize = memorySize

    try createDiskImage()

    config.bootLoader = VZMacOSBootLoader()
    config.storageDevices = try [createBlockDeviceConfiguration()]
    config.networkDevices = [createNetworkDeviceConfiguration()]
    config.graphicsDevices = [createGraphicsDeviceConfiguration()]
    config.audioDevices = [createSoundDeviceConfiguration()]
    config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    config.keyboards = [VZUSBKeyboardConfiguration()]

    try config.validate()

    try config.validateSaveRestoreSupport()

    logInfo("Created installation VM configuration", category: "VMInstaller")

    return config
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

  /// Creates block device configuration for the disk
  private func createBlockDeviceConfiguration() throws -> VZVirtioBlockDeviceConfiguration {
    let diskImageURL = URL(fileURLWithPath: vmDefinition.paths.diskImagePath)
    let attachment = try VZDiskImageStorageDeviceAttachment(url: diskImageURL, readOnly: false)
    return VZVirtioBlockDeviceConfiguration(attachment: attachment)
  }

  /// Creates network device configuration
  private func createNetworkDeviceConfiguration() -> VZVirtioNetworkDeviceConfiguration {
    let networkDevice = VZVirtioNetworkDeviceConfiguration()

    if let macAddress = VZMACAddress(string: vmDefinition.network.macAddress) {
      networkDevice.macAddress = macAddress
    } else {
      networkDevice.macAddress = VZMACAddress.randomLocallyAdministered()
    }

    networkDevice.attachment = VZNATNetworkDeviceAttachment()
    return networkDevice
  }

  /// Creates graphics device configuration
  private func createGraphicsDeviceConfiguration() -> VZMacGraphicsDeviceConfiguration {
    let graphicsConfig = VZMacGraphicsDeviceConfiguration()
    graphicsConfig.displays = [
      VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80),
    ]
    return graphicsConfig
  }

  /// Creates sound device configuration
  private func createSoundDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
    let soundDevice = VZVirtioSoundDeviceConfiguration()
    let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
    outputStream.sink = VZHostAudioOutputStreamSink()
    soundDevice.streams = [outputStream]
    return soundDevice
  }

  /// Computes appropriate CPU count
  private func computeCPUCount(requested: Int) -> Int {
    let totalAvailableCPUs = ProcessInfo.processInfo.processorCount
    var cpuCount = requested

    // Don't allocate all host CPUs (leave at least 1 for host)
    if cpuCount >= totalAvailableCPUs { cpuCount = max(1, totalAvailableCPUs - 1) }

    // Clamp to AVF limits
    cpuCount = max(cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
    cpuCount = min(cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)

    return cpuCount
  }

  /// Computes appropriate memory size
  private func computeMemorySize(requested: UInt64) -> UInt64 {
    var memorySize = requested

    // Clamp to AVF limits
    memorySize = max(memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
    memorySize = min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

    return memorySize
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

    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.main.async {
        logInfo("Creating VZMacOSInstaller with local IPSW URL: \(localIPSWURL)", category: "VMInstaller")
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: localIPSWURL)

        // Set up progress observer BEFORE starting install
        logInfo("Setting up installation progress observer", category: "VMInstaller")
        let installStart = Self.installStart
        let installRange = 1.0 - installStart
        let observer = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) {
          [weak self] _, change in // swiftlint:disable:this closure_parameter_position
          guard let self, let newProgress = change.newValue else { return }

          if newProgress == 0.0 {
            // VZMacOSInstaller hasn't started reporting real progress yet
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
        self.setInstallationObserver(observer)

        // Start installation
        logInfo("Calling installer.install()", category: "VMInstaller")
        installer.install { result in
          // Clean up observer
          self.clearInstallationObserver()

          switch result {
          case .success:
            logInfo("Installation completed successfully (VM state: \(vm.state.rawValue))", category: "VMInstaller")
            continuation.resume()
          case .failure(let error):
            logError("Installation failed: \(error.localizedDescription)", category: "VMInstaller")
            continuation.resume(throwing: VMInstallerError.installationFailed(error.localizedDescription))
          }
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
    let task = session.downloadTask(with: url)
    lock.lock()
    self.continuation = continuation
    downloadTask = task
    lock.unlock()
    task.resume()
  }

  func cancel() {
    let continuation = takeContinuation()
    lock.lock()
    let task = downloadTask
    downloadTask = nil
    lock.unlock()
    task?.cancel()
    continuation?.resume(throwing: CancellationError())
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
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
    // Called on network errors or HTTP failures (didFinishDownloadingTo is NOT called on error)
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

    let rawProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    let phaseProgress = (rawProgress * 100).rounded() / 100
    let scaledProgress = (rawProgress * VMInstaller.installStart * 100).rounded() / 100
    let downloadedMB = totalBytesWritten / 1_000_000
    let totalMB = totalBytesExpectedToWrite / 1_000_000
    let speedMBps = Double(lastCalculatedSpeed) / 1_000_000.0
    let message = String(
      format: "Downloading: %d%% (%lldMB / %lldMB) %.1f MB/s",
      Int(phaseProgress * 100), downloadedMB, totalMB, speedMBps
    )

    let percent = Int(phaseProgress * 100)
    DispatchQueue.main.async {
      installer.updateDownloadProgress(
        scaledProgress, phaseProgress: phaseProgress, message: message,
        bytesDownloaded: UInt64(totalBytesWritten),
        bytesTotal: UInt64(totalBytesExpectedToWrite),
        downloadSpeed: self.lastCalculatedSpeed
      )

      if percent != self.lastLoggedPercent {
        self.lastLoggedPercent = percent
        logInfo("Download progress: \(percent)%", category: "VMInstaller")
      }
    }
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

// MARK: - Errors

enum VMInstallerError: Error, LocalizedError {
  case invalidIPSWPath(String)
  case invalidIPSW(String)
  case restoreImageFetchFailed(String)
  case noSupportedConfiguration
  case unsupportedHardware(String)
  case insufficientResources(String)
  case auxiliaryStorageCreationFailed(String)
  case diskCreationFailed(String)
  case installationFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidIPSWPath(let msg): "Invalid IPSW path: \(msg)"
    case .invalidIPSW(let msg): "Invalid IPSW file: \(msg)"
    case .restoreImageFetchFailed(let msg): "Failed to fetch restore image: \(msg)"
    case .noSupportedConfiguration: "No supported macOS configuration available"
    case .unsupportedHardware(let msg): "Unsupported hardware: \(msg)"
    case .insufficientResources(let msg): "Insufficient resources: \(msg)"
    case .auxiliaryStorageCreationFailed(let msg): "Failed to create auxiliary storage: \(msg)"
    case .diskCreationFailed(let msg): "Failed to create disk image: \(msg)"
    case .installationFailed(let msg): "Installation failed: \(msg)"
    }
  }
}
