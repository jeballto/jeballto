import Foundation

// MARK: - Installation Route Handlers

extension APIServer {
  func handleInstallVM(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    // Parse request body (optional)
    var installRequest: InstallVMRequest?
    if let body = request.body {
      do { installRequest = try JSONDecoder().decode(InstallVMRequest.self, from: body) } catch {
        return APIRouteErrorMapper.invalidJSON(error)
      }

      if let req = installRequest {
        let validation = req.validate()
        if !validation.valid {
          return HTTPResponse.error(
            "INVALID_REQUEST",
            message: validation.error ?? "Invalid installation request",
            statusCode: 400
          )
        }
      }
    }

    let ipswSource = installRequest?.effectiveIPSWSource

    // Verify VM exists before starting installation
    do {
      _ = try await vmManager.getVM(vmId)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "INSTALL_FAILED")
    } catch { return HTTPResponse.error("INSTALL_FAILED", message: error.localizedDescription, statusCode: 500) }

    let activeCount = await vmManager.activeVMCount()
    if activeCount >= 2 {
      return HTTPResponse.error(
        "VM_LIMIT_REACHED",
        message: "Cannot install: \(activeCount) VMs already active (max 2)",
        statusCode: 409
      )
    }

    // Claim reserves the registry slot and constructs the Task inside the lock so the release
    // token is captured by the task body at construction time.
    guard claimInstallationTask(vmId, start: { token in
      Task<Void, Never> { [weak self] in
        do {
          guard let self else { return }
          try await vmManager.installVM(vmId, ipswSource: ipswSource)
          logInfo("Installation completed for VM \(vmId)", category: "APIServer")
        } catch { logError("Installation failed for VM \(vmId): \(error)", category: "APIServer") }
        self?.releaseInstallationTask(vmId, token: token)
      }
    }) != nil else {
      return HTTPResponse.error(
        "INSTALL_IN_PROGRESS",
        message: "Installation is already in progress for this VM",
        statusCode: 409
      )
    }

    // Return immediate response
    let message = if let ipswSource {
      "Installing from \(ipswSource)"
    } else {
      "Downloading and installing latest macOS"
    }
    let response = InstallStatusResponse(
      vmId: vmId,
      status: "started",
      message: message
    )
    return HTTPResponse.json(response, statusCode: 202) // Accepted
  }

  func handleGetInstallStatus(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    do {
      let (state, installProgress) = try await vmManager.getInstallationStatus(vmId)

      let status: String = switch state {
      case .installing: "installing"
      case .stopped: "completed"
      case .error: "failed"
      case .created: "not_started"
      default: state.rawValue.lowercased()
      }

      // Sentinel value -1.0 means indeterminate progress (no percentage available yet)
      let progress: Double? = if let p = installProgress?.progress, p >= 0 { p } else { nil }
      let phaseProgress: Double? = if let p = installProgress?.phaseProgress, p >= 0 { p } else { nil }

      let response = InstallStatusResponse(
        vmId: vmId,
        status: status,
        progress: progress,
        phaseProgress: phaseProgress,
        message: installProgress?.message ?? "Current state: \(state.rawValue)",
        phase: installProgress?.phase,
        bytesDownloaded: installProgress?.bytesDownloaded,
        bytesTotal: installProgress?.bytesTotal,
        downloadSpeed: installProgress?.downloadSpeed
      )
      return HTTPResponse.json(response)
    } catch { return HTTPResponse.error("NOT_FOUND", message: "VM not found", statusCode: 404) }
  }
}
