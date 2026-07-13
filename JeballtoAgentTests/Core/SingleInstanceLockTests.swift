import Darwin
import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core), .serialized)
struct SingleInstanceLockTests {
  @Test
  func lockDescriptorClosesOnExec() throws {
    try withTemporaryDirectory(prefix: "single-instance-close-on-exec") { root in
      let lock = try SingleInstanceLock(path: "\(root)/agent.lock")
      #expect(lock.closesDescriptorOnExec)
    }
  }

  @Test
  func rejectsASecondOwnerAndCanBeReacquiredAfterRelease() throws {
    try withTemporaryDirectory(prefix: "single-instance-lock") { root in
      let path = "\(root)/state/agent.lock"
      let first = try SingleInstanceLock(path: path)

      #expect(throws: SingleInstanceLockError.self) {
        _ = try SingleInstanceLock(path: path)
      }

      first.release()
      let replacement = try SingleInstanceLock(path: path)
      replacement.release()
    }
  }

  @Test
  func refusesASymbolicLinkLockFile() throws {
    try withTemporaryDirectory(prefix: "single-instance-symlink") { root in
      let target = "\(root)/target"
      let path = "\(root)/agent.lock"
      try Data("do not overwrite".utf8).write(to: URL(fileURLWithPath: target))
      try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

      #expect(throws: SingleInstanceLockError.self) {
        _ = try SingleInstanceLock(path: path)
      }
      #expect(try String(contentsOfFile: target, encoding: .utf8) == "do not overwrite")
    }
  }

  @Test
  func refusesASymbolicLinkLockDirectoryWithoutChangingItsTarget() throws {
    try withTemporaryDirectory(prefix: "single-instance-directory-symlink") { root in
      let targetDirectory = "\(root)/target"
      let linkedDirectory = "\(root)/state"
      try FileManager.default.createDirectory(atPath: targetDirectory, withIntermediateDirectories: true)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetDirectory)
      try FileManager.default.createSymbolicLink(atPath: linkedDirectory, withDestinationPath: targetDirectory)

      #expect(throws: SingleInstanceLockError.self) {
        _ = try SingleInstanceLock(path: "\(linkedDirectory)/agent.lock")
      }
      let permissions = try #require(
        FileManager.default.attributesOfItem(atPath: targetDirectory)[.posixPermissions] as? NSNumber
      )
      #expect(permissions.intValue == 0o755)
      #expect(FileManager.default.fileExists(atPath: "\(targetDirectory)/agent.lock") == false)
    }
  }
}
