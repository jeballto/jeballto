import Darwin
import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core), .serialized)
struct ZstdClientTests {
  @Test
  func chunkedFileReadPreservesBytesAndReportsEOF() throws {
    try withTemporaryDirectory(prefix: "file-chunk-read") { root in
      let path = "\(root)/input.bin"
      let expected = Data((0 ..< 97).map(UInt8.init))
      try expected.write(to: URL(fileURLWithPath: path))
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
      defer { try? handle.close() }

      let firstChunk = try readFileChunk(from: handle, upToCount: 32)
      let secondChunk = try readFileChunk(from: handle, upToCount: 128)
      let first = try #require(firstChunk)
      let second = try #require(secondChunk)
      let eof = try readFileChunk(from: handle, upToCount: 1) ?? Data()

      #expect(first + second == expected)
      #expect(eof.isEmpty)
    }
  }

  @Test
  func bundledToolEnvironmentRemovesDynamicLoaderOverridesOnly() {
    let environment = [
      "DYLD_INSERT_LIBRARIES": "/tmp/debugger.dylib",
      "DYLD_LIBRARY_PATH": "/tmp/libraries",
      "PATH": "/usr/bin",
      "TMPDIR": "/tmp/work",
    ]

    #expect(
      bundledToolEnvironment(from: environment) == [
        "PATH": "/usr/bin",
        "TMPDIR": "/tmp/work",
      ]
    )
  }

  @Test
  func decompressionRejectsOversizedOutputBeforeWritingPastDeclaredRange() async throws {
    try await withTemporaryDirectory(prefix: "zstd-output-bound") { root in
      let zstdPath = "\(root)/zstd"
      let inputPath = "\(root)/input.zst"
      let destinationPath = "\(root)/destination.bin"
      let script = """
      #!/bin/sh
      printf '12345678'
      """
      try script.write(toFile: zstdPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zstdPath)
      try Data("compressed".utf8).write(to: URL(fileURLWithPath: inputPath))
      let original = Data(repeating: 0xAA, count: 64)
      try original.write(to: URL(fileURLWithPath: destinationPath))
      let client = ZstdClient(configuredPath: zstdPath)

      await #expect(throws: ZstdError.self) {
        _ = try await client.decompressToFileRange(
          inputPath: inputPath,
          destinationPath: destinationPath,
          offset: 16,
          expectedSize: 4
        )
      }
      let after = try Data(contentsOf: URL(fileURLWithPath: destinationPath))
      #expect(after.prefix(16) == original.prefix(16))
      #expect(after.dropFirst(20) == original.dropFirst(20))
    }
  }

  @Test
  func compressionWrapsInputFileErrorsWithRangeContext() async throws {
    try await withTemporaryDirectory(prefix: "zstd-compression-file-error") { root in
      let zstdPath = "\(root)/zstd"
      let inputPath = "\(root)/missing-input.bin"
      let script = """
      #!/bin/sh
      cat >/dev/null
      """
      try script.write(toFile: zstdPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zstdPath)
      let client = ZstdClient(configuredPath: zstdPath)

      do {
        _ = try await client.compressRange(
          inputPath: inputPath,
          offset: 17,
          size: 31,
          outputPath: "\(root)/output.zst"
        )
        Issue.record("Expected the missing compression input to fail")
      } catch let error as ZstdError {
        guard case .streamingFailed(let message) = error else {
          Issue.record("Expected streamingFailed, got \(error.localizedDescription)")
          return
        }
        #expect(message.contains("31-byte range at offset 17"))
        #expect(message.contains(inputPath))
      }
    }
  }

  @Test
  func decompressionWrapsDestinationFileErrorsWithRangeContext() async throws {
    try await withTemporaryDirectory(prefix: "zstd-decompression-file-error") { root in
      let zstdPath = "\(root)/zstd"
      let inputPath = "\(root)/input.zst"
      let destinationPath = "\(root)/missing/destination.bin"
      let script = """
      #!/bin/sh
      printf 'data'
      """
      try script.write(toFile: zstdPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zstdPath)
      try Data("compressed".utf8).write(to: URL(fileURLWithPath: inputPath))
      let client = ZstdClient(configuredPath: zstdPath)

      do {
        _ = try await client.decompressToFileRange(
          inputPath: inputPath,
          destinationPath: destinationPath,
          offset: 23,
          expectedSize: 4
        )
        Issue.record("Expected the missing decompression destination to fail")
      } catch let error as ZstdError {
        guard case .streamingFailed(let message) = error else {
          Issue.record("Expected streamingFailed, got \(error.localizedDescription)")
          return
        }
        #expect(message.contains("4-byte range at offset 23"))
        #expect(message.contains(destinationPath))
      }
    }
  }

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
  for _ in 0 ..< 1000 {
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
  for _ in 0 ..< 1000 {
    if kill(pid, 0) == -1 {
      return
    }
    try await Task.sleep(nanoseconds: 5_000_000)
  }
  Issue.record("Process \(pid) was still running")
}
