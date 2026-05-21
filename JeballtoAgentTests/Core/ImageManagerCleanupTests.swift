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
}
