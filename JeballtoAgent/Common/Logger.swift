import Darwin
import Foundation
import os.log

/// Log levels for the application
enum LogLevel: String, Comparable, Sendable {
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
final class Logger: @unchecked Sendable {
  /// Subsystem identifier for os_log
  private static let subsystem = "com.jeballto.vmagent"

  /// Shared logger instance
  static let shared = Logger()

  /// Bounds one file-log entry so a single diagnostic cannot defeat the configured storage limit.
  static let maximumFileEntrySize = 64 * 1024

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
  private let settingsLock = NSLock()
  private var _timezone: TimeZone = .current
  var timezone: TimeZone {
    get { settingsLock.withLock { _timezone } }
    set {
      settingsLock.withLock { _timezone = newValue }
      let tz = newValue
      fileWriteQueue.async { [weak self] in
        guard let self else { return }
        dateFormatter.timeZone = tz
        fileDateFormatter.timeZone = tz
      }
    }
  }

  /// Current log level threshold
  private var _logLevel: LogLevel = .info
  var logLevel: LogLevel {
    get { settingsLock.withLock { _logLevel } }
    set { settingsLock.withLock { _logLevel = newValue } }
  }

  /// OS Log instance
  private let osLog: OSLog

  /// File handle for file logging
  private var fileHandle: FileHandle?

  /// Serial queue for thread-safe file writes and cleanup
  private let fileWriteQueue = DispatchQueue(label: "com.jeballto.logger.filewrite")
  private let fileWriteQueueKey = DispatchSpecificKey<Void>()

  /// Directory for log files
  private var _logDirectory: String?
  var logDirectory: String? {
    get { settingsLock.withLock { _logDirectory } }
    set { settingsLock.withLock { _logDirectory = newValue } }
  }

  /// Number of days to retain log files
  private var _retentionDays = 7
  var retentionDays: Int {
    get { settingsLock.withLock { _retentionDays } }
    set { settingsLock.withLock { _retentionDays = newValue } }
  }

  /// Maximum total size of all log files in bytes (converted from config string)
  private var _maxTotalSizeBytes = 2_147_483_648
  var maxTotalSizeBytes: Int {
    get { settingsLock.withLock { _maxTotalSizeBytes } }
    set { settingsLock.withLock { _maxTotalSizeBytes = newValue } }
  }

  /// Tracks which day's log file is currently open
  private var currentDateString: String?

  /// Periodic cleanup timer
  private var cleanupTimer: DispatchSourceTimer?

  /// Enable file logging
  private var _enableFileLogging = false
  private let fileLoggingTransitionLock = NSLock()
  var enableFileLogging: Bool {
    get { settingsLock.withLock { _enableFileLogging } }
    set {
      fileLoggingTransitionLock.lock()
      defer { fileLoggingTransitionLock.unlock() }
      guard enableFileLogging != newValue else { return }

      if newValue {
        do {
          try setupFileLogging()
          settingsLock.withLock { _enableFileLogging = true }
          startCleanupSchedule()
        } catch {
          settingsLock.withLock { _enableFileLogging = false }
          reportFileLoggingFailure(error)
        }
      } else {
        settingsLock.withLock { _enableFileLogging = false }
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
    // Close the current handle before changing its directory or date formatting.
    // Configuration updates may move logs while file logging remains enabled.
    if enableFileLogging {
      enableFileLogging = false
    }

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

    logDirectory = config.logDirectory
    enableFileLogging = config.enableFileLogging
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
    let settings = settingsLock.withLock { (logLevel: _logLevel, fileLogging: _enableFileLogging) }
    guard level >= settings.logLevel else { return }

    let fileName = (file as NSString).lastPathComponent
    let formattedMessage = "[\(level.rawValue)] [\(category)] \(message) (\(fileName):\(line))"

    os_log("%{public}@", log: osLog, type: level.osLogType, formattedMessage)

    if settings.fileLogging {
      fileWriteQueue.async { [weak self] in
        guard let self else { return }
        let timestamp = dateFormatter.string(from: Date())
        let fileMessage = "[\(timestamp)] \(formattedMessage)\n"
        if let data = Self.boundedFileEntry(fileMessage) {
          do {
            try rolloverIfNeeded()
            guard let fileHandle else {
              throw LoggerFileError.fileHandleUnavailable(
                logFilePath(forDateString: currentDateString ?? "unknown"),
                "No writable file handle is active"
              )
            }
            try rotateCurrentLogIfNeeded(incomingByteCount: data.count, fileHandle: fileHandle)
            try fileHandle.write(contentsOf: data)
          } catch {
            settingsLock.withLock { self._enableFileLogging = false }
            reportFileLoggingFailure(error)
            cleanupTimer?.cancel()
            cleanupTimer = nil
            closeFileHandleOnFileWriteQueue()
          }
        }
      }
    }
  }

  // MARK: - Daily File Rollover

  /// Switches to a new day's log file if the date has changed. Must be called on fileWriteQueue.
  private func rolloverIfNeeded() throws {
    let today = fileDateFormatter.string(from: Date())
    guard today != currentDateString else { return }

    closeFileHandleOnFileWriteQueue()
    fileHandle = try openLogFile(forDateString: today)
    currentDateString = today
  }

  /// Truncates the active daily log before an incoming entry would exceed the configured budget.
  /// Historical files are still removed by the periodic retention pass. Keeping the active file
  /// bounded prevents it from bypassing `maxTotalSize` for an entire day.
  private func rotateCurrentLogIfNeeded(incomingByteCount: Int, fileHandle: FileHandle) throws {
    let budget = UInt64(max(1_048_576, maxTotalSizeBytes))
    let descriptor = fileHandle.fileDescriptor
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
      throw LoggerFileError.logRotationFailed(
        logFilePath(forDateString: currentDateString ?? "unknown"),
        String(cString: strerror(errno))
      )
    }
    guard status.st_size >= 0 else {
      throw LoggerFileError.logRotationFailed(
        logFilePath(forDateString: currentDateString ?? "unknown"),
        "File size metadata is negative"
      )
    }

    let currentSize = UInt64(status.st_size)
    let incomingSize = UInt64(incomingByteCount)
    let (projectedSize, overflow) = currentSize.addingReportingOverflow(incomingSize)
    guard overflow || projectedSize > budget else { return }

    guard Darwin.ftruncate(descriptor, 0) == 0 else {
      throw LoggerFileError.logRotationFailed(
        logFilePath(forDateString: currentDateString ?? "unknown"),
        String(cString: strerror(errno))
      )
    }

    let marker = "[INFO] [Logger] Active log was rotated because maxTotalSize was reached\n"
    if let markerData = marker.data(using: .utf8) {
      try fileHandle.write(contentsOf: markerData)
    }
  }

  private static func boundedFileEntry(_ message: String) -> Data? {
    guard var data = message.data(using: .utf8) else { return nil }
    guard data.count > maximumFileEntrySize else { return data }

    let suffix = Data("... [file log entry truncated]\n".utf8)
    let prefixCount = max(0, maximumFileEntrySize - suffix.count)
    data = Data(data.prefix(prefixCount))
    while String(data: data, encoding: .utf8) == nil, data.isEmpty == false {
      data.removeLast()
    }
    data.append(suffix)
    return data
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
    do {
      try Self.validateRealDirectory(atPath: dir)
    } catch {
      reportFileLoggingFailure(error)
      return
    }

    let fm = FileManager.default
    let entries: [String]
    do {
      entries = try fm.contentsOfDirectory(atPath: dir)
    } catch {
      reportFileLoggingFailure(LoggerFileError.retentionInspectionFailed(dir, error.localizedDescription))
      return
    }

    let today = fileDateFormatter.string(from: Date())

    // Collect log files with parsed dates, sorted oldest-first
    var logFiles: [LogFileEntry] = []
    for entry in entries {
      guard entry.hasPrefix("agent-"), entry.hasSuffix(".log") else { continue }
      let path = "\(dir)/\(entry)"
      do {
        try Self.validateRegularFile(atPath: path)
      } catch {
        reportFileLoggingFailure(error)
        continue
      }
      let dateString = String(entry.dropFirst(6).dropLast(4)) // strip "agent-" and ".log"
      guard let date = fileDateFormatter.date(from: dateString) else { continue }
      logFiles.append(LogFileEntry(path: path, dateString: dateString, date: date))
    }
    logFiles.sort { $0.date < $1.date }

    // Retention days pass: delete files older than retentionDays
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = fileDateFormatter.timeZone
    let cutoffDate = Self.retentionCutoff(
      referenceDate: Date(),
      retentionDays: retentionDays,
      calendar: calendar
    )
    var remaining: [LogFileEntry] = []
    for file in logFiles {
      if let cutoffDate, file.dateString != today, file.date < cutoffDate {
        do {
          try fm.removeItem(atPath: file.path)
          logRetentionDeletion(file.path, reason: "older than \(retentionDays) days")
        } catch {
          reportFileLoggingFailure(
            LoggerFileError.retentionCleanupFailed(file.path, error.localizedDescription)
          )
          remaining.append(file)
        }
      } else {
        remaining.append(file)
      }
    }

    // Size budget pass: delete oldest until under maxTotalSizeBytes
    var totalSize = remaining.reduce(into: UInt64(0)) { sum, file in
      guard let size = logFileSize(file.path) else { return }
      let (newTotal, overflow) = sum.addingReportingOverflow(size)
      sum = overflow ? UInt64.max : newTotal
    }
    let sizeBudget = UInt64(max(0, maxTotalSizeBytes))

    var index = 0
    while totalSize > sizeBudget, index < remaining.count {
      let file = remaining[index]
      if file.dateString == today {
        index += 1
        continue
      }
      let fileSize = logFileSize(file.path) ?? 0
      do {
        try fm.removeItem(atPath: file.path)
        logRetentionDeletion(file.path, reason: "total size exceeds \(maxTotalSizeBytes) bytes")
        totalSize = fileSize >= totalSize ? 0 : totalSize - fileSize
      } catch {
        reportFileLoggingFailure(
          LoggerFileError.retentionCleanupFailed(file.path, error.localizedDescription)
        )
      }
      index += 1
    }
  }

  private func logFileSize(_ path: String) -> UInt64? {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      guard let size = attributes[.size] as? NSNumber, size.doubleValue >= 0 else {
        throw LoggerFileError.retentionInspectionFailed(path, "File size metadata is missing or invalid")
      }
      return size.uint64Value
    } catch {
      reportFileLoggingFailure(LoggerFileError.retentionInspectionFailed(path, error.localizedDescription))
      return nil
    }
  }

  static func retentionCutoff(referenceDate: Date, retentionDays: Int, calendar: Calendar) -> Date? {
    guard retentionDays >= 1 else { return nil }
    return calendar.date(
      byAdding: .day,
      value: -(retentionDays - 1),
      to: calendar.startOfDay(for: referenceDate)
    )
  }

  private func logRetentionDeletion(_ path: String, reason: String) {
    let fileName = (path as NSString).lastPathComponent
    let message = "[INFO] [Logger] Deleted log file \(fileName) - \(reason)\n"
    guard let data = message.data(using: .utf8), let fileHandle else { return }
    do {
      try fileHandle.write(contentsOf: data)
    } catch {
      settingsLock.withLock { _enableFileLogging = false }
      reportFileLoggingFailure(error)
      closeFileHandleOnFileWriteQueue()
    }
  }

  /// Starts periodic cleanup: runs immediately, then every hour
  private func startCleanupSchedule() {
    syncOnFileWriteQueue {
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
  }

  // MARK: - File Logging Setup

  private func setupFileLogging() throws {
    guard let dir = logDirectory else { throw LoggerFileError.logDirectoryUnavailable }

    try syncOnFileWriteQueue {
      let fm = FileManager.default
      do {
        try fm.createDirectory(
          atPath: dir,
          withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        throw LoggerFileError.directoryCreationFailed(dir, error.localizedDescription)
      }
      try Self.validateRealDirectory(atPath: dir)
      do {
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
      } catch {
        throw LoggerFileError.permissionsUpdateFailed(dir, error.localizedDescription)
      }

      try migrateOldLogFiles(in: dir)

      let today = fileDateFormatter.string(from: Date())
      closeFileHandleOnFileWriteQueue()
      fileHandle = try openLogFile(forDateString: today)
      currentDateString = today
    }
  }

  /// Migrates old agent.log and agent.log.1 to per-day format
  private func migrateOldLogFiles(in dir: String) throws {
    let fm = FileManager.default
    let oldLogPath = "\(dir)/agent.log"
    let oldBackupPath = "\(dir)/agent.log.1"

    for path in [oldBackupPath, oldLogPath] {
      guard Self.filesystemEntryExists(atPath: path) else { continue }
      try Self.validateRegularFile(atPath: path)
      let modDate: Date
      do {
        let attributes = try fm.attributesOfItem(atPath: path)
        guard let date = attributes[.modificationDate] as? Date else {
          throw LoggerFileError.migrationFailed(path, dir, "Modification date metadata is missing")
        }
        modDate = date
      } catch let error as LoggerFileError {
        throw error
      } catch {
        throw LoggerFileError.migrationFailed(path, dir, error.localizedDescription)
      }
      let dateString = fileDateFormatter.string(from: modDate)
      let newPath = logFilePath(forDateString: dateString)

      if fm.fileExists(atPath: newPath) {
        try Self.validateRegularFile(atPath: newPath)
        do {
          try appendFile(at: path, to: newPath)
          try fm.removeItem(atPath: path)
        } catch {
          throw LoggerFileError.migrationFailed(path, newPath, error.localizedDescription)
        }
      } else {
        do {
          try fm.moveItem(atPath: path, toPath: newPath)
        } catch {
          throw LoggerFileError.migrationFailed(path, newPath, error.localizedDescription)
        }
      }
      do {
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: newPath)
      } catch {
        throw LoggerFileError.permissionsUpdateFailed(newPath, error.localizedDescription)
      }
    }
  }

  private func openLogFile(forDateString dateString: String) throws -> FileHandle {
    let path = logFilePath(forDateString: dateString)
    if let dir = logDirectory {
      try Self.validateRealDirectory(atPath: dir)
    }

    let descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw LoggerFileError.fileHandleUnavailable(path, String(cString: strerror(errno)))
    }
    var info = stat()
    guard Darwin.fstat(descriptor, &info) == 0 else {
      let reason = String(cString: strerror(errno))
      Darwin.close(descriptor)
      throw LoggerFileError.invalidLogFile(path, reason)
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
      Darwin.close(descriptor)
      throw LoggerFileError.invalidLogFile(path, "Opened path is not a regular file")
    }
    guard Darwin.fchmod(descriptor, 0o600) == 0 else {
      let reason = String(cString: strerror(errno))
      Darwin.close(descriptor)
      throw LoggerFileError.permissionsUpdateFailed(path, reason)
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  private static func validateRegularFile(atPath path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0 else {
      throw LoggerFileError.invalidLogFile(path, String(cString: strerror(errno)))
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
      throw LoggerFileError.invalidLogFile(path, "Expected a regular file and refused a symbolic link or special file")
    }
  }

  private static func validateRealDirectory(atPath path: String) throws {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else {
      throw LoggerFileError.directoryCreationFailed(path, "Directory path contains a symbolic link")
    }
    var info = stat()
    guard Darwin.lstat(path, &info) == 0 else {
      throw LoggerFileError.directoryCreationFailed(path, String(cString: strerror(errno)))
    }
    guard info.st_mode & S_IFMT == S_IFDIR else {
      throw LoggerFileError.directoryCreationFailed(path, "Expected a real directory and refused a symbolic link")
    }
  }

  private static func filesystemEntryExists(atPath path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  private func appendFile(at sourcePath: String, to destinationPath: String) throws {
    let source = try FileHandle(forReadingFrom: URL(fileURLWithPath: sourcePath))
    let destination = try FileHandle(forWritingTo: URL(fileURLWithPath: destinationPath))
    defer {
      try? source.close()
      try? destination.close()
    }

    try destination.seekToEnd()
    while let data = try readFileChunk(from: source, upToCount: 1024 * 1024), data.isEmpty == false {
      try destination.write(contentsOf: data)
    }
    try destination.synchronize()
  }

  private func closeFileHandleOnFileWriteQueue() {
    if let fileHandle {
      do {
        try fileHandle.close()
      } catch {
        reportFileLoggingFailure(error)
      }
    }
    fileHandle = nil
    currentDateString = nil
  }

  private func reportFileLoggingFailure(_ error: Error) {
    os_log(
      "File logging failure: %{public}@",
      log: osLog,
      type: .error,
      error.localizedDescription
    )
  }

  private func closeFileLogging() {
    syncOnFileWriteQueue {
      cleanupTimer?.cancel()
      cleanupTimer = nil
      closeFileHandleOnFileWriteQueue()
    }
  }

  deinit { closeFileLogging() }

  private func syncOnFileWriteQueue<T>(_ operation: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: fileWriteQueueKey) != nil {
      try operation()
    } else {
      try fileWriteQueue.sync(execute: operation)
    }
  }
}

private enum LoggerFileError: Error, LocalizedError {
  case logDirectoryUnavailable
  case directoryCreationFailed(String, String)
  case fileCreationFailed(String)
  case fileHandleUnavailable(String, String)
  case permissionsUpdateFailed(String, String)
  case migrationFailed(String, String, String)
  case retentionCleanupFailed(String, String)
  case retentionInspectionFailed(String, String)
  case invalidLogFile(String, String)
  case logRotationFailed(String, String)

  var errorDescription: String? {
    switch self {
    case .logDirectoryUnavailable:
      "File logging is enabled but no log directory is configured"
    case .directoryCreationFailed(let path, let reason):
      "Failed to prepare log directory at \(path): \(reason)"
    case .fileCreationFailed(let path):
      "Failed to create log file at \(path)"
    case .fileHandleUnavailable(let path, let reason):
      "Failed to open log file for writing at \(path): \(reason)"
    case .permissionsUpdateFailed(let path, let reason):
      "Failed to protect log file permissions at \(path): \(reason)"
    case .migrationFailed(let source, let destination, let reason):
      "Failed to migrate legacy log \(source) to \(destination): \(reason)"
    case .retentionCleanupFailed(let path, let reason):
      "Failed to remove expired log file at \(path): \(reason)"
    case .retentionInspectionFailed(let path, let reason):
      "Failed to inspect logs at \(path): \(reason)"
    case .invalidLogFile(let path, let reason):
      "Refusing unsafe log file at \(path): \(reason)"
    case .logRotationFailed(let path, let reason):
      "Failed to rotate active log at \(path): \(reason)"
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
