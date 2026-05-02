import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.concurrency))
struct NetworkManagersTests {
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
  func networkManagerRegistrationUsesSetSemantics() async {
    let manager = NetworkManager(eventBus: EventBus())
    let mac = "02:ab:cd:ef:01:23"

    await manager.registerMACAddress(mac)
    await manager.registerMACAddress(mac)

    #expect(await manager.allocatedMACCount == 1)
    #expect(await manager.isMACAddressAllocated(mac))
    #expect(await manager.getAllocatedMACAddresses().contains(mac))
  }
}
