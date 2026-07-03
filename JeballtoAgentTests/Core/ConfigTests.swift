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
  func loggingSizeParserCurrentBehaviorAllowsNegativeUnits() {
    #expect(LoggingConfig.parseSize("-1GB") == -1_073_741_824)
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
}
