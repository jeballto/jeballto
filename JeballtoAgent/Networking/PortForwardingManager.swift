import Foundation
import Network

/// Manages SSH and VNC port forwarding for VM access
actor PortForwardingManager {
  /// Configuration
  private let config: NetworkingConfig

  /// Event bus for publishing events
  private let eventBus: EventBus

  /// Registry of active SSH TCP proxies
  private var activeProxies: [UUID: TCPProxy] = [:]

  /// Allocated SSH ports
  private var allocatedPorts: Set<Int> = []

  /// Registry of active VNC TCP proxies
  private var activeVNCProxies: [UUID: TCPProxy] = [:]

  /// Allocated VNC ports
  private var allocatedVNCPorts: Set<Int> = []

  init(config: NetworkingConfig, eventBus: EventBus) {
    self.config = config
    self.eventBus = eventBus
  }

  // MARK: - SSH Port Allocation

  /// Allocates a unique SSH forwarding port
  func allocatePort() -> Int? {
    for port in config.sshPortRangeStart ... config.sshPortRangeEnd where !allocatedPorts.contains(port) {
      allocatedPorts.insert(port)
      logInfo("Allocated SSH port: \(port)", category: "PortForwarding")
      return port
    }
    let range = "\(config.sshPortRangeStart)-\(config.sshPortRangeEnd)"
    logError("No available ports in range \(range)", category: "PortForwarding")
    return nil
  }

  /// Registers an existing port (when loading persisted VMs)
  func registerPort(_ port: Int) {
    allocatedPorts.insert(port)
    logDebug("Registered SSH port: \(port)", category: "PortForwarding")
  }

  /// Releases a port when VM is deleted
  func releasePort(_ port: Int) {
    allocatedPorts.remove(port)
    logDebug("Released SSH port: \(port)", category: "PortForwarding")
  }

  /// Checks if a port is already allocated
  func isPortAllocated(_ port: Int) -> Bool { allocatedPorts.contains(port) }

  // MARK: - SSH Port Forwarding Setup

  /// Sets up SSH port forwarding for a VM
  /// Creates TCP proxy: localhost:sshPort -> VM_NAT_IP:22
  func setupSSHForwarding(vmId: UUID, vmIPAddress: String, sshPort: Int) throws {
    let forwardInfo = "localhost:\(sshPort) -> \(vmIPAddress):22"
    logInfo("Setting up SSH forwarding for VM \(vmId): \(forwardInfo)", category: "PortForwarding")

    // Check if proxy already exists
    if activeProxies[vmId] != nil {
      logWarning("SSH forwarding already active for VM \(vmId)", category: "PortForwarding")
      return
    }

    // Create TCP proxy
    let proxy = TCPProxy(localPort: sshPort, remoteHost: vmIPAddress, remotePort: 22, vmId: vmId)

    // Set failure callback to clean up stale state if listener dies
    proxy.onFailure = { [weak self] in
      guard let self else { return }
      Task { await self.handleProxyFailure(vmId: vmId, type: .ssh) }
    }

    // Start proxy
    try proxy.start()

    // Store in registry
    activeProxies[vmId] = proxy

    // Publish event
    eventBus.publish(.sshPortAssigned(vmId: vmId, port: sshPort))

    logInfo("SSH forwarding active for VM \(vmId) on port \(sshPort)", category: "PortForwarding")
  }

  /// Stops SSH port forwarding for a VM and releases the allocated port
  func stopSSHForwarding(vmId: UUID) {
    logInfo("Stopping SSH forwarding for VM \(vmId)", category: "PortForwarding")

    if let proxy = activeProxies[vmId] {
      let port = proxy.localPort
      proxy.stop()
      activeProxies.removeValue(forKey: vmId)
      releasePort(port)
      logInfo("SSH forwarding stopped for VM \(vmId), port \(port) released", category: "PortForwarding")
    }
  }

  /// Checks if SSH forwarding is active for a VM
  func isSSHForwardingActive(vmId: UUID) -> Bool { activeProxies[vmId] != nil }

  // MARK: - VNC Port Allocation

  /// Allocates a unique VNC forwarding port
  func allocateVNCPort() -> Int? {
    for port in config.vncPortRangeStart ... config.vncPortRangeEnd where !allocatedVNCPorts.contains(port) {
      allocatedVNCPorts.insert(port)
      logInfo("Allocated VNC port: \(port)", category: "PortForwarding")
      return port
    }
    let range = "\(config.vncPortRangeStart)-\(config.vncPortRangeEnd)"
    logError("No available VNC ports in range \(range)", category: "PortForwarding")
    return nil
  }

  /// Registers an existing VNC port (when loading persisted VMs)
  func registerVNCPort(_ port: Int) {
    allocatedVNCPorts.insert(port)
    logDebug("Registered VNC port: \(port)", category: "PortForwarding")
  }

  /// Releases a VNC port
  func releaseVNCPort(_ port: Int) {
    allocatedVNCPorts.remove(port)
    logDebug("Released VNC port: \(port)", category: "PortForwarding")
  }

  /// Checks if a VNC port is already allocated
  func isVNCPortAllocated(_ port: Int) -> Bool { allocatedVNCPorts.contains(port) }

  // MARK: - VNC Port Forwarding Setup

  /// Sets up VNC port forwarding for a VM
  /// Creates TCP proxy: localhost:vncPort -> VM_NAT_IP:5900
  func setupVNCForwarding(vmId: UUID, vmIPAddress: String, vncPort: Int) throws {
    let forwardInfo = "localhost:\(vncPort) -> \(vmIPAddress):5900"
    logInfo("Setting up VNC forwarding for VM \(vmId): \(forwardInfo)", category: "PortForwarding")

    // Check if proxy already exists
    if activeVNCProxies[vmId] != nil {
      logWarning("VNC forwarding already active for VM \(vmId)", category: "PortForwarding")
      return
    }

    // Create TCP proxy
    let proxy = TCPProxy(localPort: vncPort, remoteHost: vmIPAddress, remotePort: 5900, vmId: vmId)

    // Set failure callback to clean up stale state if listener dies
    proxy.onFailure = { [weak self] in
      guard let self else { return }
      Task { await self.handleProxyFailure(vmId: vmId, type: .vnc) }
    }

    // Start proxy
    try proxy.start()

    // Store in registry
    activeVNCProxies[vmId] = proxy

    // Publish event
    eventBus.publish(.vncPortAssigned(vmId: vmId, port: vncPort))

    logInfo("VNC forwarding active for VM \(vmId) on port \(vncPort)", category: "PortForwarding")
  }

  /// Stops VNC port forwarding for a VM and releases the allocated port
  func stopVNCForwarding(vmId: UUID) {
    logInfo("Stopping VNC forwarding for VM \(vmId)", category: "PortForwarding")

    if let proxy = activeVNCProxies[vmId] {
      let port = proxy.localPort
      proxy.stop()
      activeVNCProxies.removeValue(forKey: vmId)
      releaseVNCPort(port)
      logInfo("VNC forwarding stopped for VM \(vmId), port \(port) released", category: "PortForwarding")
    }
  }

  /// Checks if VNC forwarding is active for a VM
  func isVNCForwardingActive(vmId: UUID) -> Bool { activeVNCProxies[vmId] != nil }

  // MARK: - Statistics

  /// Returns number of active SSH forwarding sessions
  var activeForwardingCount: Int { activeProxies.count }

  /// Returns number of active VNC forwarding sessions
  var activeVNCForwardingCount: Int { activeVNCProxies.count }

  /// Returns all allocated ports
  func getAllocatedPorts() -> [Int] { Array(allocatedPorts).sorted() }

  /// Returns all allocated VNC ports
  func getAllocatedVNCPorts() -> [Int] { Array(allocatedVNCPorts).sorted() }

  // MARK: - Proxy Failure Recovery

  private enum ProxyType { case ssh, vnc }

  /// Cleans up a proxy that failed unexpectedly (listener died)
  private func handleProxyFailure(vmId: UUID, type: ProxyType) {
    switch type {
    case .ssh:
      if let proxy = activeProxies.removeValue(forKey: vmId) {
        let port = proxy.localPort
        releasePort(port)
        logWarning(
          "SSH proxy failed for VM \(vmId) on port \(port), cleaned up stale state",
          category: "PortForwarding"
        )
      }
    case .vnc:
      if let proxy = activeVNCProxies.removeValue(forKey: vmId) {
        let port = proxy.localPort
        releaseVNCPort(port)
        logWarning(
          "VNC proxy failed for VM \(vmId) on port \(port), cleaned up stale state",
          category: "PortForwarding"
        )
      }
    }
  }

  // MARK: - Cleanup

  /// Stops all active port forwarding (SSH and VNC)
  func stopAllForwarding() {
    logInfo("Stopping all port forwarding", category: "PortForwarding")

    for proxy in activeProxies.values {
      proxy.stop()
    }
    activeProxies.removeAll()
    allocatedPorts.removeAll()

    for proxy in activeVNCProxies.values {
      proxy.stop()
    }
    activeVNCProxies.removeAll()
    allocatedVNCPorts.removeAll()

    logInfo("All port forwarding stopped", category: "PortForwarding")
  }
}
