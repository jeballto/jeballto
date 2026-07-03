# Jeballto VM Agent - Codex Instructions

## Project Map

> FOR AGENT - this section is project description for AI agents. Update when architecture changes to keep state current.

Headless API-first macOS VM manager. Apple Silicon only. Apple Virtualization framework. REST API on localhost:8011. Max 2 concurrent VMs.

### Source layout

```
JeballtoAgent/
  APIServer/          - HTTP server + routes (VMRoutes, ExecuteRoutes, ImageRoutes, InstallRoutes, JeballtofileRoutes, ScreenshotRoutes, SystemRoutes, InfraRoutes)
  VMManager/          - VMManager actor, VMInstance @MainActor, VMInstaller
  StateMachine/       - VMState (11 states), VMStateMachine (NSRecursiveLock)
  EventBus/           - EventBus class, type-safe pub/sub, ~40 event types
  Networking/         - NetworkManager actor, PortForwardingManager actor, TCPProxy
  Persistence/        - PersistenceStore actor, VMDefinition struct
  ImageManager/       - ImageManager actor, ImageStore actor, OrasClient (oras CLI wrapper), ImageReference
  Execution/          - CommandExecutor (SSH), JeballtofileExecutor, KeystrokeInjector, KeystrokeParser
  GUI/                - StatusBarManager, GUIManager @MainActor, UpdaterManager (Sparkle)
  AVFAdapter/         - AVFConfiguration, AVFDelegate
  Common/             - Config, Logger, Utils, AppVersion, ChildProcessTracker
  JeballtoAgent.swift - @main NSApplicationDelegate, entry point
openapi/jeballto-api.yaml         - OpenAPI 3.0.3 spec (source of truth for API, v0.3.5)
JeballtoAgent.docc/Articles/      - DocC docs (Architecture, APIReference, JeballtofileReference, DevelopmentGuide, GettingStarted, Troubleshooting)
```

### Manager concurrency quick ref

- `VMManager` - ACTOR, async most methods. Sync exceptions: `runningVMCount()`, `activeVMCount()`, `getVMInstance()`, `getVMState()`, `getInstallationStatus()`. `activeVMCount()` includes capacity-consuming states and actor-owned reservations.
- `PersistenceStore` - ACTOR, ALL methods SYNC. Call `ensureLoaded()` first in every public method
- `ImageManager` - ACTOR, all async
- `NetworkManager` - ACTOR, all SYNC
- `PortForwardingManager` - ACTOR, all SYNC
- `EventBus` - regular CLASS, DispatchQueue-based, all SYNC, NOT actor
- `VMInstance` - `@MainActor`, lifecycle methods (`start`/`stop`/`pause`/`resume`/`save`) ASYNC
- `VMStateMachine` - CLASS, `NSRecursiveLock`, `@unchecked Sendable`
- `APIServer` - regular CLASS, `NSLock` (`stateLock`) guards install tasks + jeballtofile executor dicts
- `StatusBarManager` - regular CLASS, `NSMenuDelegate`, `menuNeedsUpdate()` is SYNC - never call async inside

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
- `error` -> stopped, deleted
- `deleted` - terminal, no transitions
- `isOperational` = running|paused; `isTerminal` = deleted only

### VMDefinition fields

- `id` (UUID), `name`, `state` (VMState), `ephemeral` (Bool)
- `resources`: cpuCount (Int), memorySize (UInt64 bytes), diskSize (UInt64 bytes)
  - defaults: 4 CPU, 4GB RAM, 64GB disk; bounds: 1-32 CPU, 2GB-128GB RAM, 20GB-8TB disk
- `network`: macAddress, sshPort (Int?), vncPort (Int?), natIP (String?)
- `paths`: bundlePath, diskImagePath, auxiliaryStoragePath, hardwareModelPath, machineIdentifierPath, saveFilePath (String? only when paused)
- `metadata` ([String:String]), `createdAt`, `updatedAt`

### API endpoints

```
GET  /v1/health                                   - health check
POST /v1/system/reset                             - reset local state
GET  /v1/vms                                      - list VMs (limit, offset)
POST /v1/vms                                      - create VM
GET  /v1/vms/{id}                                 - get VM
DELETE /v1/vms/{id}                               - delete VM
DELETE /v1/vms                                    - wipe all VMs
PATCH /v1/vms/{id}                                - update VM resources/name
POST /v1/vms/{id}/start|stop|pause|resume|clone   - lifecycle
POST /v1/vms/{id}/install                         - start macOS install (auto-downloads IPSW)
GET  /v1/vms/{id}/install/status                  - install progress
POST /v1/vms/{id}/execute                         - SSH command execution
POST /v1/vms/{id}/keystrokes                      - GUI keystroke injection
GET  /v1/vms/{id}/screenshot                      - GUI screenshot
GET  /v1/images                                   - list local OCI images
POST /v1/images/pull                              - pull OCI image (via oras)
GET  /v1/images/pull/{id}/status                  - async pull progress
DELETE /v1/images/pull/{id}                       - cancel async pull
POST /v1/images/push                              - push VM as OCI image
GET  /v1/images/push/{id}/status                  - async push progress
DELETE /v1/images/push/{id}                       - cancel async push
DELETE /v1/images/{id}                            - delete image
POST /v1/registries/login                         - configure registry credentials
POST /v1/registries/logout                        - remove registry credentials
POST /v1/jeballtofiles                            - run blueprint
GET  /v1/jeballtofiles                            - list blueprint executions
GET  /v1/jeballtofiles/{id}                       - blueprint execution status
POST /v1/jeballtofiles/{id}/cancel                - cancel blueprint execution
DELETE /v1/jeballtofiles/{id}                     - delete blueprint execution
GET  /v1/config                                   - get config
PATCH /v1/config                                  - update config
GET  /v1/auth/verify                              - verify auth token
```

### Key request/response types (APIServer/DTOs/APIModels.swift)

- `CreateVMRequest`: name, resources (VMResourcesDTO?), image (String?), ephemeral (Bool?)
- `VMResourcesDTO`: cpuCount, memorySize, diskSize (all optional; `FlexibleByteSize` accepts "4GB" string or raw UInt64)
- `CommandExecuteRequest`: command, user, password, timeout (Int?)
- `VMResponse`: id, name, state, ephemeral, resources, network (VMNetworkResponse?), guiOpen, uptime, createdAt, updatedAt
- `VMNetworkResponse`: macAddress, sshPort, vncPort, natIP
- `HealthResponse`: status, version, vmsTotal, vmsRunning, uptime
- `InstallStatusResponse`: vmId, status, progress, phaseProgress, message, phase, bytesDownloaded, bytesTotal, downloadSpeed
- `ImageOperationStatusResponse`: operationId, type, reference, source, status, stage, progress, stageProgress, averageSpeedMBps, chunksCompleted, chunksTotal, bytesCompleted, bytesTotal, startedAt, updatedAt, completedAt, digest, image, error
- `ErrorResponse`: error.code, error.message, error.details

### EventBus event types (VMEvent enum)

VM lifecycle: `stateChanged(vmId,from,to)`, `vmCreated`, `vmDeleted`, `vmStarting`, `vmRunning`, `vmStopping`, `vmStopped`, `vmPaused`, `vmResumed`, `errorOccurred`, `vmCloned`, `vmResourcesUpdated`

Networking: `sshPortAssigned`, `sshPortReleased`, `vncPortAssigned`, `vncPortReleased`

Install: `installStarted`, `installProgress(vmId,progress,phaseProgress,message,phase,bytesDownloaded,bytesTotal,downloadSpeed)`, `installCompleted`, `installFailed`

GUI: `guiOpened`, `guiClosed`

Images: `imagePullStarted`, `imagePulled`, `imagePullFailed`, `imagePushStarted`, `imagePushed`, `imagePushFailed`, `imageDeleted`

Jeballtofiles: `jeballtofileStarted`, `jeballtofileStepStarted`, `jeballtofileStepCompleted`, `jeballtofileStepFailed`, `jeballtofileCompleted`, `jeballtofileCancelled`, `jeballtofileFailed`

### Key error enums

- `VMStateMachineError`: `invalidTransition(from,to)`, `terminalStateReached`, `alreadyInTargetState`
- `CommandExecutorError`: `sshNotConfigured`, `timeout(command,seconds)`, `processLaunchFailed`, `askpassScriptFailed`
- `PersistenceError`: `fileNotFound`, `invalidData`, `encodingFailed`, `decodingFailed`, `vmNotFound(UUID)`, `vmAlreadyExists(UUID)`, `directoryCreationFailed`
- `ImageManagerError`: `imageNotFound`, `imageNotFoundById`, `pullFailed`, `pushFailed`, `deleteFailed`, `invalidReference`, `registryUnreachable`

### Config (loaded from config.json)

- api: port=8011, host="0.0.0.0", token=UUID, enableHTTPS=false, maxConcurrentRequests=100
- storage: vmStorageDir, databasePath=vms.json, imageIndexPath=images.json
- logging: level="info", enableFileLogging=true, retentionDays=7, maxTotalSize="2GB", timezone=nil (IANA identifier, nil=system TZ)
- networking: sshPortRange=2222-2223, autoEnableSSHForwarding=true, vncPortRange=5901-5902
- images: imageStorageDir, orasPath (nil=bundled binary), maxParallelImageBlobTransfers=16, maxParallelImageCompressions=4, maxParallelImageDecompressions=2, maxParallelImageDiskWrites=1, defaultRegistry (nil), insecureRegistries=[]

### Key paths

- VM definitions: `~/Library/Application Support/Jeballto/vms.json`
- Image index: `~/Library/Application Support/Jeballto/images.json`
- Config: `~/Library/Application Support/Jeballto/config.json`
- Logs: `~/Library/Logs/Jeballto/`

### OCI images

Via `oras` CLI (not Docker). VMs stored as OCI artifacts (.bundle dirs). `ImageReference` parses `registry/repo:tag@sha256:digest`.

### Jeballtofiles (blueprints)

Declarative JSON/YAML. Step types: create, install, wait, execute (SSH), keystrokes. `JeballtofileExecutor` runs sequentially, publishes step events, supports cancellation. Cancellation marks the current step and execution as `cancelled` and publishes `JEBALLTOFILE_CANCELLED`.

### SSH execution

`CommandExecutor` retries 20x on exit 255 (connection refused) with 3s delay. Timeout -> `CommandExecutorError.timeout`. Max 5MB stdout/stderr, max 64KB command length. Child process output is drained via `AsyncProcessRunner` to avoid stdout/stderr pipe deadlocks.

## Versioning Policy

While the project version is below 1.0.0, there is NO backward compatibility requirement. Breaking API changes are acceptable - remove old fields/endpoints cleanly rather than keeping deprecated shims.

## Critical Rules

### No em dashes

Never use em dashes anywhere: code, comments, commit messages, PR descriptions, or any output. Use hyphens (-) or commas instead.

### Never block `applicationDidFinishLaunching`

`applicationDidFinishLaunching` in `JeballtoAgent.swift` is the critical startup path. StatusBarManager and UpdaterManager must be initialized first, synchronously. Any new functionality added to app launch MUST be deferred via `DispatchQueue.main.async` or `Task`. Blocking this method causes the status bar to get stuck on "Starting..." indefinitely.

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

- `VMManager` - ACTOR. Most methods async (`vmCount`, `createVM`, `startVM`, etc). Sync exceptions: `runningVMCount()`, `activeVMCount()`, `getVMInstance()`, `getVMState()`, `getInstallationStatus()`.
- `PersistenceStore` - ACTOR but ALL methods SYNC. Crossing actor boundary still requires `await`. All public methods must call `ensureLoaded()` first.
- `ImageManager` - ACTOR with ALL methods async.
- `PortForwardingManager` - ACTOR but ALL methods SYNC.
- `NetworkManager` - ACTOR but ALL methods SYNC.
- `EventBus` - regular CLASS with DispatchQueue-based thread safety. All methods SYNC. NOT an actor.
- `GUIManager` - `@MainActor`. All methods SYNC.
- `VMInstance` - `@MainActor`. Lifecycle methods (`start`, `stop`, `pause`, `resume`, `save`) are ASYNC.
- `VMStateMachine` - CLASS with `NSRecursiveLock`, `@unchecked Sendable`. Thread-safe by lock.
- `StatusBarManager` - regular CLASS (not `@MainActor`). Implements `NSMenuDelegate`. `menuNeedsUpdate()` is SYNC - never call async methods directly inside it.
- `APIServer` - regular CLASS. `start()` and `stop()` are SYNC. Holds references to actors. Uses `NSLock` (`stateLock`) for thread-safe dictionary access.

**Rules:**

- `NSMenuDelegate.menuNeedsUpdate()` is synchronous - NEVER call async functions in it. Cache async results and refresh in a background `Task`.
- `VMManager.startVM`, `VMManager.resumeVM`, and `VMManager.installVM` must reserve VM capacity before the first `await` and release that reservation with `defer`.
- `NSApplicationDelegate` methods run on main thread.
- When `guard-let` or `if-let` unwraps an optional into a local constant, do NOT re-unwrap it with another `if-let` - the local is already non-optional.
- To call `@MainActor` code from a non-isolated async context: `await MainActor.run { ... }`
- To call `@MainActor` init from non-MainActor sync context: use `Task { @MainActor in ... }` or move to `applicationDidFinishLaunching`.
- Actor-isolated sync methods still require `await` when called from outside the actor - crossing actor boundary is always async even if the method body is sync.
- All background tasks should use `Task<Void, Never>` for explicit error handling.

## Architecture

- VM lifecycle has 11 states with 1:1 `VZVirtualMachine` mapping
- Custom `EventBus` for type-safe pub/sub (not `NotificationCenter`)
- State transitions validated via state machine
- OpenAPI 3.0.3 spec in `openapi/jeballto-api.yaml` must match implementation exactly
- Manager classes use actor pattern for thread safety

### VM lifecycle state recovery pattern

Every lifecycle method (start, stop, pause, resume, save) MUST follow this pattern:

1. Transition to intermediate state (`.starting`, `.stopping`, `.pausing`, `.resuming`)
2. Wrap the VZ operation in `do/catch`
3. On success, transition to target state and publish success event
4. On failure, `forceState(.error)`, update definition, publish `.errorOccurred`, then rethrow

Never leave a VM stuck in an intermediate state on failure. The `.error` state is the recovery path.

### Shutdown

`applicationShouldTerminate` has a 30-second timeout. If `cleanupForShutdown()` does not complete within 30 seconds, the app proceeds with termination. Ephemeral VMs are stopped and deleted; non-ephemeral running VMs are paused and saved for resume.

## Testing

- Test should be changed accordingly if any changes to code are made
- Every new funciotnality should be covered by tests
- In this repo tests are lower level and fast without: live networking, no VM boot or install, no GUI window dependency
- High livel tests like E2E are kept in other repository
- Test coverage should be resonable, to protect our code base from bugs but not to be paranoid and to not create too much boilerplate code
- Check avaible skills when writing tests, you can find ones useful for testing

## Code Style

- Formatter: SwiftFormat (`nicklockwood/SwiftFormat`, see `.swiftformat`)
- Linter: SwiftLint (see `.swiftlint.yml`)
- Line length: 120 characters max
- Indentation: 2 spaces
- Run checks: `task pre-commit:run` (staged) or `task pre-commit:all` (full repo)
- Run tests: `task test`
- Comments: only for non-obvious behavior or gotchas - never restate what the code does
