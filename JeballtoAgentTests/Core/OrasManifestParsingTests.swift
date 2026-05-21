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
