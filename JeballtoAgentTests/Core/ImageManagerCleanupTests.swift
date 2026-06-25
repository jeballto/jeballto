import CryptoKit
import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct ImageManagerCleanupTests {
  @Test
  func startupCleanupRemovesStaleImageStorageArtifacts() throws {
    try withTemporaryDirectory(prefix: "image-manager-cleanup") { root in
      let staleUnpack = "\(root)/.A.bundle.unpack-\(UUID().uuidString)"
      let emptyBundle = "\(root)/A.bundle"
      let pullWorkDir = "\(root)/oras-pull-\(UUID().uuidString)"
      let validBundle = "\(root)/B.bundle"
      let unrelatedHiddenDir = "\(root)/.metadata"
      let hiddenFile = "\(root)/.DS_Store"

      try FileManager.default.createDirectory(atPath: staleUnpack, withIntermediateDirectories: true)
      try Data("partial".utf8).write(to: URL(fileURLWithPath: "\(staleUnpack)/Disk.img"))
      try FileManager.default.createDirectory(atPath: emptyBundle, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(atPath: pullWorkDir, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(atPath: validBundle, withIntermediateDirectories: true)
      try Data("disk".utf8).write(to: URL(fileURLWithPath: "\(validBundle)/Disk.img"))
      try FileManager.default.createDirectory(atPath: unrelatedHiddenDir, withIntermediateDirectories: true)
      try Data("finder".utf8).write(to: URL(fileURLWithPath: hiddenFile))

      let result = ImageManager.cleanupStaleImageStorageArtifacts(imageStorageDir: root)

      #expect(result.deleted == 3)
      #expect(result.failed == 0)
      #expect(result.errors.isEmpty)
      #expect(FileManager.default.fileExists(atPath: staleUnpack) == false)
      #expect(FileManager.default.fileExists(atPath: emptyBundle) == false)
      #expect(FileManager.default.fileExists(atPath: pullWorkDir) == false)
      #expect(FileManager.default.fileExists(atPath: validBundle))
      #expect(FileManager.default.fileExists(atPath: unrelatedHiddenDir))
      #expect(FileManager.default.fileExists(atPath: hiddenFile))
    }
  }

  @Test
  func runnableBundleValidationRejectsCompressedLayerDirectory() throws {
    try withTemporaryDirectory(prefix: "image-manager-validation") { root in
      let bundlePath = "\(root)/image.bundle"
      try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
      try Data("compressed".utf8).write(to: URL(fileURLWithPath: "\(bundlePath)/HardwareModel.abc.000000.zst"))
      try Data("compressed".utf8).write(to: URL(fileURLWithPath: "\(bundlePath)/Disk.img.abc.000000.zst"))

      #expect(throws: VMImagePackagerError.self) {
        try ImageManager.validateRunnableVMBundle(atPath: bundlePath)
      }
    }
  }

  @Test
  func runnableBundleValidationAcceptsRequiredBundleFiles() throws {
    try withTemporaryDirectory(prefix: "image-manager-validation-valid") { root in
      let bundlePath = "\(root)/image.bundle"
      try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
      for fileName in ["Disk.img", "AuxiliaryStorage", "HardwareModel", "MachineIdentifier"] {
        try Data(fileName.utf8).write(to: URL(fileURLWithPath: "\(bundlePath)/\(fileName)"))
      }

      try ImageManager.validateRunnableVMBundle(atPath: bundlePath)
    }
  }

  @Test
  func wipeAllImagesRemovesStaleImageStorageArtifactsCreatedAfterStartup() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-wipe-cleanup") { root in
      var config = Config.default
      config.images.imageStorageDir = root
      config.storage.imageIndexPath = "\(root)/images.json"
      let manager = ImageManager(
        imageStore: ImageStore(storagePath: root, indexPath: config.storage.imageIndexPath),
        orasClient: OrasClient(config: config.images),
        eventBus: EventBus(),
        config: config
      )

      let staleUnpack = "\(root)/.A.bundle.unpack-\(UUID().uuidString)"
      try FileManager.default.createDirectory(atPath: staleUnpack, withIntermediateDirectories: true)
      try Data("partial".utf8).write(to: URL(fileURLWithPath: "\(staleUnpack)/Disk.img"))

      let result = await manager.wipeAllImages()

      #expect(result.deleted == 1)
      #expect(result.failed == 0)
      #expect(result.errors.isEmpty)
      #expect(FileManager.default.fileExists(atPath: staleUnpack) == false)
    }
  }

  @Test
  func updateConfigurationRefreshesImageRuntimeSettings() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-config-update") { root in
      var config = Config.default
      config.images.imageStorageDir = root
      config.images.maxParallelImageChunks = 1
      config.storage.imageIndexPath = "\(root)/images.json"
      let manager = ImageManager(
        imageStore: ImageStore(storagePath: root, indexPath: config.storage.imageIndexPath),
        orasClient: OrasClient(config: config.images),
        eventBus: EventBus(),
        config: config
      )

      var updatedConfig = config
      updatedConfig.images.maxParallelImageChunks = 7
      updatedConfig.images.insecureRegistries = ["registry.example.com"]
      updatedConfig.images.orasPath = "\(root)/oras"

      await manager.updateConfiguration(updatedConfig)

      let imageConfig = await manager.currentImageConfig()
      #expect(imageConfig.maxParallelImageChunks == 7)
      #expect(imageConfig.insecureRegistries == ["registry.example.com"])
      #expect(imageConfig.orasPath == "\(root)/oras")
    }
  }

  @Test
  func startupCleanupRemovesSessionScopedImageWorkCache() throws {
    let resumeCache = JeballtoCachePaths.imageWork
      .appendingPathComponent("resume/pulls/sha256-test", isDirectory: true)
      .path
    try FileManager.default.createDirectory(atPath: resumeCache, withIntermediateDirectories: true)
    try Data("partial blob".utf8).write(to: URL(fileURLWithPath: "\(resumeCache)/layer"))

    ImageManager.cleanupImageWorkDirectory()

    #expect(FileManager.default.fileExists(atPath: resumeCache) == false)
    #expect(FileManager.default.fileExists(atPath: JeballtoCachePaths.imageWork.path) == false)
  }

  @Test
  func cachedBlobValidationRequiresMatchingSizeAndDigest() throws {
    try withTemporaryDirectory(prefix: "image-manager-blob-cache") { root in
      let payload = Data("cached blob".utf8)
      let path = "\(root)/blob"
      let digest = "sha256:" + SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
      try payload.write(to: URL(fileURLWithPath: path))

      #expect(ImageManager.cachedBlobIsValid(path: path, expectedDigest: digest, expectedSize: UInt64(payload.count)))
      #expect(ImageManager.cachedBlobIsValid(path: path, expectedDigest: digest, expectedSize: 1) == false)
      #expect(
        ImageManager.cachedBlobIsValid(
          path: path,
          expectedDigest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
          expectedSize: UInt64(payload.count)
        ) == false
      )
    }
  }

  @Test
  func generatedManifestContainsExpectedDescriptors() throws {
    let config = OrasDescriptor(
      mediaType: jeballtoImageConfigMediaType,
      digest: "sha256:1111111111111111111111111111111111111111111111111111111111111111",
      size: 12
    )
    let layer = OrasDescriptor(
      mediaType: jeballtoImageChunkMediaType,
      digest: "sha256:2222222222222222222222222222222222222222222222222222222222222222",
      size: 34
    )

    let data = try ImageManager.ociImageManifestData(configDescriptor: config, layerDescriptors: [layer])
    let rawManifest = try #require(String(data: data, encoding: .utf8))
    let manifest = try OrasManifestInfo(rawManifest: rawManifest)

    #expect(manifest.artifactType == jeballtoImageArtifactType)
    #expect(manifest.configDescriptor == config)
    #expect(manifest.layers == [layer])
  }
}
