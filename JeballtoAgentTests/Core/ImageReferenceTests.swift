import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct ImageReferenceTests {
  @Test(arguments: [
    "registry.example.com/vms/macos:v1",
    "registry.example.com:5000/vms/macos:v1",
    "registry.example.com/vms/macos@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "registry.example.com/repo/path",
  ])
  func parseAcceptsValidReferences(_ reference: String) throws {
    let parsed = try ImageReference.parse(reference)
    #expect(parsed.fullReference == reference)
  }

  @Test(arguments: [
    "",
    "no-slash",
    "registry.example.com/UpperCaseRepo:v1",
    "registry.example.com/repo:bad tag",
    "registry.example.com/repo@sha256:short",
  ])
  func parseRejectsInvalidReferences(_ reference: String) {
    #expect(throws: ImageReferenceError.self) {
      _ = try ImageReference.parse(reference)
    }
  }

  @Test
  func insecureRegistryCheckUsesExactRegistryMatch() throws {
    let parsed = try ImageReference.parse("registry.example.com:5000/repo/name:v1")
    #expect(parsed.isInsecureAllowed(insecureRegistries: ["registry.example.com:5000"]))
    #expect(parsed.isInsecureAllowed(insecureRegistries: ["registry.example.com"]) == false)
  }
}
