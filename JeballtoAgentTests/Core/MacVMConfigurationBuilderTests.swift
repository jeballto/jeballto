import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct MacVMConfigurationBuilderTests {
  @Test
  func assemblerRejectsOversizedPlatformIdentityBeforeDecodingIt() throws {
    try withTemporaryDirectory(prefix: "avf-platform-identity") { root in
      let id = UUID()
      let paths = VMPaths.forVM(id: id, baseDir: root)
      try FileManager.default.createDirectory(atPath: paths.bundlePath, withIntermediateDirectories: true)
      try Data(repeating: 0, count: 1_048_577)
        .write(to: URL(fileURLWithPath: paths.hardwareModelPath))
      let definition = VMDefinition(
        id: id,
        name: "oversized-platform",
        state: .stopped,
        resources: .default,
        network: VMNetwork(macAddress: "02:00:00:00:00:01"),
        paths: paths
      )

      #expect(throws: AVFError.self) {
        _ = try AVFConfigurationAssembler().createConfiguration(
          from: MacVMConfigurationBuilder().makeRuntimeSpec(for: definition)
        )
      }
    }
  }

  @Test
  func runtimeSpecPreservesCurrentStableDefaults() {
    let definition = makeDefinition()
    let spec = MacVMConfigurationBuilder().makeRuntimeSpec(for: definition)

    #expect(spec.platform == .existing(platformPaths(for: definition)))
    #expect(spec.resources.cpuCount == definition.resources.cpuCount)
    #expect(spec.resources.memorySize == definition.resources.memorySize)
    #expect(spec.storage == [
      VMConfigurationSpec.StorageDevice(
        path: definition.paths.diskImagePath,
        readOnly: false,
        controller: .virtioBlock
      ),
    ])
    #expect(spec.network == [
      VMConfigurationSpec.NetworkDevice(macAddress: definition.network.macAddress, attachment: .nat),
    ])
    #expect(spec.graphics.first?.displays == [
      VMConfigurationSpec.Display(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80),
    ])
    #expect(spec.audio == [VMConfigurationSpec.AudioDevice(inputEnabled: true, outputEnabled: true)])
    #expect(spec.pointing == [.macTrackpad])
    #expect(spec.keyboards == [.macKeyboard])
    #expect(spec.validateSaveRestoreSupport)
  }

  @Test
  func installationSpecPreservesCurrentInstallerDefaults() {
    let definition = makeDefinition()
    let spec = MacVMConfigurationBuilder().makeInstallationSpec(for: definition)

    #expect(spec.platform == .installation(platformPaths(for: definition)))
    #expect(spec.storage.first?.path == definition.paths.diskImagePath)
    #expect(spec.network.first?.attachment == .nat)
    #expect(spec.audio == [VMConfigurationSpec.AudioDevice(inputEnabled: false, outputEnabled: true)])
    #expect(spec.pointing == [.usbScreenCoordinate])
    #expect(spec.keyboards == [.usbKeyboard])
    #expect(spec.validateSaveRestoreSupport)
  }

  private func makeDefinition() -> VMDefinition {
    let id = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    return VMDefinition(
      id: id,
      name: "builder-vm",
      resources: VMResources(
        cpuCount: 6,
        memorySize: 8 * 1024 * 1024 * 1024,
        diskSize: 80 * 1024 * 1024 * 1024
      ),
      network: VMNetwork(macAddress: "02:00:00:00:00:01"),
      paths: VMPaths.forVM(id: id, baseDir: "/tmp/builder")
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
