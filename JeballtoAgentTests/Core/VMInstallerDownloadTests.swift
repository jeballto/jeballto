import Foundation
import Testing
@testable import JeballtoAgent

struct VMInstallerDownloadTests {
  @Test
  func cachePreservesOriginalFilenameAndSeparatesURLIdentity() throws {
    let cacheRoot = URL(fileURLWithPath: "/tmp/IPSWCache", isDirectory: true)
    let firstURL = try #require(URL(string: "https://example.com/releases/macOS.ipsw?build=1"))
    let secondURL = try #require(URL(string: "https://mirror.example.com/releases/macOS.ipsw?build=1"))
    let thirdURL = try #require(URL(string: "https://example.com/releases/macOS.ipsw?build=2"))

    let first = IPSWCacheLayout.location(for: firstURL, in: cacheRoot)
    let second = IPSWCacheLayout.location(for: secondURL, in: cacheRoot)
    let third = IPSWCacheLayout.location(for: thirdURL, in: cacheRoot)

    #expect(first.imageURL.lastPathComponent == "macOS.ipsw")
    #expect(second.imageURL.lastPathComponent == "macOS.ipsw")
    #expect(third.imageURL.lastPathComponent == "macOS.ipsw")
    #expect(first.directoryURL != second.directoryURL)
    #expect(first.directoryURL != third.directoryURL)
    #expect(first.imageURL.deletingLastPathComponent() == first.directoryURL)
    #expect(first.directoryURL.deletingLastPathComponent() == cacheRoot)
    #expect(first.temporaryDirectoryURL.deletingLastPathComponent().lastPathComponent == ".downloads")
    #expect(first.temporaryDirectoryURL != second.temporaryDirectoryURL)
    #expect(first.temporaryDirectoryURL != third.temporaryDirectoryURL)
  }

  @Test
  func cacheKeepsAppleRestoreImageFilename() throws {
    let url = try #require(URL(
      string:
      "https://updates.cdn-apple.com/2026WinterFCS/fullrestores/047-88313/"
        + "UniversalMac_26.3.1_25D2128_Restore.ipsw"
    ))
    let cacheRoot = URL(fileURLWithPath: "/tmp/IPSWCache", isDirectory: true)

    let location = IPSWCacheLayout.location(for: url, in: cacheRoot)

    #expect(location.imageURL.lastPathComponent == "UniversalMac_26.3.1_25D2128_Restore.ipsw")
    #expect(location.directoryURL.lastPathComponent.hasPrefix("UniversalMac_26.3.1_25D2128_Restore--"))
    #expect(location.directoryURL.lastPathComponent.utf8.count <= 255)
  }

  @Test(arguments: [
    "https://example.com/%2Ftmp%2Fevil.ipsw",
    "https://example.com/%2E%2E",
    "https://example.com/",
    "https://example.com/bad%00name.ipsw",
  ])
  func cacheFallsBackForUnsafeFilename(_ source: String) throws {
    let url = try #require(URL(string: source))
    let cacheRoot = URL(fileURLWithPath: "/tmp/IPSWCache", isDirectory: true)

    let location = IPSWCacheLayout.location(for: url, in: cacheRoot)

    #expect(location.imageURL.lastPathComponent == IPSWCacheLayout.fallbackFilename)
    #expect(location.imageURL.deletingLastPathComponent() == location.directoryURL)
    #expect(location.directoryURL.deletingLastPathComponent() == cacheRoot)
  }

  @Test
  func cacheFallsBackForFilenameBeyondFilesystemLimit() throws {
    let longStem = String(repeating: "%C3%A9", count: 130)
    let url = try #require(URL(string: "https://example.com/\(longStem).ipsw"))
    let cacheRoot = URL(fileURLWithPath: "/tmp/IPSWCache", isDirectory: true)

    let location = IPSWCacheLayout.location(for: url, in: cacheRoot)

    #expect(location.imageURL.lastPathComponent == IPSWCacheLayout.fallbackFilename)
    #expect(location.directoryURL.lastPathComponent.utf8.count <= 255)
  }

  @Test
  func partialDownloadsAreUniqueAndRemainInsideIdentityDirectory() throws {
    let url = try #require(URL(string: "https://example.com/releases/macOS.ipsw"))
    let location = IPSWCacheLayout.location(
      for: url,
      in: URL(fileURLWithPath: "/tmp/IPSWCache", isDirectory: true)
    )

    let first = location.partialURL(attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let second = location.partialURL(attemptID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

    #expect(first != second)
    #expect(first.deletingLastPathComponent() == location.temporaryDirectoryURL)
    #expect(first.lastPathComponent == "00000000-0000-0000-0000-000000000001.partial")
  }

  @Test
  func legacyHashedCacheEntryMigratesWithoutRedownload() throws {
    try withTemporaryDirectory(prefix: "ipsw-cache-migration") { root in
      let cacheRoot = URL(fileURLWithPath: root, isDirectory: true)
      let url = try #require(URL(string: "https://example.com/UniversalMac_Restore.ipsw"))
      let location = IPSWCacheLayout.location(for: url, in: cacheRoot)
      try IPSWCacheLayout.prepareDirectory(at: location.directoryURL, withIntermediateDirectories: true)
      let legacyURL = IPSWCacheLayout.legacyImageURL(for: url, in: cacheRoot)
      #expect(legacyURL.lastPathComponent == "restore-8db46c4ae1aa7d375d9b05da.ipsw")
      let contents = Data("cached-ipsw".utf8)
      try contents.write(to: legacyURL)

      try VMInstaller.migrateLegacyCachedIPSWIfNeeded(for: url, to: location)

      #expect(FileManager.default.fileExists(atPath: legacyURL.path) == false)
      #expect(try Data(contentsOf: location.imageURL) == contents)
    }
  }

  @Test
  func cacheDirectoryPreparationRejectsSymbolicLink() throws {
    try withTemporaryDirectory(prefix: "ipsw-cache-directory") { root in
      let cacheRoot = URL(fileURLWithPath: root, isDirectory: true)
      let target = cacheRoot.appendingPathComponent("target", isDirectory: true)
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
      let url = try #require(URL(string: "https://example.com/macOS.ipsw"))
      let location = IPSWCacheLayout.location(for: url, in: cacheRoot)
      try FileManager.default.createSymbolicLink(at: location.directoryURL, withDestinationURL: target)

      #expect(throws: IPSWCacheLayoutError.self) {
        try IPSWCacheLayout.prepareDirectory(at: location.directoryURL, withIntermediateDirectories: false)
      }
    }
  }

  @Test
  func stalePartialCleanupRemovesDanglingSymbolicLink() throws {
    try withTemporaryDirectory(prefix: "ipsw-stale-partial") { root in
      let directory = URL(fileURLWithPath: root, isDirectory: true)
      let partial = directory.appendingPathComponent(
        "00000000-0000-0000-0000-000000000001.partial"
      )
      try FileManager.default.createSymbolicLink(
        at: partial,
        withDestinationURL: directory.appendingPathComponent("missing")
      )
      _ = try FileManager.default.destinationOfSymbolicLink(atPath: partial.path)

      try VMInstaller.removeStalePartialIPSWs(in: directory)

      #expect(VMInstaller.cachedIPSWEntryExists(at: partial) == false)
    }
  }

  @Test
  func stalePartialCleanupCannotDeleteAnImageWithAPartialLookingOriginalName() throws {
    try withTemporaryDirectory(prefix: "ipsw-stale-partial-isolation") { root in
      let cacheRoot = URL(fileURLWithPath: root, isDirectory: true)
      let source = try #require(URL(
        string: "https://example.com/.download-00000000-0000-0000-0000-000000000001.partial"
      ))
      let location = IPSWCacheLayout.location(for: source, in: cacheRoot)
      try IPSWCacheLayout.prepareDirectory(at: location.directoryURL, withIntermediateDirectories: true)
      try IPSWCacheLayout.prepareDirectory(
        at: location.temporaryDirectoryURL,
        withIntermediateDirectories: true
      )
      let contents = Data("valid-image".utf8)
      try contents.write(to: location.imageURL)
      try Data("stale".utf8).write(to: location.partialURL(attemptID: UUID()))

      try VMInstaller.removeStalePartialIPSWs(in: location.temporaryDirectoryURL)

      #expect(try Data(contentsOf: location.imageURL) == contents)
      #expect(try FileManager.default.contentsOfDirectory(
        at: location.temporaryDirectoryURL,
        includingPropertiesForKeys: nil
      ).isEmpty)
    }
  }

  @Test
  func lateDownloadCallbackAfterCancellationCannotWritePartialFile() throws {
    try withTemporaryDirectory(prefix: "ipsw-late-callback") { root in
      let id = UUID()
      let definition = VMDefinition(
        id: id,
        name: "download-late-callback",
        resources: .default,
        paths: VMPaths.forVM(id: id, baseDir: root)
      )
      let installer = VMInstaller(vmDefinition: definition, eventBus: EventBus())
      let sourceURL = URL(fileURLWithPath: root).appendingPathComponent("session-download")
      let destinationURL = URL(fileURLWithPath: root).appendingPathComponent("download.partial")
      try Data("late download".utf8).write(to: sourceURL)
      let responseURL = try #require(URL(string: "https://example.invalid/download.ipsw"))
      let response = try #require(HTTPURLResponse(
        url: responseURL,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      ))
      let delegate = DownloadDelegate(installer: installer, destinationURL: destinationURL)

      delegate.cancel()
      delegate.finishDownload(at: sourceURL, response: response)

      #expect(FileManager.default.fileExists(atPath: sourceURL.path))
      #expect(FileManager.default.fileExists(atPath: destinationURL.path) == false)
    }
  }

  @Test
  func cachedIPSWValidationRejectsEmptyFilesAndSymbolicLinks() throws {
    try withTemporaryDirectory(prefix: "ipsw-cache-validation") { root in
      let emptyPath = "\(root)/empty.ipsw"
      let regularPath = "\(root)/regular.ipsw"
      let linkPath = "\(root)/link.ipsw"
      try Data().write(to: URL(fileURLWithPath: emptyPath))
      try Data("ipsw".utf8).write(to: URL(fileURLWithPath: regularPath))
      try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: regularPath)

      #expect(VMInstaller.cachedIPSWIsUsable(at: URL(fileURLWithPath: emptyPath)) == false)
      #expect(VMInstaller.cachedIPSWIsUsable(at: URL(fileURLWithPath: regularPath)))
      #expect(VMInstaller.cachedIPSWIsUsable(at: URL(fileURLWithPath: linkPath)) == false)
    }
  }

  @Test
  func progressForUnknownContentLengthIsIndeterminate() {
    let update = DownloadDelegate.makeProgressUpdate(
      totalBytesWritten: 12_345_678,
      totalBytesExpectedToWrite: -1,
      speedBytesPerSecond: 2_000_000
    )

    #expect(update.scaledProgress == -1.0)
    #expect(update.phaseProgress == -1.0)
    #expect(update.percent == nil)
    #expect(update.bytesDownloaded == 12_345_678)
    #expect(update.bytesTotal == nil)
    #expect(update.message.contains("downloaded"))
  }

  @Test
  func progressForKnownContentLengthIsClamped() {
    let update = DownloadDelegate.makeProgressUpdate(
      totalBytesWritten: 150,
      totalBytesExpectedToWrite: 100,
      speedBytesPerSecond: 1_000_000
    )

    #expect(update.scaledProgress == 0.5)
    #expect(update.phaseProgress == 1.0)
    #expect(update.percent == 100)
    #expect(update.bytesDownloaded == 150)
    #expect(update.bytesTotal == 100)
  }

  @Test
  func downloadSpeedConversionClampsExtremeAndInvalidCounters() {
    #expect(
      DownloadDelegate.safeBytesPerSecond(bytesDelta: .max, timeDelta: .leastNonzeroMagnitude) == .max
    )
    #expect(DownloadDelegate.safeBytesPerSecond(bytesDelta: 1000, timeDelta: 0.5) == 2000)
    #expect(DownloadDelegate.safeBytesPerSecond(bytesDelta: -1, timeDelta: 1) == 0)
    #expect(DownloadDelegate.safeBytesPerSecond(bytesDelta: 1, timeDelta: .infinity) == 0)
  }

  @Test
  func validateHTTPResponseRejectsNonSuccessStatus() throws {
    let url = try #require(URL(string: "https://example.com/macOS.ipsw"))
    let response = try #require(HTTPURLResponse(
      url: url,
      statusCode: 404,
      httpVersion: nil,
      headerFields: nil
    ))

    do {
      try DownloadDelegate.validateHTTPResponse(response)
      Issue.record("Expected non-success HTTP status to throw")
    } catch let error as VMInstallerError {
      if case .restoreImageFetchFailed(let message) = error {
        #expect(message.contains("HTTP 404"))
      } else {
        Issue.record("Expected restoreImageFetchFailed, got \(error.localizedDescription)")
      }
    }
  }

  @Test
  func httpRedirectAndNonHTTPSFinalResponseAreRejected() throws {
    let insecureURL = try #require(URL(string: "http://example.com/macOS.ipsw"))
    let redirect = URLRequest(url: insecureURL)
    #expect(throws: VMInstallerError.self) {
      try DownloadDelegate.validateRedirectTarget(redirect)
    }

    let response = try #require(HTTPURLResponse(
      url: insecureURL,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    ))
    #expect(throws: VMInstallerError.self) {
      try DownloadDelegate.validateHTTPResponse(response)
    }

    let credentialURL = try #require(URL(string: "https://user:password@example.com/macOS.ipsw"))
    #expect(throws: VMInstallerError.self) {
      try DownloadDelegate.validateRedirectTarget(URLRequest(url: credentialURL))
    }
  }

  @Test
  func installationCancellationControllerCancelsBeforeOrAfterProgressRegistration() {
    let registeredFirst = InstallationProgressCancellationController()
    let firstProgress = Progress(totalUnitCount: 100)
    registeredFirst.register(firstProgress)
    registeredFirst.cancel()

    let cancelledFirst = InstallationProgressCancellationController()
    let secondProgress = Progress(totalUnitCount: 100)
    cancelledFirst.cancel()
    cancelledFirst.register(secondProgress)

    #expect(registeredFirst.isCancellationRequested)
    #expect(firstProgress.isCancelled)
    #expect(cancelledFirst.isCancellationRequested)
    #expect(secondProgress.isCancelled)
  }

  @Test
  func diskImageCreationUsesExactByteSize() {
    let url = URL(fileURLWithPath: "/tmp/test.bundle/disk.img")
    let size: UInt64 = 20_000_000_001

    let arguments = VMInstaller.diskImageCreationArguments(url: url, size: size)

    #expect(arguments == [
      "image", "create", "blank", "--fs", "none", "--format", "ASIF", "--size", "20000000001B", url.path,
    ])
  }
}
