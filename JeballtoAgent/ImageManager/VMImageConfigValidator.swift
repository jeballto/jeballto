import CryptoKit
import Foundation

enum VMImageConfigValidator {
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
