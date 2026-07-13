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
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      logDebug("Skipping local network permission check under XCTest", category: "Network")
      return
    }

    logInfo("Triggering local network permission check", category: "Network")

    do {
      let session = try LocalNetworkPermissionSession(
        serviceType: serviceType,
        timeoutSeconds: timeoutSeconds
      )
      await withTaskCancellationHandler {
        await session.run()
      } onCancel: {
        session.cancel()
      }
    } catch {
      logWarning(
        "Could not create local network permission listener: \(error.localizedDescription)",
        category: "Network"
      )
    }
  }

  static func browserFailureDescription(_ state: NWBrowser.State) -> String? {
    guard case .failed(let error) = state else { return nil }
    return error.localizedDescription
  }
}

final class LocalNetworkPermissionCompletionGate: @unchecked Sendable {
  enum Outcome: Equatable, Sendable {
    case accessGranted
    case listenerFailed(String)
    case browserFailed(String)
    case cancelled
    case timedOut
  }

  private let lock = NSLock()
  private var outcome: Outcome?

  @discardableResult
  func performOnce(for outcome: Outcome, _ action: () -> Void) -> Bool {
    let won = lock.withLock { () -> Bool in
      guard self.outcome == nil else { return false }
      self.outcome = outcome
      return true
    }
    guard won else { return false }
    action()
    return true
  }

  var completedOutcome: Outcome? {
    lock.withLock { outcome }
  }
}

private final class LocalNetworkPermissionSession: @unchecked Sendable {
  private let listener: NWListener
  private let browser: NWBrowser
  private let queue = DispatchQueue(label: "com.jeballto.localnetwork.permission")
  private let timeoutSeconds: TimeInterval
  private let completionGate = LocalNetworkPermissionCompletionGate()
  private var timeoutWorkItem: DispatchWorkItem?
  private var completion: (() -> Void)?

  init(serviceType: String, timeoutSeconds: TimeInterval) throws {
    let listener = try NWListener(using: NWParameters(tls: .none, tcp: NWProtocolTCP.Options()))
    listener.service = NWListener.Service(name: UUID().uuidString, type: serviceType)
    self.listener = listener

    let parameters = NWParameters()
    parameters.includePeerToPeer = true
    browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
    self.timeoutSeconds = timeoutSeconds
  }

  func run() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { [self] in
        completion = { continuation.resume() }
        guard completionGate.completedOutcome == nil else {
          let completion = completion
          self.completion = nil
          completion?()
          return
        }

        listener.newConnectionHandler = { connection in
          connection.cancel()
        }
        listener.stateUpdateHandler = { [weak self] state in
          guard let self else { return }
          switch state {
          case .failed(let error):
            finish(.listenerFailed(error.localizedDescription))
          case .cancelled:
            finish(.cancelled)
          default:
            break
          }
        }

        browser.stateUpdateHandler = { [weak self] state in
          guard let self else { return }
          switch state {
          case .ready:
            logInfo("Local network permission browser is ready", category: "Network")
          case .failed(let error):
            finish(.browserFailed(error.localizedDescription))
          case .cancelled:
            finish(.cancelled)
          default:
            break
          }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
          guard results.isEmpty == false else { return }
          self?.finish(.accessGranted)
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
          self?.finish(.timedOut)
        }
        self.timeoutWorkItem = timeoutWorkItem

        listener.start(queue: queue)
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)
      }
    }
    withExtendedLifetime(self) {}
  }

  func cancel() {
    queue.async { [weak self] in
      self?.finish(.cancelled)
    }
  }

  private func finish(_ outcome: LocalNetworkPermissionCompletionGate.Outcome) {
    completionGate.performOnce(for: outcome) { [self] in
      timeoutWorkItem?.cancel()
      timeoutWorkItem = nil

      listener.newConnectionHandler = nil
      listener.stateUpdateHandler = nil
      browser.stateUpdateHandler = nil
      browser.browseResultsChangedHandler = nil
      listener.cancel()
      browser.cancel()

      switch outcome {
      case .accessGranted:
        logInfo("Local network access granted", category: "Network")
      case .listenerFailed(let message):
        logWarning("Local network listener failed: \(message)", category: "Network")
      case .browserFailed(let message):
        logWarning("Local network browser failed: \(message)", category: "Network")
      case .cancelled:
        break
      case .timedOut:
        logDebug("Local network permission check timed out, continuing", category: "Network")
      }

      let completion = completion
      self.completion = nil
      completion?()
    }
  }
}
