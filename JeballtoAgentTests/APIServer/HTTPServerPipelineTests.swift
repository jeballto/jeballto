import Foundation
import Network
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes))
struct HTTPServerPipelineTests {
  @Test
  func readerAssemblesFragmentedHeadersAndBody() throws {
    let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    let reader = HTTPRequestReader(connection: connection)

    let firstStep = reader.evaluate(
      accumulatedData: Data(),
      receivedData: Data("POST /upload HTTP/1.1\r\nContent-Len".utf8),
      isComplete: false,
      hasError: false
    )
    guard case .receiveMore(let firstFragment) = firstStep else {
      Issue.record("Expected the reader to wait for the rest of the headers")
      return
    }

    let secondStep = reader.evaluate(
      accumulatedData: firstFragment,
      receivedData: Data("gth: 4\r\n\r\nte".utf8),
      isComplete: false,
      hasError: false
    )
    guard case .receiveMore(let secondFragment) = secondStep else {
      Issue.record("Expected the reader to wait for the rest of the body")
      return
    }

    let finalStep = reader.evaluate(
      accumulatedData: secondFragment,
      receivedData: Data("st".utf8),
      isComplete: false,
      hasError: false
    )
    guard case .complete(.success(let data)?) = finalStep else {
      Issue.record("Expected the fragmented request to complete")
      return
    }

    let request = try HTTPRequestDecoder().decode(data).get()
    #expect(request.method == "POST")
    #expect(request.path == "/upload")
    #expect(request.body == Data("test".utf8))
  }

  @Test
  func readerRejectsAmbiguousFramingHeaders() {
    let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    let reader = HTTPRequestReader(connection: connection)
    let requests = [
      "POST /upload HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
      "POST /upload HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
    ]

    for rawRequest in requests {
      let step = reader.evaluate(
        accumulatedData: Data(),
        receivedData: Data(rawRequest.utf8),
        isComplete: false,
        hasError: false
      )
      guard case .complete(.failure(let response)?) = step else {
        Issue.record("Expected ambiguous request framing to fail")
        continue
      }
      #expect(response.statusCode == 400)
    }
  }

  @Test
  func readerRejectsShortAndExtraBodies() {
    let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    let reader = HTTPRequestReader(connection: connection)
    let requests = [
      (
        data: Data("POST /upload HTTP/1.1\r\nContent-Length: 4\r\n\r\nte".utf8),
        isComplete: true
      ),
      (
        data: Data("POST /upload HTTP/1.1\r\nContent-Length: 1\r\n\r\nte".utf8),
        isComplete: false
      ),
    ]

    for request in requests {
      let step = reader.evaluate(
        accumulatedData: Data(),
        receivedData: request.data,
        isComplete: request.isComplete,
        hasError: false
      )
      guard case .complete(.failure(let response)?) = step else {
        Issue.record("Expected an invalid body length to fail")
        continue
      }
      #expect(response.statusCode == 400)
    }
  }

  @Test
  func exactRouteWinsBeforeParameterizedRoute() async {
    let server = SimpleHTTPServer(port: 1, host: "127.0.0.1")
    server.get("/items/{id}") { _ in HTTPResponse(statusCode: 201) }
    server.get("/items/special") { _ in HTTPResponse(statusCode: 204) }

    let exact = await server.handleRequest(HTTPRequest(
      method: "GET",
      path: "/items/special",
      headers: [:],
      body: nil,
      queryParameters: [:]
    ))
    let parameterized = await server.handleRequest(HTTPRequest(
      method: "GET",
      path: "/items/123",
      headers: [:],
      body: nil,
      queryParameters: [:]
    ))

    #expect(exact.statusCode == 204)
    #expect(parameterized.statusCode == 201)
  }

  @Test
  func unknownRouteReturnsStableNotFoundResponse() async throws {
    let server = SimpleHTTPServer(port: 1, host: "127.0.0.1")
    let response = await server.handleRequest(HTTPRequest(
      method: "GET",
      path: "/unknown",
      headers: [:],
      body: nil,
      queryParameters: [:]
    ))
    let body = try JSONDecoder().decode(ErrorResponse.self, from: #require(response.body))

    #expect(response.statusCode == 404)
    #expect(body.error.code == "NOT_FOUND")
    #expect(body.error.message == "The requested resource was not found")
  }

  @Test
  func healthBypassesAuthenticationButOtherRoutesRequireIt() async {
    let server = SimpleHTTPServer(port: 1, host: "127.0.0.1")
    server.authToken = "secret"
    server.get("/v1/health") { _ in HTTPResponse(statusCode: 200) }
    server.get("/private") { _ in HTTPResponse(statusCode: 200) }

    let health = await server.handleRequest(HTTPRequest(
      method: "GET",
      path: "/v1/health",
      headers: [:],
      body: nil,
      queryParameters: [:]
    ))
    let unauthorized = await server.handleRequest(HTTPRequest(
      method: "GET",
      path: "/private",
      headers: [:],
      body: nil,
      queryParameters: [:]
    ))
    let authorized = await server.handleRequest(HTTPRequest(
      method: "GET",
      path: "/private",
      headers: ["authorization": "Bearer secret"],
      body: nil,
      queryParameters: [:]
    ))

    #expect(health.statusCode == 200)
    #expect(unauthorized.statusCode == 401)
    #expect(authorized.statusCode == 200)
  }

  @Test
  func leasedAdmissionReleasesAfterDispatch() async {
    let releases = HTTPPipelineCounter()
    let server = SimpleHTTPServer(port: 1, host: "127.0.0.1")
    server.requestAdmissionHandler = { _ in
      .leased {
        releases.increment()
      }
    }
    server.post("/mutate") { _ in HTTPResponse(statusCode: 202) }

    let response = await server.handleRequest(HTTPRequest(
      method: "POST",
      path: "/mutate",
      headers: [:],
      body: nil,
      queryParameters: [:]
    ))

    #expect(response.statusCode == 202)
    #expect(releases.value == 1)
  }
}

private final class HTTPPipelineCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}
