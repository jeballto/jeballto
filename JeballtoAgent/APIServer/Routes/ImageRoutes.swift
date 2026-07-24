import Foundation

private struct RegisteredImageOperation: Sendable {
  let status: ImageOperationStatus
}

// MARK: - Image & Registry Route Handlers

extension APIServer {
  private func startAdmittedImageOperation(
    kind: ImageOperationKind,
    reference: String,
    source: String? = nil,
    prepare: @Sendable @escaping () async throws -> ImageOperationPreparedWork
  ) async -> Result<RegisteredImageOperation, HTTPResponse> {
    do {
      let registration = try await imageOperationCoordinator.start(
        kind: kind,
        reference: reference,
        source: source,
        prepare: prepare
      )
      return .success(RegisteredImageOperation(status: registration.status))
    } catch let error as ImageOperationCoordinatorError {
      switch error {
      case .admissionsClosed:
        return .failure(HTTPResponse.error(
          "MAINTENANCE_IN_PROGRESS",
          message: "The agent is performing destructive maintenance",
          statusCode: 503
        ))
      case .capacityReached:
        return .failure(HTTPResponse.error(
          "TOO_MANY_IMAGE_OPERATIONS",
          message: error.localizedDescription,
          statusCode: 429
        ))
      }
    } catch is CancellationError {
      return .failure(HTTPResponse.error(
        kind == .pull ? "IMAGE_PULL_CANCELLED" : "IMAGE_PUSH_CANCELLED",
        message: "Image \(kind.rawValue) cancelled",
        statusCode: 499
      ))
    } catch {
      return .failure(HTTPResponse.error(
        kind == .pull ? "IMAGE_PULL_FAILED" : "IMAGE_PUSH_FAILED",
        message: error.localizedDescription,
        statusCode: 500
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

    let operations = await imageOperationCoordinator.list(kind: kind, activeOnly: activeOnly)
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
    let activeOperations = await imageOperationCoordinator.list(kind: kind, activeOnly: true)
    let finalOperations = await imageOperationCoordinator.cancelAll(kind: kind)
    return (tasksCancelled: activeOperations.count, operations: finalOperations)
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

    guard let status = await imageOperationCoordinator.status(for: operationId), status.kind == kind else {
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

    guard let status = await imageOperationCoordinator.status(for: operationId), status.kind == kind else {
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
    let admission = await startAdmittedImageOperation(kind: .pull, reference: reference) {
      ImageOperationPreparedWork { progressReporter in
        try await imageManager.pullImage(
          reference: reference,
          timeout: timeout,
          progressSink: progressReporter.sink
        )
      }
    }
    guard case .success(let registered) = admission else {
      if case .failure(let response) = admission { return response }
      return HTTPResponse.error("INTERNAL_ERROR", message: "Image operation admission failed", statusCode: 500)
    }
    let operation = registered.status
    guard let result = await imageOperationCoordinator.wait(for: operation.id) else {
      return HTTPResponse.error("IMAGE_OPERATION_NOT_FOUND", message: "Image operation not found", statusCode: 404)
    }

    switch result {
    case .success:
      guard let status = await imageOperationCoordinator.status(for: operation.id) else {
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
    let admission = await startAdmittedImageOperation(kind: .pull, reference: reference) {
      ImageOperationPreparedWork { progressReporter in
        try await imageManager.pullImage(
          reference: reference,
          progressSink: progressReporter.sink
        )
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

    guard let result = await imageOperationCoordinator.wait(for: registered.status.id) else {
      return .failure(HTTPResponse.error(
        "IMAGE_OPERATION_NOT_FOUND",
        message: "Image operation not found",
        statusCode: 404
      ))
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
    ) { [server] in
      try await server.prepareAdmittedPush(
        reference: reference,
        parsedSource: parsedSource,
        sourceUUID: sourceUUID,
        timeout: timeout
      )
    }
    guard case .success(let registered) = admission else {
      if case .failure(let response) = admission { return response }
      return HTTPResponse.error("INTERNAL_ERROR", message: "Image operation admission failed", statusCode: 500)
    }
    let operation = registered.status
    guard let result = await imageOperationCoordinator.wait(for: operation.id) else {
      return HTTPResponse.error("IMAGE_OPERATION_NOT_FOUND", message: "Image operation not found", statusCode: 404)
    }

    switch result {
    case .success:
      guard let status = await imageOperationCoordinator.status(for: operation.id) else {
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
    let admission = await startAdmittedImageOperation(kind: .pull, reference: reference) { [server] in
      ImageOperationPreparedWork { progressReporter in
        do {
          return try await server.imageManager.pullImage(
            reference: reference,
            timeout: timeout,
            progressSink: progressReporter.sink
          )
        } catch is CancellationError {
          logInfo("Async image pull cancelled for \(reference)", category: "APIServer")
          throw CancellationError()
        } catch {
          logError("Async image pull failed for \(reference): \(error)", category: "APIServer")
          throw error
        }
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
    ) { [server] in
      do {
        return try await server.prepareAdmittedPush(
          reference: reference,
          parsedSource: parsedSource,
          sourceUUID: sourceUUID,
          timeout: timeout
        )
      } catch is CancellationError {
        logInfo("Async image push cancelled for \(reference)", category: "APIServer")
        throw CancellationError()
      } catch {
        logError("Async image push failed for \(reference): \(error)", category: "APIServer")
        throw error
      }
    }
    guard case .success(let registered) = admission else {
      if case .failure(let response) = admission { return response }
      return HTTPResponse.error("INTERNAL_ERROR", message: "Image operation admission failed", statusCode: 500)
    }
    return HTTPResponse.json(ImageOperationStatusResponse(from: registered.status), statusCode: 202)
  }

  private func prepareAdmittedPush(
    reference: String,
    parsedSource: PushImageRequest.ParsedSource,
    sourceUUID: UUID,
    timeout: TimeInterval?
  ) async throws -> ImageOperationPreparedWork {
    let startedUptime = ProcessInfo.processInfo.systemUptime
    do {
      return try await ImageManager.withImageOperationDeadline(
        timeout: timeout,
        operationName: "image push source reservation \(reference)"
      ) {
        switch parsedSource.type {
        case .vm:
          let claim = try await self.vmManager.claimImageExportWithDefinition(sourceUUID)
          do {
            try Task.checkCancellation()
          } catch {
            await self.vmManager.releaseImageExport(sourceUUID, token: claim.token)
            throw error
          }
          let remainingTimeout = Self.remainingImageOperationTimeout(
            timeout,
            startedUptime: startedUptime
          )
          return ImageOperationPreparedWork(
            run: { progressReporter in
              try await self.imageManager.pushImageFromVM(
                reference: reference,
                vmBundlePath: claim.definition.paths.bundlePath,
                resources: claim.definition.resources,
                timeout: remainingTimeout,
                progressSink: progressReporter.sink
              )
            },
            release: {
              await self.vmManager.releaseImageExport(sourceUUID, token: claim.token)
            }
          )
        case .image:
          let claim = try await self.imageManager.claimImageExportWithRecord(sourceUUID)
          do {
            try Task.checkCancellation()
          } catch {
            await self.imageManager.releaseImageExport(sourceUUID, token: claim.token)
            throw error
          }
          let remainingTimeout = Self.remainingImageOperationTimeout(
            timeout,
            startedUptime: startedUptime
          )
          return ImageOperationPreparedWork(
            run: { progressReporter in
              try await self.imageManager.pushClaimedImage(
                reference: reference,
                sourceImageId: sourceUUID,
                existing: claim.record,
                timeout: remainingTimeout,
                progressSink: progressReporter.sink
              )
            },
            release: {
              await self.imageManager.releaseImageExport(sourceUUID, token: claim.token)
            }
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

  private nonisolated static func remainingImageOperationTimeout(
    _ timeout: TimeInterval?,
    startedUptime: TimeInterval
  ) -> TimeInterval? {
    timeout.map { max(0, $0 - (ProcessInfo.processInfo.systemUptime - startedUptime)) }
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

    _ = await imageOperationCoordinator.cancelAndWait(operationId)
    guard let cancelled = await imageOperationCoordinator.status(for: operationId) else {
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
