# Development Guide

How to build, test, and extend JeballtoAgent.

## Prerequisites

- Apple Silicon Mac
- macOS 26.0+
- Xcode 26+
- Homebrew, used by `task setup` to install project tooling
- `task` (go-task) - `brew install go-task/tap/go-task`

After Homebrew and `task` are available, `task setup` installs or downloads the remaining project tools.

## Dev Tools

All development workflows are managed via [Taskfile](https://taskfile.dev) (`go-task`). See the [installation guide](https://taskfile.dev/docs/installation) for other install options.

### Quick start

```bash
brew install go-task/tap/go-task
task setup   # installs pre-commit, xcbeautify, check-jsonschema, oras, zstd, and optional mermaid CLI
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
task build:release  # unsigned Release validation build
task test           # unit tests with xcbeautify
task test:verbose   # prettified output plus a retained raw xcodebuild log
```

**Docs and diagrams:**

```bash
task docs:preview      # live preview at http://localhost:8000/documentation/jeballtoagent
task diagrams:generate # regenerate SVGs from .mmd sources
```

**Setup and maintenance:**

```bash
task setup            # one-time setup: pre-commit, xcbeautify, check-jsonschema, oras, zstd, mermaid CLI
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
task build:release  # unsigned Release validation build
task build:archive  # Release archive using the current Xcode signing settings
```

Or directly with xcodebuild:

```bash
xcodebuild -scheme JeballtoAgent -configuration Debug
xcodebuild -scheme JeballtoAgent -configuration Release
```

Debug uses `JeballtoAgent.Debug.entitlements` so it can be signed ad hoc and stores its API token and registry
credentials in the login Keychain. Release uses `JeballtoAgent.entitlements`, which includes the application keychain
access group. The
final signed Release needs a provisioning profile that authorizes this group. `task build:release` disables code
signing and only validates compilation. `task build:archive` does not choose a team, certificate, or provisioning
profile; provide the distribution signing settings in Xcode or as xcodebuild overrides when creating a release.

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

First run creates `~/Library/Application Support/Jeballto/config.json` (permissions 0o600). The following is an
illustrative full configuration. Optional fields whose value is `null` are normally omitted from the generated file:

```json
{
  "api": {
    "port": 8011,
    "host": "0.0.0.0",
    "maxConcurrentRequests": 100
  },
  "storage": {
    "vmStorageDir": "/Users/your-name/Library/Application Support/Jeballto/VMs",
    "databasePath": "/Users/your-name/Library/Application Support/Jeballto/vms.json",
    "imageIndexPath": "/Users/your-name/Library/Application Support/Jeballto/images.json"
  },
  "logging": {
    "level": "info",
    "enableFileLogging": true,
    "logDirectory": "/Users/your-name/Library/Logs/Jeballto",
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
    "imageStorageDir": "/Users/your-name/Library/Application Support/Jeballto/Images",
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

All configured paths must be absolute. Managed directories cannot be `/` or the home directory, must have the
expected file type when they already exist, and VM, image, and log directories cannot overlap. The VM database,
image index, and their backups must be distinct files outside those managed directories. SSH and VNC ranges cannot
overlap each other or the API port. Custom `orasPath` and `zstdPath` values must point to executable regular files.
If `images.defaultRegistry` is set, references such as `team/dev:latest` use it automatically. `maxTotalSize` accepts
a positive whole number followed by `MB` or `GB`, for example `500MB` or `2GB`; the suffixes use 1024-based units.
Registries listed in `images.insecureRegistries` use plain HTTP, so credentials and VM image artifacts are not
protected in transit.

## Persistent Data Formats

Persistence contracts have separate integer versions:

| Contract | Current version | Version field | Compatibility rule |
|---|---:|---|---|
| VM database | v1 | Top-level `version` in `vms.json` | Requires version 1 and the complete v1 `VMDefinition` schema |
| Local image index | v1 | Top-level `version` in `images.json` | Requires version 1, `formatVersion: 1`, explicit owned-bundle metadata, and a managed UUID bundle path |
| Jeballto VM Bundle Format | v1 | `formatVersion` in the OCI config blob | Requires integer 1 before chunk layers are fetched or reconstructed |

The three version numbers are independent from the application version and from each other. Readers fail closed on
missing, malformed, incomplete, or unsupported data. `vms.json.bak` and `images.json.bak` are recovery copies, not
older schemas: a backup is used only when it passes the same current-version validation as the primary file.

Additive optional fields that preserve a contract's semantics may remain in that version. Incompatible required
fields, ownership rules, layer semantics, chunk encoding, or reconstruction behavior require a new integer version.

## Image Push And Pull Flow

Jeballto stores VM bundles as OCI artifacts. `oras` handles registry transfer, `zstd` handles chunk
compression, and `VMImagePackager` owns the bundle-to-layer mapping. Zero-filled chunks are represented
as metadata and are not uploaded as blob layers. Format version 1 records the `arm64` architecture and
the VM CPU, memory, and disk resources that are restored when a VM is created from the image.

The artifact contract is named **Jeballto VM Bundle Format v1**. Its OCI media types identify the stable Jeballto VM
bundle family and intentionally do not contain a format version:

| Role | Media type |
|---|---|
| Manifest `artifactType` and config `artifactType` | `application/vnd.jeballto.vm.bundle` |
| Config descriptor | `application/vnd.jeballto.vm.bundle.config+json` |
| Compressed chunk layer | `application/vnd.jeballto.vm.bundle.chunk+zstd` |

The required integer `formatVersion` in the config blob selects the schema and chunk semantics independently of the
application release version. Do not infer the format version from an OCI tag, a media type, artifact annotations, or
the Jeballto application version.

Versioning rules:

- Producers write the current `formatVersion`, currently `1`, and persist it in the local image record.
- Decoders reject a missing, malformed, or unknown version before fetching chunk layers.
- Additive optional fields that preserve all v1 semantics may remain in v1.
- An incompatible config change, required-field change, or change to layer, chunk, digest, compression, or zero-chunk
  interpretation requires the next integer version.
- Pre-1.0 configs without `formatVersion` are legacy unversioned artifacts, not v0, and are intentionally unsupported.

The required REST `ImageResponse.formatVersion` field reports the validated format stored in the local image record.
The agent fails closed when a pre-1.0 local index lacks this field or explicit ownership of its managed bundle.

Push flow:

1. `ImageManager` checks that the registry is reachable before expensive packaging starts.
2. `VMImagePackager` scans bundle files, splits them into fixed-size chunks, skips zero chunks, and
   compresses nonzero chunks with `zstd`.
3. Packaging reuses verified session work when the same source chunk is already compressed for the
   current agent session.
4. `ImageManager` uploads the config blob and nonzero chunk blobs with ORAS, skipping blobs that the
   registry already has.
5. A durable local bundle copy is created and validated, including its declared ASIF disk capacity.
6. A complete replacement image index is written to a staged file without exposing it to readers.
7. The OCI manifest is pushed after every referenced blob and the local recovery data exist.
8. The staged index atomically replaces the visible index after confirmed manifest success.

The durable bundle copy asks `/bin/cp -c` for filesystem cloning. APFS can provide a copy-on-write clone, while a
filesystem without clone support or a cross-filesystem destination falls back to a regular copy. Push status reports
this work as `finalizing`; it does not claim byte-level progress or a transfer speed for that stage.

If manifest publication starts but its result cannot be confirmed, the operation reports
`IMAGE_PUSH_COMMIT_OUTCOME_UNKNOWN`. If the manifest commit succeeds but atomic local index finalization fails, it
reports `IMAGE_PUSH_PARTIALLY_COMMITTED`. Both results require inspecting or pulling the reference before retrying.

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

OCI pull and push operation cache is session-scoped under `~/Library/Caches/Jeballto/ImageWork/sessions/`.
The agent holds a shared advisory lease on its session plus an exclusive owner lock. Before launching an image child,
it creates a bounded launch marker and starts the Jeballto executable as a wrapper. The wrapper validates the marker,
acquires its own shared lease, removes the marker, preserves the lease descriptor across `exec`, and then runs
`oras`, `zstd`, or `/bin/cp`. Cleanup requires an exclusive session lease. This keeps a session protected while its
agent is alive, during child launch, and while an orphaned image child still runs after an unexpected agent exit.

Startup removes only sessions proven inactive. With `SingleInstanceLock`, exclusive startup cleanup may also remove
old lockless work. Unsafe lock targets are preserved. Each successful transfer deletes its own operation cache.
Failed or cancelled transfers keep verified blobs and packaged chunks until the process exits. Wipe operations clear
only the current session contents and preserve its lock files.

## Code Style

All code quality tools (SwiftLint, SwiftFormat, shellcheck, markdownlint, check-jsonschema) are managed by pre-commit. Run them via task:

```bash
task pre-commit:run   # staged files only
task pre-commit:all   # entire repo
```

SwiftFormat and SwiftLint configs: `.swiftformat`, `.swiftlint.yml`.

## Adding New API Endpoints

Route handlers live in `APIServer/Routes/` as `extension APIServer` files, grouped by domain.

**1. Register in the appropriate route group in `APIServer.swift`:**

```swift
private func registerVMRoutes() {
  // existing routes...
  httpServer.post("/v1/vms/{id}/your-action") { [weak self] request in
    await self?.handleYourAction(request) ?? Self.serverUnavailableError
  }
}
```

**2. Create the handler in the appropriate Routes file:**

```swift
extension APIServer {
  func handleYourAction(_ request: HTTPRequest) async -> HTTPResponse {
    guard let vmId = extractResourceId(from: request.path) else {
      return APIRouteErrorMapper.invalidID()
    }

    do {
      let result = try await vmManager.yourAction(vmId: vmId)
      return HTTPResponse.json(YourActionResponse(result: result))
    } catch let error as VMManagerError {
      return APIRouteErrorMapper.vmManager(error, defaultCode: "ACTION_FAILED")
    } catch {
      return HTTPResponse.error("ACTION_FAILED", message: error.localizedDescription, statusCode: 500)
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
    throw VMInstanceError.notInitialized
  }
  guard stateMachine.canTransition(to: .intermediateState) else {
    throw VMInstanceError.invalidState("Cannot run operation from \(stateMachine.currentState.rawValue)")
  }
  try transition(to: .intermediateState)
  do {
    try await vm.yourOperation()
    try transition(to: .targetState)
    eventBus.publish(.yourEvent(vmId: definition.id))
  } catch {
    recordFailureIfNeeded(error)
    throw error
  }
}
```

**2. Add state if needed and update `VMState.validTransitions` in `VMState.swift`.**

**3. Publish events:**

```swift
eventBus.publish(.yourEvent(vmId: vmId))
```

## Testing

### Fast local tests (Swift Testing)

```bash
task test          # with xcbeautify output
task test:verbose  # prettified output plus a retained raw xcodebuild log
```

Tests are lower-level and fast by design: no live networking, no VM boot or install, no GUI window dependency.

### API smoke flow (manual)

```bash
# Start agent
open .build/DerivedData/Build/Products/Debug/JeballtoAgent.app

# In another terminal, choose "Copy API Token" in the menu-bar item and paste it:
export TOKEN='paste-token-here'

# Health check
curl http://127.0.0.1:8011/v1/health

# List VMs
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8011/v1/vms

# Create a blank VM
curl -fsS -X POST http://127.0.0.1:8011/v1/vms \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"test","resources":{"cpuCount":2,"memorySize":"4GB","diskSize":"40GB"}}'

# Copy id from the response
export VM_ID='paste-vm-id-here'

# Read it back, then delete it without starting or installing
curl -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8011/v1/vms/$VM_ID"
curl -X DELETE -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8011/v1/vms/$VM_ID"
```

**Debug logging:** Set `"level": "debug"` in config.json. Logs are written to `~/Library/Logs/Jeballto/agent-YYYY-MM-DD.log`.

## Common Pitfalls

**VZVirtualMachine must run on main queue:**

```swift
// WRONG - ignores the async throwing API and does not compile under strict concurrency
Task { vm.start() }

// CORRECT - call the async throwing API from MainActor isolation
@MainActor
func startVM() async throws { try await vm.start() }
```

**Concurrent VM limit:** Max 2 capacity-consuming VMs simultaneously. Installing, starting, running, pausing,
paused, resuming, and actor-owned reservations count. Reserve capacity before the first suspension point in
`startVM`, `resumeVM`, and `installVM`:

```swift
let initialState = instance.currentState
let reserved = try reserveCapacityIfNeeded(
  for: vmId,
  currentState: initialState,
  operation: "start"
)
defer { if reserved { releaseCapacityReservation(for: vmId) } }
```

**SSH_ASKPASS for passwords:** Never pass passwords in process arguments (visible in `ps`). Use the `SSH_ASKPASS` script pattern from `CommandExecutor.swift`.

**Process output:** Use `AsyncProcessRunner` for child processes that may write to both stdout and stderr. It drains
both pipes concurrently, applies timeouts, handles task cancellation, and untracks children.

**State transitions:** Always validate before transitioning:

```swift
guard stateMachine.canTransition(to: newState) else {
  throw VMInstanceError.invalidState(
    "Cannot transition from \(stateMachine.currentState.rawValue) to \(newState.rawValue)"
  )
}
```

## Debugging

**Attach Xcode debugger:**

1. Run agent from command line
2. Xcode - Debug - Attach to Process - JeballtoAgent
3. Set breakpoints, trigger API calls

**View persisted state:**

```bash
cat "$HOME/Library/Application Support/Jeballto/vms.json"
cat "$HOME/Library/Application Support/Jeballto/images.json"
```

## Resources

- [Apple Virtualization Framework](https://developer.apple.com/documentation/virtualization)
- [oras CLI](https://oras.land/)
- [OCI Distribution Spec](https://github.com/opencontainers/distribution-spec)
- OpenAPI spec: `openapi/jeballto-api.yaml` in the project repository
