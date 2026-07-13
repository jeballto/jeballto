import Foundation

// MARK: - Health, SSH, VNC, GUI, State, Events, Config Route Handlers

extension APIServer {
  // MARK: - Health

  func handleHealth() async -> HTTPResponse {
    do {
      let uptime = startUptime.map {
        max(0, Int(ProcessInfo.processInfo.systemUptime - $0))
      } ?? 0
      let health = try await HealthResponse(
        vmsTotal: vmManager.vmCount(),
        vmsRunning: vmManager.runningVMCount(),
        uptime: uptime
      )
      return HTTPResponse.json(health)
    } catch {
      return HTTPResponse.error("HEALTH_CHECK_FAILED", message: error.localizedDescription, statusCode: 500)
    }
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
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "SSH_STATUS_FAILED")
    } catch {
      return HTTPResponse.error("SSH_STATUS_FAILED", message: error.localizedDescription, statusCode: 500)
    }
  }

  func handleEnableSSH(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }
    if let response = requireCapability(.portForwarding) { return response }

    return await withExclusiveNetworkingOperation(
      vmId: vmId,
      operation: "enable SSH forwarding",
      errorCode: "SSH_ENABLE_FAILED"
    ) { await self.performEnableSSH(vmId) }
  }

  private func performEnableSSH(_ vmId: UUID) async -> HTTPResponse {
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
      try await vmManager.awaitNetworkingSetup(vmId)
      definition = try await vmManager.getVM(vmId)

      if let existingPort = definition.network.sshPort {
        if await portForwardingManager.isSSHForwardingActive(vmId: vmId) {
          let response = SSHInfoResponse(host: "127.0.0.1", port: existingPort)
          return HTTPResponse.json(response)
        }
        // The persisted reservation outlived its proxy. Release it before the
        // actor atomically chooses and starts a replacement.
        await portForwardingManager.releasePort(existingPort)
        try await vmManager.setSSHPort(nil, for: vmId)
        definition = try await vmManager.getVM(vmId)
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

      let sshPort: Int
      do {
        guard let allocatedPort = try await portForwardingManager.allocateAndSetupSSHForwarding(
          vmId: vmId,
          vmIPAddress: natIP
        ) else {
          return HTTPResponse.error(
            "SSH_ENABLE_FAILED",
            message: "No available SSH ports in configured range",
            statusCode: 503
          )
        }
        sshPort = allocatedPort
      } catch {
        return HTTPResponse.error("SSH_ENABLE_FAILED", message: error.localizedDescription, statusCode: 500)
      }

      do {
        try await vmManager.setSSHPort(sshPort, for: vmId)
      } catch {
        await portForwardingManager.stopSSHForwarding(vmId: vmId)
        throw error
      }
      await vmManager.startSSHReadinessProbe(vmId: vmId, sshPort: sshPort)

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

    return await withExclusiveNetworkingOperation(
      vmId: vmId,
      operation: "disable SSH forwarding",
      errorCode: "SSH_DISABLE_FAILED"
    ) { await self.performDisableSSH(vmId) }
  }

  private func performDisableSSH(_ vmId: UUID) async -> HTTPResponse {
    do {
      _ = try await vmManager.getVM(vmId)

      var state = try await vmManager.getVMState(vmId)
      guard state != .created, state != .installing else {
        return HTTPResponse.error(
          "INVALID_STATE",
          message: "VM must be installed before SSH can be managed (current: \(state.rawValue))",
          statusCode: 409
        )
      }

      await vmManager.cancelNetworkingSetup(vmId)

      state = try await vmManager.getVMState(vmId)
      guard state != .created, state != .installing else {
        return HTTPResponse.error(
          "INVALID_STATE",
          message: "VM must be installed before SSH can be managed (current: \(state.rawValue))",
          statusCode: 409
        )
      }
      let definition = try await vmManager.getVM(vmId)

      await portForwardingManager.stopSSHForwarding(vmId: vmId)

      if let sshPort = definition.network.sshPort {
        await portForwardingManager.releasePort(sshPort)
      }
      try await vmManager.setSSHPort(nil, for: vmId)

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

    return await withExclusiveNetworkingOperation(
      vmId: vmId,
      operation: "enable VNC forwarding",
      errorCode: "VNC_ENABLE_FAILED"
    ) { await self.performEnableVNC(vmId) }
  }

  private func performEnableVNC(_ vmId: UUID) async -> HTTPResponse {
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
        if await portForwardingManager.isVNCForwardingActive(vmId: vmId) {
          let response = VNCInfoResponse(port: existingPort)
          return HTTPResponse.json(response)
        }
        // The persisted reservation outlived its proxy. Release it before the
        // actor atomically chooses and starts a replacement.
        await portForwardingManager.releaseVNCPort(existingPort)
        try await vmManager.setVNCPort(nil, for: vmId)
        definition = try await vmManager.getVM(vmId)
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

      let vncPort: Int
      do {
        guard let allocatedPort = try await portForwardingManager.allocateAndSetupVNCForwarding(
          vmId: vmId,
          vmIPAddress: natIP
        ) else {
          return HTTPResponse.error(
            "VNC_ENABLE_FAILED",
            message: "No available VNC ports in configured range",
            statusCode: 503
          )
        }
        vncPort = allocatedPort
      } catch {
        return HTTPResponse.error("VNC_ENABLE_FAILED", message: error.localizedDescription, statusCode: 500)
      }

      do {
        try await vmManager.setVNCPort(vncPort, for: vmId)
      } catch {
        await portForwardingManager.stopVNCForwarding(vmId: vmId)
        throw error
      }

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

    return await withExclusiveNetworkingOperation(
      vmId: vmId,
      operation: "disable VNC forwarding",
      errorCode: "VNC_DISABLE_FAILED"
    ) { await self.performDisableVNC(vmId) }
  }

  private func performDisableVNC(_ vmId: UUID) async -> HTTPResponse {
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
      }
      try await vmManager.setVNCPort(nil, for: vmId)

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
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "VNC_STATUS_FAILED")
    } catch {
      return HTTPResponse.error("VNC_STATUS_FAILED", message: error.localizedDescription, statusCode: 500)
    }
  }

  private func withExclusiveNetworkingOperation(
    vmId: UUID,
    operation: String,
    errorCode: String,
    body: @Sendable () async -> HTTPResponse
  ) async -> HTTPResponse {
    do {
      return try await vmManager.withExclusiveVMOperation(vmId, operation: operation, body: body)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: errorCode)
    } catch {
      return HTTPResponse.error(errorCode, message: error.localizedDescription, statusCode: 500)
    }
  }

  // MARK: - State & Events

  func handleGetState(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    do {
      let snapshot = try await vmManager.getVMStateSnapshot(vmId)
      let response = VMStateResponse(state: snapshot.state, uptime: snapshot.uptime)
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "GET_STATE_FAILED")
    } catch {
      return HTTPResponse.error("GET_STATE_FAILED", message: error.localizedDescription, statusCode: 500)
    }
  }

  func handleGetEvents(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    let limit: Int
    do {
      limit = try HTTPQueryParameters.integer(named: "limit", in: request, defaultValue: 100, min: 1, max: 1000)
    } catch {
      return invalidQueryParameter(error)
    }

    let events = eventBus.getEvents(forVM: vmId, limit: limit)

    // Preserve event history for recently deleted VMs. A never-seen UUID remains a 404.
    do {
      _ = try await vmManager.getVM(vmId)
    } catch let error as VMManagerError {
      switch error {
      case .vmNotFound where events.isEmpty:
        return HTTPResponse.error("NOT_FOUND", message: "VM not found", statusCode: 404)
      case .vmNotFound:
        break
      default: return HTTPResponse.error("EVENTS_FAILED", message: error.localizedDescription, statusCode: 500)
      }
    } catch { return HTTPResponse.error("EVENTS_FAILED", message: error.localizedDescription, statusCode: 500) }

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

    let committed: (config: Config, revision: UInt64)
    do {
      committed = try commitConfiguration { currentConfig in
        let validation = updateRequest.validate(currentConfig: currentConfig.networking)
        guard validation.valid else {
          throw ConfigError.invalidFormat(validation.error ?? "Invalid configuration update")
        }
        return updatedConfig(from: updateRequest, applyingTo: currentConfig)
      }
    } catch let error as ConfigError {
      return HTTPResponse.error("INVALID_REQUEST", message: error.localizedDescription, statusCode: 400)
    } catch {
      return HTTPResponse.error("CONFIG_UPDATE_FAILED", message: error.localizedDescription, statusCode: 500)
    }

    await applyRuntimeConfigurationUntilCurrent(startingWith: committed)

    logInfo("Configuration updated via API", category: "APIServer")
    return HTTPResponse.json(ConfigResponse(from: config))
  }

  private func updatedConfig(from updateRequest: UpdateConfigRequest, applyingTo currentConfig: Config) -> Config {
    var newConfig = currentConfig
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

  private func applyRuntimeConfigurationUntilCurrent(
    startingWith initial: (config: Config, revision: UInt64)
  ) async {
    var snapshot = initial
    while true {
      await imageManager.updateConfiguration(snapshot.config)
      applyLoggingRuntimeConfiguration(snapshot.config.logging)

      let current = configurationSnapshot()
      guard current.revision != snapshot.revision else { return }
      snapshot = current
    }
  }

  private func applyLoggingRuntimeConfiguration(_ logging: LoggingConfig) {
    if let logLevel = LogLevel(rawValue: logging.level.uppercased()) {
      Logger.shared.logLevel = logLevel
    }
    Logger.shared.retentionDays = logging.retentionDays
    if let bytes = LoggingConfig.parseSize(logging.maxTotalSize) {
      Logger.shared.maxTotalSizeBytes = bytes
    }
    Logger.shared.timezone = logging.timezone.flatMap(TimeZone.init(identifier:)) ?? .current
  }
}
