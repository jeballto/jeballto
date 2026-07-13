import CryptoKit
import Darwin
import Foundation

// swiftlint:disable file_length

let jeballtoImageArtifactType = "application/vnd.jeballto.vm.bundle"
let jeballtoImageConfigMediaType = "application/vnd.jeballto.vm.bundle.config+json"
let jeballtoImageChunkMediaType = "application/vnd.jeballto.vm.bundle.chunk+zstd"
let requiredVMImageBundleFileNames = ["Disk.img", "AuxiliaryStorage", "HardwareModel", "MachineIdentifier"]

struct VMImageLayer: Sendable {
  let absolutePath: String
  let relativePath: String
  let mediaType: String
  let digest: String
  let size: UInt64
}

struct VMImagePackage: Sendable {
  let stagingDirectory: String
  let configPath: String
  let layers: [VMImageLayer]
  let metadata: [String: String]
}

/// Wire schema for Jeballto VM Bundle Format v1.
struct VMImageBundleConfig: Codable, Equatable, Sendable {
  struct Compression: Codable, Equatable, Sendable {
    let algorithm: String
    let level: Int
  }

  let formatVersion: Int
  let artifactType: String
  let architecture: String
  let resources: VMResources
  let chunkSize: UInt64
  let compression: Compression
  let files: [VMImagePackedFile]

  private enum CodingKeys: String, CodingKey {
    case formatVersion
    case artifactType
    case architecture
    case resources
    case chunkSize
    case compression
    case files
  }

  init(
    formatVersion: Int = VMImagePackager.currentFormatVersion,
    artifactType: String,
    architecture: String = "arm64",
    resources: VMResources = .default,
    chunkSize: UInt64,
    compression: Compression,
    files: [VMImagePackedFile]
  ) {
    self.formatVersion = formatVersion
    self.artifactType = artifactType
    self.architecture = architecture
    self.resources = resources
    self.chunkSize = chunkSize
    self.compression = compression
    self.files = files
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard container.contains(.formatVersion) else {
      throw VMImagePackagerError.unsupportedFormat(
        "unversioned images created before 1.0.0 are not supported; "
          + "re-push the VM using \(VMImagePackager.currentFormatDisplayName)"
      )
    }

    let decodedFormatVersion = try container.decode(Int.self, forKey: .formatVersion)
    guard decodedFormatVersion == VMImagePackager.currentFormatVersion else {
      throw VMImagePackagerError.unsupportedFormat(
        "version \(decodedFormatVersion) is not supported; this agent supports "
          + VMImagePackager.currentFormatDisplayName
      )
    }

    formatVersion = decodedFormatVersion
    artifactType = try container.decode(String.self, forKey: .artifactType)
    architecture = try container.decode(String.self, forKey: .architecture)
    resources = try container.decode(VMResources.self, forKey: .resources)
    chunkSize = try container.decode(UInt64.self, forKey: .chunkSize)
    compression = try container.decode(Compression.self, forKey: .compression)
    files = try container.decode([VMImagePackedFile].self, forKey: .files)
  }
}

struct VMImagePackedFile: Codable, Equatable, Sendable {
  let path: String
  let size: UInt64
  let chunks: [VMImagePackedChunk]
}

struct VMImagePackedChunk: Codable, Equatable, Sendable {
  let index: Int
  let offset: UInt64
  let uncompressedSize: UInt64
  let uncompressedDigest: String
  let compressedSize: UInt64?
  let compressedDigest: String?
  let layerPath: String?
  let zero: Bool
}

private struct PackedChunkResult: Sendable {
  let chunk: VMImagePackedChunk
  let layer: VMImageLayer?
}

private struct PackChunkRequest: Sendable {
  let index: Int
  let absolutePath: String
  let relativePath: String
  let fileSize: UInt64
  let chunkSize: UInt64
  let chunksDirectory: String
  let compressionLevel: Int
  let cachedChunk: VMImagePackedChunk?
  let zstdClient: ZstdClient
  let compressionLimiter: ImageConcurrencyLimiter?
  let timeout: TimeInterval?
}

private struct UnpackChunkRequest: Sendable {
  let packedFile: VMImagePackedFile
  let chunk: VMImagePackedChunk
  let layerDirectory: String
  let outputPath: String
  let fetchLayer: VMImageLayerFetcher?
  let zstdClient: ZstdClient
  let decompressionLimiter: ImageConcurrencyLimiter
  let diskWriteLimiter: ImageConcurrencyLimiter
  let timeout: TimeInterval?
}

typealias VMImageLayerFetcher = @Sendable (
  _ packedFile: VMImagePackedFile,
  _ chunk: VMImagePackedChunk,
  _ destinationPath: String
) async throws -> Void

struct VMImagePackProgressUpdate: Sendable {
  let chunksCompletedDelta: Int?
  let chunksTotal: Int?
  let bytesCompletedDelta: UInt64?
  let bytesTotal: UInt64?
}

typealias VMImagePackProgressSink = @Sendable (VMImagePackProgressUpdate) async -> Void

enum VMImagePackagerError: Error, LocalizedError {
  case invalidBundle(String)
  case invalidConfig(String)
  case invalidLayout(String)
  case digestMismatch(String)
  case unsupportedFormat(String)
  case unsupportedCompression(String)

  var errorDescription: String? {
    switch self {
    case .invalidBundle(let message): "Invalid VM image bundle: \(message)"
    case .invalidConfig(let message): "Invalid VM image config: \(message)"
    case .invalidLayout(let message): "Invalid VM image layout: \(message)"
    case .digestMismatch(let message): "VM image digest mismatch: \(message)"
    case .unsupportedFormat(let message): "Unsupported VM image format: \(message)"
    case .unsupportedCompression(let message): "Unsupported VM image compression: \(message)"
    }
  }
}

private enum VMImageConfigValidator {
  private struct ValidationContext {
    var seenFilePaths: Set<String> = []
    var seenLayerPaths: Set<String> = []
    var totalCompressedSize: UInt64 = 0
  }

  static func validate(_ config: VMImageBundleConfig) throws {
    guard config.files.count <= VMImagePackager.maximumFileCount else {
      throw VMImagePackagerError.invalidConfig("Image config contains too many files")
    }
    var context = ValidationContext()
    var totalSize: UInt64 = 0
    var totalChunks = 0
    for packedFile in config.files {
      let (newTotalSize, sizeOverflow) = totalSize.addingReportingOverflow(packedFile.size)
      guard !sizeOverflow, newTotalSize <= VMImagePackager.maximumUncompressedSize else {
        throw VMImagePackagerError.invalidConfig("Image expands beyond the supported 9TB limit")
      }
      totalSize = newTotalSize
      let (newChunkCount, chunkOverflow) = totalChunks.addingReportingOverflow(packedFile.chunks.count)
      guard !chunkOverflow, newChunkCount <= VMImagePackager.maximumChunkCount else {
        throw VMImagePackagerError.invalidConfig("Image config contains too many chunks")
      }
      totalChunks = newChunkCount
      try validate(packedFile, config: config, context: &context)
    }

    let missingOrEmptyRequiredFiles = requiredVMImageBundleFileNames.filter { requiredPath in
      config.files.first { $0.path == requiredPath }.map { $0.size == 0 } ?? true
    }
    guard missingOrEmptyRequiredFiles.isEmpty else {
      throw VMImagePackagerError.invalidConfig(
        "Required VM bundle files are missing or empty: \(missingOrEmptyRequiredFiles.joined(separator: ", "))"
      )
    }
  }

  static func validateRelativePath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty,
          path.utf8.count <= 1024,
          !path.hasPrefix("/"),
          path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }),
          components.allSatisfy({ component in
            component.isEmpty == false && component != "." && component != ".." && component.utf8.count <= 255
          }) else
    {
      throw VMImagePackagerError.invalidConfig("Unsafe relative path: \(path)")
    }
  }

  private static func validate(
    _ packedFile: VMImagePackedFile,
    config: VMImageBundleConfig,
    context: inout ValidationContext
  ) throws {
    try validateRelativePath(packedFile.path)
    let filePathKey = filesystemCollisionKey(packedFile.path)
    guard context.seenFilePaths.allSatisfy({ existingPath in
      existingPath != filePathKey
        && existingPath.hasPrefix(filePathKey + "/") == false
        && filePathKey.hasPrefix(existingPath + "/") == false
    }) else {
      throw VMImagePackagerError.invalidConfig("Duplicate or colliding file path: \(packedFile.path)")
    }
    context.seenFilePaths.insert(filePathKey)

    let expectedChunkCount = expectedChunkCount(fileSize: packedFile.size, chunkSize: config.chunkSize)
    guard UInt64(packedFile.chunks.count) == expectedChunkCount else {
      throw VMImagePackagerError.invalidConfig(
        "Chunk count mismatch for \(packedFile.path): expected \(expectedChunkCount), "
          + "found \(packedFile.chunks.count)"
      )
    }

    let orderedChunks = packedFile.chunks.sorted { lhs, rhs in
      lhs.index < rhs.index
    }
    for (expectedIndex, chunk) in orderedChunks.enumerated() {
      try validateChunk(
        chunk,
        in: packedFile,
        config: config,
        expectedIndex: expectedIndex,
        context: &context
      )
    }
  }

  private static func expectedChunkCount(fileSize: UInt64, chunkSize: UInt64) -> UInt64 {
    fileSize == 0 ? 1 : ((fileSize - 1) / chunkSize) + 1
  }

  private static func validateChunk(
    _ chunk: VMImagePackedChunk,
    in packedFile: VMImagePackedFile,
    config: VMImageBundleConfig,
    expectedIndex: Int,
    context: inout ValidationContext
  ) throws {
    try validateChunkLayout(chunk, in: packedFile, config: config, expectedIndex: expectedIndex)
    guard isValidSHA256Digest(chunk.uncompressedDigest) else {
      throw VMImagePackagerError.invalidConfig(
        "Invalid uncompressed digest for \(packedFile.path) chunk \(chunk.index)"
      )
    }

    if chunk.zero {
      try validateZeroChunk(chunk, in: packedFile)
      return
    }

    try validateNonzeroChunk(chunk, in: packedFile, context: &context)
  }

  private static func validateChunkLayout(
    _ chunk: VMImagePackedChunk,
    in packedFile: VMImagePackedFile,
    config: VMImageBundleConfig,
    expectedIndex: Int
  ) throws {
    guard chunk.index >= 0 else {
      throw VMImagePackagerError.invalidConfig("Negative chunk index for \(packedFile.path)")
    }
    guard chunk.index == expectedIndex else {
      throw VMImagePackagerError.invalidConfig(
        "Chunk indexes for \(packedFile.path) must be contiguous starting at 0"
      )
    }

    let (expectedOffset, offsetOverflow) = UInt64(expectedIndex)
      .multipliedReportingOverflow(by: config.chunkSize)
    guard !offsetOverflow else {
      throw VMImagePackagerError.invalidConfig(
        "Chunk offset overflow for \(packedFile.path) chunk \(chunk.index)"
      )
    }
    guard chunk.offset == expectedOffset else {
      throw VMImagePackagerError.invalidConfig(
        "Unexpected offset for \(packedFile.path) chunk \(chunk.index): expected \(expectedOffset), "
          + "found \(chunk.offset)"
      )
    }

    let expectedSize = packedFile.size == 0
      ? 0
      : min(config.chunkSize, packedFile.size - expectedOffset)
    guard chunk.uncompressedSize == expectedSize else {
      throw VMImagePackagerError.invalidConfig(
        "Unexpected size for \(packedFile.path) chunk \(chunk.index): expected \(expectedSize), "
          + "found \(chunk.uncompressedSize)"
      )
    }
  }

  private static func validateZeroChunk(_ chunk: VMImagePackedChunk, in packedFile: VMImagePackedFile) throws {
    guard chunk.compressedSize == nil,
          chunk.compressedDigest == nil,
          chunk.layerPath == nil else
    {
      throw VMImagePackagerError.invalidConfig(
        "Zero chunk for \(packedFile.path) chunk \(chunk.index) must not include layer metadata"
      )
    }
    guard chunk.uncompressedDigest == zeroDigest(size: chunk.uncompressedSize) else {
      throw VMImagePackagerError.invalidConfig(
        "Zero chunk for \(packedFile.path) chunk \(chunk.index) has an invalid uncompressed digest"
      )
    }
  }

  private static func validateNonzeroChunk(
    _ chunk: VMImagePackedChunk,
    in packedFile: VMImagePackedFile,
    context: inout ValidationContext
  ) throws {
    guard chunk.uncompressedSize > 0 else {
      throw VMImagePackagerError.invalidConfig(
        "Nonzero chunk for \(packedFile.path) chunk \(chunk.index) is empty"
      )
    }
    guard let compressedSize = chunk.compressedSize, compressedSize > 0 else {
      throw VMImagePackagerError.invalidConfig(
        "Missing compressed size for \(packedFile.path) chunk \(chunk.index)"
      )
    }
    guard compressedSize <= VMImagePackager.maximumCompressedLayerSize else {
      throw VMImagePackagerError.invalidConfig(
        "Compressed size for \(packedFile.path) chunk \(chunk.index) exceeds the 2GB layer limit"
      )
    }
    let (totalCompressedSize, compressedSizeOverflow) = context.totalCompressedSize
      .addingReportingOverflow(compressedSize)
    guard !compressedSizeOverflow, totalCompressedSize <= VMImagePackager.maximumTotalBlobSize else {
      throw VMImagePackagerError.invalidConfig("Image exceeds the supported total compressed size")
    }
    context.totalCompressedSize = totalCompressedSize
    guard let compressedDigest = chunk.compressedDigest, isValidSHA256Digest(compressedDigest) else {
      throw VMImagePackagerError.invalidConfig(
        "Invalid compressed digest for \(packedFile.path) chunk \(chunk.index)"
      )
    }
    guard let layerPath = chunk.layerPath else {
      throw VMImagePackagerError.invalidConfig("Missing layer path for \(packedFile.path) chunk \(chunk.index)")
    }
    try validateRelativePath(layerPath)
    guard layerPath.hasPrefix("chunks/") else {
      throw VMImagePackagerError.invalidConfig("Layer path must be under chunks/: \(layerPath)")
    }
    let layerPathKey = filesystemCollisionKey(layerPath)
    guard context.seenLayerPaths.allSatisfy({ existingPath in
      existingPath != layerPathKey
        && existingPath.hasPrefix(layerPathKey + "/") == false
        && layerPathKey.hasPrefix(existingPath + "/") == false
    }) else {
      throw VMImagePackagerError.invalidConfig("Duplicate or colliding layer path: \(layerPath)")
    }
    context.seenLayerPaths.insert(layerPathKey)
  }

  private static func filesystemCollisionKey(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
  }

  private static func isValidSHA256Digest(_ digest: String) -> Bool {
    let prefix = "sha256:"
    let lowercaseHex = Set("0123456789abcdef")
    guard digest.hasPrefix(prefix), digest.count == prefix.count + 64 else { return false }
    return digest.dropFirst(prefix.count).allSatisfy { character in
      lowercaseHex.contains(character)
    }
  }

  static func zeroDigest(size: UInt64) -> String {
    hexDigest(SHA256.hash(data: Data("jeballto-zero-chunk-v1:\(size)".utf8)))
  }

  private static func hexDigest(_ digest: some Sequence<UInt8>) -> String {
    "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }
}

private struct VMImagePackInventory {
  let files: [(relativePath: String, fileSize: UInt64)]
  let totalChunks: Int
  let totalBytes: UInt64
}

/// Immutable packaging configuration. FileManager operations are independent and the mutable
/// compression work is isolated inside ZstdClient process invocations.
struct VMImagePackager: @unchecked Sendable {
  static let formatName = "Jeballto VM Bundle Format"
  static let currentFormatVersion = 1
  static var currentFormatDisplayName: String { "\(formatName) v\(currentFormatVersion)" }
  static let maxConfigSize: UInt64 = 4 * 1024 * 1024
  static let maximumFileCount = 64
  static let maximumChunkCount = 65536
  static let maximumCompressedLayerSize: UInt64 = 2 * 1024 * 1024 * 1024
  static let maximumUncompressedSize: UInt64 = 9 * 1024 * 1024 * 1024 * 1024
  static let maximumTotalBlobSize: UInt64 = 9 * 1024 * 1024 * 1024 * 1024
  static let minimumChunkSize: UInt64 = 1024 * 1024
  static let maximumChunkSize: UInt64 = 1024 * 1024 * 1024
  static let defaultChunkSize: UInt64 = 256 * 1024 * 1024
  static let defaultCompressionLevel = 3

  static func automaticParallelChunkLimit(
    activeProcessorCount: Int = ProcessInfo.processInfo
      .activeProcessorCount
  ) -> Int {
    max(1, min(4, activeProcessorCount / 2))
  }

  private let zstdClient: ZstdClient
  private let chunkSize: UInt64
  private let compressionLevel: Int
  private let maxParallelChunks: Int
  private let maxParallelUnpackChunks: Int?
  private let maxParallelDecompressions: Int?
  private let maxParallelDiskWrites: Int?
  private let compressionLimiter: ImageConcurrencyLimiter?
  private let decompressionLimiter: ImageConcurrencyLimiter?
  private let diskWriteLimiter: ImageConcurrencyLimiter?
  private let fileManager: FileManager

  init(
    zstdClient: ZstdClient,
    chunkSize: UInt64 = Self.defaultChunkSize,
    compressionLevel: Int = Self.defaultCompressionLevel,
    maxParallelChunks: Int = 0,
    maxParallelUnpackChunks: Int? = nil,
    maxParallelDecompressions: Int? = nil,
    maxParallelDiskWrites: Int? = nil,
    compressionLimiter: ImageConcurrencyLimiter? = nil,
    decompressionLimiter: ImageConcurrencyLimiter? = nil,
    diskWriteLimiter: ImageConcurrencyLimiter? = nil,
    fileManager: FileManager = .default
  ) {
    self.zstdClient = zstdClient
    self.chunkSize = chunkSize
    self.compressionLevel = compressionLevel
    self.maxParallelChunks = maxParallelChunks
    self.maxParallelUnpackChunks = maxParallelUnpackChunks
    self.maxParallelDecompressions = maxParallelDecompressions
    self.maxParallelDiskWrites = maxParallelDiskWrites
    self.compressionLimiter = compressionLimiter
    self.decompressionLimiter = decompressionLimiter
    self.diskWriteLimiter = diskWriteLimiter
    self.fileManager = fileManager
  }
}

extension VMImagePackager {
  func packBundle(
    bundlePath: String,
    stagingRoot: String,
    resources: VMResources = .default,
    timeout: TimeInterval? = nil,
    progressSink: VMImagePackProgressSink? = nil
  ) async throws -> VMImagePackage {
    let stagingDirectory = "\(stagingRoot)/vm-image-\(UUID().uuidString)"
    return try await packBundle(
      bundlePath: bundlePath,
      stagingDirectory: stagingDirectory,
      removeStagingDirectoryOnFailure: true,
      resources: resources,
      timeout: timeout,
      progressSink: progressSink
    )
  }

  func packBundle(
    bundlePath: String,
    stagingDirectory: String,
    resources: VMResources = .default,
    timeout: TimeInterval? = nil,
    progressSink: VMImagePackProgressSink? = nil
  ) async throws -> VMImagePackage {
    try await packBundle(
      bundlePath: bundlePath,
      stagingDirectory: stagingDirectory,
      removeStagingDirectoryOnFailure: false,
      resources: resources,
      timeout: timeout,
      progressSink: progressSink
    )
  }

  func sourceFingerprint(bundlePath: String, resources: VMResources = .default) throws -> String {
    guard (Self.minimumChunkSize ... Self.maximumChunkSize).contains(chunkSize) else {
      throw VMImagePackagerError.invalidConfig("Chunk size must be between 1MB and 1GB")
    }
    guard resources.validate() else {
      throw VMImagePackagerError.invalidConfig("Image resources are outside supported bounds")
    }

    var hasher = SHA256()
    func append(_ value: String) {
      hasher.update(data: Data(value.utf8))
      hasher.update(data: Data([0]))
    }

    append("artifactType=\(jeballtoImageArtifactType)")
    append("chunkSize=\(chunkSize)")
    append("compression=zstd")
    append("compressionLevel=\(compressionLevel)")
    append("cpuCount=\(resources.cpuCount)")
    append("memorySize=\(resources.memorySize)")
    append("diskSize=\(resources.diskSize)")

    for relativePath in try listRegularFiles(in: bundlePath) {
      let absolutePath = "\(bundlePath)/\(relativePath)"
      let attrs = try fileManager.attributesOfItem(atPath: absolutePath)
      let size = try Self.fileSize(from: attrs, atPath: absolutePath)
      let modifiedAt = attrs[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
      append(relativePath)
      append(String(size))
      append(String(modifiedAt.timeIntervalSince1970))
    }

    return Self.hexDigest(hasher.finalize())
  }

  private func packBundle(
    bundlePath: String,
    stagingDirectory: String,
    removeStagingDirectoryOnFailure: Bool,
    resources: VMResources,
    timeout: TimeInterval?,
    progressSink: VMImagePackProgressSink?
  ) async throws -> VMImagePackage {
    guard (Self.minimumChunkSize ... Self.maximumChunkSize).contains(chunkSize) else {
      throw VMImagePackagerError.invalidConfig("Chunk size must be between 1MB and 1GB")
    }
    guard resources.validate() else {
      throw VMImagePackagerError.invalidConfig("Image resources are outside supported bounds")
    }

    let chunksDirectory = "\(stagingDirectory)/chunks"
    try fileManager.createDirectory(
      atPath: stagingDirectory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingDirectory)
    try fileManager.createDirectory(atPath: chunksDirectory, withIntermediateDirectories: true)

    do {
      let inventory = try makePackInventory(bundlePath: bundlePath)
      await progressSink?(
        VMImagePackProgressUpdate(
          chunksCompletedDelta: nil,
          chunksTotal: inventory.totalChunks,
          bytesCompletedDelta: nil,
          bytesTotal: inventory.totalBytes
        )
      )

      let cachedFilesByPath = try decodeCachedFilesByPath(stagingDirectory: stagingDirectory)
      var packedFiles: [VMImagePackedFile] = []
      var layers: [VMImageLayer] = []

      for file in inventory.files {
        let relativePath = file.relativePath
        let absolutePath = "\(bundlePath)/\(relativePath)"
        let packed = try await packFile(
          absolutePath: absolutePath,
          relativePath: relativePath,
          fileSize: file.fileSize,
          chunksDirectory: chunksDirectory,
          cachedFile: cachedFilesByPath[relativePath],
          timeout: timeout,
          progressSink: progressSink
        )
        packedFiles.append(packed.file)
        layers.append(contentsOf: packed.layers)
      }

      let config = VMImageBundleConfig(
        artifactType: jeballtoImageArtifactType,
        resources: resources,
        chunkSize: chunkSize,
        compression: .init(algorithm: "zstd", level: compressionLevel),
        files: packedFiles
      )

      let configPath = "\(stagingDirectory)/vm-bundle-config.json"
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try VMImageConfigValidator.validate(config)
      let configData = try encoder.encode(config)
      guard UInt64(configData.count) <= Self.maxConfigSize else {
        throw VMImagePackagerError.invalidConfig("Generated image config exceeds the 4MB limit")
      }
      try configData.write(to: URL(fileURLWithPath: configPath), options: .atomic)

      return VMImagePackage(
        stagingDirectory: stagingDirectory,
        configPath: configPath,
        layers: layers,
        metadata: [
          "imageFormat": "chunked-zstd",
          "artifactType": jeballtoImageArtifactType,
          "formatVersion": String(Self.currentFormatVersion),
          "architecture": "arm64",
          "cpuCount": String(resources.cpuCount),
          "memorySize": String(resources.memorySize),
          "diskSize": String(resources.diskSize),
          "chunkSize": String(chunkSize),
          "compression": "zstd",
        ]
      )
    } catch {
      if removeStagingDirectoryOnFailure {
        try? fileManager.removeItem(atPath: stagingDirectory)
      }
      throw error
    }
  }

  private func makePackInventory(bundlePath: String) throws -> VMImagePackInventory {
    let relativeFiles = try listRegularFiles(in: bundlePath)
    guard relativeFiles.isEmpty == false else {
      throw VMImagePackagerError.invalidBundle("No files found in \(bundlePath)")
    }
    guard relativeFiles.count <= Self.maximumFileCount else {
      throw VMImagePackagerError.invalidBundle("Bundle contains more than \(Self.maximumFileCount) files")
    }
    let files = try relativeFiles.map { relativePath in
      let absolutePath = "\(bundlePath)/\(relativePath)"
      return try (
        relativePath: relativePath,
        fileSize: Self.fileSize(atPath: absolutePath, fileManager: fileManager)
      )
    }
    let missingOrEmptyRequiredFiles = requiredVMImageBundleFileNames.filter { requiredPath in
      files.first { $0.relativePath == requiredPath }.map { $0.fileSize == 0 } ?? true
    }
    guard missingOrEmptyRequiredFiles.isEmpty else {
      throw VMImagePackagerError.invalidBundle(
        "Required VM bundle files are missing or empty: \(missingOrEmptyRequiredFiles.joined(separator: ", "))"
      )
    }
    let totalChunks = try files.reduce(0) { total, file in
      let (result, overflow) = try total.addingReportingOverflow(chunkCount(forFileSize: file.fileSize))
      guard overflow == false, result <= Self.maximumChunkCount else {
        throw VMImagePackagerError.invalidBundle("Bundle requires more than \(Self.maximumChunkCount) chunks")
      }
      return result
    }
    let totalBytes = try files.reduce(UInt64(0)) { total, file in
      let (result, overflow) = total.addingReportingOverflow(file.fileSize)
      guard overflow == false, result <= Self.maximumUncompressedSize else {
        throw VMImagePackagerError.invalidBundle("Bundle exceeds the supported 9TB size")
      }
      return result
    }
    return VMImagePackInventory(files: files, totalChunks: totalChunks, totalBytes: totalBytes)
  }

  func unpackBundle(pulledDirectory: String, configPath: String, outputBundlePath: String, timeout: TimeInterval? = nil)
    async throws
  {
    let config = try decodeConfig(atPath: configPath)
    try await unpackBundle(
      config: config,
      layerDirectory: pulledDirectory,
      outputBundlePath: outputBundlePath,
      fetchLayer: nil,
      timeout: timeout
    )
  }

  func unpackBundle(
    configPath: String,
    layerDirectory: String,
    outputBundlePath: String,
    fetchLayer: @escaping VMImageLayerFetcher,
    timeout: TimeInterval? = nil
  ) async throws {
    let config = try decodeConfig(atPath: configPath)
    try await unpackBundle(
      config: config,
      layerDirectory: layerDirectory,
      outputBundlePath: outputBundlePath,
      fetchLayer: fetchLayer,
      timeout: timeout
    )
  }

  func decodeConfig(atPath configPath: String) throws -> VMImageBundleConfig {
    let configSize = try Self.fileSize(atPath: configPath, fileManager: fileManager)
    guard configSize <= Self.maxConfigSize else {
      throw VMImagePackagerError.invalidConfig("Image config exceeds the 4MB limit")
    }
    let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
    let config: VMImageBundleConfig
    do {
      config = try JSONDecoder().decode(VMImageBundleConfig.self, from: configData)
    } catch let error as VMImagePackagerError {
      throw error
    } catch let error as DecodingError {
      throw VMImagePackagerError.invalidConfig(Self.configDecodingErrorDescription(error))
    } catch {
      throw VMImagePackagerError.invalidConfig("Failed to decode image config: \(error.localizedDescription)")
    }

    guard config.formatVersion == Self.currentFormatVersion else {
      throw VMImagePackagerError.unsupportedFormat(
        "version \(config.formatVersion) is not supported; this agent supports "
          + Self.currentFormatDisplayName
      )
    }
    guard config.artifactType == jeballtoImageArtifactType else {
      throw VMImagePackagerError.invalidConfig("Unsupported image config")
    }
    guard config.architecture == "arm64" else {
      throw VMImagePackagerError.invalidConfig("Unsupported image architecture \(config.architecture)")
    }
    guard config.resources.validate() else {
      throw VMImagePackagerError.invalidConfig("Image resources are outside supported bounds")
    }
    guard (Self.minimumChunkSize ... Self.maximumChunkSize).contains(config.chunkSize) else {
      throw VMImagePackagerError.invalidConfig("Chunk size must be between 1MB and 1GB")
    }
    guard config.files.isEmpty == false else {
      throw VMImagePackagerError.invalidConfig("Image config must include at least one file")
    }
    guard config.compression.algorithm == "zstd" else {
      throw VMImagePackagerError.unsupportedCompression(config.compression.algorithm)
    }
    try VMImageConfigValidator.validate(config)
    return config
  }

  private static func configDecodingErrorDescription(_ error: DecodingError) -> String {
    switch error {
    case .keyNotFound(let key, let context):
      let path = configFieldPath(context.codingPath, appending: key)
      return "Missing required field '\(path)'"
    case .typeMismatch(_, let context):
      let path = configFieldPath(context.codingPath)
      return "Field '\(path)' has an invalid type: \(context.debugDescription)"
    case .valueNotFound(_, let context):
      let path = configFieldPath(context.codingPath)
      return "Field '\(path)' must not be null: \(context.debugDescription)"
    case .dataCorrupted(let context):
      let path = configFieldPath(context.codingPath)
      return "Invalid value at '\(path)': \(context.debugDescription)"
    @unknown default:
      return "Failed to decode image config"
    }
  }

  private static func configFieldPath(_ codingPath: [CodingKey], appending key: CodingKey? = nil) -> String {
    let path = codingPath.map(\.stringValue) + [key?.stringValue].compactMap { $0 }
    return path.isEmpty ? "<root>" : path.joined(separator: ".")
  }

  private func unpackBundle(
    config: VMImageBundleConfig,
    layerDirectory: String,
    outputBundlePath: String,
    fetchLayer: VMImageLayerFetcher?,
    timeout: TimeInterval?
  ) async throws {
    let outputParent = (outputBundlePath as NSString).deletingLastPathComponent
    let requiredPhysicalBytes = try config.files.reduce(UInt64(0)) { fileTotal, file in
      try file.chunks.reduce(fileTotal) { chunkTotal, chunk in
        guard chunk.zero == false else { return chunkTotal }
        let (result, overflow) = chunkTotal.addingReportingOverflow(chunk.uncompressedSize)
        guard !overflow else {
          throw VMImagePackagerError.invalidConfig("Uncompressed image size overflow")
        }
        return result
      }
    }
    let outputParentURL = URL(fileURLWithPath: outputParent, isDirectory: true)
    if let available = try? outputParentURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage,
      available >= 0,
      requiredPhysicalBytes > UInt64(available)
    {
      throw VMImagePackagerError.invalidBundle(
        "Insufficient disk space: need \(requiredPhysicalBytes) bytes, \(available) bytes available"
      )
    }
    let outputName = (outputBundlePath as NSString).lastPathComponent
    let tempOutputBundlePath = "\(outputParent)/.\(outputName).unpack-\(UUID().uuidString)"
    try fileManager.createDirectory(
      atPath: tempOutputBundlePath,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    defer {
      try? fileManager.removeItem(atPath: tempOutputBundlePath)
    }

    for packedFile in config.files {
      try VMImageConfigValidator.validateRelativePath(packedFile.path)
      let outputPath = "\(tempOutputBundlePath)/\(packedFile.path)"
      let outputFileParent = (outputPath as NSString).deletingLastPathComponent
      try fileManager.createDirectory(atPath: outputFileParent, withIntermediateDirectories: true)
      guard fileManager.createFile(
        atPath: outputPath,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      ) else {
        throw VMImagePackagerError.invalidBundle("Failed to create output file \(packedFile.path)")
      }

      let outputHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: outputPath))
      do {
        try outputHandle.truncate(atOffset: packedFile.size)
        try outputHandle.close()
      } catch {
        try? outputHandle.close()
        throw error
      }

      try await unpackChunks(
        packedFile: packedFile,
        layerDirectory: layerDirectory,
        outputPath: outputPath,
        fetchLayer: fetchLayer,
        timeout: timeout
      )

      // Each nonzero chunk is already verified while streaming zstd output.
      // Zero chunks are holes produced by truncate, so avoid rereading full VM disks into file cache.
    }

    if fileManager.fileExists(atPath: outputBundlePath) {
      try fileManager.removeItem(atPath: outputBundlePath)
    }
    try fileManager.moveItem(atPath: tempOutputBundlePath, toPath: outputBundlePath)
  }

  private func packFile(
    absolutePath: String,
    relativePath: String,
    fileSize: UInt64,
    chunksDirectory: String,
    cachedFile: VMImagePackedFile?,
    timeout: TimeInterval?,
    progressSink: VMImagePackProgressSink?
  ) async throws -> (file: VMImagePackedFile, layers: [VMImageLayer]) {
    let chunkCount = try chunkCount(forFileSize: fileSize)
    var results: [PackedChunkResult] = []
    results.reserveCapacity(chunkCount)
    let zstdClient = zstdClient
    let chunkSize = chunkSize
    let compressionLevel = compressionLevel
    let limit = min(effectiveParallelChunks(), chunkCount)
    var cachedChunksByIndex: [Int: VMImagePackedChunk] = [:]
    for chunk in cachedFile?.chunks ?? [] where cachedChunksByIndex[chunk.index] == nil {
      cachedChunksByIndex[chunk.index] = chunk
    }

    try await withThrowingTaskGroup(of: PackedChunkResult.self) { group in
      var nextIndex = 0

      for _ in 0 ..< limit {
        let index = nextIndex
        let request = PackChunkRequest(
          index: index,
          absolutePath: absolutePath,
          relativePath: relativePath,
          fileSize: fileSize,
          chunkSize: chunkSize,
          chunksDirectory: chunksDirectory,
          compressionLevel: compressionLevel,
          cachedChunk: cachedChunksByIndex[index],
          zstdClient: zstdClient,
          compressionLimiter: compressionLimiter,
          timeout: timeout
        )
        group.addTask {
          try await Self.packChunk(request)
        }
        nextIndex += 1
      }

      do {
        while let result = try await group.next() {
          results.append(result)
          await progressSink?(
            VMImagePackProgressUpdate(
              chunksCompletedDelta: 1,
              chunksTotal: nil,
              bytesCompletedDelta: result.chunk.uncompressedSize,
              bytesTotal: nil
            )
          )
          if nextIndex < chunkCount {
            let index = nextIndex
            let request = PackChunkRequest(
              index: index,
              absolutePath: absolutePath,
              relativePath: relativePath,
              fileSize: fileSize,
              chunkSize: chunkSize,
              chunksDirectory: chunksDirectory,
              compressionLevel: compressionLevel,
              cachedChunk: cachedChunksByIndex[index],
              zstdClient: zstdClient,
              compressionLimiter: compressionLimiter,
              timeout: timeout
            )
            group.addTask {
              try await Self.packChunk(request)
            }
            nextIndex += 1
          }
        }
      } catch {
        group.cancelAll()
        throw error
      }
    }

    let orderedResults = results.sorted { $0.chunk.index < $1.chunk.index }
    let chunks = orderedResults.map(\.chunk)
    let layers = orderedResults.compactMap(\.layer)
    return (VMImagePackedFile(path: relativePath, size: fileSize, chunks: chunks), layers)
  }

  private func chunkCount(forFileSize fileSize: UInt64) throws -> Int {
    let count = fileSize == 0 ? UInt64(1) : ((fileSize - 1) / chunkSize) + 1
    guard count <= UInt64(Int.max) else {
      throw VMImagePackagerError.invalidBundle("File requires too many chunks")
    }
    return Int(count)
  }

  private func decodeCachedFilesByPath(stagingDirectory: String) throws -> [String: VMImagePackedFile] {
    let configPath = "\(stagingDirectory)/vm-bundle-config.json"
    guard fileManager.fileExists(atPath: configPath) else { return [:] }

    do {
      let config = try decodeConfig(atPath: configPath)
      guard config.chunkSize == chunkSize,
            config.compression == .init(algorithm: "zstd", level: compressionLevel) else
      {
        return [:]
      }
      var filesByPath: [String: VMImagePackedFile] = [:]
      for file in config.files where filesByPath[file.path] == nil {
        filesByPath[file.path] = file
      }
      return filesByPath
    } catch {
      try? fileManager.removeItem(atPath: configPath)
      return [:]
    }
  }

  private func unpackChunks(
    packedFile: VMImagePackedFile,
    layerDirectory: String,
    outputPath: String,
    fetchLayer: VMImageLayerFetcher?,
    timeout: TimeInterval?
  ) async throws {
    let chunks = packedFile.chunks.filter { $0.zero == false }
    guard chunks.isEmpty == false else { return }
    let zstdClient = zstdClient
    let decompressionLimiter = decompressionLimiter
      ?? ImageConcurrencyLimiter(limit: effectiveDecompressionLimit())
    let diskWriteLimiter = diskWriteLimiter
      ?? ImageConcurrencyLimiter(limit: effectiveDiskWriteLimit())
    let limit = min(effectiveUnpackChunkLimit(), chunks.count)

    try await withThrowingTaskGroup(of: Void.self) { group in
      var nextIndex = 0

      for _ in 0 ..< limit {
        let chunk = chunks[nextIndex]
        let request = UnpackChunkRequest(
          packedFile: packedFile,
          chunk: chunk,
          layerDirectory: layerDirectory,
          outputPath: outputPath,
          fetchLayer: fetchLayer,
          zstdClient: zstdClient,
          decompressionLimiter: decompressionLimiter,
          diskWriteLimiter: diskWriteLimiter,
          timeout: timeout
        )
        group.addTask {
          try await Self.unpackChunk(request)
        }
        nextIndex += 1
      }

      do {
        while try await group.next() != nil {
          if nextIndex < chunks.count {
            let chunk = chunks[nextIndex]
            let request = UnpackChunkRequest(
              packedFile: packedFile,
              chunk: chunk,
              layerDirectory: layerDirectory,
              outputPath: outputPath,
              fetchLayer: fetchLayer,
              zstdClient: zstdClient,
              decompressionLimiter: decompressionLimiter,
              diskWriteLimiter: diskWriteLimiter,
              timeout: timeout
            )
            group.addTask {
              try await Self.unpackChunk(request)
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

  private func effectiveParallelChunks() -> Int {
    if maxParallelChunks > 0 {
      return maxParallelChunks
    }
    return Self.automaticParallelChunkLimit()
  }

  private func effectiveUnpackChunkLimit() -> Int {
    if let maxParallelUnpackChunks, maxParallelUnpackChunks > 0 {
      return maxParallelUnpackChunks
    }
    return effectiveParallelChunks()
  }

  private func effectiveDecompressionLimit() -> Int {
    if let maxParallelDecompressions, maxParallelDecompressions > 0 {
      return maxParallelDecompressions
    }
    return effectiveParallelChunks()
  }

  private func effectiveDiskWriteLimit() -> Int {
    if let maxParallelDiskWrites, maxParallelDiskWrites > 0 {
      return maxParallelDiskWrites
    }
    return effectiveDecompressionLimit()
  }

  private static func packChunk(_ request: PackChunkRequest) async throws -> PackedChunkResult {
    try Task.checkCancellation()

    let offset = UInt64(request.index) * request.chunkSize
    let size = request.fileSize == 0 ? 0 : min(request.chunkSize, request.fileSize - offset)
    let chunkFileName = layerName(for: request.relativePath, index: request.index)
    let layerPath = "chunks/\(chunkFileName).zst"
    let compressedPath = "\(request.chunksDirectory)/\(chunkFileName).zst"
    let scannedChunk = try request.zstdClient.scanRange(inputPath: request.absolutePath, offset: offset, size: size)

    if scannedChunk.isZero {
      return PackedChunkResult(
        chunk: VMImagePackedChunk(
          index: request.index,
          offset: offset,
          uncompressedSize: size,
          uncompressedDigest: VMImageConfigValidator.zeroDigest(size: size),
          compressedSize: nil,
          compressedDigest: nil,
          layerPath: nil,
          zero: true
        ),
        layer: nil
      )
    }

    if let cachedResult = try cachedPackedChunkResult(
      request: request,
      scannedChunk: scannedChunk,
      compressedPath: compressedPath,
      layerPath: layerPath
    ) {
      return cachedResult
    }

    let chunkInfo: ZstdRangeDigest
    do {
      if let compressionLimiter = request.compressionLimiter {
        chunkInfo = try await compressionLimiter.withPermit {
          try await request.zstdClient.compressRange(
            inputPath: request.absolutePath,
            offset: offset,
            size: size,
            outputPath: compressedPath,
            level: request.compressionLevel,
            timeout: request.timeout
          )
        }
      } else {
        chunkInfo = try await request.zstdClient.compressRange(
          inputPath: request.absolutePath,
          offset: offset,
          size: size,
          outputPath: compressedPath,
          level: request.compressionLevel,
          timeout: request.timeout
        )
      }
    } catch {
      try? FileManager.default.removeItem(atPath: compressedPath)
      throw error
    }

    guard chunkInfo.digest == scannedChunk.digest, chunkInfo.size == scannedChunk.size else {
      try? FileManager.default.removeItem(atPath: compressedPath)
      throw VMImagePackagerError
        .digestMismatch("Source changed while packing \(request.relativePath) chunk \(request.index)")
    }

    let compressedSize = try Self.fileSize(atPath: compressedPath)
    guard compressedSize <= Self.maximumCompressedLayerSize else {
      try? FileManager.default.removeItem(atPath: compressedPath)
      throw VMImagePackagerError.invalidBundle(
        "Compressed chunk for \(request.relativePath) exceeds the supported 2GB layer size"
      )
    }
    let compressedDigest = try sha256File(atPath: compressedPath)
    return PackedChunkResult(
      chunk: VMImagePackedChunk(
        index: request.index,
        offset: offset,
        uncompressedSize: size,
        uncompressedDigest: chunkInfo.digest,
        compressedSize: compressedSize,
        compressedDigest: compressedDigest,
        layerPath: layerPath,
        zero: false
      ),
      layer: VMImageLayer(
        absolutePath: compressedPath,
        relativePath: layerPath,
        mediaType: jeballtoImageChunkMediaType,
        digest: compressedDigest,
        size: compressedSize
      )
    )
  }

  private static func cachedPackedChunkResult(
    request: PackChunkRequest,
    scannedChunk: ZstdRangeDigest,
    compressedPath: String,
    layerPath: String
  ) throws -> PackedChunkResult? {
    guard let cachedChunk = request.cachedChunk,
          cachedChunk.zero == false,
          cachedChunk.index == request.index,
          cachedChunk.offset == UInt64(request.index) * request.chunkSize,
          cachedChunk.uncompressedSize == scannedChunk.size,
          cachedChunk.uncompressedDigest == scannedChunk.digest,
          cachedChunk.layerPath == layerPath,
          let compressedSize = cachedChunk.compressedSize,
          let compressedDigest = cachedChunk.compressedDigest else
    {
      return nil
    }

    guard FileManager.default.fileExists(atPath: compressedPath) else {
      return nil
    }
    do {
      let actualSize = try fileSize(atPath: compressedPath)
      let actualDigest = try sha256File(atPath: compressedPath)
      guard actualSize == compressedSize, actualDigest == compressedDigest else {
        try? FileManager.default.removeItem(atPath: compressedPath)
        return nil
      }
    } catch {
      try? FileManager.default.removeItem(atPath: compressedPath)
      return nil
    }

    return PackedChunkResult(
      chunk: cachedChunk,
      layer: VMImageLayer(
        absolutePath: compressedPath,
        relativePath: layerPath,
        mediaType: jeballtoImageChunkMediaType,
        digest: compressedDigest,
        size: compressedSize
      )
    )
  }

  private static func unpackChunk(_ request: UnpackChunkRequest) async throws {
    try Task.checkCancellation()

    let packedFile = request.packedFile
    let chunk = request.chunk

    guard let layerPath = chunk.layerPath,
          let compressedDigest = chunk.compressedDigest,
          let compressedSize = chunk.compressedSize else
    {
      throw VMImagePackagerError.invalidConfig("Missing layer metadata for \(packedFile.path) chunk \(chunk.index)")
    }

    try VMImageConfigValidator.validateRelativePath(layerPath)
    let compressedPath = "\(request.layerDirectory)/\(layerPath)"
    do {
      if let fetchLayer = request.fetchLayer {
        let layerParent = (compressedPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: layerParent, withIntermediateDirectories: true)
        try await fetchLayer(packedFile, chunk, compressedPath)
      }
    } catch {
      try? FileManager.default.removeItem(atPath: compressedPath)
      throw error
    }

    do {
      guard FileManager.default.fileExists(atPath: compressedPath) else {
        throw VMImagePackagerError.invalidBundle("Missing layer \(layerPath)")
      }
      let actualCompressedSize = try fileSize(atPath: compressedPath)
      guard actualCompressedSize == compressedSize else {
        throw VMImagePackagerError.digestMismatch("Compressed size mismatch for \(layerPath)")
      }
      let actualCompressedDigest = try sha256File(atPath: compressedPath)
      guard actualCompressedDigest == compressedDigest else {
        throw VMImagePackagerError.digestMismatch("Compressed digest mismatch for \(layerPath)")
      }

      let actualRaw: ZstdRangeDigest
      do {
        actualRaw = try await request.decompressionLimiter.withPermit {
          try await request.zstdClient.decompressToFileRange(
            inputPath: compressedPath,
            destinationPath: request.outputPath,
            offset: chunk.offset,
            expectedSize: chunk.uncompressedSize,
            diskWriteLimiter: request.diskWriteLimiter,
            timeout: request.timeout
          )
        }
      } catch let error as ZstdError {
        switch error {
        case .commandFailed(let exitCode, let stderr) where exitCode > 0:
          throw VMImagePackagerError.invalidConfig(
            "Layer \(layerPath) is not valid zstd data: \(stderr.prefix(500))"
          )
        case .streamingFailed(let message) where message.hasPrefix("Decompressed output "):
          throw VMImagePackagerError.invalidConfig("Layer \(layerPath) has invalid output: \(message)")
        default:
          throw error
        }
      }
      guard actualRaw.size == chunk.uncompressedSize else {
        throw VMImagePackagerError.digestMismatch("Uncompressed size mismatch for \(layerPath)")
      }
      guard actualRaw.digest == chunk.uncompressedDigest else {
        throw VMImagePackagerError.digestMismatch("Uncompressed digest mismatch for \(layerPath)")
      }
      try? FileManager.default.removeItem(atPath: compressedPath)
    } catch {
      if request.fetchLayer != nil {
        try? FileManager.default.removeItem(atPath: compressedPath)
      }
      throw error
    }
  }
}

private extension VMImagePackager {
  private func listRegularFiles(in bundlePath: String) throws -> [String] {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: bundlePath, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw VMImagePackagerError.invalidBundle("Bundle directory does not exist: \(bundlePath)")
    }
    guard let enumerator = fileManager.enumerator(atPath: bundlePath) else {
      throw VMImagePackagerError.invalidBundle("Cannot enumerate bundle: \(bundlePath)")
    }

    var files: [String] = []
    while let item = enumerator.nextObject() as? String {
      let path = "\(bundlePath)/\(item)"
      var status = stat()
      let result = path.withCString { Darwin.lstat($0, &status) }
      guard result == 0 else {
        throw VMImagePackagerError.invalidBundle(
          "Cannot inspect \(item): \(String(cString: strerror(errno)))"
        )
      }
      switch status.st_mode & S_IFMT {
      case S_IFDIR:
        continue
      case S_IFREG:
        files.append(item)
      default:
        throw VMImagePackagerError.invalidBundle(
          "Bundle contains unsupported non-regular item: \(item)"
        )
      }
    }

    return files.sorted { lhs, rhs in
      if lhs == "Disk.img" { return true }
      if rhs == "Disk.img" { return false }
      return lhs < rhs
    }
  }

  private static func sha256File(atPath path: String) throws -> String {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      try Task.checkCancellation()
      let data = try readFileChunk(from: handle, upToCount: 4 * 1024 * 1024) ?? Data()
      guard !data.isEmpty else { break }
      hasher.update(data: data)
    }
    return Self.hexDigest(hasher.finalize())
  }

  private static func hexDigest(_ digest: some Sequence<UInt8>) -> String {
    "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }

  private static func fileSize(atPath path: String, fileManager: FileManager = .default) throws -> UInt64 {
    let attrs = try fileManager.attributesOfItem(atPath: path)
    return try fileSize(from: attrs, atPath: path)
  }

  private static func fileSize(from attributes: [FileAttributeKey: Any], atPath path: String) throws -> UInt64 {
    guard let number = attributes[.size] as? NSNumber, number.doubleValue >= 0 else {
      throw VMImagePackagerError.invalidBundle("Invalid file size metadata for \(path)")
    }
    return number.uint64Value
  }

  private static func layerName(for relativePath: String, index: Int) -> String {
    let digest = Self.hexDigest(SHA256.hash(data: Data(relativePath.utf8)))
      .dropFirst("sha256:".count)
      .prefix(16)
    let safePath = (relativePath as NSString).lastPathComponent
      .replacingOccurrences(of: "/", with: "__")
      .replacingOccurrences(of: ":", with: "_")
    return "\(safePath).\(digest).\(String(format: "%06d", index))"
  }
}
