import Foundation

private struct RegisteredImageOperation: Sendable {
  let status: ImageOperationStatus
  let task: Task<Result<ImageRecord, Error>, Never>
}

private struct ImageOperationProgressReporter: Sendable {
  let sink: ImageOperationProgressSink
}

final class ImageOperationStartGate: @unchecked Sendable {
  private let lock = NSLock()
  private var isOpen = false
  private var continuation: CheckedContinuation<Void, Never>?

  func wait() async {
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock { () -> Bool in
        if isOpen { return true }
        self.continuation = continuation
        return false
      }
      if shouldResume { continuation.resume() }
    }
  }

  func open() {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      isOpen = true
      let continuation = self.continuation
      self.continuation = nil
      return continuation
    }
    continuation?.resume()
  }
}

// MARK: - Image & Registry Route Handlers

extension APIServer {
  private func startAdmittedImageOperation(
    kind: ImageOperationKind,
    reference: String,
    source: String? = nil,
    operation: @Sendable @escaping (ImageOperationProgressReporter) async -> Result<ImageRecord, Error>
  ) async -> Result<RegisteredImageOperation, HTTPResponse> {
    let operationId = UUID()
    let gate = ImageOperationStartGate()
    let imageManager = imageManager
    let progressReporter = ImageOperationProgressReporter(sink: { update in
      await imageManager.updateImageOperationProgress(operationId, update: update)
    })
    let server = self
    guard let task = startImageOperationTask(operationId, start: {
      Task<Result<ImageRecord, Error>, Never> {
        await gate.wait()
        let result: Result<ImageRecord, Error> = if Task.isCancelled {
          .failure(CancellationError())
        } else {
          await operation(progressReporter)
        }
        await server.finishImageOperationTask(operationId, result: result)
        return result
      }
    }) else {
      return .failure(HTTPResponse.error(
        "MAINTENANCE_IN_PROGRESS",
        message: "The agent is performing destructive maintenance",
        statusCode: 503
      ))
    }

    do {
      let status = try await imageManager.admitImageOperation(
        id: operationId,
        kind: kind,
        reference: reference,
        source: source
      )
      gate.open()
      return .success(RegisteredImageOperation(status: status, task: task))
    } catch {
      task.cancel()
      gate.open()
      _ = await task.value
      releaseImageOperationTask(operationId)
      return .failure(HTTPResponse.error(
        "TOO_MANY_IMAGE_OPERATIONS",
        message: error.localizedDescription,
        statusCode: 429
      ))
    }
  }

  func handleListImages(_ request: HTTPRequest) async -> HTTPResponse {
    let pagination: (limit: Int, offset: Int)
    do {
      pagination = try HTTPQueryParameters.pagination(from: request)
    } catch {
      return invalidQueryParameter(error)
    }

    let allImages: [ImageRecord]
    do {
      allImages = try await imageManager.listImages()
    } catch {
      return HTTPResponse.error("IMAGE_STORE_UNAVAILABLE", message: error.localizedDescription, statusCode: 500)
    }

    let paged = Array(allImages.dropFirst(pagination.offset).prefix(pagination.limit))
    let response = ImageListResponse(
      images: paged,
      total: allImages.count,
      limit: pagination.limit,
      offset: pagination.offset
    )
    return HTTPResponse.json(response)
  }

  func handleGetImage(_ request: HTTPRequest) async -> HTTPResponse {
    guard let imageId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID(resource: "image")
    }

    do {
      let record = try await imageManager.getImage(id: imageId)
      let response = ImageResponse(from: record)
      return HTTPResponse.json(response)
    } catch let error as ImageManagerError {
      return APIRouteErrorMapper.imageManager(
        error,
        defaultCode: "IMAGE_LOOKUP_FAILED",
        notFoundCode: "IMAGE_NOT_FOUND",
        notFoundMessage: "Image not found"
      )
    } catch {
      return HTTPResponse.error("IMAGE_STORE_UNAVAILABLE", message: error.localizedDescription, statusCode: 500)
    }
  }

  func handleDeleteImage(_ request: HTTPRequest) async -> HTTPResponse {
    guard let imageId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID(resource: "image")
    }

    do {
      try await imageManager.deleteImage(id: imageId)
      return HTTPResponse(statusCode: 204)
    } catch let error as ImageManagerError {
      return APIRouteErrorMapper.imageManager(
        error,
        defaultCode: "DELETE_FAILED",
        notFoundCode: "IMAGE_NOT_FOUND",
        notFoundMessage: "Image not found"
      )
    } catch { return HTTPResponse.error("DELETE_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleWipeAllImages(_ request: HTTPRequest) async -> HTTPResponse {
    let confirmed: Bool
    do {
      confirmed = try HTTPQueryParameters.requiredTrue(named: "confirm", in: request)
    } catch {
      return invalidQueryParameter(error)
    }
    guard confirmed else {
      return HTTPResponse.error(
        "CONFIRMATION_REQUIRED",
        message: "Add ?confirm=true to confirm deletion of all images",
        statusCode: 400
      )
    }
    guard await beginExclusiveMaintenance() else {
      return HTTPResponse.error(
        "MAINTENANCE_IN_PROGRESS",
        message: "Another destructive maintenance operation is already running",
        statusCode: 409
      )
    }
    await cancelActiveImageOperations()
    await waitForActiveMutationsToDrain()
    let (deleted, failed, errors) = await imageManager.wipeAllImages()
    let response = WipeAllResponse(deleted: deleted, failed: failed, errors: errors.isEmpty ? nil : errors)
    await endExclusiveMaintenance()
    return HTTPResponse.json(response)
  }

  func handleListImagePullOperations(_ request: HTTPRequest) async -> HTTPResponse {
    await handleListImageOperations(request, kind: .pull)
  }

  func handleListImagePushOperations(_ request: HTTPRequest) async -> HTTPResponse {
    await handleListImageOperations(request, kind: .push)
  }

  private func handleListImageOperations(_ request: HTTPRequest, kind: ImageOperationKind) async -> HTTPResponse {
    let activeOnly: Bool
    do {
      activeOnly = try imageOperationActiveOnlyFilter(from: request, defaultValue: true)
    } catch let response as HTTPResponse {
      return response
    } catch {
      return invalidQueryParameter(error)
    }

    let operations = await imageManager.listImageOperationStatuses(kind: kind, activeOnly: activeOnly)
    return HTTPResponse.json(ImageOperationListResponse(operations: operations, activeOnly: activeOnly, type: kind))
  }

  func handleCancelImagePullOperations(_ request: HTTPRequest) async -> HTTPResponse {
    await handleCancelImageOperations(kind: .pull)
  }

  func handleCancelImagePushOperations(_ request: HTTPRequest) async -> HTTPResponse {
    await handleCancelImageOperations(kind: .push)
  }

  private func handleCancelImageOperations(kind: ImageOperationKind) async -> HTTPResponse {
    let result = await cancelActiveImageOperations(kind: kind)

    return HTTPResponse.json(ImageOperationCancelAllResponse(
      cancelled: result.operations.count,
      tasksCancelled: result.tasksCancelled,
      operations: result.operations
    ))
  }

  @discardableResult
  func cancelActiveImageOperations(kind: ImageOperationKind? = nil) async -> (
    tasksCancelled: Int,
    operations: [ImageOperationStatus]
  ) {
    let activeOperations = await imageManager.listImageOperationStatuses(kind: kind, activeOnly: true)
    var cancelledIds = Set<UUID>()
    for operation in activeOperations {
      if await imageManager.cancelImageOperation(operation.id) {
        cancelledIds.insert(operation.id)
      }
    }

    let tasksCancelled = await cancelAndWaitImageOperationTasks(cancelledIds)
    for operationId in cancelledIds {
      if let status = await imageManager.getImageOperationStatus(operationId), status.state.isTerminal == false {
        await imageManager.failImageOperation(operationId, error: CancellationError())
      }
    }

    var finalOperations: [ImageOperationStatus] = []
    for operationId in cancelledIds {
      if let status = await imageManager.getImageOperationStatus(operationId) {
        finalOperations.append(status)
      }
    }
    finalOperations.sort { lhs, rhs in
      if lhs.startedUptime != rhs.startedUptime { return lhs.startedUptime > rhs.startedUptime }
      return lhs.id.uuidString < rhs.id.uuidString
    }

    return (tasksCancelled: tasksCancelled, operations: finalOperations)
  }

  func handleGetImagePullOperation(_ request: HTTPRequest) async -> HTTPResponse {
    await handleGetImageOperation(request, kind: .pull)
  }

  func handleGetImagePushOperation(_ request: HTTPRequest) async -> HTTPResponse {
    await handleGetImageOperation(request, kind: .push)
  }

  private func handleGetImageOperation(_ request: HTTPRequest, kind: ImageOperationKind) async -> HTTPResponse {
    guard let operationId = extractTypedOperationId(from: request.path, kind: kind) else {
      return APIRouteErrorMapper.invalidID(resource: "image operation")
    }

    guard let status = await imageManager.getImageOperationStatus(operationId), status.kind == kind else {
      return HTTPResponse.error(
        "IMAGE_OPERATION_NOT_FOUND",
        message: "Image \(kind.rawValue) operation not found",
        statusCode: 404
      )
    }

    return HTTPResponse.json(ImageOperationStatusResponse(from: status))
  }

  func handleCancelImagePullOperation(_ request: HTTPRequest) async -> HTTPResponse {
    await handleCancelImageOperation(request, kind: .pull)
  }

  func handleCancelImagePushOperation(_ request: HTTPRequest) async -> HTTPResponse {
    await handleCancelImageOperation(request, kind: .push)
  }

  private func handleCancelImageOperation(_ request: HTTPRequest, kind: ImageOperationKind) async -> HTTPResponse {
    guard let operationId = extractTypedOperationId(from: request.path, kind: kind) else {
      return APIRouteErrorMapper.invalidID(resource: "image operation")
    }

    guard let status = await imageManager.getImageOperationStatus(operationId), status.kind == kind else {
      return HTTPResponse.error(
        "IMAGE_OPERATION_NOT_FOUND",
        message: "Image \(kind.rawValue) operation not found",
        statusCode: 404
      )
    }

    return await cancelImageOperation(operationId, currentStatus: status)
  }

  func handlePullImage(_ request: HTTPRequest) async -> HTTPResponse {
    guard let body = request.body else {
      return APIRouteErrorMapper.missingBody()
    }

    let pullRequest: PullImageRequest
    do { pullRequest = try JSONDecoder().decode(PullImageRequest.self, from: body) } catch {
      return APIRouteErrorMapper.invalidJSON(error)
    }

    let validation = pullRequest.validate()
    guard validation.valid else {
      return HTTPResponse.error(
        pullRequest.validationFailureCode,
        message: validation.error ?? "Invalid image pull request",
        statusCode: 400
      )
    }
    if let response = requireCapability(.ociImagePackaging) { return response }

    let pullTimeout: TimeInterval? = pullRequest.timeout.map { TimeInterval($0) }
    if pullRequest.shouldRunAsync {
      return await startAsyncPull(request: pullRequest, timeout: pullTimeout)
    }

    return await runBlockingPull(request: pullRequest, timeout: pullTimeout)
  }

  private func runBlockingPull(request pullRequest: PullImageRequest, timeout: TimeInterval?) async -> HTTPResponse {
    let reference = pullRequest.reference
    let imageManager = imageManager
    let admission = await startAdmittedImageOperation(kind: .pull, reference: reference) { progressReporter in
      do {
        return try await .success(imageManager.pullImage(
          reference: reference,
          timeout: timeout,
          progressSink: progressReporter.sink
        ))
      } catch {
        return .failure(error)
      }
    }
    guard case .success(let registered) = admission else {
      if case .failure(let response) = admission { return response }
      return HTTPResponse.error("INTERNAL_ERROR", message: "Image operation admission failed", statusCode: 500)
    }
    let operation = registered.status
    let task = registered.task
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }

    switch result {
    case .success:
      guard let status = await imageManager.getImageOperationStatus(operation.id) else {
        return HTTPResponse.error("IMAGE_OPERATION_NOT_FOUND", message: "Image operation not found", statusCode: 404)
      }
      return HTTPResponse.json(ImageOperationStatusResponse(from: status))
    case .failure(let error) where error is CancellationError:
      return HTTPResponse.error("IMAGE_PULL_CANCELLED", message: "Image pull cancelled", statusCode: 499)
    case .failure(let error as ImageManagerError):
      return APIRouteErrorMapper.imageManager(error, defaultCode: "IMAGE_PULL_FAILED")
    case .failure(let error):
      return HTTPResponse.error("IMAGE_PULL_FAILED", message: error.localizedDescription, statusCode: 500)
    }
  }

  func pullImageForVMCreation(reference: String) async -> Result<ImageRecord, HTTPResponse> {
    let imageManager = imageManager
    let admission = await startAdmittedImageOperation(kind: .pull, reference: reference) { progressReporter in
      do {
        return try await .success(imageManager.pullImage(
          reference: reference,
          progressSink: progressReporter.sink
        ))
      } catch {
        return .failure(error)
      }
    }
    guard case .success(let registered) = admission else {
      if case .failure(let response) = admission { return .failure(response) }
      return .failure(HTTPResponse.error(
        "INTERNAL_ERROR",
        message: "Image operation admission failed",
        statusCode: 500
      ))
    }

    let result = await withTaskCancellationHandler {
      await registered.task.value
    } onCancel: {
      registered.task.cancel()
    }

    switch result {
    case .success(let record):
      return .success(record)
    case .failure(let error) where error is CancellationError:
      return .failure(HTTPResponse.error(
        "IMAGE_PULL_CANCELLED",
        message: "Image pull cancelled",
        statusCode: 499
      ))
    case .failure(let error as ImageManagerError):
      return .failure(APIRouteErrorMapper.imageManager(error, defaultCode: "IMAGE_PULL_FAILED"))
    case .failure(let error):
      return .failure(HTTPResponse.error(
        "IMAGE_PULL_FAILED",
        message: error.localizedDescription,
        statusCode: 500
      ))
    }
  }

  func handlePushImage(_ request: HTTPRequest) async -> HTTPResponse {
    guard let body = request.body else {
      return APIRouteErrorMapper.missingBody()
    }

    let pushRequest: PushImageRequest
    do { pushRequest = try JSONDecoder().decode(PushImageRequest.self, from: body) } catch {
      return APIRouteErrorMapper.invalidJSON(error)
    }

    let validation = pushRequest.validate()
    guard validation.valid else {
      return HTTPResponse.error("INVALID_REQUEST", message: validation.error ?? "Invalid request", statusCode: 400)
    }

    guard let parsed = pushRequest.parseSource(),
          let sourceUUID = UUID(uuidString: parsed.id) else
    {
      return HTTPResponse.error(
        "INVALID_REQUEST",
        message: "Invalid source format. Use 'vm:<uuid>' or 'image:<uuid>'",
        statusCode: 400
      )
    }
    if let response = requireCapability(.ociImagePackaging) { return response }

    let pushTimeout: TimeInterval? = pushRequest.timeout.map { TimeInterval($0) }
    if pushRequest.shouldRunAsync {
      return await startAsyncPush(
        request: pushRequest,
        parsedSource: parsed,
        sourceUUID: sourceUUID,
        timeout: pushTimeout
      )
    }

    return await runBlockingPush(
      request: pushRequest,
      parsedSource: parsed,
      sourceUUID: sourceUUID,
      timeout: pushTimeout
    )
  }

  private func runBlockingPush(
    request pushRequest: PushImageRequest,
    parsedSource: PushImageRequest.ParsedSource,
    sourceUUID: UUID,
    timeout: TimeInterval?
  ) async -> HTTPResponse {
    let reference = pushRequest.reference
    let server = self
    let admission = await startAdmittedImageOperation(
      kind: .push,
      reference: reference,
      source: pushRequest.source
    ) { [server] progressReporter in
      do {
        return try await .success(server.performAdmittedPush(
          reference: reference,
          parsedSource: parsedSource,
          sourceUUID: sourceUUID,
          timeout: timeout,
          progressSink: progressReporter.sink
        ))
      } catch {
        return .failure(error)
      }
    }
    guard case .success(let registered) = admission else {
      if case .failure(let response) = admission { return response }
      return HTTPResponse.error("INTERNAL_ERROR", message: "Image operation admission failed", statusCode: 500)
    }
    let operation = registered.status
    let task = registered.task
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }

    switch result {
    case .success:
      guard let status = await imageManager.getImageOperationStatus(operation.id) else {
        return HTTPResponse.error("IMAGE_OPERATION_NOT_FOUND", message: "Image operation not found", statusCode: 404)
      }
      return HTTPResponse.json(ImageOperationStatusResponse(from: status))
    case .failure(let error) where error is CancellationError:
      return HTTPResponse.error("IMAGE_PUSH_CANCELLED", message: "Image push cancelled", statusCode: 499)
    case .failure(let error as VMManagerError):
      return APIRouteErrorMapper.vmManager(
        error,
        defaultCode: "IMAGE_PUSH_FAILED",
        notFoundMessage: "Source VM not found"
      )
    case .failure(let error as ImageManagerError):
      return APIRouteErrorMapper.imageManager(
        error,
        defaultCode: "IMAGE_PUSH_FAILED",
        notFoundCode: "IMAGE_NOT_FOUND",
        notFoundMessage: "Source image not found"
      )
    case .failure(let error):
      return HTTPResponse.error("IMAGE_PUSH_FAILED", message: error.localizedDescription, statusCode: 500)
    }
  }

  private func startAsyncPull(request pullRequest: PullImageRequest, timeout: TimeInterval?) async -> HTTPResponse {
    let reference = pullRequest.reference
    let server = self
    let admission = await startAdmittedImageOperation(kind: .pull, reference: reference) { [server] progressReporter in
      do {
        return try await .success(server.imageManager.pullImage(
          reference: reference,
          timeout: timeout,
          progressSink: progressReporter.sink
        ))
      } catch is CancellationError {
        logInfo("Async image pull cancelled for \(reference)", category: "APIServer")
        return .failure(CancellationError())
      } catch {
        logError("Async image pull failed for \(reference): \(error)", category: "APIServer")
        return .failure(error)
      }
    }
    guard case .success(let registered) = admission else {
      if case .failure(let response) = admission { return response }
      return HTTPResponse.error("INTERNAL_ERROR", message: "Image operation admission failed", statusCode: 500)
    }
    return HTTPResponse.json(ImageOperationStatusResponse(from: registered.status), statusCode: 202)
  }

  private func startAsyncPush(
    request pushRequest: PushImageRequest,
    parsedSource: PushImageRequest.ParsedSource,
    sourceUUID: UUID,
    timeout: TimeInterval?
  ) async -> HTTPResponse {
    let source = pushRequest.source
    let reference = pushRequest.reference
    let server = self
    let admission = await startAdmittedImageOperation(
      kind: .push,
      reference: reference,
      source: source
    ) { [server] progressReporter in
      do {
        return try await .success(server.performAdmittedPush(
          reference: reference,
          parsedSource: parsedSource,
          sourceUUID: sourceUUID,
          timeout: timeout,
          progressSink: progressReporter.sink
        ))
      } catch is CancellationError {
        logInfo("Async image push cancelled for \(reference)", category: "APIServer")
        return .failure(CancellationError())
      } catch {
        logError("Async image push failed for \(reference): \(error)", category: "APIServer")
        return .failure(error)
      }
    }
    guard case .success(let registered) = admission else {
      if case .failure(let response) = admission { return response }
      return HTTPResponse.error("INTERNAL_ERROR", message: "Image operation admission failed", statusCode: 500)
    }
    return HTTPResponse.json(ImageOperationStatusResponse(from: registered.status), statusCode: 202)
  }

  private func performAdmittedPush(
    reference: String,
    parsedSource: PushImageRequest.ParsedSource,
    sourceUUID: UUID,
    timeout: TimeInterval?,
    progressSink: @escaping ImageOperationProgressSink
  ) async throws -> ImageRecord {
    do {
      return try await ImageManager.withImageOperationDeadline(
        timeout: timeout,
        operationName: "image push \(reference)"
      ) {
        switch parsedSource.type {
        case .vm:
          let claim = try await self.vmManager.claimImageExportWithDefinition(sourceUUID)
          do {
            let record = try await self.imageManager.pushImageFromVM(
              reference: reference,
              vmBundlePath: claim.definition.paths.bundlePath,
              resources: claim.definition.resources,
              timeout: timeout,
              progressSink: progressSink
            )
            await self.vmManager.releaseImageExport(sourceUUID, token: claim.token)
            return record
          } catch {
            await self.vmManager.releaseImageExport(sourceUUID, token: claim.token)
            throw error
          }
        case .image:
          return try await self.imageManager.pushImage(
            reference: reference,
            imageId: sourceUUID,
            timeout: timeout,
            progressSink: progressSink
          )
        }
      }
    } catch let error as OrasError {
      if case .timeout(let operation) = error {
        throw ImageManagerError.timeout(operation)
      }
      throw error
    }
  }

  private func cancelImageOperation(
    _ operationId: UUID,
    currentStatus status: ImageOperationStatus
  ) async -> HTTPResponse {
    guard status.state.isTerminal == false else {
      return HTTPResponse.error(
        "IMAGE_OPERATION_NOT_RUNNING",
        message: "Image \(status.kind.rawValue) operation is already \(status.state.rawValue)",
        statusCode: 409
      )
    }

    _ = await imageManager.cancelImageOperation(operationId)
    if await cancelAndWaitImageOperationTask(operationId) == false {
      await imageManager.failImageOperation(operationId, error: CancellationError())
    } else if let status = await imageManager.getImageOperationStatus(operationId), status.state.isTerminal == false {
      await imageManager.failImageOperation(operationId, error: CancellationError())
    }
    guard let cancelled = await imageManager.getImageOperationStatus(operationId) else {
      return HTTPResponse.error(
        "IMAGE_OPERATION_NOT_FOUND",
        message: "Image operation not found",
        statusCode: 404
      )
    }
    return HTTPResponse.json(ImageOperationStatusResponse(from: cancelled))
  }

  private func extractTypedOperationId(from path: String, kind: ImageOperationKind) -> UUID? {
    let components = path.split(separator: "/")
    guard components.count == 5,
          components[0] == "v1",
          components[1] == "images",
          components[2] == Substring(kind.rawValue),
          components[3] == "operations" else { return nil }

    return UUID(uuidString: String(components[4]))
  }

  private func imageOperationActiveOnlyFilter(from request: HTTPRequest, defaultValue: Bool) throws -> Bool {
    try HTTPQueryParameters.boolean(named: "activeOnly", in: request, defaultValue: defaultValue) ?? defaultValue
  }

  // MARK: - Registry Handlers

  func handleRegistryLogin(_ request: HTTPRequest) async -> HTTPResponse {
    guard let body = request.body else {
      return APIRouteErrorMapper.missingBody()
    }

    let loginRequest: RegistryLoginRequest
    do { loginRequest = try JSONDecoder().decode(RegistryLoginRequest.self, from: body) } catch {
      return APIRouteErrorMapper.invalidJSON(error)
    }

    let validation = loginRequest.validate()
    guard validation.valid else {
      return HTTPResponse.error("INVALID_REQUEST", message: validation.error ?? "Invalid request", statusCode: 400)
    }

    do {
      try await imageManager.loginRegistry(
        registry: loginRequest.registry,
        username: loginRequest.username,
        password: loginRequest.password
      )
      let response = RegistryLoginResponse(
        registry: loginRequest.registry,
        status: "authenticated"
      )
      return HTTPResponse.json(response)
    } catch is CancellationError {
      return HTTPResponse.error("REGISTRY_AUTH_CANCELLED", message: "Registry login cancelled", statusCode: 499)
    } catch let error as ImageManagerError {
      return APIRouteErrorMapper.imageManager(error, defaultCode: "REGISTRY_UNAVAILABLE")
    } catch let error as RegistryCredentialStoreError {
      return HTTPResponse.error(
        "REGISTRY_CREDENTIAL_STORE_FAILED",
        message: error.localizedDescription,
        statusCode: 500
      )
    } catch let error as KeychainSecretStoreError {
      return HTTPResponse.error(
        "REGISTRY_CREDENTIAL_STORE_FAILED",
        message: error.localizedDescription,
        statusCode: 500
      )
    } catch let error as OrasError {
      switch error {
      case .invalidInput:
        return HTTPResponse.error("INVALID_REQUEST", message: error.localizedDescription, statusCode: 400)
      case .timeout:
        return HTTPResponse.error("REGISTRY_AUTH_TIMEOUT", message: error.localizedDescription, statusCode: 504)
      case .commandFailed(let exitCode, _) where exitCode != -1:
        return HTTPResponse.error("REGISTRY_AUTH_FAILED", message: error.localizedDescription, statusCode: 401)
      case .orasNotFound, .commandFailed, .invalidOutput, .manifestCommitOutcomeUnknown:
        return HTTPResponse.error("REGISTRY_TOOL_ERROR", message: error.localizedDescription, statusCode: 500)
      }
    } catch {
      return HTTPResponse.error("REGISTRY_TOOL_ERROR", message: error.localizedDescription, statusCode: 500)
    }
  }

  func handleRegistryLogout(_ request: HTTPRequest) async -> HTTPResponse {
    guard let body = request.body else {
      return APIRouteErrorMapper.missingBody()
    }

    let logoutRequest: RegistryLogoutRequest
    do { logoutRequest = try JSONDecoder().decode(RegistryLogoutRequest.self, from: body) } catch {
      return APIRouteErrorMapper.invalidJSON(error)
    }

    let logoutValidation = logoutRequest.validate()
    guard logoutValidation.valid else {
      return HTTPResponse.error(
        "INVALID_REQUEST",
        message: logoutValidation.error ?? "Invalid request",
        statusCode: 400
      )
    }

    do {
      try await imageManager.logoutRegistry(registry: logoutRequest.registry)
      return HTTPResponse.json(SuccessResponse(message: "Logged out from \(logoutRequest.registry)"))
    } catch is CancellationError {
      return HTTPResponse.error("REGISTRY_LOGOUT_CANCELLED", message: "Registry logout cancelled", statusCode: 499)
    } catch let error as RegistryCredentialStoreError {
      return HTTPResponse.error(
        "REGISTRY_CREDENTIAL_STORE_FAILED",
        message: error.localizedDescription,
        statusCode: 500
      )
    } catch let error as KeychainSecretStoreError {
      return HTTPResponse.error(
        "REGISTRY_CREDENTIAL_STORE_FAILED",
        message: error.localizedDescription,
        statusCode: 500
      )
    } catch let error as OrasError {
      switch error {
      case .invalidInput:
        return HTTPResponse.error("INVALID_REQUEST", message: error.localizedDescription, statusCode: 400)
      case .timeout:
        return HTTPResponse.error("REGISTRY_LOGOUT_TIMEOUT", message: error.localizedDescription, statusCode: 504)
      case .orasNotFound, .commandFailed, .invalidOutput, .manifestCommitOutcomeUnknown:
        return HTTPResponse.error("REGISTRY_LOGOUT_FAILED", message: error.localizedDescription, statusCode: 500)
      }
    } catch {
      return HTTPResponse.error("REGISTRY_LOGOUT_FAILED", message: error.localizedDescription, statusCode: 500)
    }
  }
}
