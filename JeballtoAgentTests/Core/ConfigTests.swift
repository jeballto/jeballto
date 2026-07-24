import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct ConfigTests {
  @Test(arguments: [
    ("1MB", 1_048_576),
    ("2GB", 2_147_483_648),
    (" 3gb ", 3_221_225_472),
  ])
  func loggingSizeParserAcceptsSupportedValues(_ input: (String, Int)) {
    #expect(LoggingConfig.parseSize(input.0) == input.1)
  }

  @Test(arguments: ["", "100", "2TB", "abcMB"])
  func loggingSizeParserRejectsInvalidValues(_ value: String) {
    #expect(LoggingConfig.parseSize(value) == nil)
  }

  @Test
  func loggingSizeParserRejectsNegativeUnits() {
    #expect(LoggingConfig.parseSize("-1GB") == nil)
  }

  @Test
  func loggingSizeParserRejectsOverflowingUnits() {
    #expect(LoggingConfig.parseSize("999999999999GB") == nil)
  }

  @Test
  func configRoundTripsThroughDisk() throws {
    try withTemporaryDirectory(prefix: "config") { root in
      let path = "\(root)/config.json"
      var config = Config.default
      config.api.port = 19090
      config.logging.level = "debug"
      config.images.maxParallelImageBlobTransfers = 12
      config.images.maxParallelImageCompressions = 4
      config.images.maxParallelImageDecompressions = 3
      config.images.maxParallelImageDiskWrites = 2

      try config.save(to: path)
      let loaded = try Config.load(from: path)

      #expect(loaded.api.port == 19090)
      #expect(loaded.logging.level == "debug")
      #expect(loaded.images.maxParallelImageBlobTransfers == 12)
      #expect(loaded.images.maxParallelImageCompressions == 4)
      #expect(loaded.images.maxParallelImageDecompressions == 3)
      #expect(loaded.images.maxParallelImageDiskWrites == 2)
    }
  }

  @Test
  func imageConfigDecodesMissingParallelismAsDefaults() throws {
    let json = """
    {
      "api": {
        "port": 8011,
        "host": "127.0.0.1",
        "token": "test-token",
        "enableHTTPS": false,
        "maxConcurrentRequests": 100
      },
      "storage": {
        "vmStorageDir": "/tmp/vms",
        "databasePath": "/tmp/vms.json",
        "imageIndexPath": "/tmp/images.json"
      },
      "logging": {
        "level": "info",
        "enableFileLogging": true,
        "logDirectory": "/tmp/logs",
        "retentionDays": 7,
        "maxTotalSize": "2GB",
        "timezone": null
      },
      "networking": {
        "sshPortRangeStart": 2222,
        "sshPortRangeEnd": 2223,
        "autoEnableSSHForwarding": true,
        "vncPortRangeStart": 5901,
        "vncPortRangeEnd": 5902
      },
      "images": {
        "imageStorageDir": "/tmp/images",
        "orasPath": null,
        "zstdPath": null,
        "defaultRegistry": null,
        "insecureRegistries": []
      }
    }
    """

    let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))

    #expect(config.images.maxParallelImageBlobTransfers == 16)
    #expect(config.images.maxParallelImageCompressions == 4)
    #expect(config.images.maxParallelImageDecompressions == 2)
    #expect(config.images.maxParallelImageDiskWrites == 1)
  }

  @Test(arguments: [
    #""maxParallelImageBlobTransfers": 0"#,
    #""maxParallelImageBlobTransfers": 65"#,
    #""maxParallelImageCompressions": 0"#,
    #""maxParallelImageCompressions": 33"#,
    #""maxParallelImageDecompressions": 0"#,
    #""maxParallelImageDecompressions": 9"#,
    #""maxParallelImageDiskWrites": 0"#,
    #""maxParallelImageDiskWrites": 5"#,
  ])
  func imageConfigRejectsParallelismOutsideRange(parallelismJSON: String) {
    let json = """
    {
      "imageStorageDir": "/tmp/images",
      "orasPath": null,
      "zstdPath": null,
      "defaultRegistry": null,
      "insecureRegistries": [],
      \(parallelismJSON)
    }
    """

    #expect(throws: ConfigError.self) {
      _ = try JSONDecoder().decode(ImageConfig.self, from: Data(json.utf8))
    }
  }

  @Test
  func loggingConfigRoundTripsTimezone() throws {
    try withTemporaryDirectory(prefix: "config") { root in
      let path = "\(root)/config.json"
      var config = Config.default
      config.logging.timezone = "UTC"

      try config.save(to: path)
      let loaded = try Config.load(from: path)

      #expect(loaded.logging.timezone == "UTC")
    }
  }

  @Test
  func loggingConfigNilTimezoneRoundTrips() throws {
    try withTemporaryDirectory(prefix: "config") { root in
      let path = "\(root)/config.json"
      var config = Config.default
      config.logging.timezone = nil

      try config.save(to: path)
      let loaded = try Config.load(from: path)

      #expect(loaded.logging.timezone == nil)
    }
  }

  @Test
  func configLoadRejectsInvalidRuntimeValues() throws {
    try withTemporaryDirectory(prefix: "config-invalid") { root in
      let path = "\(root)/config.json"
      var config = Config.default
      config.api.maxConcurrentRequests = 0
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(config).write(to: URL(fileURLWithPath: path))

      #expect(throws: ConfigError.self) {
        _ = try Config.load(from: path)
      }
    }
  }

  @Test
  func configLoadRejectsOversizedFilesBeforeDecoding() throws {
    try withTemporaryDirectory(prefix: "config-oversized") { root in
      let path = "\(root)/config.json"
      try Data(repeating: 0x20, count: Config.maximumConfigSize + 1)
        .write(to: URL(fileURLWithPath: path))

      #expect(throws: ConfigError.self) {
        _ = try Config.load(from: path)
      }
    }
  }

  @Test
  func configSaveRefusesSymbolicLinkWithoutChangingItsTarget() throws {
    try withTemporaryDirectory(prefix: "config-symlink-target") { root in
      let target = "\(root)/target.json"
      let path = "\(root)/config.json"
      let original = Data("preserve me".utf8)
      try original.write(to: URL(fileURLWithPath: target))
      try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

      #expect(throws: ConfigError.self) {
        try Config.default.save(to: path)
      }
      #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == original)
    }
  }

  @Test
  func configSaveRefusesSymbolicLinkDirectoryWithoutCreatingAFileInItsTarget() throws {
    try withTemporaryDirectory(prefix: "config-directory-symlink") { root in
      let targetDirectory = "\(root)/target"
      let linkedDirectory = "\(root)/configuration"
      try FileManager.default.createDirectory(atPath: targetDirectory, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(atPath: linkedDirectory, withDestinationPath: targetDirectory)

      #expect(throws: ConfigError.self) {
        try Config.default.save(to: "\(linkedDirectory)/config.json")
      }
      #expect(throws: ConfigError.self) {
        _ = try Config.load(from: "\(linkedDirectory)/config.json")
      }
      #expect(FileManager.default.fileExists(atPath: "\(targetDirectory)/config.json") == false)
    }
  }

  @Test
  func networkingConfigRejectsOverlappingForwardingRanges() {
    let config = NetworkingConfig(
      sshPortRangeStart: 2200,
      sshPortRangeEnd: 2300,
      vncPortRangeStart: 2300,
      vncPortRangeEnd: 2400
    )

    #expect(throws: ConfigError.self) {
      try config.validate()
    }
  }

  @Test
  func configRejectsAPIAndForwardingPortOverlap() {
    var config = Config.default
    config.api.port = config.networking.sshPortRangeStart

    #expect(throws: ConfigError.self) {
      try config.validate()
    }
  }

  @Test
  func configRejectsOverlappingVMAndImageStorage() {
    var config = Config.default
    config.images.imageStorageDir = config.storage.vmStorageDir + "/Images"

    #expect(throws: ConfigError.self) {
      try config.validate()
    }
  }

  @Test
  func configRejectsLoggingInsideManagedStorage() {
    var config = Config.default
    config.logging.logDirectory = config.storage.vmStorageDir + "/Logs"

    #expect(throws: ConfigError.self) {
      try config.validate()
    }
  }

  @Test
  func configRejectsStorageOverlapThroughASymbolicLink() throws {
    try withTemporaryDirectory(prefix: "config-symlink") { root in
      let vmStorage = "\(root)/vms"
      let imageStorage = "\(root)/images-link"
      try FileManager.default.createDirectory(atPath: vmStorage, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(atPath: imageStorage, withDestinationPath: vmStorage)
      var config = Config.default
      config.storage.vmStorageDir = vmStorage
      config.images.imageStorageDir = imageStorage

      #expect(throws: ConfigError.self) {
        try config.validate()
      }
    }
  }

  @Test
  func configRejectsSharedDatabaseAndImageIndex() {
    var config = Config.default
    config.storage.imageIndexPath = config.storage.databasePath

    #expect(throws: ConfigError.self) {
      try config.validate()
    }
  }

  @Test
  func configRejectsPrimaryAndBackupStorePathCollisions() {
    var imageIndexAtVMBackup = Config.default
    imageIndexAtVMBackup.storage.imageIndexPath = imageIndexAtVMBackup.storage.databasePath + ".bak"
    var databaseAtImageBackup = Config.default
    databaseAtImageBackup.storage.databasePath = databaseAtImageBackup.storage.imageIndexPath + ".bak"

    #expect(throws: ConfigError.self) { try imageIndexAtVMBackup.validate() }
    #expect(throws: ConfigError.self) { try databaseAtImageBackup.validate() }
  }

  @Test
  func configRejectsBackupStorePathUsedAsManagedDirectory() {
    var config = Config.default
    config.storage.vmStorageDir = config.storage.databasePath + ".bak"

    #expect(throws: ConfigError.self) { try config.validate() }
  }

  @Test
  func configRejectsCaseOnlyStorePathCollisions() {
    var config = Config.default
    config.storage.databasePath = "/tmp/Jeballto-State.json"
    config.storage.imageIndexPath = "/tmp/jeballto-state.json"

    #expect(throws: ConfigError.self) { try config.validate() }
  }

  @Test
  func configRejectsIndexesInsideDisposableStorage() {
    var databaseInVMs = Config.default
    databaseInVMs.storage.databasePath = databaseInVMs.storage.vmStorageDir + "/vms.json"
    var indexInImages = Config.default
    indexInImages.storage.imageIndexPath = indexInImages.images.imageStorageDir + "/images.json"

    #expect(throws: ConfigError.self) {
      try databaseInVMs.validate()
    }
    #expect(throws: ConfigError.self) {
      try indexInImages.validate()
    }
  }

  @Test
  func configRejectsIndexesInsideLogDirectory() {
    var config = Config.default
    config.storage.imageIndexPath = config.logging.logDirectory + "/images.json"

    #expect(throws: ConfigError.self) {
      try config.validate()
    }
  }

  @Test
  func configRejectsExistingPathsWithWrongFilesystemKind() throws {
    try withTemporaryDirectory(prefix: "config-path-kind") { root in
      let regularFile = "\(root)/file"
      let directory = "\(root)/directory"
      try Data().write(to: URL(fileURLWithPath: regularFile))
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

      var fileAsStorage = Config.default
      fileAsStorage.storage.vmStorageDir = regularFile
      var directoryAsIndex = Config.default
      directoryAsIndex.storage.imageIndexPath = directory

      #expect(throws: ConfigError.self) { try fileAsStorage.validate() }
      #expect(throws: ConfigError.self) { try directoryAsIndex.validate() }
    }
  }

  @Test
  func imageConfigRejectsInvalidToolPathsAndRegistryHosts() {
    var relativeTool = Config.default
    relativeTool.images.orasPath = "bin/oras"
    var invalidDefault = Config.default
    invalidDefault.images.defaultRegistry = "Registry.Example.com"
    var invalidInsecure = Config.default
    invalidInsecure.images.insecureRegistries = ["registry.example.com:99999"]
    var duplicateInsecure = Config.default
    duplicateInsecure.images.insecureRegistries = ["registry.example.com", "registry.example.com"]

    #expect(throws: ConfigError.self) { try relativeTool.validate() }
    #expect(throws: ConfigError.self) { try invalidDefault.validate() }
    #expect(throws: ConfigError.self) { try invalidInsecure.validate() }
    #expect(throws: ConfigError.self) { try duplicateInsecure.validate() }
  }

  @Test
  func imageToolOverridesMustExistAndBeExecutable() throws {
    try withTemporaryDirectory(prefix: "config-tools") { root in
      let nonExecutable = "\(root)/oras"
      try Data("tool".utf8).write(to: URL(fileURLWithPath: nonExecutable))

      var missing = Config.default
      missing.images.orasPath = "\(root)/missing-oras"
      var notExecutable = Config.default
      notExecutable.images.orasPath = nonExecutable
      var valid = Config.default
      valid.images.orasPath = "/usr/bin/false"

      #expect(throws: ConfigError.self) { try missing.validate() }
      #expect(throws: ConfigError.self) { try notExecutable.validate() }
      try valid.validate()
    }
  }

  @Test
  func loggingLevelMustMatchCanonicalWireValue() {
    var config = Config.default
    config.logging.level = "INFO"

    #expect(throws: ConfigError.self) { try config.validate() }
  }

  @Test
  func configRejectsRelativeAndRootStoragePaths() {
    var relative = Config.default
    relative.storage.vmStorageDir = "relative-vms"
    var root = Config.default
    root.images.imageStorageDir = "/"
    var home = Config.default
    home.storage.vmStorageDir = NSHomeDirectory()
    var rootDatabase = Config.default
    rootDatabase.storage.databasePath = "/"
    var homeIndex = Config.default
    homeIndex.storage.imageIndexPath = NSHomeDirectory()

    #expect(throws: ConfigError.self) {
      try relative.validate()
    }
    #expect(throws: ConfigError.self) {
      try root.validate()
    }
    #expect(throws: ConfigError.self) {
      try home.validate()
    }
    #expect(throws: ConfigError.self) {
      try rootDatabase.validate()
    }
    #expect(throws: ConfigError.self) {
      try homeIndex.validate()
    }
  }

  @Test
  func defaultAPIHostBindsAllInterfaces() {
    #expect(Config.default.api.host == "0.0.0.0")
  }
}
