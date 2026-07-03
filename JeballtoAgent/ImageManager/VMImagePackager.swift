import CryptoKit
import Darwin
import Foundation

// swiftlint:disable file_length

let jeballtoImageArtifactType = "application/vnd.jeballto.vm.bundle"
let jeballtoImageConfigMediaType = "application/vnd.jeballto.vm.bundle.config+json"
let jeballtoImageChunkMediaType = "application/vnd.jeballto.vm.bundle.chunk+zstd"

struct VMImageLayer: Sendable {
  let absolutePath: String
  let relativePath: String
  let mediaType: String
}

struct VMImagePackage: Sendable {
  let stagingDirectory: String
  let configPath: String
  let layers: [VMImageLayer]
  let metadata: [String: String]
}

struct VMImageBundleConfig: Codable, Equatable, Sendable {
  struct Compression: Codable, Equatable, Sendable {
    let algorithm: String
    let level: Int
  }

  let artifactType: String
  let chunkSize: UInt64
  let compression: Compression
  let files: [VMImagePackedFile]
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
  case digestMismatch(String)
  case unsupportedCompression(String)

  var errorDescription: String? {
    switch self {
    case .invalidBundle(let message): "Invalid VM image bundle: \(message)"
    case .invalidConfig(let message): "Invalid VM image config: \(message)"
    case .digestMismatch(let message): "VM image digest mismatch: \(message)"
    case .unsupportedCompression(let message): "Unsupported VM image compression: \(message)"
    }
  }
}

private enum VMImageConfigValidator {
  private struct ValidationContext {
    var seenFilePaths: Set<String> = []
    var seenLayerPaths: Set<String> = []
  }

  static func validate(_ config: VMImageBundleConfig) throws {
    var context = ValidationContext()
    for packedFile in config.files {
      try validate(packedFile, config: config, context: &context)
    }
  }

  static func validateRelativePath(_ path: String) throws {
    guard !path.isEmpty,
          !path.hasPrefix("/"),
          !path.contains("\0"),
          !path.split(separator: "/").contains("..") else
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
    guard context.seenFilePaths.insert(packedFile.path).inserted else {
      throw VMImagePackagerError.invalidConfig("Duplicate file path: \(packedFile.path)")
    }

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
        seenLayerPaths: &context.seenLayerPaths
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
    seenLayerPaths: inout Set<String>
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

    try validateNonzeroChunk(chunk, in: packedFile, seenLayerPaths: &seenLayerPaths)
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
    seenLayerPaths: inout Set<String>
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
    guard seenLayerPaths.insert(layerPath).inserted else {
      throw VMImagePackagerError.invalidConfig("Duplicate layer path: \(layerPath)")
    }
  }

  private static func isValidSHA256Digest(_ digest: String) -> Bool {
    let prefix = "sha256:"
    let lowercaseHex = Set("0123456789abcdef")
    guard digest.hasPrefix(prefix), digest.count == prefix.count + 64 else { return false }
    return digest.dropFirst(prefix.count).allSatisfy { character in
      lowercaseHex.contains(character)
    }
  }

  private static func zeroDigest(size: UInt64) -> String {
    let bufferSize = 1024 * 1024
    let zeroBuffer = Data(repeating: 0, count: bufferSize)
    var remaining = size
    var hasher = SHA256()

    while remaining > 0 {
      let count = Int(min(UInt64(bufferSize), remaining))
      if count == bufferSize {
        hasher.update(data: zeroBuffer)
      } else {
        hasher.update(data: zeroBuffer.prefix(count))
      }
      remaining -= UInt64(count)
    }

    return hexDigest(hasher.finalize())
  }

  private static func hexDigest(_ digest: some Sequence<UInt8>) -> String {
    "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
  }
}

struct VMImagePackager {
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
  private let fileManager: FileManager

  init(
    zstdClient: ZstdClient,
    chunkSize: UInt64 = Self.defaultChunkSize,
    compressionLevel: Int = Self.defaultCompressionLevel,
    maxParallelChunks: Int = 0,
    maxParallelUnpackChunks: Int? = nil,
    maxParallelDecompressions: Int? = nil,
    maxParallelDiskWrites: Int? = nil,
    fileManager: FileManager = .default
  ) {
    self.zstdClient = zstdClient
    self.chunkSize = chunkSize
    self.compressionLevel = compressionLevel
    self.maxParallelChunks = maxParallelChunks
    self.maxParallelUnpackChunks = maxParallelUnpackChunks
    self.maxParallelDecompressions = maxParallelDecompressions
    self.maxParallelDiskWrites = maxParallelDiskWrites
    self.fileManager = fileManager
  }

  func packBundle(
    bundlePath: String,
    stagingRoot: String,
    timeout: TimeInterval? = nil,
    progressSink: VMImagePackProgressSink? = nil
  ) async throws -> VMImagePackage {
    let stagingDirectory = "\(stagingRoot)/vm-image-\(UUID().uuidString)"
    return try await packBundle(
      bundlePath: bundlePath,
      stagingDirectory: stagingDirectory,
      removeStagingDirectoryOnFailure: true,
      timeout: timeout,
      progressSink: progressSink
    )
  }

  func packBundle(
    bundlePath: String,
    stagingDirectory: String,
    timeout: TimeInterval? = nil,
    progressSink: VMImagePackProgressSink? = nil
  ) async throws -> VMImagePackage {
    try await packBundle(
      bundlePath: bundlePath,
      stagingDirectory: stagingDirectory,
      removeStagingDirectoryOnFailure: false,
      timeout: timeout,
      progressSink: progressSink
    )
  }

  func sourceFingerprint(bundlePath: String) throws -> String {
    guard chunkSize > 0 else { throw VMImagePackagerError.invalidConfig("Chunk size must be positive") }

    var hasher = SHA256()
    func append(_ value: String) {
      hasher.update(data: Data(value.utf8))
      hasher.update(data: Data([0]))
    }

    append("artifactType=\(jeballtoImageArtifactType)")
    append("chunkSize=\(chunkSize)")
    append("compression=zstd")
    append("compressionLevel=\(compressionLevel)")

    for relativePath in try listRegularFiles(in: bundlePath) {
      let absolutePath = "\(bundlePath)/\(relativePath)"
      let attrs = try fileManager.attributesOfItem(atPath: absolutePath)
      let size = attrs[.size] as? UInt64 ?? UInt64(attrs[.size] as? Int64 ?? 0)
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
    timeout: TimeInterval?,
    progressSink: VMImagePackProgressSink?
  ) async throws -> VMImagePackage {
    guard chunkSize > 0 else { throw VMImagePackagerError.invalidConfig("Chunk size must be positive") }

    let chunksDirectory = "\(stagingDirectory)/chunks"
    try fileManager.createDirectory(atPath: chunksDirectory, withIntermediateDirectories: true)

    do {
      let relativeFiles = try listRegularFiles(in: bundlePath)
      guard !relativeFiles.isEmpty else {
        throw VMImagePackagerError.invalidBundle("No files found in \(bundlePath)")
      }
      let files = try relativeFiles.map { relativePath in
        let absolutePath = "\(bundlePath)/\(relativePath)"
        return try (relativePath: relativePath, fileSize: Self.fileSize(atPath: absolutePath, fileManager: fileManager))
      }
      let totalChunks = files.reduce(0) { total, file in
        total + chunkCount(forFileSize: file.fileSize)
      }
      let totalBytes = files.reduce(UInt64(0)) { total, file in
        total + file.fileSize
      }
      await progressSink?(
        VMImagePackProgressUpdate(
          chunksCompletedDelta: nil,
          chunksTotal: totalChunks,
          bytesCompletedDelta: nil,
          bytesTotal: totalBytes
        )
      )

      let cachedFilesByPath = try decodeCachedFilesByPath(stagingDirectory: stagingDirectory)
      var packedFiles: [VMImagePackedFile] = []
      var layers: [VMImageLayer] = []

      for file in files {
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
        chunkSize: chunkSize,
        compression: .init(algorithm: "zstd", level: compressionLevel),
        files: packedFiles
      )

      let configPath = "\(stagingDirectory)/vm-bundle-config.json"
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      try encoder.encode(config).write(to: URL(fileURLWithPath: configPath), options: .atomic)

      return VMImagePackage(
        stagingDirectory: stagingDirectory,
        configPath: configPath,
        layers: layers,
        metadata: [
          "imageFormat": "chunked-zstd",
          "artifactType": jeballtoImageArtifactType,
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

  private func decodeConfig(atPath configPath: String) throws -> VMImageBundleConfig {
    let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
    let config = try JSONDecoder().decode(VMImageBundleConfig.self, from: configData)

    guard config.artifactType == jeballtoImageArtifactType else {
      throw VMImagePackagerError.invalidConfig("Unsupported image config")
    }
    guard config.chunkSize > 0 else {
      throw VMImagePackagerError.invalidConfig("Chunk size must be positive")
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

  private func unpackBundle(
    config: VMImageBundleConfig,
    layerDirectory: String,
    outputBundlePath: String,
    fetchLayer: VMImageLayerFetcher?,
    timeout: TimeInterval?
  ) async throws {
    let outputParent = (outputBundlePath as NSString).deletingLastPathComponent
    let outputName = (outputBundlePath as NSString).lastPathComponent
    let tempOutputBundlePath = "\(outputParent)/.\(outputName).unpack-\(UUID().uuidString)"
    try fileManager.createDirectory(atPath: tempOutputBundlePath, withIntermediateDirectories: true)
    defer {
      try? fileManager.removeItem(atPath: tempOutputBundlePath)
    }

    for packedFile in config.files {
      try VMImageConfigValidator.validateRelativePath(packedFile.path)
      let outputPath = "\(tempOutputBundlePath)/\(packedFile.path)"
      let outputFileParent = (outputPath as NSString).deletingLastPathComponent
      try fileManager.createDirectory(atPath: outputFileParent, withIntermediateDirectories: true)
      fileManager.createFile(atPath: outputPath, contents: nil)

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
    let chunkCount = chunkCount(forFileSize: fileSize)
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

  private func chunkCount(forFileSize fileSize: UInt64) -> Int {
    fileSize == 0 ? 1 : Int((fileSize + chunkSize - 1) / chunkSize)
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
    let decompressionLimiter = ImageConcurrencyLimiter(limit: effectiveDecompressionLimit())
    let diskWriteLimiter = ImageConcurrencyLimiter(limit: effectiveDiskWriteLimit())
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
          uncompressedDigest: scannedChunk.digest,
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
      chunkInfo = try await request.zstdClient.compressRange(
        inputPath: request.absolutePath,
        offset: offset,
        size: size,
        outputPath: compressedPath,
        level: request.compressionLevel,
        timeout: request.timeout
      )
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
        mediaType: jeballtoImageChunkMediaType
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
        mediaType: jeballtoImageChunkMediaType
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

      let actualRaw = try await request.decompressionLimiter.withPermit {
        try await request.zstdClient.decompressToFileRange(
          inputPath: compressedPath,
          destinationPath: request.outputPath,
          offset: chunk.offset,
          diskWriteLimiter: request.diskWriteLimiter,
          timeout: request.timeout
        )
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
      var itemIsDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: path, isDirectory: &itemIsDirectory), !itemIsDirectory.boolValue {
        files.append(item)
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
      let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
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
    return attrs[.size] as? UInt64 ?? UInt64(attrs[.size] as? Int64 ?? 0)
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
