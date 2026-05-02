import Foundation
import Network

/// Triggers the macOS local network permission dialog on first launch.
///
/// Uses both an NWListener (advertising a Bonjour service) and an NWBrowser
/// (discovering it) together. The browser's attempt to discover the listener's
/// service on the local network is what forces macOS to show the permission
/// dialog. This is the approach documented by Apple in TN3179.
enum LocalNetworkPermission {
  private static let serviceType = "_jeballto._tcp"
  private static let timeoutSeconds: TimeInterval = 5

  static func trigger() async {
    logInfo("Triggering local network permission check", category: "Network")

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resumeGate = LocalNetworkPermissionResumeGate(continuation: continuation)

      @Sendable func resume() {
        resumeGate.resume()
      }

      let queue = DispatchQueue(label: "com.jeballto.localnetwork.permission")

      // 1. Listener: advertise a Bonjour service on the local network
      guard let listener = try? NWListener(using: NWParameters(tls: .none, tcp: NWProtocolTCP.Options())) else {
        logWarning("Could not create local network listener", category: "Network")
        resume()
        return
      }
      listener.service = NWListener.Service(name: UUID().uuidString, type: serviceType)
      listener.newConnectionHandler = { $0.cancel() }

      // 2. Browser: discover the service - this triggers the permission dialog
      let parameters = NWParameters()
      parameters.includePeerToPeer = true
      let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)

      @Sendable func cleanup() {
        listener.cancel()
        browser.cancel()
        resume()
      }

      listener.stateUpdateHandler = { state in
        if case .failed = state { cleanup() }
      }

      browser.stateUpdateHandler = { state in
        switch state {
        case .ready:
          logInfo("Local network permission dialog triggered", category: "Network")
        case .failed:
          logWarning("Local network browser failed", category: "Network")
          cleanup()
        default:
          break
        }
      }

      browser.browseResultsChangedHandler = { results, _ in
        if !results.isEmpty {
          logInfo("Local network access granted", category: "Network")
          cleanup()
        }
      }

      listener.start(queue: queue)
      browser.start(queue: queue)

      queue.asyncAfter(deadline: .now() + timeoutSeconds) {
        logDebug("Local network permission check timed out, continuing", category: "Network")
        cleanup()
      }
    }
  }
}

private final class LocalNetworkPermissionResumeGate: @unchecked Sendable {
  private let continuation: CheckedContinuation<Void, Never>
  private let lock = NSLock()
  private var resumed = false

  init(continuation: CheckedContinuation<Void, Never>) {
    self.continuation = continuation
  }

  func resume() {
    lock.lock()
    defer { lock.unlock() }
    guard !resumed else { return }
    resumed = true
    continuation.resume()
  }
}
