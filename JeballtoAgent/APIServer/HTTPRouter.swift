import Foundation

enum HTTPRouteResolution: Sendable {
  case handler(RouteHandler)
  case response(HTTPResponse)
}

final class HTTPRouter: @unchecked Sendable {
  private let lock = NSLock()
  private var routes: [String: [String: RouteHandler]] = [:]

  func register(method: String, path: String, handler: @escaping RouteHandler) {
    lock.withLock {
      routes[path, default: [:]][method] = handler
    }
  }

  var registeredRouteSignatures: Set<HTTPRouteSignature> {
    lock.withLock {
      Set(routes.flatMap { path, handlers in
        handlers.keys.map { HTTPRouteSignature(method: $0, path: path) }
      })
    }
  }

  func resolve(_ request: HTTPRequest) -> HTTPRouteResolution {
    let routesSnapshot = lock.withLock { self.routes }

    if let methodHandlers = routesSnapshot[request.path] {
      if let handler = methodHandlers[request.method] {
        return .handler(handler)
      }
      return .response(Self.methodNotAllowed(allowedMethods: Set(methodHandlers.keys)))
    }

    var allowedMethods: Set<String> = []
    for (routePath, methodHandlers) in routesSnapshot {
      if routePath.contains("{"), Self.matchesRoute(request.path, pattern: routePath) {
        allowedMethods.formUnion(methodHandlers.keys)
        if let handler = methodHandlers[request.method] {
          return .handler(handler)
        }
      }
    }
    if allowedMethods.isEmpty == false {
      return .response(Self.methodNotAllowed(allowedMethods: allowedMethods))
    }

    logDebug("Route not found: \(request.method) \(request.path)", category: "HTTPServer")
    return .response(HTTPResponse.error(
      "NOT_FOUND",
      message: "The requested resource was not found",
      statusCode: 404
    ))
  }

  private static func methodNotAllowed(allowedMethods: Set<String>) -> HTTPResponse {
    let response = HTTPResponse.error(
      "METHOD_NOT_ALLOWED",
      message: "The requested method is not allowed for this resource",
      statusCode: 405
    )
    var headers = response.headers
    headers["Allow"] = allowedMethods.sorted().joined(separator: ", ")
    return HTTPResponse(statusCode: response.statusCode, headers: headers, body: response.body)
  }

  private static func matchesRoute(_ path: String, pattern: String) -> Bool {
    let pathComponents = path.split(separator: "/", omittingEmptySubsequences: false)
    let patternComponents = pattern.split(separator: "/", omittingEmptySubsequences: false)
    guard pathComponents.count == patternComponents.count else { return false }

    for (pathComponent, patternComponent) in zip(pathComponents, patternComponents) {
      if patternComponent.hasPrefix("{"), patternComponent.hasSuffix("}") {
        guard pathComponent.isEmpty == false else { return false }
        continue
      }
      if pathComponent != patternComponent { return false }
    }
    return true
  }
}
