import Foundation

// MARK: - System Route Handlers

extension APIServer {
  func handleSystemReset(_ request: HTTPRequest) async -> HTTPResponse {
    guard request.queryParameters["confirm"] == "true" else {
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

    switch resetRequest.mode {
    case "soft":
      return await performSoftReset()
    case "hard":
      return await performHardReset()
    default:
      return HTTPResponse.error("INVALID_REQUEST", message: "Invalid mode", statusCode: 400)
    }
  }

  // MARK: - Soft Reset

  private func performSoftReset() async -> HTTPResponse {
    var errors: [String] = []

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

    // 3. Close file logging before deleting log files
    Logger.shared.enableFileLogging = false

    // 4. Remove all application directories
    let appSupportDir = NSHomeDirectory() + "/Library/Application Support/Jeballto"
    let cacheDir = NSHomeDirectory() + "/Library/Caches/Jeballto"
    let logDir = NSHomeDirectory() + "/Library/Logs/Jeballto"

    var configDeleted = false
    var logsDeleted = false

    for dir in [appSupportDir, cacheDir, logDir] {
      do {
        if FileManager.default.fileExists(atPath: dir) {
          try FileManager.default.removeItem(atPath: dir)
        }
        if dir == appSupportDir { configDeleted = true }
        if dir == logDir { logsDeleted = true }
      } catch {
        errors.append("Failed to remove \(dir): \(error.localizedDescription)")
      }
    }

    let response = SystemResetResponse(
      mode: "hard",
      vmsDeleted: vmsDeleted,
      vmsFailed: vmsFailed,
      imagesDeleted: imagesDeleted,
      imagesFailed: imagesFailed,
      ipswCacheCleared: true,
      configDeleted: configDeleted,
      logsDeleted: logsDeleted,
      willTerminate: true,
      errors: errors.isEmpty ? nil : errors
    )

    // Schedule process exit after response is flushed. We use exit(0) directly
    // rather than NSApp.terminate because applicationShouldTerminate would try
    // to save VMs to directories we just deleted, causing it to hang.
    Task.detached {
      try? await Task.sleep(nanoseconds: 500_000_000)
      exit(0)
    }

    return HTTPResponse.json(response)
  }

  // MARK: - Helpers

  private func clearIPSWCache(_ errors: inout [String]) -> Bool {
    let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Jeballto/IPSWCache")

    guard FileManager.default.fileExists(atPath: cacheDir.path) else { return true }

    do {
      try FileManager.default.removeItem(at: cacheDir)
      return true
    } catch {
      errors.append("Failed to clear IPSW cache: \(error.localizedDescription)")
      return false
    }
  }
}
