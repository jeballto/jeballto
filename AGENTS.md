# Jeballto VM Agent - Codex Instructions

## Project Map

> FOR AGENT - this section is project description for AI agents. Update when architecture changes to keep state current.

Headless API-first macOS VM manager. Apple Silicon only. Apple Virtualization framework. REST API binds to
`0.0.0.0:8011` by default. Jeballto allows at most 2 capacity-consuming VMs.

### Source layout

```
JeballtoAgent/
  APIServer/          - HTTP server, mutation admission gate, DTOs, and route groups
  VMManager/          - VMManager actor, VMInstance @MainActor, VMInstaller
  StateMachine/       - VMState (11 states), VMStateMachine (NSRecursiveLock)
  EventBus/           - EventBus class, type-safe pub/sub, ~40 event types
  Networking/         - NetworkManager actor, PortForwardingManager actor, TCPProxy
  Persistence/        - PersistenceStore actor, VMDefinition struct
  ImageManager/       - ImageManager/ImageStore actors, ORAS/zstd wrappers, OCI parsing, registry Keychain storage
  Execution/          - CommandExecutor (SSH), JeballtofileExecutor, KeystrokeInjector, KeystrokeParser
  GUI/                - StatusBarManager and GUIManager @MainActor, UpdaterManager (Sparkle)
  AVFAdapter/         - AVFConfiguration, AVFDelegate
  Common/             - Config, Logger, secrets, process helpers, keyed/serial gates, single-instance lock
  JeballtoAgent.swift - @main NSApplicationDelegate, entry point
openapi/jeballto-api.yaml         - OpenAPI 3.0.3 spec (source of truth for API, v0.3.5)
JeballtoAgent.docc/Articles/      - DocC docs (Architecture, APIReference, JeballtofileReference, DevelopmentGuide, GettingStarted, Troubleshooting)
```

### Manager concurrency quick ref

- `VMManager` - ACTOR, async most methods. Sync exceptions include `runningVMCount()`, `activeVMCount()`,
  `getVMInstance()`, and `getVMState()`. `activeVMCount()` includes capacity-consuming states and actor-owned reservations.
- `PersistenceStore` - ACTOR, ALL methods SYNC. Call `ensureLoaded()` first in every public method
- `ImageManager` - ACTOR with mixed sync/async declarations; external calls always cross the actor boundary
- `NetworkManager` - ACTOR; MAC allocation methods are sync, NAT resolution is async
- `PortForwardingManager` - ACTOR, all SYNC
- `EventBus` - regular CLASS, DispatchQueue-based, all SYNC, NOT actor
- `VMInstance` - `@MainActor`, lifecycle methods (`start`/`stop`/`pause`/`resume`/`save`) ASYNC
- `VMStateMachine` - CLASS, `NSRecursiveLock`, `@unchecked Sendable`
- `APIServer` - regular CLASS. `NSLock` guards config snapshots, image task handles, and Jeballtofile executors.
  `APIMutationGate` drains ordinary mutations before destructive maintenance.
- `StatusBarManager` - `@MainActor` CLASS and `NSMenuDelegate`; `menuNeedsUpdate()` is SYNC - never call async inside

### VM states (11) and valid transitions

- `created` -> installing, starting, error, deleted
- `installing` -> stopped, starting, error, deleted
- `stopped` -> starting, deleted, error
- `starting` -> running, paused, error
- `running` -> stopping, pausing, error
- `stopping` -> stopped, error
- `pausing` -> paused, error
- `paused` -> resuming, starting, stopping, error
- `resuming` -> running, error
- `error` -> created, stopped, deleted
- `deleted` - terminal, no transitions
- `isOperational` = running|paused; `isTerminal` = deleted only

### VMDefinition fields

- `id` (UUID), `name`, `state` (VMState), `ephemeral` (Bool), `hasBooted` (Bool)
- `resources`: cpuCount (Int), memorySize (UInt64 bytes), diskSize (UInt64 bytes)
  - defaults: 4 CPU, 4GB RAM, 64GB disk; bounds: 1-32 CPU, 2GB-128GB RAM, 20GB-8TB disk
- `network`: macAddress, sshPort (Int?), vncPort (Int?), natIP (String?)
- `paths`: bundlePath, diskImagePath, auxiliaryStoragePath, hardwareModelPath, machineIdentifierPath, saveFilePath
  (the path is configured for each VM; the file exists only for a durable shutdown save)
- `installation` (VMInstallation?), `lifetimeSeconds`, `expiresAt`
- `metadata` ([String:String], including pending disk-resize transaction markers), `createdAt`, `updatedAt`

### API endpoints

```
GET  /v1/health                                   - health check
GET  /v1/vms                                      - list VMs (limit, offset)
POST /v1/vms                                      - create VM
GET  /v1/vms/{id}                                 - get VM
DELETE /v1/vms/{id}                               - delete VM
DELETE /v1/vms                                    - wipe all VMs
PATCH /v1/vms/{id}                                - update VM resources/name
POST /v1/vms/{id}/start|stop|pause|resume|clone   - lifecycle
POST /v1/vms/{id}/install                         - start macOS install (auto-downloads IPSW)
GET  /v1/vms/{id}/install/status                  - install progress
GET  /v1/vms/{id}/state|events                    - state and retained events
GET|POST|DELETE /v1/vms/{id}/ssh                  - inspect/enable/disable SSH forwarding
GET|POST|DELETE /v1/vms/{id}/vnc                  - inspect/enable/disable VNC forwarding
GET|POST|DELETE /v1/vms/{id}/gui                  - inspect/open/close GUI
POST /v1/vms/{id}/execute                         - SSH command execution
POST /v1/vms/{id}/keystrokes                      - GUI keystroke injection
GET  /v1/vms/{id}/screenshot                      - GUI screenshot
GET  /v1/images[/{id}]                            - list/get local OCI images
DELETE /v1/images                                 - wipe all local images
DELETE /v1/images/{id}                            - delete image
POST /v1/images/pull                              - pull OCI image (via oras)
POST /v1/images/push                              - push VM as OCI image
GET|DELETE /v1/images/pull/operations             - list/cancel all pull operations
GET|DELETE /v1/images/pull/operations/{id}        - inspect/cancel one pull operation
GET|DELETE /v1/images/push/operations             - list/cancel all push operations
GET|DELETE /v1/images/push/operations/{id}        - inspect/cancel one push operation
POST /v1/registries/login                         - configure registry credentials
POST /v1/registries/logout                        - remove registry credentials
POST /v1/jeballtofiles                            - run blueprint
GET  /v1/jeballtofiles                            - list blueprint executions
GET  /v1/jeballtofiles/{id}                       - blueprint execution status
POST /v1/jeballtofiles/{id}/cancel                - cancel blueprint execution
DELETE /v1/jeballtofiles/{id}                     - delete blueprint execution
GET  /v1/config                                   - get config
PATCH /v1/config                                  - update config
GET  /v1/system/capabilities                      - host/runtime capabilities
POST /v1/system/reset                             - soft/hard local reset
GET  /v1/auth/verify                              - verify auth token
```

### Key request/response types (APIServer/DTOs/APIModels.swift)

- `CreateVMRequest`: name, resources, image, ephemeral, lifetimeSeconds
- `CloneVMRequest`: name, resources, ephemeral, lifetimeSeconds
- `VMResourcesDTO`: cpuCount, memorySize, diskSize (all optional; `FlexibleByteSize` accepts "4GB" string or raw UInt64)
- `CommandExecuteRequest`: command, user, password, timeout (Int?)
- `VMResponse`: id, name, state, ephemeral, resources, network, guiOpen, uptime, lifetimeSeconds, expiresAt,
  createdAt, updatedAt
- `VMNetworkResponse`: macAddress, sshPort, vncPort, natIP
- `HealthResponse`: status, version, vmsTotal, vmsRunning, uptime
- `InstallStatusResponse`: vmId, status, progress, phaseProgress, message, phase, bytesDownloaded, bytesTotal, downloadSpeed
- `ImageResponse`: id, reference, digest, localPath, size, resources, formatVersion, pulledAt, pushedAt, metadata
- `ImageOperationStatusResponse`: operationId, statusUrl, type, reference, source, status, stage, progress,
  stageProgress, averageSpeedMBps, chunksCompleted, chunksTotal, bytesCompleted, bytesTotal, startedAt, updatedAt,
  completedAt, digest, image, errorCode, error
- `ErrorResponse`: error.code, error.message

### EventBus event types (VMEvent enum)

VM lifecycle: `stateChanged(vmId,from,to)`, `vmCreated`, `vmDeleted`, `vmStarting`, `vmRunning`, `vmStopping`, `vmStopped`, `vmPaused`, `vmResumed`, `errorOccurred`, `vmCloned`, `vmResourcesUpdated`

Networking: `sshPortAssigned`, `sshPortReleased`, `sshReady`, `vncPortAssigned`, `vncPortReleased`

Install: `installStarted`, `installProgress(vmId,progress,phaseProgress,message,phase,bytesDownloaded,bytesTotal,downloadSpeed)`, `installCompleted`, `installCancelled`, `installFailed`

GUI: `guiOpened`, `guiClosed`

Images: `imagePullStarted`, `imagePulled`, `imagePullFailed`, `imagePushStarted`, `imagePushed`, `imagePushFailed`, `imageDeleted`

Jeballtofiles: `jeballtofileStarted`, `jeballtofileStepStarted`, `jeballtofileStepCompleted`, `jeballtofileStepFailed`, `jeballtofileCompleted`, `jeballtofileCancelled`, `jeballtofileFailed`

### Key error enums

- `VMStateMachineError`: `invalidTransition(from,to)`, `terminalStateReached`, `alreadyInTargetState`
- `CommandExecutorError`: `sshNotConfigured`, input validation cases, `timeout(command,seconds)`,
  `processLaunchFailed`, `askpassScriptFailed`
- `PersistenceError`: `fileNotFound`, `invalidData`, `encodingFailed`, `writeFailed`, `decodingFailed`,
  `vmNotFound(UUID)`, `vmAlreadyExists(UUID)`, `directoryCreationFailed`
- `ImageManagerError`: `imageNotFound`, `imageNotFoundById`, `pullFailed`, `pushFailed`, `deleteFailed`,
  `pushCommitOutcomeUnknown`, `pushPartiallyCommitted`, `invalidReference`, `invalidImage`,
  `unsupportedImageFormat`, `registryUnavailable`, `timeout`, `imageInUse`

### Config (loaded from config.json)

- api: port=8011, host="0.0.0.0", token resolved from Keychain, maxConcurrentRequests=100
- storage: vmStorageDir, databasePath=vms.json, imageIndexPath=images.json
- logging: level="info", enableFileLogging=true, retentionDays=7, maxTotalSize="2GB", timezone=nil (IANA identifier, nil=system TZ)
- networking: sshPortRange=2222-2223, autoEnableSSHForwarding=true, vncPortRange=5901-5902
- images: imageStorageDir, orasPath/zstdPath (nil=bundled binary), maxParallelImageBlobTransfers=16,
  maxParallelImageCompressions=4, maxParallelImageDecompressions=2, maxParallelImageDiskWrites=1,
  defaultRegistry=nil, insecureRegistries=[]

### Key paths

- VM definitions: `~/Library/Application Support/Jeballto/vms.json`
- Image index: `~/Library/Application Support/Jeballto/images.json`
- Config: `~/Library/Application Support/Jeballto/config.json`
- Logs: `~/Library/Logs/Jeballto/`
- API token and OCI registry credentials: application-owned macOS Keychain items

### OCI images

Via `oras` CLI (not Docker). VMs are stored as OCI artifacts (`.bundle` directories). `ImageReference` parses
`registry/repo:tag@sha256:digest`. Registry login validates credentials through ORAS, then stores them in Jeballto's
own Keychain service. Every registry command uses an isolated temporary ORAS registry config and does not inherit
Docker or standalone ORAS login state. `insecureRegistries` uses plain HTTP and can expose credentials and artifacts.

The current artifact contract is **Jeballto VM Bundle Format v1**. The config blob contains required integer
`formatVersion: 1`. Stable family media types are `application/vnd.jeballto.vm.bundle`,
`application/vnd.jeballto.vm.bundle.config+json`, and `application/vnd.jeballto.vm.bundle.chunk+zstd`. Media types do
not select the format version. Missing versions are legacy unversioned artifacts, not v0, and unknown versions are
rejected before chunk-layer download. Additive optional fields may remain in v1, but incompatible config or chunk
semantics require the next integer version. `ImageResponse.formatVersion` exposes the required stored validated
version. Incompatible pre-1.0 local index records are rejected. Async operation failures expose stable `errorCode`
separately from the human-readable `error`.

### Jeballtofiles (blueprints)

Declarative JSON/YAML. Step types: install, start, stop, gui-open, gui-close, keystrokes, execute (SSH), wait.
`JeballtofileExecutor` runs sequentially, publishes step events, and supports cancellation. Cancellation immediately
marks the current step and execution as `cancelled`, requests cooperative task cancellation, and publishes
`JEBALLTOFILE_CANCELLED`.

### SSH execution

`CommandExecutor` retries only when `retryOnSSHFailure` is enabled and exit 255 contains a recognized transient SSH
connection error. Retries wait up to 3 seconds and share the caller's overall timeout, with no fixed attempt count.
The public execute endpoint fails fast; Jeballtofile execute enables retry. Timeout becomes
`CommandExecutorError.timeout`. Max 5 MiB stdout/stderr, 65,536 UTF-8 bytes per command. Child process output is
drained via `AsyncProcessRunner` to avoid pipe deadlocks.

## Versioning Policy

While the project version is below 1.0.0, there is NO backward compatibility requirement. Breaking API changes are acceptable - remove old fields/endpoints cleanly rather than keeping deprecated shims.

## Critical Rules

### No em dashes

Never use em dashes anywhere: code, comments, commit messages, PR descriptions, or any output. Use hyphens (-) or commas instead.

### Never block app launch

`run()` initializes StatusBarManager and UpdaterManager synchronously before entering the app event loop, then defers
configuration and service startup in a `Task`. Keep `applicationDidFinishLaunching` non-blocking and do not move slow
work in front of the event loop. Blocking app launch leaves the status bar stuck on "Starting...".

### Never commit session artifacts

Never commit plans, summaries, changelogs, analysis reports, or any other session-generated documentation to the repo. Print them directly in the conversation if requested.

### Diagrams: Mermaid is source, SVG is output

Never edit SVG diagram files directly. Mermaid `.mmd` files are the source of truth. Edit the mermaid source and regenerate the SVG.

### Documentation format

Project documentation uses Apple's DocC format (`.docc`). Documentation articles are in `JeballtoAgent/JeballtoAgent.docc/Articles/`, diagrams in `JeballtoAgent/JeballtoAgent.docc/Diagrams/`.

## Error Handling

Error handling is critical and must be treated as high priority:

- Every error must have a specific, descriptive error type with a clear `localizedDescription`
- Never use generic catch-all errors - distinguish between failure modes (timeout vs launch failure vs invalid input)
- API error responses must use appropriate HTTP status codes: 400 (client errors), 404 (not found), 409 (state conflicts), 413 (payload too large), 504 (timeouts), 500 (server errors)
- Error messages must include enough context for debugging (VM ID, command prefix, state info)
- Parse errors and validation errors must surface as 400s, not 500s

## Swift Concurrency Rules

BEFORE writing any code that calls a method on another class, ALWAYS check that method's signature to see if it is async or sync. Read the source file first.

**Actor/class reference:**

- `VMManager` - ACTOR. Most methods async (`vmCount`, `createVM`, `startVM`, etc). Sync exceptions include
  `runningVMCount()`, `activeVMCount()`, `getVMInstance()`, and `getVMState()`.
- `PersistenceStore` - ACTOR but ALL methods SYNC. Crossing actor boundary still requires `await`. All public methods must call `ensureLoaded()` first.
- `ImageManager` - ACTOR with mixed sync/async declarations. Calls from outside the actor still require `await`.
- `PortForwardingManager` - ACTOR but ALL methods SYNC.
- `NetworkManager` - ACTOR. MAC allocation methods are sync; NAT resolution is async.
- `EventBus` - regular CLASS with DispatchQueue-based thread safety. All methods SYNC. NOT an actor.
- `GUIManager` - `@MainActor`. Most UI methods are sync; event-drain helpers are async.
- `VMInstance` - `@MainActor`. Lifecycle methods (`start`, `stop`, `pause`, `resume`, `save`) are ASYNC.
- `VMStateMachine` - CLASS with `NSRecursiveLock`, `@unchecked Sendable`. Thread-safe by lock.
- `StatusBarManager` - `@MainActor` CLASS implementing `NSMenuDelegate`. `menuNeedsUpdate()` is synchronous, so cache
  actor-owned values and refresh them from a separate `Task`.
- `APIServer` - regular CLASS. `start()` is sync and throwing; `stop()` is async. Holds references to actors. Uses
  `NSLock` for its synchronous registries and an actor for mutation admission.

**Rules:**

- `NSMenuDelegate.menuNeedsUpdate()` is synchronous - NEVER call async functions in it. Cache async results and refresh in a background `Task`.
- `VMManager.startVM`, `VMManager.resumeVM`, and installation entry points must reserve VM capacity before the first
  suspension and release that reservation with `defer`.
- `NSApplicationDelegate` methods run on main thread.
- When `guard-let` or `if-let` unwraps an optional into a local constant, do NOT re-unwrap it with another `if-let` - the local is already non-optional.
- Use `await MainActor.run { ... }` for synchronous `@MainActor` work from a non-isolated async context. Call an
  async `@MainActor` method directly with `await`.
- To call `@MainActor` init from non-MainActor sync context: use `Task { @MainActor in ... }` or initialize it on the
  main thread before starting deferred work.
- Actor-isolated sync methods still require `await` when called from outside the actor - crossing actor boundary is always async even if the method body is sync.
- All background tasks should use `Task<Void, Never>` for explicit error handling.

## Architecture

- VM lifecycle has 11 product states that combine `VZVirtualMachine` runtime states with installation, error, and
  persistence lifecycle states
- Custom `EventBus` for type-safe pub/sub (not `NotificationCenter`)
- State transitions validated via state machine
- OpenAPI 3.0.3 spec in `openapi/jeballto-api.yaml` must match implementation exactly
- Manager classes use actor pattern for thread safety

### VM lifecycle state recovery pattern

Every VZ-backed lifecycle path (start, stop, pause, resume, save) MUST follow this pattern. Idempotent and explicit
error-recovery branches may return or reconcile before entering the VZ operation.

1. Transition to intermediate state (`.starting`, `.stopping`, `.pausing`, `.resuming`)
2. Wrap the VZ operation in `do/catch`
3. On success, transition to target state and publish success event
4. On failure, `forceState(.error)`, update definition, publish `.errorOccurred`, then rethrow

Never leave a VM stuck in an intermediate state on failure. The `.error` state is the recovery path.

### Shutdown

`applicationShouldTerminate` has a 30-second timeout. If `cleanupForShutdown()` does not complete within 30 seconds,
the app proceeds with termination. Ephemeral VMs are stopped and deleted; non-ephemeral running and in-memory paused
VMs are saved for explicit resume.

## Testing

- Test should be changed accordingly if any changes to code are made
- Every new functionality should be covered by tests
- In this repo tests are lower level and fast, without live networking, VM boot/install, or GUI window dependencies
- High-level tests such as E2E are kept in another repository
- Test coverage should be reasonable, protecting the codebase without excessive boilerplate
- Check available skills when writing tests

## Code Style

- Formatter: SwiftFormat (`nicklockwood/SwiftFormat`, see `.swiftformat`)
- Linter: SwiftLint (see `.swiftlint.yml`)
- Line length: 120 characters max
- Indentation: 2 spaces
- Run checks: `task pre-commit:run` (staged) or `task pre-commit:all` (full repo)
- Run tests: `task test`
- Comments: only for non-obvious behavior or gotchas - never restate what the code does
