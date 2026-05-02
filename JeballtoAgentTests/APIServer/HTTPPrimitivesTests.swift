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
