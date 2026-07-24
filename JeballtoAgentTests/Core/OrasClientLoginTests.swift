import Darwin
import Foundation
import Testing
@testable import JeballtoAgent

@Suite(.tags(.core))
struct OrasClientLoginTests {
  @Test
  func writesPasswordThroughStandardInput() async throws {
    try await withTemporaryDirectory(prefix: "oras-login-input") { root in
      let orasPath = "\(root)/oras"
      let capturedPasswordPath = "\(root)/password"
      let capturedConfigPath = "\(root)/registry-config-path"
      let script = """
      #!/bin/sh
      if [ "$1" != "login" ] || [ "$2" != "registry.example.com" ]; then
        echo "unexpected args: $*" >&2
        exit 2
      fi
      previous=
      for argument in "$@"; do
        if [ "$previous" = "--registry-config" ]; then
          printf '%s' "$argument" > "\(capturedConfigPath)"
        fi
        previous="$argument"
      done
      IFS= read -r password
      printf '%s' "$password" > "\(capturedPasswordPath)"
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)
      let credentialStore = makeTestRegistryCredentialStore()
      let client = Self.makeLoginClient(root: root, orasPath: orasPath, credentialStore: credentialStore)
      let password = "s3cret value !@#$%^&*()"

      try await client.login(registry: "registry.example.com", username: "operator", password: password)

      #expect(try String(contentsOfFile: capturedPasswordPath, encoding: .utf8) == password)
      let registryConfigPath = try String(contentsOfFile: capturedConfigPath, encoding: .utf8)
      #expect(registryConfigPath.hasPrefix(root))
      #expect(FileManager.default.fileExists(atPath: registryConfigPath) == false)
      #expect(
        try await credentialStore.credential(for: "registry.example.com") ==
          RegistryCredential(username: "operator", password: password)
      )
    }
  }

  @Test
  func failedLoginPreservesExistingCredential() async throws {
    try await withTemporaryDirectory(prefix: "oras-login-failure") { root in
      let orasPath = "\(root)/oras"
      let script = """
      #!/bin/sh
      IFS= read -r password
      echo "unauthorized" >&2
      exit 1
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)
      let credentialStore = makeTestRegistryCredentialStore()
      let existing = RegistryCredential(username: "old-user", password: "old-password")
      try await credentialStore.save(existing, for: "registry.example.com")
      let client = Self.makeLoginClient(root: root, orasPath: orasPath, credentialStore: credentialStore)

      await #expect(throws: OrasError.self) {
        try await client.login(
          registry: "registry.example.com",
          username: "new-user",
          password: "new-password"
        )
      }
      #expect(try await credentialStore.credential(for: "registry.example.com") == existing)
    }
  }

  @Test
  func logoutDeletesOnlyJeballtoCredentialWithoutLaunchingOras() async throws {
    try await withTemporaryDirectory(prefix: "oras-logout") { root in
      let orasPath = "\(root)/oras"
      let launchMarker = "\(root)/launched"
      let script = """
      #!/bin/sh
      touch "\(launchMarker)"
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)
      let credentialStore = makeTestRegistryCredentialStore()
      try await credentialStore.save(
        RegistryCredential(username: "operator", password: "password"),
        for: "registry.example.com"
      )
      let client = Self.makeLoginClient(root: root, orasPath: orasPath, credentialStore: credentialStore)

      try await client.logout(registry: "registry.example.com")

      #expect(try await credentialStore.credential(for: "registry.example.com") == nil)
      #expect(FileManager.default.fileExists(atPath: launchMarker) == false)
    }
  }

  @Test
  func cancellationTerminatesLoginProcess() async throws {
    try await withTemporaryDirectory(prefix: "oras-login-cancel") { root in
      let orasPath = "\(root)/oras"
      let pidPath = "\(root)/oras.pid"
      let script = """
      #!/bin/sh
      child=
      cleanup() {
        [ -z "$child" ] || kill "$child" 2>/dev/null
        [ -z "$child" ] || wait "$child" 2>/dev/null
        exit 0
      }
      trap cleanup TERM INT
      sleep 30 &
      child=$!
      echo "$$" > "\(pidPath)"
      wait "$child"
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)
      let client = Self.makeLoginClient(root: root, orasPath: orasPath)
      let task = Task {
        try await client.login(
          registry: "registry.example.com",
          username: "operator",
          password: String(repeating: "p", count: RegistryCredentialValidator.maximumPasswordLength)
        )
      }

      let pid = try await waitForLoginPid(atPath: pidPath)
      task.cancel()

      await #expect(throws: CancellationError.self) {
        try await task.value
      }
      try await waitUntilLoginProcessStops(pid)
    }
  }

  @Test
  func rejectsInvalidCredentialsBeforeLaunchingOras() async throws {
    try await withTemporaryDirectory(prefix: "oras-login-invalid") { root in
      let orasPath = "\(root)/oras"
      let launchMarker = "\(root)/launched"
      let script = """
      #!/bin/sh
      touch "\(launchMarker)"
      """
      try script.write(toFile: orasPath, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orasPath)
      let client = Self.makeLoginClient(root: root, orasPath: orasPath)

      await #expect(throws: OrasError.self) {
        try await client.login(
          registry: "registry.example.com",
          username: "operator\nadmin",
          password: "password"
        )
      }
      #expect(FileManager.default.fileExists(atPath: launchMarker) == false)
    }
  }

  private static func makeLoginClient(
    root: String,
    orasPath: String,
    credentialStore: RegistryCredentialStore = makeTestRegistryCredentialStore()
  ) -> OrasClient {
    OrasClient(
      config: ImageConfig(
        imageStorageDir: root,
        orasPath: orasPath,
        defaultRegistry: nil,
        insecureRegistries: []
      ),
      temporaryRoot: URL(fileURLWithPath: root, isDirectory: true),
      credentialStore: credentialStore
    )
  }
}

private func waitForLoginPid(atPath path: String) async throws -> pid_t {
  for _ in 0 ..< 200 {
    if let text = try? String(contentsOfFile: path, encoding: .utf8),
       let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return pid
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  Issue.record("Timed out waiting for login pid file")
  return -1
}

private func waitUntilLoginProcessStops(_ pid: pid_t) async throws {
  for _ in 0 ..< 200 {
    if kill(pid, 0) != 0, errno == ESRCH {
      return
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
  Issue.record("Login process \(pid) was still running")
}
