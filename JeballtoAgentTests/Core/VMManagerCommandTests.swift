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
}
