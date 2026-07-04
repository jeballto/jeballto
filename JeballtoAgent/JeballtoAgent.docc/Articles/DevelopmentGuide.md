# Development Guide

How to build, test, and extend JeballtoAgent.

## Prerequisites

- Apple Silicon Mac (M1/M2/M3/M4)
- macOS 26.0+
- Xcode 26+
- `task` (go-task) - `brew install go-task/tap/go-task`

`task` is the only tool you need to install manually. Everything else is handled by `task setup`.

## Dev Tools

All development workflows are managed via [Taskfile](https://taskfile.dev) (`go-task`). See the [installation guide](https://taskfile.dev/docs/installation) for other install options.

### Quick start

```bash
brew install go-task/tap/go-task
task setup   # installs pre-commit, xcbeautify, check-jsonschema, oras, and optional mermaid CLI
task check   # verify everything is in place
```

### Discovering tasks

```bash
task          # list all available tasks with descriptions
task --list   # same
task info     # print project info and installed tool versions
```

Tasks are grouped by namespace using `:` - for example `build:release`, `docs:preview`, `pre-commit:all`. Run any task with `task <name>`:

```bash
task build           # Debug build
task test            # run unit tests
task pre-commit:all  # run all checks across the full repo
task openapi:validate
```

To see what a task does before running it:

```bash
task --summary <name>  # show description, dependencies, and commands
```

### Common workflows

**Before committing:**

```bash
task pre-commit:run   # checks staged files only
task pre-commit:all   # checks entire repo (slower, use before a PR)
```

**Build and test:**

```bash
task build          # Debug
task build:release  # Release
task test           # unit tests with xcbeautify
task test:verbose   # raw xcodebuild output
```

**Docs and diagrams:**

```bash
task docs:preview      # live preview at http://localhost:8000/documentation/jeballtoagent
task diagrams:generate # regenerate SVGs from .mmd sources
```

**Setup and maintenance:**

```bash
task setup            # one-time setup: pre-commit, xcbeautify, check-jsonschema, oras, mermaid CLI
task check            # verify all required tools are present
task clean            # remove build artifacts
task oras:download    # (re)download the oras binary
task openapi:stamp    # sync version field in jeballto-api.yaml
```

### Tools

| Tool | Install | Notes |
|---|---|---|
| `task` (go-task) | `brew install go-task/tap/go-task` | Manual - required to run anything |
| `pre-commit` | `task setup` | Required - self-manages swiftlint, swiftformat, shellcheck, gitleaks, markdownlint |
| `xcbeautify` | `task setup` | Required - formats xcodebuild output |
| `check-jsonschema` | `task setup` | Required - OpenAPI schema validation |
| `oras` | `task setup` | Required - bundled into the app at build time |
| `zstd` | `task setup` | Required - bundled into the app at build time |
| `mmdc` | `task setup` (needs npm) | Optional - diagram SVG generation |

### Xcode build phase integration

Xcode build phases delegate to task automatically during `Product - Build` or `xcodebuild`. The phases call:

- `task xcode:set-build-number` - stamps CFBundleVersion with timestamp
- `task xcode:diagrams` - generates SVGs (non-fatal if mmdc missing)
- `task xcode:copy-openapi` - stamps and copies OpenAPI schema
- `task xcode:copy-tools` - copies oras and zstd binaries to app bundle

Do not run `xcode:*` tasks manually.

## Building

**From command line:**

```bash
task build          # Debug
task build:release  # Release
task build:archive  # Release archive
```

Or directly with xcodebuild:

```bash
xcodebuild -scheme JeballtoAgent -configuration Debug
xcodebuild -scheme JeballtoAgent -configuration Release
```

**From Xcode:**

1. Open `JeballtoProject.xcodeproj`
2. Select JeballtoAgent scheme
3. Product - Build (Command+B) / Run (Command+R)

## Building Documentation

```bash
task docs:preview  # preview at localhost:8000
task docs:build    # build DocC archive to .build/Docs
```

Or use **Product - Build Documentation** (Command+Control+Shift+D) in Xcode for a full build with symbol graph.

## Configuration

First run creates `~/Library/Application Support/Jeballto/config.json` (permissions 0o600):

```json
{
  "api": {
    "port": 8011,
    "host": "0.0.0.0",
    "token": "auto-generated-uuid",
    "enableHTTPS": false,
    "maxConcurrentRequests": 100
  },
  "storage": {
    "vmStorageDir": "~/Library/Application Support/Jeballto/VMs",
    "databasePath": "~/Library/Application Support/Jeballto/vms.json"
  },
  "logging": {
    "level": "info",
    "enableFileLogging": true,
    "logDirectory": "~/Library/Logs/Jeballto",
    "retentionDays": 7,
    "maxTotalSize": "2GB"
  },
  "networking": {
    "sshPortRangeStart": 2222,
    "sshPortRangeEnd": 2223,
    "autoEnableSSHForwarding": true,
    "vncPortRangeStart": 5901,
    "vncPortRangeEnd": 5902
  },
  "images": {
    "imageStorageDir": "~/Library/Application Support/Jeballto/Images",
    "orasPath": null,
    "zstdPath": null,
    "maxParallelImageBlobTransfers": 16,
    "maxParallelImageCompressions": 4,
    "maxParallelImageDecompressions": 2,
    "maxParallelImageDiskWrites": 1,
    "defaultRegistry": null,
    "insecureRegistries": []
  }
}
```

## Image Push And Pull Flow

Jeballto stores VM bundles as OCI artifacts. `oras` handles registry transfer, `zstd` handles chunk
compression, and `VMImagePackager` owns the bundle-to-layer mapping. Zero-filled chunks are represented
as metadata and are not uploaded as blob layers.

Push flow:

1. `ImageManager` checks that the registry is reachable before expensive packaging starts.
2. `VMImagePackager` scans bundle files, splits them into fixed-size chunks, skips zero chunks, and
   compresses nonzero chunks with `zstd`.
3. Packaging reuses verified session work when the same source chunk is already compressed for the
   current agent session.
4. `ImageManager` uploads the config blob and nonzero chunk blobs with ORAS, skipping blobs that the
   registry already has.
5. The OCI manifest is pushed last, after every referenced blob exists in the registry.

Pull flow:

1. `ImageManager` resolves the reference to a manifest digest and creates a session operation directory.
2. The config blob is fetched or reused from the session blob cache, then validated by size and digest.
3. `VMImagePackager` creates the destination bundle layout and schedules nonzero chunk work.
4. Each chunk task fetches its compressed blob on demand with ORAS, validates the compressed size and
   digest, enters the decompression limiter, streams `zstd` output into the destination bundle file,
   and validates the uncompressed size and digest.
5. The image is registered only after all files are reconstructed and validated.

Parallelism is split by stage:

| Setting | Default | Range | Used by |
|---|---:|---:|---|
| `maxParallelImageBlobTransfers` | 16 | 1-64 | ORAS blob fetches during pull and ORAS blob pushes during push |
| `maxParallelImageCompressions` | 4 | 1-32 | Concurrent `zstd` compression processes during push |
| `maxParallelImageDecompressions` | 2 | 1-8 | Concurrent `zstd` decompression processes during pull |
| `maxParallelImageDiskWrites` | 1 | 1-4 | Concurrent output writes while pull decompression streams into bundle files |

Push compression uses `maxParallelImageCompressions`. The decompression and disk-write limits apply only
to pull, because push never reconstructs bundle files from compressed layers.

OCI pull and push operation cache is session-scoped under `~/Library/Caches/Jeballto/ImageWork/`. Agent
startup removes the whole ImageWork directory, and each successful transfer deletes its own operation
cache. Failed or cancelled transfers keep verified blobs and packaged chunks only until the agent exits.

## Code Style

All code quality tools (SwiftLint, SwiftFormat, shellcheck, markdownlint, check-jsonschema) are managed by pre-commit. Run them via task:

```bash
task pre-commit:run   # staged files only
task pre-commit:all   # entire repo
```

SwiftFormat and SwiftLint configs: `.swiftformat`, `.swiftlint.yml`.

## Adding New API Endpoints

Route handlers live in `APIServer/Routes/` as `extension APIServer` files, grouped by domain.

**1. Register in `APIServer.swift` - `registerRoutes()`:**

```swift
private func registerRoutes() {
    // existing routes...
    server.post("/v1/vms/{id}/your-action", handler: handleYourAction)
}
```

**2. Create the handler in the appropriate Routes file:**

```swift
extension APIServer {
  func handleYourAction(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return .error("INVALID_ID", message: "Invalid VM ID", statusCode: 400)
    }

    do {
      let result = try await vmManager.yourAction(vmId: vmId)
      return .json(YourActionResponse(result: result))
    } catch {
      return .error("ACTION_FAILED", message: error.localizedDescription, statusCode: 500)
    }
  }
}
```

**3. Add DTOs in `DTOs/APIModels.swift`:**

```swift
struct YourActionResponse: Codable {
  let result: String
}
```

**4. Update `openapi/jeballto-api.yaml`**

New `.swift` files in existing directories are picked up automatically (the Xcode project uses filesystem-synchronized groups).

## Adding New VM Operations

**1. Add to `VMInstance.swift`:**

Every lifecycle method must follow the error recovery pattern - transition to intermediate state, do work, recover to `.error` on failure:

```swift
@MainActor
func yourOperation() async throws {
    guard let vm = virtualMachine else {
        throw VMInstanceError.noVirtualMachine
    }
    try stateMachine.transition(to: .intermediateState)
    definition.updateState(.intermediateState)
    do {
        try await vm.yourOperation()
        try stateMachine.transition(to: .targetState)
        definition.updateState(.targetState)
        eventBus.publish(.yourEvent(vmId: definition.id))
    } catch {
        stateMachine.forceState(.error)
        definition.updateState(.error)
        eventBus.publish(.errorOccurred(vmId: definition.id, error: error.localizedDescription))
        throw error
    }
}
```

**2. Add state if needed in `VMState.swift`** and update transitions in `VMStateMachine.swift`.

**3. Publish events:**

```swift
eventBus.publish(.yourEvent(vmId: vmId))
```

## Testing

### Fast local tests (Swift Testing)

```bash
task test          # with xcbeautify output
task test:verbose  # raw xcodebuild output
```

Tests are lower-level and fast by design: no live networking, no VM boot or install, no GUI window dependency.

### API smoke flow (manual)

```bash
# Start agent
./build/Debug/JeballtoAgent

# In another terminal:
export TOKEN=$(cat ~/Library/Application\ Support/Jeballto/config.json | grep token | cut -d'"' -f4)

# Health check
curl http://127.0.0.1:8011/v1/health

# List VMs
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8011/v1/vms

# Create + start
VM_ID=$(curl -s -X POST http://127.0.0.1:8011/v1/vms \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"test","resources":{"cpuCount":2,"memorySize":"4GB","diskSize":"40GB"}}' \
  | grep -o '"id":"[^"]*' | cut -d'"' -f4)

curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/start -H "Authorization: Bearer $TOKEN"
```

**Debug logging:** Set `"level": "debug"` in config.json. Logs are written to `~/Library/Logs/Jeballto/agent-YYYY-MM-DD.log`.

## Common Pitfalls

**VZVirtualMachine must run on main queue:**

```swift
// WRONG - will crash
Task { vm.start() }

// CORRECT
@MainActor
func startVM() { vm.start() }
```

**Concurrent VM limit:** Max 2 capacity-consuming VMs simultaneously. Installing, starting, running, pausing,
paused, resuming, and actor-owned reservations count. Reserve capacity before the first suspension point in
`startVM`, `resumeVM`, and `installVM`:

```swift
try reserveCapacityIfNeeded(for: vmId, operation: "start")
defer { releaseCapacityReservation(for: vmId) }
guard activeVMCount() <= 2 else {
    throw VMError.limitReached
}
```

**SSH_ASKPASS for passwords:** Never pass passwords in process arguments (visible in `ps`). Use the `SSH_ASKPASS` script pattern from `CommandExecutor.swift`.

**Process output:** Use `AsyncProcessRunner` for child processes that may write to both stdout and stderr. It drains
both pipes concurrently, applies timeouts, handles task cancellation, and untracks children.

**State transitions:** Always validate before transitioning:

```swift
guard stateMachine.canTransition(to: newState) else {
    throw VMError.invalidStateTransition
}
```

## Debugging

**Attach Xcode debugger:**

1. Run agent from command line
2. Xcode - Debug - Attach to Process - JeballtoAgent
3. Set breakpoints, trigger API calls

**View persisted state:**

```bash
cat ~/Library/Application\ Support/Jeballto/vms.json | jq
cat ~/Library/Application\ Support/Jeballto/images.json | jq
```

## Resources

- [Apple Virtualization Framework](https://developer.apple.com/documentation/virtualization)
- [oras CLI](https://oras.land/)
- [OCI Distribution Spec](https://github.com/opencontainers/distribution-spec)
- OpenAPI spec: `openapi/jeballto-api.yaml` in the project repository
