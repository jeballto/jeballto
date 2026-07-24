import Foundation

enum HTTPRequestTargetError: Error, LocalizedError, Equatable {
  case invalidOriginForm
  case invalidPercentEncoding
  case emptyQueryParameterName
  case controlCharacterInQueryParameter
  case duplicateQueryParameter(String)

  var errorDescription: String? {
    switch self {
    case .invalidOriginForm: "Request target must use a canonical origin form"
    case .invalidPercentEncoding: "Query parameter contains invalid percent encoding"
    case .emptyQueryParameterName: "Query parameter name cannot be empty"
    case .controlCharacterInQueryParameter: "Query parameter cannot contain control characters"
    case .duplicateQueryParameter(let name): "Query parameter '\(name)' cannot be repeated"
    }
  }
}

/// HTTP request representation
struct HTTPRequest: Sendable {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data?
  let queryParameters: [String: String]

  /// Parses an origin-form request target without normalizing its path.
  static func parseQueryParameters(
    _ target: String
  ) -> Result<(path: String, params: [String: String]), HTTPRequestTargetError> {
    let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    guard let rawPath = targetParts.first else { return .failure(.invalidOriginForm) }
    let path = String(rawPath)
    guard path.hasPrefix("/"),
          path.hasPrefix("//") == false,
          path.contains("%") == false,
          target.contains("#") == false,
          target.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }) else
    {
      return .failure(.invalidOriginForm)
    }

    guard targetParts.count == 2, targetParts[1].isEmpty == false else {
      return .success((path, [:]))
    }

    var params: [String: String] = [:]
    for rawItem in targetParts[1].split(separator: "&", omittingEmptySubsequences: false) {
      guard rawItem.isEmpty == false else { return .failure(.emptyQueryParameterName) }
      let pair = rawItem.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let rawValue = pair.count == 2 ? pair[1] : Substring()
      guard let name = String(pair[0]).removingPercentEncoding,
            let value = String(rawValue).removingPercentEncoding else
      {
        return .failure(.invalidPercentEncoding)
      }
      guard name.isEmpty == false else { return .failure(.emptyQueryParameterName) }
      guard Self.containsControlCharacter(name) == false,
            Self.containsControlCharacter(value) == false else
      {
        return .failure(.controlCharacterInQueryParameter)
      }
      guard params[name] == nil else { return .failure(.duplicateQueryParameter(name)) }
      params[name] = value
    }

    return .success((path, params))
  }

  private static func containsControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
  }
}

/// HTTP response representation
struct HTTPResponse: Error, Sendable {
  let statusCode: Int
  let headers: [String: String]
  let body: Data?
  private let afterSendAction: (@Sendable () -> Void)?

  init(
    statusCode: Int,
    headers: [String: String] = [:],
    body: Data? = nil,
    afterSendAction: (@Sendable () -> Void)? = nil
  ) {
    self.statusCode = statusCode
    var defaultHeaders = headers
    if body != nil, defaultHeaders["Content-Type"] == nil { defaultHeaders["Content-Type"] = "application/json" }
    self.headers = defaultHeaders
    self.body = body
    self.afterSendAction = afterSendAction
  }

  /// Creates JSON response
  static func json(_ object: some Encodable, statusCode: Int = 200) -> HTTPResponse {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    do {
      let data = try encoder.encode(object)
      return HTTPResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: data)
    } catch {
      let fallback = "{\"error\":{\"code\":\"INTERNAL_ERROR\",\"message\":\"Failed to encode response\"}}"
      return HTTPResponse(
        statusCode: 500,
        headers: ["Content-Type": "application/json"],
        body: fallback.data(using: .utf8)
      )
    }
  }

  /// Creates error response
  static func error(_ code: String, message: String, statusCode: Int = 400) -> HTTPResponse {
    let errorResponse = ErrorResponse(code: code, message: message)
    return json(errorResponse, statusCode: statusCode)
  }

  /// Creates success response
  static func success(message: String? = nil, statusCode: Int = 200) -> HTTPResponse {
    let successResponse = SuccessResponse(message: message)
    return json(successResponse, statusCode: statusCode)
  }

  func afterSending(_ action: @escaping @Sendable () -> Void) -> HTTPResponse {
    HTTPResponse(statusCode: statusCode, headers: headers, body: body, afterSendAction: action)
  }

  func runAfterSendAction() {
    afterSendAction?()
  }

  /// Converts to raw HTTP response bytes
  func toData() -> Data {
    var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"

    // Add headers
    for (key, value) in headers {
      response += "\(key): \(value)\r\n"
    }

    // Always include Content-Length (0 for empty bodies)
    let bodyLength = body?.count ?? 0
    response += "Content-Length: \(bodyLength)\r\n"

    // Signal connection will close (no keep-alive support)
    response += "Connection: close\r\n"

    response += "\r\n"

    var data = response.data(using: .utf8) ?? Data()
    if let body { data.append(body) }

    return data
  }

  private var statusText: String {
    switch statusCode {
    case 200: "OK"
    case 201: "Created"
    case 202: "Accepted"
    case 204: "No Content"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 409: "Conflict"
    case 413: "Payload Too Large"
    case 429: "Too Many Requests"
    case 431: "Request Header Fields Too Large"
    case 499: "Client Closed Request"
    case 500: "Internal Server Error"
    case 503: "Service Unavailable"
    case 504: "Gateway Timeout"
    default: "Unknown"
    }
  }
}

/// Route handler type
typealias RouteHandler = @Sendable (HTTPRequest) async throws -> HTTPResponse

enum HTTPRequestAdmission: Sendable {
  case allowed
  case leased(@Sendable () async -> Void)
  case rejected(HTTPResponse)
}

typealias HTTPRequestAdmissionHandler = @Sendable (HTTPRequest) async -> HTTPRequestAdmission

struct HTTPRouteSignature: Hashable, Sendable {
  let method: String
  let path: String
}

enum HTTPServerError: Error, LocalizedError {
  case invalidPort(UInt16)
  case listenerCreationFailed(Error)
  case listenerStartupInProgress
  case listenerStartupFailed(Error)

  var errorDescription: String? {
    switch self {
    case .invalidPort(let port): "Invalid port number: \(port)"
    case .listenerCreationFailed(let error): "Failed to create listener: \(error.localizedDescription)"
    case .listenerStartupInProgress: "HTTP listener startup is already in progress"
    case .listenerStartupFailed(let error): "HTTP listener did not start: \(error.localizedDescription)"
    }
  }
}
