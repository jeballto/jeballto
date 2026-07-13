import CryptoKit
import Darwin
import Foundation

// swiftlint:disable file_length

typealias RegistryAvailabilityChecker = @Sendable (_ registry: String, _ insecure: Bool) async throws -> Void
typealias BundleCopyRunner = @Sendable (_ sourcePath: String, _ destinationPath: String) async throws -> Void

private enum ImageOperationDeadlineContext {
  @TaskLocal static var commitMarker: ImageOperationCommitMarker?
}

private final class ImageOperationCommitMarker: @unchecked Sendable {
  private let lock = NSLock()
  private let parent: ImageOperationCommitMarker?
  private var committed = false

  init(parent: ImageOperationCommitMarker?) {
    self.parent = parent
  }

  var isCommitted: Bool {
    lock.withLock { committed }
  }

  func markCommitted() {
    lock.withLock { committed = true }
    parent?.markCommitted()
  }
}

private enum ImageOperationDeadlineEvent<Value: Sendable>: Sendable {
  case succeeded(Value)
  case failed(any Error)
  case timedOut
  case deadlineTaskCancelled
}

/// Errors from image management operations
enum ImageManagerError: Error, LocalizedError {
  case imageNotFound(String)
  case imageNotFoundById(UUID)
  case pullFailed(String)
  case pushFailed(String)
  case pushCommitOutcomeUnknown(reference: String, digest: String, reason: String)
  case pushPartiallyCommitted(reference: String, digest: String, reason: String)
  case deleteFailed(String)
  case invalidReference(String)
  case invalidImage(String)
  case unsupportedImageFormat(String)
  case registryUnavailable(String)
  case timeout(String)
  case imageInUse(String)

  var errorDescription: String? {
    switch self {
    case .imageNotFound(let ref): "Image not found: \(ref)"
    case .imageNotFoundById(let id): "Image not found with ID: \(id.uuidString)"
    case .pullFailed(let msg): "Image pull failed: \(msg)"
    case .pushFailed(let msg): "Image push failed: \(msg)"
    case .pushCommitOutcomeUnknown(let reference, let digest, let reason):
      "Image push commit outcome is unknown: registry manifest \(reference) may have been committed as \(digest), "
        + "but the local image record was not finalized: \(reason). Inspect or pull the reference to reconcile it"
    case .pushPartiallyCommitted(let reference, let digest, let reason):
      "Image push partially committed: registry manifest \(reference) was committed as \(digest), but the durable "
        + "local image record could not be finalized: \(reason). Pull the reference to recover the local record"
    case .deleteFailed(let msg): "Image delete failed: \(msg)"
    case .invalidReference(let msg): "Invalid image reference: \(msg)"
    case .invalidImage(let msg): "Invalid image: \(msg)"
    case .unsupportedImageFormat(let msg): "Unsupported image format: \(msg)"
    case .registryUnavailable(let msg): "Registry unavailable: \(msg)"
    case .timeout(let msg): "Image operation timed out: \(msg)"
    case .imageInUse(let msg): "Image is in use: \(msg)"
    }
  }
}

// Central orchestrator for OCI image operations.
// Pushes VM bundle directories as chunked Jeballto OCI artifacts while preserving the public REST API.
// swiftlint:disable:next type_body_length
actor ImageManager {
  private static let deletionPendingMetadataKey = "jeballto.deletionPending"
  private static let maximumPushUploadStateSize = 8 * 1024 * 1024
  private struct ImageArtifactPullResult: Sendable {
    let digest: String
    let resources: VMResources
    let formatVersion: Int
  }

  private struct V1LayerDescriptorKey: Hashable, Sendable {
    let mediaType: String
    let digest: String
    let size: UInt64
  }

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

  private struct PreparedRegistryPush: Sendable {
    let manifestPath: String
    let manifestDigest: String
    let operationDirectory: String
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
  private let imageWorkSessionURL: URL
  nonisolated let imageWorkSessionForMaintenance: URL
  private let imageWorkChildProcessLease: ImageWorkChildProcessLease?
  private let eventBus: EventBus
  private var config: Config
  private var imageExportReservations: [UUID: Set<UUID>] = [:]
  private var deferredReplacedImages: [UUID: ImageRecord] = [:]
  private var deletingImageIds: Set<UUID> = []
  private var pendingDeletionIds: Set<UUID> = []
  private let operationCache = KeyedOperationGate()
  private let referenceMutationCache = KeyedOperationGate()
  private let imageStoreMutationGate = KeyedOperationGate()
  private var admittedImageStoreMutationCount = 0
  private let registryAuthGate = KeyedOperationGate()
  private let blobCache = ImageBlobCache()
  private let operationTracker = ImageOperationTracker()
  private let blobTransferLimiter: ImageConcurrencyLimiter
  private let compressionLimiter: ImageConcurrencyLimiter
  private let decompressionLimiter: ImageConcurrencyLimiter
  private let diskWriteLimiter: ImageConcurrencyLimiter
  private let diskImageCapacityValidator: DiskImageCapacityValidator
  private let registryAvailabilityChecker: RegistryAvailabilityChecker
  private let bundleCopyRunner: BundleCopyRunner?

  init(
    imageStore: ImageStore,
    orasClient: OrasClient,
    eventBus: EventBus,
    config: Config,
    diskImageCapacityValidator: @escaping DiskImageCapacityValidator = DiskImageInspector.validateASIFCapacity,
    registryAvailabilityChecker: RegistryAvailabilityChecker? = nil,
    bundleCopyRunner: BundleCopyRunner? = nil
  ) {
    self.imageStore = imageStore
    self.orasClient = orasClient
    imageWorkSessionURL = orasClient.imageWorkSessionURL
    imageWorkSessionForMaintenance = orasClient.imageWorkSessionURL
    imageWorkChildProcessLease = orasClient.imageWorkChildProcessLease
    self.eventBus = eventBus
    self.config = config
    self.diskImageCapacityValidator = diskImageCapacityValidator
    self.registryAvailabilityChecker = registryAvailabilityChecker ?? { registry, insecure in
      try await orasClient.checkRegistryReachable(registryHost: registry, insecure: insecure)
    }
    self.bundleCopyRunner = bundleCopyRunner
    blobTransferLimiter = ImageConcurrencyLimiter(limit: config.images.maxParallelImageBlobTransfers)
    compressionLimiter = ImageConcurrencyLimiter(limit: config.images.maxParallelImageCompressions)
    decompressionLimiter = ImageConcurrencyLimiter(limit: config.images.maxParallelImageDecompressions)
    diskWriteLimiter = ImageConcurrencyLimiter(limit: config.images.maxParallelImageDiskWrites)
  }

  func updateConfiguration(_ newConfig: Config) async {
    config = newConfig
    orasClient = orasClient.updatingConfig(newConfig.images)
    await blobTransferLimiter.updateLimit(newConfig.images.maxParallelImageBlobTransfers)
    await compressionLimiter.updateLimit(newConfig.images.maxParallelImageCompressions)
    await decompressionLimiter.updateLimit(newConfig.images.maxParallelImageDecompressions)
    await diskWriteLimiter.updateLimit(newConfig.images.maxParallelImageDiskWrites)
  }

  func currentImageConfig() -> ImageConfig {
    config.images
  }

  func imageStoreMutationCountForTesting() -> Int {
    admittedImageStoreMutationCount
  }

  private func withSerializedImageStoreMutation<T: Sendable>(
    _ operation: @Sendable @escaping () async throws -> T
  ) async throws -> T {
    admittedImageStoreMutationCount += 1
    defer { admittedImageStoreMutationCount -= 1 }
    return try await imageStoreMutationGate.withExclusiveAccess(
      for: "image-index",
      operation: operation
    )
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

    let marker = ImageOperationCommitMarker(parent: ImageOperationDeadlineContext.commitMarker)
    return try await withThrowingTaskGroup(of: ImageOperationDeadlineEvent<T>.self) { group in
      group.addTask {
        await ImageOperationDeadlineContext.$commitMarker.withValue(marker) {
          do {
            return try await .succeeded(operation())
          } catch {
            return .failed(error)
          }
        }
      }
      group.addTask {
        do {
          try await Task.sleep(nanoseconds: timeoutNanoseconds(timeout))
          return .timedOut
        } catch {
          return .deadlineTaskCancelled
        }
      }

      var deadlineExpired = false
      while let event = try await group.next() {
        switch event {
        case .succeeded(let value):
          group.cancelAll()
          if deadlineExpired, marker.isCommitted == false {
            throw OrasError.timeout(operationName)
          }
          return value
        case .failed(let error):
          group.cancelAll()
          if deadlineExpired,
             marker.isCommitted == false,
             Self.isManifestCommitOutcomeUnknown(error) == false
          {
            throw OrasError.timeout(operationName)
          }
          throw error
        case .timedOut:
          deadlineExpired = true
          group.cancelAll()
        case .deadlineTaskCancelled:
          group.cancelAll()
        }
      }
      throw OrasError.invalidOutput("Image operation \(operationName) ended without a result")
    }
  }

  private nonisolated static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64 {
    let maxSeconds = TimeInterval(UInt64.max) / 1_000_000_000
    let clamped = min(timeout, maxSeconds)
    return UInt64(clamped * 1_000_000_000)
  }

  private nonisolated static func isManifestCommitOutcomeUnknown(_ error: Error) -> Bool {
    if let managerError = error as? ImageManagerError,
       case .pushCommitOutcomeUnknown = managerError
    {
      return true
    }
    if let orasError = error as? OrasError,
       case .manifestCommitOutcomeUnknown = orasError
    {
      return true
    }
    return false
  }

  nonisolated static func markCurrentImageOperationCommitted() {
    ImageOperationDeadlineContext.commitMarker?.markCommitted()
  }

  // MARK: - Startup Cleanup

  nonisolated static func cleanupImageWorkDirectory(
    imageWorkRoot: URL,
    activeSessionURL: URL,
    exclusiveProcessOwnershipConfirmed: Bool = false
  ) {
    let fileManager = FileManager.default
    guard isRealDirectory(atPath: imageWorkRoot.path) else { return }
    let sessionsURL = imageWorkRoot.appendingPathComponent("sessions", isDirectory: true)
    let sessions: [URL] = if isRealDirectory(atPath: sessionsURL.path) {
      (try? fileManager.contentsOfDirectory(
        at: sessionsURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )) ?? []
    } else {
      []
    }

    let activeSessionPath = (activeSessionURL.path as NSString).standardizingPath
    for session in sessions where (session.path as NSString).standardizingPath != activeSessionPath {
      switch ImageWorkSessionLock.removeSessionIfInactive(at: session) {
      case .removed:
        logInfo("Cleaned up inactive image work session directory: \(session.path)", category: "ImageManager")
      case .active:
        logInfo("Preserving active image work session directory: \(session.path)", category: "ImageManager")
      case .childLaunchInProgress:
        logInfo(
          "Preserving image work session while a child process acquires its lease: \(session.path)",
          category: "ImageManager"
        )
      case .legacyWithoutLock:
        guard exclusiveProcessOwnershipConfirmed else {
          logWarning(
            "Preserving legacy image work session without a lock: \(session.path)",
            category: "ImageManager"
          )
          continue
        }
        do {
          try fileManager.removeItem(at: session)
          logInfo("Cleaned up legacy image work session directory: \(session.path)", category: "ImageManager")
        } catch {
          logError(
            "Failed to clean up legacy image work session directory \(session.path): \(error.localizedDescription)",
            category: "ImageManager"
          )
        }
      case .preserved(let reason):
        logWarning(
          "Preserving image work session directory \(session.path): \(reason)",
          category: "ImageManager"
        )
      case .removalFailed(let message):
        logError(
          "Failed to clean up inactive image work session directory \(session.path): \(message)",
          category: "ImageManager"
        )
      }
    }
    if let rootItems = try? fileManager.contentsOfDirectory(
      at: imageWorkRoot,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) {
      for item in rootItems where isUUIDWorkDirectory(item.lastPathComponent, prefix: "oras-tmp-") {
        guard exclusiveProcessOwnershipConfirmed, isRealDirectory(atPath: item.path) else {
          logWarning(
            "Preserving legacy image work directory without a session lock: \(item.path)",
            category: "ImageManager"
          )
          continue
        }
        do {
          try fileManager.removeItem(at: item)
          logInfo("Cleaned up legacy image work directory: \(item.path)", category: "ImageManager")
        } catch {
          logError(
            "Failed to clean up legacy image work directory \(item.path): \(error.localizedDescription)",
            category: "ImageManager"
          )
        }
      }
    }
    removeEmptyImageWorkParents(imageWorkRoot: imageWorkRoot)
  }

  nonisolated static func cleanupImageWorkSessionContents(at sessionURL: URL) -> [String] {
    guard isRealDirectory(atPath: sessionURL.path) else { return [] }
    guard ImageWorkChildProcessLease.hasValidLaunchMarker(in: sessionURL) == false else {
      return ["Refusing to clear image work session while a child process is acquiring its lease: \(sessionURL.path)"]
    }
    let contents: [URL]
    do {
      contents = try FileManager.default.contentsOfDirectory(
        at: sessionURL,
        includingPropertiesForKeys: nil
      )
    } catch {
      return ["Failed to inspect image work session \(sessionURL.path): \(error.localizedDescription)"]
    }

    var errors: [String] = []
    for item in contents where ImageWorkSessionLock.protectedEntryNames.contains(item.lastPathComponent) == false {
      do {
        try FileManager.default.removeItem(at: item)
      } catch {
        errors.append("Failed to clear image work entry \(item.path): \(error.localizedDescription)")
      }
    }
    return errors
  }

  /// Cleans stale foreign sessions and the caller-owned session after image operations have drained.
  /// Active foreign sessions and child launch handoffs are preserved.
  nonisolated static func cleanupImageWorkForMaintenance(
    imageWorkRoot: URL,
    ownedSessionURL: URL
  ) -> [String] {
    cleanupImageWorkDirectory(
      imageWorkRoot: imageWorkRoot,
      activeSessionURL: ownedSessionURL,
      exclusiveProcessOwnershipConfirmed: true
    )
    return cleanupImageWorkSessionContents(at: ownedSessionURL)
  }

  nonisolated static func hasLiveForeignImageWork(
    imageWorkRoot: URL,
    ownedSessionURL: URL
  ) -> Bool {
    let sessionsURL = imageWorkRoot.appendingPathComponent("sessions", isDirectory: true)
    guard isRealDirectory(atPath: sessionsURL.path) else { return false }
    let ownedPath = (ownedSessionURL.path as NSString).standardizingPath
    let sessions = (try? FileManager.default.contentsOfDirectory(
      at: sessionsURL,
      includingPropertiesForKeys: nil
    )) ?? []
    return sessions.contains { session in
      (session.path as NSString).standardizingPath != ownedPath
        && ImageWorkSessionLock.containsLiveWork(at: session)
    }
  }

  private func hasLiveForeignImageWork() -> Bool {
    let sessionsURL = imageWorkSessionURL.deletingLastPathComponent()
    guard sessionsURL.lastPathComponent == "sessions" else { return false }
    return Self.hasLiveForeignImageWork(
      imageWorkRoot: sessionsURL.deletingLastPathComponent(),
      ownedSessionURL: imageWorkSessionURL
    )
  }

  private nonisolated static func removeEmptyImageWorkParents(imageWorkRoot: URL) {
    let fileManager = FileManager.default
    let sessionsPath = imageWorkRoot.appendingPathComponent("sessions", isDirectory: true).path
    if isDirectoryEmpty(atPath: sessionsPath) {
      try? fileManager.removeItem(atPath: sessionsPath)
    }
    if isDirectoryEmpty(atPath: imageWorkRoot.path) {
      try? fileManager.removeItem(atPath: imageWorkRoot.path)
    }
  }

  nonisolated static func cleanupStaleImageStorageArtifacts(
    imageStorageDir: String,
    preserving protectedPaths: Set<String> = []
  ) -> (deleted: Int, failed: Int, errors: [String]) {
    let fileManager = FileManager.default
    let canonicalProtectedPaths = Set(protectedPaths.map(canonicalFilesystemPath))
    guard filesystemEntryExists(atPath: imageStorageDir) else {
      return (0, 0, [])
    }
    guard isRealDirectory(atPath: imageStorageDir) else {
      return (0, 1, ["Refusing to inspect image storage because it is not a real directory: \(imageStorageDir)"])
    }
    let contents: [String]
    do {
      contents = try fileManager.contentsOfDirectory(atPath: imageStorageDir)
    } catch {
      return (
        0,
        1,
        ["Failed to inspect image storage at \(imageStorageDir): \(error.localizedDescription)"]
      )
    }

    var deleted = 0
    var failed = 0
    var errors: [String] = []
    for item in contents {
      let path = "\(imageStorageDir)/\(item)"
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }

      let isWorkDir = isUUIDWorkDirectory(item, prefix: "oras-tmp-")
        || isUUIDWorkDirectory(item, prefix: "vm-image-")
        || isUUIDWorkDirectory(item, prefix: "oras-pull-")
      let isUnpackDir = isManagedUnpackDirectory(item)
      let isUnindexedImageBundle = managedImageId(fromBundleName: item) != nil
        && canonicalProtectedPaths.contains(canonicalFilesystemPath(path)) == false
      guard isWorkDir || isUnpackDir || isUnindexedImageBundle else { continue }

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
    guard isRealDirectory(atPath: path) else { return false }
    guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
    return contents.isEmpty
  }

  private nonisolated static func isRealDirectory(atPath path: String) -> Bool {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { return false }
    var status = stat()
    return path.withCString { Darwin.lstat($0, &status) } == 0
      && status.st_mode & S_IFMT == S_IFDIR
  }

  private nonisolated static func filesystemEntryExists(atPath path: String) -> Bool {
    var status = stat()
    return path.withCString { Darwin.lstat($0, &status) } == 0
  }

  private nonisolated static func canonicalFilesystemPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
  }

  private nonisolated static func isUUIDWorkDirectory(_ name: String, prefix: String) -> Bool {
    guard name.hasPrefix(prefix) else { return false }
    return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
  }

  private nonisolated static func managedImageId(fromBundleName name: String) -> UUID? {
    guard name.hasSuffix(".bundle") else { return nil }
    return UUID(uuidString: String(name.dropLast(".bundle".count)))
  }

  private nonisolated static func isManagedUnpackDirectory(_ name: String) -> Bool {
    let suffixMarker = ".bundle.unpack-"
    guard name.hasPrefix("."), let markerRange = name.range(of: suffixMarker) else { return false }
    let imageId = String(name[name.index(after: name.startIndex) ..< markerRange.lowerBound])
    let workId = String(name[markerRange.upperBound...])
    return UUID(uuidString: imageId) != nil && UUID(uuidString: workId) != nil
  }

  nonisolated static func validateRunnableVMBundle(atPath bundlePath: String) throws {
    let invalidFiles = requiredVMImageBundleFileNames.filter { fileName in
      let filePath = "\(bundlePath)/\(fileName)"
      var status = stat()
      guard filePath.withCString({ Darwin.lstat($0, &status) }) == 0,
            status.st_mode & S_IFMT == S_IFREG,
            let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
            let size = attributes[.size] as? NSNumber else { return true }
      return size.uint64Value == 0
    }

    guard invalidFiles.isEmpty else {
      throw VMImagePackagerError.invalidLayout(
        "Required VM bundle files are missing, empty, or non-regular: \(invalidFiles.joined(separator: ", "))"
      )
    }
  }

  /// Finishes image deletions that were durably marked before a previous process stopped.
  func recoverPendingDeletions() async throws {
    let snapshot = try await imageStore.maintenanceSnapshot()

    let pending = snapshot.filter {
      $0.metadata[Self.deletionPendingMetadataKey] == "true"
    }
    pendingDeletionIds.formUnion(pending.map(\.id))
    for record in pending {
      do {
        try removeOwnedImageFiles(record)
        try await imageStore.removeImage(id: record.id)
        pendingDeletionIds.remove(record.id)
        logInfo("Completed pending deletion for image \(record.id)", category: "ImageManager")
      } catch {
        logError(
          "Failed to complete pending deletion for image \(record.id): \(error.localizedDescription)",
          category: "ImageManager"
        )
      }
    }
    let currentSnapshot = try await imageStore.maintenanceSnapshot()
    if hasLiveForeignImageWork() {
      logWarning(
        "Deferred stale image storage cleanup because a child from another image work session is still running",
        category: "ImageManager"
      )
      return
    }
    let cleanup = Self.cleanupStaleImageStorageArtifacts(
      imageStorageDir: config.images.imageStorageDir,
      preserving: Set(currentSnapshot.map(\.localPath))
    )
    for error in cleanup.errors {
      logError(error, category: "ImageManager")
    }
  }

  // MARK: - Queries

  func listImages() async throws -> [ImageRecord] {
    try await imageStore.listImages()
  }

  func getImage(id: UUID) async throws -> ImageRecord {
    guard let record = try await imageStore.getImage(id: id) else {
      throw ImageManagerError.imageNotFoundById(id)
    }
    return record
  }

  func getImageByReference(_ reference: String) async throws -> ImageRecord {
    guard let record = try await imageStore.getImageByReference(reference) else {
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

  func admitImageOperation(
    id: UUID,
    kind: ImageOperationKind,
    reference: String,
    source: String? = nil
  ) async throws -> ImageOperationStatus {
    try await operationTracker.admit(id: id, kind: kind, reference: reference, source: source)
  }

  func progressSink(for operationId: UUID) async -> ImageOperationProgressSink {
    let tracker = operationTracker
    return { update in
      await tracker.update(operationId, update)
    }
  }

  func updateImageOperationProgress(_ operationId: UUID, update: ImageOperationProgressUpdate) async {
    await operationTracker.update(operationId, update)
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

  func claimImageExport(_ id: UUID) async throws -> UUID {
    try await claimImageExportWithRecord(id).token
  }

  func claimImageExportWithRecord(
    _ id: UUID,
    expectedReference: String? = nil
  ) async throws -> (token: UUID, record: ImageRecord) {
    guard !deletingImageIds.contains(id) else {
      throw ImageManagerError.imageInUse("Image \(id.uuidString) is being deleted")
    }
    guard !pendingDeletionIds.contains(id) else {
      throw ImageManagerError.imageInUse("Image \(id.uuidString) is pending deletion")
    }

    let token = UUID()
    imageExportReservations[id, default: []].insert(token)
    do {
      guard let record = try await imageStore.getImageForExport(
        id: id,
        expectedReference: expectedReference
      ) else {
        throw ImageManagerError.imageNotFoundById(id)
      }
      return (token, record)
    } catch {
      releaseImageExport(id, token: token)
      throw error
    }
  }

  func releaseImageExport(_ id: UUID, token: UUID) {
    guard var tokens = imageExportReservations[id] else { return }
    tokens.remove(token)
    if tokens.isEmpty {
      imageExportReservations.removeValue(forKey: id)
      if let deferred = deferredReplacedImages.removeValue(forKey: id) {
        do {
          try removeOwnedImageFiles(deferred)
        } catch {
          logWarning(
            "Failed to remove deferred replaced image files for \(id): \(error.localizedDescription)",
            category: "ImageManager"
          )
        }
      }
    } else {
      imageExportReservations[id] = tokens
    }
  }

  private func ensureReferenceRecordCanBeReplaced(_ id: UUID?) throws {
    guard let id else { return }
    if deletingImageIds.contains(id) {
      throw ImageManagerError.imageInUse("Image \(id.uuidString) is being deleted")
    }
    if pendingDeletionIds.contains(id) {
      throw ImageManagerError.imageInUse("Image \(id.uuidString) is pending deletion")
    }
  }

  // MARK: - Pull

  /// Pulls an OCI artifact from a registry and stores it in the local image store.
  ///
  /// Uses ORAS blob fetches under the hood. Images are reconstructed from zstd-compressed chunks
  /// into a `.bundle` directory named after the image UUID.
  /// Digest references reuse a matching valid local record. Mutable tags are resolved before reuse,
  /// so a changed registry digest replaces stale local content.
  func pullImage(
    reference: String,
    timeout: TimeInterval? = nil,
    progressSink: ImageOperationProgressSink? = nil
  ) async throws -> ImageRecord {
    let parsed: ImageReference
    do {
      parsed = try ImageReference.parse(reference, defaultRegistry: config.images.defaultRegistry)
    } catch {
      throw ImageManagerError.invalidReference(error.localizedDescription)
    }

    do {
      return try await Self.withImageOperationDeadline(
        timeout: timeout,
        operationName: "image pull \(parsed.fullReference)"
      ) {
        try await self.referenceMutationCache.withExclusiveAccess(for: "reference:\(parsed.fullReference)") {
          try await self.pullParsedImage(parsed, timeout: timeout, progressSink: progressSink)
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ImageManagerError {
      throw error
    } catch {
      if let timeoutMessage = Self.timeoutMessage(from: error) {
        eventBus.publish(.imagePullFailed(reference: parsed.fullReference, error: error.localizedDescription))
        throw ImageManagerError.timeout(timeoutMessage)
      }
      throw error
    }
  }

  private func pullParsedImage(
    _ parsed: ImageReference,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> ImageRecord {
    if parsed.digest == nil {
      try await ensureRegistryAvailable(parsed)
    }
    let resolvedReference: ImageReference
    do {
      resolvedReference = try await immutableReference(for: parsed)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if let timeoutMessage = Self.timeoutMessage(from: error) {
        throw ImageManagerError.timeout(timeoutMessage)
      }
      throw ImageManagerError.pullFailed(
        "Failed to resolve \(parsed.fullReference) to an immutable digest: \(error.localizedDescription)"
      )
    }

    var existing = try await imageStore.getImageByReference(parsed.fullReference)
    var repairMatchingDigest = false
    if let cached = existing {
      try ensureReferenceRecordCanBeReplaced(cached.id)
      if cached.digest == resolvedReference.digest {
        do {
          try Self.validateRunnableVMBundle(atPath: cached.localPath)
          guard cached.formatVersion == VMImagePackager.currentFormatVersion else {
            throw VMImagePackagerError.invalidConfig("Local image record is missing supported format metadata")
          }
          guard let resources = cached.resources else {
            throw VMImagePackagerError.invalidConfig("Local image record is missing VM resource metadata")
          }
          try await diskImageCapacityValidator("\(cached.localPath)/Disk.img", resources.diskSize)
          let current = try await imageStore.getImageByReference(parsed.fullReference)
          if current == cached {
            try ensureReferenceRecordCanBeReplaced(cached.id)
            logInfo("Image already local at resolved digest: \(parsed.fullReference)", category: "ImageManager")
            return cached
          }
          existing = current
          repairMatchingDigest = current?.id == cached.id
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as ImageManagerError {
          throw error
        } catch {
          logWarning(
            "Repairing invalid cached image \(cached.id): \(error.localizedDescription)",
            category: "ImageManager"
          )
          let current = try await imageStore.getImageByReference(parsed.fullReference)
          existing = current
          repairMatchingDigest = current?.id == cached.id
        }
      }
    }

    if parsed.digest != nil {
      try await ensureRegistryAvailable(parsed)
    }

    logInfo("Pulling image: \(parsed.fullReference)", category: "ImageManager")
    eventBus.publish(.imagePullStarted(reference: parsed.fullReference))

    let imageId = UUID()
    let localDir = "\(config.images.imageStorageDir)/\(imageId.uuidString).bundle"
    let expectedRecordId = existing?.id
    let shouldRepairMatchingDigest = repairMatchingDigest

    do {
      return try await Self.withImageOperationDeadline(
        timeout: timeout,
        operationName: "image pull \(parsed.fullReference)"
      ) {
        try await self.performPullImage(
          parsed: parsed,
          resolvedReference: resolvedReference,
          imageId: imageId,
          localDir: localDir,
          expectedRecordId: expectedRecordId,
          repairMatchingDigest: shouldRepairMatchingDigest,
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
      try? FileManager.default.removeItem(atPath: localDir)
      let pullError = Self.classifyPullError(error)
      eventBus.publish(.imagePullFailed(reference: parsed.fullReference, error: pullError.localizedDescription))
      logError(
        "Image pull failed for \(parsed.fullReference): \(pullError.localizedDescription)",
        category: "ImageManager"
      )
      throw pullError
    }
  }

  nonisolated static func classifyPullError(_ error: any Error) -> ImageManagerError {
    if let imageManagerError = error as? ImageManagerError {
      return imageManagerError
    }
    if let packagerError = error as? VMImagePackagerError {
      switch packagerError {
      case .unsupportedFormat(let message):
        return .unsupportedImageFormat(message)
      case .invalidConfig, .invalidLayout, .digestMismatch, .unsupportedCompression:
        return .invalidImage(packagerError.localizedDescription)
      case .invalidBundle:
        return .pullFailed(packagerError.localizedDescription)
      }
    }
    if let manifestError = error as? JeballtoImageManifestError {
      switch manifestError {
      case .unsupportedArtifactType, .unsupportedManifestMediaType, .unsupportedConfigMediaType:
        return .unsupportedImageFormat(manifestError.localizedDescription)
      case .invalidManifest:
        return .invalidImage(manifestError.localizedDescription)
      }
    }
    if let blobValidationError = error as? OrasBlobValidationError {
      return .invalidImage(blobValidationError.localizedDescription)
    }
    if let diskImageError = error as? DiskImageInspectionError {
      switch diskImageError {
      case .unsupportedFormat, .capacityMismatch:
        return .invalidImage(diskImageError.localizedDescription)
      case .inspectionFailed:
        return .pullFailed(diskImageError.localizedDescription)
      }
    }
    return .pullFailed(error.localizedDescription)
  }

  nonisolated static func validateV1ManifestLayerContract(
    _ descriptors: [OrasDescriptor],
    config: VMImageBundleConfig
  ) throws {
    var expected: [V1LayerDescriptorKey: Int] = [:]
    for packedFile in config.files {
      for chunk in packedFile.chunks where chunk.zero == false {
        guard let digest = chunk.compressedDigest, let size = chunk.compressedSize else {
          throw VMImagePackagerError.invalidConfig(
            "Missing compressed layer descriptor for \(packedFile.path) chunk \(chunk.index)"
          )
        }
        let key = V1LayerDescriptorKey(mediaType: jeballtoImageChunkMediaType, digest: digest, size: size)
        expected[key, default: 0] += 1
      }
    }

    var actual: [V1LayerDescriptorKey: Int] = [:]
    for descriptor in descriptors {
      let key = V1LayerDescriptorKey(
        mediaType: descriptor.mediaType,
        digest: descriptor.digest,
        size: descriptor.size
      )
      actual[key, default: 0] += 1
    }

    guard expected != actual else { return }
    let missingCount = expected.reduce(0) { total, entry in
      total + max(0, entry.value - (actual[entry.key] ?? 0))
    }
    let unexpectedCount = actual.reduce(0) { total, entry in
      total + max(0, entry.value - (expected[entry.key] ?? 0))
    }
    throw VMImagePackagerError.invalidConfig(
      "Manifest layers do not match the v1 image config: \(missingCount) missing and "
        + "\(unexpectedCount) unexpected descriptor occurrences"
    )
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
    resources: VMResources,
    timeout: TimeInterval? = nil,
    progressSink: ImageOperationProgressSink? = nil
  ) async throws -> ImageRecord {
    try Self.validateRunnableVMBundle(atPath: vmBundlePath)
    let parsed: ImageReference
    do {
      parsed = try ImageReference.parse(reference, defaultRegistry: config.images.defaultRegistry)
    } catch {
      throw ImageManagerError.invalidReference(error.localizedDescription)
    }

    do {
      return try await Self.withImageOperationDeadline(
        timeout: timeout,
        operationName: "image push \(parsed.fullReference)"
      ) {
        try await self.diskImageCapacityValidator("\(vmBundlePath)/Disk.img", resources.diskSize)
        return try await self.referenceMutationCache.withExclusiveAccess(for: "reference:\(parsed.fullReference)") {
          let expectedRecordId = try await self.imageStore.getImageByReference(parsed.fullReference)?.id
          try await self.ensureReferenceRecordCanBeReplaced(expectedRecordId)
          logInfo("Pushing VM bundle to \(parsed.fullReference) from \(vmBundlePath)", category: "ImageManager")
          self.eventBus.publish(.imagePushStarted(reference: parsed.fullReference))

          do {
            return try await self.performPushImageFromVM(
              parsed: parsed,
              vmBundlePath: vmBundlePath,
              resources: resources,
              expectedRecordId: expectedRecordId,
              timeout: timeout,
              progressSink: progressSink
            )
          } catch is CancellationError {
            logInfo("Image push cancelled: \(parsed.fullReference)", category: "ImageManager")
            throw CancellationError()
          } catch let error as ImageManagerError {
            self.eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
            throw error
          } catch {
            if let timeoutMessage = Self.timeoutMessage(from: error) {
              self.eventBus.publish(.imagePushFailed(
                reference: parsed.fullReference,
                error: error.localizedDescription
              ))
              throw ImageManagerError.timeout(timeoutMessage)
            }
            self.eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
            throw ImageManagerError.pushFailed(error.localizedDescription)
          }
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ImageManagerError {
      throw error
    } catch {
      if let timeoutMessage = Self.timeoutMessage(from: error) {
        eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
        throw ImageManagerError.timeout(timeoutMessage)
      }
      throw error
    }
  }

  /// Re-pushes an existing local image to a (possibly different) registry reference
  func pushImage(
    reference: String,
    imageId: UUID,
    timeout: TimeInterval? = nil,
    progressSink: ImageOperationProgressSink? = nil
  ) async throws -> ImageRecord {
    let sourceClaim = try await claimImageExportWithRecord(imageId)
    defer {
      releaseImageExport(imageId, token: sourceClaim.token)
    }

    let existing = sourceClaim.record
    try Self.validateRunnableVMBundle(atPath: existing.localPath)
    guard let existingResources = existing.resources else {
      throw ImageManagerError.invalidImage(
        "local image \(existing.id.uuidString) is missing VM resource metadata"
      )
    }

    let parsed: ImageReference
    do {
      parsed = try ImageReference.parse(reference, defaultRegistry: config.images.defaultRegistry)
    } catch {
      throw ImageManagerError.invalidReference(error.localizedDescription)
    }

    do {
      return try await Self.withImageOperationDeadline(
        timeout: timeout,
        operationName: "image push \(parsed.fullReference)"
      ) {
        try await self.diskImageCapacityValidator("\(existing.localPath)/Disk.img", existingResources.diskSize)
        return try await self.referenceMutationCache.withExclusiveAccess(for: "reference:\(parsed.fullReference)") {
          let expectedRecordId = try await self.imageStore.getImageByReference(parsed.fullReference)?.id
          try await self.ensureReferenceRecordCanBeReplaced(expectedRecordId)
          logInfo("Re-pushing image \(imageId) to \(parsed.fullReference)", category: "ImageManager")
          self.eventBus.publish(.imagePushStarted(reference: parsed.fullReference))

          do {
            return try await self.performPushImage(
              parsed: parsed,
              sourceImageId: imageId,
              existing: existing,
              expectedRecordId: expectedRecordId,
              timeout: timeout,
              progressSink: progressSink
            )
          } catch is CancellationError {
            logInfo("Image push cancelled: \(parsed.fullReference)", category: "ImageManager")
            throw CancellationError()
          } catch let error as ImageManagerError {
            self.eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
            throw error
          } catch {
            if let timeoutMessage = Self.timeoutMessage(from: error) {
              self.eventBus.publish(.imagePushFailed(
                reference: parsed.fullReference,
                error: error.localizedDescription
              ))
              throw ImageManagerError.timeout(timeoutMessage)
            }
            self.eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
            throw ImageManagerError.pushFailed(error.localizedDescription)
          }
        }
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ImageManagerError {
      throw error
    } catch {
      if let timeoutMessage = Self.timeoutMessage(from: error) {
        eventBus.publish(.imagePushFailed(reference: parsed.fullReference, error: error.localizedDescription))
        throw ImageManagerError.timeout(timeoutMessage)
      }
      throw error
    }
  }

  /// Checks that a push destination reference is valid and its registry is reachable.
  func checkPushDestinationReachable(reference: String) async throws {
    let parsed: ImageReference
    do {
      parsed = try ImageReference.parse(reference, defaultRegistry: config.images.defaultRegistry)
    } catch {
      throw ImageManagerError.invalidReference(error.localizedDescription)
    }

    try await ensureRegistryAvailable(parsed)
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

    guard let initialRecord = try await imageStore.getImage(id: id) else {
      throw ImageManagerError.imageNotFoundById(id)
    }
    let referenceKey = "reference:\(initialRecord.reference)"
    try await referenceMutationCache.withExclusiveAccess(for: referenceKey) {
      try await self.withSerializedImageStoreMutation {
        guard let record = try await self.imageStore.getImage(id: id) else {
          throw ImageManagerError.imageNotFoundById(id)
        }

        logInfo("Deleting image \(id): \(record.reference)", category: "ImageManager")

        var tombstone = record
        tombstone.metadata[Self.deletionPendingMetadataKey] = "true"
        try await self.imageStore.updateImage(tombstone)
        await self.markImageDeletionPending(id)
        try await self.removeOwnedImageFiles(tombstone)
        try await self.imageStore.removeImage(id: id)
        await self.clearPendingImageDeletion(id)
        self.eventBus.publish(.imageDeleted(reference: record.reference))
        logInfo("Image deleted: \(record.reference)", category: "ImageManager")
      }
    }
  }

  private func removeOwnedImageFiles(_ record: ImageRecord) throws {
    let storageRoot = URL(fileURLWithPath: config.images.imageStorageDir, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let localURL = URL(fileURLWithPath: record.localPath, isDirectory: true).standardizedFileURL
    let resolvedLocalURL = localURL.resolvingSymlinksInPath()
    guard resolvedLocalURL.deletingLastPathComponent() == storageRoot,
          resolvedLocalURL.lastPathComponent == "\(record.id.uuidString).bundle" else
    {
      throw ImageManagerError.deleteFailed(
        "Refusing to delete unmanaged image path \(record.localPath) for image \(record.id.uuidString)"
      )
    }

    if FileManager.default.fileExists(atPath: localURL.path) {
      do {
        try FileManager.default.removeItem(at: localURL)
      } catch {
        throw ImageManagerError.deleteFailed(
          "Failed to remove files at \(localURL.path): \(error.localizedDescription)"
        )
      }
    }
  }

  private func markImageDeletionPending(_ id: UUID) {
    pendingDeletionIds.insert(id)
  }

  private func clearPendingImageDeletion(_ id: UUID) {
    pendingDeletionIds.remove(id)
  }

  func wipeAllImages() async -> (deleted: Int, failed: Int, errors: [String]) {
    logWarning("Wiping all images", category: "ImageManager")
    let images: [ImageRecord]
    do {
      images = try await imageStore.listImages()
    } catch {
      let message = "Refusing to wipe images because the image index is unavailable: \(error.localizedDescription)"
      logError(message, category: "ImageManager")
      return (0, 1, [message])
    }
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
    let remainingImages: [ImageRecord]
    do {
      remainingImages = try await imageStore.maintenanceSnapshot()
    } catch {
      let message = "Image wipe could not verify the remaining index: \(error.localizedDescription)"
      logError(message, category: "ImageManager")
      failed += 1
      errors.append(message)
      let imageWorkErrors = Self.cleanupImageWorkSessionContents(at: imageWorkSessionURL)
      failed += imageWorkErrors.count
      errors.append(contentsOf: imageWorkErrors)
      return (deleted, failed, errors)
    }
    let staleArtifacts: (deleted: Int, failed: Int, errors: [String]) = if hasLiveForeignImageWork() {
      (
        0,
        1,
        ["Deferred stale image storage cleanup because a child from another image work session is still running"]
      )
    } else {
      Self.cleanupStaleImageStorageArtifacts(
        imageStorageDir: config.images.imageStorageDir,
        preserving: Set(remainingImages.map(\.localPath))
      )
    }
    deleted += staleArtifacts.deleted
    failed += staleArtifacts.failed
    errors.append(contentsOf: staleArtifacts.errors)
    let imageWorkErrors = Self.cleanupImageWorkSessionContents(at: imageWorkSessionURL)
    failed += imageWorkErrors.count
    errors.append(contentsOf: imageWorkErrors)
    logInfo("Wipe complete: \(deleted) deleted, \(failed) failed", category: "ImageManager")
    return (deleted, failed, errors)
  }

  // MARK: - Registry Auth

  func loginRegistry(registry: String, username: String, password: String) async throws {
    let insecure = config.images.insecureRegistries.contains(registry)
    let client = orasClient
    let availabilityChecker = registryAvailabilityChecker
    try await registryAuthGate.withExclusiveAccess(for: registry) {
      do {
        try await availabilityChecker(registry, insecure)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw ImageManagerError.registryUnavailable(
          "Registry \(registry) is unavailable: \(error.localizedDescription)"
        )
      }
      do {
        try await client.login(registry: registry, username: username, password: password, insecure: insecure)
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as OrasError {
        if case .commandFailed = error {
          do {
            try await availabilityChecker(registry, insecure)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            throw ImageManagerError.registryUnavailable(
              "Registry \(registry) became unavailable during login: \(error.localizedDescription)"
            )
          }
        }
        throw error
      }
    }
    logInfo("Logged in to registry: \(registry)", category: "ImageManager")
  }

  func logoutRegistry(registry: String) async throws {
    let client = orasClient
    try await registryAuthGate.withExclusiveAccess(for: registry) {
      try await client.logout(registry: registry)
    }
    logInfo("Logged out from registry: \(registry)", category: "ImageManager")
  }

  // MARK: - Helpers

  private func immutableReference(for reference: ImageReference) async throws -> ImageReference {
    if reference.digest != nil { return reference }
    let insecure = reference.isInsecureAllowed(insecureRegistries: config.images.insecureRegistries)
    let digest = try await orasClient.resolve(reference: reference, insecure: insecure)
    return try ImageReference.parse("\(reference.registry)/\(reference.repository)@\(digest)")
  }

  private func ensureRegistryAvailable(_ reference: ImageReference) async throws {
    let insecure = reference.isInsecureAllowed(insecureRegistries: config.images.insecureRegistries)
    do {
      try await registryAvailabilityChecker(reference.registry, insecure)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw ImageManagerError.registryUnavailable(
        "Registry \(reference.registry) is unavailable: \(error.localizedDescription)"
      )
    }
  }

  private func removeReplacedImageFiles(_ record: ImageRecord?) {
    guard let record else { return }
    if let reservations = imageExportReservations[record.id], reservations.isEmpty == false {
      deferredReplacedImages[record.id] = record
      return
    }
    do {
      try removeOwnedImageFiles(record)
    } catch {
      logWarning(
        "Failed to remove replaced image files for \(record.id): \(error.localizedDescription)",
        category: "ImageManager"
      )
    }
  }

  private func performPullImage(
    parsed: ImageReference,
    resolvedReference: ImageReference,
    imageId: UUID,
    localDir: String,
    expectedRecordId: UUID?,
    repairMatchingDigest: Bool,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> ImageRecord {
    try Self.createPrivateDirectory(atPath: localDir)

    let insecure = parsed.isInsecureAllowed(insecureRegistries: config.images.insecureRegistries)
    let manifest: OrasManifestInfo
    do {
      manifest = try await orasClient.fetchManifest(reference: resolvedReference, insecure: insecure)
    } catch let error as OrasError {
      if case .invalidOutput = error {
        throw ImageManagerError.invalidImage(error.localizedDescription)
      }
      throw error
    }
    do {
      try manifest.validateJeballtoImageEnvelope(reference: parsed.fullReference)
    } catch {
      logError(
        "Rejected image manifest for \(parsed.fullReference): \(manifest.formatSummary)",
        category: "ImageManager"
      )
      throw error
    }
    let pullResult = try await pullImageArtifact(
      resolvedReference,
      manifest: manifest,
      localDir: localDir,
      insecure: insecure,
      timeout: timeout,
      progressSink: progressSink
    )
    try Self.validateRunnableVMBundle(atPath: localDir)
    try await diskImageCapacityValidator("\(localDir)/Disk.img", pullResult.resources.diskSize)

    let size = directorySize(atPath: localDir)

    let record = ImageRecord(
      id: imageId,
      reference: parsed.fullReference,
      digest: pullResult.digest,
      localPath: localDir,
      size: size,
      pulledAt: Date(),
      resources: pullResult.resources,
      formatVersion: pullResult.formatVersion,
      metadata: [
        "ownsLocalPath": "true",
        "imageFormat": "chunked-zstd",
        "architecture": "arm64",
      ]
    )

    let storageResult = try await withSerializedImageStoreMutation {
      try await self.ensureReferenceRecordCanBeReplaced(expectedRecordId)
      try Task.checkCancellation()
      return try await self.imageStore.commitImageForReference(
        record,
        replacing: expectedRecordId,
        repairMatchingDigest: repairMatchingDigest
      )
    }
    Self.markCurrentImageOperationCommitted()
    if storageResult.stored.id != record.id {
      try? FileManager.default.removeItem(atPath: localDir)
      eventBus.publish(.imagePulled(reference: parsed.fullReference))
      logInfo("Image became local while pulling: \(parsed.fullReference)", category: "ImageManager")
      return storageResult.stored
    }
    removeReplacedImageFiles(storageResult.replaced)

    eventBus.publish(.imagePulled(reference: parsed.fullReference))
    logInfo("Image pulled: \(parsed.fullReference) -> \(localDir)", category: "ImageManager")

    return record
  }

  private func performPushImageFromVM(
    parsed: ImageReference,
    vmBundlePath: String,
    resources: VMResources,
    expectedRecordId: UUID?,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> ImageRecord {
    let insecure = parsed.isInsecureAllowed(insecureRegistries: config.images.insecureRegistries)
    try await ensureRegistryAvailable(parsed)
    let preparedPush = try await prepareRegistryPush(
      reference: parsed,
      bundlePath: vmBundlePath,
      resources: resources,
      insecure: insecure,
      timeout: timeout,
      progressSink: progressSink
    )
    defer { try? FileManager.default.removeItem(atPath: preparedPush.operationDirectory) }

    let imageId = UUID()
    let localDir = "\(config.images.imageStorageDir)/\(imageId.uuidString).bundle"
    do {
      try await copyBundleForImageRecord(
        from: vmBundlePath,
        to: localDir,
        reference: parsed.fullReference,
        timeout: timeout,
        progressSink: progressSink
      )
      try Self.validateRunnableVMBundle(atPath: localDir)
      try await diskImageCapacityValidator("\(localDir)/Disk.img", resources.diskSize)
      try Task.checkCancellation()
    } catch {
      try? FileManager.default.removeItem(atPath: localDir)
      throw error
    }
    let record = ImageRecord(
      id: imageId,
      reference: parsed.fullReference,
      digest: preparedPush.manifestDigest,
      localPath: localDir,
      size: directorySize(atPath: localDir),
      pushedAt: Date(),
      resources: resources,
      formatVersion: VMImagePackager.currentFormatVersion,
      metadata: [
        "sourceType": "vm",
        "sourceVmBundlePath": vmBundlePath,
        "ownsLocalPath": "true",
        "imageFormat": "chunked-zstd",
        "artifactType": jeballtoImageArtifactType,
        "architecture": "arm64",
        "compression": "zstd",
        "chunkSize": String(VMImagePackager.defaultChunkSize),
      ]
    )

    let storedRecord: ImageRecord
    do {
      let result = try await commitPreparedRegistryPush(
        parsed: parsed,
        insecure: insecure,
        preparedPush: preparedPush,
        record: record,
        expectedRecordId: expectedRecordId,
        timeout: timeout
      )
      storedRecord = result.stored
      removeReplacedImageFiles(result.replaced)
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
    logInfo(
      "Image pushed: \(parsed.fullReference) (digest: \(preparedPush.manifestDigest))",
      category: "ImageManager"
    )

    return record
  }

  private func performPushImage(
    parsed: ImageReference,
    sourceImageId: UUID,
    existing: ImageRecord,
    expectedRecordId: UUID?,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> ImageRecord {
    guard let existingResources = existing.resources else {
      throw ImageManagerError.pushFailed("Local image is missing VM resource metadata")
    }
    let insecure = parsed.isInsecureAllowed(insecureRegistries: config.images.insecureRegistries)
    try await ensureRegistryAvailable(parsed)
    let preparedPush = try await prepareRegistryPush(
      reference: parsed,
      bundlePath: existing.localPath,
      resources: existingResources,
      insecure: insecure,
      timeout: timeout,
      progressSink: progressSink
    )
    defer { try? FileManager.default.removeItem(atPath: preparedPush.operationDirectory) }

    let newId = UUID()
    let localDir = "\(config.images.imageStorageDir)/\(newId.uuidString).bundle"
    do {
      try await copyBundleForImageRecord(
        from: existing.localPath,
        to: localDir,
        reference: parsed.fullReference,
        timeout: timeout,
        progressSink: progressSink
      )
      try Self.validateRunnableVMBundle(atPath: localDir)
      try await diskImageCapacityValidator("\(localDir)/Disk.img", existingResources.diskSize)
      try Task.checkCancellation()
    } catch {
      try? FileManager.default.removeItem(atPath: localDir)
      throw error
    }
    let record = ImageRecord(
      id: newId,
      reference: parsed.fullReference,
      digest: preparedPush.manifestDigest,
      localPath: localDir,
      size: directorySize(atPath: localDir),
      pulledAt: existing.pulledAt,
      pushedAt: Date(),
      resources: existing.resources,
      formatVersion: VMImagePackager.currentFormatVersion,
      metadata: [
        "sourceImageId": sourceImageId.uuidString,
        "ownsLocalPath": "true",
        "imageFormat": "chunked-zstd",
        "artifactType": jeballtoImageArtifactType,
        "architecture": "arm64",
        "compression": "zstd",
        "chunkSize": String(VMImagePackager.defaultChunkSize),
      ]
    )

    let storedRecord: ImageRecord
    do {
      let result = try await commitPreparedRegistryPush(
        parsed: parsed,
        insecure: insecure,
        preparedPush: preparedPush,
        record: record,
        expectedRecordId: expectedRecordId,
        timeout: timeout
      )
      storedRecord = result.stored
      removeReplacedImageFiles(result.replaced)
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
    logInfo(
      "Image re-pushed: \(parsed.fullReference) (digest: \(preparedPush.manifestDigest))",
      category: "ImageManager"
    )

    return record
  }

  private func commitPreparedRegistryPush(
    parsed: ImageReference,
    insecure: Bool,
    preparedPush: PreparedRegistryPush,
    record: ImageRecord,
    expectedRecordId: UUID?,
    timeout: TimeInterval?
  ) async throws -> (stored: ImageRecord, replaced: ImageRecord?) {
    try await withSerializedImageStoreMutation {
      try await self.ensureReferenceRecordCanBeReplaced(expectedRecordId)
      try Task.checkCancellation()
      let preparedCommit = try await self.imageStore.prepareImageForReference(
        record,
        replacing: expectedRecordId,
        repairMatchingDigest: true
      )

      let pushResult: OrasPushResult
      do {
        try Task.checkCancellation()
        pushResult = try await self.orasClient.pushManifest(
          reference: parsed,
          manifestPath: preparedPush.manifestPath,
          insecure: insecure,
          timeout: timeout
        )
      } catch let error as OrasError {
        await self.imageStore.abortPreparedImageCommit(preparedCommit)
        if case .manifestCommitOutcomeUnknown(let reason) = error {
          throw ImageManagerError.pushCommitOutcomeUnknown(
            reference: parsed.fullReference,
            digest: preparedPush.manifestDigest,
            reason: reason
          )
        }
        throw error
      } catch {
        await self.imageStore.abortPreparedImageCommit(preparedCommit)
        throw error
      }

      Self.markCurrentImageOperationCommitted()
      do {
        return try await self.imageStore.finalizePreparedImageCommit(preparedCommit)
      } catch {
        await self.imageStore.abortPreparedImageCommit(preparedCommit)
        throw ImageManagerError.pushPartiallyCommitted(
          reference: parsed.fullReference,
          digest: pushResult.digest,
          reason: error.localizedDescription
        )
      }
    }
  }

  private func prepareRegistryPush(
    reference: ImageReference,
    bundlePath: String,
    resources: VMResources,
    insecure: Bool,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> PreparedRegistryPush {
    let packager = VMImagePackager(
      zstdClient: ZstdClient(
        config: config.images,
        childProcessLease: imageWorkChildProcessLease
      ),
      maxParallelChunks: config.images.maxParallelImageCompressions,
      compressionLimiter: compressionLimiter
    )
    let sourceFingerprint = try packager.sourceFingerprint(bundlePath: bundlePath, resources: resources)
    return try await withOperationCacheAccess(for: "push:\(sourceFingerprint)") {
      let pushDir = Self.pushOperationDirectory(
        sourceFingerprint: sourceFingerprint,
        imageWorkSessionURL: self.imageWorkSessionURL
      )
      let packageDir = "\(pushDir)/package"
      try Self.createPrivateDirectory(atPath: pushDir)
      try Self.createPrivateDirectory(atPath: packageDir)
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
        resources: resources,
        timeout: timeout,
        progressSink: compressionProgressSink
      )
      logInfo(
        "Compression finished for \(reference.fullReference); preparing \(package.layers.count) layers for upload",
        category: "ImageManager"
      )

      let preparedPush = try await prepareImagePackagePush(
        reference: reference,
        package: package,
        insecure: insecure,
        operationDirectory: pushDir,
        timeout: timeout,
        progressSink: progressSink
      )
      try? FileManager.default.removeItem(atPath: pushDir)
      return preparedPush
    }
  }

  private func pullImageArtifact(
    _ reference: ImageReference,
    manifest: OrasManifestInfo,
    localDir: String,
    insecure: Bool,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> ImageArtifactPullResult {
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
  ) async throws -> ImageArtifactPullResult {
    let pullDir = Self.pullOperationDirectory(
      manifestDigest: resolvedDigest,
      imageWorkSessionURL: imageWorkSessionURL
    )
    let blobCacheDir = "\(pullDir)/blobs"
    let configPath = "\(pullDir)/config/vm-bundle-config.json"
    let layerDirectory = "\(pullDir)/layers"
    try Self.createPrivateDirectory(atPath: pullDir)
    try Self.createPrivateDirectory(atPath: blobCacheDir)
    try Self.createPrivateDirectory(atPath: (configPath as NSString).deletingLastPathComponent)
    try? FileManager.default.removeItem(atPath: layerDirectory)
    try Self.createPrivateDirectory(atPath: layerDirectory)

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
      blobTransferLimiter: blobTransferLimiter,
      timeout: timeout
    )
    try Self.copyCachedBlob(from: configCachePath, to: configPath)

    let packager = VMImagePackager(
      zstdClient: ZstdClient(
        config: config.images,
        childProcessLease: imageWorkChildProcessLease
      ),
      maxParallelUnpackChunks: config.images.maxParallelImageBlobTransfers,
      maxParallelDecompressions: config.images.maxParallelImageDecompressions,
      maxParallelDiskWrites: config.images.maxParallelImageDiskWrites,
      decompressionLimiter: decompressionLimiter,
      diskWriteLimiter: diskWriteLimiter
    )
    let bundleConfig = try packager.decodeConfig(atPath: configPath)
    try manifest.validateJeballtoV1Layers(reference: reference.fullReference)
    try Self.validateV1ManifestLayerContract(manifest.layers, config: bundleConfig)
    let totalBytes = try manifest.layers.reduce(configDescriptor.size) { total, layer in
      let (result, overflow) = total.addingReportingOverflow(layer.size)
      guard overflow == false else {
        throw JeballtoImageManifestError.invalidManifest("OCI manifest blob size overflow")
      }
      return result
    }
    await progressSink?(
      ImageOperationProgressUpdate(
        chunksTotal: manifest.layers.count,
        bytesCompletedDelta: configDescriptor.size,
        bytesTotal: totalBytes
      )
    )

    var layerDescriptorsByDigest: [String: OrasDescriptor] = [:]
    for descriptor in manifest.layers where layerDescriptorsByDigest[descriptor.digest] == nil {
      layerDescriptorsByDigest[descriptor.digest] = descriptor
    }
    let fetchLayer = makeV1LayerFetcher(
      reference: reference,
      descriptorsByDigest: layerDescriptorsByDigest,
      blobCacheDirectory: blobCacheDir,
      insecure: insecure,
      timeout: timeout,
      progressSink: progressSink
    )

    try await packager.unpackBundle(
      configPath: configPath,
      layerDirectory: layerDirectory,
      outputBundlePath: localDir,
      fetchLayer: fetchLayer,
      timeout: timeout
    )
    try? FileManager.default.removeItem(atPath: pullDir)
    return ImageArtifactPullResult(
      digest: resolvedDigest,
      resources: bundleConfig.resources,
      formatVersion: bundleConfig.formatVersion
    )
  }

  private func makeV1LayerFetcher(
    reference: ImageReference,
    descriptorsByDigest: [String: OrasDescriptor],
    blobCacheDirectory: String,
    insecure: Bool,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) -> VMImageLayerFetcher {
    let orasClient = orasClient
    let blobCache = blobCache
    let blobTransferLimiter = blobTransferLimiter
    return { packedFile, chunk, destinationPath in
      guard let compressedDigest = chunk.compressedDigest,
            let compressedSize = chunk.compressedSize,
            chunk.layerPath != nil else
      {
        throw VMImagePackagerError.invalidConfig("Missing layer metadata for \(packedFile.path) chunk \(chunk.index)")
      }
      guard let descriptor = descriptorsByDigest[compressedDigest] else {
        throw VMImagePackagerError.invalidConfig("Layer \(compressedDigest) is missing from the OCI manifest")
      }
      guard descriptor.mediaType == jeballtoImageChunkMediaType else {
        throw VMImagePackagerError.invalidConfig(
          "Layer \(compressedDigest) has unsupported media type \(descriptor.mediaType)"
        )
      }
      guard descriptor.size == compressedSize else {
        throw VMImagePackagerError.invalidConfig(
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
        blobTransferLimiter: blobTransferLimiter,
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
  }

  private func withOperationCacheAccess<T: Sendable>(
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

  private func prepareImagePackagePush(
    reference: ImageReference,
    package: VMImagePackage,
    insecure: Bool,
    operationDirectory: String,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws -> PreparedRegistryPush {
    let repositoryReference = OrasClient.repositoryReference(reference)
    let configDescriptor = try Self.descriptor(
      filePath: package.configPath,
      mediaType: jeballtoImageConfigMediaType
    )
    let layerCandidates = package.layers.map { layer in
      PushBlobCandidate(
        descriptor: OrasDescriptor(mediaType: layer.mediaType, digest: layer.digest, size: layer.size),
        filePath: layer.absolutePath
      )
    }
    let configCandidate = PushBlobCandidate(descriptor: configDescriptor, filePath: package.configPath)
    let candidates = Self.uniqueBlobCandidates([configCandidate] + layerCandidates)
    let bytesTotal = try candidates.reduce(UInt64(0)) { total, candidate in
      let (result, overflow) = total.addingReportingOverflow(candidate.descriptor.size)
      guard !overflow, result <= VMImagePackager.maximumTotalBlobSize else {
        throw OrasError.invalidOutput("OCI upload exceeds the supported total blob size")
      }
      return result
    }
    logInfo(
      "Uploading \(candidates.count) blobs (\(bytesTotal) bytes) to \(reference.fullReference)",
      category: "ImageManager"
    )
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
    let manifestDigest = try Self.sha256File(atPath: manifestPath)
    let commitDirectory = Self.registryCommitOperationDirectory(imageWorkSessionURL: imageWorkSessionURL)
    let commitManifestPath = "\(commitDirectory)/manifest.json"
    try Self.createPrivateDirectory(atPath: commitDirectory)
    do {
      try Self.copyCachedBlob(from: manifestPath, to: commitManifestPath)
    } catch {
      try? FileManager.default.removeItem(atPath: commitDirectory)
      throw error
    }
    return PreparedRegistryPush(
      manifestPath: commitManifestPath,
      manifestDigest: manifestDigest,
      operationDirectory: commitDirectory
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
    let blobTransferLimiter = blobTransferLimiter

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
            blobTransferLimiter: blobTransferLimiter,
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
                blobTransferLimiter: blobTransferLimiter,
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
    blobTransferLimiter: ImageConcurrencyLimiter,
    timeout: TimeInterval?
  ) async throws -> PushBlobUploadResult {
    try await blobTransferLimiter.withPermit {
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
  }

  private nonisolated static func fetchBlobIntoCache(
    reference: ImageReference,
    descriptor: OrasDescriptor,
    cachePath: String,
    insecure: Bool,
    orasClient: OrasClient,
    blobCache: ImageBlobCache,
    blobTransferLimiter: ImageConcurrencyLimiter,
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
      try await blobTransferLimiter.withPermit {
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

  nonisolated static func pullOperationDirectory(manifestDigest: String, imageWorkSessionURL: URL) -> String {
    imageWorkSessionURL
      .appendingPathComponent(
        "operations/pulls/\(sanitizeCacheKey(manifestDigest))",
        isDirectory: true
      )
      .path
  }

  nonisolated static func pushOperationDirectory(sourceFingerprint: String, imageWorkSessionURL: URL) -> String {
    imageWorkSessionURL
      .appendingPathComponent(
        "operations/pushes/\(sanitizeCacheKey(sourceFingerprint))",
        isDirectory: true
      )
      .path
  }

  private nonisolated static func registryCommitOperationDirectory(imageWorkSessionURL: URL) -> String {
    imageWorkSessionURL
      .appendingPathComponent(
        "operations/manifest-commits/\(UUID().uuidString)",
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
    let sanitized = value.map { character in
      character.isLetter || character.isNumber ? character : "-"
    }.reduce(into: "") { result, character in
      result.append(character)
    }
    guard sanitized.utf8.count > 160 else { return sanitized }
    let digest = SHA256.hash(data: Data(value.utf8))
      .prefix(12)
      .map { String(format: "%02x", $0) }
      .joined()
    return "\(sanitized.prefix(120))-\(digest)"
  }

  private nonisolated static func loadPushUploadState(
    path: String,
    repositoryReference: String
  ) -> PushUploadState {
    guard let data = try? boundedData(atPath: path, maximumSize: maximumPushUploadStateSize),
          let state = try? JSONDecoder().decode(PushUploadState.self, from: data),
          state.repositoryReference == repositoryReference else
    {
      return PushUploadState(repositoryReference: repositoryReference, uploadedDigests: [])
    }
    return state
  }

  private nonisolated static func savePushUploadState(_ state: PushUploadState, path: String) throws {
    let parent = (path as NSString).deletingLastPathComponent
    try createPrivateDirectory(atPath: parent)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(state)
    guard data.count <= maximumPushUploadStateSize else {
      throw OrasError.invalidOutput("Image upload resume state exceeds the 8MB limit")
    }
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  }

  private nonisolated static func writeManifest(
    configDescriptor: OrasDescriptor,
    layerDescriptors: [OrasDescriptor],
    manifestPath: String
  ) throws {
    let parent = (manifestPath as NSString).deletingLastPathComponent
    try createPrivateDirectory(atPath: parent)
    try ociImageManifestData(
      configDescriptor: configDescriptor,
      layerDescriptors: layerDescriptors
    ).write(to: URL(fileURLWithPath: manifestPath), options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestPath)
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
    let data = try encoder.encode(manifest)
    guard let rawManifest = String(data: data, encoding: .utf8) else {
      throw OrasError.invalidOutput("Generated OCI manifest is not valid UTF-8")
    }
    let parsed = try OrasManifestInfo(rawManifest: rawManifest)
    try parsed.validateJeballtoImage(reference: "generated image")
    return data
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
    try createPrivateDirectory(atPath: parent)
    if FileManager.default.fileExists(atPath: destinationPath) {
      try FileManager.default.removeItem(atPath: destinationPath)
    }
    try FileManager.default.copyItem(atPath: sourcePath, toPath: destinationPath)
  }

  private func copyBundleForImageRecord(
    from sourcePath: String,
    to destinationPath: String,
    reference: String,
    timeout: TimeInterval?,
    progressSink: ImageOperationProgressSink?
  ) async throws {
    await progressSink?(
      ImageOperationProgressUpdate(
        stage: .finalizing,
        progress: 0.99,
        stageProgress: 0
      )
    )
    logInfo(
      "Creating local image snapshot for \(reference) at \(destinationPath)",
      category: "ImageManager"
    )
    let parent = (destinationPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: destinationPath) {
      try FileManager.default.removeItem(atPath: destinationPath)
    }
    do {
      try Task.checkCancellation()
      if let bundleCopyRunner {
        try await bundleCopyRunner(sourcePath, destinationPath)
      } else {
        try await runBundleCopyProcess(
          sourcePath: sourcePath,
          destinationPath: destinationPath,
          timeout: timeout
        )
      }
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destinationPath)
      try Task.checkCancellation()
      logInfo(
        "Created local image snapshot for \(reference) at \(destinationPath)",
        category: "ImageManager"
      )
      await progressSink?(
        ImageOperationProgressUpdate(
          stage: .finalizing,
          progress: 0.99,
          stageProgress: 1
        )
      )
    } catch is CancellationError {
      try? FileManager.default.removeItem(atPath: destinationPath)
      throw CancellationError()
    } catch let error as AsyncProcessRunnerError {
      try? FileManager.default.removeItem(atPath: destinationPath)
      switch error {
      case .timeout(let description):
        throw OrasError.timeout(description)
      case .launchFailed(let message):
        throw ImageManagerError.pushFailed("Failed to launch bundle copy: \(message)")
      case .inputWriteFailed(let message):
        throw ImageManagerError.pushFailed("Failed to write bundle copy standard input: \(message)")
      }
    } catch {
      try? FileManager.default.removeItem(atPath: destinationPath)
      throw error
    }
  }

  private func runBundleCopyProcess(
    sourcePath: String,
    destinationPath: String,
    timeout: TimeInterval?
  ) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/cp")
    process.arguments = ["-c", "-R", sourcePath, destinationPath]
    process.environment = bundledToolEnvironment()
    process.standardInput = FileHandle.nullDevice
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let childLaunchReservation = try imageWorkChildProcessLease?.prepare(process)
    let result = try await AsyncProcessRunner.run(
      process: process,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe,
      options: AsyncProcessRunnerOptions(
        timeout: timeout,
        timeoutDescription: "copy image bundle to \(destinationPath)",
        maxOutputSize: 64 * 1024
      ),
      childLaunchReservation: childLaunchReservation
    )
    guard result.exitCode == 0 else {
      let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
      throw ImageManagerError.pushFailed(
        "Failed to create local image copy at \(destinationPath) (cp exit \(result.exitCode)): \(stderr)"
      )
    }
  }

  private nonisolated static func fileSize(atPath path: String) throws -> UInt64 {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    guard let number = attrs[.size] as? NSNumber, number.doubleValue >= 0 else {
      throw OrasError.invalidOutput("Invalid file size metadata for \(path)")
    }
    return number.uint64Value
  }

  private nonisolated static func createPrivateDirectory(atPath path: String) throws {
    try FileManager.default.createDirectory(
      atPath: path,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
  }

  private nonisolated static func boundedData(atPath path: String, maximumSize: Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumSize + 1) ?? Data()
    guard data.count <= maximumSize else {
      throw OrasError.invalidOutput("Cached image operation state at \(path) exceeds the size limit")
    }
    return data
  }

  private nonisolated static func sha256File(atPath path: String) throws -> String {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      try Task.checkCancellation()
      let data = try readFileChunk(from: handle, upToCount: 4 * 1024 * 1024) ?? Data()
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
      if let size = try? Self.fileSize(atPath: fullPath) {
        let (newTotal, overflow) = totalSize.addingReportingOverflow(size)
        totalSize = overflow ? UInt64.max : newTotal
      }
    }
    return totalSize
  }
}
