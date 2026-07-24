import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core), .serialized)
struct VMImageBundleConfigTests: VMImagePackagerTestSupport {
  @Test
  func unsupportedImageFormatVersionIsRejectedBeforeDecodingItsSchema() throws {
    try withTemporaryDirectory(prefix: "vm-image-packager-config") { root in
      let configPath = "\(root)/vm-bundle-config.json"
      let configData = try JSONSerialization.data(withJSONObject: [
        "formatVersion": 2,
        "futureSchema": ["may": "differ from v1"],
      ], options: [.sortedKeys])
      try configData.write(to: URL(fileURLWithPath: configPath))

      let packager = try makePackager(chunkSize: 1024 * 1024)

      do {
        _ = try packager.decodeConfig(atPath: configPath)
        Issue.record("Expected format version 2 to be rejected")
      } catch let error as VMImagePackagerError {
        guard case .unsupportedFormat(let message) = error else {
          Issue.record("Expected unsupportedFormat, got \(error.localizedDescription)")
          return
        }
        #expect(message.contains("version 2 is not supported"))
        #expect(message.contains("Jeballto VM Bundle Format v1"))
      }
    }
  }

  @Test
  func unversionedPreReleaseConfigIsRejectedExplicitly() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-legacy-config") { root in
      let source = "\(root)/source.bundle"
      try makeFakeBundle(at: source)
      let packager = try makePackager(chunkSize: 1024 * 1024)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      try removeConfigFields(["formatVersion"], fromConfigAt: package.configPath)

      do {
        _ = try packager.decodeConfig(atPath: package.configPath)
        Issue.record("Expected an unversioned image config to be rejected")
      } catch let error as VMImagePackagerError {
        guard case .unsupportedFormat(let message) = error else {
          Issue.record("Expected unsupportedFormat, got \(error.localizedDescription)")
          return
        }
        #expect(message.contains("unversioned images created before 1.0.0"))
        #expect(message.contains("Jeballto VM Bundle Format v1"))
      }
    }
  }

  @Test
  func malformedVersionedConfigReportsMissingField() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-missing-field") { root in
      let source = "\(root)/source.bundle"
      try makeFakeBundle(at: source)
      let packager = try makePackager(chunkSize: 1024 * 1024)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      try removeConfigFields(["chunkSize"], fromConfigAt: package.configPath)

      do {
        _ = try packager.decodeConfig(atPath: package.configPath)
        Issue.record("Expected a malformed v1 image config to be rejected")
      } catch let error as VMImagePackagerError {
        guard case .invalidConfig(let message) = error else {
          Issue.record("Expected invalidConfig, got \(error.localizedDescription)")
          return
        }
        #expect(message == "Missing required field 'chunkSize'")
        #expect(error.localizedDescription.contains("couldn’t be read") == false)
      }
    }
  }

  @Test
  func packageRecordsFormatArchitectureAndVMResources() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-metadata") { root in
      let source = "\(root)/source.bundle"
      try makeFakeBundle(at: source)
      let resources = VMResources(
        cpuCount: 6,
        memorySize: 12 * 1024 * 1024 * 1024,
        diskSize: 80 * 1024 * 1024 * 1024
      )
      let packager = try makePackager(chunkSize: 1024 * 1024)

      let package = try await packager.packBundle(
        bundlePath: source,
        stagingRoot: root,
        resources: resources
      )
      let config = try decodePackageConfig(package)

      #expect(config.formatVersion == VMImagePackager.currentFormatVersion)
      #expect(config.architecture == "arm64")
      #expect(config.resources == resources)
    }
  }

  @Test
  func configMissingRequiredBundleFileIsRejectedBeforeUnpack() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-required-files") { root in
      let source = "\(root)/source.bundle"
      let configPath = "\(root)/missing-required-file.json"
      try makeFakeBundle(at: source)
      let packager = try makePackager(chunkSize: 1024 * 1024)
      let package = try await packager.packBundle(bundlePath: source, stagingRoot: root)
      let config = try decodePackageConfig(package)
      let invalidConfig = VMImageBundleConfig(
        formatVersion: config.formatVersion,
        artifactType: config.artifactType,
        architecture: config.architecture,
        resources: config.resources,
        chunkSize: config.chunkSize,
        compression: config.compression,
        files: config.files.filter { $0.path != "MachineIdentifier" }
      )
      try writeConfig(invalidConfig, to: configPath)

      do {
        _ = try packager.decodeConfig(atPath: configPath)
        Issue.record("Expected a missing required VM bundle file to be rejected")
      } catch let error as VMImagePackagerError {
        guard case .invalidConfig(let message) = error else {
          Issue.record("Expected invalidConfig, got \(error.localizedDescription)")
          return
        }
        #expect(message.contains("Required VM bundle files are missing or empty"))
        #expect(message.contains("MachineIdentifier"))
      }
    }
  }

  @Test
  func oversizedImageConfigIsRejectedBeforeDecode() async throws {
    try await withTemporaryDirectory(prefix: "vm-image-packager-large-config") { root in
      let configPath = "\(root)/vm-bundle-config.json"
      try Data(repeating: 0x20, count: Int(VMImagePackager.maxConfigSize + 1))
        .write(to: URL(fileURLWithPath: configPath))
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
  func decodeConfigRejectsCompressedLayerLargerThanTwoGigabytes() throws {
    try withTemporaryDirectory(prefix: "vm-image-packager-layer-limit") { root in
      let configPath = "\(root)/config.json"
      let digest = "sha256:\(String(repeating: "1", count: 64))"
      let chunk = VMImagePackedChunk(
        index: 0,
        offset: 0,
        uncompressedSize: VMImagePackager.minimumChunkSize,
        uncompressedDigest: digest,
        compressedSize: VMImagePackager.maximumCompressedLayerSize + 1,
        compressedDigest: digest,
        layerPath: "chunks/Disk.img.000000.zst",
        zero: false
      )
      let config = VMImageBundleConfig(
        artifactType: jeballtoImageArtifactType,
        chunkSize: VMImagePackager.minimumChunkSize,
        compression: .init(algorithm: "zstd", level: VMImagePackager.defaultCompressionLevel),
        files: [
          VMImagePackedFile(path: "Disk.img", size: VMImagePackager.minimumChunkSize, chunks: [chunk]),
        ]
      )
      try writeConfig(config, to: configPath)
      let packager = try makePackager(chunkSize: VMImagePackager.minimumChunkSize)

      #expect(throws: VMImagePackagerError.self) {
        try packager.decodeConfig(atPath: configPath)
      }
    }
  }

  private func removeConfigFields(_ fields: Set<String>, fromConfigAt path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for field in fields {
      object.removeValue(forKey: field)
    }
    let updated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    try updated.write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

protocol VMImagePackagerTestSupport {}

extension VMImagePackagerTestSupport {
  func makePackager(chunkSize: UInt64, maxParallelChunks: Int = 0) throws -> VMImagePackager {
    let zstdPath = try #require(findZstdPath())
    return VMImagePackager(
      zstdClient: ZstdClient(configuredPath: zstdPath),
      chunkSize: chunkSize,
      maxParallelChunks: maxParallelChunks
    )
  }

  func makeFakeBundle(at path: String) throws {
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

  func decodePackageConfig(_ package: VMImagePackage) throws -> VMImageBundleConfig {
    let data = try Data(contentsOf: URL(fileURLWithPath: package.configPath))
    return try JSONDecoder().decode(VMImageBundleConfig.self, from: data)
  }

  func writeConfig(_ config: VMImageBundleConfig, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(config).write(to: URL(fileURLWithPath: path))
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
}
