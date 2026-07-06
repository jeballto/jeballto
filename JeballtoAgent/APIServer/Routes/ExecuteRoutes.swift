import Foundation

// MARK: - Execute Route Handlers

extension APIServer {
  func handleExecuteCommand(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }
    if let response = requireCapabilities(VirtualizationFeature.commandExecutionRequirements) { return response }

    guard let body = request.body else {
      return APIRouteErrorMapper.missingBody()
    }

    let executeRequest: CommandExecuteRequest
    do { executeRequest = try JSONDecoder().decode(CommandExecuteRequest.self, from: body) } catch {
      return APIRouteErrorMapper.invalidJSON(error)
    }

    let validation = executeRequest.validate()
    guard validation.valid else {
      return APIRouteErrorMapper.invalidRequest(validation.error ?? "Invalid request")
    }

    return await executeCommand(vmId: vmId, command: executeRequest.command, request: executeRequest)
  }

  func handleKeystrokes(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }
    if let response = requireCapability(.keystrokeInjection) { return response }

    guard let body = request.body else {
      return APIRouteErrorMapper.missingBody()
    }

    let keystrokesRequest: KeystrokesRequest
    do { keystrokesRequest = try JSONDecoder().decode(KeystrokesRequest.self, from: body) } catch {
      return APIRouteErrorMapper.invalidJSON(error)
    }

    let validation = keystrokesRequest.validate()
    guard validation.valid else {
      return APIRouteErrorMapper.invalidRequest(validation.error ?? "Invalid request")
    }

    return await executeKeystrokes(vmId: vmId, keystrokes: keystrokesRequest.keystrokes)
  }

  // MARK: - Private Helpers

  private func executeCommand(vmId: UUID, command: String, request: CommandExecuteRequest) async -> HTTPResponse {
    do {
      let result = try await vmManager.executeCommand(
        vmId,
        command: command,
        user: request.effectiveUser,
        password: request.effectivePassword,
        timeout: request.effectiveTimeout
      )
      let response = CommandExecuteResponse(
        vmId: vmId.uuidString,
        exitCode: Int(result.exitCode),
        stdout: result.stdout,
        stderr: result.stderr
      )
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(
        error,
        defaultCode: "EXECUTE_FAILED",
        invalidStateCode: "INVALID_STATE"
      )
    } catch let error as CommandExecutorError {
      return APIRouteErrorMapper.commandExecutor(error, defaultCode: "EXECUTE_FAILED")
    } catch { return HTTPResponse.error("EXECUTE_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  private func executeKeystrokes(vmId: UUID, keystrokes: [String]) async -> HTTPResponse {
    do {
      let count = try await vmManager.executeKeystrokes(vmId, keystrokes: keystrokes)
      let response = KeystrokesResponse(
        vmId: vmId.uuidString,
        keystrokesCount: count,
        message: "Injected \(count) keystroke actions"
      )
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(
        error,
        defaultCode: "EXECUTE_FAILED",
        invalidStateCode: "INVALID_STATE"
      )
    } catch let error as KeystrokeParserError {
      return HTTPResponse.error(
        "INVALID_REQUEST",
        message: "Keystroke parse error: \(error.localizedDescription)",
        statusCode: 400
      )
    } catch { return HTTPResponse.error("EXECUTE_FAILED", message: error.localizedDescription, statusCode: 500) }
  }
}
