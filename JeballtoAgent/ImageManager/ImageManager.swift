import CryptoKit
import Foundation

// swiftlint:disable file_length

/// Errors from image management operations
enum ImageManagerError: Error, LocalizedError {
  case imageNotFound(String)
  case imageNotFoundById(UUID)
  case pullFailed(String)
  case pushFailed(String)
  case deleteFailed(String)
  case invalidReference(String)
  case registryUnreachable(String)
  case timeout(String)
  case imageInUse(String)

  var errorDescription: String? {
    switch self {
    case .imageNotFound(let ref): "Image not found: \(ref)"
    case .imageNotFoundById(let id): "Image not found with ID: \(id.uuidString)"
    case .pullFailed(let msg): "Image pull failed: \(msg)"
    case .pushFailed(let msg): "Image push failed: \(msg)"
    case .deleteFailed(let msg): "Image delete failed: \(msg)"
    case .invalidReference(let msg): "Invalid image reference: \(msg)"
    case .registryUnreachable(let msg): "Registry unreachable: \(msg)"
    case .timeout(let msg): "Image operation timed out: \(msg)"
    case .imageInUse(let msg): "Image is in use: \(msg)"
    }
  }
}

// Central orchestrator for OCI image operations.
// Pushes VM bundle directories as chunked Jeballto OCI artifacts while preserving the public REST API.
// swiftlint:disable:next type_body_length
actor ImageManager {
  private struct PushBlobCandidate: Sendable {
    let descriptor: OrasDescriptor
    let filePath: String
  }

  private struct PushBlobUploadResult: Sendable {
    let descriptor: OrasDescriptor
  }

  private struct PushUploadState: Codable, Sendable {
    let repositoryReference: String
    var uploadedDigests: Set<String>
  }

  private struct OCIImageManifest: Encodable {
    let schemaVersion: Int
    let mediaType: String
    let artifactType: String
    let config: OrasDescriptor
    let layers: [OrasDescriptor]
  }

  private let imageStore: ImageStore
  private var orasClient: OrasClient
  private let eventBus: EventBus
  private var config: Config
  private var imageExportReservations: [UUID: Set<UUID>] = [:]
  private var deletingImageIds: Set<UUID> = []
  private let operationCache = ImageOperationCache()
  private let blobCache = ImageBlobCache()
  private let operationTracker = ImageOperationTracker()

  init(imageStore: ImageStore, orasClient: OrasClient, eventBus: EventBus, config: Config) {
    self.imageStore = imageStore
    self.orasClient = orasClient
    self.eventBus = eventBus
    self.config = config
    cleanupStaleImageWorkDirs(imageStorageDir: config.images.imageStorageDir)
  }

  func updateConfiguration(_ newConfig: Config) {
    config = newConfig
    orasClient = OrasClient(config: newConfig.images)
  }

  func currentImageConfig() -> ImageConfig {
    config.images
  }

  nonisolated static func withImageOperationDeadline<T: Sendable>(
    timeout: TimeInterval?,
    operationName: String,
    operation: @Sendable @escaping () async throws -> T
  ) async throws -> T {
    guard let timeout else {
      return try await operation()
    }
    guard timeout > 0 else {
      throw OrasError.timeout(operationName)
    }

    return try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(nanoseconds: timeoutNanoseconds(timeout))
        throw OrasError.timeout(operationName)
      }

      do {
        guard let result = try await group.next() else {
          throw OrasError.invalidOutput("Image operation \(operationName) ended without a result")
        }
        group.cancelAll()
        return result
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }

  private nonisolated static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64 {
    let maxSeconds = TimeInterval(UInt64.max) / 1_000_000_000
    let clamped = min(timeout, maxSeconds)
    return UInt64(clamped * 1_000_000_000)
  }

  // MARK: - Startup Cleanup

  private nonisolated func cleanupStaleImageWorkDirs(imageStorageDir: String) {
    Self.cleanupImageWorkDirectory()
    _ = Self.cleanupStaleImageStorageArtifacts(imageStorageDir: imageStorageDir)
  }

  nonisolated static func cleanupImageWorkDirectory() {
    let fileManager = FileManager.default
    let workPath = JeballtoCachePaths.imageWork.path
    if fileManager.fileExists(atPath: workPath) {
      logInfo("Cleaning up stale image work directory: \(workPath)", category: "ImageManager")
      try? fileManager.removeItem(atPath: workPath)
    }
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

  // MARK: - Async operation status

  func startImageOperation(
    kind: ImageOperationKind,
    reference: String,
    source: String? = nil
  ) async -> ImageOperationStatus {
    await operationTracker.start(kind: kind, reference: reference, source: source)
  }

  func progressSink(for operationId: UUID) async -> ImageOperationProgressSink {
    let tracker = operationTracker
    return { update in
      await tracker.update(operationId, update)
    }
  }

  func completeImageOperation(_ operationId: UUID, record: ImageRecord) async {
    await operationTracker.complete(operationId, record: record)
  }

  func failImageOperation(_ operationId: UUID, error: Error) async {
    await operationTracker.fail(operationId, error: error)
  }

  @discardableResult
  func cancelImageOperation(_ operationId: UUID) async -> Bool {
    await operationTracker.cancel(operationId)
  }

  func getImageOperationStatus(_ operationId: UUID) async -> ImageOperationStatus? {
    await operationTracker.get(operationId)
  }

  func listImageOperationStatuses(
    kind: ImageOperationKind? = nil,
    activeOnly: Bool = false
  ) async -> [ImageOperationStatus] {
    await operationTracker.list(kind: kind, activeOnly: activeOnly)
  }

  func claimImageExport(_ id: UUID) throws -> UUID {
    guard !deletingImageIds.contains(id) else {
      throw ImageManagerError.imageInUse("Image \(id.uuidString) is being deleted")
    }

    let token = UUID()
    imageExportReservations[id, default: []].insert(token)
    return token
  }

  func releaseImageExport(_ id: UUID, token: UUID) {
    guard var tokens = imageExportReservations[id] else { return }
    tokens.remove(token)
    if tokens.isEmpty {
      imageExportReservations.removeValue(forKey: id)
    } else {
      imageExportReservations[id] = tokens
    }
  }

  // MARK: - Pull

  /// Pulls an OCI artifact from a registry and stores it in the local image store.
  ///
  /// Uses ORAS blob fetches under the hood. Images are reconstructed from zstd-compressed chunks
  /// into a `.bundle` directory named after the image UUID.
  /// If the image already exists locally (same reference), returns the existing record immediately
  /// without network access - this is intentional for CI/CD idempotency.
  func pullImage(
    reference: String,
    timeout: TimeInterval? = nil,
    progressSink: ImageOperationProgressSink? = nil
  ) async throws -> ImageRecord {
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
      return try await Self.withImageOperationDeadline(
        timeout: timeout,
        operationName: "image pull \(parsed.fullReference)"
      ) {
        try await self.performPullImage(
          parsed: parsed,
          imageId: imageId,
          localDir: localDir,
          timeout: timeout,
          progressSink: progressSink
        )
      }
    } catch is CancellationError {
      try? FileManager.default.removeItem(atPath: localDir)
      logInfo("Image pull cancelled: \(parsed.fullReference)", category: "ImageManager")
      throw CancellationError()
    } catch {
      if let timeoutMessage = Self.timeoutMessage(from: error) {
        try? FileManager.default.removeItem(atPath: localDir)
        eventBus.publish(.imagePullFailed(reference: parsed.fullReference, error: error.localizedDescription))
        throw ImageManagerError.timeout(timeoutMessage)
      }
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
    timeout: TimeInterval? = nil,
    progressSink: ImageOperationProgressSink? = nil
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
      return try await Self.withImageOperationDeadline(
        timeout: timeout,
        operationName: "image push \(parsed.fullReference)"
      ) {
        try await self.performPushImageFromVM(
          parsed: parsed,
          vmBundlePath: vmBundlePath,
          timeout: timeout,
          progressSink: progressSink
        )
      }
    } catch is CancellationError {
      logInfo("Image push cancelled: \(parsed.fullReference)", category: "ImageManager")
      throw CancellationError()
    } catch let error as ImageManagerError {
      eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
      throw error
    } catch {
      if let timeoutMessage = Self.timeoutMessage(from: error) {
        eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
        throw ImageManagerError.timeout(timeoutMessage)
      }
      eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
      throw ImageManagerError.pushFailed(error.localizedDescription)
    }
  }

  /// Re-pushes an existing local image to a (possibly different) registry reference
  func pushImage(
    reference: String,
    imageId: UUID,
    timeout: TimeInterval? = nil,
    progressSink: ImageOperationProgressSink? = nil,
    claimSource: Bool = true
  ) async throws -> ImageRecord {
    let exportToken: UUID? = if claimSource {
      try claimImageExport(imageId)
    } else {
      nil
    }
    defer {
      if let exportToken {
        releaseImageExport(imageId, token: exportToken)
      }
    }

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
      return try await Self.withImageOperationDeadline(
        timeout: timeout,
        operationName: "image push \(parsed.fullReference)"
      ) {
        try await self.performPushImage(
          parsed: parsed,
          sourceImageId: imageId,
          existing: existing,
          timeout: timeout,
          progressSink: progressSink
        )
      }
    } catch is CancellationError {
      logInfo("Image push cancelled: \(parsed.fullReference)", category: "ImageManager")
      throw CancellationError()
    } catch let error as ImageManagerError {
      eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
      throw error
    } catch {
      if let timeoutMessage = Self.timeoutMessage(from: error) {
        eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
        throw ImageManagerError.timeout(timeoutMessage)
      }
      eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
      throw ImageManagerError.pushFailed(error.localizedDescription)
    }
  }

  /// Checks that a push destination reference is valid and its registry is reachable.
  func checkPushDestinationReachable(reference: String) async throws {
    let parsed: ImageReference
    do {
      parsed = try ImageReference.parse(reference)
    } catch {
      throw ImageManagerError.invalidReference(error.localizedDescription)
    }

    let insecure = parsed.isInsecureAllowed(insecureRegistries: config.images.insecureRegistries)
    do {
      try await orasClient.checkRegistryReachable(registryHost: parsed.registry, insecure: insecure)
    } catch {
      throw ImageManagerError.registryUnreachable(
        "Cannot reach registry \(parsed.registry): \(error.localizedDescription)"
      )
    }
  }

  // MARK: - Delete

  func deleteImage(id: UUID) async throws {
    if let reservations = imageExportReservations[id], !reservations.isEmpty {
      throw ImageManagerError.imageInUse("Image \(id.uuidString) is being pushed")
    }
    guard deletingImageIds.insert(id).inserted else {
      throw ImageManagerError.imageInUse("Image \(id.uuidString) is already being deleted")
    }
    defer {
      deletingImageIds.remove(id)
    }

    let pushSource = "image:\(id.uuidString)"
    if await operationTracker.hasActiveOperation(source: pushSource) {
      throw ImageManagerError.imageInUse("Image \(id.uuidString) has an active push operation")
    }

    guard let record = await imageStore.getImage(id: id) else {
      throw ImageManagerError.imageNotFoundById(id)
    }

    logInfo("Deleting image \(id): \(record.reference)", category: "ImageManager")

    // Legacy pushed records may point at source VM or image paths. New pushed records set ownsLocalPath=true.
    let ownsLocalPath = record.metadata["ownsLocalPath"] == "true"
    let isSharedPath = !ownsLocalPath &&
      (record.metadata["sourceType"] == "vm" || record.metadata["sourceImageId"] != nil)
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
    Self.cleanupImageWorkDirectory()
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

  private func performPullImage(
    parsed: ImageReference,
    imageId: UUID,
    localDir: String,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> ImageRecord {
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
    let totalBytes = (manifest.configDescriptor?.size ?? 0) + manifest.layers.reduce(UInt64(0)) { total, layer in
      total + layer.size
    }
    await progressSink?(
      ImageOperationProgressUpdate(
        chunksTotal: manifest.layers.count,
        bytesTotal: totalBytes
      )
    )
    let pullResult = try await pullImageArtifact(
      parsed,
      manifest: manifest,
      localDir: localDir,
      insecure: insecure,
      timeout: timeout,
      progressSink: progressSink
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

    let storedRecord = try await imageStore.addImageIfReferenceAbsent(record)
    if storedRecord.id != record.id {
      try? FileManager.default.removeItem(atPath: localDir)
      eventBus.publish(.imagePulled(reference: parsed.fullReference))
      logInfo("Image became local while pulling: \(parsed.fullReference)", category: "ImageManager")
      return storedRecord
    }

    eventBus.publish(.imagePulled(reference: parsed.fullReference))
    logInfo("Image pulled: \(parsed.fullReference) -> \(localDir)", category: "ImageManager")

    return record
  }

  private func performPushImageFromVM(
    parsed: ImageReference,
    vmBundlePath: String,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> ImageRecord {
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
      timeout: timeout,
      progressSink: progressSink
    )

    let imageId = UUID()
    let localDir = "\(config.images.imageStorageDir)/\(imageId.uuidString).bundle"
    try copyBundleForImageRecord(from: vmBundlePath, to: localDir)
    let record = ImageRecord(
      id: imageId,
      reference: parsed.fullReference,
      digest: pushResult.digest,
      localPath: localDir,
      size: directorySize(atPath: localDir),
      pushedAt: Date(),
      metadata: [
        "sourceType": "vm",
        "sourceVmBundlePath": vmBundlePath,
        "ownsLocalPath": "true",
        "imageFormat": "chunked-zstd",
        "artifactType": jeballtoImageArtifactType,
        "compression": "zstd",
        "chunkSize": String(VMImagePackager.defaultChunkSize),
      ]
    )

    let storedRecord: ImageRecord
    do {
      storedRecord = try await imageStore.addImageIfReferenceAbsent(record)
    } catch {
      try? FileManager.default.removeItem(atPath: localDir)
      throw error
    }
    if storedRecord.id != record.id {
      try? FileManager.default.removeItem(atPath: localDir)
      eventBus.publish(.imagePushed(reference: parsed.fullReference))
      logInfo("Image already registered after push: \(parsed.fullReference)", category: "ImageManager")
      return storedRecord
    }

    eventBus.publish(.imagePushed(reference: parsed.fullReference))
    logInfo("Image pushed: \(parsed.fullReference) (digest: \(pushResult.digest))", category: "ImageManager")

    return record
  }

  private func performPushImage(
    parsed: ImageReference,
    sourceImageId: UUID,
    existing: ImageRecord,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> ImageRecord {
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
      timeout: timeout,
      progressSink: progressSink
    )

    let newId = UUID()
    let localDir = "\(config.images.imageStorageDir)/\(newId.uuidString).bundle"
    try copyBundleForImageRecord(from: existing.localPath, to: localDir)
    let record = ImageRecord(
      id: newId,
      reference: parsed.fullReference,
      digest: pushResult.digest,
      localPath: localDir,
      size: directorySize(atPath: localDir),
      pulledAt: existing.pulledAt,
      pushedAt: Date(),
      metadata: [
        "sourceImageId": sourceImageId.uuidString,
        "ownsLocalPath": "true",
        "imageFormat": "chunked-zstd",
        "artifactType": jeballtoImageArtifactType,
        "compression": "zstd",
        "chunkSize": String(VMImagePackager.defaultChunkSize),
      ]
    )

    let storedRecord: ImageRecord
    do {
      storedRecord = try await imageStore.addImageIfReferenceAbsent(record)
    } catch {
      try? FileManager.default.removeItem(atPath: localDir)
      throw error
    }
    if storedRecord.id != record.id {
      try? FileManager.default.removeItem(atPath: localDir)
      eventBus.publish(.imagePushed(reference: parsed.fullReference))
      logInfo("Image already registered after re-push: \(parsed.fullReference)", category: "ImageManager")
      return storedRecord
    }

    eventBus.publish(.imagePushed(reference: parsed.fullReference))
    logInfo("Image re-pushed: \(parsed.fullReference) (digest: \(pushResult.digest))", category: "ImageManager")

    return record
  }

  private func pushImageBundle(
    reference: ImageReference,
    bundlePath: String,
    insecure: Bool,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> OrasPushResult {
    let packager = VMImagePackager(
      zstdClient: ZstdClient(config: config.images),
      maxParallelChunks: config.images.maxParallelImageCompressions
    )
    let sourceFingerprint = try packager.sourceFingerprint(bundlePath: bundlePath)
    return try await withOperationCacheAccess(for: "push:\(sourceFingerprint)") {
      let pushDir = Self.pushOperationDirectory(sourceFingerprint: sourceFingerprint)
      let packageDir = "\(pushDir)/package"
      try FileManager.default.createDirectory(atPath: packageDir, withIntermediateDirectories: true)
      let compressionProgressSink: VMImagePackProgressSink? = if let progressSink {
        { @Sendable update in
          await progressSink(
            ImageOperationProgressUpdate(
              stage: .compressing,
              chunksCompletedDelta: update.chunksCompletedDelta,
              chunksTotal: update.chunksTotal,
              bytesCompletedDelta: update.bytesCompletedDelta,
              bytesTotal: update.bytesTotal
            )
          )
        }
      } else {
        nil
      }

      let package = try await packager.packBundle(
        bundlePath: bundlePath,
        stagingDirectory: packageDir,
        timeout: timeout,
        progressSink: compressionProgressSink
      )

      let pushResult = try await pushImagePackage(
        reference: reference,
        package: package,
        insecure: insecure,
        operationDirectory: pushDir,
        timeout: timeout,
        progressSink: progressSink
      )
      try? FileManager.default.removeItem(atPath: pushDir)
      return pushResult
    }
  }

  private func pullImageArtifact(
    _ reference: ImageReference,
    manifest: OrasManifestInfo,
    localDir: String,
    insecure: Bool,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> OrasPullResult {
    let resolvedDigest: String = if let digest = reference.digest {
      digest
    } else {
      try await orasClient.resolve(reference: reference, insecure: insecure)
    }
    return try await withOperationCacheAccess(for: "pull:\(resolvedDigest)") {
      try await pullResolvedImageArtifact(
        reference,
        manifest: manifest,
        localDir: localDir,
        resolvedDigest: resolvedDigest,
        insecure: insecure,
        timeout: timeout,
        progressSink: progressSink
      )
    }
  }

  private func pullResolvedImageArtifact(
    _ reference: ImageReference,
    manifest: OrasManifestInfo,
    localDir: String,
    resolvedDigest: String,
    insecure: Bool,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> OrasPullResult {
    let pullDir = Self.pullOperationDirectory(manifestDigest: resolvedDigest)
    let blobCacheDir = "\(pullDir)/blobs"
    let configPath = "\(pullDir)/config/vm-bundle-config.json"
    let layerDirectory = "\(pullDir)/layers"
    try FileManager.default.createDirectory(atPath: blobCacheDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      atPath: (configPath as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true
    )
    try? FileManager.default.removeItem(atPath: layerDirectory)
    try FileManager.default.createDirectory(atPath: layerDirectory, withIntermediateDirectories: true)

    guard let configDescriptor = manifest.configDescriptor else {
      throw OrasError.invalidOutput("Jeballto image manifest is missing a config descriptor")
    }

    let configCachePath = Self.blobCachePath(blobCacheDir: blobCacheDir, digest: configDescriptor.digest)
    try await Self.fetchBlobIntoCache(
      reference: reference,
      descriptor: configDescriptor,
      cachePath: configCachePath,
      insecure: insecure,
      orasClient: orasClient,
      blobCache: blobCache,
      timeout: timeout
    )
    await progressSink?(
      ImageOperationProgressUpdate(
        bytesCompletedDelta: configDescriptor.size
      )
    )
    try Self.copyCachedBlob(from: configCachePath, to: configPath)

    var layerDescriptorsByDigest: [String: OrasDescriptor] = [:]
    for descriptor in manifest.layers where layerDescriptorsByDigest[descriptor.digest] == nil {
      layerDescriptorsByDigest[descriptor.digest] = descriptor
    }
    let descriptorsByDigest = layerDescriptorsByDigest
    let blobCacheDirectory = blobCacheDir
    let orasClient = orasClient
    let blobCache = blobCache
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
      let cachedBlobPath = Self.blobCachePath(blobCacheDir: blobCacheDirectory, digest: compressedDigest)
      try await Self.fetchBlobIntoCache(
        reference: reference,
        descriptor: descriptor,
        cachePath: cachedBlobPath,
        insecure: insecure,
        orasClient: orasClient,
        blobCache: blobCache,
        timeout: timeout
      )
      await progressSink?(
        ImageOperationProgressUpdate(
          chunksCompletedDelta: 1,
          bytesCompletedDelta: compressedSize
        )
      )
      try Self.copyCachedBlob(from: cachedBlobPath, to: destinationPath)
    }

    let packager = VMImagePackager(
      zstdClient: ZstdClient(config: config.images),
      maxParallelUnpackChunks: config.images.maxParallelImageBlobTransfers,
      maxParallelDecompressions: config.images.maxParallelImageDecompressions,
      maxParallelDiskWrites: config.images.maxParallelImageDiskWrites
    )
    try await packager.unpackBundle(
      configPath: configPath,
      layerDirectory: layerDirectory,
      outputBundlePath: localDir,
      fetchLayer: fetchLayer,
      timeout: timeout
    )
    try? FileManager.default.removeItem(atPath: pullDir)
    return OrasPullResult(digest: resolvedDigest, rawOutput: manifest.rawManifest)
  }

  private func withOperationCacheAccess<T>(
    for key: String,
    operation: @Sendable () async throws -> T
  ) async throws -> T {
    try await operationCache.withExclusiveAccess(for: key, operation: operation)
  }

  private nonisolated static func uniqueBlobCandidates(_ candidates: [PushBlobCandidate]) -> [PushBlobCandidate] {
    var seenDigests: Set<String> = []
    var uniqueCandidates: [PushBlobCandidate] = []
    for candidate in candidates where seenDigests.insert(candidate.descriptor.digest).inserted {
      uniqueCandidates.append(candidate)
    }
    return uniqueCandidates
  }

  private nonisolated static func timeoutMessage(from error: Error) -> String? {
    if case OrasError.timeout(let message) = error {
      return message
    }
    if case ZstdError.timeout(let message) = error {
      return message
    }
    return nil
  }

  private func pushImagePackage(
    reference: ImageReference,
    package: VMImagePackage,
    insecure: Bool,
    operationDirectory: String,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> OrasPushResult {
    let repositoryReference = OrasClient.repositoryReference(reference)
    let configDescriptor = try Self.descriptor(
      filePath: package.configPath,
      mediaType: jeballtoImageConfigMediaType
    )
    let layerCandidates = try package.layers.map { layer in
      try PushBlobCandidate(
        descriptor: Self.descriptor(filePath: layer.absolutePath, mediaType: layer.mediaType),
        filePath: layer.absolutePath
      )
    }
    let configCandidate = PushBlobCandidate(descriptor: configDescriptor, filePath: package.configPath)
    let candidates = Self.uniqueBlobCandidates([configCandidate] + layerCandidates)
    let bytesTotal = candidates.reduce(UInt64(0)) { total, candidate in
      total + candidate.descriptor.size
    }
    await progressSink?(
      ImageOperationProgressUpdate(
        stage: .uploading,
        progress: 0.5,
        stageProgress: 0,
        setChunksCompleted: 0,
        chunksTotal: candidates.count,
        setBytesCompleted: 0,
        bytesTotal: bytesTotal
      )
    )
    let statePath = Self.pushUploadStatePath(
      operationDirectory: operationDirectory,
      repositoryReference: repositoryReference
    )
    var state = Self.loadPushUploadState(path: statePath, repositoryReference: repositoryReference)

    try await uploadBlobs(
      candidates,
      repositoryReference: repositoryReference,
      insecure: insecure,
      statePath: statePath,
      state: &state,
      timeout: timeout,
      progressSink: progressSink
    )

    let manifestPath = "\(operationDirectory)/manifest.json"
    try Self.writeManifest(
      configDescriptor: configDescriptor,
      layerDescriptors: layerCandidates.map(\.descriptor),
      manifestPath: manifestPath
    )
    return try await orasClient.pushManifest(
      reference: reference,
      manifestPath: manifestPath,
      insecure: insecure,
      timeout: timeout
    )
  }

  private func uploadBlobs(
    _ candidates: [PushBlobCandidate],
    repositoryReference: String,
    insecure: Bool,
    statePath: String,
    state: inout PushUploadState,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws {
    guard candidates.isEmpty == false else { return }

    let limit = min(effectiveImageTransferLimit(), candidates.count)
    let orasClient = orasClient
    let initialUploadedDigests = state.uploadedDigests

    try await withThrowingTaskGroup(of: PushBlobUploadResult.self) { group in
      var nextIndex = 0

      for _ in 0 ..< limit {
        let candidate = candidates[nextIndex]
        group.addTask {
          try await Self.confirmOrUploadBlob(
            candidate,
            repositoryReference: repositoryReference,
            insecure: insecure,
            alreadyUploaded: initialUploadedDigests.contains(candidate.descriptor.digest),
            orasClient: orasClient,
            timeout: timeout
          )
        }
        nextIndex += 1
      }

      do {
        while let uploadResult = try await group.next() {
          state.uploadedDigests.insert(uploadResult.descriptor.digest)
          try Self.savePushUploadState(state, path: statePath)
          await progressSink?(
            ImageOperationProgressUpdate(
              stage: .uploading,
              chunksCompletedDelta: 1,
              bytesCompletedDelta: uploadResult.descriptor.size
            )
          )
          if nextIndex < candidates.count {
            let candidate = candidates[nextIndex]
            group.addTask {
              try await Self.confirmOrUploadBlob(
                candidate,
                repositoryReference: repositoryReference,
                insecure: insecure,
                alreadyUploaded: initialUploadedDigests.contains(candidate.descriptor.digest),
                orasClient: orasClient,
                timeout: timeout
              )
            }
            nextIndex += 1
          }
        }
      } catch {
        group.cancelAll()
        throw error
      }
    }
  }

  private nonisolated static func confirmOrUploadBlob(
    _ candidate: PushBlobCandidate,
    repositoryReference: String,
    insecure: Bool,
    alreadyUploaded: Bool,
    orasClient: OrasClient,
    timeout: TimeInterval?
  ) async throws -> PushBlobUploadResult {
    if alreadyUploaded,
       try await orasClient.blobPresence(
         repositoryReference: repositoryReference,
         digest: candidate.descriptor.digest,
         insecure: insecure
       ) == .exists
    {
      return PushBlobUploadResult(descriptor: candidate.descriptor)
    }

    if try await orasClient.blobPresence(
      repositoryReference: repositoryReference,
      digest: candidate.descriptor.digest,
      insecure: insecure
    ) == .exists {
      return PushBlobUploadResult(descriptor: candidate.descriptor)
    }

    _ = try await orasClient.pushBlob(
      repositoryReference: repositoryReference,
      digest: candidate.descriptor.digest,
      filePath: candidate.filePath,
      mediaType: candidate.descriptor.mediaType,
      expectedSize: candidate.descriptor.size,
      insecure: insecure,
      timeout: timeout
    )
    return PushBlobUploadResult(descriptor: candidate.descriptor)
  }

  private nonisolated static func fetchBlobIntoCache(
    reference: ImageReference,
    descriptor: OrasDescriptor,
    cachePath: String,
    insecure: Bool,
    orasClient: OrasClient,
    blobCache: ImageBlobCache,
    timeout: TimeInterval?
  ) async throws {
    try await blobCache.withExclusiveAccess(for: descriptor.digest) {
      if cachedBlobIsValid(
        path: cachePath,
        expectedDigest: descriptor.digest,
        expectedSize: descriptor.size
      ) {
        return
      }
      try? FileManager.default.removeItem(atPath: cachePath)
      try await orasClient.fetchBlob(
        reference: reference,
        digest: descriptor.digest,
        outputPath: cachePath,
        expectedSize: descriptor.size,
        insecure: insecure,
        timeout: timeout
      )
    }
  }

  nonisolated static func cachedBlobIsValid(
    path: String,
    expectedDigest: String,
    expectedSize: UInt64
  ) -> Bool {
    guard FileManager.default.fileExists(atPath: path),
          (try? fileSize(atPath: path)) == expectedSize,
          (try? sha256File(atPath: path)) == expectedDigest else
    {
      return false
    }
    return true
  }

  private func effectiveImageTransferLimit() -> Int {
    config.images.maxParallelImageBlobTransfers
  }

  nonisolated static func pullOperationDirectory(manifestDigest: String) -> String {
    JeballtoCachePaths.imageWork
      .appendingPathComponent(
        "operations/pulls/\(sanitizeCacheKey(manifestDigest))",
        isDirectory: true
      )
      .path
  }

  nonisolated static func pushOperationDirectory(sourceFingerprint: String) -> String {
    JeballtoCachePaths.imageWork
      .appendingPathComponent(
        "operations/pushes/\(sanitizeCacheKey(sourceFingerprint))",
        isDirectory: true
      )
      .path
  }

  private nonisolated static func blobCachePath(blobCacheDir: String, digest: String) -> String {
    "\(blobCacheDir)/\(sanitizeCacheKey(digest))"
  }

  private nonisolated static func pushUploadStatePath(
    operationDirectory: String,
    repositoryReference: String
  ) -> String {
    "\(operationDirectory)/uploads-\(sanitizeCacheKey(repositoryReference)).json"
  }

  private nonisolated static func sanitizeCacheKey(_ value: String) -> String {
    value.map { character in
      character.isLetter || character.isNumber ? character : "-"
    }.reduce(into: "") { result, character in
      result.append(character)
    }
  }

  private nonisolated static func loadPushUploadState(
    path: String,
    repositoryReference: String
  ) -> PushUploadState {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let state = try? JSONDecoder().decode(PushUploadState.self, from: data),
          state.repositoryReference == repositoryReference else
    {
      return PushUploadState(repositoryReference: repositoryReference, uploadedDigests: [])
    }
    return state
  }

  private nonisolated static func savePushUploadState(_ state: PushUploadState, path: String) throws {
    let parent = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(state).write(to: URL(fileURLWithPath: path), options: .atomic)
  }

  private nonisolated static func writeManifest(
    configDescriptor: OrasDescriptor,
    layerDescriptors: [OrasDescriptor],
    manifestPath: String
  ) throws {
    let parent = (manifestPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    try ociImageManifestData(
      configDescriptor: configDescriptor,
      layerDescriptors: layerDescriptors
    ).write(to: URL(fileURLWithPath: manifestPath), options: .atomic)
  }

  nonisolated static func ociImageManifestData(
    configDescriptor: OrasDescriptor,
    layerDescriptors: [OrasDescriptor]
  ) throws -> Data {
    let manifest = OCIImageManifest(
      schemaVersion: 2,
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      artifactType: jeballtoImageArtifactType,
      config: configDescriptor,
      layers: layerDescriptors
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(manifest)
  }

  private nonisolated static func descriptor(filePath: String, mediaType: String) throws -> OrasDescriptor {
    try OrasDescriptor(
      mediaType: mediaType,
      digest: sha256File(atPath: filePath),
      size: fileSize(atPath: filePath)
    )
  }

  private nonisolated static func copyCachedBlob(from sourcePath: String, to destinationPath: String) throws {
    let parent = (destinationPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: destinationPath) {
      try FileManager.default.removeItem(atPath: destinationPath)
    }
    try FileManager.default.copyItem(atPath: sourcePath, toPath: destinationPath)
  }

  private func copyBundleForImageRecord(from sourcePath: String, to destinationPath: String) throws {
    let parent = (destinationPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: destinationPath) {
      try FileManager.default.removeItem(atPath: destinationPath)
    }
    do {
      try FileManager.default.copyItem(atPath: sourcePath, toPath: destinationPath)
    } catch {
      throw ImageManagerError.pushFailed("Failed to create local image copy at \(destinationPath): \(error)")
    }
  }

  private nonisolated static func fileSize(atPath path: String) throws -> UInt64 {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    return attrs[.size] as? UInt64 ?? UInt64(attrs[.size] as? Int64 ?? 0)
  }

  private nonisolated static func sha256File(atPath path: String) throws -> String {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
      guard !data.isEmpty else { break }
      hasher.update(data: data)
    }
    return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
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
