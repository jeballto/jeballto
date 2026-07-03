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
  var metadata: [String: String]

  init(
    id: UUID = UUID(),
    reference: String,
    digest: String? = nil,
    localPath: String,
    size: UInt64? = nil,
    pulledAt: Date? = nil,
    pushedAt: Date? = nil,
    metadata: [String: String] = [:]
  ) {
    self.id = id
    self.reference = reference
    self.digest = digest
    self.localPath = localPath
    self.size = size
    self.pulledAt = pulledAt
    self.pushedAt = pushedAt
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

/// Errors from image store operations
enum ImageStoreError: Error, LocalizedError {
  case imageNotFound(UUID)
  case imageAlreadyExists(UUID)
  case encodingFailed(Error)
  case decodingFailed(Error)
  case directoryCreationFailed(String)

  var errorDescription: String? {
    switch self {
    case .imageNotFound(let id): "Image not found with ID: \(id.uuidString)"
    case .imageAlreadyExists(let id): "Image already exists with ID: \(id.uuidString)"
    case .encodingFailed(let error): "Failed to encode image index: \(error.localizedDescription)"
    case .decodingFailed(let error): "Failed to decode image index: \(error.localizedDescription)"
    case .directoryCreationFailed(let path): "Failed to create directory: \(path)"
    }
  }
}

/// Manages persistence of the local image index to disk
actor ImageStore {
  private let storagePath: String
  private let indexPath: String
  private let fileManager = FileManager.default
  private var index: ImageIndex
  private var isLoaded = false
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  /// - Parameters:
  ///   - storagePath: Directory where image bundles are stored. Created on first use.
  ///   - indexPath: Path to `images.json`. Defaults to `storagePath/images.json` when nil.
  init(storagePath: String, indexPath: String? = nil) {
    self.storagePath = storagePath
    self.indexPath = indexPath ?? "\(storagePath)/images.json"

    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601

    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    index = .empty
  }

  // MARK: - Lazy Loading

  private func ensureLoaded() {
    guard !isLoaded else { return }
    isLoaded = true

    do {
      let loaded = try loadFromDisk()
      index = loaded
    } catch {
      logWarning(
        "Failed to load image index from \(indexPath): \(error). Starting with empty index.",
        category: "ImageStore"
      )
    }

    do {
      try createStorageDirectoryIfNeeded()
    } catch {
      logError("Failed to create image storage directory: \(error)", category: "ImageStore")
    }
  }

  // MARK: - Public API

  func addImage(_ record: ImageRecord) throws {
    ensureLoaded()
    guard index.images[record.id] == nil else { throw ImageStoreError.imageAlreadyExists(record.id) }
    index.images[record.id] = record
    try saveToDisk()
  }

  func addImageIfReferenceAbsent(_ record: ImageRecord) throws -> ImageRecord {
    ensureLoaded()
    if let existing = index.images.values.first(where: { $0.reference == record.reference }) {
      return existing
    }
    guard index.images[record.id] == nil else { throw ImageStoreError.imageAlreadyExists(record.id) }
    index.images[record.id] = record
    try saveToDisk()
    return record
  }

  func updateImage(_ record: ImageRecord) throws {
    ensureLoaded()
    guard index.images[record.id] != nil else { throw ImageStoreError.imageNotFound(record.id) }
    index.images[record.id] = record
    try saveToDisk()
  }

  func removeImage(id: UUID) throws {
    ensureLoaded()
    guard index.images[id] != nil else { throw ImageStoreError.imageNotFound(id) }
    index.images.removeValue(forKey: id)
    try saveToDisk()
  }

  func getImage(id: UUID) -> ImageRecord? {
    ensureLoaded()
    return index.images[id]
  }

  func getImageByReference(_ reference: String) -> ImageRecord? {
    ensureLoaded()
    return index.images.values.first { $0.reference == reference }
  }

  func listImages() -> [ImageRecord] {
    ensureLoaded()
    return Array(index.images.values).sorted { ($0.pulledAt ?? .distantPast) > ($1.pulledAt ?? .distantPast) }
  }

  func imageExistsByReference(_ reference: String) -> Bool {
    ensureLoaded()
    return index.images.values.contains { $0.reference == reference }
  }

  func count() -> Int {
    ensureLoaded()
    return index.images.count
  }

  // MARK: - Private Methods

  private func loadFromDisk() throws -> ImageIndex {
    guard fileManager.fileExists(atPath: indexPath) else {
      return .empty
    }

    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: indexPath))
      return try decoder.decode(ImageIndex.self, from: data)
    } catch let error as DecodingError {
      throw ImageStoreError.decodingFailed(error)
    }
  }

  private func saveToDisk() throws {
    do {
      if fileManager.fileExists(atPath: indexPath) {
        let backupPath = indexPath + ".bak"
        try? fileManager.removeItem(atPath: backupPath)
        try? fileManager.copyItem(atPath: indexPath, toPath: backupPath)
      }

      let data = try encoder.encode(index)
      try data.write(to: URL(fileURLWithPath: indexPath), options: .atomic)
    } catch {
      throw ImageStoreError.encodingFailed(error)
    }
  }

  private func createStorageDirectoryIfNeeded() throws {
    var isDirectory: ObjCBool = false
    if !fileManager.fileExists(atPath: storagePath, isDirectory: &isDirectory) {
      do {
        try fileManager.createDirectory(atPath: storagePath, withIntermediateDirectories: true)
      } catch {
        throw ImageStoreError.directoryCreationFailed(storagePath)
      }
    }
  }
}
