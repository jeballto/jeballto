import Foundation
import Testing
@testable import JeballtoAgent

struct VMInstallerDownloadTests {
  @Test
  func cacheFilenameIncludesURLIdentity() throws {
    let firstURL = try #require(URL(string: "https://example.com/releases/macOS.ipsw"))
    let secondURL = try #require(URL(string: "https://mirror.example.com/releases/macOS.ipsw"))

    let first = VMInstaller.cacheFilename(for: firstURL)
    let second = VMInstaller.cacheFilename(for: secondURL)

    #expect(first != second)
    #expect(first.hasSuffix(".ipsw"))
    #expect(second.hasSuffix(".ipsw"))
    #expect(first.contains("/") == false)
    #expect(second.contains("/") == false)
  }

  @Test
  func cacheFilenameBoundsLongURLPathComponent() throws {
    let longStem = String(repeating: "a", count: 300)
    let url = try #require(URL(string: "https://example.com/\(longStem).ipsw"))

    let filename = VMInstaller.cacheFilename(for: url)

    #expect(filename.count < 255)
    #expect(filename.hasSuffix(".ipsw"))
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
