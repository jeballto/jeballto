import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct JeballtoCachePathsTests {
  @Test
  func cacheOverrideAcceptsAbsoluteNonRootPath() {
    let url = JeballtoCachePaths.validatedOverrideURL(for: "/tmp/jeballto-cache")

    #expect(url?.path == "/tmp/jeballto-cache")
  }

  @Test(arguments: ["", ".", "relative/cache", "/"])
  func cacheOverrideRejectsUnsafePaths(_ path: String) {
    #expect(JeballtoCachePaths.validatedOverrideURL(for: path) == nil)
  }

  @Test
  func cacheOverrideRejectsHomeDirectory() {
    #expect(JeballtoCachePaths.validatedOverrideURL(for: NSHomeDirectory()) == nil)
  }

  @Test
  func imageWorkSessionLockRejectsASecondOwnerAndCanBeReacquired() throws {
    try withTemporaryDirectory(prefix: "image-work-session-lock") { root in
      let sessionURL = URL(fileURLWithPath: root, isDirectory: true)
        .appendingPathComponent("ImageWork/sessions/session", isDirectory: true)
      let first = try ImageWorkSessionLock(sessionURL: sessionURL)

      #expect(throws: ImageWorkSessionLockError.self) {
        _ = try ImageWorkSessionLock(sessionURL: sessionURL)
      }

      first.release()
      let replacement = try ImageWorkSessionLock(sessionURL: sessionURL)
      replacement.release()
    }
  }

  @Test
  func childKernelLeaseKeepsSessionAliveAfterOwnerExit() throws {
    try withTemporaryDirectory(prefix: "image-work-child-lease") { root in
      let sessionURL = URL(fileURLWithPath: root, isDirectory: true)
        .appendingPathComponent("ImageWork/sessions/session", isDirectory: true)
      let owner = try ImageWorkSessionLock(sessionURL: sessionURL)
      let childLease = try ImageWorkChildProcessLease.acquireKernelLeaseForTesting(sessionURL: sessionURL)

      owner.release()
      #expect(ImageWorkSessionLock.containsLiveWork(at: sessionURL))
      #expect(ImageWorkSessionLock.removeSessionIfInactive(at: sessionURL) == .active)
      #expect(FileManager.default.fileExists(atPath: sessionURL.path))

      childLease.release()
      #expect(ImageWorkSessionLock.containsLiveWork(at: sessionURL) == false)
      #expect(ImageWorkSessionLock.removeSessionIfInactive(at: sessionURL) == .removed)
      #expect(FileManager.default.fileExists(atPath: sessionURL.path) == false)
    }
  }

  @Test
  func launchMarkerClosesTheLeaseHandoffGap() throws {
    try withTemporaryDirectory(prefix: "image-work-launch-marker") { root in
      let sessionURL = URL(fileURLWithPath: root, isDirectory: true)
        .appendingPathComponent("ImageWork/sessions/session", isDirectory: true)
      let owner = try ImageWorkSessionLock(sessionURL: sessionURL)
      let childProcessLease = try owner.childProcessLease(
        wrapperExecutableURL: URL(fileURLWithPath: "/usr/bin/false")
      )
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
      let reservation = try childProcessLease.prepare(process)

      owner.release()
      #expect(ImageWorkSessionLock.removeSessionIfInactive(at: sessionURL) == .childLaunchInProgress)

      reservation.cancelBeforeLaunch()
      #expect(ImageWorkSessionLock.removeSessionIfInactive(at: sessionURL) == .removed)
    }
  }

  @Test
  func symbolicLaunchMarkerCannotBlockCleanup() throws {
    try withTemporaryDirectory(prefix: "image-work-symbolic-launch-marker") { root in
      let rootURL = URL(fileURLWithPath: root, isDirectory: true)
      let sessionURL = rootURL.appendingPathComponent("ImageWork/sessions/session", isDirectory: true)
      let owner = try ImageWorkSessionLock(sessionURL: sessionURL)
      let outside = rootURL.appendingPathComponent("outside")
      try Data("keep".utf8).write(to: outside)
      try FileManager.default.createSymbolicLink(
        at: sessionURL.appendingPathComponent(".child-launch-\(UUID().uuidString)"),
        withDestinationURL: outside
      )

      owner.release()
      #expect(ImageWorkSessionLock.removeSessionIfInactive(at: sessionURL) == .removed)
      #expect(try Data(contentsOf: outside) == Data("keep".utf8))
    }
  }

  @Test
  func imageWorkSessionLockRefusesSymbolicDirectoryComponents() throws {
    try withTemporaryDirectory(prefix: "image-work-session-directory-symlinks") { root in
      let rootURL = URL(fileURLWithPath: root, isDirectory: true)
      let outside = rootURL.appendingPathComponent("outside", isDirectory: true)
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

      let linkedImageWork = rootURL.appendingPathComponent("linked-root/ImageWork", isDirectory: true)
      try FileManager.default.createDirectory(
        at: linkedImageWork.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try FileManager.default.createSymbolicLink(at: linkedImageWork, withDestinationURL: outside)
      #expect(throws: ImageWorkSessionLockError.self) {
        _ = try ImageWorkSessionLock(
          sessionURL: linkedImageWork.appendingPathComponent("sessions/session", isDirectory: true)
        )
      }

      let imageWorkWithLinkedSessions = rootURL.appendingPathComponent("linked-sessions/ImageWork", isDirectory: true)
      try FileManager.default.createDirectory(at: imageWorkWithLinkedSessions, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        at: imageWorkWithLinkedSessions.appendingPathComponent("sessions", isDirectory: true),
        withDestinationURL: outside
      )
      #expect(throws: ImageWorkSessionLockError.self) {
        _ = try ImageWorkSessionLock(
          sessionURL: imageWorkWithLinkedSessions.appendingPathComponent("sessions/session", isDirectory: true)
        )
      }

      let imageWorkWithLinkedSession = rootURL.appendingPathComponent("linked-session/ImageWork", isDirectory: true)
      let sessionsURL = imageWorkWithLinkedSession.appendingPathComponent("sessions", isDirectory: true)
      try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
      try FileManager.default.createSymbolicLink(
        at: sessionsURL.appendingPathComponent("session", isDirectory: true),
        withDestinationURL: outside
      )
      #expect(throws: ImageWorkSessionLockError.self) {
        _ = try ImageWorkSessionLock(
          sessionURL: sessionsURL.appendingPathComponent("session", isDirectory: true)
        )
      }
    }
  }
}
