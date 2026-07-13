import Cocoa
import Darwin
import ServiceManagement
import Sparkle
import UniformTypeIdentifiers

@MainActor
final class StatusBarManager: NSObject, NSMenuDelegate {
  private var statusItem: NSStatusItem?
  private var apiToken: String?
  private var vmManager: VMManager?
  private var serverStartUptime: TimeInterval?
  private var updaterManager: UpdaterManager?
  private var logDirectory = "\(NSHomeDirectory())/Library/Logs/Jeballto"
  private var countRefreshTimer: Timer?

  // Menu items that get updated dynamically
  private var statusMenuItem: NSMenuItem?
  private var vmsMenuItem: NSMenuItem?
  private var uptimeMenuItem: NSMenuItem?
  private var loginItemMenuItem: NSMenuItem?
  private var betaUpdatesMenuItem: NSMenuItem?

  // Cached values for sync access (actor-isolated VMManager can't be called from sync context)
  private var cachedRunningVMs: Int = 0
  private var cachedTotalVMs: Int = 0

  isolated deinit {
    countRefreshTimer?.invalidate()
  }

  func setup(updaterManager: UpdaterManager) {
    self.updaterManager = updaterManager

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    if let button = statusItem.button {
      if let icon = NSImage(named: "TrayIcon") {
        icon.isTemplate = true
        button.image = icon
      } else {
        logError("TrayIcon image not found in asset catalog, using text fallback", category: "StatusBar")
        button.title = "J"
      }
      button.toolTip = "Jeballto VM Agent"
    }

    let menu = NSMenu()
    menu.delegate = self

    // Health status items (disabled, informational)
    let statusItem_ = NSMenuItem(title: "Status: Starting...", action: nil, keyEquivalent: "")
    statusItem_.isEnabled = false
    menu.addItem(statusItem_)
    statusMenuItem = statusItem_

    let vmsItem = NSMenuItem(title: "VMs: -", action: nil, keyEquivalent: "")
    vmsItem.isEnabled = false
    menu.addItem(vmsItem)
    vmsMenuItem = vmsItem

    let uptimeItem = NSMenuItem(title: "Uptime: -", action: nil, keyEquivalent: "")
    uptimeItem.isEnabled = false
    menu.addItem(uptimeItem)
    uptimeMenuItem = uptimeItem

    menu.addItem(.separator())

    // Copy API Token
    menu.addItem(withTitle: "Copy API Token", action: #selector(copyAPIToken), keyEquivalent: "c")
      .target = self
    menu.addItem(withTitle: "Export API Schema", action: #selector(exportAPISchema), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "Open Application Support", action: #selector(openApplicationSupport), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "Open Cache", action: #selector(openCache), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "Open Logs", action: #selector(openLogs), keyEquivalent: "")
      .target = self
    menu.addItem(withTitle: "Export Logs", action: #selector(exportLogs), keyEquivalent: "")
      .target = self
    menu.addItem(
      withTitle: "Check for Updates",
      action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
      keyEquivalent: ""
    )
    .target = updaterManager.updaterController

    let betaUpdatesItem = NSMenuItem(title: "Beta Updates", action: #selector(toggleBetaUpdates), keyEquivalent: "")
    betaUpdatesItem.target = self
    betaUpdatesItem.state = updaterManager.isBetaUpdatesEnabled ? .on : .off
    menu.addItem(betaUpdatesItem)
    betaUpdatesMenuItem = betaUpdatesItem

    menu.addItem(.separator())

    let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
    loginItem.target = self
    loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(loginItem)
    loginItemMenuItem = loginItem

    menu.addItem(withTitle: "About Jeballto", action: #selector(showAbout), keyEquivalent: "")
      .target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Stop Jeballto", action: #selector(stopApp), keyEquivalent: "q")
      .target = self

    statusItem.menu = menu
    self.statusItem = statusItem

    logInfo("Status bar icon configured", category: "StatusBar")
  }

  func configure(
    token: String,
    vmManager: VMManager,
    serverStartUptime: TimeInterval?,
    initialVMCount: Int,
    logDirectory: String
  ) {
    apiToken = token
    self.vmManager = vmManager
    self.serverStartUptime = serverStartUptime
    self.logDirectory = logDirectory
    cachedTotalVMs = initialVMCount

    // Immediately reflect that initialization is complete
    statusMenuItem?.title = "Status: Healthy"
    vmsMenuItem?.title = "VMs: 0 running / \(initialVMCount) total"
    refreshCachedCounts()
    startCountRefreshTimer()
  }

  // MARK: - NSMenuDelegate

  func menuNeedsUpdate(_ menu: NSMenu) {
    guard vmManager != nil else {
      statusMenuItem?.title = "Status: Starting..."
      vmsMenuItem?.title = "VMs: -"
      uptimeMenuItem?.title = "Uptime: -"
      return
    }

    statusMenuItem?.title = "Status: Healthy"

    vmsMenuItem?.title = "VMs: \(cachedRunningVMs) running / \(cachedTotalVMs) total"

    loginItemMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    betaUpdatesMenuItem?.state = updaterManager?.isBetaUpdatesEnabled == true ? .on : .off

    if let startUptime = serverStartUptime {
      let seconds = max(0, Int(ProcessInfo.processInfo.systemUptime - startUptime))
      uptimeMenuItem?.title = "Uptime: \(formatUptime(seconds))"
    }
  }

  private func startCountRefreshTimer() {
    countRefreshTimer?.invalidate()
    countRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshCachedCounts()
      }
    }
  }

  private func refreshCachedCounts() {
    guard let vmManager else { return }
    Task<Void, Never> { [weak self] in
      let running = await vmManager.runningVMCount()
      do {
        let total = try await vmManager.vmCount()
        guard let self else { return }
        cachedRunningVMs = running
        cachedTotalVMs = total
        vmsMenuItem?.title = "VMs: \(running) running / \(total) total"
      } catch {
        logError("Failed to refresh VM count: \(error.localizedDescription)", category: "StatusBar")
      }
    }
  }

  // MARK: - Actions

  @objc private func toggleLoginItem() {
    let service = SMAppService.mainApp
    do {
      if service.status == .enabled {
        try service.unregister()
        loginItemMenuItem?.state = .off
        logInfo("Unregistered from login items", category: "StatusBar")
      } else {
        try service.register()
        loginItemMenuItem?.state = .on
        logInfo("Registered as login item", category: "StatusBar")
      }
    } catch {
      logError("Failed to toggle login item: \(error)", category: "StatusBar")
    }
  }

  @objc private func toggleBetaUpdates() {
    guard let updaterManager else {
      logError("Updater manager not available yet", category: "StatusBar")
      return
    }

    let isEnabled = !updaterManager.isBetaUpdatesEnabled
    updaterManager.setBetaUpdatesEnabled(isEnabled)
    betaUpdatesMenuItem?.state = isEnabled ? .on : .off

    let feedName = isEnabled ? "beta" : "stable"
    logInfo("Switched Sparkle update feed to \(feedName)", category: "StatusBar")
  }

  @objc private func copyAPIToken() {
    guard let token = apiToken else {
      logError("API token not available yet", category: "StatusBar")
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(token, forType: .string)
    logInfo("API token copied to clipboard", category: "StatusBar")
  }

  @objc private func exportAPISchema() {
    guard let sourceURL = Bundle.main.url(forResource: "jeballto-api", withExtension: "yaml") else {
      logError("OpenAPI schema not found in bundle", category: "StatusBar")
      return
    }

    let panel = NSSavePanel()
    panel.nameFieldStringValue = "jeballto-api.yaml"
    panel.allowedContentTypes = [UTType.yaml]
    panel.canCreateDirectories = true

    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK, let destURL = panel.url else { return }

    do {
      let content = try Data(contentsOf: sourceURL)
      try content.write(to: destURL)
      logInfo("OpenAPI schema exported to \(destURL.path)", category: "StatusBar")
    } catch {
      logError("Failed to export OpenAPI schema: \(error)", category: "StatusBar")
    }
  }

  @objc private func openApplicationSupport() {
    let path = "\(NSHomeDirectory())/Library/Application Support/Jeballto"
    let url = URL(fileURLWithPath: path, isDirectory: true)
    NSWorkspace.shared.open(url)
    logInfo("Opened Application Support directory", category: "StatusBar")
  }

  @objc private func openCache() {
    let url = JeballtoCachePaths.root
    NSWorkspace.shared.open(url)
    logInfo("Opened Cache directory", category: "StatusBar")
  }

  @objc private func openLogs() {
    let url = URL(fileURLWithPath: logDirectory, isDirectory: true)
    NSWorkspace.shared.open(url)
    logInfo("Opened Logs directory", category: "StatusBar")
  }

  @objc private func exportLogs() {
    let logDir = logDirectory
    let fm = FileManager.default

    guard let entries = try? fm.contentsOfDirectory(atPath: logDir) else {
      logError("Log directory not found at \(logDir)", category: "StatusBar")
      return
    }

    let logFiles = entries.filter { $0.hasPrefix("agent-") && $0.hasSuffix(".log") }.sorted()
    guard !logFiles.isEmpty else {
      logError("No log files found in \(logDir)", category: "StatusBar")
      return
    }

    let panel = NSSavePanel()
    panel.canCreateDirectories = true

    if logFiles.count == 1 {
      panel.nameFieldStringValue = logFiles[0]

      NSApp.activate(ignoringOtherApps: true)
      guard panel.runModal() == .OK, let destURL = panel.url else { return }

      let sourceURL = URL(fileURLWithPath: logDir, isDirectory: true).appendingPathComponent(logFiles[0])
      Task<Void, Never> {
        do {
          try await Self.copyLogFile(from: sourceURL, to: destURL)
          logInfo("Logs exported to \(destURL.path)", category: "StatusBar")
        } catch {
          logError("Failed to export logs: \(error.localizedDescription)", category: "StatusBar")
        }
      }
    } else {
      panel.nameFieldStringValue = "jeballto-logs.zip"

      NSApp.activate(ignoringOtherApps: true)
      guard panel.runModal() == .OK, let destURL = panel.url else { return }

      let sourceURLs = logFiles.map {
        URL(fileURLWithPath: logDir, isDirectory: true).appendingPathComponent($0)
      }
      Task<Void, Never> {
        do {
          try await Self.archiveLogs(sourceURLs, to: destURL)
          logInfo("Logs exported to \(destURL.path)", category: "StatusBar")
        } catch {
          logError("Failed to export logs: \(error.localizedDescription)", category: "StatusBar")
        }
      }
    }
  }

  @concurrent private nonisolated static func copyLogFile(
    from sourceURL: URL,
    to destinationURL: URL
  ) async throws {
    guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else {
      throw StatusBarError.invalidLogDestination(destinationURL.path)
    }
    try validateLogFile(sourceURL)

    let temporaryURL = temporaryExportURL(for: destinationURL)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/cp")
    process.arguments = ["-f", sourceURL.path, temporaryURL.path]
    process.standardInput = FileHandle.nullDevice
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let result = try await AsyncProcessRunner.run(
      process: process,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe,
      options: AsyncProcessRunnerOptions(
        timeout: 120,
        timeoutDescription: "log file export",
        maxOutputSize: 1024 * 1024
      )
    )
    guard result.exitCode == 0 else {
      throw StatusBarError.logCopyFailed(
        exitCode: result.exitCode,
        output: processOutput(result)
      )
    }
    try promoteExport(at: temporaryURL, to: destinationURL)
  }

  @concurrent private nonisolated static func archiveLogs(
    _ sourceURLs: [URL],
    to destinationURL: URL
  ) async throws {
    guard sourceURLs.isEmpty == false else {
      throw StatusBarError.logArchivePreparationFailed("No log files were selected")
    }
    for sourceURL in sourceURLs {
      guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL else {
        throw StatusBarError.invalidLogDestination(destinationURL.path)
      }
      try validateLogFile(sourceURL)
    }

    let stagingRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("jeballto-log-export-\(UUID().uuidString)", isDirectory: true)
    let stagingDirectory = stagingRoot.appendingPathComponent("Jeballto Logs", isDirectory: true)
    do {
      try FileManager.default.createDirectory(
        at: stagingDirectory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      for sourceURL in sourceURLs {
        let stagedURL = stagingDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
      }
    } catch {
      try? FileManager.default.removeItem(at: stagingRoot)
      throw StatusBarError.logArchivePreparationFailed(error.localizedDescription)
    }
    defer { try? FileManager.default.removeItem(at: stagingRoot) }

    let temporaryURL = temporaryExportURL(for: destinationURL)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--sequesterRsrc", stagingDirectory.path, temporaryURL.path]
    process.standardInput = FileHandle.nullDevice
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let result = try await AsyncProcessRunner.run(
      process: process,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe,
      options: AsyncProcessRunnerOptions(
        timeout: 120,
        timeoutDescription: "log archive export",
        maxOutputSize: 1024 * 1024
      )
    )
    guard result.exitCode == 0 else {
      throw StatusBarError.logArchiveFailed(
        exitCode: result.exitCode,
        output: processOutput(result)
      )
    }
    try promoteExport(at: temporaryURL, to: destinationURL)
  }

  private nonisolated static func validateLogFile(_ url: URL) throws {
    let name = url.lastPathComponent
    guard name.hasPrefix("agent-"), name.hasSuffix(".log") else {
      throw StatusBarError.logFileUnavailable(url.path, "The file name is not a Jeballto agent log")
    }
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      throw StatusBarError.logFileUnavailable(url.path, String(cString: strerror(errno)))
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
      throw StatusBarError.logFileUnavailable(
        url.path,
        "The path is not a regular file; symbolic links and special files are refused"
      )
    }
  }

  private nonisolated static func temporaryExportURL(for destinationURL: URL) -> URL {
    destinationURL.deletingLastPathComponent()
      .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
  }

  private nonisolated static func promoteExport(at temporaryURL: URL, to destinationURL: URL) throws {
    do {
      if FileManager.default.fileExists(atPath: destinationURL.path) {
        _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
      } else {
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
      }
    } catch {
      throw StatusBarError.logExportPromotionFailed(destinationURL.path, error.localizedDescription)
    }
  }

  private nonisolated static func processOutput(_ result: ProcessExecutionResult) -> String {
    let data = result.stderr.isEmpty ? result.stdout : result.stderr
    let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    let suffix = result.stderr.isEmpty ? result.stdoutTruncated : result.stderrTruncated
    let description = output.isEmpty ? "No error output" : output
    return suffix ? "\(description) (output truncated)" : description
  }

  @objc private func showAbout() {
    let alert = NSAlert()
    alert.messageText = "Jeballto VM Agent"

    alert.informativeText =
      "Version: \(AppVersion.marketing)\n\nA headless macOS virtual machine manager for Apple Silicon."

    alert.alertStyle = .informational

    alert.icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    alert.addButton(withTitle: "OK")

    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  @objc private func stopApp() {
    logInfo("Stop requested from status bar menu", category: "StatusBar")
    NSApp.terminate(nil)
  }

  // MARK: - Helpers

  private func formatUptime(_ totalSeconds: Int) -> String {
    let days = totalSeconds / 86400
    let hours = (totalSeconds % 86400) / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if days > 0 {
      return "\(days)d \(hours)h"
    } else if hours > 0 {
      return "\(hours)h \(minutes)m"
    } else if minutes > 0 {
      return "\(minutes)m \(seconds)s"
    } else {
      return "\(seconds)s"
    }
  }
}

private enum StatusBarError: Error, LocalizedError {
  case invalidLogDestination(String)
  case logFileUnavailable(String, String)
  case logCopyFailed(exitCode: Int32, output: String)
  case logArchivePreparationFailed(String)
  case logArchiveFailed(exitCode: Int32, output: String)
  case logExportPromotionFailed(String, String)

  var errorDescription: String? {
    switch self {
    case .invalidLogDestination(let path):
      "Refusing to replace an active log file at \(path)"
    case .logFileUnavailable(let path, let reason):
      "Log file is unavailable at \(path): \(reason)"
    case .logCopyFailed(let exitCode, let output):
      "Log copy process exited with status \(exitCode): \(output)"
    case .logArchivePreparationFailed(let reason):
      "Failed to prepare selected logs for export: \(reason)"
    case .logArchiveFailed(let exitCode, let output):
      "Log archive process exited with status \(exitCode): \(output)"
    case .logExportPromotionFailed(let path, let reason):
      "Failed to save exported logs at \(path): \(reason)"
    }
  }
}
