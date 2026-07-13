import Darwin
import Foundation

struct SystemResetEnvironment: Sendable {
  let appSupportDirectory: String
  let defaultLogDirectory: String
  let cacheRoot: URL
  let deleteSecrets: @Sendable () async throws -> Void
  let terminate: @Sendable () -> Void

  static let live = SystemResetEnvironment(
    appSupportDirectory: NSHomeDirectory() + "/Library/Application Support/Jeballto",
    defaultLogDirectory: NSHomeDirectory() + "/Library/Logs/Jeballto",
    cacheRoot: JeballtoCachePaths.root,
    deleteSecrets: {
      try await RegistryCredentialStore.shared.deleteAllCredentials()
      try await APISecretStore.shared.deleteToken()
    },
    terminate: {
      exit(0)
    }
  )
}

// MARK: - System Route Handlers

extension APIServer {
  func handleSystemReset(_ request: HTTPRequest) async -> HTTPResponse {
    let confirmed: Bool
    do {
      confirmed = try HTTPQueryParameters.requiredTrue(named: "confirm", in: request)
    } catch {
      return invalidQueryParameter(error)
    }
    guard confirmed else {
      return HTTPResponse.error(
        "CONFIRMATION_REQUIRED",
        message: "Add ?confirm=true to confirm system reset",
        statusCode: 400
      )
    }

    guard let body = request.body else {
      return APIRouteErrorMapper.missingBody()
    }

    let resetRequest: SystemResetRequest
    do { resetRequest = try JSONDecoder().decode(SystemResetRequest.self, from: body) } catch {
      return APIRouteErrorMapper.invalidRequest("Invalid request body: \(error.localizedDescription)")
    }

    let validation = resetRequest.validate()
    guard validation.valid else {
      return HTTPResponse.error("INVALID_REQUEST", message: validation.error ?? "Invalid request", statusCode: 400)
    }

    guard await beginExclusiveMaintenance() else {
      return HTTPResponse.error(
        "MAINTENANCE_IN_PROGRESS",
        message: "Another destructive maintenance operation is already running",
        statusCode: 409
      )
    }
    await cancelActiveImageOperations()
    await cancelAllJeballtofileExecutors()
    _ = await vmManager.cancelAllInstallations()
    await waitForActiveMutationsToDrain()

    switch resetRequest.mode {
    case "soft":
      let response = await performSoftReset()
      await endExclusiveMaintenance()
      return response
    case "hard":
      return await performHardReset()
    default:
      await endExclusiveMaintenance()
      return HTTPResponse.error("INVALID_REQUEST", message: "Invalid mode", statusCode: 400)
    }
  }

  // MARK: - Soft Reset

  private func performSoftReset() async -> HTTPResponse {
    var errors: [String] = []
    await cancelActiveImageOperations()
    await cancelAllJeballtofileExecutors()

    // 1. Wipe all VMs (force-stop + delete)
    var vmsDeleted = 0
    var vmsFailed = 0
    do {
      let result = try await vmManager.wipeAllVMs()
      vmsDeleted = result.deleted
      vmsFailed = result.failed
      errors.append(contentsOf: result.errors)
    } catch {
      vmsFailed = 1
      errors.append("VM wipe failed: \(error.localizedDescription)")
    }

    // 2. Wipe all images
    let imageResult = await imageManager.wipeAllImages()
    let imagesDeleted = imageResult.deleted
    let imagesFailed = imageResult.failed
    errors.append(contentsOf: imageResult.errors)

    // 3. Clear IPSW cache
    let ipswCacheCleared = clearIPSWCache(&errors)

    let response = SystemResetResponse(
      mode: "soft",
      vmsDeleted: vmsDeleted,
      vmsFailed: vmsFailed,
      imagesDeleted: imagesDeleted,
      imagesFailed: imagesFailed,
      ipswCacheCleared: ipswCacheCleared,
      configDeleted: false,
      logsDeleted: false,
      willTerminate: false,
      errors: errors.isEmpty ? nil : errors
    )
    return HTTPResponse.json(response)
  }

  // MARK: - Hard Reset

  private func performHardReset() async -> HTTPResponse {
    var errors: [String] = []
    await cancelActiveImageOperations()
    await cancelAllJeballtofileExecutors()

    // 1. Wipe all VMs (force-stop + delete)
    var vmsDeleted = 0
    var vmsFailed = 0
    do {
      let result = try await vmManager.wipeAllVMs()
      vmsDeleted = result.deleted
      vmsFailed = result.failed
      errors.append(contentsOf: result.errors)
    } catch {
      vmsFailed = 1
      errors.append("VM wipe failed: \(error.localizedDescription)")
    }

    // 2. Wipe all images
    let imageResult = await imageManager.wipeAllImages()
    let imagesDeleted = imageResult.deleted
    let imagesFailed = imageResult.failed
    errors.append(contentsOf: imageResult.errors)

    guard vmsFailed == 0, imagesFailed == 0 else {
      errors.append(
        "Hard reset stopped before deleting configuration because one or more managed resources could not be removed"
      )
      let response = SystemResetResponse(
        mode: "hard",
        vmsDeleted: vmsDeleted,
        vmsFailed: vmsFailed,
        imagesDeleted: imagesDeleted,
        imagesFailed: imagesFailed,
        ipswCacheCleared: false,
        configDeleted: false,
        logsDeleted: false,
        willTerminate: false,
        errors: errors
      )
      await endExclusiveMaintenance()
      return HTTPResponse.json(response, statusCode: 500)
    }

    // 3. Close file logging before deleting log files
    Logger.shared.enableFileLogging = false

    // 4. Remove application-owned data
    let appSupportDir = systemResetEnvironment.appSupportDirectory
    let defaultLogDir = systemResetEnvironment.defaultLogDirectory
    let configuredLogDir = config.logging.logDirectory

    let ipswCacheCleared = Self.clearOwnedCacheDirectories(
      root: systemResetEnvironment.cacheRoot,
      imageWorkSession: imageManager.imageWorkSessionForMaintenance,
      errors: &errors
    )

    Self.clearApplicationSupportContents(
      at: appSupportDir,
      preserving: ["agent.lock"],
      errors: &errors
    )

    removeManagedDataFiles(&errors)
    removeManagedDirectoryIfEmpty(config.storage.vmStorageDir, errors: &errors)
    removeManagedDirectoryIfEmpty(config.images.imageStorageDir, errors: &errors)

    let configDeleted = removeConfigFile(&errors)
    let logsDeleted = Self.clearLogFiles(
      in: Set([defaultLogDir, configuredLogDir]),
      errors: &errors
    )
    var secretsDeleted = false
    if errors.isEmpty, ipswCacheCleared, configDeleted, logsDeleted {
      do {
        try await systemResetEnvironment.deleteSecrets()
        secretsDeleted = true
      } catch {
        errors.append("Failed to delete credentials from Keychain: \(error.localizedDescription)")
      }
    }
    let willTerminate = errors.isEmpty && secretsDeleted

    let response = SystemResetResponse(
      mode: "hard",
      vmsDeleted: vmsDeleted,
      vmsFailed: vmsFailed,
      imagesDeleted: imagesDeleted,
      imagesFailed: imagesFailed,
      ipswCacheCleared: ipswCacheCleared,
      configDeleted: configDeleted,
      logsDeleted: logsDeleted,
      willTerminate: willTerminate,
      errors: errors.isEmpty ? nil : errors
    )

    guard willTerminate else {
      Logger.shared.configure(with: config.logging)
      await endExclusiveMaintenance()
      return HTTPResponse.json(response, statusCode: 500)
    }

    // Exit only from the HTTP send completion. NSApp.terminate would try to save VMs into
    // directories that hard reset just removed.
    let terminate = systemResetEnvironment.terminate
    return HTTPResponse.json(response).afterSending {
      terminate()
    }
  }

  // MARK: - Helpers

  private func clearIPSWCache(_ errors: inout [String]) -> Bool {
    clearCacheDirectory(JeballtoCachePaths.ipswCache, label: "IPSW", errors: &errors)
  }

  private func clearCacheDirectory(_ cacheDir: URL, label: String, errors: inout [String]) -> Bool {
    guard Self.filesystemEntryExists(at: cacheDir.path) else { return true }

    do {
      try FileManager.default.removeItem(at: cacheDir)
      return true
    } catch {
      errors.append("Failed to clear \(label) cache: \(error.localizedDescription)")
      return false
    }
  }

  static func clearOwnedCacheDirectories(
    root: URL,
    imageWorkSession: URL,
    errors: inout [String]
  ) -> Bool {
    let fileManager = FileManager.default
    switch traversalDirectoryState(at: root.path, label: "cache root", errors: &errors) {
    case .missing:
      return true
    case .unsafe:
      return false
    case .directory:
      break
    }
    var ipswCleared = true
    let ipswDirectory = root.appendingPathComponent("IPSWCache", isDirectory: true)
    if filesystemEntryExists(at: ipswDirectory.path) {
      do {
        try fileManager.removeItem(at: ipswDirectory)
      } catch {
        ipswCleared = false
        errors.append("Failed to clear IPSW cache: \(error.localizedDescription)")
      }
    }

    let imageWorkRoot = root.appendingPathComponent("ImageWork", isDirectory: true)
    errors.append(contentsOf: ImageManager.cleanupImageWorkForMaintenance(
      imageWorkRoot: imageWorkRoot,
      ownedSessionURL: imageWorkSession
    ))

    if let contents = try? fileManager.contentsOfDirectory(atPath: root.path), contents.isEmpty {
      try? fileManager.removeItem(at: root)
    }
    return ipswCleared
  }

  static func clearApplicationSupportContents(
    at directory: String,
    preserving preservedNames: Set<String>,
    errors: inout [String]
  ) {
    let normalized = (directory as NSString).standardizingPath
    guard normalized != "/", normalized != NSHomeDirectory() else {
      errors.append("Refusing to clear unsafe application directory: \(directory)")
      return
    }
    guard traversalDirectoryState(
      at: normalized,
      label: "application support directory",
      errors: &errors
    ) == .directory else { return }

    let entries: [String]
    do {
      entries = try FileManager.default.contentsOfDirectory(atPath: normalized)
    } catch {
      errors.append("Failed to inspect \(normalized): \(error.localizedDescription)")
      return
    }
    for entry in entries where preservedNames.contains(entry) == false {
      do {
        let path = URL(fileURLWithPath: normalized, isDirectory: true)
          .appendingPathComponent(entry, isDirectory: false)
        try FileManager.default.removeItem(at: path)
      } catch {
        errors.append("Failed to remove \(entry) from \(normalized): \(error.localizedDescription)")
      }
    }
  }

  private func removeManagedDataFiles(_ errors: inout [String]) {
    for path in [
      config.storage.databasePath,
      config.storage.databasePath + ".bak",
      config.storage.imageIndexPath,
      config.storage.imageIndexPath + ".bak",
    ] {
      var status = stat()
      let result = path.withCString { Darwin.lstat($0, &status) }
      if result != 0 {
        guard errno == ENOENT else {
          errors.append("Failed to inspect managed data file \(path): \(Self.posixMessage())")
          continue
        }
        continue
      }
      guard status.st_mode & S_IFMT != S_IFDIR else {
        errors.append("Refusing to remove managed data file because it is a directory: \(path)")
        continue
      }
      do {
        try FileManager.default.removeItem(atPath: path)
      } catch {
        errors.append("Failed to remove managed data file \(path): \(error.localizedDescription)")
      }
    }
  }

  private func removeManagedDirectoryIfEmpty(_ path: String, errors: inout [String]) {
    guard Self.traversalDirectoryState(at: path, label: "managed directory", errors: &errors) == .directory else {
      return
    }
    do {
      guard try FileManager.default.contentsOfDirectory(atPath: path).isEmpty else { return }
      try FileManager.default.removeItem(atPath: path)
    } catch {
      errors.append("Failed to remove empty managed directory \(path): \(error.localizedDescription)")
    }
  }

  private func removeConfigFile(_ errors: inout [String]) -> Bool {
    var status = stat()
    let result = configPath.withCString { Darwin.lstat($0, &status) }
    if result != 0 {
      guard errno == ENOENT else {
        errors.append("Failed to inspect config file \(configPath): \(Self.posixMessage())")
        return false
      }
      return true
    }
    guard status.st_mode & S_IFMT != S_IFDIR else {
      errors.append("Refusing to remove config path because it is a directory: \(configPath)")
      return false
    }

    do {
      try FileManager.default.removeItem(atPath: configPath)
      return true
    } catch {
      errors.append("Failed to remove config file \(configPath): \(error.localizedDescription)")
      return false
    }
  }

  static func clearLogFiles(in directories: Set<String>, errors: inout [String]) -> Bool {
    var succeeded = true
    for directory in directories {
      switch traversalDirectoryState(at: directory, label: "log directory", errors: &errors) {
      case .missing:
        continue
      case .unsafe:
        succeeded = false
        continue
      case .directory:
        break
      }
      let entries: [String]
      do {
        entries = try FileManager.default.contentsOfDirectory(atPath: directory)
      } catch {
        succeeded = false
        errors.append("Failed to inspect log directory \(directory): \(error.localizedDescription)")
        continue
      }
      for entry in entries where Self.isAgentLogFile(entry) {
        let path = "\(directory)/\(entry)"
        var status = stat()
        guard path.withCString({ Darwin.lstat($0, &status) }) == 0 else {
          succeeded = false
          errors.append("Failed to inspect log entry \(path): \(Self.posixMessage())")
          continue
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
          succeeded = false
          errors.append("Refusing to delete unsafe log entry because it is not a regular file: \(path)")
          continue
        }
        do {
          try FileManager.default.removeItem(atPath: path)
        } catch {
          succeeded = false
          errors.append("Failed to delete log entry \(path): \(error.localizedDescription)")
        }
      }
    }
    return succeeded
  }

  private enum TraversalDirectoryState {
    case missing
    case directory
    case unsafe
  }

  private static func traversalDirectoryState(
    at path: String,
    label: String,
    errors: inout [String]
  ) -> TraversalDirectoryState {
    let standardizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    let resolvedPath = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath().path
    guard standardizedPath == resolvedPath else {
      errors.append("Refusing to traverse \(label) because its path contains a symbolic link: \(path)")
      return .unsafe
    }
    var status = stat()
    let result = path.withCString { Darwin.lstat($0, &status) }
    if result != 0 {
      guard errno == ENOENT else {
        errors.append("Failed to inspect \(label) \(path): \(posixMessage())")
        return .unsafe
      }
      return .missing
    }
    guard status.st_mode & S_IFMT == S_IFDIR else {
      errors.append("Refusing to traverse \(label) because it is not a real directory: \(path)")
      return .unsafe
    }
    return .directory
  }

  private static func filesystemEntryExists(at path: String) -> Bool {
    var status = stat()
    return path.withCString { Darwin.lstat($0, &status) } == 0
  }

  private static func posixMessage(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
  }

  static func isAgentLogFile(_ name: String) -> Bool {
    if name == "agent.log" || name == "agent.log.1" { return true }
    guard name.hasPrefix("agent-"), name.hasSuffix(".log") else { return false }
    let dateText = String(name.dropFirst("agent-".count).dropLast(".log".count))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: dateText) else { return false }
    return formatter.string(from: date) == dateText
  }
}
