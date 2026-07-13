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

  @Test
  func retentionCutoffKeepsExactlyTheConfiguredCalendarDays() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let referenceDate = try #require(
      ISO8601DateFormatter().date(from: "2026-07-11T12:00:00Z")
    )
    let expectedCutoff = try #require(
      ISO8601DateFormatter().date(from: "2026-07-05T00:00:00Z")
    )

    #expect(
      Logger.retentionCutoff(referenceDate: referenceDate, retentionDays: 7, calendar: calendar) == expectedCutoff
    )
  }

  @Test
  func reconfigurationMovesFileLoggingToTheNewDirectory() throws {
    try withTemporaryDirectory(prefix: "logger-reconfigure") { root in
      let firstDirectory = "\(root)/first"
      let secondDirectory = "\(root)/second"
      let logger = Logger()
      defer { logger.enableFileLogging = false }

      logger.configure(with: LoggingConfig(enableFileLogging: true, logDirectory: firstDirectory))
      let firstEntries = try FileManager.default.contentsOfDirectory(atPath: firstDirectory)
      #expect(firstEntries.contains {
        $0.hasPrefix("agent-") && $0.hasSuffix(".log")
      })

      logger.configure(with: LoggingConfig(enableFileLogging: true, logDirectory: secondDirectory))
      let secondEntries = try FileManager.default.contentsOfDirectory(atPath: secondDirectory)
      #expect(secondEntries.contains {
        $0.hasPrefix("agent-") && $0.hasSuffix(".log")
      })
    }
  }

  @Test
  func fileLoggingDisablesItselfWhenConfiguredDirectoryIsAFile() throws {
    try withTemporaryDirectory(prefix: "logger-invalid-directory") { root in
      let filePath = "\(root)/not-a-directory"
      try Data("occupied".utf8).write(to: URL(fileURLWithPath: filePath))
      let logger = Logger()

      logger.configure(with: LoggingConfig(enableFileLogging: true, logDirectory: filePath))

      #expect(logger.enableFileLogging == false)
    }
  }

  @Test
  func fileLoggingRefusesSymbolicLinkForLogDirectory() throws {
    try withTemporaryDirectory(prefix: "logger-directory-symlink") { root in
      let target = "\(root)/outside"
      let link = "\(root)/logs"
      let sentinel = "\(target)/agent-2000-01-01.log"
      try FileManager.default.createDirectory(
        atPath: target,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
      )
      try Data("keep".utf8).write(to: URL(fileURLWithPath: sentinel))
      try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
      let permissionsBefore = try #require(
        FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? NSNumber
      )
      let logger = Logger()

      logger.configure(with: LoggingConfig(enableFileLogging: true, logDirectory: link))

      let permissionsAfter = try #require(
        FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? NSNumber
      )
      #expect(logger.enableFileLogging == false)
      #expect(permissionsAfter == permissionsBefore)
      #expect(try String(contentsOfFile: sentinel, encoding: .utf8) == "keep")
    }
  }

  @Test
  func fileLoggingRefusesSymbolicLinkForCurrentLogFile() throws {
    try withTemporaryDirectory(prefix: "logger-symlink") { root in
      let logDirectory = "\(root)/logs"
      let victimPath = "\(root)/victim"
      try FileManager.default.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)
      try Data("do not modify".utf8).write(to: URL(fileURLWithPath: victimPath))

      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "UTC")
      formatter.dateFormat = "yyyy-MM-dd"
      let logPath = "\(logDirectory)/agent-\(formatter.string(from: Date())).log"
      try FileManager.default.createSymbolicLink(atPath: logPath, withDestinationPath: victimPath)

      let logger = Logger()
      logger.configure(with: LoggingConfig(
        enableFileLogging: true,
        logDirectory: logDirectory,
        timezone: "UTC"
      ))

      #expect(logger.enableFileLogging == false)
      #expect(try String(contentsOfFile: victimPath, encoding: .utf8) == "do not modify")
    }
  }

  @Test
  func fileLoggingRefusesDanglingSymbolicLinkForCurrentLogFile() throws {
    try withTemporaryDirectory(prefix: "logger-dangling-symlink") { root in
      let logDirectory = "\(root)/logs"
      let missingTarget = "\(root)/missing-target"
      try FileManager.default.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "UTC")
      formatter.dateFormat = "yyyy-MM-dd"
      let logPath = "\(logDirectory)/agent-\(formatter.string(from: Date())).log"
      try FileManager.default.createSymbolicLink(atPath: logPath, withDestinationPath: missingTarget)

      let logger = Logger()
      logger.configure(with: LoggingConfig(
        enableFileLogging: true,
        logDirectory: logDirectory,
        timezone: "UTC"
      ))

      #expect(logger.enableFileLogging == false)
      #expect(FileManager.default.fileExists(atPath: missingTarget) == false)
    }
  }

  @Test
  func activeLogRotatesBeforeExceedingConfiguredSizeBudget() throws {
    try withTemporaryDirectory(prefix: "logger-size-budget") { root in
      let logDirectory = "\(root)/logs"
      try FileManager.default.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)

      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(identifier: "UTC")
      formatter.dateFormat = "yyyy-MM-dd"
      let logPath = "\(logDirectory)/agent-\(formatter.string(from: Date())).log"
      try Data(repeating: 0x61, count: 1_048_550).write(to: URL(fileURLWithPath: logPath))

      let logger = Logger()
      logger.configure(with: LoggingConfig(
        enableFileLogging: true,
        logDirectory: logDirectory,
        retentionDays: 7,
        maxTotalSize: "1MB",
        timezone: "UTC"
      ))
      logger.info(String(repeating: "b", count: 4096), category: "SizeBudgetTest")
      logger.enableFileLogging = false

      let data = try Data(contentsOf: URL(fileURLWithPath: logPath))
      let contents = String(decoding: data, as: UTF8.self)
      #expect(data.count < 128 * 1024)
      #expect(contents.contains("Active log was rotated because maxTotalSize was reached"))
      #expect(contents.contains("SizeBudgetTest"))
    }
  }

  @Test
  func oversizedFileLogEntryIsBounded() throws {
    try withTemporaryDirectory(prefix: "logger-entry-budget") { root in
      let logDirectory = "\(root)/logs"
      let logger = Logger()
      logger.configure(with: LoggingConfig(
        enableFileLogging: true,
        logDirectory: logDirectory,
        maxTotalSize: "1MB",
        timezone: "UTC"
      ))
      logger.error(String(repeating: "x", count: Logger.maximumFileEntrySize * 2), category: "EntryBudgetTest")
      logger.enableFileLogging = false

      let entries = try FileManager.default.contentsOfDirectory(atPath: logDirectory)
      let logName = try #require(entries.first { $0.hasPrefix("agent-") && $0.hasSuffix(".log") })
      let data = try Data(contentsOf: URL(fileURLWithPath: "\(logDirectory)/\(logName)"))
      let contents = String(decoding: data, as: UTF8.self)
      #expect(data.count <= Logger.maximumFileEntrySize)
      #expect(contents.contains("[file log entry truncated]"))
    }
  }
}
