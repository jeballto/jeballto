import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.concurrency))
struct EventBusTests {
  @Test
  func subscribePublishAndUnsubscribeWork() async {
    let bus = EventBus(maxHistorySize: 20)
    let recorder = EventRecorder()

    let token = bus.subscribe { event in
      recorder.append(event)
    }

    #expect(bus.subscriberCount == 1)

    let vmId = UUID()
    bus.publish(.vmCreated(vmId: vmId, name: "one"))

    let delivered = await waitUntil {
      recorder.count == 1
    }
    #expect(delivered)

    bus.unsubscribe(token)
    #expect(bus.subscriberCount == 0)

    bus.publish(.vmCreated(vmId: UUID(), name: "two"))
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(recorder.count == 1)
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

private final class EventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [VMEvent] = []

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return events.count
  }

  func append(_ event: VMEvent) {
    lock.lock()
    defer { lock.unlock() }
    events.append(event)
  }
}
