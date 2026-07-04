import Foundation

// MARK: - Image & Registry Route Handlers

extension APIServer {
  func handleListImages(_ request: HTTPRequest) async -> HTTPResponse {
    let allImages = await imageManager.listImages()

    let requestedLimit = Int(request.queryParameters["limit"] ?? "") ?? allImages.count
    let limit = max(1, min(requestedLimit, 1000))
    let offset = max(0, Int(request.queryParameters["offset"] ?? "") ?? 0)

    let paged = Array(allImages.dropFirst(offset).prefix(limit))
    let response = ImageListResponse(images: paged, total: allImages.count, limit: limit, offset: offset)
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
    } catch { return HTTPResponse.error("IMAGE_NOT_FOUND", message: "Image not found", statusCode: 404) }
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
    guard request.queryParameters["confirm"] == "true" else {
      return HTTPResponse.error(
        "CONFIRMATION_REQUIRED",
        message: "Add ?confirm=true to confirm deletion of all images",
        statusCode: 400
      )
    }
    await cancelAllImageOperationTasks()
    let (deleted, failed, errors) = await imageManager.wipeAllImages()
    let response = WipeAllResponse(deleted: deleted, failed: failed, errors: errors.isEmpty ? nil : errors)
    return HTTPResponse.json(response)
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
      return HTTPResponse.error("INVALID_REFERENCE", message: validation.error ?? "Invalid reference", statusCode: 400)
    }

    let pullTimeout: TimeInterval? = pullRequest.timeout.map { TimeInterval($0) }
    if pullRequest.shouldRunAsync {
      let operation = await imageManager.startImageOperation(kind: .pull, reference: pullRequest.reference)
      let operationId = operation.id
      let reference = pullRequest.reference
      let progressSink = await imageManager.progressSink(for: operationId)
      let server = self
      startImageOperationTask(operationId) {
        Task<Void, Never> { [server] in
          let result: Result<ImageRecord, Error>
          do {
            let record = try await server.imageManager.pullImage(
              reference: reference,
              timeout: pullTimeout,
              progressSink: progressSink
            )
            result = .success(record)
          } catch is CancellationError {
            logInfo("Async image pull cancelled for \(reference)", category: "APIServer")
            result = .failure(CancellationError())
          } catch {
            logError("Async image pull failed for \(reference): \(error)", category: "APIServer")
            result = .failure(error)
          }
          await server.finishImageOperationTask(operationId, result: result)
        }
      }

      let response = ImagePullResponse(
        reference: pullRequest.reference,
        status: "started",
        digest: nil,
        image: nil,
        message: "Image pull started",
        operationId: operationId.uuidString,
        statusUrl: "/v1/images/pull/\(operationId.uuidString)/status"
      )
      return HTTPResponse.json(response, statusCode: 202)
    }

    do {
      let record = try await imageManager.pullImage(reference: pullRequest.reference, timeout: pullTimeout)
      let response = ImagePullResponse(
        reference: record.reference,
        status: "completed",
        digest: record.digest,
        image: ImageResponse(from: record),
        message: nil
      )
      return HTTPResponse.json(response)
    } catch is CancellationError {
      return HTTPResponse.error("IMAGE_PULL_CANCELLED", message: "Image pull cancelled", statusCode: 499)
    } catch let error as ImageManagerError {
      return APIRouteErrorMapper.imageManager(error, defaultCode: "IMAGE_PULL_FAILED")
    } catch { return HTTPResponse.error("IMAGE_PULL_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleGetImagePullStatus(_ request: HTTPRequest) async -> HTTPResponse {
    guard let operationId = extractImageOperationId(from: request.path, operation: "pull") else {
      return APIRouteErrorMapper.invalidID(resource: "image operation")
    }

    guard let status = await imageManager.getImageOperationStatus(operationId), status.kind == .pull else {
      return HTTPResponse.error("IMAGE_OPERATION_NOT_FOUND", message: "Image pull operation not found", statusCode: 404)
    }

    return HTTPResponse.json(ImageOperationStatusResponse(from: status))
  }

  func handleCancelImagePull(_ request: HTTPRequest) async -> HTTPResponse {
    await handleCancelImageOperation(request, kind: .pull)
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

    do {
      let pushTimeout: TimeInterval? = pushRequest.timeout.map { TimeInterval($0) }
      if pushRequest.shouldRunAsync {
        return await startAsyncPush(
          request: pushRequest,
          parsedSource: parsed,
          sourceUUID: sourceUUID,
          timeout: pushTimeout
        )
      }

      let record: ImageRecord
      switch parsed.type {
      case .vm:
        let vmDefinition = try await vmManager.getVM(sourceUUID)
        let exportToken = try await vmManager.claimImageExport(sourceUUID)
        do {
          record = try await imageManager.pushImageFromVM(
            reference: pushRequest.reference,
            vmBundlePath: vmDefinition.paths.bundlePath,
            timeout: pushTimeout
          )
          await vmManager.releaseImageExport(sourceUUID, token: exportToken)
        } catch {
          await vmManager.releaseImageExport(sourceUUID, token: exportToken)
          throw error
        }
      case .image:
        record = try await imageManager.pushImage(
          reference: pushRequest.reference,
          imageId: sourceUUID,
          timeout: pushTimeout
        )
      }

      let response = ImagePushResponse(
        reference: record.reference,
        status: "completed",
        digest: record.digest,
        image: ImageResponse(from: record),
        message: nil
      )
      return HTTPResponse.json(response)
    } catch is CancellationError {
      return HTTPResponse.error("IMAGE_PUSH_CANCELLED", message: "Image push cancelled", statusCode: 499)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(
        error,
        defaultCode: "IMAGE_PUSH_FAILED",
        notFoundMessage: "Source VM not found"
      )
    } catch let error as ImageManagerError {
      return APIRouteErrorMapper.imageManager(
        error,
        defaultCode: "IMAGE_PUSH_FAILED",
        notFoundCode: "IMAGE_NOT_FOUND",
        notFoundMessage: "Source image not found"
      )
    } catch { return HTTPResponse.error("IMAGE_PUSH_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleGetImagePushStatus(_ request: HTTPRequest) async -> HTTPResponse {
    guard let operationId = extractImageOperationId(from: request.path, operation: "push") else {
      return APIRouteErrorMapper.invalidID(resource: "image operation")
    }

    guard let status = await imageManager.getImageOperationStatus(operationId), status.kind == .push else {
      return HTTPResponse.error("IMAGE_OPERATION_NOT_FOUND", message: "Image push operation not found", statusCode: 404)
    }

    return HTTPResponse.json(ImageOperationStatusResponse(from: status))
  }

  func handleCancelImagePush(_ request: HTTPRequest) async -> HTTPResponse {
    await handleCancelImageOperation(request, kind: .push)
  }

  private func startAsyncPush(
    request pushRequest: PushImageRequest,
    parsedSource: PushImageRequest.ParsedSource,
    sourceUUID: UUID,
    timeout: TimeInterval?
  ) async -> HTTPResponse {
    let source = pushRequest.source
    let reference = pushRequest.reference

    do {
      let operation: ImageOperationStatus
      switch parsedSource.type {
      case .vm:
        let vmDefinition = try await vmManager.getVM(sourceUUID)
        let exportToken = try await vmManager.claimImageExport(sourceUUID)
        let vmBundlePath = vmDefinition.paths.bundlePath
        operation = await imageManager.startImageOperation(kind: .push, reference: reference, source: source)
        let operationId = operation.id
        let progressSink = await imageManager.progressSink(for: operationId)
        let server = self
        startImageOperationTask(operationId) {
          Task<Void, Never> { [server] in
            let result: Result<ImageRecord, Error>
            do {
              let record = try await server.imageManager.pushImageFromVM(
                reference: reference,
                vmBundlePath: vmBundlePath,
                timeout: timeout,
                progressSink: progressSink
              )
              result = .success(record)
            } catch is CancellationError {
              logInfo("Async image push cancelled for \(reference)", category: "APIServer")
              result = .failure(CancellationError())
            } catch {
              logError("Async image push failed for \(reference): \(error)", category: "APIServer")
              result = .failure(error)
            }
            await server.vmManager.releaseImageExport(sourceUUID, token: exportToken)
            await server.finishImageOperationTask(operationId, result: result)
          }
        }
      case .image:
        let exportToken = try await imageManager.claimImageExport(sourceUUID)
        do {
          _ = try await imageManager.getImage(id: sourceUUID)
          operation = await imageManager.startImageOperation(kind: .push, reference: reference, source: source)
        } catch {
          await imageManager.releaseImageExport(sourceUUID, token: exportToken)
          throw error
        }
        let operationId = operation.id
        let progressSink = await imageManager.progressSink(for: operationId)
        let server = self
        startImageOperationTask(operationId) {
          Task<Void, Never> { [server] in
            let result: Result<ImageRecord, Error>
            do {
              let record = try await server.imageManager.pushImage(
                reference: reference,
                imageId: sourceUUID,
                timeout: timeout,
                progressSink: progressSink,
                claimSource: false
              )
              result = .success(record)
            } catch is CancellationError {
              logInfo("Async image push cancelled for \(reference)", category: "APIServer")
              result = .failure(CancellationError())
            } catch {
              logError("Async image push failed for \(reference): \(error)", category: "APIServer")
              result = .failure(error)
            }
            await server.finishImageOperationTask(operationId, result: result)
            await server.imageManager.releaseImageExport(sourceUUID, token: exportToken)
          }
        }
      }
      let operationId = operation.id

      let response = ImagePushResponse(
        reference: reference,
        status: "started",
        digest: nil,
        image: nil,
        message: "Image push started",
        operationId: operationId.uuidString,
        statusUrl: "/v1/images/push/\(operationId.uuidString)/status"
      )
      return HTTPResponse.json(response, statusCode: 202)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(
        error,
        defaultCode: "IMAGE_PUSH_FAILED",
        notFoundMessage: "Source VM not found"
      )
    } catch let error as ImageManagerError {
      return APIRouteErrorMapper.imageManager(
        error,
        defaultCode: "IMAGE_PUSH_FAILED",
        notFoundCode: "IMAGE_NOT_FOUND",
        notFoundMessage: "Source image not found"
      )
    } catch {
      return HTTPResponse.error("IMAGE_PUSH_FAILED", message: error.localizedDescription, statusCode: 500)
    }
  }

  private func handleCancelImageOperation(_ request: HTTPRequest, kind: ImageOperationKind) async -> HTTPResponse {
    guard let operationId = extractImageOperationId(from: request.path, operation: kind.rawValue, includeStatus: false) else {
      return APIRouteErrorMapper.invalidID(resource: "image operation")
    }

    guard let status = await imageManager.getImageOperationStatus(operationId), status.kind == kind else {
      return HTTPResponse.error(
        "IMAGE_OPERATION_NOT_FOUND",
        message: "Image \(kind.rawValue) operation not found",
        statusCode: 404
      )
    }

    guard status.state.isTerminal == false else {
      return HTTPResponse.error(
        "IMAGE_OPERATION_NOT_RUNNING",
        message: "Image \(kind.rawValue) operation is already \(status.state.rawValue)",
        statusCode: 409
      )
    }

    _ = await imageManager.cancelImageOperation(operationId)
    if cancelImageOperationTask(operationId) == false {
      await imageManager.failImageOperation(operationId, error: CancellationError())
    }
    guard let cancelled = await imageManager.getImageOperationStatus(operationId) else {
      return HTTPResponse.error(
        "IMAGE_OPERATION_NOT_FOUND",
        message: "Image \(kind.rawValue) operation not found",
        statusCode: 404
      )
    }
    return HTTPResponse.json(ImageOperationStatusResponse(from: cancelled))
  }

  private func extractImageOperationId(from path: String, operation: String, includeStatus: Bool = true) -> UUID? {
    let components = path.split(separator: "/")
    guard components.count >= 4,
          components[0] == "v1",
          components[1] == "images",
          components[2] == Substring(operation) else { return nil }

    if includeStatus {
      guard components.count == 5,
            components[4] == "status" else { return nil }
    } else {
      guard components.count == 4 else { return nil }
    }

    return UUID(uuidString: String(components[3]))
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
        status: "authenticated",
        message: nil
      )
      return HTTPResponse.json(response)
    } catch {
      return HTTPResponse.error("REGISTRY_AUTH_FAILED", message: error.localizedDescription, statusCode: 401)
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
    } catch {
      return HTTPResponse.error("REGISTRY_LOGOUT_FAILED", message: error.localizedDescription, statusCode: 500)
    }
  }
}
