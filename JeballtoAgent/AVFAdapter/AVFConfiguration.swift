import Foundation
import Virtualization

/// Configuration helper for Apple Virtualization Framework (AVF)
/// Creates VZVirtualMachineConfiguration instances for macOS VMs
class AVFConfiguration {
  /// The VM definition containing paths and resource specifications
  let vmDefinition: VMDefinition

  /// Hardware model data loaded from disk
  private var hardwareModel: VZMacHardwareModel?

  /// Machine identifier loaded from disk
  private var machineIdentifier: VZMacMachineIdentifier?

  init(vmDefinition: VMDefinition) { self.vmDefinition = vmDefinition }

  // MARK: - Main Configuration

  /// Creates a complete VZVirtualMachineConfiguration for the VM
  /// - Returns: Configured VZVirtualMachineConfiguration
  /// - Throws: Configuration errors
  func createConfiguration() throws -> VZVirtualMachineConfiguration {
    let configuration = VZVirtualMachineConfiguration()

    let platformConfig = try createPlatformConfiguration()
    configuration.platform = platformConfig
    configuration.bootLoader = createBootLoader()
    configuration.cpuCount = computeCPUCount(requested: vmDefinition.resources.cpuCount)
    configuration.memorySize = computeMemorySize(requested: vmDefinition.resources.memorySize)
    configuration.storageDevices = try [createBlockDeviceConfiguration()]
    configuration.networkDevices = [createNetworkDeviceConfiguration()]
    configuration.graphicsDevices = [createGraphicsDeviceConfiguration()]
    configuration.audioDevices = [createSoundDeviceConfiguration()]
    configuration.pointingDevices = [createPointingDeviceConfiguration()]
    configuration.keyboards = [createKeyboardConfiguration()]

    try configuration.validate()

    return configuration
  }

  // MARK: - Platform Configuration

  /// Creates VZMacPlatformConfiguration with hardware model and machine identifier
  /// See: https://developer.apple.com/documentation/virtualization/vzmacplatformconfiguration
  private func createPlatformConfiguration() throws -> VZMacPlatformConfiguration {
    // Load hardware model from disk
    let hardwareModelData = try Data(contentsOf: URL(fileURLWithPath: vmDefinition.paths.hardwareModelPath))
    guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
      throw AVFError.invalidHardwareModel
    }
    self.hardwareModel = hardwareModel

    // Load machine identifier from disk
    let machineIdentifierData = try Data(contentsOf: URL(fileURLWithPath: vmDefinition.paths.machineIdentifierPath))
    guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIdentifierData) else {
      throw AVFError.invalidMachineIdentifier
    }
    self.machineIdentifier = machineIdentifier

    // Create platform configuration
    let platformConfiguration = VZMacPlatformConfiguration()
    platformConfiguration.hardwareModel = hardwareModel
    platformConfiguration.machineIdentifier = machineIdentifier

    // Attach auxiliary storage
    // See: https://developer.apple.com/documentation/virtualization/vzmacauxiliarystorage
    let auxiliaryStorageURL = URL(fileURLWithPath: vmDefinition.paths.auxiliaryStoragePath)

    logInfo("=== AVFConfiguration: Loading auxiliary storage ===", category: "AVFConfiguration")
    logInfo("Path: \(auxiliaryStorageURL.path)", category: "AVFConfiguration")
    logInfo(
      "File exists: \(FileManager.default.fileExists(atPath: auxiliaryStorageURL.path))",
      category: "AVFConfiguration"
    )

    do {
      let attrs = try FileManager.default.attributesOfItem(atPath: auxiliaryStorageURL.path)
      logInfo("File size: \(attrs[.size] ?? "unknown") bytes", category: "AVFConfiguration")
      logInfo("File creation date: \(attrs[.creationDate] ?? "unknown")", category: "AVFConfiguration")
      logInfo("File modification date: \(attrs[.modificationDate] ?? "unknown")", category: "AVFConfiguration")
    } catch { logError("Cannot read file attributes: \(error.localizedDescription)", category: "AVFConfiguration") }

    logInfo(
      "Attempting to load auxiliary storage using VZMacAuxiliaryStorage(contentsOf:)",
      category: "AVFConfiguration"
    )
    platformConfiguration.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: auxiliaryStorageURL)
    logInfo("Auxiliary storage loaded successfully", category: "AVFConfiguration")

    return platformConfiguration
  }

  // MARK: - CPU Configuration

  /// Computes appropriate CPU count within AVF limits
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration/3656716-cpucount
  private func computeCPUCount(requested: Int) -> Int {
    let totalAvailableCPUs = ProcessInfo.processInfo.processorCount

    // Use requested count, but ensure it's reasonable
    var virtualCPUCount = requested

    // Don't allocate all host CPUs (leave at least 1 for host)
    if virtualCPUCount >= totalAvailableCPUs { virtualCPUCount = max(1, totalAvailableCPUs - 1) }

    // Clamp to AVF limits
    virtualCPUCount = max(virtualCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
    virtualCPUCount = min(virtualCPUCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)

    return virtualCPUCount
  }

  // MARK: - Memory Configuration

  /// Computes appropriate memory size within AVF limits
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration/3656717-memorysize
  private func computeMemorySize(requested: UInt64) -> UInt64 {
    var memorySize = requested

    // Clamp to AVF limits
    memorySize = max(memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
    memorySize = min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

    return memorySize
  }

  // MARK: - Boot Loader

  /// Creates VZMacOSBootLoader for booting macOS
  /// See: https://developer.apple.com/documentation/virtualization/vzmacosbootloader
  private func createBootLoader() -> VZMacOSBootLoader { VZMacOSBootLoader() }

  // MARK: - Storage Configuration

  /// Creates Virtio block device for the main disk
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtioblockdeviceconfiguration
  private func createBlockDeviceConfiguration() throws -> VZVirtioBlockDeviceConfiguration {
    let diskImageURL = URL(fileURLWithPath: vmDefinition.paths.diskImagePath)

    // Attach disk image (read-write)
    let diskImageAttachment = try VZDiskImageStorageDeviceAttachment(url: diskImageURL, readOnly: false)

    let disk = VZVirtioBlockDeviceConfiguration(attachment: diskImageAttachment)
    return disk
  }

  // MARK: - Graphics Configuration

  /// Creates VZMacGraphicsDeviceConfiguration for display
  /// See: https://developer.apple.com/documentation/virtualization/vzmacgraphicsdeviceconfiguration
  private func createGraphicsDeviceConfiguration() -> VZMacGraphicsDeviceConfiguration {
    let graphicsConfiguration = VZMacGraphicsDeviceConfiguration()

    // Use minimal resolution for headless operation
    graphicsConfiguration.displays = [
      VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80),
    ]

    return graphicsConfiguration
  }

  // MARK: - Network Configuration

  /// Creates Virtio network device with NAT attachment
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtionetworkdeviceconfiguration
  /// See: https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment
  private func createNetworkDeviceConfiguration() -> VZVirtioNetworkDeviceConfiguration {
    let networkDevice = VZVirtioNetworkDeviceConfiguration()

    // Use unique MAC address from vmDefinition
    if let macAddress = VZMACAddress(string: vmDefinition.network.macAddress) {
      networkDevice.macAddress = macAddress
    } else {
      // Fallback: generate a new one (should not happen with proper VMDefinition)
      networkDevice.macAddress = VZMACAddress.randomLocallyAdministered()
    }

    // Use NAT networking (no root privileges required)
    // See: https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment
    let networkAttachment = VZNATNetworkDeviceAttachment()
    networkDevice.attachment = networkAttachment

    return networkDevice
  }

  // MARK: - Audio Configuration

  /// Creates Virtio sound device with bidirectional audio
  /// See: https://developer.apple.com/documentation/virtualization/vzvirtiosounddeviceconfiguration
  private func createSoundDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
    let audioConfiguration = VZVirtioSoundDeviceConfiguration()

    // Input stream (microphone)
    let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
    inputStream.source = VZHostAudioInputStreamSource()

    // Output stream (speakers)
    let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
    outputStream.sink = VZHostAudioOutputStreamSink()

    audioConfiguration.streams = [inputStream, outputStream]
    return audioConfiguration
  }

  // MARK: - Input Device Configuration

  /// Creates pointing device configuration (trackpad)
  /// See: https://developer.apple.com/documentation/virtualization/vzmactrackpadconfiguration
  private func createPointingDeviceConfiguration() -> VZPointingDeviceConfiguration {
    VZMacTrackpadConfiguration()
  }

  /// Creates keyboard configuration
  /// See: https://developer.apple.com/documentation/virtualization/vzmackeyboardconfiguration
  private func createKeyboardConfiguration() -> VZKeyboardConfiguration {
    VZMacKeyboardConfiguration()
  }

  // MARK: - Helper Methods

  /// Saves hardware model to disk (for new VM creation)
  static func saveHardwareModel(_ model: VZMacHardwareModel, to path: String) throws {
    try model.dataRepresentation.write(to: URL(fileURLWithPath: path), options: .atomic)
  }

  /// Saves machine identifier to disk (for new VM creation)
  static func saveMachineIdentifier(_ identifier: VZMacMachineIdentifier, to path: String) throws {
    try identifier.dataRepresentation.write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

// MARK: - Errors

/// Errors specific to AVF configuration
enum AVFError: Error, LocalizedError {
  case invalidHardwareModel
  case invalidMachineIdentifier
  case diskImageNotFound(String)
  case configurationValidationFailed(Error)

  var errorDescription: String? {
    switch self {
    case .invalidHardwareModel: "Invalid hardware model data"
    case .invalidMachineIdentifier: "Invalid machine identifier data"
    case .diskImageNotFound(let path): "Disk image not found at: \(path)"
    case .configurationValidationFailed(let error):
      "Configuration validation failed: \(error.localizedDescription)"
    }
  }
}
