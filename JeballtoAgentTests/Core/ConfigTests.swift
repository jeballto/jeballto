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
  func configRoundTripsThroughDisk() async throws {
    try await withTemporaryDirectory(prefix: "config") { root in
      let path = "\(root)/config.json"
      var config = Config.default
      config.api.port = 19090
      config.logging.level = "debug"
      config.images.maxParallelImageChunks = 3

      try config.save(to: path)
      let loaded = try Config.load(from: path)

      #expect(loaded.api.port == 19090)
      #expect(loaded.logging.level == "debug")
      #expect(loaded.images.maxParallelImageChunks == 3)
    }
  }

  @Test
  func imageConfigDecodesMissingParallelChunksAsAuto() throws {
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

    #expect(config.images.maxParallelImageChunks == 0)
  }

  @Test(arguments: [-1, 33])
  func imageConfigRejectsParallelChunksOutsideApiRange(value: Int) {
    let json = """
    {
      "imageStorageDir": "/tmp/images",
      "orasPath": null,
      "zstdPath": null,
      "maxParallelImageChunks": \(value),
      "defaultRegistry": null,
      "insecureRegistries": []
    }
    """

    #expect(throws: ConfigError.self) {
      _ = try JSONDecoder().decode(ImageConfig.self, from: Data(json.utf8))
    }
  }

  @Test
  func loggingConfigRoundTripsTimezone() async throws {
    try await withTemporaryDirectory(prefix: "config") { root in
      let path = "\(root)/config.json"
      var config = Config.default
      config.logging.timezone = "UTC"

      try config.save(to: path)
      let loaded = try Config.load(from: path)

      #expect(loaded.logging.timezone == "UTC")
    }
  }

  @Test
  func loggingConfigNilTimezoneRoundTrips() async throws {
    try await withTemporaryDirectory(prefix: "config") { root in
      let path = "\(root)/config.json"
      var config = Config.default
      config.logging.timezone = nil

      try config.save(to: path)
      let loaded = try Config.load(from: path)

      #expect(loaded.logging.timezone == nil)
    }
  }
}
