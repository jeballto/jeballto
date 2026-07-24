import Darwin
import Foundation
@preconcurrency import Virtualization

/// Converts pure VM configuration specs into Apple Virtualization configurations.
struct AVFConfigurationAssembler {
  /// Validates requested resources against the current host without changing them.
  func validateHostResources(_ resources: VMResources) throws {
    _ = try computeCPUCount(requested: resources.cpuCount, installationRequirements: nil)
    _ = try computeMemorySize(requested: resources.memorySize, installationRequirements: nil)
  }

  func validateResources(
    in spec: VMConfigurationSpec,
    installationRequirements: VZMacOSConfigurationRequirements?
  ) throws {
    _ = try computeCPUCount(
      requested: spec.resources.cpuCount,
      installationRequirements: installationRequirements
    )
    _ = try computeMemorySize(
      requested: spec.resources.memorySize,
      installationRequirements: installationRequirements
    )
  }

  func createConfiguration(
    from spec: VMConfigurationSpec,
    installationRequirements: VZMacOSConfigurationRequirements? = nil
  ) throws -> VZVirtualMachineConfiguration {
    let configuration = VZVirtualMachineConfiguration()

    configuration.platform = try createPlatformConfiguration(
      from: spec.platform,
      installationRequirements: installationRequirements
    )
    configuration.bootLoader = VZMacOSBootLoader()
    configuration.cpuCount = try computeCPUCount(
      requested: spec.resources.cpuCount,
      installationRequirements: installationRequirements
    )
    configuration.memorySize = try computeMemorySize(
      requested: spec.resources.memorySize,
      installationRequirements: installationRequirements
    )
    configuration.storageDevices = try spec.storage.map(createStorageDevice)
    configuration.networkDevices = try spec.network.map(createNetworkDevice)
    configuration.graphicsDevices = spec.graphics.map(createGraphicsDevice)
    configuration.audioDevices = spec.audio.map(createAudioDevice)
    configuration.pointingDevices = spec.pointing.map(createPointingDevice)
    configuration.keyboards = spec.keyboards.map(createKeyboard)

    do {
      try configuration.validate()
      if spec.validateSaveRestoreSupport {
        try configuration.validateSaveRestoreSupport()
      }
    } catch {
      throw AVFError.configurationValidationFailed(error)
    }

    return configuration
  }

  private func createPlatformConfiguration(
    from spec: VMConfigurationSpec.MacPlatformSpec,
    installationRequirements: VZMacOSConfigurationRequirements?
  ) throws -> VZMacPlatformConfiguration {
    switch spec {
    case .existing(let paths):
      return try createExistingPlatformConfiguration(paths: paths)
    case .installation(let paths):
      guard let installationRequirements else {
        throw AVFError.missingInstallationRequirements
      }
      return try createInstallationPlatformConfiguration(
        paths: paths,
        installationRequirements: installationRequirements
      )
    }
  }

  private func createExistingPlatformConfiguration(
    paths: VMConfigurationSpec.PlatformPaths
  ) throws -> VZMacPlatformConfiguration {
    let hardwareModelData = try readPlatformIdentity(at: paths.hardwareModelPath)
    guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
      throw AVFError.invalidHardwareModel
    }

    let machineIdentifierData = try readPlatformIdentity(at: paths.machineIdentifierPath)
    guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIdentifierData) else {
      throw AVFError.invalidMachineIdentifier
    }

    let platformConfiguration = VZMacPlatformConfiguration()
    platformConfiguration.hardwareModel = hardwareModel
    platformConfiguration.machineIdentifier = machineIdentifier
    platformConfiguration.auxiliaryStorage = VZMacAuxiliaryStorage(
      contentsOf: URL(fileURLWithPath: paths.auxiliaryStoragePath)
    )
    return platformConfiguration
  }

  private func createInstallationPlatformConfiguration(
    paths: VMConfigurationSpec.PlatformPaths,
    installationRequirements: VZMacOSConfigurationRequirements
  ) throws -> VZMacPlatformConfiguration {
    let auxiliaryStorageURL = URL(fileURLWithPath: paths.auxiliaryStoragePath)
    let auxiliaryStorage: VZMacAuxiliaryStorage
    do {
      auxiliaryStorage = try VZMacAuxiliaryStorage(
        creatingStorageAt: auxiliaryStorageURL,
        hardwareModel: installationRequirements.hardwareModel,
        options: []
      )
    } catch {
      throw AVFError.auxiliaryStorageCreationFailed(error.localizedDescription)
    }

    let platformConfiguration = VZMacPlatformConfiguration()
    platformConfiguration.auxiliaryStorage = auxiliaryStorage
    platformConfiguration.hardwareModel = installationRequirements.hardwareModel
    platformConfiguration.machineIdentifier = VZMacMachineIdentifier()

    try platformConfiguration.hardwareModel.dataRepresentation.write(
      to: URL(fileURLWithPath: paths.hardwareModelPath),
      options: .atomic
    )
    try platformConfiguration.machineIdentifier.dataRepresentation.write(
      to: URL(fileURLWithPath: paths.machineIdentifierPath),
      options: .atomic
    )

    return platformConfiguration
  }

  private func computeCPUCount(
    requested: Int,
    installationRequirements: VZMacOSConfigurationRequirements?
  ) throws -> Int {
    let totalAvailableCPUs = ProcessInfo.processInfo.processorCount
    let maximumForHost = max(1, totalAvailableCPUs - 1)
    guard requested <= maximumForHost else {
      throw AVFError.insufficientResources(
        "Requested \(requested) CPUs, but this host supports at most \(maximumForHost) guest CPUs"
      )
    }
    guard requested >= VZVirtualMachineConfiguration.minimumAllowedCPUCount,
          requested <= VZVirtualMachineConfiguration.maximumAllowedCPUCount else
    {
      throw AVFError.insufficientResources("Requested CPU count is outside Virtualization framework limits")
    }

    if let installationRequirements,
       requested < installationRequirements.minimumSupportedCPUCount
    {
      throw AVFError.insufficientResources(
        "CPU count \(requested) is below minimum \(installationRequirements.minimumSupportedCPUCount)"
      )
    }
    return requested
  }

  private func computeMemorySize(
    requested: UInt64,
    installationRequirements: VZMacOSConfigurationRequirements?
  ) throws -> UInt64 {
    guard requested >= VZVirtualMachineConfiguration.minimumAllowedMemorySize,
          requested <= VZVirtualMachineConfiguration.maximumAllowedMemorySize else
    {
      throw AVFError.insufficientResources("Requested memory is outside Virtualization framework limits")
    }

    if let installationRequirements,
       requested < installationRequirements.minimumSupportedMemorySize
    {
      throw AVFError.insufficientResources("Memory size is below minimum required")
    }
    return requested
  }

  private func createStorageDevice(
    from spec: VMConfigurationSpec.StorageDevice
  ) throws -> VZStorageDeviceConfiguration {
    guard FileManager.default.fileExists(atPath: spec.path) else {
      throw AVFError.diskImageNotFound(spec.path)
    }
    let attachment: VZDiskImageStorageDeviceAttachment
    do {
      attachment = try VZDiskImageStorageDeviceAttachment(
        url: URL(fileURLWithPath: spec.path),
        readOnly: spec.readOnly
      )
    } catch {
      throw AVFError.storageAttachmentFailed(spec.path, error.localizedDescription)
    }
    switch spec.controller {
    case .virtioBlock:
      return VZVirtioBlockDeviceConfiguration(attachment: attachment)
    }
  }

  private func createNetworkDevice(
    from spec: VMConfigurationSpec.NetworkDevice
  ) throws -> VZNetworkDeviceConfiguration {
    let networkDevice = VZVirtioNetworkDeviceConfiguration()
    guard let macAddress = VZMACAddress(string: spec.macAddress) else {
      throw AVFError.invalidMACAddress(spec.macAddress)
    }
    networkDevice.macAddress = macAddress
    switch spec.attachment {
    case .nat:
      networkDevice.attachment = VZNATNetworkDeviceAttachment()
    }
    return networkDevice
  }

  private func readPlatformIdentity(at path: String) throws -> Data {
    let maximumSize = 1_048_576
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw AVFError.platformIdentityReadFailed(path, Self.posixMessage())
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
          status.st_mode & S_IFMT == S_IFREG else
    {
      throw AVFError.platformIdentityReadFailed(path, "Expected a regular file")
    }
    guard status.st_size >= 0, UInt64(status.st_size) <= UInt64(maximumSize) else {
      throw AVFError.platformIdentityReadFailed(path, "File exceeds the 1MB limit")
    }
    do {
      let data = try handle.read(upToCount: maximumSize + 1) ?? Data()
      guard data.count <= maximumSize else {
        throw AVFError.platformIdentityReadFailed(path, "File exceeds the 1MB limit")
      }
      return data
    } catch let error as AVFError {
      throw error
    } catch {
      throw AVFError.platformIdentityReadFailed(path, error.localizedDescription)
    }
  }

  private static func posixMessage(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
  }

  private func createGraphicsDevice(from spec: VMConfigurationSpec.GraphicsDevice) -> VZGraphicsDeviceConfiguration {
    let graphicsConfiguration = VZMacGraphicsDeviceConfiguration()
    graphicsConfiguration.displays = spec.displays.map {
      VZMacGraphicsDisplayConfiguration(
        widthInPixels: $0.widthInPixels,
        heightInPixels: $0.heightInPixels,
        pixelsPerInch: $0.pixelsPerInch
      )
    }
    return graphicsConfiguration
  }

  private func createAudioDevice(from spec: VMConfigurationSpec.AudioDevice) -> VZAudioDeviceConfiguration {
    let audioConfiguration = VZVirtioSoundDeviceConfiguration()
    var streams: [VZVirtioSoundDeviceStreamConfiguration] = []
    if spec.inputEnabled {
      let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
      inputStream.source = VZHostAudioInputStreamSource()
      streams.append(inputStream)
    }
    if spec.outputEnabled {
      let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
      outputStream.sink = VZHostAudioOutputStreamSink()
      streams.append(outputStream)
    }
    audioConfiguration.streams = streams
    return audioConfiguration
  }

  private func createPointingDevice(
    from spec: VMConfigurationSpec.PointingDevice
  ) -> VZPointingDeviceConfiguration {
    switch spec {
    case .macTrackpad:
      VZMacTrackpadConfiguration()
    case .usbScreenCoordinate:
      VZUSBScreenCoordinatePointingDeviceConfiguration()
    }
  }

  private func createKeyboard(from spec: VMConfigurationSpec.KeyboardDevice) -> VZKeyboardConfiguration {
    switch spec {
    case .macKeyboard:
      VZMacKeyboardConfiguration()
    case .usbKeyboard:
      VZUSBKeyboardConfiguration()
    }
  }
}
