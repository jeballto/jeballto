import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct ImageReferenceTests {
  @Test(arguments: [
    "registry.example.com/vms/macos:latest",
    "registry.example.com:5000/vms/macos:latest",
    "registry.example.com/vms/macos@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "registry.example.com/vms/macos:latest@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "registry.example.com/repo/path",
  ])
  func parseAcceptsValidReferences(_ reference: String) throws {
    let parsed = try ImageReference.parse(reference)
    #expect(parsed.fullReference == reference)
  }

  @Test(arguments: [
    "",
    "no-slash",
    "registry.example.com/UpperCaseRepo:latest",
    "registry.example.com/repo:bad tag",
    "registry.example.com/repo@sha256:short",
    "registry..example.com/repo:tag",
  ])
  func parseRejectsInvalidReferences(_ reference: String) {
    #expect(throws: ImageReferenceError.self) {
      _ = try ImageReference.parse(reference)
    }
  }

  @Test
  func insecureRegistryCheckUsesExactRegistryMatch() throws {
    let parsed = try ImageReference.parse("registry.example.com:5000/repo/name:latest")
    #expect(parsed.isInsecureAllowed(insecureRegistries: ["registry.example.com:5000"]))
    #expect(parsed.isInsecureAllowed(insecureRegistries: ["registry.example.com"]) == false)
  }

  @Test
  func parseUsesConfiguredDefaultRegistryForShortReference() throws {
    let parsed = try ImageReference.parse("team/macos:latest", defaultRegistry: "registry.example.com")
    #expect(parsed.fullReference == "registry.example.com/team/macos:latest")
  }

  @Test
  func parseRejectsUnqualifiedRepositoryWithoutDefaultRegistry() {
    #expect(throws: ImageReferenceError.self) {
      _ = try ImageReference.parse("team/macos:latest")
    }
  }

  @Test(arguments: ["registry.example.com:0/repo:tag", "registry.example.com:65536/repo:tag"])
  func parseRejectsRegistryPortOutsideValidRange(_ reference: String) {
    #expect(throws: ImageReferenceError.self) {
      _ = try ImageReference.parse(reference)
    }
  }

  @Test
  func parseRejectsOversizedRegistryLabelsAndRepositories() {
    let oversizedLabel = String(repeating: "a", count: 64)
    let oversizedRepository = String(repeating: "r", count: 256)

    #expect(throws: ImageReferenceError.self) {
      _ = try ImageReference.parse("\(oversizedLabel).example.com/repo:tag")
    }
    #expect(throws: ImageReferenceError.self) {
      _ = try ImageReference.parse("registry.example.com/\(oversizedRepository):tag")
    }
  }

  @Test
  func parseMeasuresReferenceLimitBeforeTrimmingWhitespace() {
    let validReference = "registry.example.com/repo:tag"
    let oversizedReference = validReference + String(repeating: " ", count: 1025 - validReference.utf8.count)

    #expect(oversizedReference.utf8.count == 1025)
    #expect(throws: ImageReferenceError.self) {
      _ = try ImageReference.parse(oversizedReference)
    }
  }
}
