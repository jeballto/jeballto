import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct OrasClientTransportSecurityTests {
  @Test
  func insecureRegistryUsesPlainHTTPTransportFlag() {
    #expect(OrasClient.transportSecurityArguments(plainHTTP: true) == ["--plain-http"])
  }

  @Test
  func secureRegistryUsesDefaultTransport() {
    #expect(OrasClient.transportSecurityArguments(plainHTTP: false).isEmpty)
  }

  @Test
  func debugArgumentRenderingRedactsRegistryUsernames() {
    let rendered = OrasClient.sanitizedArguments([
      "resolve",
      "registry.example.com/repo:tag",
      "-u",
      "service-account",
      "--username=second-account",
    ])

    #expect(rendered.contains("service-account") == false)
    #expect(rendered.contains("second-account") == false)
    #expect(rendered.contains("-u <redacted>"))
    #expect(rendered.contains("--username=<redacted>"))
  }
}
