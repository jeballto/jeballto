import Foundation

/// URLSession invokes delegate callbacks on its serial delegate queue. Cross-thread cancellation
/// and continuation ownership are protected by `lock`.
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  weak var installer: VMInstaller?
  private let lock = NSLock()
  private var continuation: CheckedContinuation<URL, Error>?
  private var downloadTask: URLSessionDownloadTask?
  private var isCancelled = false
  private let destinationURL: URL
  private var lastLoggedPercent: Int = -1
  private var lastProgressUpdateUptime: TimeInterval?
  private var lastSpeedCheckBytes: Int64 = 0
  private var lastCalculatedSpeed: UInt64 = 0

  init(installer: VMInstaller, destinationURL: URL) {
    self.installer = installer
    self.destinationURL = destinationURL
  }

  func startDownload(
    from url: URL,
    session: URLSession,
    continuation: CheckedContinuation<URL, Error>
  ) {
    lock.lock()
    guard !isCancelled else {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    let task = session.downloadTask(with: url)
    self.continuation = continuation
    downloadTask = task
    lock.unlock()
    task.resume()
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let task = downloadTask
    let continuation = continuation
    downloadTask = nil
    self.continuation = nil
    lock.unlock()
    task?.cancel()
    continuation?.resume(throwing: CancellationError())
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    finishDownload(at: location, response: downloadTask.response)
  }

  func finishDownload(at location: URL, response: URLResponse?) {
    do {
      try Self.validateHTTPResponse(response)
    } catch {
      takeContinuation()?.resume(throwing: error)
      clearTask()
      return
    }

    guard let continuation = takeContinuation() else {
      clearTask()
      return
    }

    // Move downloaded file to cache before temp is cleaned up
    do {
      try FileManager.default.moveItem(at: location, to: destinationURL)
      continuation.resume(returning: destinationURL)
    } catch {
      continuation.resume(throwing: VMInstallerError.restoreImageFetchFailed(
        "Failed to move downloaded file: \(error.localizedDescription)"
      ))
    }
    clearTask()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    // Called on transport errors. HTTP status failures are handled before moving the downloaded file.
    guard let error else { return } // success is handled in didFinishDownloadingTo
    if isCancellation(error) {
      takeContinuation()?.resume(throwing: CancellationError())
    } else {
      takeContinuation()?.resume(throwing: VMInstallerError.restoreImageFetchFailed(
        "Failed to download IPSW: \(error.localizedDescription)"
      ))
    }
    clearTask()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    do {
      try Self.validateRedirectTarget(request)
      completionHandler(request)
    } catch {
      takeContinuation()?.resume(throwing: error)
      clearTask()
      task.cancel()
      completionHandler(nil)
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard let installer else { return }

    // Throttle progress updates to every 0.5s to avoid flooding the event bus
    let now = ProcessInfo.processInfo.systemUptime
    let progressState = lock.withLock { () -> (speed: UInt64, shouldPublish: Bool) in
      let timeDelta = lastProgressUpdateUptime.map { now - $0 } ?? .infinity
      guard timeDelta >= 0.5 else { return (lastCalculatedSpeed, false) }

      let bytesDelta = totalBytesWritten - lastSpeedCheckBytes
      if bytesDelta > 0 {
        lastCalculatedSpeed = Self.safeBytesPerSecond(bytesDelta: bytesDelta, timeDelta: timeDelta)
      }
      lastProgressUpdateUptime = now
      lastSpeedCheckBytes = totalBytesWritten
      return (lastCalculatedSpeed, true)
    }
    guard progressState.shouldPublish else { return }

    let progressUpdate = Self.makeProgressUpdate(
      totalBytesWritten: totalBytesWritten,
      totalBytesExpectedToWrite: totalBytesExpectedToWrite,
      speedBytesPerSecond: progressState.speed
    )
    installer.updateDownloadProgress(
      progressUpdate.scaledProgress,
      phaseProgress: progressUpdate.phaseProgress,
      message: progressUpdate.message,
      bytesDownloaded: progressUpdate.bytesDownloaded,
      bytesTotal: progressUpdate.bytesTotal,
      downloadSpeed: progressState.speed
    )

    if let percent = progressUpdate.percent {
      let shouldLog = lock.withLock { () -> Bool in
        guard percent != lastLoggedPercent else { return false }
        lastLoggedPercent = percent
        return true
      }
      if shouldLog {
        logInfo("Download progress: \(percent)%", category: "VMInstaller")
      }
    }
  }

  static func validateHTTPResponse(_ response: URLResponse?) throws {
    guard let httpResponse = response as? HTTPURLResponse else {
      throw VMInstallerError.restoreImageFetchFailed("Download did not return an HTTP response")
    }

    guard (200 ... 299).contains(httpResponse.statusCode) else {
      throw VMInstallerError.restoreImageFetchFailed(
        "IPSW download failed with HTTP \(httpResponse.statusCode)"
      )
    }
    guard let finalURL = httpResponse.url else {
      throw VMInstallerError.restoreImageFetchFailed("IPSW download response is missing its final URL")
    }
    do {
      guard try IPSWSourceValidator.normalized(finalURL.absoluteString) != nil,
            finalURL.scheme?.lowercased() == "https" else
      {
        throw IPSWSourceValidationError.invalid("final URL is not HTTPS")
      }
    } catch {
      throw VMInstallerError.restoreImageFetchFailed(
        "IPSW download ended on an unsafe URL: \(error.localizedDescription)"
      )
    }
  }

  static func validateRedirectTarget(_ request: URLRequest) throws {
    guard let targetURL = request.url else {
      throw VMInstallerError.restoreImageFetchFailed("Refusing an IPSW redirect without a target URL")
    }
    do {
      guard try IPSWSourceValidator.normalized(targetURL.absoluteString) != nil,
            targetURL.scheme?.lowercased() == "https" else
      {
        throw IPSWSourceValidationError.invalid("redirect target is not HTTPS")
      }
    } catch {
      throw VMInstallerError.restoreImageFetchFailed(
        "Refusing an IPSW redirect to an unsafe URL: \(error.localizedDescription)"
      )
    }
  }

  static func makeProgressUpdate(
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64,
    speedBytesPerSecond: UInt64
  ) -> DownloadProgressUpdate {
    let bytesDownloaded = UInt64(max(0, totalBytesWritten))
    let downloadedMB = max(0, totalBytesWritten) / 1_000_000
    let speedMBps = Double(speedBytesPerSecond) / 1_000_000.0

    guard totalBytesExpectedToWrite > 0 else {
      let message = String(
        format: "Downloading: %lldMB downloaded %.1f MB/s",
        downloadedMB,
        speedMBps
      )
      return DownloadProgressUpdate(
        scaledProgress: -1.0,
        phaseProgress: -1.0,
        percent: nil,
        message: message,
        bytesDownloaded: bytesDownloaded,
        bytesTotal: nil
      )
    }

    let rawProgress = min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    let phaseProgress = (rawProgress * 100).rounded() / 100
    let scaledProgress = (rawProgress * VMInstaller.installStart * 100).rounded() / 100
    let totalMB = totalBytesExpectedToWrite / 1_000_000
    let percent = Int(phaseProgress * 100)
    let message = String(
      format: "Downloading: %d%% (%lldMB / %lldMB) %.1f MB/s",
      percent,
      downloadedMB,
      totalMB,
      speedMBps
    )

    return DownloadProgressUpdate(
      scaledProgress: scaledProgress,
      phaseProgress: phaseProgress,
      percent: percent,
      message: message,
      bytesDownloaded: bytesDownloaded,
      bytesTotal: UInt64(totalBytesExpectedToWrite)
    )
  }

  static func safeBytesPerSecond(bytesDelta: Int64, timeDelta: TimeInterval) -> UInt64 {
    guard bytesDelta > 0, timeDelta > 0, timeDelta.isFinite else { return 0 }
    let value = Double(bytesDelta) / timeDelta
    guard value > 0 else { return 0 }
    guard value.isFinite, value < Double(UInt64.max) else { return UInt64.max }
    return UInt64(value)
  }

  private func takeContinuation() -> CheckedContinuation<URL, Error>? {
    lock.lock()
    defer { lock.unlock() }
    let existing = continuation
    continuation = nil
    return existing
  }

  private func clearTask() {
    lock.lock()
    defer { lock.unlock() }
    downloadTask = nil
  }

  private func isCancellation(_ error: Error) -> Bool {
    lock.withLock {
      isCancelled || (error as? URLError)?.code == .cancelled
    }
  }
}

struct DownloadProgressUpdate: Equatable {
  let scaledProgress: Double
  let phaseProgress: Double
  let percent: Int?
  let message: String
  let bytesDownloaded: UInt64
  let bytesTotal: UInt64?
}
