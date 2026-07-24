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
    if let response = requireCapabilities(VirtualizationFeature.vmInstallationRequirements) { return response }

    let ipswSource = installRequest?.effectiveIPSWSource

    do {
      try await vmManager.startInstallation(vmId, ipswSource: ipswSource)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(
        error,
        defaultCode: "INSTALL_FAILED",
        concurrentLimitCode: "VM_LIMIT_REACHED"
      )
    } catch { return HTTPResponse.error("INSTALL_FAILED", message: error.localizedDescription, statusCode: 500) }

    // Return immediate response
    let message = if let ipswSource {
      "Installing from \(IPSWSourceValidator.logDescription(ipswSource))"
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
      let (_, installation, installProgress) = try await vmManager.getInstallationStatus(vmId)

      let status = InstallStatusResponse.wireStatus(for: installation)

      // Sentinel value -1.0 means indeterminate progress (no percentage available yet)
      let progress: Double? = if let p = installProgress?.progress, p >= 0 { p } else { nil }
      let phaseProgress: Double? = if let p = installProgress?.phaseProgress, p >= 0 { p } else { nil }

      let response = InstallStatusResponse(
        vmId: vmId,
        status: status,
        progress: progress,
        phaseProgress: phaseProgress,
        message: installProgress?.message ?? installation?.message ?? "Installation has not started",
        phase: installProgress?.phase,
        bytesDownloaded: installProgress?.bytesDownloaded,
        bytesTotal: installProgress?.bytesTotal,
        downloadSpeed: installProgress?.downloadSpeed
      )
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "INSTALL_STATUS_FAILED")
    } catch {
      return HTTPResponse.error("INSTALL_STATUS_FAILED", message: error.localizedDescription, statusCode: 500)
    }
  }
}
