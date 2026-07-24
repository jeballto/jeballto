import Foundation
import Testing
@testable import JeballtoAgent

/// Version-gate and backup behaviour for the local image index.
@Suite(.tags(.persistence))
struct ImageStoreVersioningTests {
  @Test
  func abandonedPreparedFileCannotBypassMissingIndexFailClosedBehavior() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-missing-index-prepared") { root in
      let storage = "\(root)/images"
      let indexDirectory = "\(root)/indexes"
      let indexPath = "\(indexDirectory)/images.json"
      let bundle = "\(storage)/\(UUID().uuidString).bundle"
      let stagedPath = "\(indexPath).prepared-\(UUID().uuidString)"
      try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(atPath: indexDirectory, withIntermediateDirectories: true)
      try Data("must survive".utf8).write(to: URL(fileURLWithPath: "\(bundle)/Disk.img"))
      try Data("bounded abandoned stage".utf8).write(to: URL(fileURLWithPath: stagedPath))
      let store = ImageStore(storagePath: storage, indexPath: indexPath)

      await #expect(throws: ImageStoreError.self) {
        _ = try await store.listImages()
      }
      #expect(FileManager.default.fileExists(atPath: "\(bundle)/Disk.img"))
      #expect(FileManager.default.fileExists(atPath: stagedPath) == false)
    }
  }

  @Test(arguments: [1, 999])
  func unsupportedIndexVersionBlocksMutation(version: Int) async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let indexPath = "\(root)/images.json"
      let encoder = JSONEncoder()
      let incompatibleData = try encoder.encode(ImageIndex(version: version))
      try incompatibleData.write(to: URL(fileURLWithPath: indexPath))
      let store = ImageStore(storagePath: root)

      do {
        try await store.addImage(makeRecord(reference: "registry.example.com/vm:new", localPath: root))
        Issue.record("Expected unsupported index version to fail")
      } catch let error as ImageStoreError {
        guard case .unsupportedIndexVersion(let path, let actual, let expected) = error else {
          Issue.record("Expected unsupportedIndexVersion, got \(error.localizedDescription)")
          return
        }
        #expect(path == indexPath)
        #expect(actual == version)
        #expect(expected == 2)
      }
      #expect(try Data(contentsOf: URL(fileURLWithPath: indexPath)) == incompatibleData)
    }
  }

  @Test
  func missingIndexVersionDoesNotRestoreCurrentBackup() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-missing-version") { root in
      let indexPath = "\(root)/images.json"
      let backupPath = indexPath + ".bak"
      let primaryData = try JSONSerialization.data(withJSONObject: ["images": [:]])
      let backupData = try JSONEncoder().encode(ImageIndex.empty)
      try primaryData.write(to: URL(fileURLWithPath: indexPath))
      try backupData.write(to: URL(fileURLWithPath: backupPath))

      do {
        _ = try await ImageStore(storagePath: root).listImages()
        Issue.record("Expected a missing index version to fail")
      } catch let error as ImageStoreError {
        guard case .missingIndexVersion(let path, let expected) = error else {
          Issue.record("Expected missingIndexVersion, got \(error.localizedDescription)")
          return
        }
        #expect(path == indexPath)
        #expect(expected == 2)
      }

      #expect(try Data(contentsOf: URL(fileURLWithPath: indexPath)) == primaryData)
      #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == backupData)
    }
  }

  @Test
  func nonIntegerIndexVersionIsRejectedExplicitly() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-invalid-version") { root in
      let indexPath = "\(root)/images.json"
      let primaryData = try JSONSerialization.data(
        withJSONObject: ["version": "2", "images": [:]]
      )
      try primaryData.write(to: URL(fileURLWithPath: indexPath))

      do {
        _ = try await ImageStore(storagePath: root).listImages()
        Issue.record("Expected a non-integer index version to fail")
      } catch let error as ImageStoreError {
        guard case .invalidIndexVersion(let path, let expected) = error else {
          Issue.record("Expected invalidIndexVersion, got \(error.localizedDescription)")
          return
        }
        #expect(path == indexPath)
        #expect(expected == 2)
      }

      #expect(try Data(contentsOf: URL(fileURLWithPath: indexPath)) == primaryData)
    }
  }

  @Test
  func versionOneIndexIsRejectedBeforeSchemaDecode() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-version-first") { root in
      let indexPath = "\(root)/images.json"
      let incompleteVersionOneData = try JSONSerialization.data(
        withJSONObject: ["version": 1]
      )
      try incompleteVersionOneData.write(to: URL(fileURLWithPath: indexPath))

      do {
        _ = try await ImageStore(storagePath: root).listImages()
        Issue.record("Expected the v1 index to be rejected before schema decoding")
      } catch let error as ImageStoreError {
        guard case .unsupportedIndexVersion(let path, let actual, let expected) = error else {
          Issue.record("Expected unsupportedIndexVersion, got \(error.localizedDescription)")
          return
        }
        #expect(path == indexPath)
        #expect(actual == 1)
        #expect(expected == 2)
      }

      #expect(try Data(contentsOf: URL(fileURLWithPath: indexPath)) == incompleteVersionOneData)
    }
  }

  @Test
  func unsupportedPrimaryIndexVersionDoesNotRollBackToCurrentVersionBackup() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-future-version") { root in
      let indexPath = "\(root)/images.json"
      let backupPath = indexPath + ".bak"
      let backupRecord = makeRecord(reference: "registry.example.com/vm:older", localPath: root)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let backupData = try encoder.encode(ImageIndex(images: [backupRecord.id: backupRecord]))
      try backupData.write(to: URL(fileURLWithPath: backupPath))
      let primaryData = try JSONSerialization.data(
        withJSONObject: ["version": 999, "images": [:]],
        options: [.sortedKeys]
      )
      try primaryData.write(to: URL(fileURLWithPath: indexPath))
      let store = ImageStore(storagePath: root, indexPath: indexPath)

      do {
        _ = try await store.listImages()
        Issue.record("Expected the future image index version to fail closed")
      } catch let error as ImageStoreError {
        #expect(error.localizedDescription.contains("version 999"))
      }

      #expect(try Data(contentsOf: URL(fileURLWithPath: indexPath)) == primaryData)
      #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == backupData)
    }
  }

  @Test
  func incompatibleBackupIsNotOverwrittenByMutation() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-incompatible-backup") { root in
      let indexPath = "\(root)/images.json"
      let backupPath = indexPath + ".bak"
      let store = ImageStore(storagePath: root)
      let existing = makeRecord(reference: "registry.example.com/vm:existing", localPath: root)
      try await store.addImage(existing)

      let primaryData = try Data(contentsOf: URL(fileURLWithPath: indexPath))
      let incompatibleBackup = try JSONEncoder().encode(ImageIndex(version: 1))
      try incompatibleBackup.write(to: URL(fileURLWithPath: backupPath))
      let additional = makeRecord(reference: "registry.example.com/vm:additional", localPath: root)

      do {
        try await store.addImage(additional)
        Issue.record("Expected an incompatible backup to block mutation")
      } catch let error as ImageStoreError {
        guard case .unsupportedIndexVersion(_, let actual, let expected) = error else {
          Issue.record("Expected unsupportedIndexVersion, got \(error.localizedDescription)")
          return
        }
        #expect(actual == 1)
        #expect(expected == 2)
      }

      #expect(try await store.count() == 1)
      #expect(try Data(contentsOf: URL(fileURLWithPath: indexPath)) == primaryData)
      #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == incompatibleBackup)
    }
  }

  @Test
  func missingPrimaryDoesNotRestoreVersionOneBackup() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-incompatible-backup-recovery") { root in
      let indexPath = "\(root)/images.json"
      let backupPath = indexPath + ".bak"
      let incompatibleBackup = try JSONEncoder().encode(ImageIndex(version: 1))
      try incompatibleBackup.write(to: URL(fileURLWithPath: backupPath))

      do {
        _ = try await ImageStore(storagePath: root).listImages()
        Issue.record("Expected a v1 backup to be rejected")
      } catch let error as ImageStoreError {
        guard case .unsupportedIndexVersion(let path, let actual, let expected) = error else {
          Issue.record("Expected unsupportedIndexVersion, got \(error.localizedDescription)")
          return
        }
        #expect(path == backupPath)
        #expect(actual == 1)
        #expect(expected == 2)
      }

      #expect(FileManager.default.fileExists(atPath: indexPath) == false)
      #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == incompatibleBackup)
    }
  }

  @Test
  func oversizedIndexIsRejectedWithoutReadingItAsAnEmptyStore() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-oversized") { root in
      let indexPath = "\(root)/images.json"
      try Data(repeating: 0x20, count: 16 * 1024 * 1024 + 1).write(to: URL(fileURLWithPath: indexPath))
      let store = ImageStore(storagePath: root)

      do {
        _ = try await store.listImages()
        Issue.record("Expected oversized image index to fail")
      } catch let error as ImageStoreError {
        #expect(error.localizedDescription.contains("16MB"))
      }
    }
  }

  @Test
  func unmanagedPersistedLocalPathIsRejectedBeforeRecoveryCanDeleteIt() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-unmanaged") { root in
      let record = ImageRecord(
        reference: "registry.example.com/vm:latest",
        digest: "sha256:" + String(repeating: "a", count: 64),
        localPath: "\(root)/unmanaged.bundle"
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(ImageIndex(images: [record.id: record]))
        .write(to: URL(fileURLWithPath: "\(root)/images.json"))
      let store = ImageStore(storagePath: root)

      do {
        _ = try await store.listImages()
        Issue.record("Expected unmanaged persisted image path to fail validation")
      } catch let error as ImageStoreError {
        #expect(error.localizedDescription.contains("unmanaged local path"))
      }
    }
  }

  @Test
  func managedLookingSymlinkToOutsideStorageIsRejected() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-symlink") { root in
      let storage = "\(root)/images"
      let outside = "\(root)/outside.bundle"
      try FileManager.default.createDirectory(atPath: storage, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
      try Data("must survive".utf8).write(to: URL(fileURLWithPath: "\(outside)/payload"))
      let id = UUID()
      let linkPath = "\(storage)/\(id.uuidString).bundle"
      try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: outside)
      let store = ImageStore(storagePath: storage)
      let record = ImageRecord(
        id: id,
        reference: "registry.example.com/vm:latest",
        localPath: linkPath
      )

      await #expect(throws: ImageStoreError.self) {
        try await store.addImage(record)
      }
      #expect(FileManager.default.fileExists(atPath: "\(outside)/payload"))
    }
  }

  @Test
  func indexAndBackupSymbolicLinksAreRejectedWithoutChangingTheirTargets() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-index-symlinks") { root in
      let storage = "\(root)/images"
      let indexPath = "\(root)/images.json"
      let indexTarget = "\(root)/external-index.json"
      try FileManager.default.createDirectory(atPath: storage, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      try encoder.encode(ImageIndex.empty).write(to: URL(fileURLWithPath: indexTarget))
      let originalIndexTarget = try Data(contentsOf: URL(fileURLWithPath: indexTarget))
      try FileManager.default.createSymbolicLink(atPath: indexPath, withDestinationPath: indexTarget)

      await #expect(throws: ImageStoreError.self) {
        _ = try await ImageStore(storagePath: storage, indexPath: indexPath).listImages()
      }
      #expect(try Data(contentsOf: URL(fileURLWithPath: indexTarget)) == originalIndexTarget)

      try FileManager.default.removeItem(atPath: indexPath)
      try FileManager.default.createSymbolicLink(
        atPath: indexPath,
        withDestinationPath: "\(root)/missing-index"
      )
      await #expect(throws: ImageStoreError.self) {
        _ = try await ImageStore(storagePath: storage, indexPath: indexPath).listImages()
      }
      try FileManager.default.removeItem(atPath: indexPath)

      let store = ImageStore(storagePath: storage, indexPath: indexPath)
      let first = makeRecord(reference: "registry.example.com/first:latest", localPath: storage)
      try await store.addImage(first)

      let backupTarget = "\(root)/external-backup"
      let originalBackupTarget = Data("preserve".utf8)
      try originalBackupTarget.write(to: URL(fileURLWithPath: backupTarget))
      try FileManager.default.removeItem(atPath: indexPath + ".bak")
      try FileManager.default.createSymbolicLink(
        atPath: indexPath + ".bak",
        withDestinationPath: backupTarget
      )
      let second = makeRecord(reference: "registry.example.com/second:latest", localPath: storage)

      await #expect(throws: ImageStoreError.self) {
        try await store.addImage(second)
      }
      #expect(try await store.count() == 1)
      #expect(try Data(contentsOf: URL(fileURLWithPath: backupTarget)) == originalBackupTarget)
    }
  }
}
