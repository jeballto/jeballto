import Foundation
import Network

enum HTTPRequestReadStep {
  case receiveMore(Data)
  case complete(Result<Data, HTTPResponse>?)
}

final class HTTPRequestReader: @unchecked Sendable {
  private let connection: NWConnection
  private let decoder: HTTPRequestDecoder

  init(connection: NWConnection, decoder: HTTPRequestDecoder = HTTPRequestDecoder()) {
    self.connection = connection
    self.decoder = decoder
  }

  func read(completion: @escaping @Sendable (Result<Data, HTTPResponse>?) -> Void) {
    receive(accumulatedData: Data(), completion: completion)
  }

  func evaluate(
    accumulatedData: Data,
    receivedData: Data?,
    isComplete: Bool,
    hasError: Bool
  ) -> HTTPRequestReadStep {
    guard let receivedData else {
      return .complete(accumulatedData.isEmpty ? nil : .failure(HTTPRequestDecoder.malformedRequestResponse))
    }

    var accumulated = accumulatedData
    accumulated.append(receivedData)

    let headerEnd = HTTPRequestDecoder.headerEnd(in: accumulated)
    if let response = decoder.headerLimitResponse(
      accumulatedCount: accumulated.count,
      headerEnd: headerEnd
    ) {
      logWarning(
        "Headers exceed \(HTTPRequestDecoder.maxHeaderSize) bytes, closing connection",
        category: "HTTPServer"
      )
      return .complete(.failure(response))
    }

    guard let headerEnd else {
      if isComplete || hasError {
        return .complete(.success(accumulated))
      }
      return .receiveMore(accumulated)
    }

    return evaluateBody(
      in: accumulated,
      headerEnd: headerEnd,
      isComplete: isComplete,
      hasError: hasError
    )
  }

  private func evaluateBody(
    in accumulated: Data,
    headerEnd: Data.Index,
    isComplete: Bool,
    hasError: Bool
  ) -> HTTPRequestReadStep {
    let headerData = accumulated[accumulated.startIndex ..< headerEnd]
    let headerString = String(data: headerData, encoding: .utf8) ?? ""
    let contentLength: Int
    switch decoder.contentLength(fromHeaderString: headerString) {
    case .success(let value):
      contentLength = value
    case .failure(let response):
      return .complete(.failure(response))
    }

    if contentLength > HTTPRequestDecoder.maxRequestBodySize {
      logWarning(
        "Content-Length \(contentLength) exceeds \(HTTPRequestDecoder.maxRequestBodySize), rejecting",
        category: "HTTPServer"
      )
      return .complete(.failure(HTTPRequestDecoder.payloadTooLargeResponse()))
    }

    let bodyStart = headerEnd + 4
    let receivedBodyLength = accumulated.endIndex - bodyStart
    if receivedBodyLength > HTTPRequestDecoder.maxRequestBodySize {
      logWarning(
        "Request body exceeds \(HTTPRequestDecoder.maxRequestBodySize) bytes while reading, rejecting",
        category: "HTTPServer"
      )
      return .complete(.failure(HTTPRequestDecoder.payloadTooLargeResponse()))
    }
    if receivedBodyLength > contentLength {
      return .complete(.failure(HTTPRequestDecoder.malformedRequestResponse))
    }
    if receivedBodyLength >= contentLength {
      return .complete(.success(accumulated))
    }
    if isComplete || hasError {
      return .complete(.failure(HTTPRequestDecoder.malformedRequestResponse))
    }
    return .receiveMore(accumulated)
  }

  private func receive(
    accumulatedData: Data,
    completion: @escaping @Sendable (Result<Data, HTTPResponse>?) -> Void
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
      switch self.evaluate(
        accumulatedData: accumulatedData,
        receivedData: data,
        isComplete: isComplete,
        hasError: error != nil
      ) {
      case .receiveMore(let accumulated):
        self.receive(accumulatedData: accumulated, completion: completion)
      case .complete(let result):
        completion(result)
      }
    }
  }
}
