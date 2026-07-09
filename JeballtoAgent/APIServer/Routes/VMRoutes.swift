import Foundation

// MARK: - VM Lifecycle Route Handlers

extension APIServer {
  func handleCreateVM(_ request: HTTPRequest) async -> HTTPResponse {
    guard let body = request.body else {
      return APIRouteErrorMapper.missingBody()
    }

    let createRequest: CreateVMRequest
    do { createRequest = try JSONDecoder().decode(CreateVMRequest.self, from: body) } catch {
      return APIRouteErrorMapper.invalidJSON(error)
    }

    let createValidation = createRequest.validate()
    guard createValidation.valid else {
      return HTTPResponse.error(
        "INVALID_REQUEST",
        message: createValidation.error ?? "Invalid request",
        statusCode: 400
      )
    }

    if let imageRef = createRequest.image, !imageRef.isEmpty, let response = requireCapability(.ociImagePackaging) {
      return response
    }

    let ephemeral = createRequest.ephemeral ?? false
    let lifetimeSeconds = createRequest.lifetimeSeconds

    do {
      let definition: VMDefinition
      if let imageRef = createRequest.image, !imageRef.isEmpty {
        let imageRecord = try await imageManager.pullImage(reference: imageRef)
        definition = try await vmManager.createVMFromImage(
          name: createRequest.name,
          imagePath: imageRecord.localPath,
          ephemeral: ephemeral,
          lifetimeSeconds: lifetimeSeconds
        )
      } else {
        let resources = createRequest.resources?.toVMResources() ?? VMResources.default
        guard resources.validate() else {
          return HTTPResponse.error(
            "INVALID_RESOURCES",
            message: "Invalid resources: CPU count 1-32, memory 2GB-128GB, disk 20GB-8TB",
            statusCode: 400
          )
        }
        definition = try await vmManager.createVM(
          name: createRequest.name,
          resources: resources,
          ephemeral: ephemeral,
          lifetimeSeconds: lifetimeSeconds
        )
      }
      let response = await makeVMResponse(from: definition)
      return HTTPResponse.json(response, statusCode: 201)
    } catch let error as ImageManagerError {
      return APIRouteErrorMapper.imageManager(error, defaultCode: "IMAGE_PULL_FAILED")
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "CREATE_FAILED")
    } catch { return HTTPResponse.error("CREATE_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleListVMs(_ request: HTTPRequest) async -> HTTPResponse {
    let allVMs = await vmManager.listVMs()

    let requestedLimit = Int(request.queryParameters["limit"] ?? "") ?? 100
    let limit = max(1, min(requestedLimit, 1000))
    let offset = max(0, Int(request.queryParameters["offset"] ?? "") ?? 0)

    let paged = Array(allVMs.dropFirst(offset).prefix(limit))

    var vmResponses: [VMResponse] = []
    for vm in paged {
      await vmResponses.append(makeVMResponse(from: vm))
    }
    let response = VMListResponse(vms: vmResponses, total: allVMs.count, limit: limit, offset: offset)
    return HTTPResponse.json(response)
  }

  func handleGetVM(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    do {
      let definition = try await vmManager.getVM(vmId)
      let response = await makeVMResponse(from: definition)
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "GET_VM_FAILED")
    } catch { return HTTPResponse.error("GET_VM_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleStartVM(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }
    if let response = requireCapabilities(VirtualizationFeature.vmRuntimeRequirements) { return response }

    do {
      try await vmManager.startVM(vmId)
      let definition = try await vmManager.getVM(vmId)
      let response = await makeVMResponse(from: definition)
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(
        error,
        defaultCode: "START_FAILED",
        concurrentLimitCode: "VM_LIMIT_REACHED"
      )
    } catch { return HTTPResponse.error("START_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleStopVM(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }
    if let response = requireCapability(.macOSVirtualization) { return response }

    do {
      try await vmManager.stopVM(vmId)
      let definition = try await vmManager.getVM(vmId)
      let response = await makeVMResponse(from: definition)
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "STOP_FAILED")
    } catch { return HTTPResponse.error("STOP_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handlePauseVM(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }
    if let response = requireCapability(.macOSVirtualization) { return response }

    do {
      try await vmManager.pauseVM(vmId)
      let definition = try await vmManager.getVM(vmId)
      let response = await makeVMResponse(from: definition)
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "PAUSE_FAILED")
    } catch { return HTTPResponse.error("PAUSE_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleResumeVM(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }
    if let response = requireCapabilities(VirtualizationFeature.vmRuntimeRequirements) { return response }

    do {
      try await vmManager.resumeVM(vmId)
      let definition = try await vmManager.getVM(vmId)
      let response = await makeVMResponse(from: definition)
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "RESUME_FAILED")
    } catch { return HTTPResponse.error("RESUME_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleDeleteVM(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    let force = request.queryParameters["force"]?.lowercased() == "true"

    do {
      try await vmManager.deleteVM(vmId, deleteFiles: true, force: force)
      return HTTPResponse(statusCode: 204) // No content
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(
        error,
        defaultCode: "DELETE_FAILED",
        invalidStateCode: "INVALID_STATE"
      )
    } catch { return HTTPResponse.error("DELETE_FAILED", message: error.localizedDescription, statusCode: 500) }
  }

  func handleWipeAllVMs(_ request: HTTPRequest) async -> HTTPResponse {
    guard request.queryParameters["confirm"] == "true" else {
      return HTTPResponse.error(
        "CONFIRMATION_REQUIRED",
        message: "Add ?confirm=true to confirm deletion of all VMs",
        statusCode: 400
      )
    }

    do {
      await cancelActiveImageOperations()
      let (deleted, failed, errors) = try await vmManager.wipeAllVMs()
      let response = WipeAllResponse(deleted: deleted, failed: failed, errors: errors.isEmpty ? nil : errors)
      return HTTPResponse.json(response)
    } catch {
      return HTTPResponse.error("WIPE_FAILED", message: error.localizedDescription, statusCode: 500)
    }
  }

  func handleUpdateVM(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    guard let body = request.body else {
      return APIRouteErrorMapper.missingBody()
    }

    let updateRequest: UpdateVMRequest
    do { updateRequest = try JSONDecoder().decode(UpdateVMRequest.self, from: body) } catch {
      return APIRouteErrorMapper.invalidJSON(error)
    }

    let validation = updateRequest.validate()
    guard validation.valid else {
      return HTTPResponse.error("INVALID_REQUEST", message: validation.error ?? "Invalid request", statusCode: 400)
    }

    do {
      let definition = try await vmManager.updateVM(
        vmId,
        name: updateRequest.name,
        cpuCount: updateRequest.resources?.cpuCount,
        memorySize: updateRequest.resources?.memorySize?.bytes,
        diskSize: updateRequest.resources?.diskSize?.bytes
      )
      let response = await makeVMResponse(from: definition)
      return HTTPResponse.json(response)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(
        error,
        defaultCode: "UPDATE_VM_FAILED",
        invalidStateCode: "INVALID_STATE"
      )
    } catch {
      return HTTPResponse.error("UPDATE_VM_FAILED", message: error.localizedDescription, statusCode: 500)
    }
  }

  func handleCloneVM(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    guard let body = request.body else {
      return APIRouteErrorMapper.missingBody()
    }

    let cloneRequest: CloneVMRequest
    do { cloneRequest = try JSONDecoder().decode(CloneVMRequest.self, from: body) } catch {
      return APIRouteErrorMapper.invalidJSON(error)
    }

    let cloneValidation = cloneRequest.validate()
    guard cloneValidation.valid else {
      return HTTPResponse.error("INVALID_REQUEST", message: cloneValidation.error ?? "Invalid request", statusCode: 400)
    }

    let resources = cloneRequest.resources?.toVMResources()
    if let r = resources, !r.validate() {
      return HTTPResponse.error(
        "INVALID_RESOURCES",
        message: "Invalid resources: CPU count 1-32, memory 2GB-128GB, disk 20GB-8TB",
        statusCode: 400
      )
    }

    let force = request.queryParameters["force"]?.lowercased() == "true"
    let ephemeral = cloneRequest.ephemeral ?? false

    do {
      let definition = try await vmManager.cloneVM(
        vmId,
        name: cloneRequest.name,
        resources: resources,
        force: force,
        ephemeral: ephemeral
      )
      let response = await makeVMResponse(from: definition)
      return HTTPResponse.json(response, statusCode: 201)
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(
        error,
        defaultCode: "CLONE_FAILED",
        invalidStateCode: "INVALID_STATE"
      )
    } catch { return HTTPResponse.error("CLONE_FAILED", message: error.localizedDescription, statusCode: 500) }
  }
}
