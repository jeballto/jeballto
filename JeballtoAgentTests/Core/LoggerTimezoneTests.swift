import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core), .serialized)
struct LoggerTimezoneTests {
  @Test
  func loggerConfiguresTimezoneFromConfig() {
    let config = LoggingConfig(
      level: "info",
      enableFileLogging: false,
      logDirectory: nil,
      retentionDays: 7,
      maxTotalSize: "2GB",
      timezone: "UTC"
    )
    let logger = Logger()
    logger.configure(with: config)

    // "UTC" and "GMT" are both UTC+0 - identifier varies by platform
    #expect(logger.timezone.secondsFromGMT() == 0)
  }

  @Test
  func loggerFallsBackToSystemTimezoneOnNilConfig() {
    let config = LoggingConfig(
      level: "info",
      enableFileLogging: false,
      logDirectory: nil,
      retentionDays: 7,
      maxTotalSize: "2GB",
      timezone: nil
    )
    let logger = Logger()
    logger.configure(with: config)

    #expect(logger.timezone == TimeZone.current)
  }

  @Test
  func loggerIgnoresInvalidTimezoneIdentifier() {
    // Invalid IANA identifiers are caught at the API layer (UpdateConfigRequest.validate).
    // configure(with:) silently falls back to system TZ for robustness.
    let config = LoggingConfig(
      level: "info",
      enableFileLogging: false,
      logDirectory: nil,
      retentionDays: 7,
      maxTotalSize: "2GB",
      timezone: "NotATZ"
    )
    let logger = Logger()
    logger.configure(with: config)

    #expect(logger.timezone == TimeZone.current)
  }
}
