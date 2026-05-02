import Foundation
import os.log

/// Log levels for the application
enum LogLevel: String, Comparable {
  case debug = "DEBUG"
  case info = "INFO"
  case warning = "WARNING"
  case error = "ERROR"

  var osLogType: OSLogType {
    switch self {
    case .debug: .debug
    case .info: .info
    case .warning: .default
    case .error: .error
    }
  }

  static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    let order: [LogLevel] = [.debug, .info, .warning, .error]
    guard let lhsIndex = order.firstIndex(of: lhs), let rhsIndex = order.firstIndex(of: rhs) else { return false }
    return lhsIndex < rhsIndex
  }
}

/// Centralized logging system with per-day log files and retention-based cleanup
class Logger {
  /// Subsystem identifier for os_log
  private static let subsystem = "com.jeballto.vmagent"

  /// Shared logger instance
  static let shared = Logger()

  /// Date formatter for log timestamps. Instance var so timezone can be updated.
  /// Only accessed on fileWriteQueue.
  private var dateFormatter: ISO8601DateFormatter = .init()

  /// Date formatter for daily log file names (yyyy-MM-dd). Instance var so timezone can be updated.
  /// Only accessed on fileWriteQueue.
  private var fileDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
  }()

  /// IANA timezone for log timestamps. Updates both formatters on fileWriteQueue when set.
  var timezone: TimeZone = .current {
    didSet {
      let tz = timezone // capture value on calling thread before async dispatch
      fileWriteQueue.async { [weak self] in
        guard let self else { return }
        dateFormatter.timeZone = tz
        fileDateFormatter.timeZone = tz
      }
    }
  }

  /// Current log level threshold
  var logLevel: LogLevel = .info

  /// OS Log instance
  private let osLog: OSLog

  /// File handle for file logging
  private var fileHandle: FileHandle?

  /// Serial queue for thread-safe file writes and cleanup
  private let fileWriteQueue = DispatchQueue(label: "com.jeballto.logger.filewrite")
  private let fileWriteQueueKey = DispatchSpecificKey<Void>()

  /// Directory for log files
  var logDirectory: String?

  /// Number of days to retain log files
  var retentionDays: Int = 7

  /// Maximum total size of all log files in bytes (converted from config string)
  var maxTotalSizeBytes: Int = 2_147_483_648

  /// Tracks which day's log file is currently open
  private var currentDateString: String?

  /// Periodic cleanup timer
  private var cleanupTimer: DispatchSourceTimer?

  /// Enable file logging
  var enableFileLogging: Bool = false {
    didSet {
      if enableFileLogging, fileHandle == nil {
        setupFileLogging()
      } else if !enableFileLogging, fileHandle != nil {
        closeFileLogging()
      }
    }
  }

  init() {
    osLog = OSLog(subsystem: Logger.subsystem, category: "general")
    fileWriteQueue.setSpecific(key: fileWriteQueueKey, value: ())
  }

  /// Configures the logger with settings from config
  func configure(with config: LoggingConfig) {
    switch config.level.lowercased() {
    case "debug": logLevel = .debug
    case "info": logLevel = .info
    case "warning": logLevel = .warning
    case "error": logLevel = .error
    default: logLevel = .info
    }

    retentionDays = config.retentionDays
    maxTotalSizeBytes = LoggingConfig.parseSize(config.maxTotalSize) ?? 2_147_483_648

    if let tzId = config.timezone, let tz = TimeZone(identifier: tzId) {
      timezone = tz
    } else {
      timezone = .current
    }

    if config.enableFileLogging {
      logDirectory = config.logDirectory
      setupFileLogging()
      enableFileLogging = true
      startCleanupSchedule()
    }
  }

  // MARK: - Logging Methods

  /// Logs a debug message
  func debug(_ message: String, category: String = "general", file: String = #file, line: Int = #line) {
    log(level: .debug, message: message, category: category, file: file, line: line)
  }

  /// Logs an info message
  func info(_ message: String, category: String = "general", file: String = #file, line: Int = #line) {
    log(level: .info, message: message, category: category, file: file, line: line)
  }

  /// Logs a warning message
  func warning(_ message: String, category: String = "general", file: String = #file, line: Int = #line) {
    log(level: .warning, message: message, category: category, file: file, line: line)
  }

  /// Logs an error message
  func error(_ message: String, category: String = "general", file: String = #file, line: Int = #line) {
    log(level: .error, message: message, category: category, file: file, line: line)
  }

  /// Generic logging method
  private func log(level: LogLevel, message: String, category: String, file: String, line: Int) {
    guard level >= logLevel else { return }

    let fileName = (file as NSString).lastPathComponent
    let formattedMessage = "[\(level.rawValue)] [\(category)] \(message) (\(fileName):\(line))"

    os_log("%{public}@", log: osLog, type: level.osLogType, formattedMessage)

    if enableFileLogging {
      fileWriteQueue.async { [weak self] in
        guard let self else { return }
        let timestamp = dateFormatter.string(from: Date())
        let fileMessage = "[\(timestamp)] \(formattedMessage)\n"
        if let data = fileMessage.data(using: .utf8) {
          rolloverIfNeeded()
          fileHandle?.write(data)
        }
      }
    }
  }

  // MARK: - Daily File Rollover

  /// Switches to a new day's log file if the date has changed. Must be called on fileWriteQueue.
  private func rolloverIfNeeded() {
    let today = fileDateFormatter.string(from: Date())
    guard today != currentDateString else { return }

    try? fileHandle?.close()
    fileHandle = nil

    let path = logFilePath(forDateString: today)
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    fileHandle = FileHandle(forWritingAtPath: path)
    fileHandle?.seekToEndOfFile()
    currentDateString = today
  }

  /// Returns the log file path for a given date string
  private func logFilePath(forDateString dateString: String) -> String {
    "\(logDirectory ?? NSTemporaryDirectory())/agent-\(dateString).log"
  }

  // MARK: - Cleanup

  /// Represents a dated log file for retention cleanup
  private struct LogFileEntry {
    let path: String
    let dateString: String
    let date: Date
  }

  /// Performs retention-based cleanup. Must be called on fileWriteQueue.
  private func performCleanup() {
    guard let dir = logDirectory else { return }

    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }

    let today = fileDateFormatter.string(from: Date())

    // Collect log files with parsed dates, sorted oldest-first
    var logFiles: [LogFileEntry] = []
    for entry in entries {
      guard entry.hasPrefix("agent-"), entry.hasSuffix(".log") else { continue }
      let dateString = String(entry.dropFirst(6).dropLast(4)) // strip "agent-" and ".log"
      guard let date = fileDateFormatter.date(from: dateString) else { continue }
      logFiles.append(LogFileEntry(path: "\(dir)/\(entry)", dateString: dateString, date: date))
    }
    logFiles.sort { $0.date < $1.date }

    // Retention days pass: delete files older than retentionDays
    let calendar = Calendar.current
    let cutoffDate = calendar.date(byAdding: .day, value: -retentionDays, to: calendar.startOfDay(for: Date()))!
    var remaining: [LogFileEntry] = []
    for file in logFiles {
      if file.dateString != today, file.date < cutoffDate {
        try? fm.removeItem(atPath: file.path)
        logRetentionDeletion(file.path, reason: "older than \(retentionDays) days")
      } else {
        remaining.append(file)
      }
    }

    // Size budget pass: delete oldest until under maxTotalSizeBytes
    var totalSize = remaining.reduce(into: 0) { sum, file in
      let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
      sum += size
    }

    var index = 0
    while totalSize > maxTotalSizeBytes, index < remaining.count {
      let file = remaining[index]
      if file.dateString == today {
        index += 1
        continue
      }
      let fileSize = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
      try? fm.removeItem(atPath: file.path)
      logRetentionDeletion(file.path, reason: "total size exceeds \(maxTotalSizeBytes) bytes")
      totalSize -= fileSize
      index += 1
    }
  }

  private func logRetentionDeletion(_ path: String, reason: String) {
    let fileName = (path as NSString).lastPathComponent
    let message = "[INFO] [Logger] Deleted log file \(fileName) - \(reason)\n"
    if let data = message.data(using: .utf8) {
      fileHandle?.write(data)
    }
  }

  /// Starts periodic cleanup: runs immediately, then every hour
  private func startCleanupSchedule() {
    cleanupTimer?.cancel()
    cleanupTimer = nil

    let timer = DispatchSource.makeTimerSource(queue: fileWriteQueue)
    timer.schedule(deadline: .now(), repeating: 3600)
    timer.setEventHandler { [weak self] in
      self?.performCleanup()
    }
    timer.resume()
    cleanupTimer = timer
  }

  // MARK: - File Logging Setup

  private func setupFileLogging() {
    guard let dir = logDirectory else { return }

    syncOnFileWriteQueue {
      let fm = FileManager.default
      try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

      migrateOldLogFiles(in: dir)

      let today = fileDateFormatter.string(from: Date())
      let path = logFilePath(forDateString: today)

      if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
      }

      fileHandle = FileHandle(forWritingAtPath: path)
      fileHandle?.seekToEndOfFile()
      currentDateString = today
    }
  }

  /// Migrates old agent.log and agent.log.1 to per-day format
  private func migrateOldLogFiles(in dir: String) {
    let fm = FileManager.default
    let oldLogPath = "\(dir)/agent.log"
    let oldBackupPath = "\(dir)/agent.log.1"

    for path in [oldBackupPath, oldLogPath] {
      guard fm.fileExists(atPath: path) else { continue }
      let modDate = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? Date()
      let dateString = fileDateFormatter.string(from: modDate)
      let newPath = logFilePath(forDateString: dateString)

      if fm.fileExists(atPath: newPath) {
        // Append old content to existing per-day file
        if let oldData = fm.contents(atPath: path) {
          if let handle = FileHandle(forWritingAtPath: newPath) {
            handle.seekToEndOfFile()
            handle.write(oldData)
            try? handle.close()
          }
        }
        try? fm.removeItem(atPath: path)
      } else {
        try? fm.moveItem(atPath: path, toPath: newPath)
      }
    }
  }

  private func closeFileLogging() {
    syncOnFileWriteQueue {
      cleanupTimer?.cancel()
      cleanupTimer = nil
      try? fileHandle?.close()
      fileHandle = nil
      currentDateString = nil
    }
  }

  deinit { closeFileLogging() }

  private func syncOnFileWriteQueue(_ operation: () -> Void) {
    if DispatchQueue.getSpecific(key: fileWriteQueueKey) != nil {
      operation()
    } else {
      fileWriteQueue.sync(execute: operation)
    }
  }
}

/// Global logging functions for convenience
func logDebug(_ message: String, category: String = "general", file: String = #file, line: Int = #line) {
  Logger.shared.debug(message, category: category, file: file, line: line)
}

func logInfo(_ message: String, category: String = "general", file: String = #file, line: Int = #line) {
  Logger.shared.info(message, category: category, file: file, line: line)
}

func logWarning(_ message: String, category: String = "general", file: String = #file, line: Int = #line) {
  Logger.shared.warning(message, category: category, file: file, line: line)
}

func logError(_ message: String, category: String = "general", file: String = #file, line: Int = #line) {
  Logger.shared.error(message, category: category, file: file, line: line)
}
