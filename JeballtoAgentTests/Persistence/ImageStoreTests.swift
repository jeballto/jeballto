import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.persistence))
struct ImageStoreTests {
  private func makeRecord(
    id: UUID = UUID(),
    reference: String,
    localPath: String,
    pulledAt: Date? = nil
  ) -> ImageRecord {
    ImageRecord(
      id: id,
      reference: reference,
      localPath: localPath,
      pulledAt: pulledAt
    )
  }

  @Test
  func addGetRemoveLifecycle() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let store = ImageStore(storagePath: root)
      let id = UUID()
      let record = makeRecord(id: id, reference: "registry.example.com/vm:latest", localPath: "\(root)/\(id)")

      try await store.addImage(record)
      #expect(await store.count() == 1)

      let loaded = await store.getImage(id: id)
      #expect(loaded?.reference == "registry.example.com/vm:latest")

      try await store.removeImage(id: id)
      #expect(await store.count() == 0)
      #expect(await store.getImage(id: id) == nil)
    }
  }

  @Test
  func listImagesSortedByPulledAtDescending() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let store = ImageStore(storagePath: root)
      let old = makeRecord(reference: "old:latest", localPath: root, pulledAt: Date(timeIntervalSince1970: 1))
      let new = makeRecord(reference: "new:latest", localPath: root, pulledAt: Date(timeIntervalSince1970: 2))
      let noPull = makeRecord(reference: "nopull:latest", localPath: root, pulledAt: nil)

      try await store.addImage(old)
      try await store.addImage(new)
      try await store.addImage(noPull)

      let listed = await store.listImages()
      #expect(listed.count == 3)
      // newest pulledAt first; nil pulledAt falls to end
      #expect(listed[0].reference == "new:latest")
      #expect(listed[1].reference == "old:latest")
    }
  }

  @Test
  func reloadingFromDiskKeepsData() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let id = UUID()
      let record = makeRecord(id: id, reference: "persist:1.0", localPath: root)

      let first = ImageStore(storagePath: root)
      try await first.addImage(record)

      let second = ImageStore(storagePath: root)
      let loaded = await second.getImage(id: id)
      #expect(loaded?.reference == "persist:1.0")
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
      let loaded = await second.getImage(id: id)
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
      let result = await store.getImageByReference(query)
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

      #expect(await store.imageExistsByReference("exists:1.0") == false)
      try await store.addImage(record)
      #expect(await store.imageExistsByReference("exists:1.0"))
      try await store.removeImage(id: record.id)
      #expect(await store.imageExistsByReference("exists:1.0") == false)
    }
  }

  @Test
  func invalidOnDiskDataFallsBackToEmptyIndex() async throws {
    try await withTemporaryDirectory(prefix: "imagestore") { root in
      let indexPath = "\(root)/images.json"
      try Data("not-json".utf8).write(to: URL(fileURLWithPath: indexPath))

      let store = ImageStore(storagePath: root)
      #expect(await store.count() == 0)

      let record = makeRecord(reference: "after-recovery:1.0", localPath: root)
      try await store.addImage(record)
      #expect(await store.count() == 1)
    }
  }
}
