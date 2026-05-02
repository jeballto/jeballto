import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct VMStateTests {
  @Test(arguments: [
    (VMState.created, VMState.installing),
    (VMState.created, VMState.starting),
    (VMState.installing, VMState.stopped),
    (VMState.stopped, VMState.starting),
    (VMState.starting, VMState.running),
    (VMState.running, VMState.pausing),
    (VMState.paused, VMState.resuming),
    (VMState.resuming, VMState.running),
    (VMState.error, VMState.deleted),
  ])
  func validTransitionsAreAllowed(_ input: (from: VMState, to: VMState)) {
    #expect(input.from.canTransition(to: input.to))
  }

  @Test(arguments: [
    (VMState.running, VMState.created),
    (VMState.paused, VMState.installing),
    (VMState.deleted, VMState.running),
    (VMState.starting, VMState.stopped),
  ])
  func invalidTransitionsAreRejected(_ input: (from: VMState, to: VMState)) {
    #expect(input.from.canTransition(to: input.to) == false)
  }

  @Test(arguments: VMState.allCases)
  func onlyDeletedStateIsTerminal(_ state: VMState) {
    #expect(state.isTerminal == (state == .deleted))
  }

  @Test(arguments: VMState.allCases)
  func onlyRunningAndPausedAreOperational(_ state: VMState) {
    let expected = state == .running || state == .paused
    #expect(state.isOperational == expected)
  }

  @Test(arguments: VMState.allCases)
  func noStateCanTransitionToItself(_ state: VMState) {
    #expect(state.canTransition(to: state) == false)
  }
}
