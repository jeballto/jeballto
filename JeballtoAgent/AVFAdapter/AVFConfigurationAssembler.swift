import Foundation
@preconcurrency import Virtualization

/// Converts pure VM configuration specs into Apple Virtualization configurations.
struct AVFConfigurationAssembler {
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
    configuration.networkDevices = spec.network.map(createNetworkDevice)
    configuration.graphicsDevices = spec.graphics.map(createGraphicsDevice)
    configuration.audioDevices = spec.audio.map(createAudioDevice)
    configuration.pointingDevices = spec.pointing.map(createPointingDevice)
    configuration.keyboards = spec.keyboards.map(createKeyboard)

    try configuration.validate()
    if spec.validateSaveRestoreSupport {
      try configuration.validateSaveRestoreSupport()
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
    let hardwareModelData = try Data(contentsOf: URL(fileURLWithPath: paths.hardwareModelPath))
    guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
      throw AVFError.invalidHardwareModel
    }

    let machineIdentifierData = try Data(contentsOf: URL(fileURLWithPath: paths.machineIdentifierPath))
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
    var cpuCount = requested
    if cpuCount >= totalAvailableCPUs {
      cpuCount = max(1, totalAvailableCPUs - 1)
    }
    cpuCount = max(cpuCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
    cpuCount = min(cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)

    if let installationRequirements,
       cpuCount < installationRequirements.minimumSupportedCPUCount
    {
      throw AVFError.insufficientResources(
        "CPU count \(cpuCount) is below minimum \(installationRequirements.minimumSupportedCPUCount)"
      )
    }
    return cpuCount
  }

  private func computeMemorySize(
    requested: UInt64,
    installationRequirements: VZMacOSConfigurationRequirements?
  ) throws -> UInt64 {
    var memorySize = requested
    memorySize = max(memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
    memorySize = min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)

    if let installationRequirements,
       memorySize < installationRequirements.minimumSupportedMemorySize
    {
      throw AVFError.insufficientResources("Memory size is below minimum required")
    }
    return memorySize
  }

  private func createStorageDevice(
    from spec: VMConfigurationSpec.StorageDevice
  ) throws -> VZStorageDeviceConfiguration {
    let attachment = try VZDiskImageStorageDeviceAttachment(
      url: URL(fileURLWithPath: spec.path),
      readOnly: spec.readOnly
    )
    switch spec.controller {
    case .virtioBlock:
      return VZVirtioBlockDeviceConfiguration(attachment: attachment)
    }
  }

  private func createNetworkDevice(from spec: VMConfigurationSpec.NetworkDevice) -> VZNetworkDeviceConfiguration {
    let networkDevice = VZVirtioNetworkDeviceConfiguration()
    networkDevice.macAddress = VZMACAddress(string: spec.macAddress) ?? VZMACAddress.randomLocallyAdministered()
    switch spec.attachment {
    case .nat:
      networkDevice.attachment = VZNATNetworkDeviceAttachment()
    }
    return networkDevice
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
