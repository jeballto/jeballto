import Foundation

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

struct PackedChunkResult: Sendable {
  let chunk: VMImagePackedChunk
  let layer: VMImageLayer?
}

struct PackChunkRequest: Sendable {
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

struct UnpackChunkRequest: Sendable {
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
