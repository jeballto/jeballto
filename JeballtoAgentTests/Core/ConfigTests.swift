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

      try config.save(to: path)
      let loaded = try Config.load(from: path)

      #expect(loaded.api.port == 19090)
      #expect(loaded.logging.level == "debug")
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
