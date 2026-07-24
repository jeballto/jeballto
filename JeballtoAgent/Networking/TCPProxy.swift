import Foundation
import Network

/// TCP proxy that forwards connections from a local port to a remote host:port
/// Uses Apple's Network framework for userspace TCP forwarding
final class TCPProxy: @unchecked Sendable {
  /// Local port to listen on (e.g., 2222 for SSH)
  let localPort: Int

  /// Remote host to forward to (VM NAT IP)
  private let remoteHost: String

  /// Remote port to forward to (e.g., 22 for SSH)
  private let remotePort: Int

  /// VM ID for logging
  private let vmId: UUID

  /// Network listener for incoming connections
  /// See: https://developer.apple.com/documentation/network/nwlistener
  private var listener: NWListener?

  /// Active connections being proxied
  private var activeConnections: [TCPProxyConnection] = []

  /// Queue for connection handling
  private let connectionQueue: DispatchQueue

  /// Is the proxy currently running (access only via connectionQueue)
  private var _isRunning = false

  /// Thread-safe read of isRunning
  var isRunning: Bool {
    connectionQueue.sync { _isRunning }
  }

  /// Called when the listener fails unexpectedly (for cleanup by owner)
  var onFailure: (() -> Void)?

  init(localPort: Int, remoteHost: String, remotePort: Int, vmId: UUID) {
    self.localPort = localPort
    self.remoteHost = remoteHost
    self.remotePort = remotePort
    self.vmId = vmId
    connectionQueue = DispatchQueue(label: "com.jeballto.tcpproxy.\(localPort)")
  }

  // MARK: - Lifecycle

  /// Starts the TCP proxy
  /// See: https://developer.apple.com/documentation/network/nwlistener
  func start() throws {
    let alreadyRunning = connectionQueue.sync { _isRunning }
    guard !alreadyRunning else {
      logWarning("TCP proxy already running on port \(localPort)", category: "TCPProxy")
      return
    }

    // Create TCP listener parameters
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

    // Create listener
    guard let rawLocalPort = UInt16(exactly: localPort), rawLocalPort > 0,
          let port = NWEndpoint.Port(rawValue: rawLocalPort) else
    {
      throw TCPProxyError.invalidPort(localPort)
    }
    guard let rawRemotePort = UInt16(exactly: remotePort), rawRemotePort > 0,
          NWEndpoint.Port(rawValue: rawRemotePort) != nil else
    {
      throw TCPProxyError.invalidRemotePort(remotePort)
    }

    do {
      let newListener = try NWListener(using: parameters, on: port)
      let readiness = NetworkListenerReadiness()

      // Set up new connection handler
      newListener.newConnectionHandler = { [weak self] connection in self?.handleNewConnection(connection) }

      // Set up state change handler
      newListener.stateUpdateHandler = { [weak self] state in
        self?.handleListenerStateChange(state)
        readiness.observe(state)
      }

      connectionQueue.sync {
        listener = newListener
        _isRunning = false
      }
      newListener.start(queue: connectionQueue)
      do {
        try readiness.wait(timeout: 5)
      } catch {
        connectionQueue.sync {
          if listener === newListener {
            listener = nil
            _isRunning = false
            newListener.newConnectionHandler = nil
            newListener.stateUpdateHandler = nil
            newListener.cancel()
          }
        }
        throw error
      }
      let ready = connectionQueue.sync {
        listener === newListener && _isRunning
      }
      guard ready else { throw TCPProxyError.listenerStoppedBeforeReady(localPort) }

      logInfo("TCP proxy started: localhost:\(localPort) -> \(remoteHost):\(remotePort)", category: "TCPProxy")
    } catch let error as TCPProxyError {
      throw error
    } catch {
      throw TCPProxyError.listenerFailed(error)
    }
  }

  /// Stops the TCP proxy
  func stop() {
    let stoppedAnything = connectionQueue.sync {
      let hadState = listener != nil || activeConnections.isEmpty == false || _isRunning
      listener?.newConnectionHandler = nil
      listener?.stateUpdateHandler = nil
      listener?.cancel()
      listener = nil
      for connection in activeConnections {
        connection.close()
      }
      activeConnections.removeAll()
      _isRunning = false
      onFailure = nil
      return hadState
    }

    if stoppedAnything {
      logInfo("TCP proxy stopped on port \(localPort)", category: "TCPProxy")
    }
  }

  // MARK: - Connection Handling

  private func handleNewConnection(_ clientConnection: NWConnection) {
    guard _isRunning else {
      clientConnection.cancel()
      return
    }
    guard let rawRemotePort = UInt16(exactly: remotePort),
          let endpointPort = NWEndpoint.Port(rawValue: rawRemotePort) else
    {
      logError("TCP proxy has invalid remote port \(remotePort)", category: "TCPProxy")
      clientConnection.cancel()
      return
    }
    logDebug("New connection to TCP proxy on port \(localPort)", category: "TCPProxy")

    // Create connection to remote host
    let remoteEndpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(remoteHost),
      port: endpointPort
    )

    let proxyConnection = TCPProxyConnection(
      clientConnection: clientConnection,
      remoteEndpoint: remoteEndpoint,
      queue: connectionQueue
    )

    activeConnections.append(proxyConnection)

    // Start proxying
    proxyConnection.start { [weak self, weak proxyConnection] in
      // Connection closed, remove from active list
      guard let proxyConnection else { return }
      self?.activeConnections.removeAll { $0 === proxyConnection }
    }
  }

  private func handleListenerStateChange(_ state: NWListener.State) {
    // This handler runs on connectionQueue, so direct _isRunning access is safe
    switch state {
    case .ready:
      _isRunning = true
      logDebug("TCP proxy listener ready on port \(localPort)", category: "TCPProxy")
    case .failed(let error):
      logError("TCP proxy listener failed on port \(localPort): \(error)", category: "TCPProxy")
      let failureHandler = onFailure
      onFailure = nil
      listener?.newConnectionHandler = nil
      listener?.stateUpdateHandler = nil
      listener?.cancel()
      listener = nil
      for connection in activeConnections {
        connection.close()
      }
      activeConnections.removeAll()
      _isRunning = false
      failureHandler?()
    case .cancelled:
      logDebug("TCP proxy listener cancelled on port \(localPort)", category: "TCPProxy")
      listener = nil
      _isRunning = false
    default: break
    }
  }

  // MARK: - Statistics

  /// Returns the number of active connections (thread-safe via connectionQueue)
  var activeConnectionCount: Int {
    connectionQueue.sync { activeConnections.count }
  }
}

// MARK: - TCP Proxy Connection

/// Represents a single proxied connection
/// Handles bidirectional data forwarding between client and remote
private final class TCPProxyConnection: @unchecked Sendable {
  private enum ForwardingDirection {
    case clientToRemote
    case remoteToClient
  }

  private let clientConnection: NWConnection
  private let remoteConnection: NWConnection
  private let queue: DispatchQueue
  private var onClose: (() -> Void)?
  private var isClosed = false
  private var clientToRemoteComplete = false
  private var remoteToClientComplete = false

  init(clientConnection: NWConnection, remoteEndpoint: NWEndpoint, queue: DispatchQueue) {
    self.clientConnection = clientConnection
    self.queue = queue

    // Create connection to remote
    let parameters = NWParameters.tcp
    remoteConnection = NWConnection(to: remoteEndpoint, using: parameters)
  }

  func start(onClose: @escaping () -> Void) {
    self.onClose = onClose

    clientConnection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled: self?.close()
      default: break
      }
    }

    // Wait for remote connection to be ready
    remoteConnection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        // Both connections ready, start forwarding
        self?.startForwarding()
      case .failed, .cancelled: self?.close()
      default: break
      }
    }

    // Install handlers before starting so an immediate failure cannot be missed.
    clientConnection.start(queue: queue)
    remoteConnection.start(queue: queue)
  }

  private func startForwarding() {
    // Forward data from client to remote
    forwardData(from: clientConnection, to: remoteConnection, direction: .clientToRemote)

    // Forward data from remote to client
    forwardData(from: remoteConnection, to: clientConnection, direction: .remoteToClient)
  }

  private func forwardData(
    from source: NWConnection,
    to destination: NWConnection,
    direction: ForwardingDirection
  ) {
    source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self else { return }

      if let data, !data.isEmpty {
        destination.send(
          content: data,
          contentContext: isComplete ? .finalMessage : .defaultMessage,
          isComplete: isComplete,
          completion: .contentProcessed { [weak self] sendError in
            guard let self else { return }
            if let sendError {
              logDebug("Error forwarding data: \(sendError)", category: "TCPProxy")
              close()
              return
            }

            if error != nil {
              close()
            } else if isComplete {
              markDirectionComplete(direction)
            } else {
              forwardData(from: source, to: destination, direction: direction)
            }
          }
        )
      } else if error != nil {
        close()
      } else if isComplete {
        destination.send(
          content: nil,
          contentContext: .finalMessage,
          isComplete: true,
          completion: .contentProcessed { [weak self] sendError in
            guard let self else { return }
            if let sendError {
              logDebug("Error forwarding TCP close: \(sendError)", category: "TCPProxy")
              close()
            } else {
              markDirectionComplete(direction)
            }
          }
        )
      } else {
        forwardData(from: source, to: destination, direction: direction)
      }
    }
  }

  private func markDirectionComplete(_ direction: ForwardingDirection) {
    switch direction {
    case .clientToRemote:
      clientToRemoteComplete = true
    case .remoteToClient:
      remoteToClientComplete = true
    }
    if clientToRemoteComplete, remoteToClientComplete {
      close()
    }
  }

  func close() {
    queue.async { [self] in
      guard !isClosed else { return }
      isClosed = true
      clientConnection.stateUpdateHandler = nil
      remoteConnection.stateUpdateHandler = nil
      clientConnection.cancel()
      remoteConnection.cancel()
      let closeHandler = onClose
      onClose = nil
      closeHandler?()
    }
  }
}

// MARK: - Errors

enum TCPProxyError: Error, LocalizedError {
  case invalidPort(Int)
  case invalidRemotePort(Int)
  case listenerFailed(Error)
  case listenerStoppedBeforeReady(Int)
  case forwardingAlreadyActive(vmId: UUID, port: Int)

  var errorDescription: String? {
    switch self {
    case .invalidPort(let port): "Invalid port number: \(port)"
    case .invalidRemotePort(let port): "Invalid remote port number: \(port)"
    case .listenerFailed(let error): "Failed to start listener: \(error.localizedDescription)"
    case .listenerStoppedBeforeReady(let port): "Listener on port \(port) stopped before startup completed"
    case .forwardingAlreadyActive(let vmId, let port):
      "Forwarding for VM \(vmId.uuidString) is already active on port \(port)"
    }
  }
}
