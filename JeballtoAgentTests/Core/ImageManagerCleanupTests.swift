import CryptoKit
import Foundation
import Testing
@testable import JeballtoAgent

// swiftlint:disable file_length type_body_length

private func makeImageManagerTestOrasClient(
  config: ImageConfig,
  temporaryRoot: URL? = nil
) -> OrasClient {
  let isolatedTemporaryRoot = temporaryRoot ?? URL(
    fileURLWithPath: config.imageStorageDir,
    isDirectory: true
  )
  .appendingPathComponent(".test-image-work", isDirectory: true)
  .appendingPathComponent(UUID().uuidString, isDirectory: true)
  return OrasClient(
    config: config,
    temporaryRoot: isolatedTemporaryRoot,
    credentialStore: makeTestRegistryCredentialStore()
  )
}

@Suite(.tags(.core), .serialized)
struct ImageManagerCleanupTests {
  @Test
  func startupCleanupRemovesStaleImageStorageArtifacts() throws {
    try withTemporaryDirectory(prefix: "image-manager-cleanup") { root in
      let imageId = UUID()
      let staleUnpack = "\(root)/.\(imageId.uuidString).bundle.unpack-\(UUID().uuidString)"
      let emptyBundle = "\(root)/\(UUID().uuidString).bundle"
      let pullWorkDir = "\(root)/oras-pull-\(UUID().uuidString)"
      let validBundle = "\(root)/\(UUID().uuidString).bundle"
      let unrelatedHiddenDir = "\(root)/.metadata"
      let hiddenFile = "\(root)/.DS_Store"
      let lookalikeBundle = "\(root)/customer.bundle"
      let lookalikeWorkDir = "\(root)/oras-pull-not-a-uuid"
      let lookalikeUnpack = "\(root)/.customer.bundle.unpack-\(UUID().uuidString)"

      try FileManager.default.createDirectory(atPath: staleUnpack, withIntermediateDirectories: true)
      try Data("partial".utf8).write(to: URL(fileURLWithPath: "\(staleUnpack)/Disk.img"))
      try FileManager.default.createDirectory(atPath: emptyBundle, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(atPath: pullWorkDir, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(atPath: validBundle, withIntermediateDirectories: true)
      try Data("disk".utf8).write(to: URL(fileURLWithPath: "\(validBundle)/Disk.img"))
      try FileManager.default.createDirectory(atPath: unrelatedHiddenDir, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(atPath: lookalikeBundle, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(atPath: lookalikeWorkDir, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(atPath: lookalikeUnpack, withIntermediateDirectories: true)
      try Data("finder".utf8).write(to: URL(fileURLWithPath: hiddenFile))

      let result = ImageManager.cleanupStaleImageStorageArtifacts(
        imageStorageDir: root,
        preserving: [validBundle]
      )

      #expect(result.deleted == 3)
      #expect(result.failed == 0)
      #expect(result.errors.isEmpty)
      #expect(FileManager.default.fileExists(atPath: staleUnpack) == false)
      #expect(FileManager.default.fileExists(atPath: emptyBundle) == false)
      #expect(FileManager.default.fileExists(atPath: pullWorkDir) == false)
      #expect(FileManager.default.fileExists(atPath: validBundle))
      #expect(FileManager.default.fileExists(atPath: unrelatedHiddenDir))
      #expect(FileManager.default.fileExists(atPath: hiddenFile))
      #expect(FileManager.default.fileExists(atPath: lookalikeBundle))
      #expect(FileManager.default.fileExists(atPath: lookalikeWorkDir))
      #expect(FileManager.default.fileExists(atPath: lookalikeUnpack))
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
  func runnableBundleValidationRejectsRequiredFileSymlinks() throws {
    try withTemporaryDirectory(prefix: "image-manager-bundle-symlink") { root in
      let bundlePath = "\(root)/image.bundle"
      let outsideDisk = "\(root)/outside-disk.img"
      try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
      try Data("outside".utf8).write(to: URL(fileURLWithPath: outsideDisk))
      try FileManager.default.createSymbolicLink(
        atPath: "\(bundlePath)/Disk.img",
        withDestinationPath: outsideDisk
      )
      for fileName in ["AuxiliaryStorage", "HardwareModel", "MachineIdentifier"] {
        try Data(fileName.utf8).write(to: URL(fileURLWithPath: "\(bundlePath)/\(fileName)"))
      }

      #expect(throws: VMImagePackagerError.self) {
        try ImageManager.validateRunnableVMBundle(atPath: bundlePath)
      }
    }
  }

  @Test
  func runnableBundleValidationReportsEmptyRequiredFilesAccurately() throws {
    try withTemporaryDirectory(prefix: "image-manager-bundle-empty-file") { root in
      let bundlePath = "\(root)/image.bundle"
      try FileManager.default.createDirectory(atPath: bundlePath, withIntermediateDirectories: true)
      try Data().write(to: URL(fileURLWithPath: "\(bundlePath)/Disk.img"))
      for fileName in ["AuxiliaryStorage", "HardwareModel", "MachineIdentifier"] {
        try Data(fileName.utf8).write(to: URL(fileURLWithPath: "\(bundlePath)/\(fileName)"))
      }

      do {
        try ImageManager.validateRunnableVMBundle(atPath: bundlePath)
        Issue.record("Expected an empty required VM bundle file to be rejected")
      } catch let error as VMImagePackagerError {
        guard case .invalidLayout(let message) = error else {
          Issue.record("Expected invalidLayout, got \(error.localizedDescription)")
          return
        }
        #expect(message.contains("missing, empty, or non-regular"))
        #expect(message.contains("Disk.img"))
      }
    }
  }

  @Test
  func wipeAllImagesRemovesStaleImageStorageArtifactsCreatedAfterStartup() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-wipe-cleanup") { root in
      var config = Config.default
      config.images.imageStorageDir = root
      config.storage.imageIndexPath = "\(root)/images.json"
      let imageWorkRoot = URL(fileURLWithPath: root, isDirectory: true)
        .appendingPathComponent("cache/ImageWork", isDirectory: true)
      let ownSession = imageWorkRoot.appendingPathComponent("sessions/own", isDirectory: true)
      let ownSessionLock = try ImageWorkSessionLock(sessionURL: ownSession)
      let manager = ImageManager(
        imageStore: ImageStore(storagePath: root, indexPath: config.storage.imageIndexPath),
        orasClient: makeImageManagerTestOrasClient(config: config.images, temporaryRoot: ownSession),
        eventBus: EventBus(),
        config: config
      )

      let staleUnpack = "\(root)/.\(UUID().uuidString).bundle.unpack-\(UUID().uuidString)"
      let ownWork = ownSession.appendingPathComponent("operations/pulls/work", isDirectory: true)
      try FileManager.default.createDirectory(atPath: staleUnpack, withIntermediateDirectories: true)
      try Data("partial".utf8).write(to: URL(fileURLWithPath: "\(staleUnpack)/Disk.img"))
      try FileManager.default.createDirectory(at: ownWork, withIntermediateDirectories: true)

      let result = await manager.wipeAllImages()

      #expect(result.deleted == 1)
      #expect(result.failed == 0)
      #expect(result.errors.isEmpty)
      #expect(FileManager.default.fileExists(atPath: staleUnpack) == false)
      #expect(FileManager.default.fileExists(atPath: ownWork.path) == false)
      #expect(FileManager.default.fileExists(atPath: ownSession.appendingPathComponent(".session.lock").path))
      withExtendedLifetime(ownSessionLock) {}
    }
  }

  @Test
  func staleCleanupRemovesOnlyUnindexedManagedImageBundles() throws {
    try withTemporaryDirectory(prefix: "image-manager-unindexed-cleanup") { root in
      let indexedId = UUID()
      let orphanedId = UUID()
      let indexedPath = "\(root)/\(indexedId.uuidString).bundle"
      let orphanedPath = "\(root)/\(orphanedId.uuidString).bundle"
      try makeFakeBundle(at: indexedPath)
      try makeFakeBundle(at: orphanedPath)

      let result = ImageManager.cleanupStaleImageStorageArtifacts(
        imageStorageDir: root,
        preserving: [indexedPath]
      )

      #expect(result.deleted == 1)
      #expect(result.failed == 0)
      #expect(FileManager.default.fileExists(atPath: indexedPath))
      #expect(FileManager.default.fileExists(atPath: orphanedPath) == false)
    }
  }

  @Test
  func startupRemovesACopyInterruptedBeforeItsIndexStage() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-copy-crash") { root in
      let imageStorage = "\(root)/images"
      let indexPath = "\(root)/images.json"
      let initialStore = ImageStore(storagePath: imageStorage, indexPath: indexPath)
      #expect(try await initialStore.count() == 0)

      let orphanedPath = "\(imageStorage)/\(UUID().uuidString).bundle"
      try makeFakeBundle(at: orphanedPath)

      var config = Config.default
      config.images.imageStorageDir = imageStorage
      config.storage.imageIndexPath = indexPath
      let recoveredStore = ImageStore(storagePath: imageStorage, indexPath: indexPath)
      let manager = ImageManager(
        imageStore: recoveredStore,
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config
      )

      try await manager.recoverPendingDeletions()

      #expect(try await recoveredStore.count() == 0)
      #expect(FileManager.default.fileExists(atPath: orphanedPath) == false)
    }
  }

  @Test
  func staleImageStorageCleanupDoesNotTraverseSymbolicRoot() throws {
    try withTemporaryDirectory(prefix: "image-storage-symlink") { root in
      let outside = "\(root)/outside"
      let storageLink = "\(root)/images"
      let bundle = "\(outside)/\(UUID().uuidString).bundle"
      let sentinel = "\(bundle)/keep"
      try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: URL(fileURLWithPath: sentinel))
      try FileManager.default.createSymbolicLink(atPath: storageLink, withDestinationPath: outside)

      let result = ImageManager.cleanupStaleImageStorageArtifacts(imageStorageDir: storageLink)

      #expect(result.deleted == 0)
      #expect(result.failed == 1)
      #expect(FileManager.default.fileExists(atPath: sentinel))
    }
  }

  @Test
  func wipeDoesNotRemoveAnImageWithAnActiveExportReservation() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-wipe-reservation") { root in
      let imageStorage = "\(root)/images"
      let imageId = UUID()
      let bundlePath = "\(imageStorage)/\(imageId.uuidString).bundle"
      let indexPath = "\(root)/images.json"
      let store = ImageStore(storagePath: imageStorage, indexPath: indexPath)
      #expect(try await store.count() == 0)
      try makeFakeBundle(at: bundlePath)
      try await store.addImage(ImageRecord(
        id: imageId,
        reference: "registry.example.com/vm:latest",
        localPath: bundlePath
      ))

      var config = Config.default
      config.images.imageStorageDir = imageStorage
      config.storage.imageIndexPath = indexPath
      let manager = ImageManager(
        imageStore: store,
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config
      )
      let token = try await manager.claimImageExport(imageId)

      let result = await manager.wipeAllImages()

      #expect(result.deleted == 0)
      #expect(result.failed == 1)
      #expect(FileManager.default.fileExists(atPath: bundlePath))
      #expect(try await manager.getImage(id: imageId).id == imageId)
      await manager.releaseImageExport(imageId, token: token)
      try await manager.deleteImage(id: imageId)
    }
  }

  @Test
  func exportClaimRejectsMissingStoreRecordWithoutLeakingAReservation() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-missing-export") { root in
      let imageStorage = "\(root)/images"
      let indexPath = "\(root)/images.json"
      let imageId = UUID()
      let store = ImageStore(storagePath: imageStorage, indexPath: indexPath)
      var config = Config.default
      config.images.imageStorageDir = imageStorage
      config.storage.imageIndexPath = indexPath
      let manager = ImageManager(
        imageStore: store,
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config
      )

      do {
        _ = try await manager.claimImageExport(imageId)
        Issue.record("Expected a missing image export claim to fail")
      } catch let error as ImageManagerError {
        guard case .imageNotFoundById(let missingId) = error else {
          Issue.record("Expected imageNotFoundById, got \(error.localizedDescription)")
          return
        }
        #expect(missingId == imageId)
      }

      let bundlePath = "\(imageStorage)/\(imageId.uuidString).bundle"
      try makeFakeBundle(at: bundlePath)
      try await store.addImage(ImageRecord(
        id: imageId,
        reference: "registry.example.com/vm:latest",
        localPath: bundlePath,
        metadata: ["ownsLocalPath": "true"]
      ))
      await #expect(throws: ImageManagerError.self) {
        _ = try await manager.claimImageExportWithRecord(
          imageId,
          expectedReference: "registry.example.com/vm:stale"
        )
      }
      try await manager.deleteImage(id: imageId)
      #expect(try await store.getImage(id: imageId) == nil)
    }
  }

  @Test
  func corruptIndexPreventsRecoveryAndWipeFromDeletingArbitraryPaths() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-corrupt-index") { root in
      let imageStorage = "\(root)/images"
      let indexPath = "\(root)/images.json"
      let victimPath = "\(root)/victim.bundle"
      try FileManager.default.createDirectory(atPath: imageStorage, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(atPath: victimPath, withIntermediateDirectories: true)
      try Data("must survive".utf8).write(to: URL(fileURLWithPath: "\(victimPath)/payload"))

      var record = ImageRecord(
        reference: "registry.example.com/vm:latest",
        digest: "sha256:" + String(repeating: "a", count: 64),
        localPath: victimPath
      )
      record.metadata["jeballto.deletionPending"] = "true"
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(ImageIndex(images: [record.id: record]))
        .write(to: URL(fileURLWithPath: indexPath))

      var config = Config.default
      config.images.imageStorageDir = imageStorage
      config.storage.imageIndexPath = indexPath
      let manager = ImageManager(
        imageStore: ImageStore(storagePath: imageStorage, indexPath: indexPath),
        orasClient: makeImageManagerTestOrasClient(
          config: config.images,
          temporaryRoot: URL(fileURLWithPath: root)
        ),
        eventBus: EventBus(),
        config: config
      )

      await #expect(throws: ImageStoreError.self) {
        try await manager.recoverPendingDeletions()
      }
      let wipe = await manager.wipeAllImages()

      #expect(FileManager.default.fileExists(atPath: victimPath))
      #expect(wipe.deleted == 0)
      #expect(wipe.failed == 1)
      #expect(wipe.errors.first?.contains("index is unavailable") == true)
    }
  }

  @Test
  func failedDurableDeletionPreventsNewImageExports() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-pending-delete") { root in
      let imageStorage = "\(root)/images"
      let indexPath = "\(root)/images.json"
      let imageId = UUID()
      let managedBundle = "\(imageStorage)/\(imageId.uuidString).bundle"
      let store = ImageStore(storagePath: imageStorage, indexPath: indexPath)
      #expect(try await store.count() == 0)
      try makeFakeBundle(at: managedBundle)
      let record = ImageRecord(
        id: imageId,
        reference: "registry.example.com/vm:latest",
        digest: "sha256:" + String(repeating: "a", count: 64),
        localPath: managedBundle
      )
      try await store.addImage(record)

      var config = Config.default
      config.images.imageStorageDir = imageStorage
      config.storage.imageIndexPath = indexPath
      let manager = ImageManager(
        imageStore: store,
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config
      )

      try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: imageStorage)
      defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: imageStorage)
      }
      await #expect(throws: ImageManagerError.self) {
        try await manager.deleteImage(id: record.id)
      }
      await #expect(throws: ImageManagerError.self) {
        _ = try await manager.claimImageExport(record.id)
      }
      let tombstone = try #require(await store.getImage(id: record.id))
      #expect(tombstone.metadata["jeballto.deletionPending"] == "true")
      #expect(FileManager.default.fileExists(atPath: managedBundle))
    }
  }

  @Test
  func recoveryPreservesIndexedBundleReferencedByEquivalentPath() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-canonical-index") { root in
      let imageStorage = "\(root)/images"
      let indexPath = "\(root)/images.json"
      try FileManager.default.createDirectory(atPath: imageStorage, withIntermediateDirectories: true)
      let imageId = UUID()
      let canonicalBundlePath = "\(imageStorage)/\(imageId.uuidString).bundle"
      let store = ImageStore(storagePath: imageStorage, indexPath: indexPath)
      #expect(try await store.count() == 0)
      try makeFakeBundle(at: canonicalBundlePath)
      try await store.addImage(ImageRecord(
        id: imageId,
        reference: "registry.example.com/repo:tag",
        localPath: "\(imageStorage)/./\(imageId.uuidString).bundle"
      ))

      var config = Config.default
      config.images.imageStorageDir = imageStorage
      config.storage.imageIndexPath = indexPath
      let manager = ImageManager(
        imageStore: store,
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config
      )

      try await manager.recoverPendingDeletions()

      #expect(FileManager.default.fileExists(atPath: canonicalBundlePath))
      #expect(try await manager.getImage(id: imageId).id == imageId)
    }
  }

  @Test
  func updateConfigurationRefreshesImageRuntimeSettings() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-config-update") { root in
      var config = Config.default
      config.images.imageStorageDir = root
      config.images.maxParallelImageBlobTransfers = 1
      config.images.maxParallelImageCompressions = 1
      config.images.maxParallelImageDecompressions = 1
      config.images.maxParallelImageDiskWrites = 1
      config.storage.imageIndexPath = "\(root)/images.json"
      let manager = ImageManager(
        imageStore: ImageStore(storagePath: root, indexPath: config.storage.imageIndexPath),
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config
      )

      var updatedConfig = config
      updatedConfig.images.maxParallelImageBlobTransfers = 7
      updatedConfig.images.maxParallelImageCompressions = 4
      updatedConfig.images.maxParallelImageDecompressions = 4
      updatedConfig.images.maxParallelImageDiskWrites = 2
      updatedConfig.images.insecureRegistries = ["registry.example.com"]
      updatedConfig.images.orasPath = "\(root)/oras"

      await manager.updateConfiguration(updatedConfig)

      let imageConfig = await manager.currentImageConfig()
      #expect(imageConfig.maxParallelImageBlobTransfers == 7)
      #expect(imageConfig.maxParallelImageCompressions == 4)
      #expect(imageConfig.maxParallelImageDecompressions == 4)
      #expect(imageConfig.maxParallelImageDiskWrites == 2)
      #expect(imageConfig.insecureRegistries == ["registry.example.com"])
      #expect(imageConfig.orasPath == "\(root)/oras")
    }
  }

  @Test
  func localCopyFailureCannotPublishTheRegistryManifest() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-precommit-copy") { root in
      let callsPath = "\(root)/oras-calls"
      let orasPath = "\(root)/oras"
      let zstdPath = "\(root)/zstd"
      let sourceBundle = "\(root)/source.bundle"
      let imageStorage = "\(root)/images"
      let indexPath = "\(root)/images.json"
      try makeFakeOras(at: orasPath, callsPath: callsPath)
      try makeImageManagerFakeZstd(at: zstdPath)
      try makeFakeBundle(at: sourceBundle)

      var config = Config.default
      config.images = ImageConfig(
        imageStorageDir: imageStorage,
        orasPath: orasPath,
        zstdPath: zstdPath,
        defaultRegistry: nil,
        insecureRegistries: ["registry.example.com"]
      )
      config.storage.imageIndexPath = indexPath
      let store = ImageStore(storagePath: imageStorage, indexPath: indexPath)
      #expect(try await store.count() == 0)
      let manager = ImageManager(
        imageStore: store,
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config,
        diskImageCapacityValidator: { _, _ in },
        registryAvailabilityChecker: { _, _ in },
        bundleCopyRunner: { _, destinationPath in
          try FileManager.default.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)
          try Data("partial".utf8).write(to: URL(fileURLWithPath: "\(destinationPath)/Disk.img"))
          throw ImageManagerError.pushFailed("simulated local copy failure")
        }
      )

      await #expect(throws: ImageManagerError.self) {
        try await manager.pushImageFromVM(
          reference: "registry.example.com/repo:copy-failure",
          vmBundlePath: sourceBundle,
          resources: .default
        )
      }

      let calls = try String(contentsOfFile: callsPath, encoding: .utf8)
      #expect(calls.contains("manifest push") == false)
      #expect(try await store.count() == 0)
      #expect(try managedImageBundles(at: imageStorage).isEmpty)
    }
  }

  @Test
  func finalizingCopyTimeoutRemovesPartialBundleAndFailsTheTrackedPush() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-copy-timeout") { root in
      let callsPath = "\(root)/oras-calls"
      let orasPath = "\(root)/oras"
      let zstdPath = "\(root)/zstd"
      let sourceBundle = "\(root)/source.bundle"
      let imageStorage = "\(root)/images"
      let indexPath = "\(root)/images.json"
      try makeFakeOras(at: orasPath, callsPath: callsPath)
      try makeImageManagerFakeZstd(at: zstdPath)
      try makeFakeBundle(at: sourceBundle)

      var config = Config.default
      config.images = ImageConfig(
        imageStorageDir: imageStorage,
        orasPath: orasPath,
        zstdPath: zstdPath,
        defaultRegistry: nil,
        insecureRegistries: ["registry.example.com"]
      )
      config.storage.imageIndexPath = indexPath
      let store = ImageStore(storagePath: imageStorage, indexPath: indexPath)
      let manager = ImageManager(
        imageStore: store,
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config,
        diskImageCapacityValidator: { _, _ in },
        registryAvailabilityChecker: { _, _ in },
        bundleCopyRunner: { _, destinationPath in
          try FileManager.default.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)
          try Data("partial".utf8).write(to: URL(fileURLWithPath: "\(destinationPath)/Disk.img"))
          throw OrasError.timeout("simulated finalizing copy timeout")
        }
      )
      let reference = "registry.example.com/repo:copy-timeout"
      let operation = await manager.startImageOperation(kind: .push, reference: reference)
      let progressSink = await manager.progressSink(for: operation.id)

      do {
        let record = try await manager.pushImageFromVM(
          reference: reference,
          vmBundlePath: sourceBundle,
          resources: .default,
          progressSink: progressSink
        )
        await manager.completeImageOperation(operation.id, record: record)
        Issue.record("Expected the finalizing copy to time out")
      } catch {
        await manager.failImageOperation(operation.id, error: error)
      }

      let status = try #require(await manager.getImageOperationStatus(operation.id))
      #expect(status.state == .failed)
      #expect(status.errorCode == .imagePushTimeout)
      #expect(status.stage == .finalizing)
      #expect(status.stageProgress == 0)
      #expect(status.progress == 0.99)
      #expect(status.image == nil)
      #expect(try await store.count() == 0)
      #expect(try managedImageBundles(at: imageStorage).isEmpty)
      let calls = try String(contentsOfFile: callsPath, encoding: .utf8)
      #expect(calls.contains("manifest push") == false)
    }
  }

  @Test
  func cancellingFinalizingCopyRemovesPartialBundleAndCancelsTheTrackedPush() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-copy-cancel") { root in
      let callsPath = "\(root)/oras-calls"
      let orasPath = "\(root)/oras"
      let zstdPath = "\(root)/zstd"
      let sourceBundle = "\(root)/source.bundle"
      let imageStorage = "\(root)/images"
      let indexPath = "\(root)/images.json"
      let copyStarted = AsyncTestSignal()
      try makeFakeOras(at: orasPath, callsPath: callsPath)
      try makeImageManagerFakeZstd(at: zstdPath)
      try makeFakeBundle(at: sourceBundle)

      var config = Config.default
      config.images = ImageConfig(
        imageStorageDir: imageStorage,
        orasPath: orasPath,
        zstdPath: zstdPath,
        defaultRegistry: nil,
        insecureRegistries: ["registry.example.com"]
      )
      config.storage.imageIndexPath = indexPath
      let store = ImageStore(storagePath: imageStorage, indexPath: indexPath)
      let manager = ImageManager(
        imageStore: store,
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config,
        diskImageCapacityValidator: { _, _ in },
        registryAvailabilityChecker: { _, _ in },
        bundleCopyRunner: { _, destinationPath in
          try FileManager.default.createDirectory(atPath: destinationPath, withIntermediateDirectories: true)
          try Data("partial".utf8).write(to: URL(fileURLWithPath: "\(destinationPath)/Disk.img"))
          await copyStarted.signal()
          try await Task.sleep(nanoseconds: UInt64.max)
        }
      )
      let reference = "registry.example.com/repo:copy-cancel"
      let operation = await manager.startImageOperation(kind: .push, reference: reference)
      let progressSink = await manager.progressSink(for: operation.id)
      let pushTask = Task {
        do {
          let record = try await manager.pushImageFromVM(
            reference: reference,
            vmBundlePath: sourceBundle,
            resources: .default,
            progressSink: progressSink
          )
          await manager.completeImageOperation(operation.id, record: record)
        } catch {
          await manager.failImageOperation(operation.id, error: error)
        }
      }

      await copyStarted.wait()
      pushTask.cancel()
      await pushTask.value

      let status = try #require(await manager.getImageOperationStatus(operation.id))
      #expect(status.state == .cancelled)
      #expect(status.errorCode == .imagePushCancelled)
      #expect(status.stage == .finalizing)
      #expect(status.stageProgress == 0)
      #expect(status.progress == 0.99)
      #expect(status.image == nil)
      #expect(try await store.count() == 0)
      #expect(try managedImageBundles(at: imageStorage).isEmpty)
      let calls = try String(contentsOfFile: callsPath, encoding: .utf8)
      #expect(calls.contains("manifest push") == false)
    }
  }

  @Test
  func invalidLocalCopyCannotPublishTheRegistryManifest() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-precommit-validation") { root in
      let callsPath = "\(root)/oras-calls"
      let orasPath = "\(root)/oras"
      let zstdPath = "\(root)/zstd"
      let sourceBundle = "\(root)/source.bundle"
      let imageStorage = "\(root)/images"
      let indexPath = "\(root)/images.json"
      try makeFakeOras(at: orasPath, callsPath: callsPath)
      try makeImageManagerFakeZstd(at: zstdPath)
      try makeFakeBundle(at: sourceBundle)

      var config = Config.default
      config.images = ImageConfig(
        imageStorageDir: imageStorage,
        orasPath: orasPath,
        zstdPath: zstdPath,
        defaultRegistry: nil,
        insecureRegistries: ["registry.example.com"]
      )
      config.storage.imageIndexPath = indexPath
      let store = ImageStore(storagePath: imageStorage, indexPath: indexPath)
      let manager = ImageManager(
        imageStore: store,
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config,
        diskImageCapacityValidator: { path, _ in
          if path.hasPrefix(imageStorage + "/") {
            throw DiskImageInspectionError.inspectionFailed("simulated invalid local copy")
          }
        },
        registryAvailabilityChecker: { _, _ in }
      )

      await #expect(throws: ImageManagerError.self) {
        try await manager.pushImageFromVM(
          reference: "registry.example.com/repo:invalid-copy",
          vmBundlePath: sourceBundle,
          resources: .default
        )
      }

      let calls = try String(contentsOfFile: callsPath, encoding: .utf8)
      #expect(calls.contains("manifest push") == false)
      #expect(try await store.count() == 0)
      let storedBundles = try FileManager.default.contentsOfDirectory(atPath: imageStorage)
        .filter { $0.hasSuffix(".bundle") }
      #expect(storedBundles.isEmpty)
    }
  }

  @Test
  func finalizeFailureAfterManifestCommitReportsThePartialCommitPrecisely() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-partial-commit") { root in
      let callsPath = "\(root)/oras-calls"
      let orasPath = "\(root)/oras"
      let zstdPath = "\(root)/zstd"
      let sourceBundle = "\(root)/source.bundle"
      let imageStorage = "\(root)/images"
      let indexPath = "\(root)/images.json"
      try makeFakeOras(
        at: orasPath,
        callsPath: callsPath,
        replaceIndexWithDirectoryAtManifest: indexPath
      )
      try makeImageManagerFakeZstd(at: zstdPath)
      try makeFakeBundle(at: sourceBundle)

      var config = Config.default
      config.images = ImageConfig(
        imageStorageDir: imageStorage,
        orasPath: orasPath,
        zstdPath: zstdPath,
        defaultRegistry: nil,
        insecureRegistries: ["registry.example.com"]
      )
      config.storage.imageIndexPath = indexPath
      let store = ImageStore(storagePath: imageStorage, indexPath: indexPath)
      #expect(try await store.count() == 0)
      let manager = ImageManager(
        imageStore: store,
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config,
        diskImageCapacityValidator: { _, _ in },
        registryAvailabilityChecker: { _, _ in }
      )

      do {
        _ = try await manager.pushImageFromVM(
          reference: "registry.example.com/repo:partial",
          vmBundlePath: sourceBundle,
          resources: .default
        )
        Issue.record("Expected the sabotaged local index finalization to fail")
      } catch let error as ImageManagerError {
        guard case .pushPartiallyCommitted(let reference, let digest, let reason) = error else {
          Issue.record("Expected pushPartiallyCommitted, got \(error.localizedDescription)")
          return
        }
        #expect(reference == "registry.example.com/repo:partial")
        #expect(digest.hasPrefix("sha256:"))
        #expect(reason.contains("Failed to finalize prepared image index"))
        #expect(error.localizedDescription.contains("Pull the reference to recover the local record"))
      }

      let calls = try String(contentsOfFile: callsPath, encoding: .utf8)
      #expect(calls.contains("manifest push"))
      #expect(try await store.count() == 0)
      let storedBundles = try FileManager.default.contentsOfDirectory(atPath: imageStorage)
        .filter { $0.hasSuffix(".bundle") }
      #expect(storedBundles.isEmpty)
    }
  }

  @Test
  func preparedPushSerializesAConcurrentDeleteUntilTheIndexCommitFinishes() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-index-serialization") { root in
      let orasPath = "\(root)/oras"
      let zstdPath = "\(root)/zstd"
      let manifestStartedPath = "\(root)/manifest-started"
      let manifestReleasePath = "\(root)/manifest-release"
      let sourceBundle = "\(root)/source.bundle"
      let imageStorage = "\(root)/images"
      let indexPath = "\(root)/images.json"
      try makeFakeOras(
        at: orasPath,
        manifestStartedPath: manifestStartedPath,
        manifestReleasePath: manifestReleasePath
      )
      try makeImageManagerFakeZstd(at: zstdPath)
      try makeFakeBundle(at: sourceBundle)

      let deletedId = UUID()
      let deletedBundle = "\(imageStorage)/\(deletedId.uuidString).bundle"
      let store = ImageStore(storagePath: imageStorage, indexPath: indexPath)
      #expect(try await store.count() == 0)
      try makeFakeBundle(at: deletedBundle)
      try await store.addImage(ImageRecord(
        id: deletedId,
        reference: "registry.example.com/repo:delete-me",
        localPath: deletedBundle,
        resources: .default,
        formatVersion: VMImagePackager.currentFormatVersion,
        metadata: ["ownsLocalPath": "true"]
      ))

      var config = Config.default
      config.images = ImageConfig(
        imageStorageDir: imageStorage,
        orasPath: orasPath,
        zstdPath: zstdPath,
        defaultRegistry: nil,
        insecureRegistries: ["registry.example.com"]
      )
      config.storage.imageIndexPath = indexPath
      let manager = ImageManager(
        imageStore: store,
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config,
        diskImageCapacityValidator: { _, _ in },
        registryAvailabilityChecker: { _, _ in }
      )

      let pushTask = Task {
        try await manager.pushImageFromVM(
          reference: "registry.example.com/repo:pushed",
          vmBundlePath: sourceBundle,
          resources: .default
        )
      }
      defer {
        pushTask.cancel()
        try? Data().write(to: URL(fileURLWithPath: manifestReleasePath))
      }
      #expect(await waitUntil(timeout: 3) {
        FileManager.default.fileExists(atPath: manifestStartedPath)
      })

      let deleteTask = Task {
        try await manager.deleteImage(id: deletedId)
      }
      defer { deleteTask.cancel() }
      #expect(await waitUntilAsync(timeout: 3) {
        await manager.imageStoreMutationCountForTesting() == 2
      })
      #expect(try await store.getImage(id: deletedId)?.id == deletedId)
      #expect(FileManager.default.fileExists(atPath: deletedBundle))

      try Data().write(to: URL(fileURLWithPath: manifestReleasePath))
      let pushed = try await pushTask.value
      try await deleteTask.value

      #expect(try await store.getImage(id: deletedId) == nil)
      #expect(try await store.getImage(id: pushed.id)?.id == pushed.id)
      #expect(FileManager.default.fileExists(atPath: deletedBundle) == false)
      #expect(FileManager.default.fileExists(atPath: pushed.localPath))
    }
  }

  @Test
  func repeatedPushRefreshesTheDurableRecordForTheReference() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-push-record") { root in
      let registryPort = try freeLocalTCPPort()
      let registryHost = "127.0.0.1:\(registryPort)"
      let registryServer = SimpleHTTPServer(port: registryPort, host: "127.0.0.1")
      registryServer.get("/v2/") { _ in HTTPResponse(statusCode: 200) }
      try registryServer.start()
      defer { registryServer.stop() }
      try await Task.sleep(nanoseconds: 50_000_000)

      let orasPath = "\(root)/oras"
      let zstdPath = "\(root)/zstd"
      try makeFakeOras(at: orasPath)
      try makeImageManagerFakeZstd(at: zstdPath)

      let bundlePath = "\(root)/source.bundle"
      try makeFakeBundle(at: bundlePath)

      var config = Config.default
      config.images = ImageConfig(
        imageStorageDir: "\(root)/images",
        orasPath: orasPath,
        zstdPath: zstdPath,
        defaultRegistry: nil,
        insecureRegistries: [registryHost]
      )
      config.storage.imageIndexPath = "\(root)/images.json"
      let store = ImageStore(
        storagePath: config.images.imageStorageDir,
        indexPath: config.storage.imageIndexPath
      )
      let manager = ImageManager(
        imageStore: store,
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config,
        diskImageCapacityValidator: { _, _ in },
        registryAvailabilityChecker: { _, _ in }
      )
      let reference = "\(registryHost)/repo:tag"
      let progressRecorder = ImageOperationProgressRecorder()

      let first = try await manager.pushImageFromVM(
        reference: reference,
        vmBundlePath: bundlePath,
        resources: .default,
        progressSink: { update in
          await progressRecorder.append(update)
        }
      )
      let finalizingUpdates = await progressRecorder.all().filter { $0.stage == .finalizing }
      #expect(finalizingUpdates.map(\.stageProgress) == [0, 1])
      #expect(finalizingUpdates.allSatisfy { $0.progress == 0.99 })
      var staleRecord = first
      staleRecord.pushedAt = Date(timeIntervalSince1970: 1)
      staleRecord.resources = VMResources(
        cpuCount: 1,
        memorySize: 2 * 1024 * 1024 * 1024,
        diskSize: 20 * 1024 * 1024 * 1024
      )
      try await store.updateImage(staleRecord)
      try Data().write(to: URL(fileURLWithPath: "\(first.localPath)/Disk.img"))

      let second = try await manager.pushImageFromVM(
        reference: reference,
        vmBundlePath: bundlePath,
        resources: .default
      )
      let images = try await manager.listImages()

      #expect(first.id != second.id)
      #expect(images.count == 1)
      #expect(images.first?.id == second.id)
      #expect(second.localPath != bundlePath)
      #expect(second.formatVersion == VMImagePackager.currentFormatVersion)
      #expect(second.resources == .default)
      #expect(try #require(second.pushedAt) > Date(timeIntervalSince1970: 1))
      #expect(second.metadata["architecture"] == "arm64")
      #expect(FileManager.default.fileExists(atPath: first.localPath) == false)
      #expect(FileManager.default.fileExists(atPath: second.localPath))

      try FileManager.default.removeItem(atPath: bundlePath)
      try ImageManager.validateRunnableVMBundle(atPath: second.localPath)

      try await manager.deleteImage(id: second.id)
      #expect(FileManager.default.fileExists(atPath: second.localPath) == false)
    }
  }

  @Test
  func replacingImageDefersOldBundleDeletionUntilExportReservationIsReleased() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-replacement-reservation") { root in
      let registryPort = try freeLocalTCPPort()
      let registryHost = "127.0.0.1:\(registryPort)"
      let registryServer = SimpleHTTPServer(port: registryPort, host: "127.0.0.1")
      registryServer.get("/v2/") { _ in HTTPResponse(statusCode: 200) }
      try registryServer.start()
      defer { registryServer.stop() }

      let orasPath = "\(root)/oras"
      let zstdPath = "\(root)/zstd"
      try makeFakeOras(at: orasPath)
      try makeImageManagerFakeZstd(at: zstdPath)

      let imageStorage = "\(root)/images"
      try FileManager.default.createDirectory(atPath: imageStorage, withIntermediateDirectories: true)
      let oldId = UUID()
      let oldBundlePath = "\(imageStorage)/\(oldId.uuidString).bundle"
      let sourceBundlePath = "\(root)/source.bundle"
      let store = ImageStore(storagePath: imageStorage, indexPath: "\(root)/images.json")
      #expect(try await store.count() == 0)
      try makeFakeBundle(at: oldBundlePath)
      try makeFakeBundle(at: sourceBundlePath)

      let reference = "\(registryHost)/repo:tag"
      try await store.addImage(ImageRecord(
        id: oldId,
        reference: reference,
        digest: "sha256:" + String(repeating: "b", count: 64),
        localPath: oldBundlePath,
        resources: .default,
        metadata: ["ownsLocalPath": "true"]
      ))

      var config = Config.default
      config.images = ImageConfig(
        imageStorageDir: imageStorage,
        orasPath: orasPath,
        zstdPath: zstdPath,
        defaultRegistry: nil,
        insecureRegistries: [registryHost]
      )
      config.storage.imageIndexPath = "\(root)/images.json"
      let manager = ImageManager(
        imageStore: store,
        orasClient: makeImageManagerTestOrasClient(
          config: config.images,
          temporaryRoot: URL(fileURLWithPath: "\(root)/tmp")
        ),
        eventBus: EventBus(),
        config: config,
        diskImageCapacityValidator: { _, _ in },
        registryAvailabilityChecker: { _, _ in }
      )
      let exportToken = try await manager.claimImageExport(oldId)

      let replacement = try await manager.pushImageFromVM(
        reference: reference,
        vmBundlePath: sourceBundlePath,
        resources: .default,
        timeout: 5
      )

      #expect(replacement.id != oldId)
      #expect(FileManager.default.fileExists(atPath: oldBundlePath))
      await manager.releaseImageExport(oldId, token: exportToken)
      #expect(FileManager.default.fileExists(atPath: oldBundlePath) == false)
      #expect(FileManager.default.fileExists(atPath: replacement.localPath))
      try await manager.deleteImage(id: replacement.id)
    }
  }

  @Test
  func repushedImageRecordSurvivesSourceImageDeletion() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-repush-record") { root in
      let registryPort = try freeLocalTCPPort()
      let registryHost = "127.0.0.1:\(registryPort)"
      let registryServer = SimpleHTTPServer(port: registryPort, host: "127.0.0.1")
      registryServer.get("/v2/") { _ in HTTPResponse(statusCode: 200) }
      try registryServer.start()
      defer { registryServer.stop() }
      try await Task.sleep(nanoseconds: 50_000_000)

      let orasPath = "\(root)/oras"
      let zstdPath = "\(root)/zstd"
      try makeFakeOras(at: orasPath)
      try makeImageManagerFakeZstd(at: zstdPath)

      let bundlePath = "\(root)/source.bundle"
      try makeFakeBundle(at: bundlePath)

      var config = Config.default
      config.images = ImageConfig(
        imageStorageDir: "\(root)/images",
        orasPath: orasPath,
        zstdPath: zstdPath,
        defaultRegistry: nil,
        insecureRegistries: [registryHost]
      )
      config.storage.imageIndexPath = "\(root)/images.json"
      let manager = ImageManager(
        imageStore: ImageStore(storagePath: config.images.imageStorageDir, indexPath: config.storage.imageIndexPath),
        orasClient: makeImageManagerTestOrasClient(config: config.images),
        eventBus: EventBus(),
        config: config,
        diskImageCapacityValidator: { _, _ in },
        registryAvailabilityChecker: { _, _ in }
      )

      let source = try await manager.pushImageFromVM(
        reference: "\(registryHost)/repo:source",
        vmBundlePath: bundlePath,
        resources: .default,
        timeout: 5
      )
      let repushed = try await manager.pushImage(
        reference: "\(registryHost)/repo:repushed",
        imageId: source.id,
        timeout: 5
      )

      #expect(repushed.localPath != source.localPath)
      #expect(repushed.formatVersion == VMImagePackager.currentFormatVersion)
      #expect(repushed.metadata["architecture"] == "arm64")
      #expect(FileManager.default.fileExists(atPath: repushed.localPath))

      try await manager.deleteImage(id: source.id)
      try ImageManager.validateRunnableVMBundle(atPath: repushed.localPath)
      #expect(FileManager.default.fileExists(atPath: source.localPath) == false)

      try await manager.deleteImage(id: repushed.id)
      #expect(FileManager.default.fileExists(atPath: repushed.localPath) == false)
    }
  }

  @Test
  func startupCleanupPreservesActiveSessionsAndRemovesOnlyAnUnlockedSession() throws {
    try withTemporaryDirectory(prefix: "image-work-cleanup") { root in
      let imageWorkRoot = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("ImageWork")
      let activeSession = imageWorkRoot.appendingPathComponent("sessions/active-session", isDirectory: true)
      let otherActiveSession = imageWorkRoot.appendingPathComponent("sessions/other-active", isDirectory: true)
      let inactiveSession = imageWorkRoot.appendingPathComponent("sessions/inactive", isDirectory: true)
      let activeOwner = try ImageWorkSessionLock(sessionURL: activeSession)
      let otherActiveOwner = try ImageWorkSessionLock(sessionURL: otherActiveSession)
      let inactiveOwner = try ImageWorkSessionLock(sessionURL: inactiveSession)
      let activeCache = activeSession.appendingPathComponent("operations/pulls/current", isDirectory: true)
      let otherActiveCache = otherActiveSession.appendingPathComponent("operations/pulls/other", isDirectory: true)
      let inactiveCache = inactiveSession.appendingPathComponent("operations/pulls/stale", isDirectory: true)
      try FileManager.default.createDirectory(at: activeCache, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: otherActiveCache, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: inactiveCache, withIntermediateDirectories: true)
      inactiveOwner.release()

      ImageManager.cleanupImageWorkDirectory(imageWorkRoot: imageWorkRoot, activeSessionURL: activeSession)

      #expect(FileManager.default.fileExists(atPath: activeCache.path))
      #expect(FileManager.default.fileExists(atPath: otherActiveCache.path))
      #expect(FileManager.default.fileExists(atPath: inactiveCache.path) == false)
      withExtendedLifetime((activeOwner, otherActiveOwner)) {}
    }
  }

  @Test
  func maintenanceCleanupClearsOwnedSessionWithoutDeletingActiveForeignSession() throws {
    try withTemporaryDirectory(prefix: "image-work-maintenance") { root in
      let imageWorkRoot = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("ImageWork")
      let ownedSession = imageWorkRoot.appendingPathComponent("sessions/owned", isDirectory: true)
      let foreignSession = imageWorkRoot.appendingPathComponent("sessions/foreign", isDirectory: true)
      let ownedLock = try ImageWorkSessionLock(sessionURL: ownedSession)
      let foreignLock = try ImageWorkSessionLock(sessionURL: foreignSession)
      let ownedWork = ownedSession.appendingPathComponent("operations/push/current", isDirectory: true)
      let foreignWork = foreignSession.appendingPathComponent("operations/push/current", isDirectory: true)
      try FileManager.default.createDirectory(at: ownedWork, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: foreignWork, withIntermediateDirectories: true)

      let errors = ImageManager.cleanupImageWorkForMaintenance(
        imageWorkRoot: imageWorkRoot,
        ownedSessionURL: ownedSession
      )

      #expect(errors.isEmpty)
      #expect(FileManager.default.fileExists(atPath: ownedWork.path) == false)
      #expect(FileManager.default.fileExists(
        atPath: ownedSession.appendingPathComponent(ImageWorkSessionLock.lockFileName).path
      ))
      #expect(FileManager.default.fileExists(
        atPath: ownedSession.appendingPathComponent(ImageWorkSessionLock.ownerLockFileName).path
      ))
      #expect(FileManager.default.fileExists(atPath: foreignWork.path))
      withExtendedLifetime((ownedLock, foreignLock)) {}
    }
  }

  @Test
  func recoveryDefersStaleImageStorageCleanupWhileForeignChildLeaseIsAlive() async throws {
    try await withTemporaryDirectory(prefix: "image-work-storage-lease") { root in
      let imageStorage = "\(root)/images"
      let indexPath = "\(root)/images.json"
      let imageWorkRoot = URL(fileURLWithPath: "\(root)/cache/ImageWork", isDirectory: true)
      let ownedSession = imageWorkRoot.appendingPathComponent("sessions/owned", isDirectory: true)
      let foreignSession = imageWorkRoot.appendingPathComponent("sessions/foreign", isDirectory: true)
      let ownedLock = try ImageWorkSessionLock(sessionURL: ownedSession)
      let foreignOwner = try ImageWorkSessionLock(sessionURL: foreignSession)
      let foreignChild = try ImageWorkChildProcessLease.acquireKernelLeaseForTesting(sessionURL: foreignSession)
      foreignOwner.release()

      let stalePath = "\(imageStorage)/.\(UUID().uuidString).bundle.unpack-\(UUID().uuidString)"
      try FileManager.default.createDirectory(atPath: stalePath, withIntermediateDirectories: true)
      try Data("partial".utf8).write(to: URL(fileURLWithPath: "\(stalePath)/Disk.img"))
      var config = Config.default
      config.images.imageStorageDir = imageStorage
      config.storage.imageIndexPath = indexPath
      let store = ImageStore(storagePath: imageStorage, indexPath: indexPath)
      #expect(try await store.count() == 0)
      let manager = ImageManager(
        imageStore: store,
        orasClient: makeImageManagerTestOrasClient(config: config.images, temporaryRoot: ownedSession),
        eventBus: EventBus(),
        config: config
      )

      try await manager.recoverPendingDeletions()
      #expect(FileManager.default.fileExists(atPath: stalePath))

      foreignChild.release()
      try await manager.recoverPendingDeletions()
      #expect(FileManager.default.fileExists(atPath: stalePath) == false)
      withExtendedLifetime(ownedLock) {}
    }
  }

  @Test
  func startupCleanupPreservesSessionsWithoutASafeLock() throws {
    try withTemporaryDirectory(prefix: "image-work-unsafe-locks") { root in
      let imageWorkRoot = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("ImageWork")
      let activeSession = imageWorkRoot.appendingPathComponent("sessions/active", isDirectory: true)
      let missingLockSession = imageWorkRoot.appendingPathComponent("sessions/missing-lock", isDirectory: true)
      let symbolicLockSession = imageWorkRoot.appendingPathComponent("sessions/symbolic-lock", isDirectory: true)
      let directoryLockSession = imageWorkRoot.appendingPathComponent("sessions/directory-lock", isDirectory: true)
      let activeOwner = try ImageWorkSessionLock(sessionURL: activeSession)
      let outsideLock = URL(fileURLWithPath: root).appendingPathComponent("outside-lock")
      try FileManager.default.createDirectory(at: missingLockSession, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: symbolicLockSession, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: directoryLockSession, withIntermediateDirectories: true)
      try Data("outside".utf8).write(to: outsideLock)
      try FileManager.default.createSymbolicLink(
        at: symbolicLockSession.appendingPathComponent(ImageWorkSessionLock.lockFileName),
        withDestinationURL: outsideLock
      )
      try FileManager.default.createDirectory(
        at: directoryLockSession.appendingPathComponent(ImageWorkSessionLock.lockFileName),
        withIntermediateDirectories: false
      )

      ImageManager.cleanupImageWorkDirectory(imageWorkRoot: imageWorkRoot, activeSessionURL: activeSession)

      #expect(FileManager.default.fileExists(atPath: missingLockSession.path))
      #expect(FileManager.default.fileExists(atPath: symbolicLockSession.path))
      #expect(FileManager.default.fileExists(atPath: directoryLockSession.path))
      #expect(FileManager.default.fileExists(atPath: outsideLock.path))

      ImageManager.cleanupImageWorkDirectory(
        imageWorkRoot: imageWorkRoot,
        activeSessionURL: activeSession,
        exclusiveProcessOwnershipConfirmed: true
      )

      #expect(FileManager.default.fileExists(atPath: missingLockSession.path) == false)
      #expect(FileManager.default.fileExists(atPath: symbolicLockSession.path))
      #expect(FileManager.default.fileExists(atPath: directoryLockSession.path))
      #expect(FileManager.default.fileExists(atPath: outsideLock.path))
      withExtendedLifetime(activeOwner) {}
    }
  }

  @Test
  func startupCleanupPreservesLegacyRootWorkWithoutALivenessLock() throws {
    try withTemporaryDirectory(prefix: "image-root-work-cleanup") { root in
      let imageWorkRoot = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("ImageWork")
      let staleRootWork = imageWorkRoot.appendingPathComponent("oras-tmp-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: staleRootWork, withIntermediateDirectories: true)

      ImageManager.cleanupImageWorkDirectory(
        imageWorkRoot: imageWorkRoot,
        activeSessionURL: imageWorkRoot.appendingPathComponent("sessions/active", isDirectory: true)
      )

      #expect(FileManager.default.fileExists(atPath: staleRootWork.path))

      ImageManager.cleanupImageWorkDirectory(
        imageWorkRoot: imageWorkRoot,
        activeSessionURL: imageWorkRoot.appendingPathComponent("sessions/active", isDirectory: true),
        exclusiveProcessOwnershipConfirmed: true
      )

      #expect(FileManager.default.fileExists(atPath: staleRootWork.path) == false)
    }
  }

  @Test
  func startupCleanupDoesNotTraverseSymbolicImageWorkRoot() throws {
    try withTemporaryDirectory(prefix: "image-work-root-symlink") { root in
      let outside = URL(fileURLWithPath: root).appendingPathComponent("outside", isDirectory: true)
      let imageWorkLink = URL(fileURLWithPath: root).appendingPathComponent("ImageWork", isDirectory: true)
      let stale = outside.appendingPathComponent("oras-tmp-\(UUID().uuidString)", isDirectory: true)
      let sentinel = stale.appendingPathComponent("keep")
      try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: sentinel)
      try FileManager.default.createSymbolicLink(at: imageWorkLink, withDestinationURL: outside)

      ImageManager.cleanupImageWorkDirectory(
        imageWorkRoot: imageWorkLink,
        activeSessionURL: imageWorkLink.appendingPathComponent("sessions/active", isDirectory: true)
      )

      #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }
  }

  @Test
  func startupCleanupDoesNotTraverseSymbolicSessionsDirectory() throws {
    try withTemporaryDirectory(prefix: "image-work-sessions-symlink") { root in
      let imageWorkRoot = URL(fileURLWithPath: root).appendingPathComponent("ImageWork", isDirectory: true)
      let outside = URL(fileURLWithPath: root).appendingPathComponent("outside", isDirectory: true)
      let staleSession = outside.appendingPathComponent("stale", isDirectory: true)
      let sentinel = staleSession.appendingPathComponent("keep")
      try FileManager.default.createDirectory(at: imageWorkRoot, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: staleSession, withIntermediateDirectories: true)
      try Data("keep".utf8).write(to: sentinel)
      try FileManager.default.createSymbolicLink(
        at: imageWorkRoot.appendingPathComponent("sessions", isDirectory: true),
        withDestinationURL: outside
      )

      ImageManager.cleanupImageWorkDirectory(
        imageWorkRoot: imageWorkRoot,
        activeSessionURL: imageWorkRoot.appendingPathComponent("sessions/active", isDirectory: true)
      )

      #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }
  }
}

private func makeFakeOras(
  at path: String,
  callsPath: String? = nil,
  replaceIndexWithDirectoryAtManifest indexPath: String? = nil,
  manifestStartedPath: String? = nil,
  manifestReleasePath: String? = nil
) throws {
  let recordCall = callsPath.map { "printf '%s %s\\n' \"$1\" \"$2\" >> '\($0)'" } ?? ""
  let replaceIndex = indexPath.map {
    "/bin/rm -f '\($0)' && /bin/mkdir -p '\($0)'"
  } ?? ""
  let waitForManifestRelease = if let manifestStartedPath, let manifestReleasePath {
    """
    /usr/bin/touch '\(manifestStartedPath)'
    while [ ! -f '\(manifestReleasePath)' ]; do
      /bin/sleep 0.01
    done
    """
  } else {
    ""
  }
  let script = """
  #!/bin/sh
  \(recordCall)
  if [ "$1" = "blob" ] && [ "$2" = "fetch" ]; then
    echo "404 not found" >&2
    exit 1
  fi
  if [ "$1" = "blob" ] && [ "$2" = "push" ]; then
    media_type=""
    size=""
    target=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --media-type)
          shift
          media_type="$1"
          ;;
        --size)
          shift
          size="$1"
          ;;
        *@sha256:*)
          target="$1"
          ;;
      esac
      shift
    done
    digest="${target##*@}"
    printf '{"mediaType":"%s","digest":"%s","size":%s}\\n' "$media_type" "$digest" "$size"
    exit 0
  fi
  if [ "$1" = "manifest" ] && [ "$2" = "push" ]; then
    \(waitForManifestRelease)
    \(replaceIndex)
    manifest=""
    for argument in "$@"; do
      if [ -f "$argument" ]; then
        manifest="$argument"
      fi
    done
    digest="sha256:$(/usr/bin/shasum -a 256 "$manifest" | /usr/bin/awk '{print $1}')"
    size="$(/usr/bin/stat -f %z "$manifest")"
    printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":%s}\\n' "$digest" "$size"
    exit 0
  fi
  exit 0
  """
  try script.write(toFile: path, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
}

private func makeFakeBundle(at path: String) throws {
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  try Data("aux-\(path)".utf8).write(to: URL(fileURLWithPath: "\(path)/AuxiliaryStorage"))
  try Data("hardware-\(path)".utf8).write(to: URL(fileURLWithPath: "\(path)/HardwareModel"))
  try Data("machine-\(path)".utf8).write(to: URL(fileURLWithPath: "\(path)/MachineIdentifier"))
  try Data("disk-\(path)".utf8).write(to: URL(fileURLWithPath: "\(path)/Disk.img"))
  try Data(path.utf8).write(to: URL(fileURLWithPath: "\(path)/FixtureIdentity"))
}

private func managedImageBundles(at storagePath: String) throws -> [String] {
  try FileManager.default.contentsOfDirectory(atPath: storagePath).filter { $0.hasSuffix(".bundle") }
}
