import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiModels))
struct JeballtofileValidationTests {
  @Test
  func fileSourceIsDecodedExactlyOnce() {
    #expect(JeballtofileExecutor.resolveIPSWSource("file:///tmp/macOS%20image.ipsw") == "/tmp/macOS image.ipsw")
    #expect(JeballtofileExecutor.resolveIPSWSource("file:///tmp/%252e%252e/image.ipsw") == "/tmp/%2e%2e/image.ipsw")
  }

  @Test
  func jeballtofileRequestRequiresSteps() {
    let request = JeballtofileRequest(name: "vm", source: nil, resources: nil, steps: [])
    let validation = request.validate()

    #expect(validation.valid == false)
    #expect(validation.error?.contains("steps") == true)
  }

  @Test
  func jeballtofileRequestRejectsExcessiveStepCount() {
    let step = JeballtofileStep(
      type: .wait,
      keystrokes: nil,
      command: nil,
      user: nil,
      password: nil,
      timeout: nil,
      seconds: 1
    )
    let request = JeballtofileRequest(
      name: "vm",
      source: nil,
      resources: nil,
      steps: Array(repeating: step, count: JeballtofileRequest.maximumSteps + 1)
    )

    #expect(request.validate().valid == false)
    #expect(request.validate().error?.contains("max 1000") == true)
  }

  @Test
  func jeballtofileRequestAllowsInstallStepWithoutSource() {
    let request = JeballtofileRequest(
      name: "vm",
      source: nil,
      resources: nil,
      steps: [JeballtofileStep(
        type: .install,
        keystrokes: nil,
        command: nil,
        user: nil,
        password: nil,
        timeout: nil,
        seconds: nil
      )]
    )
    let validation = request.validate()

    #expect(validation.valid)
  }

  @Test
  func jeballtofileRequestValidatesInstallSourceFormat() {
    let request = JeballtofileRequest(
      name: "vm",
      source: "http://example.com/file.ipsw",
      resources: nil,
      steps: [JeballtofileStep(
        type: .install,
        keystrokes: nil,
        command: nil,
        user: nil,
        password: nil,
        timeout: nil,
        seconds: nil
      )]
    )

    #expect(request.validate().valid == false)
  }

  @Test
  func jeballtofileRejectsSourceWithoutInstallAndDuplicateInstallSteps() {
    let wait = JeballtofileStep(
      type: .wait,
      keystrokes: nil,
      command: nil,
      user: nil,
      password: nil,
      timeout: nil,
      seconds: 1
    )
    let install = JeballtofileStep(
      type: .install,
      keystrokes: nil,
      command: nil,
      user: nil,
      password: nil,
      timeout: nil,
      seconds: nil
    )

    #expect(
      JeballtofileRequest(name: "vm", source: "/tmp/test.ipsw", resources: nil, steps: [wait])
        .validate().valid == false
    )
    #expect(
      JeballtofileRequest(name: "vm", source: nil, resources: nil, steps: [install, install])
        .validate().valid == false
    )
  }

  @Test
  func jeballtofileRejectsFieldsThatDoNotBelongToStepType() {
    let waitWithCommand = JeballtofileStep(
      type: .wait,
      keystrokes: nil,
      command: "ignored before this fix",
      user: nil,
      password: nil,
      timeout: nil,
      seconds: 1
    )
    let installWithTimeout = JeballtofileStep(
      type: .install,
      keystrokes: nil,
      command: nil,
      user: nil,
      password: nil,
      timeout: 30,
      seconds: nil
    )

    #expect(waitWithCommand.validate().valid == false)
    #expect(installWithTimeout.validate().valid == false)
  }

  @Test
  func jeballtofileRejectsStepsThatAreGuaranteedToFailForThePriorState() {
    let install = makeStep(.install)
    let start = makeStep(.start)
    let stop = makeStep(.stop)
    let execute = makeStep(.execute, command: "true")
    let keystrokes = makeStep(.keystrokes, keystrokes: ["<enter>"])

    let startBeforeInstall = JeballtofileRequest(
      name: "vm",
      source: nil,
      resources: nil,
      steps: [start]
    ).validate()
    let executeWhileStopped = JeballtofileRequest(
      name: "vm",
      source: nil,
      resources: nil,
      steps: [install, execute]
    ).validate()
    let secondStart = JeballtofileRequest(
      name: "vm",
      source: nil,
      resources: nil,
      steps: [install, start, start]
    ).validate()
    let keystrokesAfterStop = JeballtofileRequest(
      name: "vm",
      source: nil,
      resources: nil,
      steps: [install, start, stop, keystrokes]
    ).validate()

    #expect(startBeforeInstall.valid == false)
    #expect(startBeforeInstall.error?.contains("Step 0") == true)
    #expect(executeWhileStopped.valid == false)
    #expect(executeWhileStopped.error?.contains("Step 1") == true)
    #expect(secondStart.valid == false)
    #expect(secondStart.error?.contains("Step 2") == true)
    #expect(keystrokesAfterStop.valid == false)
    #expect(keystrokesAfterStop.error?.contains("Step 3") == true)
  }

  @Test
  func jeballtofileAcceptsMultipleValidBootCycles() {
    let request = JeballtofileRequest(
      name: "vm",
      source: nil,
      resources: nil,
      steps: [
        makeStep(.install),
        makeStep(.start),
        makeStep(.guiOpen),
        makeStep(.keystrokes, keystrokes: ["<enter>"]),
        makeStep(.stop),
        makeStep(.wait, seconds: 1),
        makeStep(.start),
        makeStep(.execute, command: "true"),
        makeStep(.stop),
      ]
    )

    #expect(request.validate().valid)
  }

  @Test
  func jeballtofileStepValidation() {
    let install = JeballtofileStep(
      type: .install,
      keystrokes: nil,
      command: nil,
      user: nil,
      password: nil,
      timeout: nil,
      seconds: nil
    )
    let executeValid = JeballtofileStep(
      type: .execute,
      keystrokes: nil,
      command: "echo hello",
      user: nil,
      password: nil,
      timeout: 30,
      seconds: nil
    )
    let executeInvalid = JeballtofileStep(
      type: .execute,
      keystrokes: nil,
      command: "",
      user: nil,
      password: nil,
      timeout: 30,
      seconds: nil
    )
    let executeWithUnsafeUsername = JeballtofileStep(
      type: .execute,
      keystrokes: nil,
      command: "true",
      user: "-oProxyCommand=whoami",
      password: nil,
      timeout: 30,
      seconds: nil
    )
    let waitValid = JeballtofileStep(
      type: .wait,
      keystrokes: nil,
      command: nil,
      user: nil,
      password: nil,
      timeout: nil,
      seconds: 5
    )
    let waitInvalid = JeballtofileStep(
      type: .wait,
      keystrokes: nil,
      command: nil,
      user: nil,
      password: nil,
      timeout: nil,
      seconds: 301
    )
    let keysValid = JeballtofileStep(
      type: .keystrokes,
      keystrokes: ["hello", "<enter>"],
      command: nil,
      user: nil,
      password: nil,
      timeout: nil,
      seconds: nil
    )
    let keysInvalid = JeballtofileStep(
      type: .keystrokes,
      keystrokes: [],
      command: nil,
      user: nil,
      password: nil,
      timeout: nil,
      seconds: nil
    )
    let keysAggregateTooLong = JeballtofileStep(
      type: .keystrokes,
      keystrokes: [String(repeating: "a", count: 6000), String(repeating: "b", count: 5000)],
      command: nil,
      user: nil,
      password: nil,
      timeout: nil,
      seconds: nil
    )

    #expect(install.validate().valid)
    #expect(executeValid.validate().valid)
    #expect(executeInvalid.validate().valid == false)
    #expect(executeWithUnsafeUsername.validate().valid == false)
    #expect(waitValid.validate().valid)
    #expect(waitInvalid.validate().valid == false)
    #expect(keysValid.validate().valid)
    #expect(keysInvalid.validate().valid == false)
    #expect(keysAggregateTooLong.validate().valid == false)
  }

  private func makeStep(
    _ type: JeballtofileStepType,
    keystrokes: [String]? = nil,
    command: String? = nil,
    seconds: Int? = nil
  ) -> JeballtofileStep {
    JeballtofileStep(
      type: type,
      keystrokes: keystrokes,
      command: command,
      user: nil,
      password: nil,
      timeout: nil,
      seconds: seconds
    )
  }
}
