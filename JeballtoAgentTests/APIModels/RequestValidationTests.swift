import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiModels))
struct RequestValidationTests {
  @Test
  func createVMRequestAcceptsNameWithSpacesBecauseValidatorAllowsIt() {
    let request = CreateVMRequest(name: "dev vm", resources: nil, image: nil)
    let validation = request.validate()

    #expect(validation.valid)
    #expect(validation.error == nil)
  }

  @Test
  func createVMRequestRejectsInvalidImageReference() {
    let request = CreateVMRequest(name: "dev-vm", resources: nil, image: "invalid image")
    let validation = request.validate()

    #expect(validation.valid == false)
    #expect(validation.error?.contains("Invalid image reference") == true)
  }

  @Test
  func cloneVMRequestRejectsInvalidName() {
    let request = CloneVMRequest(name: "", resources: nil)
    let validation = request.validate()

    #expect(validation.valid == false)
  }

  @Test(arguments: [
    InstallVMRequest(source: nil),
    InstallVMRequest(source: "https://example.com/file.ipsw"),
    InstallVMRequest(source: "file:///tmp/file.ipsw"),
    InstallVMRequest(source: "/tmp/file.ipsw"),
  ])
  func installVMRequestAcceptsSupportedSources(_ request: InstallVMRequest) {
    #expect(request.validate().valid)
  }

  @Test(arguments: [
    InstallVMRequest(source: "http://example.com/file.ipsw"),
    InstallVMRequest(source: "file://relative/path.ipsw"),
    InstallVMRequest(source: "relative/path.ipsw"),
  ])
  func installVMRequestRejectsUnsupportedSources(_ request: InstallVMRequest) {
    #expect(request.validate().valid == false)
  }

  @Test
  func installVMRequestNormalizesFileScheme() {
    let fromFile = InstallVMRequest(source: "file:///tmp/test.ipsw")
    let fromHttps = InstallVMRequest(source: "https://example.com/test.ipsw")

    #expect(fromFile.effectiveIPSWSource == "/tmp/test.ipsw")
    #expect(fromHttps.effectiveIPSWSource == "https://example.com/test.ipsw")
  }

  @Test
  func commandExecuteRequestValidation() {
    let valid = CommandExecuteRequest(command: "echo hello", user: nil, password: nil, timeout: 60)
    let timeoutZero = CommandExecuteRequest(command: "echo", user: nil, password: nil, timeout: 0)
    let timeoutTooHigh = CommandExecuteRequest(command: "echo", user: nil, password: nil, timeout: 601)
    let emptyCommand = CommandExecuteRequest(command: "", user: nil, password: nil, timeout: nil)

    #expect(valid.validate().valid)
    #expect(timeoutZero.validate().valid == false)
    #expect(timeoutTooHigh.validate().valid == false)
    #expect(emptyCommand.validate().valid == false)
    #expect(valid.effectiveUser == "admin")
    #expect(valid.effectivePassword == "admin")
    #expect(valid.effectiveTimeout == 60)
  }

  @Test
  func commandExecuteRejectsOverlongCommand() {
    let command = String(repeating: "a", count: CommandExecutor.maxCommandLength + 1)
    let request = CommandExecuteRequest(command: command, user: nil, password: nil, timeout: nil)

    #expect(request.validate().valid == false)
  }

  @Test
  func keystrokesRequestValidation() {
    #expect(KeystrokesRequest(keystrokes: ["a", "<enter>"]).validate().valid)
    #expect(KeystrokesRequest(keystrokes: []).validate().valid == false)

    let veryLong = String(repeating: "a", count: 10001)
    #expect(KeystrokesRequest(keystrokes: [veryLong]).validate().valid == false)
  }

  @Test
  func pullImageRequestValidation() {
    let valid = PullImageRequest(reference: "registry.example.com/vm/macos:latest", timeout: 10)
    let invalidRef = PullImageRequest(reference: "not valid", timeout: 10)
    let invalidTimeout = PullImageRequest(reference: "registry.example.com/vm/macos:latest", timeout: 0)

    #expect(valid.validate().valid)
    #expect(invalidRef.validate().valid == false)
    #expect(invalidTimeout.validate().valid == false)
  }

  @Test
  func pushImageRequestValidationAndSourceParsing() {
    let id = UUID().uuidString
    let vmSource = "vm:\(id)"
    let imageSource = "image:\(id)"

    let vmRequest = PushImageRequest(reference: "registry.example.com/vm/macos:latest", source: vmSource, timeout: 10)
    let imageRequest = PushImageRequest(
      reference: "registry.example.com/vm/macos:latest",
      source: imageSource,
      timeout: nil
    )
    let invalidSource = PushImageRequest(
      reference: "registry.example.com/vm/macos:latest",
      source: "bad:\(id)",
      timeout: nil
    )

    #expect(vmRequest.validate().valid)
    #expect(imageRequest.validate().valid)
    #expect(invalidSource.validate().valid == false)

    #expect(vmRequest.parseSource()?.type == .vm)
    #expect(imageRequest.parseSource()?.type == .image)
    #expect(PushImageRequest(reference: "x", source: nil, timeout: nil).parseSource() == nil)
  }

  @Test
  func registryRequestValidation() {
    let loginValid = RegistryLoginRequest(registry: "registry.example.com:5000", username: "u", password: "p")
    let loginInvalidHost = RegistryLoginRequest(registry: "bad host", username: "u", password: "p")
    let logoutValid = RegistryLogoutRequest(registry: "registry.example.com")
    let logoutInvalid = RegistryLogoutRequest(registry: "")

    #expect(loginValid.validate().valid)
    #expect(loginInvalidHost.validate().valid == false)
    #expect(logoutValid.validate().valid)
    #expect(logoutInvalid.validate().valid == false)
  }

  @Test
  func updateConfigImageParallelismValidation() throws {
    let validJSON = """
    {"images":{
      "maxParallelImageBlobTransfers":16,
      "maxParallelImageDecompressions":2,
      "maxParallelImageDiskWrites":1
    }}
    """
    let zeroJSON = #"{"images":{"maxParallelImageBlobTransfers":0}}"#
    let tooHighJSONs = [
      #"{"images":{"maxParallelImageBlobTransfers":65}}"#,
      #"{"images":{"maxParallelImageDecompressions":9}}"#,
      #"{"images":{"maxParallelImageDiskWrites":5}}"#,
    ]

    let valid = try JSONDecoder().decode(UpdateConfigRequest.self, from: Data(validJSON.utf8))
    let zero = try JSONDecoder().decode(UpdateConfigRequest.self, from: Data(zeroJSON.utf8))

    #expect(valid.validate().valid)
    #expect(zero.validate().valid == false)
    for tooHighJSON in tooHighJSONs {
      let tooHigh = try JSONDecoder().decode(UpdateConfigRequest.self, from: Data(tooHighJSON.utf8))
      #expect(tooHigh.validate().valid == false)
    }
  }

  @Test
  func configResponseIncludesImageParallelismSettings() {
    var config = Config.default
    config.images.maxParallelImageBlobTransfers = 16
    config.images.maxParallelImageDecompressions = 2
    config.images.maxParallelImageDiskWrites = 1

    let response = ConfigResponse(from: config)

    #expect(response.images.maxParallelImageBlobTransfers == 16)
    #expect(response.images.maxParallelImageDecompressions == 2)
    #expect(response.images.maxParallelImageDiskWrites == 1)
  }

  @Test
  func updateConfigRequestValidation() {
    let valid = UpdateConfigRequest(
      logging: LoggingConfigUpdate(level: "info", retentionDays: 7, maxTotalSize: "2GB", timezone: "Europe/Warsaw"),
      networking: NetworkingConfigUpdate(
        sshPortRangeStart: 2222, sshPortRangeEnd: 2223, autoEnableSSHForwarding: nil,
        vncPortRangeStart: nil, vncPortRangeEnd: nil
      ),
      images: nil
    )
    let invalidLevel = UpdateConfigRequest(
      logging: LoggingConfigUpdate(level: "trace", retentionDays: nil, maxTotalSize: nil, timezone: "Europe/Warsaw"),
      networking: nil,
      images: nil
    )
    let invalidTimezone = UpdateConfigRequest(
      logging: LoggingConfigUpdate(level: "trace", retentionDays: nil, maxTotalSize: nil, timezone: "U1"),
      networking: nil,
      images: nil
    )
    let invalidRetention = UpdateConfigRequest(
      logging: LoggingConfigUpdate(level: nil, retentionDays: 0, maxTotalSize: nil, timezone: "UTC"),
      networking: nil,
      images: nil
    )
    let invalidSize = UpdateConfigRequest(
      logging: LoggingConfigUpdate(level: nil, retentionDays: nil, maxTotalSize: "2KB", timezone: "UTC"),
      networking: nil,
      images: nil
    )
    let invalidPortRange = UpdateConfigRequest(
      logging: nil,
      networking: NetworkingConfigUpdate(
        sshPortRangeStart: 3000, sshPortRangeEnd: 2000, autoEnableSSHForwarding: nil,
        vncPortRangeStart: nil, vncPortRangeEnd: nil
      ),
      images: nil
    )

    #expect(valid.validate().valid)
    #expect(invalidLevel.validate().valid == false)
    #expect(invalidTimezone.validate().valid == false)
    #expect(invalidRetention.validate().valid == false)
    #expect(invalidSize.validate().valid == false)
    #expect(invalidPortRange.validate().valid == false)
  }

  @Test
  func updateConfigRejectsPartialPortRangeThatInvertsRange() {
    let currentConfig = NetworkingConfig(
      sshPortRangeStart: 2222,
      sshPortRangeEnd: 2223
    )

    // Only start provided, higher than current end - should fail
    let startOnly = UpdateConfigRequest(
      logging: nil,
      networking: NetworkingConfigUpdate(
        sshPortRangeStart: 3000, sshPortRangeEnd: nil, autoEnableSSHForwarding: nil,
        vncPortRangeStart: nil, vncPortRangeEnd: nil
      ),
      images: nil
    )
    #expect(startOnly.validate(currentConfig: currentConfig).valid == false)

    // Only end provided, lower than current start - should fail
    let endOnly = UpdateConfigRequest(
      logging: nil,
      networking: NetworkingConfigUpdate(
        sshPortRangeStart: nil, sshPortRangeEnd: 2000, autoEnableSSHForwarding: nil,
        vncPortRangeStart: nil, vncPortRangeEnd: nil
      ),
      images: nil
    )
    #expect(endOnly.validate(currentConfig: currentConfig).valid == false)

    // Only start provided, within current range - should pass
    let validStart = UpdateConfigRequest(
      logging: nil,
      networking: NetworkingConfigUpdate(
        sshPortRangeStart: 2220, sshPortRangeEnd: nil, autoEnableSSHForwarding: nil,
        vncPortRangeStart: nil, vncPortRangeEnd: nil
      ),
      images: nil
    )
    #expect(validStart.validate(currentConfig: currentConfig).valid)
  }

  @Test
  func updateConfigRejectsPartialVNCPortRangeThatInvertsRange() {
    let currentConfig = NetworkingConfig(
      sshPortRangeStart: 2222,
      sshPortRangeEnd: 2223,
      vncPortRangeStart: 5901,
      vncPortRangeEnd: 5902
    )

    let vncStartTooHigh = UpdateConfigRequest(
      logging: nil,
      networking: NetworkingConfigUpdate(
        sshPortRangeStart: nil, sshPortRangeEnd: nil, autoEnableSSHForwarding: nil,
        vncPortRangeStart: 6000, vncPortRangeEnd: nil
      ),
      images: nil
    )
    #expect(vncStartTooHigh.validate(currentConfig: currentConfig).valid == false)

    let vncEndTooLow = UpdateConfigRequest(
      logging: nil,
      networking: NetworkingConfigUpdate(
        sshPortRangeStart: nil, sshPortRangeEnd: nil, autoEnableSSHForwarding: nil,
        vncPortRangeStart: nil, vncPortRangeEnd: 5000
      ),
      images: nil
    )
    #expect(vncEndTooLow.validate(currentConfig: currentConfig).valid == false)

    let vncInvalidPort = UpdateConfigRequest(
      logging: nil,
      networking: NetworkingConfigUpdate(
        sshPortRangeStart: nil, sshPortRangeEnd: nil, autoEnableSSHForwarding: nil,
        vncPortRangeStart: 80, vncPortRangeEnd: nil
      ),
      images: nil
    )
    #expect(vncInvalidPort.validate(currentConfig: currentConfig).valid == false)
  }

  @Test
  func systemResetRequestValidation() {
    #expect(SystemResetRequest(mode: "soft").validate().valid)
    #expect(SystemResetRequest(mode: "hard").validate().valid)
    #expect(SystemResetRequest(mode: "nuke").validate().valid == false)
  }

  @Test
  func createVMRequestDecodesEphemeralFlag() throws {
    let json = Data(#"{"name": "ci-vm", "ephemeral": true}"#.utf8)
    let request = try JSONDecoder().decode(CreateVMRequest.self, from: json)

    #expect(request.ephemeral == true)
    #expect(request.validate().valid)
  }

  @Test
  func createVMRequestDefaultsEphemeralToNilWhenOmitted() throws {
    let json = Data(#"{"name": "normal-vm"}"#.utf8)
    let request = try JSONDecoder().decode(CreateVMRequest.self, from: json)

    #expect(request.ephemeral == nil)
  }

  @Test
  func cloneVMRequestDecodesEphemeralFlag() throws {
    let json = Data(#"{"name": "cloned-vm", "ephemeral": true}"#.utf8)
    let request = try JSONDecoder().decode(CloneVMRequest.self, from: json)

    #expect(request.ephemeral == true)
  }

  @Test
  func vmResponseIncludesEphemeralField() {
    let id = UUID()
    let definition = VMDefinition(
      id: id,
      name: "ephemeral-vm",
      state: .running,
      ephemeral: true,
      resources: .default,
      paths: VMPaths.forVM(id: id, baseDir: "/tmp/test")
    )
    let response = VMResponse(from: definition)

    #expect(response.ephemeral == true)
  }

  @Test
  func vmResponseEphemeralDefaultsFalse() {
    let id = UUID()
    let definition = VMDefinition(
      id: id,
      name: "normal-vm",
      resources: .default,
      paths: VMPaths.forVM(id: id, baseDir: "/tmp/test")
    )
    let response = VMResponse(from: definition)

    #expect(response.ephemeral == false)
  }

  // MARK: - UpdateVMRequest

  @Test
  func updateVMRequestRejectsEmptyBody() throws {
    let json = Data(#"{}"#.utf8)
    let request = try JSONDecoder().decode(UpdateVMRequest.self, from: json)

    #expect(request.validate().valid == false)
    #expect(request.validate().error?.contains("At least one") == true)
  }

  @Test
  func updateVMRequestAcceptsNameOnly() throws {
    let json = Data(#"{"name": "new-name"}"#.utf8)
    let request = try JSONDecoder().decode(UpdateVMRequest.self, from: json)

    #expect(request.validate().valid)
    #expect(request.name == "new-name")
    #expect(request.resources == nil)
  }

  @Test
  func updateVMRequestRejectsInvalidName() throws {
    let json = Data(#"{"name": ""}"#.utf8)
    let request = try JSONDecoder().decode(UpdateVMRequest.self, from: json)

    #expect(request.validate().valid == false)
  }

  @Test
  func updateVMRequestAcceptsResourcesOnly() throws {
    let json = Data(#"{"resources": {"cpuCount": 8}}"#.utf8)
    let request = try JSONDecoder().decode(UpdateVMRequest.self, from: json)

    #expect(request.validate().valid)
    #expect(request.name == nil)
    #expect(request.resources?.cpuCount == 8)
  }

  @Test
  func updateVMRequestAcceptsStringMemorySize() throws {
    let json = Data(#"{"resources": {"memorySize": "16GB"}}"#.utf8)
    let request = try JSONDecoder().decode(UpdateVMRequest.self, from: json)

    #expect(request.validate().valid)
    #expect(request.resources?.memorySize?.bytes == UInt64(16) * 1024 * 1024 * 1024)
  }

  @Test
  func updateVMRequestRejectsInvalidCPU() throws {
    let tooLow = Data(#"{"resources": {"cpuCount": 0}}"#.utf8)
    let tooHigh = Data(#"{"resources": {"cpuCount": 33}}"#.utf8)
    let requestLow = try JSONDecoder().decode(UpdateVMRequest.self, from: tooLow)
    let requestHigh = try JSONDecoder().decode(UpdateVMRequest.self, from: tooHigh)

    #expect(requestLow.validate().valid == false)
    #expect(requestHigh.validate().valid == false)
  }

  @Test
  func updateVMRequestRejectsSmallMemory() throws {
    let json = Data(#"{"resources": {"memorySize": "1GB"}}"#.utf8)
    let request = try JSONDecoder().decode(UpdateVMRequest.self, from: json)

    #expect(request.validate().valid == false)
    #expect(request.validate().error?.contains("Memory") == true)
  }

  @Test
  func updateVMRequestRejectsSmallDisk() throws {
    let json = Data(#"{"resources": {"diskSize": "10GB"}}"#.utf8)
    let request = try JSONDecoder().decode(UpdateVMRequest.self, from: json)

    #expect(request.validate().valid == false)
    #expect(request.validate().error?.contains("Disk") == true)
  }

  @Test
  func updateVMRequestRejectsOversizedMemory() throws {
    let json = Data(#"{"resources": {"memorySize": "256GB"}}"#.utf8)
    let request = try JSONDecoder().decode(UpdateVMRequest.self, from: json)

    #expect(request.validate().valid == false)
    #expect(request.validate().error?.contains("128GB") == true)
  }

  @Test
  func updateVMRequestAcceptsMemoryAtUpperBound() throws {
    let json = Data(#"{"resources": {"memorySize": "128GB"}}"#.utf8)
    let request = try JSONDecoder().decode(UpdateVMRequest.self, from: json)

    #expect(request.validate().valid)
  }

  @Test
  func updateVMRequestRejectsOversizedDisk() throws {
    let json = Data(#"{"resources": {"diskSize": "9TB"}}"#.utf8)
    let request = try JSONDecoder().decode(UpdateVMRequest.self, from: json)

    #expect(request.validate().valid == false)
    #expect(request.validate().error?.contains("8TB") == true)
  }

  @Test
  func updateVMRequestAcceptsDiskAtUpperBound() throws {
    let json = Data(#"{"resources": {"diskSize": "8TB"}}"#.utf8)
    let request = try JSONDecoder().decode(UpdateVMRequest.self, from: json)

    #expect(request.validate().valid)
  }

  @Test
  func updateVMRequestAcceptsNameAndResources() throws {
    let json = Data(#"{"name": "updated-vm", "resources": {"cpuCount": 8, "memorySize": "16GB"}}"#.utf8)
    let request = try JSONDecoder().decode(UpdateVMRequest.self, from: json)

    #expect(request.validate().valid)
    #expect(request.name == "updated-vm")
    #expect(request.resources?.cpuCount == 8)
    #expect(request.resources?.memorySize?.bytes == UInt64(16) * 1024 * 1024 * 1024)
  }

  @Test
  func updateVMRequestRejectsEmptyResourcesWithNoName() throws {
    let json = Data(#"{"resources": {}}"#.utf8)
    let request = try JSONDecoder().decode(UpdateVMRequest.self, from: json)

    #expect(request.validate().valid == false)
  }

  // MARK: - VMResourcesResponse formatting

  @Test
  func vmResourcesResponseFormatsWholeGB() {
    let resources = VMResources(
      cpuCount: 4,
      memorySize: 8 * 1024 * 1024 * 1024,
      diskSize: 64 * 1024 * 1024 * 1024
    )
    let response = VMResourcesResponse(from: resources)

    #expect(response.memorySize == "8GB")
    #expect(response.diskSize == "64GB")
    #expect(response.cpuCount == 4)
  }

  @Test
  func vmResourcesResponseFormatsFractionalGB() {
    let resources = VMResources(
      cpuCount: 2,
      memorySize: UInt64(4.5 * 1024 * 1024 * 1024),
      diskSize: UInt64(32.5 * 1024 * 1024 * 1024)
    )
    let response = VMResourcesResponse(from: resources)

    #expect(response.memorySize == "4.5GB")
    #expect(response.diskSize == "32.5GB")
  }

  @Test
  func vmResourcesResponseUsesCorrectJSONKeys() throws {
    let resources = VMResources(
      cpuCount: 4,
      memorySize: 4 * 1024 * 1024 * 1024,
      diskSize: 64 * 1024 * 1024 * 1024
    )
    let response = VMResourcesResponse(from: resources)
    let data = try JSONEncoder().encode(response)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    // Verify new key names are used (not memoryGB/diskGB)
    #expect(json?["memorySize"] as? String == "4GB")
    #expect(json?["diskSize"] as? String == "64GB")
    #expect(json?["cpuCount"] as? Int == 4)
    #expect(json?["memoryGB"] == nil)
    #expect(json?["diskGB"] == nil)
  }

  @Test
  func updateConfigAcceptsValidTimezone() {
    let request = UpdateConfigRequest(
      logging: LoggingConfigUpdate(level: nil, retentionDays: nil, maxTotalSize: nil, timezone: "UTC"),
      networking: nil,
      images: nil
    )
    #expect(request.validate().valid)
  }

  @Test
  func updateConfigAcceptsNilTimezone() {
    let request = UpdateConfigRequest(
      logging: LoggingConfigUpdate(level: nil, retentionDays: nil, maxTotalSize: nil, timezone: nil),
      networking: nil,
      images: nil
    )
    #expect(request.validate().valid)
  }

  @Test
  func createVMRequestRejectsResourcesWithImage() {
    let resources = VMResourcesDTO(cpuCount: 4, memorySize: nil, diskSize: nil)
    let request = CreateVMRequest(name: "from-image", resources: resources, image: "registry.example.com/vms/m:latest")

    let validation = request.validate()
    #expect(validation.valid == false)
    #expect(validation.error?.contains("resources cannot be set") == true)
  }

  @Test
  func createVMRequestAcceptsImageWithoutResources() {
    let request = CreateVMRequest(name: "from-image", resources: nil, image: "registry.example.com/vms/m:latest")
    #expect(request.validate().valid)
  }

  @Test
  func createVMRequestRejectsLifetimeOutOfRange() {
    let negative = CreateVMRequest(name: "v", resources: nil, image: nil, lifetimeSeconds: 0)
    let tooBig = CreateVMRequest(name: "v", resources: nil, image: nil, lifetimeSeconds: 604_801)
    let ok = CreateVMRequest(name: "v", resources: nil, image: nil, lifetimeSeconds: 3600)

    #expect(negative.validate().valid == false)
    #expect(tooBig.validate().valid == false)
    #expect(ok.validate().valid)
  }

  @Test
  func createVMRequestDecodesLifetimeSeconds() throws {
    let json = Data(#"{"name": "ci", "lifetimeSeconds": 1800}"#.utf8)
    let request = try JSONDecoder().decode(CreateVMRequest.self, from: json)
    #expect(request.lifetimeSeconds == 1800)
    #expect(request.validate().valid)
  }

  @Test
  func vmResponseIncludesLifetimeAndExpiry() {
    let id = UUID()
    let expiry = Date(timeIntervalSince1970: 1_700_000_000)
    let definition = VMDefinition(
      id: id,
      name: "ttl-vm",
      resources: .default,
      paths: VMPaths.forVM(id: id, baseDir: "/tmp/test"),
      lifetimeSeconds: 3600,
      expiresAt: expiry
    )
    let response = VMResponse(from: definition)

    #expect(response.lifetimeSeconds == 3600)
    #expect(response.expiresAt != nil)
  }

  @Test
  func vmDefinitionDecodesLegacyJSONWithoutLifetimeFields() throws {
    let id = UUID()
    let json = Data(#"""
    {
      "id": "\#(id.uuidString)",
      "name": "legacy",
      "state": "stopped",
      "ephemeral": false,
      "resources": {"cpuCount": 4, "memorySize": 4294967296, "diskSize": 21474836480},
      "network": {"macAddress": "02:00:00:00:00:01"},
      "paths": {
        "bundlePath": "/tmp/x.bundle",
        "diskImagePath": "/tmp/x.bundle/Disk.img",
        "auxiliaryStoragePath": "/tmp/x.bundle/AuxiliaryStorage",
        "hardwareModelPath": "/tmp/x.bundle/HardwareModel",
        "machineIdentifierPath": "/tmp/x.bundle/MachineIdentifier"
      },
      "metadata": {},
      "createdAt": "2024-01-01T00:00:00Z",
      "updatedAt": "2024-01-01T00:00:00Z"
    }
    """#.utf8)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let definition = try decoder.decode(VMDefinition.self, from: json)

    #expect(definition.lifetimeSeconds == nil)
    #expect(definition.expiresAt == nil)
  }

  @Test
  func updateConfigRejectsInvalidTimezone() {
    let request = UpdateConfigRequest(
      logging: LoggingConfigUpdate(level: nil, retentionDays: nil, maxTotalSize: nil, timezone: "NotATimezone"),
      networking: nil,
      images: nil
    )
    let result = request.validate()
    #expect(result.valid == false)
    #expect(result.error?.contains("timezone") == true)
  }
}
