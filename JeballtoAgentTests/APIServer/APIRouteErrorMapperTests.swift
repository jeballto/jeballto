import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiRoutes))
struct APIRouteErrorMapperTests {
  private func decodedError(_ response: HTTPResponse) throws -> ErrorResponse {
    try JSONDecoder().decode(ErrorResponse.self, from: #require(response.body))
  }

  @Test
  func parseAndValidationHelpersMapTo400() throws {
    let invalidId = APIRouteErrorMapper.invalidID()
    let missingBody = APIRouteErrorMapper.missingBody()
    let invalidJSON = APIRouteErrorMapper.invalidJSON(DecodingError.dataCorrupted(.init(
      codingPath: [],
      debugDescription: "bad"
    )))
    let invalidIDError = try decodedError(invalidId)

    #expect(invalidId.statusCode == 400)
    #expect(missingBody.statusCode == 400)
    #expect(invalidJSON.statusCode == 400)
    #expect(invalidIDError.error.code == "INVALID_ID")
  }

  @Test
  func vmNotFoundMapsTo404() throws {
    let response = APIRouteErrorMapper.vmManager(
      .vmNotFound(UUID()),
      defaultCode: "START_FAILED"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 404)
    #expect(decoded.error.code == "NOT_FOUND")
  }

  @Test
  func vmInvalidStateCanMapTo409() throws {
    let response = APIRouteErrorMapper.vmManager(
      .invalidState("bad state"),
      defaultCode: "EXECUTE_FAILED",
      invalidStateCode: "INVALID_STATE"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 409)
    #expect(decoded.error.code == "INVALID_STATE")
  }

  @Test
  func vmInvalidStateDefaultsTo409() throws {
    let response = APIRouteErrorMapper.vmManager(
      .invalidState("bad state"),
      defaultCode: "EXECUTE_FAILED"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 409)
    #expect(decoded.error.code == "INVALID_STATE")
  }

  @Test
  func vmLimitCanMapTo409() throws {
    let response = APIRouteErrorMapper.vmManager(
      .concurrentVMLimitReached("busy"),
      defaultCode: "START_FAILED",
      concurrentLimitCode: "VM_LIMIT_REACHED"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 409)
    #expect(decoded.error.code == "VM_LIMIT_REACHED")
  }

  @Test
  func unexpectedVmErrorsMapTo500() throws {
    let response = APIRouteErrorMapper.vmManager(
      .operationFailed("oops"),
      defaultCode: "START_FAILED"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 500)
    #expect(decoded.error.code == "START_FAILED")
  }

  @Test
  func vmTimeoutMapsTo504() throws {
    let response = APIRouteErrorMapper.vmManager(
      .timeout("disk resize"),
      defaultCode: "UPDATE_VM_FAILED"
    )

    #expect(response.statusCode == 504)
    #expect(try decodedError(response).error.code == "UPDATE_VM_FAILED")
  }

  @Test
  func commandExecutorTimeoutMapsTo504() throws {
    let timeout = APIRouteErrorMapper.commandExecutor(
      .timeout(command: "echo", seconds: 2),
      defaultCode: "EXECUTE_FAILED"
    )
    let launchFailure = APIRouteErrorMapper.commandExecutor(
      .processLaunchFailed("bad"),
      defaultCode: "EXECUTE_FAILED"
    )

    #expect(timeout.statusCode == 504)
    #expect(try decodedError(timeout).error.code == "EXECUTE_TIMEOUT")
    #expect(launchFailure.statusCode == 500)
  }

  @Test
  func imageNotFoundCanMapTo404() throws {
    let response = APIRouteErrorMapper.imageManager(
      .imageNotFoundById(UUID()),
      defaultCode: "DELETE_FAILED",
      notFoundCode: "IMAGE_NOT_FOUND",
      notFoundMessage: "Image not found"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 404)
    #expect(decoded.error.code == "IMAGE_NOT_FOUND")
  }

  @Test
  func imageNotFoundWithoutOverrideFallsBackTo500() throws {
    let response = APIRouteErrorMapper.imageManager(
      .imageNotFound("registry/repo:latest"),
      defaultCode: "DELETE_FAILED"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 500)
    #expect(decoded.error.code == "DELETE_FAILED")
  }

  @Test
  func registryUnavailableMapsTo503() throws {
    let response = APIRouteErrorMapper.imageManager(
      .registryUnavailable("registry.example.com"),
      defaultCode: "IMAGE_PUSH_FAILED"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 503)
    #expect(decoded.error.code == "IMAGE_PUSH_FAILED")
  }

  @Test
  func imageTimeoutMapsTo504() throws {
    let response = APIRouteErrorMapper.imageManager(
      .timeout("image pull registry.example.com/vm:latest"),
      defaultCode: "IMAGE_PULL_FAILED"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 504)
    #expect(decoded.error.code == "IMAGE_PULL_FAILED")
  }

  @Test
  func partiallyCommittedPushUsesItsOwnStableErrorCode() throws {
    let response = APIRouteErrorMapper.imageManager(
      .pushPartiallyCommitted(
        reference: "registry.example.com/repo:tag",
        digest: "sha256:\(String(repeating: "a", count: 64))",
        reason: "atomic rename failed"
      ),
      defaultCode: "IMAGE_PUSH_FAILED"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 500)
    #expect(decoded.error.code == "IMAGE_PUSH_PARTIALLY_COMMITTED")
    #expect(decoded.error.message.contains("Pull the reference to recover the local record"))
  }

  @Test
  func unknownPushCommitOutcomeUsesItsOwnStableErrorCode() throws {
    let response = APIRouteErrorMapper.imageManager(
      .pushCommitOutcomeUnknown(
        reference: "registry.example.com/repo:tag",
        digest: "sha256:\(String(repeating: "a", count: 64))",
        reason: "manifest process was interrupted"
      ),
      defaultCode: "IMAGE_PUSH_FAILED"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 500)
    #expect(decoded.error.code == "IMAGE_PUSH_COMMIT_OUTCOME_UNKNOWN")
    #expect(decoded.error.message.contains("may have been committed"))
  }

  @Test
  func invalidImageReferenceMapsTo400() throws {
    let response = APIRouteErrorMapper.imageManager(
      .invalidReference("bad reference"),
      defaultCode: "IMAGE_PULL_FAILED"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 400)
    #expect(decoded.error.code == "INVALID_REFERENCE")
  }

  @Test
  func unsupportedImageFormatMapsToSpecific400() throws {
    let response = APIRouteErrorMapper.imageManager(
      .unsupportedImageFormat("unversioned pre-1.0 image"),
      defaultCode: "IMAGE_PULL_FAILED"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 400)
    #expect(decoded.error.code == "UNSUPPORTED_IMAGE_FORMAT")
    #expect(decoded.error.message.contains("unversioned pre-1.0 image"))
  }

  @Test
  func invalidImageMapsToSpecific400() throws {
    let response = APIRouteErrorMapper.imageManager(
      .invalidImage("config is missing chunkSize"),
      defaultCode: "IMAGE_PULL_FAILED"
    )
    let decoded = try decodedError(response)

    #expect(response.statusCode == 400)
    #expect(decoded.error.code == "INVALID_IMAGE")
    #expect(decoded.error.message.contains("config is missing chunkSize"))
  }
}
