import Testing
@testable import JeballtoAgent

struct ProcessExitObserverTests {
  @Test
  func finishBeforeWaitReturnsStoredStatus() async {
    let observer = ProcessExitObserver()

    observer.finish(17)

    #expect(await observer.wait() == 17)
    #expect(observer.pendingWaiterCount == 0)
  }

  @Test
  func waitBeforeFinishResumesWithStatus() async {
    let observer = ProcessExitObserver()
    let waiter = Task {
      await observer.wait()
    }
    while observer.pendingWaiterCount == 0 {
      await Task.yield()
    }

    observer.finish(23)

    #expect(await waiter.value == 23)
    #expect(observer.pendingWaiterCount == 0)
  }

  @Test
  func duplicateFinishKeepsFirstStatusAndResumesEveryWaiterOnce() async {
    let observer = ProcessExitObserver()
    let firstWaiter = Task {
      await observer.wait()
    }
    let secondWaiter = Task {
      await observer.wait()
    }
    while observer.pendingWaiterCount < 2 {
      await Task.yield()
    }

    observer.finish(31)
    observer.finish(47)

    #expect(await firstWaiter.value == 31)
    #expect(await secondWaiter.value == 31)
    #expect(await observer.wait() == 31)
  }
}
