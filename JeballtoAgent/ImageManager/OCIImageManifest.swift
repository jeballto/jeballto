import Foundation

/// A downloaded OCI blob did not match the descriptor advertised by the registry.
enum OrasBlobValidationError: Error, Equatable, LocalizedError, Sendable {
  case sizeMismatch(digest: String, expected: UInt64, actual: UInt64)
  case digestMismatch(expected: String, actual: String)

  var errorDescription: String? {
    switch self {
    case .sizeMismatch(let digest, let expected, let actual):
      "Blob \(digest) size mismatch: expected \(expected), got \(actual)"
    case .digestMismatch(let expected, let actual):
      "Blob digest mismatch: expected \(expected), got \(actual)"
    }
  }
}

/// Result of an oras push operation.
struct OrasPushResult: Sendable {
  let digest: String
}

let ociImageManifestMediaType = "application/vnd.oci.image.manifest.v1+json"

/// Metadata from an OCI manifest.
struct OrasDescriptor: Codable, Equatable, Sendable {
  let mediaType: String
  let digest: String
  let size: UInt64
}

/// Validation failures for the Jeballto OCI manifest contract.
enum JeballtoImageManifestError: Error, Equatable, LocalizedError, Sendable {
  case unsupportedArtifactType(subject: String, actual: String?)
  case unsupportedManifestMediaType(subject: String, actual: String)
  case unsupportedConfigMediaType(subject: String, actual: String)
  case invalidManifest(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedArtifactType(let subject, let actual):
      "\(subject) manifest has unsupported artifact type \(actual ?? "nil")"
    case .unsupportedManifestMediaType(let subject, let actual):
      "\(subject) manifest has unsupported media type \(actual)"
    case .unsupportedConfigMediaType(let subject, let actual):
      "\(subject) manifest has unsupported config media type \(actual)"
    case .invalidManifest(let message):
      message
    }
  }
}

struct OrasManifestInfo: Sendable {
  private static let maxManifestSize = 8 * 1024 * 1024
  let schemaVersion: Int?
  let mediaType: String?
  let artifactType: String?
  let configMediaType: String?
  let configDescriptor: OrasDescriptor?
  let layers: [OrasDescriptor]
  let rawManifest: String

  var isJeballtoImage: Bool {
    (try? validateJeballtoImage()) != nil
  }

  var formatSummary: String {
    let layerSummary = Dictionary(grouping: layers, by: \.mediaType)
      .map { mediaType, descriptors in "\(mediaType) x\(descriptors.count)" }
      .sorted()
      .joined(separator: ", ")
    return [
      "schemaVersion=\(schemaVersion.map(String.init) ?? "nil")",
      "mediaType=\(mediaType ?? "nil")",
      "artifactType=\(artifactType ?? "nil")",
      "configMediaType=\(configMediaType ?? "nil")",
      "layerMediaTypes=\(layerSummary)",
    ].joined(separator: ", ")
  }

  init(rawManifest: String) throws {
    struct Manifest: Decodable {
      let schemaVersion: Int?
      let mediaType: String?
      let artifactType: String?
      let config: OrasDescriptor?
      let layers: [OrasDescriptor]?
    }

    guard rawManifest.utf8.count <= Self.maxManifestSize else {
      throw OrasError.invalidOutput("OCI manifest exceeds the 8MB limit")
    }
    let data = Data(rawManifest.utf8)
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    schemaVersion = manifest.schemaVersion
    mediaType = manifest.mediaType
    artifactType = manifest.artifactType
    configMediaType = manifest.config?.mediaType
    configDescriptor = manifest.config
    layers = manifest.layers ?? []
    self.rawManifest = rawManifest
  }

  /// Validates the stable Jeballto OCI envelope and the current v1 layer contract.
  func validateJeballtoImage(reference: String? = nil) throws {
    try validateJeballtoImageEnvelope(reference: reference)
    try validateJeballtoV1Layers(reference: reference)
  }

  /// Validates the stable OCI envelope needed to locate and decode the versioned config blob.
  func validateJeballtoImageEnvelope(reference: String? = nil) throws {
    let subject = reference ?? "image"

    guard schemaVersion == 2 else {
      throw JeballtoImageManifestError.invalidManifest(
        "\(subject) manifest must use OCI schemaVersion 2"
      )
    }
    if let mediaType, mediaType != ociImageManifestMediaType {
      throw JeballtoImageManifestError.unsupportedManifestMediaType(
        subject: subject,
        actual: mediaType
      )
    }
    guard artifactType == jeballtoImageArtifactType else {
      throw JeballtoImageManifestError.unsupportedArtifactType(
        subject: subject,
        actual: artifactType
      )
    }
    guard let configDescriptor else {
      throw JeballtoImageManifestError.invalidManifest(
        "\(subject) manifest is missing a config descriptor"
      )
    }
    guard configDescriptor.mediaType == jeballtoImageConfigMediaType else {
      throw JeballtoImageManifestError.unsupportedConfigMediaType(
        subject: subject,
        actual: configDescriptor.mediaType
      )
    }
    try Self.validateDescriptor(configDescriptor, role: "config", subject: subject)
    guard configDescriptor.size <= VMImagePackager.maxConfigSize else {
      throw JeballtoImageManifestError.invalidManifest(
        "\(subject) config descriptor exceeds the 4MB limit"
      )
    }
  }

  /// Validates descriptors that belong to Jeballto VM Bundle Format v1.
  func validateJeballtoV1Layers(reference: String? = nil) throws {
    let subject = reference ?? "image"
    guard let configDescriptor else {
      throw JeballtoImageManifestError.invalidManifest(
        "\(subject) manifest is missing a config descriptor"
      )
    }
    guard layers.isEmpty == false else {
      throw JeballtoImageManifestError.invalidManifest(
        "\(subject) manifest must include at least one layer"
      )
    }
    guard layers.count <= VMImagePackager.maximumChunkCount else {
      throw JeballtoImageManifestError.invalidManifest(
        "\(subject) manifest contains too many layers"
      )
    }
    var totalBlobSize = configDescriptor.size
    for layer in layers {
      guard layer.mediaType == jeballtoImageChunkMediaType else {
        throw JeballtoImageManifestError.invalidManifest(
          "\(subject) manifest has unsupported layer media type \(layer.mediaType)"
        )
      }
      try Self.validateDescriptor(layer, role: "layer", subject: subject)
      guard layer.size <= VMImagePackager.maximumCompressedLayerSize else {
        throw JeballtoImageManifestError.invalidManifest(
          "\(subject) layer \(layer.digest) exceeds the 2GB limit"
        )
      }
      let (newTotal, overflow) = totalBlobSize.addingReportingOverflow(layer.size)
      guard !overflow, newTotal <= VMImagePackager.maximumTotalBlobSize else {
        throw JeballtoImageManifestError.invalidManifest(
          "\(subject) manifest exceeds the supported total blob size"
        )
      }
      totalBlobSize = newTotal
    }
  }

  private static func validateDescriptor(_ descriptor: OrasDescriptor, role: String, subject: String) throws {
    guard descriptor.digest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil else {
      throw JeballtoImageManifestError.invalidManifest(
        "\(subject) \(role) descriptor has invalid digest \(descriptor.digest)"
      )
    }
    guard descriptor.size > 0 else {
      throw JeballtoImageManifestError.invalidManifest(
        "\(subject) \(role) descriptor must have a positive size"
      )
    }
  }
}

enum OrasBlobPresence: Equatable, Sendable {
  case exists
  case missing
}
