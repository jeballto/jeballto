import Foundation

/// Errors from image management operations
enum ImageManagerError: Error, LocalizedError {
  case imageNotFound(String)
  case imageNotFoundById(UUID)
  case pullFailed(String)
  case pushFailed(String)
  case deleteFailed(String)
  case invalidReference(String)
  case registryUnreachable(String)

  var errorDescription: String? {
    switch self {
    case .imageNotFound(let ref): "Image not found: \(ref)"
    case .imageNotFoundById(let id): "Image not found with ID: \(id.uuidString)"
    case .pullFailed(let msg): "Image pull failed: \(msg)"
    case .pushFailed(let msg): "Image push failed: \(msg)"
    case .deleteFailed(let msg): "Image delete failed: \(msg)"
    case .invalidReference(let msg): "Invalid image reference: \(msg)"
    case .registryUnreachable(let msg): "Registry unreachable: \(msg)"
    }
  }
}

/// Central orchestrator for OCI image operations.
/// Pushes VM bundle directories directly via oras (which auto-compresses directories
/// as tar+gzip OCI layers). No manual compression step needed.
actor ImageManager {
  private let imageStore: ImageStore
  private let orasClient: OrasClient
  private let eventBus: EventBus
  private let config: Config

  init(imageStore: ImageStore, orasClient: OrasClient, eventBus: EventBus, config: Config) {
    self.imageStore = imageStore
    self.orasClient = orasClient
    self.eventBus = eventBus
    self.config = config
    cleanupStaleOrasTempDirs(storageDir: config.images.imageStorageDir)
  }

  // MARK: - Startup Cleanup

  private nonisolated func cleanupStaleOrasTempDirs(storageDir: String) {
    let fileManager = FileManager.default
    guard let contents = try? fileManager.contentsOfDirectory(atPath: storageDir) else { return }

    for item in contents where item.hasPrefix("oras-tmp-") {
      let path = "\(storageDir)/\(item)"
      logInfo("Cleaning up stale oras temp directory: \(path)", category: "ImageManager")
      try? fileManager.removeItem(atPath: path)
    }
  }

  // MARK: - Queries

  func listImages() async -> [ImageRecord] {
    await imageStore.listImages()
  }

  func getImage(id: UUID) async throws -> ImageRecord {
    guard let record = await imageStore.getImage(id: id) else {
      throw ImageManagerError.imageNotFoundById(id)
    }
    return record
  }

  func getImageByReference(_ reference: String) async throws -> ImageRecord {
    guard let record = await imageStore.getImageByReference(reference) else {
      throw ImageManagerError.imageNotFound(reference)
    }
    return record
  }

  // MARK: - Pull

  /// Pulls an OCI artifact from a registry and stores it in the local image store.
  ///
  /// Uses `oras pull` under the hood. Layers are decompressed and flattened so the VM bundle
  /// files (`Disk.img`, `HardwareModel`, etc.) sit directly inside a `.bundle` directory
  /// named after the image UUID, matching the VM storage format.
  /// If the image already exists locally (same reference), returns the existing record immediately
  /// without network access - this is intentional for CI/CD idempotency.
  func pullImage(reference: String, timeout: TimeInterval? = nil) async throws -> ImageRecord {
    let parsed: ImageReference
    do {
      parsed = try ImageReference.parse(reference)
    } catch {
      throw ImageManagerError.invalidReference(error.localizedDescription)
    }

    // CI/CD behavior: if already local, return immediately
    if let existing = await imageStore.getImageByReference(parsed.fullReference) {
      logInfo("Image already local: \(parsed.fullReference)", category: "ImageManager")
      return existing
    }

    logInfo("Pulling image: \(parsed.fullReference)", category: "ImageManager")
    eventBus.publish(.imagePullStarted(reference: parsed.fullReference))

    let imageId = UUID()
    let localDir = "\(config.images.imageStorageDir)/\(imageId.uuidString).bundle"

    do {
      try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)

      let insecure = parsed.isInsecureAllowed(insecureRegistries: config.images.insecureRegistries)
      let pullResult = try await orasClient.pull(
        reference: parsed,
        outputDir: localDir,
        insecure: insecure,
        timeout: timeout
      )

      // oras extracts directory layers into a subdirectory (e.g. localDir/VM.bundle/).
      // Flatten so bundle files (Disk.img, HardwareModel, etc.) sit directly in localDir.
      try flattenPulledBundle(inDir: localDir)

      let size = directorySize(atPath: localDir)

      let record = ImageRecord(
        id: imageId,
        reference: parsed.fullReference,
        digest: pullResult.digest,
        localPath: localDir,
        size: size,
        pulledAt: Date()
      )

      try await imageStore.addImage(record)

      eventBus.publish(.imagePulled(reference: parsed.fullReference))
      logInfo("Image pulled: \(parsed.fullReference) -> \(localDir)", category: "ImageManager")

      return record
    } catch {
      // Clean up on failure
      try? FileManager.default.removeItem(atPath: localDir)
      eventBus.publish(.imagePullFailed(reference: parsed.fullReference, error: error.localizedDescription))
      throw ImageManagerError.pullFailed(error.localizedDescription)
    }
  }

  // MARK: - Push

  /// Pushes a VM bundle directory to an OCI registry as a single OCI artifact.
  ///
  /// Uses `oras push` with artifact type `application/vnd.jeballto.vm.bundle.v1`.
  /// `oras` automatically compresses the directory contents as tar+gzip OCI layers.
  /// The VM must be stopped before calling this method to ensure a consistent disk image.
  func pushImageFromVM(
    reference: String,
    vmBundlePath: String,
    timeout: TimeInterval? = nil
  ) async throws -> ImageRecord {
    let parsed: ImageReference
    do {
      parsed = try ImageReference.parse(reference)
    } catch {
      throw ImageManagerError.invalidReference(error.localizedDescription)
    }

    logInfo("Pushing VM bundle to \(parsed.fullReference) from \(vmBundlePath)", category: "ImageManager")
    eventBus.publish(.imagePushStarted(reference: parsed.fullReference))

    do {
      let insecure = parsed.isInsecureAllowed(insecureRegistries: config.images.insecureRegistries)
      do {
        try await orasClient.checkRegistryReachable(registryHost: parsed.registry, insecure: insecure)
      } catch {
        throw ImageManagerError.registryUnreachable(
          "Cannot reach registry \(parsed.registry): \(error.localizedDescription)"
        )
      }
      let pushResult = try await orasClient.push(
        reference: parsed,
        files: [vmBundlePath],
        insecure: insecure,
        timeout: timeout
      )

      // Register locally so it can be re-pulled or re-pushed
      let imageId = UUID()
      let record = ImageRecord(
        id: imageId,
        reference: parsed.fullReference,
        digest: pushResult.digest,
        localPath: vmBundlePath,
        size: directorySize(atPath: vmBundlePath),
        pushedAt: Date(),
        metadata: ["sourceType": "vm"]
      )

      try await imageStore.addImage(record)

      eventBus.publish(.imagePushed(reference: parsed.fullReference))
      logInfo("Image pushed: \(parsed.fullReference) (digest: \(pushResult.digest))", category: "ImageManager")

      return record
    } catch let error as ImageManagerError {
      eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
      throw error
    } catch {
      eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
      throw ImageManagerError.pushFailed(error.localizedDescription)
    }
  }

  /// Re-pushes an existing local image to a (possibly different) registry reference
  func pushImage(reference: String, imageId: UUID, timeout: TimeInterval? = nil) async throws -> ImageRecord {
    guard let existing = await imageStore.getImage(id: imageId) else {
      throw ImageManagerError.imageNotFoundById(imageId)
    }

    let parsed: ImageReference
    do {
      parsed = try ImageReference.parse(reference)
    } catch {
      throw ImageManagerError.invalidReference(error.localizedDescription)
    }

    logInfo("Re-pushing image \(imageId) to \(parsed.fullReference)", category: "ImageManager")
    eventBus.publish(.imagePushStarted(reference: parsed.fullReference))

    do {
      let insecure = parsed.isInsecureAllowed(insecureRegistries: config.images.insecureRegistries)
      do {
        try await orasClient.checkRegistryReachable(registryHost: parsed.registry, insecure: insecure)
      } catch {
        throw ImageManagerError.registryUnreachable(
          "Cannot reach registry \(parsed.registry): \(error.localizedDescription)"
        )
      }
      let pushResult = try await orasClient.push(
        reference: parsed,
        files: [existing.localPath],
        insecure: insecure,
        timeout: timeout
      )

      // Create a new record for the new reference
      let newId = UUID()
      let record = ImageRecord(
        id: newId,
        reference: parsed.fullReference,
        digest: pushResult.digest,
        localPath: existing.localPath,
        size: existing.size,
        pulledAt: existing.pulledAt,
        pushedAt: Date(),
        metadata: ["sourceImageId": imageId.uuidString]
      )

      try await imageStore.addImage(record)

      eventBus.publish(.imagePushed(reference: parsed.fullReference))
      logInfo("Image re-pushed: \(parsed.fullReference) (digest: \(pushResult.digest))", category: "ImageManager")

      return record
    } catch let error as ImageManagerError {
      eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
      throw error
    } catch {
      eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
      throw ImageManagerError.pushFailed(error.localizedDescription)
    }
  }

  // MARK: - Delete

  func deleteImage(id: UUID) async throws {
    guard let record = await imageStore.getImage(id: id) else {
      throw ImageManagerError.imageNotFoundById(id)
    }

    logInfo("Deleting image \(id): \(record.reference)", category: "ImageManager")

    // Only remove local files if this image owns them (not a VM bundle or shared path)
    let isSharedPath = record.metadata["sourceType"] == "vm" || record.metadata["sourceImageId"] != nil
    if !isSharedPath, FileManager.default.fileExists(atPath: record.localPath) {
      do {
        try FileManager.default.removeItem(atPath: record.localPath)
      } catch {
        throw ImageManagerError.deleteFailed("Failed to remove files at \(record.localPath): \(error)")
      }
    }

    try await imageStore.removeImage(id: id)
    eventBus.publish(.imageDeleted(reference: record.reference))
    logInfo("Image deleted: \(record.reference)", category: "ImageManager")
  }

  func wipeAllImages() async -> (deleted: Int, failed: Int, errors: [String]) {
    logWarning("Wiping all images", category: "ImageManager")
    let images = await imageStore.listImages()
    var deleted = 0
    var failed = 0
    var errors: [String] = []
    for image in images {
      do {
        try await deleteImage(id: image.id)
        deleted += 1
      } catch {
        failed += 1
        errors.append("\(image.reference): \(error.localizedDescription)")
      }
    }
    logInfo("Wipe complete: \(deleted) deleted, \(failed) failed", category: "ImageManager")
    return (deleted, failed, errors)
  }

  // MARK: - Registry Auth

  func loginRegistry(registry: String, username: String, password: String) async throws {
    let insecure = config.images.insecureRegistries.contains(registry)
    try await orasClient.login(registry: registry, username: username, password: password, insecure: insecure)
    logInfo("Logged in to registry: \(registry)", category: "ImageManager")
  }

  func logoutRegistry(registry: String) async throws {
    try await orasClient.logout(registry: registry)
    logInfo("Logged out from registry: \(registry)", category: "ImageManager")
  }

  // MARK: - Helpers

  /// After oras pull, directory layers are extracted as a subdirectory
  /// (e.g. `localDir/SomeVM.bundle/`). This moves the contents up so
  /// bundle files sit directly in localDir, which is what createVMFromImage expects.
  private func flattenPulledBundle(inDir dir: String) throws {
    let fileManager = FileManager.default
    let contents = try fileManager.contentsOfDirectory(atPath: dir)

    // Look for a single subdirectory (the extracted bundle)
    for item in contents {
      let itemPath = "\(dir)/\(item)"
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: itemPath, isDirectory: &isDirectory), isDirectory.boolValue {
        let bundleContents = try fileManager.contentsOfDirectory(atPath: itemPath)
        for file in bundleContents {
          try fileManager.moveItem(atPath: "\(itemPath)/\(file)", toPath: "\(dir)/\(file)")
        }
        try fileManager.removeItem(atPath: itemPath)
        logInfo("Flattened pulled bundle directory: \(item)", category: "ImageManager")
        return
      }
    }
    // No subdirectory found - files are already flat (individual file push format)
  }

  /// Computes total size of a directory's contents
  private func directorySize(atPath path: String) -> UInt64 {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(atPath: path) else { return 0 }

    var totalSize: UInt64 = 0
    while let file = enumerator.nextObject() as? String {
      let fullPath = "\(path)/\(file)"
      if let attrs = try? fileManager.attributesOfItem(atPath: fullPath),
         let size = attrs[.size] as? UInt64
      {
        totalSize += size
      }
    }
    return totalSize
  }
}
