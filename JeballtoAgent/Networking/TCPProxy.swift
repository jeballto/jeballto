import Foundation
import Network

/// TCP proxy that forwards connections from a local port to a remote host:port
/// Uses Apple's Network framework for userspace TCP forwarding
class TCPProxy {
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

    // Create listener
    guard let port = NWEndpoint.Port(rawValue: UInt16(localPort)) else { throw TCPProxyError.invalidPort(localPort) }

    do {
      let newListener = try NWListener(using: parameters, on: port)

      // Set up new connection handler
      newListener.newConnectionHandler = { [weak self] connection in self?.handleNewConnection(connection) }

      // Set up state change handler
      newListener.stateUpdateHandler = { [weak self] state in self?.handleListenerStateChange(state) }

      // Start listening
      newListener.start(queue: connectionQueue)

      listener = newListener
      // isRunning set in handleListenerStateChange when listener reaches .ready state

      logInfo("TCP proxy started: localhost:\(localPort) -> \(remoteHost):\(remotePort)", category: "TCPProxy")
    } catch { throw TCPProxyError.listenerFailed(error) }
  }

  /// Stops the TCP proxy
  func stop() {
    let wasRunning = connectionQueue.sync { _isRunning }
    guard wasRunning else { return }

    logInfo("Stopping TCP proxy on port \(localPort)", category: "TCPProxy")

    connectionQueue.sync {
      listener?.cancel()
      listener = nil
      for connection in activeConnections {
        connection.close()
      }
      activeConnections.removeAll()
      _isRunning = false
    }

    logInfo("TCP proxy stopped on port \(localPort)", category: "TCPProxy")
  }

  // MARK: - Connection Handling

  private func handleNewConnection(_ clientConnection: NWConnection) {
    logDebug("New connection to TCP proxy on port \(localPort)", category: "TCPProxy")

    // Create connection to remote host
    let remoteEndpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(remoteHost),
      port: NWEndpoint.Port(integerLiteral: UInt16(remotePort))
    )

    let proxyConnection = TCPProxyConnection(
      clientConnection: clientConnection,
      remoteEndpoint: remoteEndpoint,
      queue: connectionQueue
    )

    activeConnections.append(proxyConnection)

    // Start proxying
    proxyConnection.start { [weak self] in
      // Connection closed, remove from active list
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
      _isRunning = false
      onFailure?()
    case .cancelled:
      logDebug("TCP proxy listener cancelled on port \(localPort)", category: "TCPProxy")
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
private class TCPProxyConnection {
  private let clientConnection: NWConnection
  private let remoteConnection: NWConnection
  private let queue: DispatchQueue
  private var onClose: (() -> Void)?
  private var isClosed = false

  init(clientConnection: NWConnection, remoteEndpoint: NWEndpoint, queue: DispatchQueue) {
    self.clientConnection = clientConnection
    self.queue = queue

    // Create connection to remote
    let parameters = NWParameters.tcp
    remoteConnection = NWConnection(to: remoteEndpoint, using: parameters)
  }

  func start(onClose: @escaping () -> Void) {
    self.onClose = onClose

    // Start both connections
    clientConnection.start(queue: queue)
    remoteConnection.start(queue: queue)

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
  }

  private func startForwarding() {
    // Forward data from client to remote
    forwardData(from: clientConnection, to: remoteConnection)

    // Forward data from remote to client
    forwardData(from: remoteConnection, to: clientConnection)
  }

  private func forwardData(from source: NWConnection, to destination: NWConnection) {
    source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self else { return }

      if let data, !data.isEmpty {
        // Forward data to destination
        destination.send(
          content: data,
          completion: .contentProcessed { [weak self] sendError in
            guard let self else { return }
            if let sendError {
              logDebug("Error forwarding data: \(sendError)", category: "TCPProxy")
              close()
              return
            }

            // Close after delivering the final chunk, or continue receiving
            if isComplete || error != nil {
              close()
            } else {
              forwardData(from: source, to: destination)
            }
          }
        )
      } else if isComplete || error != nil {
        // No data to send, close immediately
        close()
      }
    }
  }

  func close() {
    queue.async { [self] in
      guard !isClosed else { return }
      isClosed = true
      clientConnection.cancel()
      remoteConnection.cancel()
      onClose?()
    }
  }
}

// MARK: - Errors

enum TCPProxyError: Error, LocalizedError {
  case invalidPort(Int)
  case listenerFailed(Error)
  case connectionFailed(Error)

  var errorDescription: String? {
    switch self {
    case .invalidPort(let port): "Invalid port number: \(port)"
    case .listenerFailed(let error): "Failed to start listener: \(error.localizedDescription)"
    case .connectionFailed(let error): "Connection failed: \(error.localizedDescription)"
    }
  }
}
