import CryptoKit
import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core), .serialized)
struct ImageManagerPullTests {
  private struct ServedBlob {
    let digest: String
    let path: String
  }

  private struct V1ArtifactFixture {
    let manifestDigest: String
    let manifestPath: String
    let blobs: [ServedBlob]
    let zstdPath: String
  }

  @Test
  func artifactContractFailuresAreClassifiedAsInvalidImage() {
    let failures: [any Error] = [
      VMImagePackagerError.invalidConfig("missing field"),
      VMImagePackagerError.invalidLayout("missing Disk.img"),
      VMImagePackagerError.digestMismatch("raw chunk mismatch"),
      VMImagePackagerError.unsupportedCompression("gzip"),
      DiskImageInspectionError.unsupportedFormat("UDIF"),
      DiskImageInspectionError.capacityMismatch(expected: 64, actual: 32),
      OrasBlobValidationError.sizeMismatch(digest: "sha256:expected", expected: 64, actual: 32),
      OrasBlobValidationError.digestMismatch(expected: "sha256:expected", actual: "sha256:actual"),
    ]

    for failure in failures {
      let classified = ImageManager.classifyPullError(failure)
      guard case .invalidImage = classified else {
        Issue.record("Expected invalidImage, got \(classified.localizedDescription)")
        continue
      }
    }

    let localFailure = ImageManager.classifyPullError(
      DiskImageInspectionError.inspectionFailed("diskutil failed")
    )
    guard case .pullFailed = localFailure else {
      Issue.record("Expected local inspection failure to remain pullFailed")
      return
    }

    let unsupportedManifest = ImageManager.classifyPullError(
      JeballtoImageManifestError.unsupportedArtifactType(subject: "image", actual: "application/example")
    )
    guard case .unsupportedImageFormat = unsupportedManifest else {
      Issue.record("Expected unsupported manifest family to map to unsupportedImageFormat")
      return
    }
  }

  @Test
  func v1ManifestLayerContractRejectsExtraAndMissingDuplicateOccurrences() throws {
    let digest = "sha256:\(String(repeating: "a", count: 64))"
    let extraDigest = "sha256:\(String(repeating: "b", count: 64))"
    let chunk = VMImagePackedChunk(
      index: 0,
      offset: 0,
      uncompressedSize: 1,
      uncompressedDigest: digest,
      compressedSize: 1,
      compressedDigest: digest,
      layerPath: "chunks/Disk.img.000000.zst",
      zero: false
    )
    let config = VMImageBundleConfig(
      artifactType: jeballtoImageArtifactType,
      chunkSize: VMImagePackager.minimumChunkSize,
      compression: .init(algorithm: "zstd", level: VMImagePackager.defaultCompressionLevel),
      files: [VMImagePackedFile(path: "Disk.img", size: 1, chunks: [chunk])]
    )
    let matching = OrasDescriptor(mediaType: jeballtoImageChunkMediaType, digest: digest, size: 1)
    let extra = OrasDescriptor(mediaType: jeballtoImageChunkMediaType, digest: extraDigest, size: 1)

    try ImageManager.validateV1ManifestLayerContract([matching], config: config)
    #expect(throws: VMImagePackagerError.self) {
      try ImageManager.validateV1ManifestLayerContract([matching, extra], config: config)
    }

    let duplicateChunk = VMImagePackedChunk(
      index: 1,
      offset: VMImagePackager.minimumChunkSize,
      uncompressedSize: 1,
      uncompressedDigest: digest,
      compressedSize: 1,
      compressedDigest: digest,
      layerPath: "chunks/Disk.img.000001.zst",
      zero: false
    )
    let duplicateConfig = VMImageBundleConfig(
      artifactType: jeballtoImageArtifactType,
      chunkSize: VMImagePackager.minimumChunkSize,
      compression: .init(algorithm: "zstd", level: VMImagePackager.defaultCompressionLevel),
      files: [
        VMImagePackedFile(
          path: "Disk.img",
          size: VMImagePackager.minimumChunkSize + 1,
          chunks: [chunk, duplicateChunk]
        ),
      ]
    )
    #expect(throws: VMImagePackagerError.self) {
      try ImageManager.validateV1ManifestLayerContract([matching], config: duplicateConfig)
    }
  }

  @Test
  func freshLegacyPullReturnsUnsupportedFormatBeforeFetchingLayers() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-legacy-pull") { root in
      let reference = "registry.example.com/macos:v7"
      let configData = try legacyConfigData()
      let configDigest = sha256Digest(configData)
      let manifestDigest = sha256Digest(Data(UUID().uuidString.utf8))
      let layerDigest = "sha256:\(String(repeating: "a", count: 64))"
      let configPath = "\(root)/legacy-config.json"
      let manifestPath = "\(root)/manifest.json"
      let callsPath = "\(root)/oras-calls"
      let orasPath = "\(root)/oras"
      try configData.write(to: URL(fileURLWithPath: configPath))
      try manifestData(
        configDigest: configDigest,
        configSize: UInt64(configData.count),
        layerDigest: layerDigest
      ).write(to: URL(fileURLWithPath: manifestPath))
      try makeLegacyPullOras(
        at: orasPath,
        manifestDigest: manifestDigest,
        manifestPath: manifestPath,
        configPath: configPath,
        callsPath: callsPath
      )

      var config = makeTestConfig(root: root)
      config.images.orasPath = orasPath
      let store = ImageStore(storagePath: config.images.imageStorageDir, indexPath: config.storage.imageIndexPath)
      let manager = makeImageManager(config: config, store: store, temporaryRoot: root)
      let pullWork = ImageManager.pullOperationDirectory(
        manifestDigest: manifestDigest,
        imageWorkSessionURL: imageWorkSessionURL(temporaryRoot: root)
      )
      defer { try? FileManager.default.removeItem(atPath: pullWork) }

      do {
        _ = try await manager.pullImage(reference: reference)
        Issue.record("Expected the legacy image to be rejected")
      } catch let error as ImageManagerError {
        guard case .unsupportedImageFormat(let message) = error else {
          Issue.record("Expected unsupportedImageFormat, got \(error.localizedDescription)")
          return
        }
        #expect(message.contains("unversioned images created before 1.0.0"))
        #expect(message.contains("Jeballto VM Bundle Format v1"))
      }

      let calls = try commandCalls(at: callsPath)
      #expect(calls == ["resolve", "manifest fetch", "blob fetch"])
      #expect(try await store.count() == 0)
    }
  }

  @Test
  func futureFormatIsRejectedFromConfigBeforeV1LayerValidation() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-future-format") { root in
      let reference = "registry.example.com/macos:future"
      let configData = try JSONSerialization.data(withJSONObject: [
        "formatVersion": 2,
        "futureSchema": ["compression": "lz4"],
      ], options: [.sortedKeys])
      let configDigest = sha256Digest(configData)
      let manifestDigest = sha256Digest(Data(UUID().uuidString.utf8))
      let configPath = "\(root)/future-config.json"
      let manifestPath = "\(root)/manifest.json"
      let callsPath = "\(root)/oras-calls"
      let orasPath = "\(root)/oras"
      try configData.write(to: URL(fileURLWithPath: configPath))
      try manifestData(
        configDigest: configDigest,
        configSize: UInt64(configData.count),
        layerDigest: "sha256:\(String(repeating: "a", count: 64))",
        layerMediaType: "application/vnd.jeballto.vm.bundle.chunk+lz4"
      ).write(to: URL(fileURLWithPath: manifestPath))
      try makeLegacyPullOras(
        at: orasPath,
        manifestDigest: manifestDigest,
        manifestPath: manifestPath,
        configPath: configPath,
        callsPath: callsPath
      )

      var config = makeTestConfig(root: root)
      config.images.orasPath = orasPath
      let store = ImageStore(storagePath: config.images.imageStorageDir, indexPath: config.storage.imageIndexPath)
      let manager = makeImageManager(config: config, store: store, temporaryRoot: root)
      defer { try? FileManager.default.removeItem(atPath: ImageManager.pullOperationDirectory(
        manifestDigest: manifestDigest,
        imageWorkSessionURL: imageWorkSessionURL(temporaryRoot: root)
      )) }

      do {
        _ = try await manager.pullImage(reference: reference)
        Issue.record("Expected future image format to be rejected")
      } catch let error as ImageManagerError {
        guard case .unsupportedImageFormat(let message) = error else {
          Issue.record("Expected unsupportedImageFormat, got \(error.localizedDescription)")
          return
        }
        #expect(message.contains("version 2 is not supported"))
      }

      #expect(try commandCalls(at: callsPath) == ["resolve", "manifest fetch", "blob fetch"])
      #expect(try await store.count() == 0)
    }
  }

  @Test
  func matchingLegacyLocalRecordUsesRemoteConfigAsSourceOfTruth() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-legacy-local") { root in
      let reference = "registry.example.com/macos:v7"
      let configData = try legacyConfigData()
      let configDigest = sha256Digest(configData)
      let manifestDigest = sha256Digest(Data(UUID().uuidString.utf8))
      let configPath = "\(root)/legacy-config.json"
      let manifestPath = "\(root)/manifest.json"
      let callsPath = "\(root)/oras-calls"
      let orasPath = "\(root)/oras"
      try configData.write(to: URL(fileURLWithPath: configPath))
      try manifestData(
        configDigest: configDigest,
        configSize: UInt64(configData.count),
        layerDigest: "sha256:\(String(repeating: "a", count: 64))"
      ).write(to: URL(fileURLWithPath: manifestPath))
      try makeLegacyPullOras(
        at: orasPath,
        manifestDigest: manifestDigest,
        manifestPath: manifestPath,
        configPath: configPath,
        callsPath: callsPath
      )

      var config = makeTestConfig(root: root)
      config.images.orasPath = orasPath
      let store = ImageStore(storagePath: config.images.imageStorageDir, indexPath: config.storage.imageIndexPath)
      #expect(try await store.count() == 0)
      let imageId = UUID()
      let bundlePath = "\(config.images.imageStorageDir)/\(imageId.uuidString).bundle"
      try makeRunnableBundle(at: bundlePath)
      try await store.addImage(ImageRecord(
        id: imageId,
        reference: reference,
        digest: manifestDigest,
        localPath: bundlePath,
        resources: nil
      ))
      let manager = makeImageManager(config: config, store: store, temporaryRoot: root)
      defer {
        try? FileManager.default.removeItem(atPath: ImageManager.pullOperationDirectory(
          manifestDigest: manifestDigest,
          imageWorkSessionURL: imageWorkSessionURL(temporaryRoot: root)
        ))
      }

      do {
        _ = try await manager.pullImage(reference: reference)
        Issue.record("Expected the remote legacy config to be rejected")
      } catch let error as ImageManagerError {
        guard case .unsupportedImageFormat(let message) = error else {
          Issue.record("Expected unsupportedImageFormat, got \(error.localizedDescription)")
          return
        }
        #expect(message.contains("unversioned images created before 1.0.0"))
      }

      #expect(try commandCalls(at: callsPath) == ["resolve", "manifest fetch", "blob fetch"])
      #expect(try await store.getImage(id: imageId)?.resources == nil)
    }
  }

  @Test
  func matchingIncompleteLocalRecordIsRepairedFromValidV1RemoteConfig() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-v1-local-repair") { root in
      let reference = "registry.example.com/macos:current"
      let resources = VMResources(
        cpuCount: 6,
        memorySize: 12 * 1024 * 1024 * 1024,
        diskSize: 80 * 1024 * 1024 * 1024
      )
      let fixture = try await makeV1ArtifactFixture(at: root, resources: resources)
      let callsPath = "\(root)/oras-calls"
      let orasPath = "\(root)/oras"
      try makeArtifactPullOras(
        at: orasPath,
        manifestDigest: fixture.manifestDigest,
        manifestPath: fixture.manifestPath,
        repositoryReference: "registry.example.com/macos",
        blobs: fixture.blobs,
        callsPath: callsPath
      )

      var config = makeTestConfig(root: root)
      config.images.orasPath = orasPath
      config.images.zstdPath = fixture.zstdPath
      let store = ImageStore(storagePath: config.images.imageStorageDir, indexPath: config.storage.imageIndexPath)
      #expect(try await store.count() == 0)
      let incompleteId = UUID()
      let incompleteBundlePath = "\(config.images.imageStorageDir)/\(incompleteId.uuidString).bundle"
      try makeRunnableBundle(at: incompleteBundlePath)
      try await store.addImage(ImageRecord(
        id: incompleteId,
        reference: reference,
        digest: fixture.manifestDigest,
        localPath: incompleteBundlePath
      ))
      let manager = makeImageManager(config: config, store: store, temporaryRoot: root)
      let pullWork = ImageManager.pullOperationDirectory(
        manifestDigest: fixture.manifestDigest,
        imageWorkSessionURL: imageWorkSessionURL(temporaryRoot: root)
      )
      try? FileManager.default.removeItem(atPath: pullWork)
      defer { try? FileManager.default.removeItem(atPath: pullWork) }

      let repaired = try await manager.pullImage(reference: reference)

      #expect(repaired.id != incompleteId)
      #expect(repaired.digest == fixture.manifestDigest)
      #expect(repaired.resources == resources)
      #expect(repaired.formatVersion == VMImagePackager.currentFormatVersion)
      #expect(try await store.getImage(id: incompleteId) == nil)
      #expect(try await store.getImage(id: repaired.id) == repaired)
      #expect(FileManager.default.fileExists(atPath: incompleteBundlePath) == false)
      for fileName in requiredVMImageBundleFileNames {
        #expect(FileManager.default.fileExists(atPath: "\(repaired.localPath)/\(fileName)"))
      }

      let calls = try commandCalls(at: callsPath)
      #expect(Array(calls.prefix(2)) == ["resolve", "manifest fetch"])
      #expect(calls.dropFirst(2).allSatisfy { $0 == "blob fetch" })
      #expect(calls.count == fixture.blobs.count + 2)
    }
  }

  @Test
  func cancellingCachedImageValidationDoesNotStartRepairPull() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-cached-cancellation") { root in
      let digest = sha256Digest(Data(UUID().uuidString.utf8))
      let reference = "registry.example.com/macos:current"
      let callsPath = "\(root)/oras-calls"
      let orasPath = "\(root)/oras"
      try makeResolveOnlyOras(at: orasPath, digest: digest, callsPath: callsPath)

      var config = makeTestConfig(root: root)
      config.images.orasPath = orasPath
      let store = ImageStore(storagePath: config.images.imageStorageDir, indexPath: config.storage.imageIndexPath)
      #expect(try await store.count() == 0)
      let imageId = UUID()
      let bundlePath = "\(config.images.imageStorageDir)/\(imageId.uuidString).bundle"
      try makeRunnableBundle(at: bundlePath)
      try await store.addImage(ImageRecord(
        id: imageId,
        reference: reference,
        digest: digest,
        localPath: bundlePath,
        resources: .default,
        formatVersion: VMImagePackager.currentFormatVersion
      ))
      let validatorEntered = AsyncTestSignal()
      let manager = makeImageManager(
        config: config,
        store: store,
        temporaryRoot: root,
        diskImageCapacityValidator: { _, _ in
          await validatorEntered.signal()
          try await Task.sleep(for: .seconds(10))
        }
      )

      let pullTask = Task {
        try await manager.pullImage(reference: reference)
      }
      await validatorEntered.wait()
      pullTask.cancel()
      do {
        _ = try await pullTask.value
        Issue.record("Expected cached image validation to be cancelled")
      } catch is CancellationError {
      } catch {
        Issue.record("Expected CancellationError, got \(error.localizedDescription)")
      }

      #expect(try commandCalls(at: callsPath) == ["resolve"])
    }
  }

  @Test
  func cachedImageIsNotReturnedAfterDeletionStartsDuringValidation() async throws {
    try await withTemporaryDirectory(prefix: "image-manager-cached-deletion") { root in
      let digest = sha256Digest(Data(UUID().uuidString.utf8))
      let reference = "registry.example.com/macos:current"
      let callsPath = "\(root)/oras-calls"
      let orasPath = "\(root)/oras"
      try makeResolveOnlyOras(at: orasPath, digest: digest, callsPath: callsPath)

      var config = makeTestConfig(root: root)
      config.images.orasPath = orasPath
      let store = ImageStore(storagePath: config.images.imageStorageDir, indexPath: config.storage.imageIndexPath)
      #expect(try await store.count() == 0)
      let imageId = UUID()
      let bundlePath = "\(config.images.imageStorageDir)/\(imageId.uuidString).bundle"
      try makeRunnableBundle(at: bundlePath)
      try await store.addImage(ImageRecord(
        id: imageId,
        reference: reference,
        digest: digest,
        localPath: bundlePath,
        resources: .default,
        formatVersion: VMImagePackager.currentFormatVersion
      ))
      let validatorEntered = AsyncTestSignal()
      let releaseValidator = AsyncTestSignal()
      let manager = makeImageManager(
        config: config,
        store: store,
        temporaryRoot: root,
        diskImageCapacityValidator: { _, _ in
          await validatorEntered.signal()
          await releaseValidator.wait()
        }
      )

      let pullTask = Task {
        try await manager.pullImage(reference: reference)
      }
      await validatorEntered.wait()
      let releaseTask = Task<Void, Never> {
        try? await Task.sleep(for: .milliseconds(100))
        await releaseValidator.signal()
      }
      try await manager.deleteImage(id: imageId)
      await releaseTask.value

      do {
        _ = try await pullTask.value
        Issue.record("Expected a cached image being deleted not to be returned")
      } catch let error as ImageManagerError {
        guard case .imageInUse(let message) = error else {
          Issue.record("Expected imageInUse, got \(error.localizedDescription)")
          return
        }
        #expect(message.contains("being deleted"))
      }

      #expect(try commandCalls(at: callsPath) == ["resolve"])
      #expect(try await store.getImage(id: imageId) == nil)
    }
  }

  private func makeImageManager(
    config: Config,
    store: ImageStore,
    temporaryRoot: String,
    diskImageCapacityValidator: @escaping DiskImageCapacityValidator = { _, _ in }
  ) -> ImageManager {
    ImageManager(
      imageStore: store,
      orasClient: OrasClient(
        config: config.images,
        temporaryRoot: URL(fileURLWithPath: "\(temporaryRoot)/oras-work", isDirectory: true),
        credentialStore: makeTestRegistryCredentialStore()
      ),
      eventBus: EventBus(),
      config: config,
      diskImageCapacityValidator: diskImageCapacityValidator,
      registryAvailabilityChecker: { _, _ in }
    )
  }

  private func imageWorkSessionURL(temporaryRoot: String) -> URL {
    URL(fileURLWithPath: "\(temporaryRoot)/oras-work", isDirectory: true)
  }

  private func legacyConfigData() throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "artifactType": jeballtoImageArtifactType,
      "chunkSize": VMImagePackager.defaultChunkSize,
      "compression": [
        "algorithm": "zstd",
        "level": VMImagePackager.defaultCompressionLevel,
      ],
      "files": [],
    ], options: [.sortedKeys])
  }

  private func manifestData(
    configDigest: String,
    configSize: UInt64,
    layerDigest: String,
    layerMediaType: String = jeballtoImageChunkMediaType
  ) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 2,
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "artifactType": jeballtoImageArtifactType,
      "config": [
        "mediaType": jeballtoImageConfigMediaType,
        "digest": configDigest,
        "size": configSize,
      ],
      "layers": [[
        "mediaType": layerMediaType,
        "digest": layerDigest,
        "size": 1,
      ]],
    ], options: [.sortedKeys])
  }

  private func makeLegacyPullOras(
    at path: String,
    manifestDigest: String,
    manifestPath: String,
    configPath: String,
    callsPath: String
  ) throws {
    let script = """
    #!/bin/sh
    if [ "$1" = "resolve" ]; then
      printf 'resolve\n' >> '\(callsPath)'
      printf '%s\n' '\(manifestDigest)'
      exit 0
    fi
    if [ "$1" = "manifest" ] && [ "$2" = "fetch" ]; then
      printf 'manifest fetch\n' >> '\(callsPath)'
      /bin/cat '\(manifestPath)'
      exit 0
    fi
    if [ "$1" = "blob" ] && [ "$2" = "fetch" ]; then
      printf 'blob fetch\n' >> '\(callsPath)'
      /bin/cat '\(configPath)'
      exit 0
    fi
    printf 'unexpected %s %s\n' "$1" "$2" >> '\(callsPath)'
    exit 97
    """
    try writeExecutable(script, to: path)
  }

  private func makeArtifactPullOras(
    at path: String,
    manifestDigest: String,
    manifestPath: String,
    repositoryReference: String,
    blobs: [ServedBlob],
    callsPath: String
  ) throws {
    let blobHandlers = blobs.map { blob in
      """
      if [ "$blob_reference" = '\(repositoryReference)@\(blob.digest)' ]; then
        /bin/cat '\(blob.path)'
        exit 0
      fi
      """
    }.joined(separator: "\n")
    let script = """
    #!/bin/sh
    if [ "$1" = "resolve" ]; then
      printf 'resolve\n' >> '\(callsPath)'
      printf '%s\n' '\(manifestDigest)'
      exit 0
    fi
    if [ "$1" = "manifest" ] && [ "$2" = "fetch" ]; then
      printf 'manifest fetch\n' >> '\(callsPath)'
      /bin/cat '\(manifestPath)'
      exit 0
    fi
    if [ "$1" = "blob" ] && [ "$2" = "fetch" ]; then
      printf 'blob fetch\n' >> '\(callsPath)'
      blob_reference=""
      for argument in "$@"; do
        case "$argument" in
          '\(repositoryReference)'@sha256:*)
            blob_reference="$argument"
            ;;
        esac
      done
    \(blobHandlers)
      exit 95
    fi
    exit 94
    """
    try writeExecutable(script, to: path)
  }

  private func makeV1ArtifactFixture(at root: String, resources: VMResources) async throws -> V1ArtifactFixture {
    let source = "\(root)/remote-source.bundle"
    try makeRunnableBundle(at: source)
    let zstdPath = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/zstd")
      .path
    #expect(FileManager.default.isExecutableFile(atPath: zstdPath))
    let packager = VMImagePackager(
      zstdClient: ZstdClient(configuredPath: zstdPath),
      chunkSize: VMImagePackager.minimumChunkSize
    )
    let package = try await packager.packBundle(
      bundlePath: source,
      stagingRoot: "\(root)/artifact",
      resources: resources
    )
    let configData = try Data(contentsOf: URL(fileURLWithPath: package.configPath))
    let configBlob = ServedBlob(digest: sha256Digest(configData), path: package.configPath)
    let layerBlobs = try package.layers.map { layer in
      let data = try Data(contentsOf: URL(fileURLWithPath: layer.absolutePath))
      return ServedBlob(digest: sha256Digest(data), path: layer.absolutePath)
    }
    let layerDescriptors = try layerBlobs.enumerated().map { index, blob -> [String: Any] in
      let attributes = try FileManager.default.attributesOfItem(atPath: blob.path)
      let size = try #require(attributes[.size] as? NSNumber)
      return [
        "mediaType": package.layers[index].mediaType,
        "digest": blob.digest,
        "size": size.uint64Value,
      ]
    }
    let manifest = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 2,
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "artifactType": jeballtoImageArtifactType,
      "config": [
        "mediaType": jeballtoImageConfigMediaType,
        "digest": configBlob.digest,
        "size": UInt64(configData.count),
      ],
      "layers": layerDescriptors,
    ], options: [.sortedKeys])
    let manifestPath = "\(root)/v1-manifest.json"
    try manifest.write(to: URL(fileURLWithPath: manifestPath))
    return V1ArtifactFixture(
      manifestDigest: sha256Digest(manifest),
      manifestPath: manifestPath,
      blobs: [configBlob] + layerBlobs,
      zstdPath: zstdPath
    )
  }

  private func makeResolveOnlyOras(at path: String, digest: String, callsPath: String) throws {
    let script = """
    #!/bin/sh
    if [ "$1" = "resolve" ]; then
      printf 'resolve\n' >> '\(callsPath)'
      printf '%s\n' '\(digest)'
      exit 0
    fi
    printf '%s%s\n' "$1" "${2:+ $2}" >> '\(callsPath)'
    exit 96
    """
    try writeExecutable(script, to: path)
  }

  private func writeExecutable(_ script: String, to path: String) throws {
    try script.write(toFile: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
  }

  private func makeRunnableBundle(at path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    for file in ["Disk.img", "AuxiliaryStorage", "HardwareModel", "MachineIdentifier"] {
      try Data(file.utf8).write(to: URL(fileURLWithPath: "\(path)/\(file)"))
    }
  }

  private func commandCalls(at path: String) throws -> [String] {
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    return contents.split(separator: "\n").map(String.init)
  }

  private func sha256Digest(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
