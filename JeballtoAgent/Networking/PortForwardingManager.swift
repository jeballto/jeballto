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
    if allocatedPorts.insert(port).inserted {
      logDebug("Registered SSH port: \(port)", category: "PortForwarding")
    }
  }

  /// Releases a port when VM is deleted
  func releasePort(_ port: Int) {
    if allocatedPorts.remove(port) != nil {
      logDebug("Released SSH port: \(port)", category: "PortForwarding")
    }
  }

  /// Checks if a port is already allocated
  func isPortAllocated(_ port: Int) -> Bool { allocatedPorts.contains(port) }

  // MARK: - SSH Port Forwarding Setup

  /// Atomically allocates a port and starts SSH forwarding.
  /// Returns the existing active port when forwarding is already configured for the VM.
  func allocateAndSetupSSHForwarding(vmId: UUID, vmIPAddress: String) throws -> Int? {
    if let existing = activeProxies[vmId] {
      if existing.isRunning {
        return existing.localPort
      }
      let port = existing.localPort
      existing.stop()
      activeProxies.removeValue(forKey: vmId)
      releasePort(port)
    }

    guard let port = allocatePort() else { return nil }
    do {
      try setupSSHForwarding(vmId: vmId, vmIPAddress: vmIPAddress, sshPort: port)
      return port
    } catch {
      releasePort(port)
      throw error
    }
  }

  /// Sets up SSH port forwarding for a VM
  /// Creates TCP proxy: localhost:sshPort -> VM_NAT_IP:22
  private func setupSSHForwarding(vmId: UUID, vmIPAddress: String, sshPort: Int) throws {
    let forwardInfo = "localhost:\(sshPort) -> \(vmIPAddress):22"
    logInfo("Setting up SSH forwarding for VM \(vmId): \(forwardInfo)", category: "PortForwarding")

    // Check if proxy already exists
    if let existing = activeProxies[vmId] {
      guard existing.localPort == sshPort, existing.isRunning else {
        throw TCPProxyError.forwardingAlreadyActive(vmId: vmId, port: existing.localPort)
      }
      return
    }

    // Create TCP proxy
    let proxy = TCPProxy(localPort: sshPort, remoteHost: vmIPAddress, remotePort: 22, vmId: vmId)

    // Set failure callback to clean up stale state if listener dies
    proxy.onFailure = { [weak self, weak proxy] in
      guard let self, let proxy else { return }
      Task<Void, Never> { await self.handleProxyFailure(vmId: vmId, type: .ssh, failedProxy: proxy) }
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
      eventBus.publish(.sshPortReleased(vmId: vmId))
      logInfo("SSH forwarding stopped for VM \(vmId), port \(port) released", category: "PortForwarding")
    }
  }

  /// Checks if SSH forwarding is active for a VM
  func isSSHForwardingActive(vmId: UUID) -> Bool { activeProxies[vmId]?.isRunning == true }

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
    if allocatedVNCPorts.insert(port).inserted {
      logDebug("Registered VNC port: \(port)", category: "PortForwarding")
    }
  }

  /// Releases a VNC port
  func releaseVNCPort(_ port: Int) {
    if allocatedVNCPorts.remove(port) != nil {
      logDebug("Released VNC port: \(port)", category: "PortForwarding")
    }
  }

  /// Checks if a VNC port is already allocated
  func isVNCPortAllocated(_ port: Int) -> Bool { allocatedVNCPorts.contains(port) }

  // MARK: - VNC Port Forwarding Setup

  /// Atomically allocates a port and starts VNC forwarding.
  /// Returns the existing active port when forwarding is already configured for the VM.
  func allocateAndSetupVNCForwarding(vmId: UUID, vmIPAddress: String) throws -> Int? {
    if let existing = activeVNCProxies[vmId] {
      if existing.isRunning {
        return existing.localPort
      }
      let port = existing.localPort
      existing.stop()
      activeVNCProxies.removeValue(forKey: vmId)
      releaseVNCPort(port)
    }

    guard let port = allocateVNCPort() else { return nil }
    do {
      try setupVNCForwarding(vmId: vmId, vmIPAddress: vmIPAddress, vncPort: port)
      return port
    } catch {
      releaseVNCPort(port)
      throw error
    }
  }

  /// Sets up VNC port forwarding for a VM
  /// Creates TCP proxy: localhost:vncPort -> VM_NAT_IP:5900
  private func setupVNCForwarding(vmId: UUID, vmIPAddress: String, vncPort: Int) throws {
    let forwardInfo = "localhost:\(vncPort) -> \(vmIPAddress):5900"
    logInfo("Setting up VNC forwarding for VM \(vmId): \(forwardInfo)", category: "PortForwarding")

    // Check if proxy already exists
    if let existing = activeVNCProxies[vmId] {
      guard existing.localPort == vncPort, existing.isRunning else {
        throw TCPProxyError.forwardingAlreadyActive(vmId: vmId, port: existing.localPort)
      }
      return
    }

    // Create TCP proxy
    let proxy = TCPProxy(localPort: vncPort, remoteHost: vmIPAddress, remotePort: 5900, vmId: vmId)

    // Set failure callback to clean up stale state if listener dies
    proxy.onFailure = { [weak self, weak proxy] in
      guard let self, let proxy else { return }
      Task<Void, Never> { await self.handleProxyFailure(vmId: vmId, type: .vnc, failedProxy: proxy) }
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
      eventBus.publish(.vncPortReleased(vmId: vmId))
      logInfo("VNC forwarding stopped for VM \(vmId), port \(port) released", category: "PortForwarding")
    }
  }

  /// Checks if VNC forwarding is active for a VM
  func isVNCForwardingActive(vmId: UUID) -> Bool { activeVNCProxies[vmId]?.isRunning == true }

  // MARK: - Statistics

  /// Returns number of active SSH forwarding sessions
  var activeForwardingCount: Int { activeProxies.values.count(where: \.isRunning) }

  /// Returns number of active VNC forwarding sessions
  var activeVNCForwardingCount: Int { activeVNCProxies.values.count(where: \.isRunning) }

  /// Returns all allocated ports
  func getAllocatedPorts() -> [Int] { Array(allocatedPorts).sorted() }

  /// Returns all allocated VNC ports
  func getAllocatedVNCPorts() -> [Int] { Array(allocatedVNCPorts).sorted() }

  // MARK: - Proxy Failure Recovery

  private enum ProxyType { case ssh, vnc }

  /// Marks a proxy unavailable after its listener dies. The port reservation remains owned by the VM until a
  /// caller explicitly disables or repairs forwarding, preventing another VM from taking a still-persisted port.
  private func handleProxyFailure(vmId: UUID, type: ProxyType, failedProxy: TCPProxy) {
    switch type {
    case .ssh:
      guard activeProxies[vmId] === failedProxy else { return }
      logWarning(
        "SSH proxy failed for VM \(vmId) on port \(failedProxy.localPort), forwarding is unavailable until repaired",
        category: "PortForwarding"
      )
    case .vnc:
      guard activeVNCProxies[vmId] === failedProxy else { return }
      logWarning(
        "VNC proxy failed for VM \(vmId) on port \(failedProxy.localPort), forwarding is unavailable until repaired",
        category: "PortForwarding"
      )
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
