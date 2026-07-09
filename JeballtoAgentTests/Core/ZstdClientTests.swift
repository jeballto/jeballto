import Darwin
import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core), .serialized)
struct ZstdClientTests {
  @Test
  func compressCancellationTerminatesZstdProcess() async throws {
    try await withTemporaryDirectory(prefix: "zstd-cancel") { root in
      let zstdPath = (root as NSString).appendingPathComponent("zstd")
      let inputPath = (root as NSString).appendingPathComponent("input.bin")
      let outputPath = (root as NSString).appendingPathComponent("output.zst")
      let pidPath = (root as NSString).appendingPathComponent("zstd.pid")
      let input = Data(repeating: 0x61, count: 8 * 1024 * 1024)
      try input.write(to: URL(fileURLWithPath: inputPath))

      let script = """
      #!/bin/sh
      echo "$$" > "\(pidPath)"
      sleep 30
      """
      try script.write(toFile: zstdPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zstdPath)

      let client = ZstdClient(configuredPath: zstdPath)
      let task = Task {
        try await client.compressRange(
          inputPath: inputPath,
          offset: 0,
          size: UInt64(input.count),
          outputPath: outputPath
        )
      }

      let pid = try await waitForPid(atPath: pidPath)
      task.cancel()

      await #expect(throws: CancellationError.self) {
        _ = try await task.value
      }
      try await waitUntilProcessStops(pid)
    }
  }
}

private func waitForPid(atPath path: String) async throws -> pid_t {
  for _ in 0 ..< 200 {
    if let text = try? String(contentsOfFile: path, encoding: .utf8),
       let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return pid
    }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
  Issue.record("Timed out waiting for pid file")
  throw CancellationError()
}

private func waitUntilProcessStops(_ pid: pid_t) async throws {
  for _ in 0 ..< 200 {
    if kill(pid, 0) == -1 {
      return
    }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
  Issue.record("Process \(pid) was still running")
}
