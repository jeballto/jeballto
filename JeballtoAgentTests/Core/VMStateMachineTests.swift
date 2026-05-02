import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct VMStateMachineTests {
  @Test
  func transitionRecordsHistory() throws {
    let sut = VMStateMachine(initialState: .created)

    try sut.transition(to: .installing)
    try sut.transition(to: .stopped)

    #expect(sut.currentState == .stopped)
    #expect(sut.transitionHistory.count == 2)
    #expect(sut.transitionHistory[0] == VMStateTransition(from: .created, to: .installing))
    #expect(sut.transitionHistory[1] == VMStateTransition(from: .installing, to: .stopped))
  }

  @Test
  func alreadyInTargetStateThrows() {
    let sut = VMStateMachine(initialState: .created)

    #expect(throws: VMStateMachineError.self) {
      try sut.transition(to: .created)
    }
  }

  @Test
  func terminalStateRejectsTransitions() {
    let sut = VMStateMachine(initialState: .deleted)

    #expect(throws: VMStateMachineError.self) {
      try sut.transition(to: .running)
    }
    #expect(sut.canTransition(to: .running) == false)
  }

  @Test
  func invalidTransitionThrows() {
    let sut = VMStateMachine(initialState: .running)

    #expect(throws: VMStateMachineError.self) {
      try sut.transition(to: .created)
    }
  }

  @Test
  func forceStateAddsTransition() {
    let sut = VMStateMachine(initialState: .created)

    sut.forceState(.error)

    #expect(sut.currentState == .error)
    #expect(sut.transitionHistory == [VMStateTransition(from: .created, to: .error)])
  }

  @Test
  func resetClearsHistoryAndRestoresState() throws {
    let sut = VMStateMachine(initialState: .created)
    try sut.transition(to: .installing)

    sut.reset(to: .stopped)

    #expect(sut.currentState == .stopped)
    #expect(sut.transitionHistory.isEmpty)
  }

  @Test
  func historyIsTrimmedToConfiguredMaximum() throws {
    let sut = VMStateMachine(initialState: .created, maxHistorySize: 2)

    try sut.transition(to: .installing)
    try sut.transition(to: .stopped)
    try sut.transition(to: .starting)

    #expect(sut.transitionHistory.count == 2)
    #expect(sut.transitionHistory[0] == VMStateTransition(from: .installing, to: .stopped))
    #expect(sut.transitionHistory[1] == VMStateTransition(from: .stopped, to: .starting))
  }
}
