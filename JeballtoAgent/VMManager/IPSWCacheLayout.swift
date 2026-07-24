import CryptoKit
import Darwin
import Foundation

struct IPSWCacheLocation: Equatable, Sendable {
  let directoryURL: URL
  let imageURL: URL
  let temporaryDirectoryURL: URL

  func partialURL(attemptID: UUID) -> URL {
    temporaryDirectoryURL.appendingPathComponent("\(attemptID.uuidString.lowercased()).partial")
  }
}

enum IPSWCacheLayoutError: Error, LocalizedError {
  case directoryPreparationFailed(path: String, message: String)

  var errorDescription: String? {
    switch self {
    case .directoryPreparationFailed(let path, let message):
      "Failed to prepare IPSW cache directory at \(path): \(message)"
    }
  }
}

enum IPSWCacheLayout {
  static let fallbackFilename = "restore.ipsw"
  private static let maximumNameByteCount = 255

  static func location(for remoteURL: URL, in cacheRoot: URL) -> IPSWCacheLocation {
    let filename = originalFilename(for: remoteURL)
    let digest = urlDigest(for: remoteURL)
    let stem = readableStem(for: filename)
    let suffix = "--\(digest)"
    let boundedStem = prefix(stem, fittingUTF8ByteCount: maximumNameByteCount - suffix.utf8.count)
    let directoryURL = cacheRoot.appendingPathComponent("\(boundedStem)\(suffix)", isDirectory: true)
    let temporaryDirectoryURL = cacheRoot
      .appendingPathComponent(".downloads", isDirectory: true)
      .appendingPathComponent(digest, isDirectory: true)

    return IPSWCacheLocation(
      directoryURL: directoryURL,
      imageURL: directoryURL.appendingPathComponent(filename, isDirectory: false),
      temporaryDirectoryURL: temporaryDirectoryURL
    )
  }

  static func legacyImageURL(for remoteURL: URL, in cacheRoot: URL) -> URL {
    let digest = urlDigest(for: remoteURL, byteCount: 12)
    return cacheRoot.appendingPathComponent("restore-\(digest).ipsw", isDirectory: false)
  }

  static func prepareDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
    var status = stat()
    let initialResult = url.path.withCString { Darwin.lstat($0, &status) }
    if initialResult == 0 {
      guard status.st_mode & S_IFMT == S_IFDIR else {
        throw IPSWCacheLayoutError.directoryPreparationFailed(
          path: url.path,
          message: "path is a symbolic link or not a directory"
        )
      }
    } else {
      guard errno == ENOENT else {
        throw IPSWCacheLayoutError.directoryPreparationFailed(path: url.path, message: posixMessage())
      }
      do {
        try FileManager.default.createDirectory(
          at: url,
          withIntermediateDirectories: withIntermediateDirectories,
          attributes: [.posixPermissions: 0o700]
        )
      } catch {
        throw IPSWCacheLayoutError.directoryPreparationFailed(
          path: url.path,
          message: error.localizedDescription
        )
      }
    }

    guard url.path.withCString({ Darwin.lstat($0, &status) }) == 0,
          status.st_mode & S_IFMT == S_IFDIR else
    {
      throw IPSWCacheLayoutError.directoryPreparationFailed(
        path: url.path,
        message: "created path is a symbolic link or not a directory"
      )
    }

    do {
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    } catch {
      throw IPSWCacheLayoutError.directoryPreparationFailed(path: url.path, message: error.localizedDescription)
    }
  }

  private static func originalFilename(for remoteURL: URL) -> String {
    guard let components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false) else {
      return fallbackFilename
    }
    let encodedPath = components.percentEncodedPath
    guard encodedPath.isEmpty == false, encodedPath.hasSuffix("/") == false,
          let encodedComponent = encodedPath.split(separator: "/", omittingEmptySubsequences: true).last,
          let filename = String(encodedComponent).removingPercentEncoding,
          isSafeFilename(filename) else
    {
      return fallbackFilename
    }
    return filename
  }

  private static func isSafeFilename(_ filename: String) -> Bool {
    guard filename.isEmpty == false, filename != ".", filename != "..",
          filename.utf8.count <= maximumNameByteCount,
          filename.contains("/") == false else
    {
      return false
    }
    return filename.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) == false }
  }

  private static func readableStem(for filename: String) -> String {
    let stem: String = if let extensionSeparator = filename.lastIndex(of: "."),
                          extensionSeparator != filename.startIndex
    {
      String(filename[..<extensionSeparator])
    } else {
      filename
    }
    return stem.isEmpty ? "restore" : stem
  }

  private static func urlDigest(for remoteURL: URL, byteCount: Int = 32) -> String {
    SHA256.hash(data: Data(remoteURL.absoluteString.utf8))
      .prefix(byteCount)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func prefix(_ value: String, fittingUTF8ByteCount limit: Int) -> String {
    var result = ""
    var byteCount = 0
    for character in value {
      let characterByteCount = String(character).utf8.count
      guard byteCount + characterByteCount <= limit else { break }
      result.append(character)
      byteCount += characterByteCount
    }
    return result.isEmpty ? "restore" : result
  }

  private static func posixMessage(_ code: Int32 = errno) -> String {
    String(cString: strerror(code))
  }
}
