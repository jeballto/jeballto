import Foundation

/// Builds pure macOS VM configuration specs from persisted VM definitions.
struct MacVMConfigurationBuilder {
  func makeRuntimeSpec(for definition: VMDefinition) -> VMConfigurationSpec {
    makeSpec(
      for: definition,
      platform: .existing(platformPaths(for: definition)),
      audio: [VMConfigurationSpec.AudioDevice(inputEnabled: true, outputEnabled: true)],
      pointing: [.macTrackpad],
      keyboards: [.macKeyboard]
    )
  }

  func makeInstallationSpec(for definition: VMDefinition) -> VMConfigurationSpec {
    makeSpec(
      for: definition,
      platform: .installation(platformPaths(for: definition)),
      audio: [VMConfigurationSpec.AudioDevice(inputEnabled: false, outputEnabled: true)],
      pointing: [.usbScreenCoordinate],
      keyboards: [.usbKeyboard]
    )
  }

  private func makeSpec(
    for definition: VMDefinition,
    platform: VMConfigurationSpec.MacPlatformSpec,
    audio: [VMConfigurationSpec.AudioDevice],
    pointing: [VMConfigurationSpec.PointingDevice],
    keyboards: [VMConfigurationSpec.KeyboardDevice]
  ) -> VMConfigurationSpec {
    VMConfigurationSpec(
      platform: platform,
      resources: VMConfigurationSpec.Resources(
        cpuCount: definition.resources.cpuCount,
        memorySize: definition.resources.memorySize
      ),
      storage: [
        VMConfigurationSpec.StorageDevice(
          path: definition.paths.diskImagePath,
          readOnly: false,
          controller: .virtioBlock
        ),
      ],
      network: [
        VMConfigurationSpec.NetworkDevice(
          macAddress: definition.network.macAddress,
          attachment: .nat
        ),
      ],
      graphics: [
        VMConfigurationSpec.GraphicsDevice(
          displays: [
            VMConfigurationSpec.Display(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80),
          ]
        ),
      ],
      audio: audio,
      pointing: pointing,
      keyboards: keyboards,
      validateSaveRestoreSupport: true
    )
  }

  private func platformPaths(for definition: VMDefinition) -> VMConfigurationSpec.PlatformPaths {
    VMConfigurationSpec.PlatformPaths(
      auxiliaryStoragePath: definition.paths.auxiliaryStoragePath,
      hardwareModelPath: definition.paths.hardwareModelPath,
      machineIdentifierPath: definition.paths.machineIdentifierPath
    )
  }
}
