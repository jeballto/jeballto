import Foundation

/// Centralized mapping from route-layer failures to HTTP responses.
/// This keeps status-code policy testable without starting the full server.
enum APIRouteErrorMapper {
  static func invalidID(resource: String = "VM") -> HTTPResponse {
    HTTPResponse.error("INVALID_ID", message: "Invalid \(resource) ID", statusCode: 400)
  }

  static func missingBody() -> HTTPResponse {
    HTTPResponse.error("INVALID_REQUEST", message: "Missing request body", statusCode: 400)
  }

  static func invalidJSON(_ error: Error) -> HTTPResponse {
    HTTPResponse.error("INVALID_REQUEST", message: "Invalid JSON: \(error.localizedDescription)", statusCode: 400)
  }

  static func invalidRequest(_ message: String, code: String = "INVALID_REQUEST") -> HTTPResponse {
    HTTPResponse.error(code, message: message, statusCode: 400)
  }

  static func vmManager(
    _ error: VMManagerError,
    defaultCode: String,
    notFoundCode: String = "NOT_FOUND",
    notFoundMessage: String = "VM not found",
    invalidStateCode: String = "INVALID_STATE",
    concurrentLimitCode: String = "VM_LIMIT_REACHED"
  ) -> HTTPResponse {
    switch error {
    case .vmNotFound:
      HTTPResponse.error(notFoundCode, message: notFoundMessage, statusCode: 404)
    case .invalidState:
      HTTPResponse.error(invalidStateCode, message: error.localizedDescription, statusCode: 409)
    case .concurrentVMLimitReached:
      HTTPResponse.error(concurrentLimitCode, message: error.localizedDescription, statusCode: 409)
    case .invalidResources:
      HTTPResponse.error(defaultCode, message: error.localizedDescription, statusCode: 400)
    case .operationFailed:
      HTTPResponse.error(defaultCode, message: error.localizedDescription, statusCode: 500)
    }
  }

  static func imageManager(
    _ error: ImageManagerError,
    defaultCode: String,
    notFoundCode: String? = nil,
    notFoundMessage: String? = nil
  ) -> HTTPResponse {
    switch error {
    case .imageNotFound, .imageNotFoundById:
      if let notFoundCode {
        return HTTPResponse.error(
          notFoundCode,
          message: notFoundMessage ?? error.localizedDescription,
          statusCode: 404
        )
      }
      return HTTPResponse.error(defaultCode, message: error.localizedDescription, statusCode: 500)
    case .invalidReference:
      return HTTPResponse.error("INVALID_REFERENCE", message: error.localizedDescription, statusCode: 400)
    case .pullFailed, .pushFailed, .deleteFailed:
      return HTTPResponse.error(defaultCode, message: error.localizedDescription, statusCode: 500)
    case .registryUnreachable:
      return HTTPResponse.error(defaultCode, message: error.localizedDescription, statusCode: 503)
    }
  }

  static func commandExecutor(_ error: CommandExecutorError, defaultCode: String = "EXECUTE_FAILED") -> HTTPResponse {
    HTTPResponse.error(
      defaultCode,
      message: error.localizedDescription,
      statusCode: error.isTimeout ? 504 : 500
    )
  }
}
