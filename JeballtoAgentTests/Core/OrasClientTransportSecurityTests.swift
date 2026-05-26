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
}
