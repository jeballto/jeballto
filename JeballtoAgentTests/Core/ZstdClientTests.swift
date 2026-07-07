import Darwin
import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct ZstdClientTests {
  @Test
  func compressCancellationTerminatesZstdProcess() async throws {
    try await withTemporaryDirectory(prefix: "zstd-cancel") { root in
      let zstdPath = "\(root)/zstd"
      let pidPath = "\(root)/zstd.pid"
      let inputPath = "\(root)/input.bin"
      let outputPath = "\(root)/output.zst"
      let script = """
      #!/bin/sh
      echo $$ > "\(pidPath)"
      sleep 30
      """
      try script.write(toFile: zstdPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zstdPath)
      try Data(repeating: 42, count: 8 * 1024 * 1024).write(to: URL(fileURLWithPath: inputPath))

      let client = ZstdClient(configuredPath: zstdPath)
      let task = Task {
        try await client.compressRange(inputPath: inputPath, offset: 0, size: 8 * 1024 * 1024, outputPath: outputPath)
      }
      let processStarted = await waitUntil {
        FileManager.default.fileExists(atPath: pidPath)
      }
      try #require(processStarted)

      task.cancel()

      await #expect(throws: CancellationError.self) {
        try await task.value
      }
      let pidText = try String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
      let pid = try #require(Int32(pidText))
      let processStopped = await waitUntil {
        kill(pid, 0) == -1
      }
      #expect(processStopped)
    }
  }
}
