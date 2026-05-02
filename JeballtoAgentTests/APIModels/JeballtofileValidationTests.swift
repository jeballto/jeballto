import Testing
@testable import JeballtoAgent

@Suite(.tags(.apiModels))
struct JeballtofileValidationTests {
  @Test
  func jeballtofileRequestRequiresSteps() {
    let request = JeballtofileRequest(name: "vm", source: nil, resources: nil, steps: [])
    let validation = request.validate()

    #expect(validation.valid == false)
    #expect(validation.error?.contains("steps") == true)
  }

  @Test
  func jeballtofileRequestRequiresSourceWhenInstallStepExists() {
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

    #expect(validation.valid == false)
    #expect(validation.error?.contains("source") == true)
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

    #expect(install.validate().valid)
    #expect(executeValid.validate().valid)
    #expect(executeInvalid.validate().valid == false)
    #expect(waitValid.validate().valid)
    #expect(waitInvalid.validate().valid == false)
    #expect(keysValid.validate().valid)
    #expect(keysInvalid.validate().valid == false)
  }
}
