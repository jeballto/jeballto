import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct DurableMarkerStoreTests {
  @Test
  func atomicWriteRoundTripsAndSecuresPublishedFile() throws {
    try withTemporaryDirectory { root in
      let path = "\(root)/marker.json"
      let expected = Data("{\"formatVersion\":1}".utf8)

      let publication = try DurableMarkerStore.writeDataAtomically(
        expected,
        to: path,
        maximumSize: 1024
      )

      #expect(publication.postPublishWarning == nil)
      #expect(try DurableMarkerStore.readDataIfPresent(from: path, maximumSize: 1024) == expected)
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
  }

  @Test
  func readRejectsSymbolicLinkWithoutFollowingIt() throws {
    try withTemporaryDirectory { root in
      let externalPath = "\(root)/external"
      let markerPath = "\(root)/marker"
      try Data("external".utf8).write(to: URL(fileURLWithPath: externalPath))
      try FileManager.default.createSymbolicLink(atPath: markerPath, withDestinationPath: externalPath)

      #expect(throws: DurableMarkerStoreError.self) {
        _ = try DurableMarkerStore.readDataIfPresent(from: markerPath, maximumSize: 1024)
      }
      #expect(try Data(contentsOf: URL(fileURLWithPath: externalPath)) == Data("external".utf8))
    }
  }

  @Test
  func writeRejectsNonRegularExistingTarget() throws {
    try withTemporaryDirectory { root in
      let markerPath = "\(root)/marker"
      try FileManager.default.createDirectory(atPath: markerPath, withIntermediateDirectories: false)

      #expect(throws: DurableMarkerStoreError.self) {
        try DurableMarkerStore.writeDataAtomically(Data("value".utf8), to: markerPath, maximumSize: 1024)
      }
      var isDirectory: ObjCBool = false
      #expect(FileManager.default.fileExists(atPath: markerPath, isDirectory: &isDirectory))
      #expect(isDirectory.boolValue)
    }
  }

  @Test
  func boundedReadRejectsOversizedPayload() throws {
    try withTemporaryDirectory { root in
      let markerPath = "\(root)/marker"
      try Data(repeating: 0x41, count: 65).write(to: URL(fileURLWithPath: markerPath))

      #expect(throws: DurableMarkerStoreError.self) {
        _ = try DurableMarkerStore.readDataIfPresent(from: markerPath, maximumSize: 64)
      }
    }
  }

  @Test
  func negativeSizeLimitIsRejectedWithoutIntegerOverflow() throws {
    try withTemporaryDirectory { root in
      let markerPath = "\(root)/marker"

      #expect(throws: DurableMarkerStoreError.self) {
        try DurableMarkerStore.writeDataAtomically(Data(), to: markerPath, maximumSize: -1)
      }
      #expect(throws: DurableMarkerStoreError.self) {
        _ = try DurableMarkerStore.readDataIfPresent(from: markerPath, maximumSize: -1)
      }
    }
  }

  @Test
  func removingMarkerBelowMissingParentIsIdempotent() throws {
    try withTemporaryDirectory { root in
      let result = try DurableMarkerStore.removeIfPresent(at: "\(root)/missing/marker")
      #expect(result == nil)
    }
  }

  @Test
  func postPublishSyncFailureNeverTurnsPublishedWriteIntoRollbackSignal() throws {
    try withTemporaryDirectory { root in
      let markerPath = "\(root)/marker"
      let expected = Data("published".utf8)

      let publication = try DurableMarkerStore.writeDataAtomically(
        expected,
        to: markerPath,
        maximumSize: 1024,
        postPublishSync: { _ in throw TestPostPublishError.injected }
      )

      #expect(publication.postPublishWarning != nil)
      #expect(try Data(contentsOf: URL(fileURLWithPath: markerPath)) == expected)
    }
  }
}

private enum TestPostPublishError: Error {
  case injected
}
