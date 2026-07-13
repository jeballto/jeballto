import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.persistence))
struct ImageStoreTests {
  private func makeRecord(
    id: UUID = UUID(),
    reference: String,
    localPath: String,
    pulledAt: Date? = nil,
    formatVersion: Int = VMImagePackager.currentFormatVersion
  ) -> ImageRecord {
    ImageRecord(
      id: id,
      reference: reference,
      localPath: "\(localPath)/\(id.uuidString).bundle",
      pulledAt: pulledAt,
      formatVersion: formatVersion
    )
  }

  @Test
  func addGetRemoveLifecycle() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let store = ImageStore(storagePath: root)
      let id = UUID()
      let record = makeRecord(id: id, reference: "registry.example.com/vm:latest", localPath: root)

      try await store.addImage(record)
      #expect(try await store.count() == 1)

      let loaded = try await store.getImage(id: id)
      #expect(loaded?.reference == "registry.example.com/vm:latest")

      try await store.removeImage(id: id)
      let remainingCount = try await store.count()
      #expect(remainingCount == 0)
      #expect(try await store.getImage(id: id) == nil)
    }
  }

  @Test
  func firstLoadPersistsAnEmptyBaselineBeforeManagedBundlesCanBeCreated() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-empty-baseline") { root in
      let indexPath = "\(root)/images.json"
      let store = ImageStore(storagePath: root, indexPath: indexPath)

      let initialCount = try await store.count()
      #expect(initialCount == 0)
      #expect(FileManager.default.fileExists(atPath: indexPath))

      let reloaded = ImageStore(storagePath: root, indexPath: indexPath)
      let reloadedCount = try await reloaded.count()
      #expect(reloadedCount == 0)
    }
  }

  @Test
  func listImagesSortedByLatestActivityDescending() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let store = ImageStore(storagePath: root)
      let old = makeRecord(reference: "old:latest", localPath: root, pulledAt: Date(timeIntervalSince1970: 1))
      let new = makeRecord(reference: "new:latest", localPath: root, pulledAt: Date(timeIntervalSince1970: 2))
      let repushedId = UUID()
      let repushed = ImageRecord(
        id: repushedId,
        reference: "repushed:latest",
        localPath: "\(root)/\(repushedId.uuidString).bundle",
        pulledAt: Date(timeIntervalSince1970: 1),
        pushedAt: Date(timeIntervalSince1970: 3)
      )
      let noPull = makeRecord(reference: "nopull:latest", localPath: root, pulledAt: nil)

      try await store.addImage(old)
      try await store.addImage(new)
      try await store.addImage(repushed)
      try await store.addImage(noPull)

      let listed = try await store.listImages()
      #expect(listed.count == 4)
      #expect(listed.map(\.reference).prefix(3) == ["repushed:latest", "new:latest", "old:latest"])
      #expect(listed.last?.reference == "nopull:latest")
    }
  }

  @Test
  func reloadingFromDiskKeepsData() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let id = UUID()
      let record = makeRecord(
        id: id,
        reference: "persist:1.0",
        localPath: root,
        formatVersion: VMImagePackager.currentFormatVersion
      )

      let first = ImageStore(storagePath: root)
      try await first.addImage(record)

      let second = ImageStore(storagePath: root)
      let loaded = try await second.getImage(id: id)
      #expect(loaded?.reference == "persist:1.0")
      #expect(loaded?.formatVersion == VMImagePackager.currentFormatVersion)
    }
  }

  @Test
  func imageResponseExposesFormatVersion() {
    let record = ImageRecord(
      reference: "registry.example.com/vm:latest",
      localPath: "/tmp/image.bundle",
      formatVersion: VMImagePackager.currentFormatVersion
    )

    #expect(ImageResponse(from: record).formatVersion == VMImagePackager.currentFormatVersion)
  }

  @Test
  func invalidFormatVersionIsRejected() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-format-version") { root in
      let store = ImageStore(storagePath: root)
      let record = makeRecord(
        reference: "registry.example.com/vm:invalid",
        localPath: root,
        formatVersion: 0
      )

      do {
        try await store.addImage(record)
        Issue.record("Expected an invalid format version to be rejected")
      } catch let error as ImageStoreError {
        #expect(error.localizedDescription.contains("unsupported format version 0"))
        #expect(error.localizedDescription.contains("Pre-1.0 image index migration is not supported"))
      }
    }
  }

  @Test
  func recordWithoutExplicitBundleOwnershipIsRejected() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-ownership") { root in
      let store = ImageStore(storagePath: root)
      let id = UUID()
      let record = ImageRecord(
        id: id,
        reference: "registry.example.com/vm:unowned",
        localPath: "\(root)/\(id.uuidString).bundle",
        metadata: [:]
      )

      do {
        try await store.addImage(record)
        Issue.record("Expected missing local bundle ownership to be rejected")
      } catch let error as ImageStoreError {
        #expect(error.localizedDescription.contains("does not explicitly own its local bundle"))
        #expect(error.localizedDescription.contains("Pre-1.0 image index migration is not supported"))
      }
    }
  }

  @Test
  func legacyIndexWithoutFormatVersionFailsClosedWithRecoveryInstructions() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-legacy-index") { root in
      let indexPath = "\(root)/images.json"
      let id = UUID()
      let record: [String: Any] = [
        "id": id.uuidString,
        "reference": "registry.example.com/vm:legacy",
        "localPath": "\(root)/\(id.uuidString).bundle",
        "metadata": ["ownsLocalPath": "true"],
      ]
      let payload: [String: Any] = [
        "version": 1,
        "images": [id.uuidString: record],
      ]
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      try data.write(to: URL(fileURLWithPath: indexPath))
      let store = ImageStore(storagePath: root, indexPath: indexPath)

      do {
        _ = try await store.listImages()
        Issue.record("Expected the legacy local index to be rejected")
      } catch let error as ImageStoreError {
        #expect(error.localizedDescription.contains("Incompatible local image index at \(indexPath)"))
        #expect(error.localizedDescription.contains("Pre-1.0 image index migration is not supported"))
        #expect(error.localizedDescription.contains("managed image bundles under \(root)"))
      }
    }
  }

  @Test
  func updateImagePersistsChanges() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let id = UUID()
      var record = makeRecord(id: id, reference: "update:1.0", localPath: root)

      let first = ImageStore(storagePath: root)
      try await first.addImage(record)

      record.reference = "update:2.0"
      try await first.updateImage(record)

      let second = ImageStore(storagePath: root)
      let loaded = try await second.getImage(id: id)
      #expect(loaded?.reference == "update:2.0")
    }
  }

  @Test
  func duplicateAddThrowsAlreadyExists() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let store = ImageStore(storagePath: root)
      let id = UUID()
      let record = makeRecord(id: id, reference: "dup:latest", localPath: root)

      try await store.addImage(record)

      do {
        try await store.addImage(record)
        Issue.record("Expected duplicate add to throw")
      } catch let error as ImageStoreError {
        if case .imageAlreadyExists(let duplicateId) = error {
          #expect(duplicateId == id)
        } else {
          Issue.record("Expected imageAlreadyExists, got \(error.localizedDescription)")
        }
      }
    }
  }

  @Test
  func oversizedIndexIsRejectedBeforeItCanBecomeUnreadableOnRestart() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-size-limit") { root in
      let store = ImageStore(storagePath: root)
      let id = UUID()
      let record = ImageRecord(
        id: id,
        reference: "registry.example.com/oversized:latest",
        localPath: "\(root)/\(id.uuidString).bundle",
        metadata: [
          "ownsLocalPath": "true",
          "payload": String(repeating: "x", count: 17 * 1024 * 1024),
        ]
      )

      await #expect(throws: ImageStoreError.self) {
        try await store.addImage(record)
      }
      let inMemoryCount = try await store.count()
      let reloadedCount = try await ImageStore(storagePath: root).count()
      #expect(inMemoryCount == 0)
      #expect(reloadedCount == 0)
    }
  }

  @Test
  func conditionalReferenceCommitRejectsStaleObservationAndSupportsSameDigestRepair() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-conditional") { root in
      let store = ImageStore(storagePath: root)
      let reference = "registry.example.com/vm:latest"
      let first = makeRecord(reference: reference, localPath: root)
      try await store.addImage(first)

      let replacement = makeRecord(reference: reference, localPath: root)
      do {
        _ = try await store.commitImageForReference(replacement, replacing: UUID())
        Issue.record("Expected a stale conditional commit to fail")
      } catch let error as ImageStoreError {
        guard case .referenceChanged = error else {
          Issue.record("Expected referenceChanged, got \(error.localizedDescription)")
          return
        }
      }
      #expect(try await store.getImageByReference(reference)?.id == first.id)

      let digest = "sha256:" + String(repeating: "a", count: 64)
      var firstWithDigest = first
      firstWithDigest.digest = digest
      try await store.updateImage(firstWithDigest)
      let repairId = UUID()
      let repair = ImageRecord(
        id: repairId,
        reference: reference,
        digest: digest,
        localPath: "\(root)/\(repairId.uuidString).bundle"
      )
      let repaired = try await store.commitImageForReference(
        repair,
        replacing: first.id,
        repairMatchingDigest: true
      )

      #expect(repaired.stored.id == repair.id)
      #expect(repaired.replaced?.id == first.id)
      #expect(try await store.getImageByReference(reference)?.id == repair.id)
    }
  }

  @Test
  func preparedReferenceCommitIsInvisibleUntilFinalized() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-prepared-commit") { root in
      let store = ImageStore(storagePath: root)
      let reference = "registry.example.com/vm:latest"
      let original = makeRecord(reference: reference, localPath: root)
      let replacement = makeRecord(reference: reference, localPath: root)
      try await store.addImage(original)

      let prepared = try await store.prepareImageForReference(
        replacement,
        replacing: original.id,
        repairMatchingDigest: true
      )

      #expect(try await store.getImageByReference(reference)?.id == original.id)
      let finalized = try await store.finalizePreparedImageCommit(prepared)
      #expect(finalized.stored.id == replacement.id)
      #expect(finalized.replaced?.id == original.id)
      #expect(try await store.getImageByReference(reference)?.id == replacement.id)

      let reloaded = ImageStore(storagePath: root)
      #expect(try await reloaded.getImageByReference(reference)?.id == replacement.id)
    }
  }

  @Test
  func preparedFinalizeStaysCommittedAfterPostPublishSyncFailure() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-prepared-post-publish-sync") { root in
      let store = ImageStore(
        storagePath: root,
        durablePostPublishSync: { _ in throw SimulatedImageStoreSyncError() }
      )
      let reference = "registry.example.com/vm:latest"
      let original = makeRecord(reference: reference, localPath: root)
      let replacement = makeRecord(reference: reference, localPath: root)
      try await store.addImage(original)
      let prepared = try await store.prepareImageForReference(
        replacement,
        replacing: original.id,
        repairMatchingDigest: true
      )

      _ = try await store.finalizePreparedImageCommit(prepared)

      #expect(try await store.getImageByReference(reference)?.id == replacement.id)
      let reloaded = ImageStore(storagePath: root)
      #expect(try await reloaded.getImageByReference(reference)?.id == replacement.id)
    }
  }

  @Test
  func abortedPreparedReferenceCommitPreservesOriginalRecord() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-aborted-commit") { root in
      let store = ImageStore(storagePath: root)
      let reference = "registry.example.com/vm:latest"
      let original = makeRecord(reference: reference, localPath: root)
      let replacement = makeRecord(reference: reference, localPath: root)
      try await store.addImage(original)

      let prepared = try await store.prepareImageForReference(
        replacement,
        replacing: original.id,
        repairMatchingDigest: true
      )
      await store.abortPreparedImageCommit(prepared)

      #expect(try await store.getImageByReference(reference)?.id == original.id)
      let reloaded = ImageStore(storagePath: root)
      #expect(try await reloaded.getImageByReference(reference)?.id == original.id)
    }
  }

  @Test
  func abandonedPreparedReferenceCommitIsDiscardedAfterStoreReinitialization() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-prepared-discard") { root in
      let reference = "registry.example.com/vm:latest"
      let record = makeRecord(reference: reference, localPath: root)
      let interruptedStore = ImageStore(storagePath: root)
      #expect(try await interruptedStore.count() == 0)
      try FileManager.default.createDirectory(atPath: record.localPath, withIntermediateDirectories: true)
      _ = try await interruptedStore.prepareImageForReference(
        record,
        replacing: nil,
        repairMatchingDigest: true
      )

      let recoveredStore = ImageStore(storagePath: root)
      #expect(try await recoveredStore.getImageByReference(reference) == nil)
      #expect(FileManager.default.fileExists(atPath: "\(root)/images.json"))
      #expect(try FileManager.default.contentsOfDirectory(atPath: root).contains {
        $0.hasPrefix("images.json.prepared-")
      } == false)
    }
  }

  @Test
  func malformedAbandonedPreparedCommitDoesNotHideAHealthyPrimaryIndex() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-malformed-prepared") { root in
      let store = ImageStore(storagePath: root)
      let record = makeRecord(reference: "registry.example.com/vm:latest", localPath: root)
      try await store.addImage(record)
      let stagedPath = "\(root)/images.json.prepared-\(UUID().uuidString)"
      try Data("truncated".utf8).write(to: URL(fileURLWithPath: stagedPath))

      let recoveredStore = ImageStore(storagePath: root)
      #expect(try await recoveredStore.getImage(id: record.id)?.id == record.id)
      #expect(FileManager.default.fileExists(atPath: stagedPath) == false)
    }
  }

  @Test
  func missingOperationsThrowNotFound() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let store = ImageStore(storagePath: root)
      let missingId = UUID()
      let replacement = makeRecord(id: missingId, reference: "missing:latest", localPath: root)

      do {
        try await store.updateImage(replacement)
        Issue.record("Expected updateImage to throw")
      } catch let error as ImageStoreError {
        if case .imageNotFound(let id) = error {
          #expect(id == missingId)
        } else {
          Issue.record("Expected imageNotFound, got \(error.localizedDescription)")
        }
      }

      do {
        try await store.removeImage(id: missingId)
        Issue.record("Expected removeImage to throw")
      } catch let error as ImageStoreError {
        if case .imageNotFound(let id) = error {
          #expect(id == missingId)
        } else {
          Issue.record("Expected imageNotFound, got \(error.localizedDescription)")
        }
      }
    }
  }

  @Test(arguments: [true, false])
  func getImageByReferenceReturnsMatchOrNil(shouldMatch: Bool) async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let store = ImageStore(storagePath: root)
      let record = makeRecord(reference: "lookup:1.0", localPath: root)
      try await store.addImage(record)

      let query = shouldMatch ? "lookup:1.0" : "other:1.0"
      let result = try await store.getImageByReference(query)
      if shouldMatch {
        #expect(result?.reference == "lookup:1.0")
      } else {
        #expect(result == nil)
      }
    }
  }

  @Test
  func imageExistsByReferenceCheck() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let store = ImageStore(storagePath: root)
      let record = makeRecord(reference: "exists:1.0", localPath: root)

      #expect(try await store.imageExistsByReference("exists:1.0") == false)
      try await store.addImage(record)
      #expect(try await store.imageExistsByReference("exists:1.0"))
      try await store.removeImage(id: record.id)
      #expect(try await store.imageExistsByReference("exists:1.0") == false)
    }
  }

  @Test
  func invalidOnDiskDataBlocksMutationAndPreservesFile() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let indexPath = "\(root)/images.json"
      let originalData = Data("not-json".utf8)
      try originalData.write(to: URL(fileURLWithPath: indexPath))

      let store = ImageStore(storagePath: root)
      await #expect(throws: ImageStoreError.self) {
        _ = try await store.count()
      }
      await #expect(throws: ImageStoreError.self) {
        _ = try await store.listImages()
      }
      await #expect(throws: ImageStoreError.self) {
        _ = try await store.getImage(id: UUID())
      }

      let record = makeRecord(reference: "after-recovery:1.0", localPath: root)
      do {
        try await store.addImage(record)
        Issue.record("Expected corrupt image index to block writes")
      } catch let error as ImageStoreError {
        if case .invalidData(let reason) = error {
          #expect(reason.contains("Refusing to treat it as an empty store"))
        } else {
          Issue.record("Expected invalidData, got \(error.localizedDescription)")
        }
      }

      let preservedData = try Data(contentsOf: URL(fileURLWithPath: indexPath))
      #expect(preservedData == originalData)
    }
  }

  @Test
  func failedWriteDoesNotMutateInMemoryIndex() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let storage = "\(root)/storage"
      let store = ImageStore(storagePath: storage)
      let original = makeRecord(reference: "registry.example.com/vm:original", localPath: storage)
      try await store.addImage(original)

      try FileManager.default.removeItem(atPath: storage)
      var changed = original
      changed.reference = "registry.example.com/vm:must-not-stick"

      do {
        try await store.updateImage(changed)
        Issue.record("Expected write to a removed storage directory to fail")
      } catch {
        let retained = try await store.getImage(id: original.id)
        #expect(retained?.reference == original.reference)
      }
    }
  }

  @Test
  func postPublishSyncFailureDoesNotSplitMemoryFromPublishedIndex() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-post-publish-sync") { root in
      let record = makeRecord(reference: "registry.example.com/vm:published", localPath: root)
      let store = ImageStore(
        storagePath: root,
        durablePostPublishSync: { _ in throw SimulatedImageStoreSyncError() }
      )

      try await store.addImage(record)

      #expect(try await store.getImage(id: record.id)?.id == record.id)
      let reloaded = ImageStore(storagePath: root)
      #expect(try await reloaded.getImage(id: record.id)?.id == record.id)
    }
  }

  @Test
  func corruptPrimaryRecoversFromBackup() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let indexPath = "\(root)/images.json"
      let firstStore = ImageStore(storagePath: root)
      let record = makeRecord(reference: "registry.example.com/vm:recoverable", localPath: root)
      try await firstStore.addImage(record)
      try? FileManager.default.removeItem(atPath: indexPath + ".bak")
      try FileManager.default.copyItem(atPath: indexPath, toPath: indexPath + ".bak")
      try Data("corrupt".utf8).write(to: URL(fileURLWithPath: indexPath))

      let recoveredStore = ImageStore(storagePath: root)
      #expect(try await recoveredStore.getImage(id: record.id)?.reference == record.reference)

      let reloadedStore = ImageStore(storagePath: root)
      #expect(try await reloadedStore.getImage(id: record.id)?.reference == record.reference)
    }
  }

  @Test
  func missingPrimaryRecoversFromBackupInsteadOfStartingEmpty() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-missing-primary") { root in
      let indexPath = "\(root)/indexes/images.json"
      let store = ImageStore(storagePath: "\(root)/images", indexPath: indexPath)
      let first = makeRecord(reference: "registry.example.com/vm:first", localPath: "\(root)/images")
      let second = makeRecord(reference: "registry.example.com/vm:second", localPath: "\(root)/images")
      try await store.addImage(first)
      try await store.addImage(second)
      #expect(FileManager.default.fileExists(atPath: indexPath + ".bak"))
      try FileManager.default.removeItem(atPath: indexPath)

      let recovered = ImageStore(storagePath: "\(root)/images", indexPath: indexPath)

      #expect(try await recovered.getImage(id: first.id)?.id == first.id)
      #expect(try await recovered.getImage(id: second.id) == nil)
      #expect(FileManager.default.fileExists(atPath: indexPath))
    }
  }

  @Test
  func missingIndexWithManagedBundlesFailsClosedAndPreservesData() async throws {
    try await withTemporaryDirectory(prefix: "imagestore-missing-index") { root in
      let storage = "\(root)/images"
      let id = UUID()
      let bundle = "\(storage)/\(id.uuidString).bundle"
      try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
      try Data("must survive".utf8).write(to: URL(fileURLWithPath: "\(bundle)/Disk.img"))
      let store = ImageStore(storagePath: storage, indexPath: "\(root)/indexes/images.json")

      await #expect(throws: ImageStoreError.self) {
        _ = try await store.listImages()
      }
      #expect(FileManager.default.fileExists(atPath: "\(bundle)/Disk.img"))
    }
  }

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

  @Test
  func unsupportedIndexVersionBlocksMutation() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let indexPath = "\(root)/images.json"
      let encoder = JSONEncoder()
      try encoder.encode(ImageIndex(version: 999)).write(to: URL(fileURLWithPath: indexPath))
      let store = ImageStore(storagePath: root)

      do {
        try await store.addImage(makeRecord(reference: "registry.example.com/vm:new", localPath: root))
        Issue.record("Expected unsupported index version to fail")
      } catch let error as ImageStoreError {
        #expect(error.localizedDescription.contains("version 999"))
      }
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

private struct SimulatedImageStoreSyncError: Error {}
