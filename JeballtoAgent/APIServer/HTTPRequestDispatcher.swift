import Foundation

final class HTTPRequestDispatcher: @unchecked Sendable {
  private let router: HTTPRouter
  private let configurationLock = NSLock()
  private var _authToken: String?
  private var _requestAdmissionHandler: HTTPRequestAdmissionHandler?

  init(router: HTTPRouter) {
    self.router = router
  }

  var authToken: String? {
    get { configurationLock.withLock { _authToken } }
    set { configurationLock.withLock { _authToken = newValue } }
  }

  var requestAdmissionHandler: HTTPRequestAdmissionHandler? {
    get { configurationLock.withLock { _requestAdmissionHandler } }
    set { configurationLock.withLock { _requestAdmissionHandler = newValue } }
  }

  func dispatch(_ request: HTTPRequest) async -> HTTPResponse {
    logDebug("HTTP Request: \(request.method) \(request.path)", category: "HTTPServer")

    let isHealthCheck = request.path == "/v1/health"
    let authToken = configurationLock.withLock { _authToken }
    if isHealthCheck == false, let authToken {
      guard let authHeader = request.headers["authorization"],
            let suppliedToken = Self.bearerToken(from: authHeader),
            Self.constantTimeEqual(suppliedToken, expected: authToken) else
      {
        logWarning("Unauthorized request: \(request.method) \(request.path)", category: "HTTPServer")
        return HTTPResponse.error(
          "UNAUTHORIZED",
          message: "Invalid or missing authentication token",
          statusCode: 401
        )
      }
    }

    guard Task.isCancelled == false else {
      return Self.requestCancelledResponse
    }

    let requestAdmissionHandler = configurationLock.withLock { _requestAdmissionHandler }
    if let requestAdmissionHandler {
      switch await requestAdmissionHandler(request) {
      case .allowed:
        guard Task.isCancelled == false else {
          return Self.requestCancelledResponse
        }
      case .leased(let release):
        guard Task.isCancelled == false else {
          await release()
          return Self.requestCancelledResponse
        }
        let response = await dispatchToRoute(request)
        await release()
        return response
      case .rejected(let response):
        return response
      }
    }

    return await dispatchToRoute(request)
  }

  static func bearerToken(from header: String) -> String? {
    guard let separator = header.firstIndex(of: " ") else { return nil }
    let scheme = header[..<separator]
    guard scheme.caseInsensitiveCompare("Bearer") == .orderedSame else { return nil }
    let credentials = header[separator...].drop(while: { $0 == " " })
    guard credentials.isEmpty == false,
          credentials.contains(where: { $0 == " " || $0 == "\t" }) == false else
    {
      return nil
    }
    return String(credentials)
  }

  private static let requestCancelledResponse = HTTPResponse.error(
    "REQUEST_CANCELLED",
    message: "Request processing was cancelled",
    statusCode: 499
  )

  private func dispatchToRoute(_ request: HTTPRequest) async -> HTTPResponse {
    switch router.resolve(request) {
    case .handler(let handler):
      return await invokeRouteHandler(handler, request: request)
    case .response(let response):
      return response
    }
  }

  private func invokeRouteHandler(_ handler: RouteHandler, request: HTTPRequest) async -> HTTPResponse {
    do {
      return try await handler(request)
    } catch is CancellationError {
      logDebug("Handler cancelled for \(request.method) \(request.path)", category: "HTTPServer")
      return Self.requestCancelledResponse
    } catch {
      logError(
        "Handler error for \(request.method) \(request.path): \(error.localizedDescription)",
        category: "HTTPServer"
      )
      return HTTPResponse.error("INTERNAL_ERROR", message: error.localizedDescription, statusCode: 500)
    }
  }

  private static func constantTimeEqual(_ supplied: String, expected: String) -> Bool {
    let suppliedBytes = Array(supplied.utf8)
    let expectedBytes = Array(expected.utf8)

    var difference = suppliedBytes.count ^ expectedBytes.count
    for index in 0 ..< expectedBytes.count {
      let suppliedByte = index < suppliedBytes.count ? suppliedBytes[index] : 0
      difference |= Int(suppliedByte ^ expectedBytes[index])
    }
    return difference == 0
  }
}
