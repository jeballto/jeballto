import Foundation

// MARK: - Health, SSH, VNC, GUI, State, Events, Config Route Handlers

extension APIServer {
  // MARK: - Health

  func handleHealth() async -> HTTPResponse {
    let uptime = Int(Date().timeIntervalSince(startTime))
    let health = await HealthResponse(
      vmsTotal: vmManager.vmCount(),
      vmsRunning: vmManager.runningVMCount(),
      uptime: uptime
    )
    return HTTPResponse.json(health)
  }

  // MARK: - Capabilities

  func handleSystemCapabilities() async -> HTTPResponse {
    HTTPResponse.json(SystemCapabilitiesResponse(capabilities: capabilityProvider()))
  }

  // MARK: - SSH

  func handleGetSSH(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    do {
      let definition = try await vmManager.getVM(vmId)

      let state = try await vmManager.getVMState(vmId)
      guard state != .created, state != .installing else {
        return HTTPResponse.error(
          "INVALID_STATE",
          message: "VM must be installed before SSH can be used (current: \(state.rawValue))",
          statusCode: 409
        )
      }

      guard let sshPort = definition.network.sshPort else {
        return HTTPResponse.error("SSH_NOT_CONFIGURED", message: "SSH port not configured for this VM", statusCode: 404)
      }

      let proxyAlive = await portForwardingManager.isSSHForwardingActive(vmId: vmId)
      let status = proxyAlive ? "ready" : "unavailable"
      let response = SSHInfoResponse(host: "127.0.0.1", port: sshPort, status: status)
      return HTTPResponse.json(response)
    } catch { return HTTPResponse.error("NOT_FOUND", message: "VM not found", statusCode: 404) }
  }

  func handleEnableSSH(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }
    if let response = requireCapability(.portForwarding) { return response }

    do {
      var definition = try await vmManager.getVM(vmId)

      let state = try await vmManager.getVMState(vmId)
      guard state == .running else {
        return HTTPResponse.error(
          "INVALID_STATE",
          message: "VM must be RUNNING to enable SSH forwarding (current: \(state.rawValue))",
          statusCode: 409
        )
      }

      // Wait for any pending auto-enable networking task to finish, then re-read definition.
      // This prevents a race where auto-enable allocates port 2222 and this endpoint
      // allocates port 2223 because it read the definition before auto-enable persisted.
      await vmManager.awaitNetworkingSetup(vmId)
      definition = try await vmManager.getVM(vmId)

      if let existingPort = definition.network.sshPort {
        // Verify the TCP proxy is actually running (it may have died)
        if await portForwardingManager.isSSHForwardingActive(vmId: vmId) {
          let response = SSHInfoResponse(host: "127.0.0.1", port: existingPort)
          return HTTPResponse.json(response)
        }
        // Proxy is dead - clean up stale state and re-create below
        await portForwardingManager.releasePort(existingPort)
        var cleaned = definition
        cleaned.clearSSHPort()
        try await updateVMDefinition(vmId, definition: cleaned)
      }

      var natIP = definition.network.natIP
      if natIP == nil {
        natIP = await vmManager.ensureNATIP(vmId)
        if natIP != nil {
          definition = try await vmManager.getVM(vmId)
        }
      }
      guard let natIP else {
        return HTTPResponse.error(
          "SSH_ENABLE_FAILED",
          message: "VM has no NAT IP address, wait for the VM to fully boot and retry",
          statusCode: 409
        )
      }

      guard let sshPort = await portForwardingManager.allocatePort() else {
        return HTTPResponse.error(
          "SSH_ENABLE_FAILED",
          message: "No available SSH ports in configured range",
          statusCode: 503
        )
      }

      do {
        try await portForwardingManager.setupSSHForwarding(vmId: vmId, vmIPAddress: natIP, sshPort: sshPort)
        await vmManager.startSSHReadinessProbe(vmId: vmId, sshPort: sshPort)
      } catch {
        await portForwardingManager.releasePort(sshPort)
        return HTTPResponse.error("SSH_ENABLE_FAILED", message: error.localizedDescription, statusCode: 500)
      }

      var updated = definition
      updated.updateSSHPort(sshPort)
      try await updateVMDefinition(vmId, definition: updated)

      let response = SSHInfoResponse(host: "127.0.0.1", port: sshPort)
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "SSH_ENABLE_FAILED")
    } catch { return HTTPResponse.error("SSH_ENABLE_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleDisableSSH(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    do {
      let definition = try await vmManager.getVM(vmId)

      let state = try await vmManager.getVMState(vmId)
      guard state != .created, state != .installing else {
        return HTTPResponse.error(
          "INVALID_STATE",
          message: "VM must be installed before SSH can be managed (current: \(state.rawValue))",
          statusCode: 409
        )
      }

      await portForwardingManager.stopSSHForwarding(vmId: vmId)

      if let sshPort = definition.network.sshPort {
        await portForwardingManager.releasePort(sshPort)
        eventBus.publish(.sshPortReleased(vmId: vmId))
      }

      var updated = definition
      updated.clearSSHPort()
      try await updateVMDefinition(vmId, definition: updated)

      let response = SSHInfoResponse(host: "127.0.0.1", port: nil, status: "disabled")
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "SSH_DISABLE_FAILED")
    } catch { return HTTPResponse.error("SSH_DISABLE_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  // MARK: - VNC

  func handleEnableVNC(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }
    if let response = requireCapability(.portForwarding) { return response }

    do {
      var definition = try await vmManager.getVM(vmId)

      let state = try await vmManager.getVMState(vmId)
      guard state == .running else {
        return HTTPResponse.error(
          "INVALID_STATE",
          message: "VM must be RUNNING to enable VNC forwarding (current: \(state.rawValue))",
          statusCode: 409
        )
      }

      // Idempotent: if VNC is already enabled, return current info
      if let existingPort = definition.network.vncPort {
        // Verify the TCP proxy is actually running (it may have died)
        if await portForwardingManager.isVNCForwardingActive(vmId: vmId) {
          let response = VNCInfoResponse(port: existingPort)
          return HTTPResponse.json(response)
        }
        // Proxy is dead - clean up stale state and re-create below
        await portForwardingManager.releaseVNCPort(existingPort)
        var cleaned = definition
        cleaned.clearVNCPort()
        try await updateVMDefinition(vmId, definition: cleaned)
      }

      var natIP = definition.network.natIP
      if natIP == nil {
        natIP = await vmManager.ensureNATIP(vmId)
        if natIP != nil {
          definition = try await vmManager.getVM(vmId)
        }
      }
      guard let natIP else {
        return HTTPResponse.error(
          "VNC_ENABLE_FAILED",
          message: "VM has no NAT IP address, cannot set up VNC forwarding",
          statusCode: 409
        )
      }

      guard let vncPort = await portForwardingManager.allocateVNCPort() else {
        return HTTPResponse.error(
          "VNC_ENABLE_FAILED",
          message: "No available VNC ports in configured range",
          statusCode: 503
        )
      }

      do {
        try await portForwardingManager.setupVNCForwarding(vmId: vmId, vmIPAddress: natIP, vncPort: vncPort)
      } catch {
        await portForwardingManager.releaseVNCPort(vncPort)
        return HTTPResponse.error("VNC_ENABLE_FAILED", message: error.localizedDescription, statusCode: 500)
      }

      var updated = definition
      updated.updateVNCPort(vncPort)
      try await updateVMDefinition(vmId, definition: updated)

      let response = VNCInfoResponse(port: vncPort)
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "VNC_ENABLE_FAILED")
    } catch { return HTTPResponse.error("VNC_ENABLE_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleDisableVNC(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    do {
      let definition = try await vmManager.getVM(vmId)

      let state = try await vmManager.getVMState(vmId)
      guard state != .created, state != .installing else {
        return HTTPResponse.error(
          "INVALID_STATE",
          message: "VM must be installed before VNC can be managed (current: \(state.rawValue))",
          statusCode: 409
        )
      }

      await portForwardingManager.stopVNCForwarding(vmId: vmId)

      if let vncPort = definition.network.vncPort {
        await portForwardingManager.releaseVNCPort(vncPort)
        eventBus.publish(.vncPortReleased(vmId: vmId))
      }

      var updated = definition
      updated.clearVNCPort()
      try await updateVMDefinition(vmId, definition: updated)

      let response = VNCInfoResponse(host: "127.0.0.1", port: nil, status: "disabled")
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "VNC_DISABLE_FAILED")
    } catch { return HTTPResponse.error("VNC_DISABLE_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleGetVNC(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    do {
      let definition = try await vmManager.getVM(vmId)

      let state = try await vmManager.getVMState(vmId)
      guard state != .created, state != .installing else {
        return HTTPResponse.error(
          "INVALID_STATE",
          message: "VM must be installed before VNC can be used (current: \(state.rawValue))",
          statusCode: 409
        )
      }

      guard let vncPort = definition.network.vncPort else {
        return HTTPResponse.error(
          "VNC_NOT_CONFIGURED",
          message: "VNC forwarding not enabled for this VM",
          statusCode: 404
        )
      }

      let proxyAlive = await portForwardingManager.isVNCForwardingActive(vmId: vmId)
      let status = proxyAlive ? "ready" : "unavailable"
      let response = VNCInfoResponse(port: vncPort, status: status)
      return HTTPResponse.json(response)
    } catch { return HTTPResponse.error("NOT_FOUND", message: "VM not found", statusCode: 404) }
  }

  // MARK: - State & Events

  func handleGetState(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    do {
      let state = try await vmManager.getVMState(vmId)
      let uptime = try? await vmManager.getVMUptime(vmId)
      let response = VMStateResponse(state: state, uptime: uptime ?? nil)
      return HTTPResponse.json(response)
    } catch { return HTTPResponse.error("NOT_FOUND", message: "VM not found", statusCode: 404) }
  }

  func handleGetEvents(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    // Verify VM exists
    do {
      _ = try await vmManager.getVM(vmId)
    } catch let error as VMManagerError {
      switch error {
      case .vmNotFound: return HTTPResponse.error("NOT_FOUND", message: "VM not found", statusCode: 404)
      default: return HTTPResponse.error("EVENTS_FAILED", message: error.localizedDescription, statusCode: 500)
      }
    } catch { return HTTPResponse.error("EVENTS_FAILED", message: error.localizedDescription, statusCode: 500) }

    let requestedLimit = Int(request.queryParameters["limit"] ?? "100") ?? 100
    let limit = max(1, min(requestedLimit, 1000))

    let events = eventBus.getEvents(forVM: vmId, limit: limit)
    let response = EventListResponse(events: events)
    return HTTPResponse.json(response)
  }

  // MARK: - GUI

  func handleOpenGUI(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }
    if let response = requireCapability(.guiDisplay) { return response }

    do {
      try await vmManager.openGUI(vmId)
      let guiOpen = await vmManager.isGUIOpen(vmId)
      let response = GUIStatusResponse(vmId: vmId, guiOpen: guiOpen)
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "GUI_OPEN_FAILED")
    } catch { return HTTPResponse.error("GUI_OPEN_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleCloseGUI(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    do {
      try await vmManager.closeGUI(vmId)
      let guiOpen = await vmManager.isGUIOpen(vmId)
      let response = GUIStatusResponse(vmId: vmId, guiOpen: guiOpen)
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "GUI_CLOSE_FAILED")
    } catch { return HTTPResponse.error("GUI_CLOSE_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleGetGUIStatus(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    // Verify VM exists
    do {
      _ = try await vmManager.getVM(vmId)
    } catch let error as VMManagerError {
      switch error {
      case .vmNotFound: return HTTPResponse.error("NOT_FOUND", message: "VM not found", statusCode: 404)
      default: return HTTPResponse.error("GUI_STATUS_FAILED", message: error.localizedDescription, statusCode: 500)
      }
    } catch { return HTTPResponse.error("GUI_STATUS_FAILED", message: error.localizedDescription, statusCode: 500) }

    let guiOpen = await vmManager.isGUIOpen(vmId)
    let response = GUIStatusResponse(vmId: vmId, guiOpen: guiOpen)
    return HTTPResponse.json(response)
  }

  // MARK: - Auth

  func handleVerifyAuth() async -> HTTPResponse {
    HTTPResponse.json(["status": "ok"])
  }

  // MARK: - Config

  func handleGetConfig() async -> HTTPResponse {
    HTTPResponse.json(ConfigResponse(from: config))
  }

  func handleUpdateConfig(_ request: HTTPRequest) async -> HTTPResponse {
    guard let body = request.body else {
      return APIRouteErrorMapper.missingBody()
    }

    let updateRequest: UpdateConfigRequest
    do { updateRequest = try JSONDecoder().decode(UpdateConfigRequest.self, from: body) } catch {
      return APIRouteErrorMapper.invalidJSON(error)
    }

    let validation = updateRequest.validate(currentConfig: config.networking)
    guard validation.valid else {
      return HTTPResponse.error("INVALID_REQUEST", message: validation.error ?? "Invalid request", statusCode: 400)
    }

    let newConfig = updatedConfig(from: updateRequest)

    // Persist to disk first - only update in-memory state on success
    do {
      try newConfig.save()
      config = newConfig
    } catch {
      return HTTPResponse.error("CONFIG_UPDATE_FAILED", message: error.localizedDescription, statusCode: 500)
    }

    await imageManager.updateConfiguration(newConfig)
    applyLoggingRuntimeUpdates(updateRequest.logging)

    logInfo("Configuration updated via API", category: "APIServer")
    return HTTPResponse.json(ConfigResponse(from: config))
  }

  private func updatedConfig(from updateRequest: UpdateConfigRequest) -> Config {
    var newConfig = config
    applyLoggingUpdate(updateRequest.logging, to: &newConfig)
    applyNetworkingUpdate(updateRequest.networking, to: &newConfig)
    applyImageUpdate(updateRequest.images, to: &newConfig)
    return newConfig
  }

  private func applyLoggingUpdate(_ logging: LoggingConfigUpdate?, to config: inout Config) {
    guard let logging else { return }
    if let level = logging.level { config.logging.level = level }
    if let retentionDays = logging.retentionDays { config.logging.retentionDays = retentionDays }
    if let maxTotalSize = logging.maxTotalSize { config.logging.maxTotalSize = maxTotalSize }
    if let tz = logging.timezone { config.logging.timezone = tz }
  }

  private func applyNetworkingUpdate(_ networking: NetworkingConfigUpdate?, to config: inout Config) {
    guard let networking else { return }
    if let start = networking.sshPortRangeStart { config.networking.sshPortRangeStart = start }
    if let end = networking.sshPortRangeEnd { config.networking.sshPortRangeEnd = end }
    if let auto = networking.autoEnableSSHForwarding { config.networking.autoEnableSSHForwarding = auto }
    if let start = networking.vncPortRangeStart { config.networking.vncPortRangeStart = start }
    if let end = networking.vncPortRangeEnd { config.networking.vncPortRangeEnd = end }
  }

  private func applyImageUpdate(_ images: ImageConfigUpdate?, to config: inout Config) {
    guard let images else { return }
    if let registry = images.defaultRegistry { config.images.defaultRegistry = registry }
    if let insecure = images.insecureRegistries { config.images.insecureRegistries = insecure }
    if let maxParallelImageBlobTransfers = images.maxParallelImageBlobTransfers {
      config.images.maxParallelImageBlobTransfers = maxParallelImageBlobTransfers
    }
    if let maxParallelImageCompressions = images.maxParallelImageCompressions {
      config.images.maxParallelImageCompressions = maxParallelImageCompressions
    }
    if let maxParallelImageDecompressions = images.maxParallelImageDecompressions {
      config.images.maxParallelImageDecompressions = maxParallelImageDecompressions
    }
    if let maxParallelImageDiskWrites = images.maxParallelImageDiskWrites {
      config.images.maxParallelImageDiskWrites = maxParallelImageDiskWrites
    }
  }

  private func applyLoggingRuntimeUpdates(_ logging: LoggingConfigUpdate?) {
    guard let logging else { return }
    if let level = logging.level, let logLevel = LogLevel(rawValue: level.uppercased()) {
      Logger.shared.logLevel = logLevel
    }
    if let retentionDays = logging.retentionDays {
      Logger.shared.retentionDays = retentionDays
    }
    if let maxTotalSize = logging.maxTotalSize, let bytes = LoggingConfig.parseSize(maxTotalSize) {
      Logger.shared.maxTotalSizeBytes = bytes
    }
    if let tz = logging.timezone {
      Logger.shared.timezone = tz.flatMap(TimeZone.init(identifier:)) ?? .current
    }
  }
}
