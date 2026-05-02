import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.concurrency))
struct EventBusTests {
  @Test
  func subscribePublishAndUnsubscribeWork() async {
    let bus = EventBus(maxHistorySize: 20)
    let lock = NSLock()
    var received: [VMEvent] = []

    let token = bus.subscribe { event in
      lock.lock()
      received.append(event)
      lock.unlock()
    }

    let subscribed = await waitUntil { bus.subscriberCount == 1 }
    #expect(subscribed)

    let vmId = UUID()
    bus.publish(.vmCreated(vmId: vmId, name: "one"))

    let delivered = await waitUntil {
      lock.lock()
      defer { lock.unlock() }
      return received.count == 1
    }
    #expect(delivered)

    bus.unsubscribe(token)
    let unsubscribed = await waitUntil { bus.subscriberCount == 0 }
    #expect(unsubscribed)

    bus.publish(.vmCreated(vmId: UUID(), name: "two"))
    try? await Task.sleep(nanoseconds: 50_000_000)

    lock.lock()
    defer { lock.unlock() }
    #expect(received.count == 1)
  }

  @Test
  func historyIsTrimmedAndFilteredByVm() async {
    let bus = EventBus(maxHistorySize: 3)
    let vm1 = UUID()
    let vm2 = UUID()

    bus.publish(.vmCreated(vmId: vm1, name: "one"))
    bus.publish(.vmStarting(vmId: vm1))
    bus.publish(.vmRunning(vmId: vm1))
    bus.publish(.vmCreated(vmId: vm2, name: "two"))

    let trimmed = await waitUntil { bus.eventCount == 3 }
    #expect(trimmed)

    let all = bus.getAllEvents(limit: 10)
    #expect(all.count == 3)

    let vm1Events = bus.getEvents(forVM: vm1, limit: 10)
    #expect(vm1Events.isEmpty == false)
    #expect(vm1Events.allSatisfy { $0.event.vmId == vm1 })
  }

  @Test
  func getLimitParameterIsRespected() async {
    let bus = EventBus(maxHistorySize: 100)
    let vmId = UUID()

    for _ in 0 ..< 5 {
      bus.publish(.stateChanged(vmId: vmId, from: .created, to: .stopped))
    }

    let ready = await waitUntil { bus.eventCount == 5 }
    #expect(ready)

    let limited = bus.getEvents(forVM: vmId, limit: 2)
    #expect(limited.count == 2)
  }

  @Test
  func imageEventsAreNotReturnedByVmFilter() async {
    let bus = EventBus(maxHistorySize: 10)
    let vmId = UUID()

    bus.publish(.imagePulled(reference: "registry.example.com/vm:latest"))
    bus.publish(.imagePushFailed(reference: "registry.example.com/vm:latest", error: "timeout"))

    let ready = await waitUntil { bus.eventCount == 2 }
    #expect(ready)

    let vmEvents = bus.getEvents(forVM: vmId, limit: 10)
    #expect(vmEvents.isEmpty)
  }

  @Test
  func clearHistoryRemovesStoredEvents() async {
    let bus = EventBus(maxHistorySize: 10)
    bus.publish(.vmCreated(vmId: UUID(), name: "one"))
    bus.publish(.vmCreated(vmId: UUID(), name: "two"))

    let hasEvents = await waitUntil { bus.eventCount == 2 }
    #expect(hasEvents)

    bus.clearHistory()
    let cleared = await waitUntil { bus.eventCount == 0 }
    #expect(cleared)
    #expect(bus.getAllEvents(limit: 10).isEmpty)
  }
}
