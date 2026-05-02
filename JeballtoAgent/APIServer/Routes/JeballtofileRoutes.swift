import Foundation
import Yams

// MARK: - Jeballtofile Route Handlers

extension APIServer {
  func handleCreateJeballtofile(_ request: HTTPRequest) async -> HTTPResponse {
    guard let body = request.body else {
      return APIRouteErrorMapper.missingBody()
    }

    let jeballtofileRequest: JeballtofileRequest
    do {
      jeballtofileRequest = try decodeJeballtofile(body: body, contentType: request.headers["content-type"])
    } catch {
      return HTTPResponse.error("INVALID_REQUEST", message: error.localizedDescription, statusCode: 400)
    }

    let validation = jeballtofileRequest.validate()
    guard validation.valid else {
      return HTTPResponse.error("INVALID_REQUEST", message: validation.error ?? "Invalid request", statusCode: 400)
    }

    // Create the VM
    let resources = jeballtofileRequest.resources?.toVMResources() ?? VMResources.default
    let definition: VMDefinition
    do {
      definition = try await vmManager.createVM(name: jeballtofileRequest.name, resources: resources)
    } catch let error as VMManagerError {
      switch error {
      case .invalidResources:
        return HTTPResponse.error("INVALID_REQUEST", message: error.localizedDescription, statusCode: 400)
      default:
        return HTTPResponse.error("CREATE_FAILED", message: error.localizedDescription, statusCode: 500)
      }
    } catch {
      return HTTPResponse.error("CREATE_FAILED", message: error.localizedDescription, statusCode: 500)
    }

    let executionId = UUID()
    let vmId = definition.id
    let execution = JeballtofileExecution(id: executionId, vmId: vmId, totalSteps: jeballtofileRequest.steps.count)

    let executor = JeballtofileExecutor(
      execution: execution,
      steps: jeballtofileRequest.steps,
      source: jeballtofileRequest.source,
      vmManager: vmManager,
      eventBus: eventBus
    )

    setJeballtofileExecutor(executionId, executor: executor)
    executor.start()

    let response = JeballtofileResponse(
      executionId: executionId,
      vmId: vmId,
      totalSteps: jeballtofileRequest.steps.count
    )
    return HTTPResponse.json(response, statusCode: 202)
  }

  func handleGetJeballtofileStatus(_ request: HTTPRequest) async -> HTTPResponse {
    guard let executionId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID(resource: "execution")
    }

    guard let executor = getJeballtofileExecutor(executionId) else {
      return HTTPResponse.error("NOT_FOUND", message: "Jeballtofile execution not found", statusCode: 404)
    }

    let response = JeballtofileStatusResponse(from: executor.execution)
    return HTTPResponse.json(response)
  }

  func handleListJeballtofiles(_ request: HTTPRequest) async -> HTTPResponse {
    let executions = listJeballtofileExecutors().map { JeballtofileStatusResponse(from: $0.execution) }
    let response = JeballtofileListResponse(executions: executions, total: executions.count)
    return HTTPResponse.json(response)
  }

  func handleCancelJeballtofile(_ request: HTTPRequest) async -> HTTPResponse {
    guard let executionId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID(resource: "execution")
    }

    guard let executor = getJeballtofileExecutor(executionId) else {
      return HTTPResponse.error("NOT_FOUND", message: "Jeballtofile execution not found", statusCode: 404)
    }

    guard executor.execution.status == .running else {
      return HTTPResponse.error(
        "INVALID_STATE",
        message: "Execution is not running (current: \(executor.execution.status.rawValue))",
        statusCode: 409
      )
    }

    executor.cancel()
    return HTTPResponse.json(SuccessResponse(message: "Jeballtofile execution cancellation requested"))
  }

  func handleDeleteJeballtofile(_ request: HTTPRequest) async -> HTTPResponse {
    guard let executionId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID(resource: "execution")
    }

    guard let executor = getJeballtofileExecutor(executionId) else {
      return HTTPResponse.error("NOT_FOUND", message: "Jeballtofile execution not found", statusCode: 404)
    }

    guard executor.execution.status != .running else {
      return HTTPResponse.error(
        "INVALID_STATE",
        message: "Cannot delete a running execution, cancel it first",
        statusCode: 409
      )
    }

    removeJeballtofileExecutor(executionId)
    return HTTPResponse.json(SuccessResponse(message: "Jeballtofile execution deleted"))
  }

  // MARK: - Decoding

  private func decodeJeballtofile(body: Data, contentType: String?) throws -> JeballtofileRequest {
    let isYAML = contentType.map {
      $0.contains("yaml") || $0.contains("x-yaml")
    } ?? false

    if isYAML {
      guard let yamlString = String(data: body, encoding: .utf8) else {
        throw JeballtofileDecodeError.invalidEncoding
      }
      return try YAMLDecoder().decode(JeballtofileRequest.self, from: yamlString)
    }

    return try JSONDecoder().decode(JeballtofileRequest.self, from: body)
  }
}

enum JeballtofileDecodeError: Error, LocalizedError {
  case invalidEncoding

  var errorDescription: String? {
    switch self {
    case .invalidEncoding:
      "Request body is not valid UTF-8"
    }
  }
}
