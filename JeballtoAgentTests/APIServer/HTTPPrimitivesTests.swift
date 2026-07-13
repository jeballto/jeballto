import Foundation
import Network
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes))
struct HTTPPrimitivesTests {
  @Test
  func queryParametersAreParsedFromPath() throws {
    let parsed = try HTTPRequest.parseQueryParameters("/v1/vms?id=1&limit=50&label=a+b").get()

    #expect(parsed.path == "/v1/vms")
    #expect(parsed.params["id"] == "1")
    #expect(parsed.params["limit"] == "50")
    #expect(parsed.params["label"] == "a+b")
  }

  @Test
  func invalidQueryPathIsRejected() {
    let parsed = HTTPRequest.parseQueryParameters("://not a url")
    guard case .failure(.invalidOriginForm) = parsed else {
      Issue.record("Expected an invalid origin-form target error")
      return
    }
  }

  @Test
  func queryParserIdentifiesDuplicatesAfterPercentDecoding() {
    let parsed = HTTPRequest.parseQueryParameters("/v1/vms?%6cimit=1&limit=2")
    guard case .failure(.duplicateQueryParameter("limit")) = parsed else {
      Issue.record("Expected a duplicate decoded query parameter error")
      return
    }
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
  func responseRunsPostSendActionOnlyWhenExplicitlyTriggered() {
    let counter = ThreadSafeCounter()
    let response = HTTPResponse(statusCode: 200).afterSending { counter.increment() }

    _ = response.toData()
    #expect(counter.value == 0)
    response.runAfterSendAction()
    #expect(counter.value == 1)
  }

  @Test
  func contentLengthRejectsMalformedValues() throws {
    let missing = SimpleHTTPServer.contentLength(fromHeaderString: "Host: example.test")
    let valid = SimpleHTTPServer.contentLength(fromHeaderString: "Host: example.test\r\nContent-Length: 42")
    let malformed = SimpleHTTPServer.contentLength(fromHeaderString: "Content-Length: nope")
    let negative = SimpleHTTPServer.contentLength(fromHeaderString: "Content-Length: -1")
    let explicitlyPositive = SimpleHTTPServer.contentLength(fromHeaderString: "Content-Length: +1")
    let duplicate = SimpleHTTPServer.contentLength(
      fromHeaderString: "Content-Length: 1\r\nContent-Length: 1"
    )
    let unsupportedTransferEncoding = SimpleHTTPServer.contentLength(
      fromHeaderString: "Transfer-Encoding: chunked"
    )

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
    let explicitlyPositiveError = try #require(explicitlyPositive.failureResponse)
    let duplicateError = try #require(duplicate.failureResponse)
    let transferEncodingError = try #require(unsupportedTransferEncoding.failureResponse)
    #expect(malformedError.statusCode == 400)
    #expect(negativeError.statusCode == 400)
    #expect(explicitlyPositiveError.statusCode == 400)
    #expect(duplicateError.statusCode == 400)
    #expect(transferEncodingError.statusCode == 400)
  }

  @Test
  func oversizedHeadersReturn431WithOrWithoutTerminator() throws {
    let unterminated = try #require(
      SimpleHTTPServer.headerLimitResponse(accumulatedCount: 65540, headerEnd: nil)
    )
    let terminated = try #require(
      SimpleHTTPServer.headerLimitResponse(accumulatedCount: 70000, headerEnd: 65537)
    )

    #expect(unterminated.statusCode == 431)
    #expect(terminated.statusCode == 431)
    let allowed = SimpleHTTPServer.headerLimitResponse(accumulatedCount: 65539, headerEnd: nil)
    #expect(allowed?.statusCode == nil)
  }

  @Test
  func parserRejectsBodiesThatDoNotExactlyMatchContentLength() throws {
    let shortBody = Data("POST /v1/system/reset HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}".utf8)
    let extraBody = Data("POST /v1/system/reset HTTP/1.1\r\nContent-Length: 1\r\n\r\n{}".utf8)

    let shortResponse = try #require(SimpleHTTPServer.parseHTTPRequest(shortBody).requestFailureResponse)
    let extraResponse = try #require(SimpleHTTPServer.parseHTTPRequest(extraBody).requestFailureResponse)

    #expect(shortResponse.statusCode == 400)
    #expect(extraResponse.statusCode == 400)
  }

  @Test
  func parserRejectsEncodedPathAliasesAndFragments() throws {
    let encodedHealth = Data("GET /v1%2Fhealth HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
    let fragmentedHealth = Data("GET /v1/health#ignored HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
    let authorityAlias = Data("GET //example.test/v1/health HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
    let encodedQuery = Data("GET /v1/health?value=hello%20world HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)

    #expect(try #require(SimpleHTTPServer.parseHTTPRequest(encodedHealth).requestFailureResponse).statusCode == 400)
    #expect(try #require(SimpleHTTPServer.parseHTTPRequest(fragmentedHealth).requestFailureResponse).statusCode == 400)
    #expect(try #require(SimpleHTTPServer.parseHTTPRequest(authorityAlias).requestFailureResponse).statusCode == 400)
    if case .success(let request) = SimpleHTTPServer.parseHTTPRequest(encodedQuery) {
      #expect(request.path == "/v1/health")
      #expect(request.queryParameters["value"] == "hello world")
    } else {
      Issue.record("Expected percent-encoded query values to remain supported")
    }
  }

  @Test(arguments: [
    "/v1/vms?limit=%ZZ",
    "/v1/vms?limit=%FF",
    "/v1/vms?limit=%00",
    "/v1/vms?limit=1&limit=2",
    "/v1/vms?%6cimit=1&limit=2",
    "/v1/vms?=1",
    "/v1/vms?limit=1&&offset=2",
  ])
  func parserRejectsMalformedOrAmbiguousQueryParameters(_ target: String) throws {
    let requestData = Data("GET \(target) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
    let response = try #require(SimpleHTTPServer.parseHTTPRequest(requestData).requestFailureResponse)

    #expect(response.statusCode == 400)
  }

  @Test
  func bearerAuthenticationSchemeIsCaseInsensitiveAndRequiresOneOrMoreSpaces() {
    #expect(SimpleHTTPServer.bearerToken(from: "Bearer token") == "token")
    #expect(SimpleHTTPServer.bearerToken(from: "bearer   token") == "token")
    #expect(SimpleHTTPServer.bearerToken(from: "BEARER token") == "token")
    #expect(SimpleHTTPServer.bearerToken(from: "Bearer") == nil)
    #expect(SimpleHTTPServer.bearerToken(from: "Bearer token extra") == nil)
    #expect(SimpleHTTPServer.bearerToken(from: "Basic token") == nil)
  }

  @Test
  func knownPathsReturn405AndAdvertiseAllowedMethods() async {
    let server = SimpleHTTPServer(port: 1, host: "127.0.0.1")
    server.get("/exact") { _ in HTTPResponse(statusCode: 200) }
    server.get("/items/{id}") { _ in HTTPResponse(statusCode: 200) }
    server.delete("/items/{id}") { _ in HTTPResponse(statusCode: 204) }

    let exact = await server.handleRequest(HTTPRequest(
      method: "POST",
      path: "/exact",
      headers: [:],
      body: nil,
      queryParameters: [:]
    ))
    let parameterized = await server.handleRequest(HTTPRequest(
      method: "PATCH",
      path: "/items/123",
      headers: [:],
      body: nil,
      queryParameters: [:]
    ))

    #expect(exact.statusCode == 405)
    #expect(exact.headers["Allow"] == "GET")
    #expect(parameterized.statusCode == 405)
    #expect(parameterized.headers["Allow"] == "DELETE, GET")
  }

  @Test
  func exactRouteCancellationReturns499() async {
    let server = SimpleHTTPServer(port: 1, host: "127.0.0.1")
    server.get("/cancelled") { _ in throw CancellationError() }

    let response = await server.handleRequest(HTTPRequest(
      method: "GET",
      path: "/cancelled",
      headers: [:],
      body: nil,
      queryParameters: [:]
    ))

    #expect(response.statusCode == 499)
  }

  @Test
  func parameterizedRouteErrorsReturn500() async {
    let server = SimpleHTTPServer(port: 1, host: "127.0.0.1")
    server.get("/items/{id}") { _ in throw HTTPPrimitiveTestError.routeFailure }

    let response = await server.handleRequest(HTTPRequest(
      method: "GET",
      path: "/items/123",
      headers: [:],
      body: nil,
      queryParameters: [:]
    ))

    #expect(response.statusCode == 500)
  }

  @Test
  func parameterizedRoutesRejectNonCanonicalSlashLayouts() async {
    let server = SimpleHTTPServer(port: 1, host: "127.0.0.1")
    server.get("/items/{id}") { _ in HTTPResponse(statusCode: 200) }

    for path in ["/items//123", "/items/123/", "//items/123", "/items/"] {
      let response = await server.handleRequest(HTTPRequest(
        method: "GET",
        path: path,
        headers: [:],
        body: nil,
        queryParameters: [:]
      ))
      #expect(response.statusCode == 404, "Expected non-canonical path \(path) to be rejected")
    }
  }

  @Test
  func routeRegistrationAndSnapshotsAreSafeWhenConcurrent() async {
    let server = SimpleHTTPServer(port: 1, host: "127.0.0.1")
    let routeCount = 200

    await withTaskGroup(of: Void.self) { group in
      for index in 0 ..< routeCount {
        group.addTask {
          server.get("/concurrent/\(index)") { _ in HTTPResponse(statusCode: 200) }
        }
        group.addTask {
          _ = server.registeredRouteSignatures
        }
      }
    }

    #expect(server.registeredRouteSignatures.count == routeCount)
  }

  @Test
  func connectionCancellationDrainsHandlerAndReleasesSlotOnce() async throws {
    let slotReleases = ThreadSafeCounter()
    let finishes = ThreadSafeCounter()
    let connectionCancellations = ThreadSafeCounter()
    let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
    let slot = HTTPConnectionSlot { slotReleases.increment() }
    let context = HTTPConnectionContext(
      connection: connection,
      slot: slot,
      cancelConnection: { connectionCancellations.increment() }
    ) {
      finishes.increment()
    }
    _ = try #require(context.installHandlerTask {
      Task<Void, Never> {
        while Task.isCancelled == false {
          await Task.yield()
        }
        context.finish()
      }
    })

    let cancelledHandler = try #require(context.requestCancellation())
    await cancelledHandler.value
    context.finish()
    _ = context.requestCancellation()

    #expect(slotReleases.value == 1)
    #expect(finishes.value == 1)
    #expect(connectionCancellations.value == 1)
  }

  @Test
  func stopInvalidatesListenerStartupBeforeTheListenerCanStart() async {
    let factory = BlockingListenerFactory()
    let server = SimpleHTTPServer(
      port: 12345,
      host: "127.0.0.1",
      listenerFactory: { parameters, port in
        try factory.makeListener(parameters: parameters, port: port)
      }
    )
    let startTask = Task.detached { () -> Bool in
      do {
        try server.start()
        return false
      } catch HTTPServerError.listenerStartupFailed(let error) {
        guard let readinessError = error as? NetworkListenerReadiness.ReadinessError,
              case .cancelled = readinessError else
        {
          return false
        }
        return true
      } catch {
        return false
      }
    }

    await factory.waitUntilEntered()
    do {
      try server.start()
      Issue.record("Expected a concurrent startup attempt to be rejected")
    } catch HTTPServerError.listenerStartupInProgress {
      // Expected while the first startup owns the lifecycle generation.
    } catch {
      Issue.record("Unexpected concurrent startup error: \(error)")
    }

    server.stop()
    factory.resumeCreation()

    #expect(await startTask.value)
  }

  @Test
  func queryParameterHelpersRejectInvalidValues() throws {
    let request = HTTPRequest(
      method: "GET",
      path: "/v1/vms",
      headers: [:],
      body: nil,
      queryParameters: ["limit": "0", "force": "maybe"]
    )

    #expect(throws: HTTPQueryParameterError.self) {
      _ = try HTTPQueryParameters.pagination(from: request)
    }
    #expect(throws: HTTPQueryParameterError.self) {
      _ = try HTTPQueryParameters.boolean(named: "force", in: request, defaultValue: false)
    }
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

private final class ThreadSafeCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}

private enum HTTPPrimitiveTestError: Error {
  case listenerFactoryReleased
  case routeFailure
}

private final class BlockingListenerFactory: @unchecked Sendable {
  private let lock = NSLock()
  private let creationGate = DispatchSemaphore(value: 0)
  private var didEnter = false
  private var entryWaiter: CheckedContinuation<Void, Never>?

  func makeListener(parameters _: NWParameters, port _: NWEndpoint.Port) throws -> NWListener {
    let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      didEnter = true
      let waiter = entryWaiter
      entryWaiter = nil
      return waiter
    }
    waiter?.resume()
    creationGate.wait()
    throw HTTPPrimitiveTestError.listenerFactoryReleased
  }

  func waitUntilEntered() async {
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock { () -> Bool in
        guard didEnter == false else { return true }
        entryWaiter = continuation
        return false
      }
      if shouldResume { continuation.resume() }
    }
  }

  func resumeCreation() {
    creationGate.signal()
  }
}

private extension Result where Success == Int, Failure == HTTPResponse {
  var failureResponse: HTTPResponse? {
    if case .failure(let response) = self { return response }
    return nil
  }
}

private extension Result where Success == HTTPRequest, Failure == HTTPResponse {
  var requestFailureResponse: HTTPResponse? {
    if case .failure(let response) = self { return response }
    return nil
  }
}
