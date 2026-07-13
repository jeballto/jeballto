import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct OrasManifestParsingTests {
  @Test
  func manifestParsingExtractsConfigAndLayerDescriptors() throws {
    let rawManifest = """
    {
      "schemaVersion": 2,
      "artifactType": "\(jeballtoImageArtifactType)",
      "config": {
        "mediaType": "\(jeballtoImageConfigMediaType)",
        "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "size": 123
      },
      "layers": [
        {
          "mediaType": "\(jeballtoImageChunkMediaType)",
          "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
          "size": 456
        },
        {
          "mediaType": "\(jeballtoImageChunkMediaType)",
          "digest": "sha256:3333333333333333333333333333333333333333333333333333333333333333",
          "size": 789
        }
      ]
    }
    """

    let manifest = try OrasManifestInfo(rawManifest: rawManifest)

    #expect(manifest.artifactType == jeballtoImageArtifactType)
    #expect(manifest.configMediaType == jeballtoImageConfigMediaType)
    let configDigest = try #require(manifest.configDescriptor?.digest)
    #expect(configDigest == "sha256:1111111111111111111111111111111111111111111111111111111111111111")
    #expect(manifest.configDescriptor?.size == 123)
    #expect(manifest.layers.map(\.digest) == [
      "sha256:2222222222222222222222222222222222222222222222222222222222222222",
      "sha256:3333333333333333333333333333333333333333333333333333333333333333",
    ])
    #expect(manifest.layers.map(\.size) == [456, 789])
    #expect(manifest.formatSummary.contains("\(jeballtoImageChunkMediaType) x2"))
  }

  @Test
  func manifestWithCanonicalConfigMediaTypeIsDetectedAsJeballtoImage() throws {
    let rawManifest = """
    {
      "schemaVersion": 2,
      "artifactType": "\(jeballtoImageArtifactType)",
      "config": {
        "mediaType": "\(jeballtoImageConfigMediaType)",
        "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "size": 123
      },
      "layers": [
        {
          "mediaType": "\(jeballtoImageChunkMediaType)",
          "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
          "size": 456
        }
      ]
    }
    """

    let manifest = try OrasManifestInfo(rawManifest: rawManifest)

    #expect(manifest.isJeballtoImage)
  }

  @Test
  func unsupportedManifestMediaTypeHasAFormatError() throws {
    let unsupportedMediaType = "application/vnd.oci.image.index.v1+json"
    let rawManifest = """
    {
      "schemaVersion": 2,
      "mediaType": "\(unsupportedMediaType)",
      "artifactType": "\(jeballtoImageArtifactType)",
      "config": {
        "mediaType": "\(jeballtoImageConfigMediaType)",
        "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "size": 123
      },
      "layers": [
        {
          "mediaType": "\(jeballtoImageChunkMediaType)",
          "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
          "size": 456
        }
      ]
    }
    """
    let manifest = try OrasManifestInfo(rawManifest: rawManifest)

    #expect(throws: JeballtoImageManifestError.unsupportedManifestMediaType(
      subject: "image",
      actual: unsupportedMediaType
    )) {
      try manifest.validateJeballtoImageEnvelope()
    }
  }

  @Test
  func manifestWithoutCanonicalArtifactTypeIsRejectedEvenWithConfigMediaType() throws {
    let rawManifest = """
    {
      "schemaVersion": 2,
      "config": {
        "mediaType": "\(jeballtoImageConfigMediaType)",
        "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "size": 123
      },
      "layers": [
        {
          "mediaType": "\(jeballtoImageChunkMediaType)",
          "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
          "size": 456
        }
      ]
    }
    """

    let manifest = try OrasManifestInfo(rawManifest: rawManifest)

    #expect(manifest.isJeballtoImage == false)
    #expect(throws: JeballtoImageManifestError.unsupportedArtifactType(subject: "image", actual: nil)) {
      try manifest.validateJeballtoImageEnvelope()
    }
  }

  @Test
  func manifestWithoutCanonicalConfigMediaTypeIsRejectedEvenWithArtifactType() throws {
    let rawManifest = """
    {
      "schemaVersion": 2,
      "artifactType": "\(jeballtoImageArtifactType)",
      "config": {
        "mediaType": "application/vnd.unknown.config+json",
        "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "size": 123
      },
      "layers": [
        {
          "mediaType": "\(jeballtoImageChunkMediaType)",
          "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
          "size": 456
        }
      ]
    }
    """

    let manifest = try OrasManifestInfo(rawManifest: rawManifest)

    #expect(manifest.isJeballtoImage == false)
    #expect(throws: JeballtoImageManifestError.unsupportedConfigMediaType(
      subject: "image",
      actual: "application/vnd.unknown.config+json"
    )) {
      try manifest.validateJeballtoImageEnvelope()
    }
  }

  @Test
  func manifestWithoutCanonicalLayerMediaTypeIsRejected() throws {
    let rawManifest = """
    {
      "schemaVersion": 2,
      "artifactType": "\(jeballtoImageArtifactType)",
      "config": {
        "mediaType": "\(jeballtoImageConfigMediaType)",
        "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "size": 123
      },
      "layers": [
        {
          "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
          "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
          "size": 456
        }
      ]
    }
    """

    let manifest = try OrasManifestInfo(rawManifest: rawManifest)

    #expect(manifest.isJeballtoImage == false)
    do {
      try manifest.validateJeballtoV1Layers()
      Issue.record("Expected v1 layer validation to reject the layer media type")
    } catch let error as JeballtoImageManifestError {
      guard case .invalidManifest(let message) = error else {
        Issue.record("Expected invalidManifest, got \(error.localizedDescription)")
        return
      }
      #expect(message.contains("unsupported layer media type"))
    }
  }

  @Test
  func envelopeAcceptsFutureLayerMediaTypeBeforeV1Validation() throws {
    let futureLayerMediaType = "application/vnd.jeballto.vm.bundle.chunk+lz4"
    let rawManifest = """
    {
      "schemaVersion": 2,
      "artifactType": "\(jeballtoImageArtifactType)",
      "config": {
        "mediaType": "\(jeballtoImageConfigMediaType)",
        "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "size": 123
      },
      "layers": [
        {
          "mediaType": "\(futureLayerMediaType)",
          "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
          "size": 456
        }
      ]
    }
    """
    let manifest = try OrasManifestInfo(rawManifest: rawManifest)

    try manifest.validateJeballtoImageEnvelope()

    do {
      try manifest.validateJeballtoImage()
      Issue.record("Expected full v1 validation to reject the future layer media type")
    } catch let error as JeballtoImageManifestError {
      guard case .invalidManifest(let message) = error else {
        Issue.record("Expected invalidManifest, got \(error.localizedDescription)")
        return
      }
      #expect(message.contains("unsupported layer media type \(futureLayerMediaType)"))
    }
  }

  @Test
  func versionedJeballtoManifestIsRejected() throws {
    let rawManifest = """
    {
      "schemaVersion": 2,
      "artifactType": "application/vnd.jeballto.vm.bundle.v2",
      "config": {
        "mediaType": "application/vnd.jeballto.vm.bundle.config.v2+json",
        "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "size": 123
      },
      "layers": [
        {
          "mediaType": "application/vnd.jeballto.vm.bundle.chunk.v1+zstd",
          "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
          "size": 456
        }
      ]
    }
    """

    let manifest = try OrasManifestInfo(rawManifest: rawManifest)

    #expect(manifest.isJeballtoImage == false)
  }

  @Test
  func unrelatedManifestIsNotDetectedAsJeballtoImage() throws {
    let rawManifest = """
    {
      "schemaVersion": 2,
      "artifactType": "application/vnd.other.vm.bundle",
      "config": {
        "mediaType": "application/vnd.unknown.config+json",
        "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "size": 123
      },
      "layers": [
        {
          "mediaType": "application/vnd.oci.image.layer.tar+gzip",
          "digest": "sha256:2222222222222222222222222222222222222222222222222222222222222222",
          "size": 456
        }
      ]
    }
    """

    let manifest = try OrasManifestInfo(rawManifest: rawManifest)

    #expect(manifest.isJeballtoImage == false)
  }
}
