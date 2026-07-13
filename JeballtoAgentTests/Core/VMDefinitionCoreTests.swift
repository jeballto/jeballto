import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct VMDefinitionCoreTests {
  @Test
  func expirySleepIntervalsRecheckLongWallClockDeadlines() {
    let now = Date(timeIntervalSince1970: 1000)

    #expect(VMManager.expirySleepInterval(expiresAt: now.addingTimeInterval(120), now: now) == 30)
    #expect(VMManager.expirySleepInterval(expiresAt: now.addingTimeInterval(5), now: now) == 5)
    #expect(VMManager.expirySleepInterval(expiresAt: now, now: now) == nil)
    #expect(VMManager.expirySleepInterval(expiresAt: now.addingTimeInterval(-1), now: now) == nil)
  }

  @Test(arguments: [
    VMResources(cpuCount: 1, memorySize: 2 * 1024 * 1024 * 1024, diskSize: 20 * 1024 * 1024 * 1024),
    VMResources.default,
    VMResources(cpuCount: 32, memorySize: 16 * 1024 * 1024 * 1024, diskSize: 256 * 1024 * 1024 * 1024),
  ])
  func validResourcesPassValidation(_ resources: VMResources) {
    #expect(resources.validate())
  }

  @Test(arguments: [
    VMResources(cpuCount: 0, memorySize: 4 * 1024 * 1024 * 1024, diskSize: 64 * 1024 * 1024 * 1024),
    VMResources(cpuCount: 33, memorySize: 4 * 1024 * 1024 * 1024, diskSize: 64 * 1024 * 1024 * 1024),
    VMResources(cpuCount: 4, memorySize: 1_073_741_824, diskSize: 64 * 1024 * 1024 * 1024),
    VMResources(cpuCount: 4, memorySize: 4 * 1024 * 1024 * 1024, diskSize: 10 * 1024 * 1024 * 1024),
  ])
  func invalidResourcesFailValidation(_ resources: VMResources) {
    #expect(resources.validate() == false)
  }

  @Test(arguments: ["vm-1", "vm_1", "vm one", "vm.one", "a", String(repeating: "a", count: 100)])
  func vmNameValidatorAcceptsValidValues(_ name: String) {
    #expect(VMNameValidator.validate(name))
  }

  @Test(arguments: ["", "   ", " vm", "vm ", "bad/name", "bad*name", String(repeating: "a", count: 101)])
  func vmNameValidatorRejectsInvalidValues(_ name: String) {
    #expect(VMNameValidator.validate(name) == false)
  }

  @Test
  func generatedMacAddressHasExpectedFormatAndBits() {
    let mac = VMNetwork.generateMACAddress()
    let octets = mac.split(separator: ":")
    let first = Int(octets[0], radix: 16) ?? -1

    #expect(VMNetwork(macAddress: mac).isValidMACAddress)
    #expect(octets.count == 6)
    #expect((first & 0x01) == 0)
    #expect((first & 0x02) == 0x02)
  }

  @Test
  func vmPathsUseProvidedBaseDirectory() {
    let id = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
    let paths = VMPaths.forVM(id: id, baseDir: "/tmp/custom-vms")

    #expect(paths.bundlePath == "/tmp/custom-vms/550E8400-E29B-41D4-A716-446655440000.bundle")
    #expect(paths.diskImagePath.hasSuffix("/Disk.img"))
    #expect(paths.auxiliaryStoragePath.hasSuffix("/AuxiliaryStorage"))
    #expect(paths.hardwareModelPath.hasSuffix("/HardwareModel"))
    #expect(paths.machineIdentifierPath.hasSuffix("/MachineIdentifier"))
    #expect(paths.saveFilePath.hasSuffix("/SaveFile.vzvmsave"))
  }

  @Test
  func vmDefinitionMutatorsUpdateNetworkAssignments() {
    let id = UUID()
    let initialDate = Date(timeIntervalSince1970: 1)
    var definition = VMDefinition(
      id: id,
      name: "mutable",
      state: .created,
      resources: .default,
      network: VMNetwork(macAddress: "02:00:00:00:00:01"),
      paths: VMPaths.forVM(id: id, baseDir: "/tmp/mutable"),
      createdAt: initialDate,
      updatedAt: initialDate
    )

    definition.updateSSHPort(2222)
    definition.updateVNCPort(5901)
    definition.updateNATIP("192.168.64.2")
    definition.clearVNCPort()
    definition.clearNATIP()
    definition.clearSSHPort()

    #expect(definition.network.sshPort == nil)
    #expect(definition.network.vncPort == nil)
    #expect(definition.network.natIP == nil)
    #expect(definition.updatedAt > initialDate)
  }

  @Test
  func vmDefinitionDefaultsEphemeralToFalse() {
    let id = UUID()
    let definition = VMDefinition(
      id: id,
      name: "normal-vm",
      resources: .default,
      paths: VMPaths.forVM(id: id, baseDir: "/tmp/test")
    )
    #expect(definition.ephemeral == false)
  }

  @Test
  func vmDefinitionStoresEphemeralFlag() {
    let id = UUID()
    let definition = VMDefinition(
      id: id,
      name: "ephemeral-vm",
      ephemeral: true,
      resources: .default,
      paths: VMPaths.forVM(id: id, baseDir: "/tmp/test")
    )
    #expect(definition.ephemeral == true)
  }

  @Test
  func vmPathsExistenceChecksReflectFilesystemState() async throws {
    try withTemporaryDirectory(prefix: "paths") { root in
      let id = UUID()
      let paths = VMPaths.forVM(id: id, baseDir: root)

      #expect(paths.bundleExists() == false)
      #expect(paths.allFilesExist() == false)

      try FileManager.default.createDirectory(
        atPath: paths.bundlePath,
        withIntermediateDirectories: true
      )
      try Data().write(to: URL(fileURLWithPath: paths.diskImagePath))
      try Data().write(to: URL(fileURLWithPath: paths.auxiliaryStoragePath))
      try Data().write(to: URL(fileURLWithPath: paths.hardwareModelPath))
      try Data().write(to: URL(fileURLWithPath: paths.machineIdentifierPath))

      #expect(paths.bundleExists())
      #expect(paths.allFilesExist())
    }
  }
}
