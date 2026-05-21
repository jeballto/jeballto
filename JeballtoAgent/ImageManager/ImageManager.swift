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
/// Pushes VM bundle directories as chunked Jeballto OCI artifacts while preserving the public REST API.
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
    cleanupStaleImageWorkDirs(imageStorageDir: config.images.imageStorageDir)
  }

  // MARK: - Startup Cleanup

  private nonisolated func cleanupStaleImageWorkDirs(imageStorageDir: String) {
    let fileManager = FileManager.default
    let workPath = JeballtoCachePaths.imageWork.path
    if fileManager.fileExists(atPath: workPath) {
      logInfo("Cleaning up stale image work directory: \(workPath)", category: "ImageManager")
      try? fileManager.removeItem(atPath: workPath)
    }

    _ = Self.cleanupStaleImageStorageArtifacts(imageStorageDir: imageStorageDir)
  }

  nonisolated static func cleanupStaleImageStorageArtifacts(
    imageStorageDir: String
  ) -> (deleted: Int, failed: Int, errors: [String]) {
    let fileManager = FileManager.default
    guard let contents = try? fileManager.contentsOfDirectory(atPath: imageStorageDir) else {
      return (0, 0, [])
    }

    var deleted = 0
    var failed = 0
    var errors: [String] = []
    let workPrefixes = ["oras-tmp-", "vm-image-", "oras-pull-"]
    for item in contents {
      let path = "\(imageStorageDir)/\(item)"
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }

      let isWorkDir = workPrefixes.contains { item.hasPrefix($0) }
      let isUnpackDir = item.hasPrefix(".") && item.contains(".bundle.unpack-")
      let isEmptyImageBundle = item.hasSuffix(".bundle") && isDirectoryEmpty(atPath: path)
      guard isWorkDir || isUnpackDir || isEmptyImageBundle else { continue }

      logInfo("Cleaning up stale image storage directory: \(path)", category: "ImageManager")
      do {
        try fileManager.removeItem(atPath: path)
        deleted += 1
      } catch {
        failed += 1
        errors.append("Failed to remove stale image artifact \(path): \(error.localizedDescription)")
      }
    }
    return (deleted, failed, errors)
  }

  private nonisolated static func isDirectoryEmpty(atPath path: String) -> Bool {
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
    return contents.isEmpty
  }

  nonisolated static func validateRunnableVMBundle(atPath bundlePath: String) throws {
    let requiredFiles = ["Disk.img", "AuxiliaryStorage", "HardwareModel", "MachineIdentifier"]
    let missingFiles = requiredFiles.filter { fileName in
      let filePath = "\(bundlePath)/\(fileName)"
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: filePath, isDirectory: &isDirectory) == false
        || isDirectory.boolValue
    }

    guard missingFiles.isEmpty else {
      throw VMImagePackagerError.invalidBundle(
        "Pulled image at \(bundlePath) is missing required VM bundle files: \(missingFiles.joined(separator: ", "))"
      )
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
  /// Uses ORAS blob fetches under the hood. Images are reconstructed from zstd-compressed chunks
  /// into a `.bundle` directory named after the image UUID.
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
      do {
        try Self.validateRunnableVMBundle(atPath: existing.localPath)
        logInfo("Image already local: \(parsed.fullReference)", category: "ImageManager")
        return existing
      } catch {
        logWarning(
          "Discarding invalid cached image \(existing.id): \(error.localizedDescription)",
          category: "ImageManager"
        )
        try? FileManager.default.removeItem(atPath: existing.localPath)
        try? await imageStore.removeImage(id: existing.id)
      }
    }

    logInfo("Pulling image: \(parsed.fullReference)", category: "ImageManager")
    eventBus.publish(.imagePullStarted(reference: parsed.fullReference))

    let imageId = UUID()
    let localDir = "\(config.images.imageStorageDir)/\(imageId.uuidString).bundle"

    do {
      try FileManager.default.createDirectory(atPath: localDir, withIntermediateDirectories: true)

      let insecure = parsed.isInsecureAllowed(insecureRegistries: config.images.insecureRegistries)
      let manifest = try await orasClient.fetchManifest(reference: parsed, insecure: insecure)
      do {
        try manifest.validateJeballtoImage(reference: parsed.fullReference)
      } catch {
        logError(
          "Unsupported Jeballto image format for \(parsed.fullReference): \(manifest.formatSummary)",
          category: "ImageManager"
        )
        throw error
      }
      let pullResult = try await pullImageArtifact(
        parsed,
        manifest: manifest,
        localDir: localDir,
        insecure: insecure,
        timeout: timeout
      )
      try Self.validateRunnableVMBundle(atPath: localDir)

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
      logError(
        "Image pull failed for \(parsed.fullReference): \(error.localizedDescription)",
        category: "ImageManager"
      )
      throw ImageManagerError.pullFailed(error.localizedDescription)
    }
  }

  // MARK: - Push

  /// Pushes a VM bundle directory to an OCI registry as a Jeballto OCI artifact.
  ///
  /// Uses `oras push` with artifact type `application/vnd.jeballto.vm.bundle`.
  /// The VM disk is split into deterministic zstd-compressed chunks so retries can reuse
  /// already-present registry blobs.
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
      let pushResult = try await pushImageBundle(
        reference: parsed,
        bundlePath: vmBundlePath,
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
        metadata: [
          "sourceType": "vm",
          "imageFormat": "chunked-zstd",
          "artifactType": jeballtoImageArtifactType,
          "compression": "zstd",
          "chunkSize": String(VMImagePackager.defaultChunkSize),
        ]
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
      let pushResult = try await pushImageBundle(
        reference: parsed,
        bundlePath: existing.localPath,
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
        metadata: [
          "sourceImageId": imageId.uuidString,
          "imageFormat": "chunked-zstd",
          "artifactType": jeballtoImageArtifactType,
          "compression": "zstd",
          "chunkSize": String(VMImagePackager.defaultChunkSize),
        ]
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
    let staleArtifacts = Self.cleanupStaleImageStorageArtifacts(imageStorageDir: config.images.imageStorageDir)
    deleted += staleArtifacts.deleted
    failed += staleArtifacts.failed
    errors.append(contentsOf: staleArtifacts.errors)
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

  private func pushImageBundle(
    reference: ImageReference,
    bundlePath: String,
    insecure: Bool,
    timeout: TimeInterval?
  ) async throws -> OrasPushResult {
    let packager = VMImagePackager(
      zstdClient: ZstdClient(config: config.images),
      maxParallelChunks: config.images.maxParallelImageChunks
    )
    let package = try await packager.packBundle(
      bundlePath: bundlePath,
      stagingRoot: JeballtoCachePaths.imageWork.path,
      timeout: timeout
    )
    defer { try? FileManager.default.removeItem(atPath: package.stagingDirectory) }

    return try await orasClient.pushImagePackage(
      reference: reference,
      package: package,
      insecure: insecure,
      timeout: timeout
    )
  }

  private func pullImageArtifact(
    _ reference: ImageReference,
    manifest: OrasManifestInfo,
    localDir: String,
    insecure: Bool,
    timeout: TimeInterval?
  ) async throws -> OrasPullResult {
    let pullDir = JeballtoCachePaths.imageWork
      .appendingPathComponent("oras-pull-\(UUID().uuidString)", isDirectory: true)
      .path
    let configPath = "\(pullDir)/vm-bundle-config.json"
    try FileManager.default.createDirectory(atPath: pullDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: pullDir) }
    let resolvedDigest: String = if let digest = reference.digest {
      digest
    } else {
      try await orasClient.resolve(reference: reference, insecure: insecure)
    }

    guard let configDescriptor = manifest.configDescriptor else {
      throw OrasError.invalidOutput("Jeballto image manifest is missing a config descriptor")
    }

    try await orasClient.fetchBlob(
      reference: reference,
      digest: configDescriptor.digest,
      outputPath: configPath,
      expectedSize: configDescriptor.size,
      insecure: insecure,
      timeout: timeout
    )

    var layerDescriptorsByDigest: [String: OrasDescriptor] = [:]
    for descriptor in manifest.layers where layerDescriptorsByDigest[descriptor.digest] == nil {
      layerDescriptorsByDigest[descriptor.digest] = descriptor
    }
    let descriptorsByDigest = layerDescriptorsByDigest
    let orasClient = orasClient
    let fetchLayer: VMImageLayerFetcher = { packedFile, chunk, destinationPath in
      guard let compressedDigest = chunk.compressedDigest,
            let compressedSize = chunk.compressedSize,
            chunk.layerPath != nil else
      {
        throw VMImagePackagerError.invalidConfig("Missing layer metadata for \(packedFile.path) chunk \(chunk.index)")
      }
      guard let descriptor = descriptorsByDigest[compressedDigest] else {
        throw OrasError.invalidOutput("Layer \(compressedDigest) is missing from the OCI manifest")
      }
      guard descriptor.mediaType == jeballtoImageChunkMediaType else {
        throw OrasError.invalidOutput("Layer \(compressedDigest) has unsupported media type \(descriptor.mediaType)")
      }
      guard descriptor.size == compressedSize else {
        throw OrasError.invalidOutput(
          "Layer \(compressedDigest) size mismatch: manifest \(descriptor.size), config \(compressedSize)"
        )
      }
      try await orasClient.fetchBlob(
        reference: reference,
        digest: compressedDigest,
        outputPath: destinationPath,
        expectedSize: compressedSize,
        insecure: insecure,
        timeout: timeout
      )
    }

    let packager = VMImagePackager(
      zstdClient: ZstdClient(config: config.images),
      maxParallelChunks: config.images.maxParallelImageChunks
    )
    try await packager.unpackBundle(
      configPath: configPath,
      layerDirectory: pullDir,
      outputBundlePath: localDir,
      fetchLayer: fetchLayer,
      timeout: timeout
    )
    return OrasPullResult(digest: resolvedDigest, rawOutput: manifest.rawManifest)
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
