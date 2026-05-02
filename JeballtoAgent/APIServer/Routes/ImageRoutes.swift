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

    do {
      let pullTimeout: TimeInterval? = pullRequest.timeout.map { TimeInterval($0) }
      let record = try await imageManager.pullImage(reference: pullRequest.reference, timeout: pullTimeout)
      let response = ImagePullResponse(
        reference: record.reference,
        status: "completed",
        digest: record.digest,
        image: ImageResponse(from: record),
        message: nil
      )
      return HTTPResponse.json(response)
    } catch let error as ImageManagerError {
      return APIRouteErrorMapper.imageManager(error, defaultCode: "IMAGE_PULL_FAILED")
    } catch { return HTTPResponse.error("IMAGE_PULL_FAILED", message: error.localizedDescription, statusCode: 500) }
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
      let record: ImageRecord
      switch parsed.type {
      case .vm:
        let vmDefinition = try await vmManager.getVM(sourceUUID)
        let vmState = try await vmManager.getVMState(sourceUUID)
        guard vmState == .stopped || vmState == .created else {
          return HTTPResponse.error(
            "INVALID_STATE",
            message: "VM must be stopped before pushing (current: \(vmState.rawValue))",
            statusCode: 409
          )
        }
        record = try await imageManager.pushImageFromVM(
          reference: pushRequest.reference,
          vmBundlePath: vmDefinition.paths.bundlePath,
          timeout: pushTimeout
        )
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
