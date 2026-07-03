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
      config.images.maxParallelImageBlobTransfers = 1
      config.images.maxParallelImageDecompressions = 1
      config.images.maxParallelImageDiskWrites = 1
      config.storage.imageIndexPath = "\(root)/images.json"
      let manager = ImageManager(
        imageStore: ImageStore(storagePath: root, indexPath: config.storage.imageIndexPath),
        orasClient: OrasClient(config: config.images),
        eventBus: EventBus(),
        config: config
      )

      var updatedConfig = config
      updatedConfig.images.maxParallelImageBlobTransfers = 7
      updatedConfig.images.maxParallelImageDecompressions = 4
      updatedConfig.images.maxParallelImageDiskWrites = 2
      updatedConfig.images.insecureRegistries = ["registry.example.com"]
      updatedConfig.images.orasPath = "\(root)/oras"

      await manager.updateConfiguration(updatedConfig)

      let imageConfig = await manager.currentImageConfig()
      #expect(imageConfig.maxParallelImageBlobTransfers == 7)
      #expect(imageConfig.maxParallelImageDecompressions == 4)
      #expect(imageConfig.maxParallelImageDiskWrites == 2)
      #expect(imageConfig.insecureRegistries == ["registry.example.com"])
      #expect(imageConfig.orasPath == "\(root)/oras")
    }
  }

  @Test
  func startupCleanupRemovesSessionScopedImageWorkCache() throws {
    let operationCache = JeballtoCachePaths.imageWork
      .appendingPathComponent("operations/pulls/sha256-test", isDirectory: true)
      .path
    try FileManager.default.createDirectory(atPath: operationCache, withIntermediateDirectories: true)
    try Data("partial blob".utf8).write(to: URL(fileURLWithPath: "\(operationCache)/layer"))

    ImageManager.cleanupImageWorkDirectory()

    #expect(FileManager.default.fileExists(atPath: operationCache) == false)
    #expect(FileManager.default.fileExists(atPath: JeballtoCachePaths.imageWork.path) == false)
  }

  @Test
  func operationDirectoriesAreStableForSameSessionResumeKey() {
    let pullPath = ImageManager.pullOperationDirectory(manifestDigest: "sha256:abc/def")
    let samePullPath = ImageManager.pullOperationDirectory(manifestDigest: "sha256:abc/def")
    let differentPullPath = ImageManager.pullOperationDirectory(manifestDigest: "sha256:xyz")
    let pushPath = ImageManager.pushOperationDirectory(sourceFingerprint: "sha256:source")
    let samePushPath = ImageManager.pushOperationDirectory(sourceFingerprint: "sha256:source")

    #expect(pullPath == samePullPath)
    #expect(pullPath != differentPullPath)
    #expect(pushPath == samePushPath)
    #expect(pullPath.contains("/operations/pulls/"))
    #expect(pushPath.contains("/operations/pushes/"))
  }

  @Test
  func imageOperationDeadlineCancelsWholeOperation() async {
    let startedAt = Date()

    do {
      _ = try await ImageManager.withImageOperationDeadline(
        timeout: 0.05,
        operationName: "test image operation"
      ) {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return true
      }
      Issue.record("Expected image operation deadline to throw")
    } catch let error as OrasError {
      guard case .timeout(let command) = error else {
        Issue.record("Expected OrasError.timeout, got \(error)")
        return
      }
      #expect(command == "test image operation")
    } catch {
      Issue.record("Expected OrasError.timeout, got \(error)")
    }

    #expect(Date().timeIntervalSince(startedAt) < 1)
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

  @Test
  func blobCacheSerializesWorkForSameDigestOnly() async throws {
    let cache = ImageBlobCache()
    let recorder = BlobCacheRecorder()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 3 {
        group.addTask {
          try await cache.withExclusiveAccess(for: "sha256:same") {
            await recorder.beginSameDigestWork()
            try await Task.sleep(nanoseconds: 20_000_000)
            await recorder.endSameDigestWork()
          }
        }
      }

      try await group.waitForAll()
    }

    #expect(await recorder.maxActiveSameDigestWork() == 1)
  }

  @Test
  func operationCacheSerializesWorkForSameKey() async throws {
    let cache = ImageOperationCache()
    let recorder = OperationCacheRecorder()

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0 ..< 3 {
        group.addTask {
          try await cache.withExclusiveAccess(for: "pull:sha256-same") {
            await recorder.beginSameKeyWork()
            try await Task.sleep(nanoseconds: 20_000_000)
            await recorder.endSameKeyWork()
          }
        }
      }

      try await group.waitForAll()
    }

    #expect(await recorder.maxActiveSameKeyWork() == 1)
  }

  @Test
  func operationCacheCancelsWaitingWork() async throws {
    let cache = ImageOperationCache()
    let holderEntered = AsyncTestSignal()
    let holder = Task {
      try await cache.withExclusiveAccess(for: "pull:sha256-same") {
        await holderEntered.signal()
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    await holderEntered.wait()

    let waiter = Task {
      try await cache.withExclusiveAccess(for: "pull:sha256-same") {
        Issue.record("Cancelled waiter should not run cached work")
      }
    }
    try await Task.sleep(nanoseconds: 20_000_000)

    waiter.cancel()
    await #expect(throws: CancellationError.self) {
      try await waiter.value
    }

    holder.cancel()
    _ = try? await holder.value

    let completed = try await cache.withExclusiveAccess(for: "pull:sha256-same") {
      true
    }
    #expect(completed)
  }

  @Test
  func concurrencyLimiterCancelsWaitingWork() async throws {
    let limiter = ImageConcurrencyLimiter(limit: 1)
    let holderEntered = AsyncTestSignal()
    let holder = Task {
      try await limiter.withPermit {
        await holderEntered.signal()
        try await Task.sleep(nanoseconds: 250_000_000)
      }
    }
    await holderEntered.wait()

    let waiter = Task {
      try await limiter.withPermit {
        Issue.record("Cancelled waiter should not receive a permit")
      }
    }
    try await Task.sleep(nanoseconds: 20_000_000)

    waiter.cancel()
    await #expect(throws: CancellationError.self) {
      try await waiter.value
    }

    holder.cancel()
    _ = try? await holder.value

    let completed = try await limiter.withPermit {
      true
    }
    #expect(completed)
  }
}

private actor AsyncTestSignal {
  private var isSignalled = false
  private var continuations: [CheckedContinuation<Void, Never>] = []

  func signal() {
    isSignalled = true
    let waitingContinuations = continuations
    continuations.removeAll()
    for continuation in waitingContinuations {
      continuation.resume()
    }
  }

  func wait() async {
    guard isSignalled == false else { return }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }
}

private actor BlobCacheRecorder {
  private var activeSameDigestWork = 0
  private var maxActiveSameDigestWorkValue = 0

  func beginSameDigestWork() {
    activeSameDigestWork += 1
    maxActiveSameDigestWorkValue = max(maxActiveSameDigestWorkValue, activeSameDigestWork)
  }

  func endSameDigestWork() {
    activeSameDigestWork -= 1
  }

  func maxActiveSameDigestWork() -> Int {
    maxActiveSameDigestWorkValue
  }
}

private actor OperationCacheRecorder {
  private var activeSameKeyWork = 0
  private var maxActiveSameKeyWorkValue = 0

  func beginSameKeyWork() {
    activeSameKeyWork += 1
    maxActiveSameKeyWorkValue = max(maxActiveSameKeyWorkValue, activeSameKeyWork)
  }

  func endSameKeyWork() {
    activeSameKeyWork -= 1
  }

  func maxActiveSameKeyWork() -> Int {
    maxActiveSameKeyWorkValue
  }
}
