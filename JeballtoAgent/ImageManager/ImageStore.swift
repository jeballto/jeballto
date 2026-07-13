import Darwin
import Foundation

/// A locally stored OCI image record
struct ImageRecord: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var reference: String
  var digest: String?
  var localPath: String
  var size: UInt64?
  var pulledAt: Date?
  var pushedAt: Date?
  var resources: VMResources?
  var formatVersion: Int
  var metadata: [String: String]

  init(
    id: UUID = UUID(),
    reference: String,
    digest: String? = nil,
    localPath: String,
    size: UInt64? = nil,
    pulledAt: Date? = nil,
    pushedAt: Date? = nil,
    resources: VMResources? = nil,
    formatVersion: Int = VMImagePackager.currentFormatVersion,
    metadata: [String: String] = ["ownsLocalPath": "true"]
  ) {
    self.id = id
    self.reference = reference
    self.digest = digest
    self.localPath = localPath
    self.size = size
    self.pulledAt = pulledAt
    self.pushedAt = pushedAt
    self.resources = resources
    self.formatVersion = formatVersion
    self.metadata = metadata
  }
}

/// Top-level image index structure
struct ImageIndex: Codable, Sendable {
  var version: Int
  var images: [UUID: ImageRecord]

  init(version: Int = 1, images: [UUID: ImageRecord] = [:]) {
    self.version = version
    self.images = images
  }

  static var empty: ImageIndex { ImageIndex(version: 1, images: [:]) }
}

private struct ImageIndexVersionProbe: Decodable {
  let version: Int
}

struct PreparedImageReferenceCommit: Sendable {
  fileprivate let token: UUID
  let stored: ImageRecord
  let replaced: ImageRecord?
}

/// Errors from image store operations
enum ImageStoreError: Error, LocalizedError {
  case imageNotFound(UUID)
  case imageAlreadyExists(UUID)
  case referenceChanged(reference: String, expected: UUID?, actual: UUID?)
  case unsupportedIndexVersion(path: String, actual: Int, expected: Int)
  case invalidData(String)
  case encodingFailed(Error)
  case writeFailed(path: String, error: Error)
  case directoryCreationFailed(String)
  case preparedCommitInProgress
  case preparedCommitNotFound(UUID)
  case preparedCommitFinalizeFailed(path: String, error: String)

  var errorDescription: String? {
    switch self {
    case .imageNotFound(let id): "Image not found with ID: \(id.uuidString)"
    case .imageAlreadyExists(let id): "Image already exists with ID: \(id.uuidString)"
    case .referenceChanged(let reference, let expected, let actual):
      "Image reference \(reference) changed while the operation was running (expected "
        + (expected?.uuidString ?? "none") + ", found " + (actual?.uuidString ?? "none") + ")"
    case .unsupportedIndexVersion(let path, let actual, let expected):
      "Unsupported image index version \(actual) at \(path), expected \(expected)"
    case .invalidData(let reason): "Invalid image index: \(reason)"
    case .encodingFailed(let error): "Failed to encode image index: \(error.localizedDescription)"
    case .writeFailed(let path, let error):
      "Failed to write image index at \(path): \(error.localizedDescription)"
    case .directoryCreationFailed(let path): "Failed to create directory: \(path)"
    case .preparedCommitInProgress:
      "Another prepared image index commit is already in progress"
    case .preparedCommitNotFound(let token):
      "Prepared image index commit not found: \(token.uuidString)"
    case .preparedCommitFinalizeFailed(let path, let error):
      "Failed to finalize prepared image index at \(path): \(error)"
    }
  }
}

/// Manages persistence of the local image index to disk
actor ImageStore {
  private struct PendingReferenceCommit {
    let prepared: PreparedImageReferenceCommit
    let candidate: ImageIndex
    let candidateData: Data
    let stagedPath: String
  }

  private static let currentIndexVersion = 1
  private static let maximumIndexSize = 16 * 1024 * 1024

  private let storagePath: String
  private let indexPath: String
  private let durablePostPublishSync: DurableMarkerStore.PostPublishSync?
  private let fileManager = FileManager.default
  private var index: ImageIndex
  private var isLoaded = false
  private var loadFailure: Error?
  private var pendingReferenceCommit: PendingReferenceCommit?
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  /// - Parameters:
  ///   - storagePath: Directory where image bundles are stored. Created on first use.
  ///   - indexPath: Path to `images.json`. Defaults to `storagePath/images.json` when nil.
  init(
    storagePath: String,
    indexPath: String? = nil,
    durablePostPublishSync: DurableMarkerStore.PostPublishSync? = nil
  ) {
    self.storagePath = storagePath
    self.indexPath = indexPath ?? "\(storagePath)/images.json"
    self.durablePostPublishSync = durablePostPublishSync

    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601

    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    index = .empty
  }

  // MARK: - Lazy Loading

  private func ensureLoaded() throws {
    if !isLoaded {
      isLoaded = true

      do {
        try createDirectoriesIfNeeded()
        index = try loadFromDisk()
      } catch {
        loadFailure = error
        logWarning(
          "Failed to load image index from \(indexPath): \(error). Refusing access until the file is repaired.",
          category: "ImageStore"
        )
      }
    }

    if let loadFailure {
      throw ImageStoreError.invalidData(
        "Failed to load existing index at \(indexPath): \(loadFailure.localizedDescription). "
          + "Refusing to treat it as an empty store"
      )
    }
  }

  // MARK: - Public API

  func addImage(_ record: ImageRecord) throws {
    try ensureLoadedForMutation()
    guard index.images[record.id] == nil else { throw ImageStoreError.imageAlreadyExists(record.id) }
    var candidate = index
    candidate.images[record.id] = record
    try commit(candidate)
  }

  /// Commits a record only if the reference still points at the record observed before async work began.
  /// Matching digests are reused unless `repairMatchingDigest` requests replacement of invalid local data.
  func commitImageForReference(
    _ record: ImageRecord,
    replacing expectedRecordId: UUID?,
    repairMatchingDigest: Bool = false
  ) throws -> (stored: ImageRecord, replaced: ImageRecord?) {
    try ensureLoadedForMutation()
    let existing = index.images.values.first { $0.reference == record.reference }
    guard existing?.id == expectedRecordId else {
      throw ImageStoreError.referenceChanged(
        reference: record.reference,
        expected: expectedRecordId,
        actual: existing?.id
      )
    }

    if let existing, existing.digest != nil, existing.digest == record.digest, !repairMatchingDigest {
      return (existing, nil)
    }

    var candidate = index
    if let existing {
      candidate.images.removeValue(forKey: existing.id)
    }
    guard candidate.images[record.id] == nil else { throw ImageStoreError.imageAlreadyExists(record.id) }
    candidate.images[record.id] = record
    try commit(candidate)
    return (record, existing)
  }

  /// Prepares a complete, durable index replacement without making it visible to readers.
  /// The caller must serialize all other index mutations until it finalizes or aborts this commit.
  func prepareImageForReference(
    _ record: ImageRecord,
    replacing expectedRecordId: UUID?,
    repairMatchingDigest: Bool = false
  ) throws -> PreparedImageReferenceCommit {
    try ensureLoadedForMutation()
    guard pendingReferenceCommit == nil else {
      throw ImageStoreError.preparedCommitInProgress
    }

    let existing = index.images.values.first { $0.reference == record.reference }
    guard existing?.id == expectedRecordId else {
      throw ImageStoreError.referenceChanged(
        reference: record.reference,
        expected: expectedRecordId,
        actual: existing?.id
      )
    }

    let matchingRecord: ImageRecord? = if let existing,
                                          existing.digest != nil,
                                          existing.digest == record.digest,
                                          !repairMatchingDigest
    {
      existing
    } else {
      nil
    }

    var candidate = index
    if matchingRecord == nil {
      if let existing {
        candidate.images.removeValue(forKey: existing.id)
      }
      guard candidate.images[record.id] == nil else {
        throw ImageStoreError.imageAlreadyExists(record.id)
      }
      candidate.images[record.id] = record
    }
    try validate(candidate)

    let token = UUID()
    let stagedPath = indexPath + ".prepared-\(token.uuidString)"
    let candidateData = try encodedIndexData(candidate)
    try writePreparedIndex(candidateData, to: stagedPath)
    let prepared = PreparedImageReferenceCommit(
      token: token,
      stored: matchingRecord ?? record,
      replaced: matchingRecord == nil ? existing : nil
    )
    pendingReferenceCommit = PendingReferenceCommit(
      prepared: prepared,
      candidate: candidate,
      candidateData: candidateData,
      stagedPath: stagedPath
    )
    return prepared
  }

  func finalizePreparedImageCommit(
    _ prepared: PreparedImageReferenceCommit
  ) throws -> (stored: ImageRecord, replaced: ImageRecord?) {
    try ensureLoadedForMutation()
    guard let pending = pendingReferenceCommit, pending.prepared.token == prepared.token else {
      throw ImageStoreError.preparedCommitNotFound(prepared.token)
    }

    do {
      try publishIndexData(pending.candidateData, to: indexPath)
    } catch {
      throw ImageStoreError.preparedCommitFinalizeFailed(path: indexPath, error: error.localizedDescription)
    }
    index = pending.candidate
    pendingReferenceCommit = nil
    do {
      _ = try DurableMarkerStore.removeIfPresent(
        at: pending.stagedPath,
        postPublishSync: durablePostPublishSync
      )
    } catch {
      logWarning(
        "Finalized image index but could not remove prepared file at \(pending.stagedPath): "
          + error.localizedDescription,
        category: "ImageStore"
      )
    }
    return (pending.prepared.stored, pending.prepared.replaced)
  }

  func abortPreparedImageCommit(_ prepared: PreparedImageReferenceCommit) {
    guard let pending = pendingReferenceCommit, pending.prepared.token == prepared.token else { return }
    _ = try? DurableMarkerStore.removeIfPresent(
      at: pending.stagedPath,
      postPublishSync: durablePostPublishSync
    )
    pendingReferenceCommit = nil
  }

  /// Returns one authoritative snapshot after verifying both the ID membership and reference mapping.
  func getImageForExport(id: UUID, expectedReference: String? = nil) throws -> ImageRecord? {
    try ensureLoaded()
    guard let record = index.images[id] else { return nil }
    if let expectedReference, record.reference != expectedReference { return nil }
    guard index.images.values.first(where: { $0.reference == record.reference })?.id == id else {
      return nil
    }
    return record
  }

  func updateImage(_ record: ImageRecord) throws {
    try ensureLoadedForMutation()
    guard index.images[record.id] != nil else { throw ImageStoreError.imageNotFound(record.id) }
    var candidate = index
    candidate.images[record.id] = record
    try commit(candidate)
  }

  func removeImage(id: UUID) throws {
    try ensureLoadedForMutation()
    guard index.images[id] != nil else { throw ImageStoreError.imageNotFound(id) }
    var candidate = index
    candidate.images.removeValue(forKey: id)
    try commit(candidate)
  }

  func getImage(id: UUID) throws -> ImageRecord? {
    try ensureLoaded()
    return index.images[id]
  }

  func getImageByReference(_ reference: String) throws -> ImageRecord? {
    try ensureLoaded()
    return index.images.values.first { $0.reference == reference }
  }

  func listImages() throws -> [ImageRecord] {
    try ensureLoaded()
    return Array(index.images.values).sorted { lhs, rhs in
      let lhsDate = Self.latestActivityDate(for: lhs)
      let rhsDate = Self.latestActivityDate(for: rhs)
      if lhsDate != rhsDate { return lhsDate > rhsDate }
      return lhs.id.uuidString < rhs.id.uuidString
    }
  }

  /// Returns an authoritative snapshot for destructive maintenance work.
  /// Unlike the read APIs, this refuses to represent an unreadable index as an empty store.
  func maintenanceSnapshot() throws -> [ImageRecord] {
    try ensureLoadedForMutation()
    return Array(index.images.values)
  }

  func imageExistsByReference(_ reference: String) throws -> Bool {
    try ensureLoaded()
    return index.images.values.contains { $0.reference == reference }
  }

  func count() throws -> Int {
    try ensureLoaded()
    return index.images.count
  }

  // MARK: - Private Methods

  private func loadFromDisk() throws -> ImageIndex {
    try discardAbandonedPreparedReferenceCommitIfNeeded()
    let backupPath = indexPath + ".bak"
    guard Self.filesystemEntryExists(at: indexPath) else {
      if Self.filesystemEntryExists(at: backupPath) {
        let recovered = try decodeIndex(at: backupPath)
        try restorePrimaryIndex(from: backupPath)
        logWarning("Recovered missing image index from backup at \(backupPath)", category: "ImageStore")
        return recovered
      }
      if try storageContainsManagedBundles() {
        throw ImageStoreError.invalidData(
          "Image index is missing while managed image bundles still exist in \(storagePath)"
        )
      }
      let empty = ImageIndex.empty
      try writeToDisk(empty)
      return empty
    }

    do {
      return try decodeIndex(at: indexPath)
    } catch let error as ImageStoreError {
      if case .unsupportedIndexVersion = error {
        throw error
      }
      return try recoverIndexFromBackup(after: error, backupPath: backupPath)
    } catch {
      return try recoverIndexFromBackup(after: error, backupPath: backupPath)
    }
  }

  private func recoverIndexFromBackup(after primaryError: Error, backupPath: String) throws -> ImageIndex {
    guard fileManager.fileExists(atPath: backupPath) else { throw primaryError }

    do {
      let recovered = try decodeIndex(at: backupPath)
      try restorePrimaryIndex(from: backupPath)
      logWarning("Recovered image index from backup at \(backupPath)", category: "ImageStore")
      return recovered
    } catch {
      throw ImageStoreError.invalidData(
        "Failed to load image index and backup. Primary: \(primaryError.localizedDescription). "
          + "Backup: \(error.localizedDescription)"
      )
    }
  }

  private func ensureLoadedForMutation() throws {
    try ensureLoaded()
  }

  private func discardAbandonedPreparedReferenceCommitIfNeeded() throws {
    let directory = (indexPath as NSString).deletingLastPathComponent
    let indexName = (indexPath as NSString).lastPathComponent
    let prefix = indexName + ".prepared-"
    let preparedPaths = try fileManager.contentsOfDirectory(atPath: directory)
      .filter { name in
        guard name.hasPrefix(prefix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
      }
      .sorted()
      .map { "\(directory)/\($0)" }

    guard preparedPaths.count <= 1 else {
      throw ImageStoreError.invalidData(
        "Found multiple prepared image index commits at \(directory)"
      )
    }
    guard let preparedPath = preparedPaths.first else { return }

    var status = stat()
    guard preparedPath.withCString({ Darwin.lstat($0, &status) }) == 0,
          status.st_mode & S_IFMT == S_IFREG,
          status.st_size >= 0,
          UInt64(status.st_size) <= UInt64(Self.maximumIndexSize) else
    {
      throw ImageStoreError.invalidData(
        "Prepared image index commit at \(preparedPath) must be a bounded regular file"
      )
    }
    do {
      _ = try DurableMarkerStore.removeIfPresent(
        at: preparedPath,
        postPublishSync: durablePostPublishSync
      )
    } catch {
      throw ImageStoreError.writeFailed(path: preparedPath, error: error)
    }
    logWarning(
      "Discarded abandoned prepared image index commit at \(preparedPath)",
      category: "ImageStore"
    )
  }

  private func decodeIndex(at path: String) throws -> ImageIndex {
    do {
      let data = try boundedIndexData(at: path)
      let version = try decoder.decode(ImageIndexVersionProbe.self, from: data).version
      guard version == Self.currentIndexVersion else {
        throw ImageStoreError.unsupportedIndexVersion(
          path: path,
          actual: version,
          expected: Self.currentIndexVersion
        )
      }
      let decoded = try decoder.decode(ImageIndex.self, from: data)
      try validate(decoded)
      return decoded
    } catch let error as ImageStoreError {
      throw error
    } catch let error as DecodingError {
      throw ImageStoreError.invalidData(
        incompatibleIndexRecoveryMessage(
          reason: "index schema is incompatible or incomplete: \(error.localizedDescription)"
        )
      )
    } catch {
      throw ImageStoreError.invalidData("Failed to read image index at \(path): \(error.localizedDescription)")
    }
  }

  private func commit(_ candidate: ImageIndex) throws {
    try validate(candidate)
    try writeToDisk(candidate)
    index = candidate
  }

  private func writeToDisk(_ candidate: ImageIndex) throws {
    let candidateData = try encodedIndexData(candidate)
    do {
      let backupPath = indexPath + ".bak"
      try validateWritableFileTarget(at: indexPath)
      try validateWritableFileTarget(at: backupPath)
      if fileManager.fileExists(atPath: indexPath) {
        let currentData = try encodedIndexData(index)
        try publishIndexData(currentData, to: backupPath)
      }

      try publishIndexData(candidateData, to: indexPath)
    } catch let error as ImageStoreError {
      throw error
    } catch {
      throw ImageStoreError.writeFailed(path: indexPath, error: error)
    }
  }

  private func writePreparedIndex(_ candidateData: Data, to stagedPath: String) throws {
    do {
      let backupPath = indexPath + ".bak"
      try validateWritableFileTarget(at: indexPath)
      try validateWritableFileTarget(at: backupPath)
      try validateWritableFileTarget(at: stagedPath)
      if fileManager.fileExists(atPath: indexPath) {
        let currentData = try encodedIndexData(index)
        try publishIndexData(currentData, to: backupPath)
      }
      try publishIndexData(candidateData, to: stagedPath)
    } catch let error as ImageStoreError {
      throw error
    } catch {
      _ = try? DurableMarkerStore.removeIfPresent(
        at: stagedPath,
        postPublishSync: durablePostPublishSync
      )
      throw ImageStoreError.writeFailed(path: stagedPath, error: error)
    }
  }

  private func encodedIndexData(_ value: ImageIndex) throws -> Data {
    let data: Data
    do {
      data = try encoder.encode(value)
    } catch {
      throw ImageStoreError.encodingFailed(error)
    }
    guard data.count <= Self.maximumIndexSize else {
      throw ImageStoreError.invalidData("Encoded image index exceeds the 16MB limit")
    }
    return data
  }

  private func restorePrimaryIndex(from backupPath: String) throws {
    let data = try boundedIndexData(at: backupPath)
    try publishIndexData(data, to: indexPath)
  }

  private func publishIndexData(_ data: Data, to path: String) throws {
    do {
      _ = try DurableMarkerStore.writeDataAtomically(
        data,
        to: path,
        maximumSize: Self.maximumIndexSize,
        permissions: 0o600,
        postPublishSync: durablePostPublishSync
      )
    } catch let error as ImageStoreError {
      throw error
    } catch {
      throw ImageStoreError.writeFailed(path: path, error: error)
    }
  }

  private func boundedIndexData(at path: String) throws -> Data {
    let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw ImageStoreError.invalidData("Failed to open image index at \(path): \(Self.posixMessage())")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
      throw ImageStoreError.invalidData("Failed to inspect image index at \(path): \(Self.posixMessage())")
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw ImageStoreError.invalidData("Image index at \(path) must be a regular file")
    }
    guard status.st_size >= 0, UInt64(status.st_size) <= UInt64(Self.maximumIndexSize) else {
      throw ImageStoreError.invalidData("Image index at \(path) exceeds the 16MB limit")
    }
    let data = try handle.read(upToCount: Self.maximumIndexSize + 1) ?? Data()
    guard data.count <= Self.maximumIndexSize else {
      throw ImageStoreError.invalidData("Image index at \(path) exceeds the 16MB limit")
    }
    return data
  }

  private func validateWritableFileTarget(at path: String) throws {
    var status = stat()
    let result = path.withCString { Darwin.lstat($0, &status) }
    if result == 0 {
      guard status.st_mode & S_IFMT == S_IFREG else {
        throw ImageStoreError.invalidData("Image index target at \(path) must be a regular file")
      }
      return
    }
    guard errno == ENOENT else {
      throw ImageStoreError.invalidData(
        "Failed to inspect image index target at \(path): \(Self.posixMessage())"
      )
    }
  }

  private static func posixMessage(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
  }

  private static func filesystemEntryExists(at path: String) -> Bool {
    var status = stat()
    return path.withCString { Darwin.lstat($0, &status) } == 0
  }

  private func validate(_ decoded: ImageIndex) throws {
    var references: Set<String> = []
    for (key, record) in decoded.images {
      guard key == record.id else {
        throw ImageStoreError.invalidData(
          "Image dictionary key \(key.uuidString) does not match record ID \(record.id.uuidString)"
        )
      }
      guard record.reference.isEmpty == false, references.insert(record.reference).inserted else {
        throw ImageStoreError.invalidData("Image references must be nonempty and unique")
      }
      if let digest = record.digest {
        guard digest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil else {
          throw ImageStoreError.invalidData("Image \(record.id.uuidString) has invalid digest \(digest)")
        }
      }
      if let resources = record.resources, resources.validate() == false {
        throw ImageStoreError.invalidData("Image \(record.id.uuidString) has invalid VM resources")
      }
      guard record.formatVersion == VMImagePackager.currentFormatVersion else {
        throw ImageStoreError.invalidData(
          incompatibleIndexRecoveryMessage(
            reason: "image \(record.id.uuidString) uses unsupported format version \(record.formatVersion)"
          )
        )
      }

      guard record.metadata["ownsLocalPath"] == "true" else {
        throw ImageStoreError.invalidData(
          incompatibleIndexRecoveryMessage(
            reason: "image \(record.id.uuidString) does not explicitly own its local bundle"
          )
        )
      }
      let storageURL = URL(fileURLWithPath: storagePath, isDirectory: true)
        .standardizedFileURL
        .resolvingSymlinksInPath()
      let localURL = URL(fileURLWithPath: record.localPath, isDirectory: true).standardizedFileURL
      let resolvedLocalURL = localURL.resolvingSymlinksInPath()
      guard resolvedLocalURL.deletingLastPathComponent() == storageURL,
            resolvedLocalURL.lastPathComponent == "\(record.id.uuidString).bundle" else
      {
        throw ImageStoreError.invalidData(
          "Image \(record.id.uuidString) has unmanaged local path \(record.localPath)"
        )
      }
    }
  }

  private func incompatibleIndexRecoveryMessage(reason: String) -> String {
    "Incompatible local image index at \(indexPath): \(reason). Pre-1.0 image index migration is not supported. "
      + "Stop the agent, remove the incompatible index, its .bak backup, and managed image bundles under "
      + "\(storagePath), then pull or push the images again"
  }

  private func createDirectoriesIfNeeded() throws {
    try createDirectoryIfNeeded(at: storagePath, permissions: 0o700)
    try createDirectoryIfNeeded(at: (indexPath as NSString).deletingLastPathComponent, permissions: nil)
  }

  private func createDirectoryIfNeeded(at path: String, permissions: Int?) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else { throw ImageStoreError.directoryCreationFailed(path) }
    } else {
      do {
        try fileManager.createDirectory(atPath: path, withIntermediateDirectories: true)
      } catch {
        throw ImageStoreError.directoryCreationFailed(path)
      }
    }
    if let permissions {
      do {
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
      } catch {
        throw ImageStoreError.directoryCreationFailed(path)
      }
    }
  }

  private func storageContainsManagedBundles() throws -> Bool {
    try fileManager.contentsOfDirectory(atPath: storagePath).contains { name in
      guard name.hasSuffix(".bundle") else { return false }
      return UUID(uuidString: String(name.dropLast(".bundle".count))) != nil
    }
  }

  private static func latestActivityDate(for record: ImageRecord) -> Date {
    switch (record.pulledAt, record.pushedAt) {
    case (let pulled?, let pushed?): max(pulled, pushed)
    case (let pulled?, nil): pulled
    case (nil, let pushed?): pushed
    case (nil, nil): .distantPast
    }
  }
}
