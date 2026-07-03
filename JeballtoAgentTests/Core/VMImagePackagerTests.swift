import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
// swiftlint:disable:next type_body_length
struct VMImagePackagerTests {
  @Test(
    arguments: [
      (activeProcessorCount: 1, expectedLimit: 1),
      (activeProcessorCount: 2, expectedLimit: 1),
      (activeProcessorCount: 4, expectedLimit: 2),
      (activeProcessorCount: 6, expectedLimit: 3),
      (activeProcessorCount: 9, expectedLimit: 4),
      (activeProcessorCount: 16, expectedLimit: 4),
    ]
  )
  func automaticParallelChunkLimitUsesHalfCpuCountAndCapsAtFour(
    activeProcessorCount: Int,
    expectedLimit: Int
  ) {
    #expect(VMImagePackager.automaticParallelChunkLimit(activeProcessorCount: activeProcessorCount) == expectedLimit)
  }

  @Test
  func packAndUnpackRoundTripsBundleBytes() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager") { root in
      let source = "\(root)/source.bundle"
      let unpacked = "\(root)/unpacked.bundle"
      try makeFakeBundle(at: source)

      let packager = try makePackager(chunkSize: 1024 * 1024, maxParallelChunks: 2)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      try await packager.unpackBundle(
        pulledDirectory: package.stagingDirectory,
        configPath: package.configPath,
        outputBundlePath: unpacked
      )

      try assertBundlesEqual(source, unpacked)
    }
  }

  @Test
  func packBundleReportsCompressionProgressForEachChunk() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-progress") { root in
      let source = "\(root)/source.bundle"
      try makeFakeBundle(at: source)

      let recorder = PackProgressRecorder()
      let packager = try makePackager(chunkSize: 1024 * 1024, maxParallelChunks: 2)
      _ = try await packager.packBundle(
        bundlePath: source,
        stagingRoot: root,
        progressSink: { update in
          await recorder.append(update)
        }
      )

      let updates = await recorder.all()
      let totalUpdate = try #require(updates.first)
      let chunkUpdates = updates.dropFirst()

      #expect(totalUpdate.chunksTotal == 6)
      #expect(totalUpdate.bytesTotal == 3_145_746)
      #expect(chunkUpdates.count == 6)
      #expect(chunkUpdates.reduce(0) { $0 + ($1.chunksCompletedDelta ?? 0) } == 6)
      #expect(chunkUpdates.reduce(UInt64(0)) { $0 + ($1.bytesCompletedDelta ?? 0) } == 3_145_746)
    }
  }

  @Test
  func versionedImageConfigIsRejected() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-config") { root in
      let configPath = "\(root)/vm-bundle-config.json"
      let config = VMImageBundleConfig(
        artifactType: "application/vnd.jeballto.vm.bundle.v2",
        chunkSize: VMImagePackager.defaultChunkSize,
        compression: .init(algorithm: "zstd", level: VMImagePackager.defaultCompressionLevel),
        files: [
          VMImagePackedFile(path: "Disk.img", size: 0, chunks: []),
        ]
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(config).write(to: URL(fileURLWithPath: configPath))

      let packager = try makePackager(chunkSize: 1024 * 1024)

      await #expect(throws: VMImagePackagerError.self) {
        try await packager.unpackBundle(
          pulledDirectory: root,
          configPath: configPath,
          outputBundlePath: "\(root)/unpacked.bundle"
        )
      }
    }
  }

  @Test
  func parallelPackingKeepsChunkAndLayerOrderDeterministic() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-order") { root in
      let source = "\(root)/source.bundle"
      try makeFakeBundle(at: source)

      let packager = try makePackager(chunkSize: 1024 * 1024, maxParallelChunks: 2)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let data = try Data(contentsOf: URL(fileURLWithPath: package.configPath))
      let config = try JSONDecoder().decode(VMImageBundleConfig.self, from: data)
      let disk = try #require(config.files.first { $0.path == "Disk.img" })
      let diskLayerPaths = package.layers.map(\.relativePath).filter { $0.contains("/Disk.img.") }

      #expect(disk.chunks.map(\.index) == [0, 1, 2])
      #expect(diskLayerPaths == disk.chunks.compactMap(\.layerPath))
    }
  }

  @Test
  func zeroChunksAreRecordedWithoutLayerFiles() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-zero") { root in
      let source = "\(root)/source.bundle"
      try makeFakeBundle(at: source)

      let packager = try makePackager(chunkSize: 1024 * 1024)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let data = try Data(contentsOf: URL(fileURLWithPath: package.configPath))
      let config = try JSONDecoder().decode(VMImageBundleConfig.self, from: data)
      let disk = try #require(config.files.first { $0.path == "Disk.img" })

      #expect(disk.chunks.contains { $0.zero && $0.layerPath == nil })
      #expect(package.layers.count == disk.chunks.filter { !$0.zero }.count + 3)
    }
  }

  @Test
  func unpackRejectsZeroChunkWithForgedDigest() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-zero-digest") { root in
      let source = "\(root)/source.bundle"
      let unpacked = "\(root)/unpacked.bundle"
      let corruptConfigPath = "\(root)/corrupt-config.json"
      try makeFakeBundle(at: source)

      let packager = try makePackager(chunkSize: 1024 * 1024)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let config = try decodePackageConfig(package)
      let fileIndex = try #require(config.files.firstIndex { $0.path == "Disk.img" })
      let disk = config.files[fileIndex]
      let zeroChunkIndex = try #require(disk.chunks.firstIndex { $0.zero })
      let zeroChunk = disk.chunks[zeroChunkIndex]
      let corruptChunk = VMImagePackedChunk(
        index: zeroChunk.index,
        offset: zeroChunk.offset,
        uncompressedSize: zeroChunk.uncompressedSize,
        uncompressedDigest: "sha256:\(String(repeating: "1", count: 64))",
        compressedSize: nil,
        compressedDigest: nil,
        layerPath: nil,
        zero: true
      )
      let corruptConfig = replacingChunk(
        in: config,
        fileIndex: fileIndex,
        chunkIndex: zeroChunkIndex,
        with: corruptChunk
      )
      try writeConfig(corruptConfig, to: corruptConfigPath)

      await #expect(throws: VMImagePackagerError.self) {
        try await packager.unpackBundle(
          pulledDirectory: package.stagingDirectory,
          configPath: corruptConfigPath,
          outputBundlePath: unpacked
        )
      }
      #expect(FileManager.default.fileExists(atPath: unpacked) == false)
    }
  }

  @Test
  func unpackRejectsChunkOffsetPastDeclaredFileSize() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-bad-offset") { root in
      let source = "\(root)/source.bundle"
      let unpacked = "\(root)/unpacked.bundle"
      let corruptConfigPath = "\(root)/corrupt-config.json"
      try makeFakeBundle(at: source)

      let packager = try makePackager(chunkSize: 1024 * 1024)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let config = try decodePackageConfig(package)
      let fileIndex = try #require(config.files.firstIndex { !$0.chunks.isEmpty })
      let file = config.files[fileIndex]
      let chunk = try #require(file.chunks.first)
      let corruptChunk = VMImagePackedChunk(
        index: chunk.index,
        offset: file.size + 1,
        uncompressedSize: chunk.uncompressedSize,
        uncompressedDigest: chunk.uncompressedDigest,
        compressedSize: chunk.compressedSize,
        compressedDigest: chunk.compressedDigest,
        layerPath: chunk.layerPath,
        zero: chunk.zero
      )
      let corruptConfig = replacingChunk(in: config, fileIndex: fileIndex, chunkIndex: 0, with: corruptChunk)
      try writeConfig(corruptConfig, to: corruptConfigPath)

      await #expect(throws: VMImagePackagerError.self) {
        try await packager.unpackBundle(
          pulledDirectory: package.stagingDirectory,
          configPath: corruptConfigPath,
          outputBundlePath: unpacked
        )
      }
      #expect(FileManager.default.fileExists(atPath: unpacked) == false)
    }
  }

  @Test
  func unpackRejectsOverlappingChunkLayout() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-overlap") { root in
      let source = "\(root)/source.bundle"
      let unpacked = "\(root)/unpacked.bundle"
      let corruptConfigPath = "\(root)/corrupt-config.json"
      try makeFakeBundle(at: source)

      let packager = try makePackager(chunkSize: 1024 * 1024)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let config = try decodePackageConfig(package)
      let fileIndex = try #require(config.files.firstIndex { $0.path == "Disk.img" && $0.chunks.count > 1 })
      let chunks = config.files[fileIndex].chunks
      let firstChunk = chunks[0]
      let secondChunk = chunks[1]
      let corruptChunk = VMImagePackedChunk(
        index: firstChunk.index,
        offset: firstChunk.offset,
        uncompressedSize: secondChunk.uncompressedSize,
        uncompressedDigest: secondChunk.uncompressedDigest,
        compressedSize: secondChunk.compressedSize,
        compressedDigest: secondChunk.compressedDigest,
        layerPath: secondChunk.layerPath,
        zero: secondChunk.zero
      )
      let corruptConfig = replacingChunk(in: config, fileIndex: fileIndex, chunkIndex: 1, with: corruptChunk)
      try writeConfig(corruptConfig, to: corruptConfigPath)

      await #expect(throws: VMImagePackagerError.self) {
        try await packager.unpackBundle(
          pulledDirectory: package.stagingDirectory,
          configPath: corruptConfigPath,
          outputBundlePath: unpacked
        )
      }
      #expect(FileManager.default.fileExists(atPath: unpacked) == false)
    }
  }

  @Test
  func unpackRejectsZeroChunkWithLayerMetadata() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-zero-layer") { root in
      let source = "\(root)/source.bundle"
      let unpacked = "\(root)/unpacked.bundle"
      let corruptConfigPath = "\(root)/corrupt-config.json"
      try makeFakeBundle(at: source)

      let packager = try makePackager(chunkSize: 1024 * 1024)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let config = try decodePackageConfig(package)
      let fileIndex = try #require(config.files.firstIndex { $0.path == "Disk.img" })
      let disk = config.files[fileIndex]
      let zeroChunkIndex = try #require(disk.chunks.firstIndex { $0.zero })
      let zeroChunk = disk.chunks[zeroChunkIndex]
      let layerChunk = try #require(disk.chunks.first { !$0.zero })
      let corruptChunk = VMImagePackedChunk(
        index: zeroChunk.index,
        offset: zeroChunk.offset,
        uncompressedSize: zeroChunk.uncompressedSize,
        uncompressedDigest: zeroChunk.uncompressedDigest,
        compressedSize: layerChunk.compressedSize,
        compressedDigest: layerChunk.compressedDigest,
        layerPath: layerChunk.layerPath,
        zero: true
      )
      let corruptConfig = replacingChunk(
        in: config,
        fileIndex: fileIndex,
        chunkIndex: zeroChunkIndex,
        with: corruptChunk
      )
      try writeConfig(corruptConfig, to: corruptConfigPath)

      await #expect(throws: VMImagePackagerError.self) {
        try await packager.unpackBundle(
          pulledDirectory: package.stagingDirectory,
          configPath: corruptConfigPath,
          outputBundlePath: unpacked
        )
      }
      #expect(FileManager.default.fileExists(atPath: unpacked) == false)
    }
  }

  @Test
  func unpackRejectsDuplicateLayerPaths() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-duplicate-layer") { root in
      let source = "\(root)/source.bundle"
      let unpacked = "\(root)/unpacked.bundle"
      let corruptConfigPath = "\(root)/corrupt-config.json"
      try makeFakeBundle(at: source)

      let packager = try makePackager(chunkSize: 1024 * 1024)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let config = try decodePackageConfig(package)
      let fileIndex = try #require(config.files.firstIndex { file in
        file.chunks.filter { !$0.zero }.count >= 2
      })
      let chunks = config.files[fileIndex].chunks
      let nonzeroIndexes = chunks.indices.filter { !chunks[$0].zero }
      let firstChunkIndex = try #require(nonzeroIndexes.first)
      let firstChunk = chunks[firstChunkIndex]
      let duplicateChunkIndex = try #require(nonzeroIndexes.dropFirst().first)
      let duplicateChunk = chunks[duplicateChunkIndex]
      let corruptChunk = VMImagePackedChunk(
        index: duplicateChunk.index,
        offset: duplicateChunk.offset,
        uncompressedSize: duplicateChunk.uncompressedSize,
        uncompressedDigest: duplicateChunk.uncompressedDigest,
        compressedSize: duplicateChunk.compressedSize,
        compressedDigest: duplicateChunk.compressedDigest,
        layerPath: firstChunk.layerPath,
        zero: false
      )
      let corruptConfig = replacingChunk(
        in: config,
        fileIndex: fileIndex,
        chunkIndex: duplicateChunkIndex,
        with: corruptChunk
      )
      try writeConfig(corruptConfig, to: corruptConfigPath)

      await #expect(throws: VMImagePackagerError.self) {
        try await packager.unpackBundle(
          pulledDirectory: package.stagingDirectory,
          configPath: corruptConfigPath,
          outputBundlePath: unpacked
        )
      }
      #expect(FileManager.default.fileExists(atPath: unpacked) == false)
    }
  }

  @Test
  func unpackDeletesCompressedLayerFilesAfterWriting() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-cleanup") { root in
      let source = "\(root)/source.bundle"
      let unpacked = "\(root)/unpacked.bundle"
      try makeFakeBundle(at: source)

      let packager = try makePackager(chunkSize: 1024 * 1024)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let layerPaths = package.layers.map(\.absolutePath)
      #expect(layerPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) })

      try await packager.unpackBundle(
        pulledDirectory: package.stagingDirectory,
        configPath: package.configPath,
        outputBundlePath: unpacked
      )

      #expect(layerPaths.allSatisfy { FileManager.default.fileExists(atPath: $0) == false })
      try assertBundlesEqual(source, unpacked)
    }
  }

  @Test
  func resumablePackReusesCachedCompressedChunksWhenSourceDigestMatches() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-resume-reuse") { root in
      let source = "\(root)/source.bundle"
      let stagingDirectory = "\(root)/resume-package"
      try makeFakeBundle(at: source)

      let packager = try makePackager(chunkSize: 1024 * 1024)
      let firstPackage = try await packager.packBundle(bundlePath: source, stagingDirectory: stagingDirectory)
      let firstLayer = try #require(firstPackage.layers.first)
      let firstModifiedAt = try modificationDate(atPath: firstLayer.absolutePath)
      let firstConfig = try decodePackageConfig(firstPackage)

      try await Task.sleep(nanoseconds: 1_100_000_000)
      let secondPackage = try await packager.packBundle(bundlePath: source, stagingDirectory: stagingDirectory)
      let secondLayer = try #require(secondPackage.layers.first)
      let secondModifiedAt = try modificationDate(atPath: secondLayer.absolutePath)
      let secondConfig = try decodePackageConfig(secondPackage)

      #expect(firstLayer.absolutePath == secondLayer.absolutePath)
      #expect(firstModifiedAt == secondModifiedAt)
      #expect(firstConfig == secondConfig)
    }
  }

  @Test
  func resumablePackRecompressesChangedSourceChunk() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-resume-changed") { root in
      let source = "\(root)/source.bundle"
      let stagingDirectory = "\(root)/resume-package"
      try makeFakeBundle(at: source)

      let packager = try makePackager(chunkSize: 1024 * 1024)
      let firstPackage = try await packager.packBundle(bundlePath: source, stagingDirectory: stagingDirectory)
      let firstConfig = try decodePackageConfig(firstPackage)
      let firstAux = try #require(firstConfig.files.first { $0.path == "AuxiliaryStorage" })
      let firstChunk = try #require(firstAux.chunks.first)

      try Data("changed auxiliary storage".utf8).write(to: URL(fileURLWithPath: "\(source)/AuxiliaryStorage"))
      let secondPackage = try await packager.packBundle(bundlePath: source, stagingDirectory: stagingDirectory)
      let secondConfig = try decodePackageConfig(secondPackage)
      let secondAux = try #require(secondConfig.files.first { $0.path == "AuxiliaryStorage" })
      let secondChunk = try #require(secondAux.chunks.first)

      #expect(firstChunk.uncompressedDigest != secondChunk.uncompressedDigest)
      #expect(firstChunk.compressedDigest != secondChunk.compressedDigest)
    }
  }

  @Test
  func corruptChunkFailsDigestValidation() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-corrupt") { root in
      let source = "\(root)/source.bundle"
      let unpacked = "\(root)/unpacked.bundle"
      try makeFakeBundle(at: source)

      let packager = try makePackager(chunkSize: 1024 * 1024)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let firstLayer = try #require(package.layers.first)
      let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: firstLayer.absolutePath))
      try handle.seek(toOffset: 0)
      try handle.write(contentsOf: Data([0x00, 0x01, 0x02, 0x03]))
      try handle.close()

      await #expect(throws: VMImagePackagerError.self) {
        try await packager.unpackBundle(
          pulledDirectory: package.stagingDirectory,
          configPath: package.configPath,
          outputBundlePath: unpacked
        )
      }
      #expect(FileManager.default.fileExists(atPath: unpacked) == false)
    }
  }

  @Test
  func pipelinedUnpackFetchesLayersOnDemandAndSkipsZeroChunks() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-pipeline") { root in
      let source = "\(root)/source.bundle"
      let pulled = "\(root)/pulled"
      let unpacked = "\(root)/unpacked.bundle"
      try makeFakeBundle(at: source)
      try FileManager.default.createDirectory(atPath: pulled, withIntermediateDirectories: true)

      let packager = try makePackager(chunkSize: 1024 * 1024, maxParallelChunks: 2)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let config = try decodePackageConfig(package)
      let nonZeroChunks = config.files.flatMap(\.chunks).filter { !$0.zero }
      let recorder = FetchRecorder()

      try await packager.unpackBundle(
        configPath: package.configPath,
        layerDirectory: pulled,
        outputBundlePath: unpacked,
        fetchLayer: { _, chunk, destinationPath in
          await recorder.record(chunk)
          let layerPath = try #require(chunk.layerPath)
          try FileManager.default.copyItem(
            atPath: "\(package.stagingDirectory)/\(layerPath)",
            toPath: destinationPath
          )
        }
      )

      let fetchedChunks = await recorder.fetchedChunks()
      #expect(fetchedChunks.count == nonZeroChunks.count)
      #expect(fetchedChunks.allSatisfy { !$0.zero })
      try assertBundlesEqual(source, unpacked)
    }
  }

  @Test
  func pipelinedUnpackBoundsConcurrentFetchAndDecompressWork() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-pipeline-limit") { root in
      let source = "\(root)/source.bundle"
      let pulled = "\(root)/pulled"
      let unpacked = "\(root)/unpacked.bundle"
      try makeFakeBundle(at: source)
      try FileManager.default.createDirectory(atPath: pulled, withIntermediateDirectories: true)

      let packager = try makePackager(chunkSize: 1024 * 1024, maxParallelChunks: 2)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let recorder = FetchRecorder()

      try await packager.unpackBundle(
        configPath: package.configPath,
        layerDirectory: pulled,
        outputBundlePath: unpacked,
        fetchLayer: { _, chunk, destinationPath in
          await recorder.beginFetch()
          do {
            let layerPath = try #require(chunk.layerPath)
            try FileManager.default.copyItem(
              atPath: "\(package.stagingDirectory)/\(layerPath)",
              toPath: destinationPath
            )
            try await Task.sleep(nanoseconds: 20_000_000)
            await recorder.endFetch()
          } catch {
            await recorder.endFetch()
            throw error
          }
        }
      )

      let maxActiveFetches = await recorder.maxActiveFetches()
      #expect(maxActiveFetches == 2)
      try assertBundlesEqual(source, unpacked)
    }
  }

  @Test
  func pipelinedUnpackRemovesPartialLayerAndDoesNotPublishBundleOnFetchFailure() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-pipeline-fetch-failure") { root in
      let source = "\(root)/source.bundle"
      let pulled = "\(root)/pulled"
      let unpacked = "\(root)/unpacked.bundle"
      try makeFakeBundle(at: source)
      try FileManager.default.createDirectory(atPath: pulled, withIntermediateDirectories: true)

      let packager = try makePackager(chunkSize: 1024 * 1024, maxParallelChunks: 1)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)

      await #expect(throws: VMImagePackagerError.self) {
        try await packager.unpackBundle(
          configPath: package.configPath,
          layerDirectory: pulled,
          outputBundlePath: unpacked,
          fetchLayer: { _, _, destinationPath in
            try Data([0x01, 0x02, 0x03]).write(to: URL(fileURLWithPath: destinationPath))
            throw VMImagePackagerError.invalidBundle("fetch failed")
          }
        )
      }

      #expect(FileManager.default.fileExists(atPath: unpacked) == false)
      #expect(try regularFiles(in: pulled).isEmpty)
    }
  }

  @Test
  func pipelinedUnpackFailsRawDigestValidationWithoutPublishingBundle() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-pipeline-raw-corrupt") { root in
      let source = "\(root)/source.bundle"
      let pulled = "\(root)/pulled"
      let unpacked = "\(root)/unpacked.bundle"
      let corruptConfigPath = "\(root)/corrupt-config.json"
      try makeFakeBundle(at: source)
      try FileManager.default.createDirectory(atPath: pulled, withIntermediateDirectories: true)

      let packager = try makePackager(chunkSize: 1024 * 1024, maxParallelChunks: 1)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let config = try decodePackageConfig(package)
      let fileIndex = try #require(config.files.firstIndex { file in
        file.chunks.contains { !$0.zero }
      })
      let chunkIndex = try #require(config.files[fileIndex].chunks.firstIndex { !$0.zero })
      let chunk = config.files[fileIndex].chunks[chunkIndex]
      let corruptChunk = VMImagePackedChunk(
        index: chunk.index,
        offset: chunk.offset,
        uncompressedSize: chunk.uncompressedSize,
        uncompressedDigest: "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        compressedSize: chunk.compressedSize,
        compressedDigest: chunk.compressedDigest,
        layerPath: chunk.layerPath,
        zero: chunk.zero
      )
      var files = config.files
      var chunks = files[fileIndex].chunks
      chunks[chunkIndex] = corruptChunk
      files[fileIndex] = VMImagePackedFile(path: files[fileIndex].path, size: files[fileIndex].size, chunks: chunks)
      let corruptConfig = VMImageBundleConfig(
        artifactType: config.artifactType,
        chunkSize: config.chunkSize,
        compression: config.compression,
        files: files
      )
      try JSONEncoder().encode(corruptConfig).write(to: URL(fileURLWithPath: corruptConfigPath))

      await #expect(throws: VMImagePackagerError.self) {
        try await packager.unpackBundle(
          configPath: corruptConfigPath,
          layerDirectory: pulled,
          outputBundlePath: unpacked,
          fetchLayer: { _, chunk, destinationPath in
            let layerPath = try #require(chunk.layerPath)
            try FileManager.default.copyItem(
              atPath: "\(package.stagingDirectory)/\(layerPath)",
              toPath: destinationPath
            )
          }
        )
      }

      #expect(FileManager.default.fileExists(atPath: unpacked) == false)
    }
  }

  @Test
  func packagePushesToOciLayoutAsMultipleLayersAndPullsBack() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-oci") { root in
      let source = "\(root)/source.bundle"
      let pulled = "\(root)/pulled"
      let unpacked = "\(root)/unpacked.bundle"
      let layoutReference = "\(root)/layout:test"
      try makeFakeBundle(at: source)

      let orasPath = try #require(findOrasPath())
      let packager = try makePackager(chunkSize: 1024 * 1024)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)

      var pushArgs = [
        "push",
        "--oci-layout",
        layoutReference,
        "--config",
        "vm-bundle-config.json:\(jeballtoImageConfigMediaType)",
        "--artifact-type",
        jeballtoImageArtifactType,
        "--format",
        "json",
        "--disable-path-validation",
      ]
      pushArgs.append(contentsOf: package.layers.map { "\($0.relativePath):\($0.mediaType)" })
      try runTool(orasPath, arguments: pushArgs, workingDirectory: package.stagingDirectory)

      let manifestData = try runTool(
        orasPath,
        arguments: ["manifest", "fetch", "--oci-layout", layoutReference],
        workingDirectory: nil
      )
      let manifest = try #require(try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
      let artifactType = manifest["artifactType"] as? String
      let layers = try #require(manifest["layers"] as? [[String: Any]])
      #expect(artifactType == jeballtoImageArtifactType)
      #expect(layers.count == package.layers.count)
      #expect(layers.count > 1)

      try FileManager.default.createDirectory(atPath: pulled, withIntermediateDirectories: true)
      try runTool(
        orasPath,
        arguments: [
          "pull",
          "--oci-layout",
          layoutReference,
          "-o",
          pulled,
          "--config",
          "\(pulled)/vm-bundle-config.json",
          "--format",
          "json",
        ],
        workingDirectory: nil
      )

      try await packager.unpackBundle(
        pulledDirectory: pulled,
        configPath: "\(pulled)/vm-bundle-config.json",
        outputBundlePath: unpacked
      )
      try assertBundlesEqual(source, unpacked)
    }
  }

  @Test
  func similarRelativePathsDoNotCollideInLayerNames() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-paths") { root in
      let source = "\(root)/source.bundle"
      let unpacked = "\(root)/unpacked.bundle"
      try FileManager.default.createDirectory(atPath: "\(source)/a", withIntermediateDirectories: true)
      try Data("nested".utf8).write(to: URL(fileURLWithPath: "\(source)/a/b"))
      try Data("flat".utf8).write(to: URL(fileURLWithPath: "\(source)/a__b"))

      let packager = try makePackager(chunkSize: 1024 * 1024)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let layerPaths = package.layers.map(\.relativePath)
      #expect(Set(layerPaths).count == layerPaths.count)

      try await packager.unpackBundle(
        pulledDirectory: package.stagingDirectory,
        configPath: package.configPath,
        outputBundlePath: unpacked
      )
      let nested = try Data(contentsOf: URL(fileURLWithPath: "\(unpacked)/a/b"))
      let flat = try Data(contentsOf: URL(fileURLWithPath: "\(unpacked)/a__b"))
      #expect(nested == Data("nested".utf8))
      #expect(flat == Data("flat".utf8))
    }
  }

  private func makePackager(chunkSize: UInt64, maxParallelChunks: Int = 0) throws -> VMImagePackager {
    let zstdPath = try #require(findZstdPath())
    return VMImagePackager(
      zstdClient: ZstdClient(configuredPath: zstdPath),
      chunkSize: chunkSize,
      maxParallelChunks: maxParallelChunks
    )
  }

  private func findOrasPath() -> String? {
    let repoOras = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/oras")
      .path
    for path in [repoOras, "/opt/homebrew/bin/oras", "/usr/local/bin/oras"]
      where FileManager.default.fileExists(atPath: path)
    {
      return path
    }
    return nil
  }

  private func findZstdPath() -> String? {
    let repoZstd = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/zstd")
      .path
    for path in [repoZstd, "/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
      where FileManager.default.fileExists(atPath: path)
    {
      return path
    }
    return nil
  }

  private func makeFakeBundle(at path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    try Data("aux".utf8).write(to: URL(fileURLWithPath: "\(path)/AuxiliaryStorage"))
    try Data("hardware".utf8).write(to: URL(fileURLWithPath: "\(path)/HardwareModel"))
    try Data("machine".utf8).write(to: URL(fileURLWithPath: "\(path)/MachineIdentifier"))

    FileManager.default.createFile(atPath: "\(path)/Disk.img", contents: nil)
    let disk = try FileHandle(forWritingTo: URL(fileURLWithPath: "\(path)/Disk.img"))
    try disk.write(contentsOf: Data(repeating: 0x41, count: 1024 * 1024))
    try disk.seek(toOffset: 2 * 1024 * 1024)
    try disk.write(contentsOf: Data(repeating: 0x42, count: 1024 * 1024))
    try disk.truncate(atOffset: 3 * 1024 * 1024)
    try disk.close()
  }

  private func assertBundlesEqual(_ lhs: String, _ rhs: String) throws {
    for file in ["AuxiliaryStorage", "HardwareModel", "MachineIdentifier", "Disk.img"] {
      let lhsData = try Data(contentsOf: URL(fileURLWithPath: "\(lhs)/\(file)"))
      let rhsData = try Data(contentsOf: URL(fileURLWithPath: "\(rhs)/\(file)"))
      #expect(lhsData == rhsData)
    }
  }

  private func decodePackageConfig(_ package: VMImagePackage) throws -> VMImageBundleConfig {
    let data = try Data(contentsOf: URL(fileURLWithPath: package.configPath))
    return try JSONDecoder().decode(VMImageBundleConfig.self, from: data)
  }

  private func writeConfig(_ config: VMImageBundleConfig, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(config).write(to: URL(fileURLWithPath: path))
  }

  private func replacingChunk(
    in config: VMImageBundleConfig,
    fileIndex: Int,
    chunkIndex: Int,
    with chunk: VMImagePackedChunk
  ) -> VMImageBundleConfig {
    var files = config.files
    var chunks = files[fileIndex].chunks
    chunks[chunkIndex] = chunk
    files[fileIndex] = VMImagePackedFile(path: files[fileIndex].path, size: files[fileIndex].size, chunks: chunks)
    return VMImageBundleConfig(
      artifactType: config.artifactType,
      chunkSize: config.chunkSize,
      compression: config.compression,
      files: files
    )
  }

  private func modificationDate(atPath path: String) throws -> Date {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    return try #require(attrs[.modificationDate] as? Date)
  }

  private func regularFiles(in path: String) throws -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: path) else { return [] }
    var files: [String] = []
    while let item = enumerator.nextObject() as? String {
      let itemPath = "\(path)/\(item)"
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDirectory), !isDirectory.boolValue {
        files.append(item)
      }
    }
    return files
  }

  private actor FetchRecorder {
    private var chunks: [VMImagePackedChunk] = []
    private var active = 0
    private var maxActive = 0

    func record(_ chunk: VMImagePackedChunk) {
      chunks.append(chunk)
    }

    func beginFetch() {
      active += 1
      maxActive = max(maxActive, active)
    }

    func endFetch() {
      active -= 1
    }

    func fetchedChunks() -> [VMImagePackedChunk] {
      chunks
    }

    func maxActiveFetches() -> Int {
      maxActive
    }
  }

  @discardableResult
  private func runTool(_ path: String, arguments: [String], workingDirectory: String?) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if let workingDirectory {
      process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()

    let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    if process.terminationStatus != 0 {
      let errorText = String(data: stderr, encoding: .utf8) ?? ""
      throw VMImagePackagerError.invalidBundle("\(path) failed: \(errorText)")
    }
    return stdout
  }
}

private actor PackProgressRecorder {
  private var updates: [VMImagePackProgressUpdate] = []

  func append(_ update: VMImagePackProgressUpdate) {
    updates.append(update)
  }

  func all() -> [VMImagePackProgressUpdate] {
    updates
  }
}
