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
}
