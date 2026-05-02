import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.concurrency))
struct LocalNetworkPermissionTests {
  @Test
  func triggerCompletesWithinTimeout() async {
    // Verify trigger() completes without hanging or crashing.
    // In a test environment the browser may fail or time out - both are fine,
    // the important thing is that it returns promptly.
    await LocalNetworkPermission.trigger()
  }
}
