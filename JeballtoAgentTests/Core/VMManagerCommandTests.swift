import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct VMManagerCommandTests {
  @Test
  func diskImageResizeCommandUsesDiskutilImageResizeForASIFImages() {
    let command = VMManager.diskImageResizeCommand(
      path: "/tmp/Test.bundle/Disk.img",
      newSize: 107_374_182_400
    )

    #expect(command.executableURL.path == "/usr/sbin/diskutil")
    #expect(command.arguments == ["image", "resize", "--size", "107374182400", "/tmp/Test.bundle/Disk.img"])
  }

  @Test(arguments: ["-n", "pa'ss", #"pa\cword"#])
  func askpassScriptPrintsPasswordLiterally(password: String) throws {
    let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("jeballto-askpass-test-\(UUID().uuidString).sh")
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let content = CommandExecutor.askpassScriptContent(for: password)
    try content.write(to: scriptURL, atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [scriptURL.path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()

    try process.run()
    process.waitUntilExit()

    let data = output.fileHandleForReading.readDataToEndOfFile()
    let text = String(data: data, encoding: .utf8)
    #expect(process.terminationStatus == 0)
    #expect(text == "\(password)\n")
  }
}
