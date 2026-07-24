import Foundation

struct HTTPRequestDecoder: Sendable {
  private struct DecodedHead {
    let method: String
    let path: String
    let headers: [String: String]
    let queryParameters: [String: String]
  }

  static let maxRequestBodySize = 1_048_576
  static let maxHeaderSize = 65536

  static let malformedRequestResponse = HTTPResponse.error(
    "INVALID_REQUEST",
    message: "Malformed HTTP request",
    statusCode: 400
  )

  func decode(_ data: Data) -> Result<HTTPRequest, HTTPResponse> {
    guard let headerEndIndex = Self.headerEnd(in: data) else {
      return .failure(Self.malformedRequestResponse)
    }

    let headerData = data[data.startIndex ..< headerEndIndex]
    guard let headerString = String(data: headerData, encoding: .utf8) else {
      return .failure(Self.malformedRequestResponse)
    }
    let head: DecodedHead
    switch decodeHead(headerString) {
    case .success(let decodedHead):
      head = decodedHead
    case .failure(let response):
      return .failure(response)
    }

    let bodyStartIndex = headerEndIndex + 4
    let bodyData = data[bodyStartIndex ..< data.endIndex]
    if bodyData.count > Self.maxRequestBodySize {
      logWarning("Request body too large (\(bodyData.count) bytes), rejecting", category: "HTTPServer")
      return .failure(Self.payloadTooLargeResponse())
    }

    let declaredContentLength: Int
    switch contentLength(fromHeaderString: headerString) {
    case .success(let length):
      declaredContentLength = length
    case .failure(let response):
      return .failure(response)
    }
    guard bodyData.count == declaredContentLength else {
      return .failure(Self.malformedRequestResponse)
    }

    return .success(HTTPRequest(
      method: head.method,
      path: head.path,
      headers: head.headers,
      body: bodyData.isEmpty ? nil : Data(bodyData),
      queryParameters: head.queryParameters
    ))
  }

  func contentLength(fromHeaderString headerString: String) -> Result<Int, HTTPResponse> {
    var values: [Int] = []
    for line in headerString.components(separatedBy: "\r\n") {
      let lowercasedLine = line.lowercased()
      if lowercasedLine.hasPrefix("transfer-encoding:") {
        return .failure(Self.malformedRequestResponse)
      }
      guard lowercasedLine.hasPrefix("content-length:") else { continue }
      let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
      guard value.isEmpty == false,
            value.utf8.allSatisfy({ (0x30 ... 0x39).contains($0) }),
            let contentLength = Int(value) else
      {
        return .failure(Self.malformedRequestResponse)
      }
      values.append(contentLength)
    }
    guard values.count <= 1 else {
      return .failure(Self.malformedRequestResponse)
    }
    return .success(values.first ?? 0)
  }

  func headerLimitResponse(accumulatedCount: Int, headerEnd: Int?) -> HTTPResponse? {
    if let headerEnd {
      guard headerEnd > Self.maxHeaderSize else { return nil }
    } else {
      guard accumulatedCount > Self.maxHeaderSize + 3 else { return nil }
    }
    return Self.headersTooLargeResponse()
  }

  static func headerEnd(in data: Data) -> Data.Index? {
    guard data.count >= 4 else { return nil }
    let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
    for index in data.startIndex ... (data.endIndex - separator.count) {
      if data[index] == separator[0],
         data[index + 1] == separator[1],
         data[index + 2] == separator[2],
         data[index + 3] == separator[3]
      {
        return index
      }
    }
    return nil
  }

  static func payloadTooLargeResponse() -> HTTPResponse {
    HTTPResponse.error(
      "PAYLOAD_TOO_LARGE",
      message: "Request body exceeds maximum size of \(maxRequestBodySize) bytes",
      statusCode: 413
    )
  }

  private static func headersTooLargeResponse() -> HTTPResponse {
    HTTPResponse.error(
      "HEADERS_TOO_LARGE",
      message: "Request headers exceed maximum size of \(maxHeaderSize) bytes",
      statusCode: 431
    )
  }

  private func decodeHead(_ headerString: String) -> Result<DecodedHead, HTTPResponse> {
    let lines = headerString.components(separatedBy: "\r\n")
    guard let requestLine = lines.first,
          let (method, requestTarget) = Self.decodeRequestLine(requestLine) else
    {
      return .failure(Self.malformedRequestResponse)
    }

    let parsedTarget: (path: String, params: [String: String])
    switch HTTPRequest.parseQueryParameters(requestTarget) {
    case .success(let target):
      parsedTarget = target
    case .failure:
      return .failure(Self.malformedRequestResponse)
    }

    let headers: [String: String]
    switch Self.decodeHeaders(lines.dropFirst()) {
    case .success(let decodedHeaders):
      headers = decodedHeaders
    case .failure(let response):
      return .failure(response)
    }

    return .success(DecodedHead(
      method: method,
      path: parsedTarget.path,
      headers: headers,
      queryParameters: parsedTarget.params
    ))
  }

  private static func decodeRequestLine(_ requestLine: String) -> (method: String, target: String)? {
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard parts.count == 3,
          parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else
    {
      return nil
    }

    let method = String(parts[0])
    guard method.isEmpty == false,
          method.unicodeScalars.allSatisfy(Self.isHTTPHeaderNameScalar) else
    {
      return nil
    }
    return (method, String(parts[1]))
  }

  private static func decodeHeaders(
    _ lines: ArraySlice<String>
  ) -> Result<[String: String], HTTPResponse> {
    var headers: [String: String] = [:]
    for line in lines {
      guard let colonIndex = line.firstIndex(of: ":") else {
        return .failure(Self.malformedRequestResponse)
      }
      let rawKey = String(line[..<colonIndex])
      let key = rawKey.lowercased()
      guard rawKey.isEmpty == false,
            rawKey == rawKey.trimmingCharacters(in: .whitespaces),
            rawKey.unicodeScalars.allSatisfy(Self.isHTTPHeaderNameScalar),
            headers[key] == nil else
      {
        return .failure(Self.malformedRequestResponse)
      }

      let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
      guard value.unicodeScalars.allSatisfy(Self.isHTTPHeaderValueScalar) else {
        return .failure(Self.malformedRequestResponse)
      }
      headers[key] = value
    }
    return .success(headers)
  }

  private static func isHTTPHeaderValueScalar(_ scalar: UnicodeScalar) -> Bool {
    scalar.value == 0x09 || scalar.value >= 0x20 && scalar.value != 0x7F
  }

  private static func isHTTPHeaderNameScalar(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.value {
    case 0x21, 0x23 ... 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x30 ... 0x39,
         0x41 ... 0x5A, 0x5E ... 0x7A, 0x7C, 0x7E:
      true
    default:
      false
    }
  }
}
