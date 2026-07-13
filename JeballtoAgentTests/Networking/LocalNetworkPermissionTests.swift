import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.concurrency))
struct LocalNetworkPermissionTests {
  @Test
  func completionGateKeepsTheFirstOutcome() {
    let gate = LocalNetworkPermissionCompletionGate()
    var completionCount = 0

    let completedFromSuccess = gate.performOnce(for: .accessGranted) {
      completionCount += 1
    }
    let completedFromTimeout = gate.performOnce(for: .timedOut) {
      completionCount += 1
    }

    #expect(completedFromSuccess)
    #expect(completedFromTimeout == false)
    #expect(completionCount == 1)
    #expect(gate.completedOutcome == .accessGranted)
  }

  @Test
  func completionGateKeepsCancellationAheadOfLateStartup() {
    let gate = LocalNetworkPermissionCompletionGate()
    var completionCount = 0

    #expect(gate.performOnce(for: .cancelled) {})
    if gate.completedOutcome != nil {
      completionCount += 1
    }
    #expect(gate.performOnce(for: .timedOut) { completionCount += 1 } == false)

    #expect(completionCount == 1)
    #expect(gate.completedOutcome == .cancelled)
  }

  @Test
  func triggerReturnsWithoutStartingDiscoveryUnderXCTest() async {
    await LocalNetworkPermission.trigger()
  }
}
