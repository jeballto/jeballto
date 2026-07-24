import Foundation
import Network
import Testing
@testable import JeballtoAgent

@Suite(.tags(.concurrency))
struct NetworkManagersTests {
  @Test
  func intentionalLocalNetworkBrowserCancellationIsNotReportedAsFailure() {
    #expect(LocalNetworkPermission.browserFailureDescription(.cancelled) == nil)
    #expect(
      LocalNetworkPermission.browserFailureDescription(.failed(.posix(.ECONNREFUSED))) != nil
    )
  }

  @Test(arguments: [-1, 0, 65536])
  func tcpProxyRejectsInvalidLocalPortsWithoutTrapping(_ port: Int) {
    let proxy = TCPProxy(localPort: port, remoteHost: "127.0.0.1", remotePort: 22, vmId: UUID())

    #expect(throws: TCPProxyError.self) {
      try proxy.start()
    }
  }

  @Test(arguments: [-1, 0, 65536])
  func tcpProxyRejectsInvalidRemotePortsWithoutTrapping(_ port: Int) {
    let proxy = TCPProxy(localPort: 22222, remoteHost: "127.0.0.1", remotePort: port, vmId: UUID())

    #expect(throws: TCPProxyError.self) {
      try proxy.start()
    }
  }

  @Test
  func listenerReadinessUsesATerminalResultAndBoundsItsWait() {
    let cancelled = NetworkListenerReadiness()
    cancelled.observe(.cancelled)
    #expect(throws: NetworkListenerReadiness.ReadinessError.self) {
      try cancelled.wait(timeout: 1)
    }

    let ready = NetworkListenerReadiness()
    ready.observe(.ready)
    ready.observe(.cancelled)
    #expect(throws: Never.self) {
      try ready.wait(timeout: 0)
    }

    let unresolved = NetworkListenerReadiness()
    do {
      try unresolved.wait(timeout: -1)
      Issue.record("Expected an unresolved listener readiness wait to time out")
    } catch NetworkListenerReadiness.ReadinessError.timedOut(let seconds) {
      #expect(seconds == 0)
    } catch {
      Issue.record("Unexpected readiness error: \(error)")
    }
  }

  @Test
  func portForwardingManagerAllocatesAndReleasesPorts() async {
    let bus = EventBus()
    let manager = PortForwardingManager(
      config: NetworkingConfig(
        sshPortRangeStart: 3000,
        sshPortRangeEnd: 3001,
        autoEnableSSHForwarding: false,
        vncPortRangeStart: 4000,
        vncPortRangeEnd: 4001
      ),
      eventBus: bus
    )

    let first = await manager.allocatePort()
    let second = await manager.allocatePort()
    let exhausted = await manager.allocatePort()

    #expect(first == 3000)
    #expect(second == 3001)
    #expect(exhausted == nil)

    if let first {
      await manager.releasePort(first)
      #expect(await manager.allocatePort() == 3000)
    }

    let firstVNC = await manager.allocateVNCPort()
    let secondVNC = await manager.allocateVNCPort()
    let exhaustedVNC = await manager.allocateVNCPort()

    #expect(firstVNC == 4000)
    #expect(secondVNC == 4001)
    #expect(exhaustedVNC == nil)
  }

  @Test
  func networkManagerTracksAllocatedMacAddresses() async {
    let manager = NetworkManager(eventBus: EventBus())
    var generated: Set<String> = []

    for _ in 0 ..< 20 {
      let mac = await manager.generateUniqueMACAddress()
      #expect(generated.contains(mac) == false)
      generated.insert(mac)
    }

    let manual = "02:aa:bb:cc:dd:ee"
    await manager.registerMACAddress(manual)
    #expect(await manager.isMACAddressAllocated(manual))

    await manager.releaseMACAddress(manual)
    #expect(await manager.isMACAddressAllocated(manual) == false)
    #expect(await manager.allocatedMACCount == generated.count)
  }

  @Test
  func portForwardingRegistrationBookkeepingIsConsistent() async {
    let manager = PortForwardingManager(
      config: NetworkingConfig(
        sshPortRangeStart: 3000,
        sshPortRangeEnd: 3010,
        autoEnableSSHForwarding: false,
        vncPortRangeStart: 4000,
        vncPortRangeEnd: 4010
      ),
      eventBus: EventBus()
    )

    await manager.registerPort(3007)
    await manager.registerPort(3003)
    await manager.registerVNCPort(4008)
    await manager.registerVNCPort(4002)

    #expect(await manager.isPortAllocated(3007))
    #expect(await manager.isVNCPortAllocated(4002))
    #expect(await manager.getAllocatedPorts() == [3003, 3007])
    #expect(await manager.getAllocatedVNCPorts() == [4002, 4008])

    await manager.releasePort(3007)
    await manager.releaseVNCPort(4008)
    #expect(await manager.isPortAllocated(3007) == false)
    #expect(await manager.isVNCPortAllocated(4008) == false)
  }

  @Test
  func atomicPortSetupRollsBackReservationWhenListenerCannotBind() async throws {
    let port = try freeLocalTCPPort()
    let blocker = SimpleHTTPServer(port: port, host: "127.0.0.1")
    blocker.get("/") { _ in HTTPResponse(statusCode: 200) }
    try blocker.start()

    let manager = PortForwardingManager(
      config: NetworkingConfig(
        sshPortRangeStart: Int(port),
        sshPortRangeEnd: Int(port),
        autoEnableSSHForwarding: false,
        vncPortRangeStart: 4000,
        vncPortRangeEnd: 4000
      ),
      eventBus: EventBus()
    )
    let vmId = UUID()

    await #expect(throws: TCPProxyError.self) {
      _ = try await manager.allocateAndSetupSSHForwarding(vmId: vmId, vmIPAddress: "127.0.0.1")
    }
    #expect(await manager.getAllocatedPorts().isEmpty)

    blocker.stop()
    try await Task.sleep(nanoseconds: 20_000_000)
    let allocated = try await manager.allocateAndSetupSSHForwarding(vmId: vmId, vmIPAddress: "127.0.0.1")
    #expect(allocated == Int(port))
    #expect(await manager.getAllocatedPorts() == [Int(port)])

    let idempotent = try await manager.allocateAndSetupSSHForwarding(vmId: vmId, vmIPAddress: "127.0.0.1")
    #expect(idempotent == Int(port))
    #expect(await manager.getAllocatedPorts() == [Int(port)])
    await manager.stopAllForwarding()
  }

  @Test
  func stoppingForwardingReportsTheReleaseAndUpdatesActivity() async throws {
    let port = try freeLocalTCPPort()
    let bus = EventBus()
    let manager = PortForwardingManager(
      config: NetworkingConfig(
        sshPortRangeStart: Int(port),
        sshPortRangeEnd: Int(port),
        autoEnableSSHForwarding: false,
        vncPortRangeStart: 4000,
        vncPortRangeEnd: 4000
      ),
      eventBus: bus
    )
    let vmId = UUID()

    let allocated = try await manager.allocateAndSetupSSHForwarding(vmId: vmId, vmIPAddress: "127.0.0.1")
    #expect(allocated == Int(port))
    #expect(await manager.isSSHForwardingActive(vmId: vmId))
    #expect(await manager.activeForwardingCount == 1)

    await manager.stopSSHForwarding(vmId: vmId)
    await bus.waitUntilIdle()

    #expect(await manager.isSSHForwardingActive(vmId: vmId) == false)
    #expect(await manager.activeForwardingCount == 0)
    #expect(bus.getEvents(forVM: vmId).map(\.event) == [
      .sshPortAssigned(vmId: vmId, port: Int(port)),
      .sshPortReleased(vmId: vmId),
    ])
  }

  @Test
  func networkManagerRegistrationUsesSetSemantics() async {
    let manager = NetworkManager(eventBus: EventBus())
    let mac = "02:ab:cd:ef:01:23"

    await manager.registerMACAddress(mac)
    await manager.registerMACAddress(mac)

    #expect(await manager.allocatedMACCount == 1)
    #expect(await manager.isMACAddressAllocated(mac))
    #expect(await manager.getAllocatedMACAddresses().contains(mac))
  }

  @Test
  func natResolutionRejectsNonPositiveAttemptCount() async {
    let manager = NetworkManager(eventBus: EventBus())

    #expect(await manager.resolveNATIP(macAddress: "02:ab:cd:ef:01:23", maxAttempts: 0) == nil)
  }
}
