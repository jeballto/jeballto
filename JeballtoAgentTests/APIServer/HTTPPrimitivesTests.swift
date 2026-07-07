import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes))
struct HTTPPrimitivesTests {
  @Test
  func queryParametersAreParsedFromPath() {
    let parsed = HTTPRequest.parseQueryParameters("/v1/vms?id=1&limit=50")

    #expect(parsed.path == "/v1/vms")
    #expect(parsed.params["id"] == "1")
    #expect(parsed.params["limit"] == "50")
  }

  @Test
  func invalidQueryPathFallsBackToOriginalPath() {
    let parsed = HTTPRequest.parseQueryParameters("://not a url")
    #expect(parsed.path == "://not a url")
    #expect(parsed.params.isEmpty)
  }

  @Test
  func responseSetsDefaultContentTypeWhenBodyExists() {
    let response = HTTPResponse(statusCode: 200, body: Data("{}".utf8))
    #expect(response.headers["Content-Type"] == "application/json")
  }

  @Test
  func responseSerializationIncludesStatusHeadersAndBodyLength() {
    let body = Data("hello".utf8)
    let response = HTTPResponse(statusCode: 504, headers: ["X-Test": "1"], body: body)
    let raw = String(data: response.toData(), encoding: .utf8)

    #expect(raw?.contains("HTTP/1.1 504 Gateway Timeout") == true)
    #expect(raw?.contains("X-Test: 1") == true)
    #expect(raw?.contains("Content-Length: 5") == true)
    #expect(raw?.contains("Connection: close") == true)
    #expect(raw?.hasSuffix("hello") == true)
  }

  @Test
  func responseSerializationUsesKnownReasonPhrases() {
    let cancelled = String(data: HTTPResponse(statusCode: 499).toData(), encoding: .utf8)
    let unavailable = String(data: HTTPResponse(statusCode: 503).toData(), encoding: .utf8)

    #expect(cancelled?.contains("HTTP/1.1 499 Client Closed Request") == true)
    #expect(unavailable?.contains("HTTP/1.1 503 Service Unavailable") == true)
  }

  @Test
  func contentLengthRejectsMalformedValues() throws {
    let missing = SimpleHTTPServer.contentLength(fromHeaderString: "Host: example.test")
    let valid = SimpleHTTPServer.contentLength(fromHeaderString: "Host: example.test\r\nContent-Length: 42")
    let malformed = SimpleHTTPServer.contentLength(fromHeaderString: "Content-Length: nope")
    let negative = SimpleHTTPServer.contentLength(fromHeaderString: "Content-Length: -1")

    if case .success(let length) = missing {
      #expect(length == 0)
    } else {
      Issue.record("Expected missing Content-Length to default to 0")
    }

    if case .success(let length) = valid {
      #expect(length == 42)
    } else {
      Issue.record("Expected valid Content-Length to parse")
    }

    let malformedError = try #require(malformed.failureResponse)
    let negativeError = try #require(negative.failureResponse)
    #expect(malformedError.statusCode == 400)
    #expect(negativeError.statusCode == 400)
  }

  @Test
  func helperFactoriesProduceExpectedPayloads() throws {
    let success = HTTPResponse.success(message: "ok", statusCode: 201)
    let error = HTTPResponse.error("BAD", message: "nope", statusCode: 400)

    let successBody = try JSONDecoder().decode(SuccessResponse.self, from: #require(success.body))
    let errorBody = try JSONDecoder().decode(ErrorResponse.self, from: #require(error.body))

    #expect(success.statusCode == 201)
    #expect(successBody.success)
    #expect(successBody.message == "ok")
    #expect(error.statusCode == 400)
    #expect(errorBody.error.code == "BAD")
    #expect(errorBody.error.message == "nope")
  }
}

private extension Result where Success == Int, Failure == HTTPResponse {
  var failureResponse: HTTPResponse? {
    if case .failure(let response) = self { return response }
    return nil
  }
}
