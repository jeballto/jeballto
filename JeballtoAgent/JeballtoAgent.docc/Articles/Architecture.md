# Architecture

How JeballtoAgent is structured internally - components, concurrency model, state machine, and storage layout.

## Overview

JeballtoAgent is a headless macOS app built on Apple's Virtualization framework. It exposes a REST API for programmatic VM lifecycle management and uses a layered, actor-based architecture for thread safety.

## System Components

![System Architecture](architecture.svg)

## Component Responsibilities

### JeballtoAgent (Main)

- Application entry point (`NSApplication`-based)
- Initializes `StatusBarManager` and `UpdaterManager` synchronously before deferring configuration and service startup
- Deferred startup creates EventBus, PersistenceStore, NetworkManager, PortForwardingManager, GUIManager, VMManager,
  ImageManager, and APIServer in dependency order
- Signal handling (SIGTERM, SIGINT) - cleans up VMs on shutdown: ephemeral VMs are stopped and deleted, while
  non-ephemeral running and in-memory paused VMs are saved

### APIServer

- HTTP server on configurable host:port (default `0.0.0.0:8011`)
- Request authentication before routing
- RESTful endpoint routing
- Request/response JSON serialization
- Standardized error responses

See <doc:APIServer> for the symbol reference.

### VMManager (actor)

- Central VM registry
- Lifecycle operations: create, start, stop, pause, resume, delete
- Concurrent VM limit enforcement (max 2)
- Installation orchestration (delegates to VMInstaller)
- Coordinates with GUIManager, NetworkManager, PortForwardingManager
- Runtime and installation state reconciliation after restart
- Lifetime expiry: schedules a background task per VM; fires `stopVM` on expiry (ephemeral VMs auto-delete via the `.vmStopped` event path)

See <doc:VMManager> for the symbol reference.

### VMInstance (@MainActor)

- Wraps a single `VZVirtualMachine`
- State machine enforcement for normal lifecycle transitions; explicit failure and restart recovery can force a
  reconciled state
- Lifecycle operations (start, stop, pause, resume)
- Save/restore support (saves to `SaveFile.vzvmsave`)
- Exposes lifecycle state while `VMManager` tracks uptime from monotonic running-state timestamps

`VZVirtualMachine` and its associated views require the main queue. `VMInstance` is `@MainActor` to enforce this.
Actor-isolated callers use `MainActor.run` for synchronous access and call asynchronous lifecycle methods with
`await`.

### AVFAdapter

Owns all direct Apple Virtualization configuration assembly:

- `VMConfigurationSpec` is a pure Swift description of the VM hardware Jeballto wants.
- `MacVMConfigurationBuilder` maps `VMDefinition` into runtime or installation specs.
- `AVFConfigurationAssembler` converts specs into `VZVirtualMachineConfiguration`.
- `VirtualizationRuntimeFactory` creates `VZVirtualMachine` and wires `AVFDelegate`.
- `VirtualizationCapabilities` reports host support, feature lifecycle, and enabled runtime capabilities for `/v1/system/capabilities`.

`VMManager`, `VMInstance`, and `VMInstaller` should depend on these adapter-level concepts instead of assembling device-specific `VZ*` objects directly.

### VMInstaller

Three installation paths:

| Method | What happens |
|--------|-------------|
| Auto-download | Looks up the latest macOS IPSW from Apple (the lookup retries 3x with backoff), caches it, then installs |
| Remote URL | Downloads or reuses IPSW in the persistent `IPSWCache`, then installs |
| Local file | Loads IPSW directly from disk |

Progress events: `installStarted` - `installProgress` (with messages) - `installCompleted`, `installCancelled`, or
`installFailed`.

### CommandExecutor

Runs shell commands inside VMs over SSH:

```
APIServer
  -> VMManager.executeCommand(...)
    -> CommandExecutor.execute(command, sshPort, user, password, timeout)
      -> Process("/usr/bin/ssh", args)
        -> SSH_ASKPASS script (password in a mode-0700 temporary file, script path via env)
        -> Race: command vs timeout task
      -> CommandResult { exitCode, stdout, stderr, stdoutTruncated, stderrTruncated }
```

Limits: 5 MiB per output stream, 65,536 UTF-8 bytes per command, 5-second SSH connect timeout. Output that exceeds
the per-stream limit is drained but omitted after the limit, and the corresponding truncation flag is set.

### KeystrokeParser and KeystrokeInjector

Parses a DSL string (e.g. `"hello<enter><wait2s>"`) into actions, then injects them into `VZVirtualMachineView` as synthetic `NSEvent`s.

```
APIServer
  -> VMManager.executeKeystrokes(...)
    -> KeystrokeParser.parse("hello<enter>")
      -> [.keyPress(h), .keyPress(e), ..., .keyPress(enter)]
    -> KeystrokeInjector.execute(actions, vm, guiManager)
      -> ensureView() (creates hidden view if no GUI window open)
      -> view.keyDown()/keyUp() for each action
      -> 75ms delay between keys
```

Works during `installing` state - no SSH needed.

### ImageManager (actor)

OCI image operations using `oras` CLI:

| Operation | What happens |
|-----------|-------------|
| `pullImage(reference)` | Resolves mutable tags to the current registry digest, reuses a valid matching local record when possible, otherwise fetches or reuses verified config and zstd chunks, reconstructs `Images/{uuid}.bundle`, and registers it in ImageStore |
| `pushImageFromVM(reference, vmBundlePath)` | Chunks and compresses the VM bundle, uploads blobs, validates a durable local copy, stages the complete index, pushes the manifest, then atomically finalizes the local index |
| `pushImage(reference, imageId)` | Re-pushes an atomically claimed local image through the same staged commit pipeline |
| `deleteImage(id)` | Removes files (if owned, not a shared VM bundle) - removes from ImageStore |
| `loginRegistry` | Checks registry availability, validates credentials with an isolated `oras login`, then stores them in Jeballto's Keychain service |
| `logoutRegistry` | Deletes only Jeballto's stored credential for the registry |

### OrasClient

Thin wrapper around the `oras` CLI binary. Key design choices:

- Uses `Process` with argument arrays (no shell invocation) to prevent command injection
- Passwords passed via stdin (not in process args, not visible in `ps`)
- Every command uses a private temporary ORAS registry configuration. Stored Jeballto credentials are supplied from
  Keychain, and Docker or standalone ORAS login state is never reused.
- Timeout protection: bulk blob transfers have no fixed internal timeout unless the caller supplies an operation
  deadline; login and short metadata commands use 30 seconds, and registry reachability checks use 5 seconds
- Output capped at 8 MiB per stream
- VM images are chunked by `VMImagePackager` and compressed by `zstd` before ORAS uploads each nonzero chunk as a separate layer
- Pull and push operation cache lives under `ImageWork/sessions/<session>/operations/`. The agent holds a shared
  advisory session lease. Each image child starts through the Jeballto executable, validates its launch marker,
  acquires its own shared lease, and preserves that descriptor across `exec` into `oras`, `zstd`, or `/bin/cp`.
  Cleanup needs an exclusive lease, so it preserves sessions used by a live agent or an orphaned child. A launch
  marker also prevents cleanup during the small handoff window before the child acquires its lease. Startup removes
  only proven-inactive sessions and preserves unsafe lock targets. Successful transfers delete their operation cache,
  while failed or cancelled transfers keep verified work until the process exits.
- Image transfer parallelism is split by stage: `maxParallelImageBlobTransfers` defaults to 16 ORAS blob transfers, `maxParallelImageCompressions` defaults to 4 zstd encoders, `maxParallelImageDecompressions` defaults to 2 zstd decoders, and `maxParallelImageDiskWrites` defaults to 1 output write slot

Resolves `oras` binary: checks `config.images.orasPath` first, then `Bundle.main.resourceURL/oras`.
Resolves `zstd` binary: checks `config.images.zstdPath` first, then `Bundle.main.resourceURL/zstd`.

### EventBus

Non-blocking pub/sub event system:

- Subscriber callbacks run in publish order on a shared serial delivery queue
- Thread-safe: concurrent queue with barriers for writes
- Retains the last 1000 events globally, with filtered per-VM queries
- Subscription tokens for unsubscribe

A slow subscriber delays later callbacks and events on that delivery queue, but never blocks the publisher. See
<doc:EventBus>.

### NetworkManager (actor)

- Generates unique locally-administered MAC addresses per VM
- Prevents MAC collisions
- Resolves the guest NAT address from the host ARP table after the AVF adapter attaches NAT networking

### PortForwardingManager (actor)

- Allocates SSH ports from a configurable range (default 2222-2223)
- Allocates VNC ports from a configurable range (default 5901-5902)
- Creates TCP proxy: `localhost:port -> VM_NAT_IP:22` (SSH)
- Creates TCP proxy: `localhost:port -> VM_NAT_IP:5900` (VNC)
- Releases ports when a VM stops or is deleted; startup clears stale persisted SSH, VNC, and NAT assignments before
  new forwarding is configured

### GUIManager (@MainActor)

- Creates/manages `NSWindow` + `VZVirtualMachineView` per VM
- Idempotent: open brings to front, close is safe when already closed
- Provides hidden views for keystroke injection (when no GUI window is open)

## State Machine

![VM State Machine](state-machine.svg)

See <doc:VMState> for the full transition table.

**State persistence:** Lifecycle operations persist their resulting state before API handlers return. Event handlers
also persist lifecycle events and run side effects such as networking cleanup. On restart, `starting`, `stopping`,
`pausing`, and `resuming` are reset to `stopped`. A `paused` VM is preserved only when a shutdown recovery save
file exists.

**Error recovery:** If a lifecycle operation fails (for example, `vm.start()` throws), the VM transitions to
`error` rather than remaining stuck in an intermediate state. Every lifecycle method enforces this with error
handling and `forceState(.error)`.

On graceful shutdown (SIGTERM/SIGINT), the agent runs `cleanupForShutdown()` (30-second timeout):

- **Ephemeral VMs** - stopped (if running/paused) then deleted.
- **Non-ephemeral running VMs** - paused and saved to disk for restore on next launch.
- **Non-ephemeral in-memory paused VMs** - their existing paused runtime is saved without resuming it first.

On crash or forced kill, runtime state is reconciled on the next startup. Runtime transitional and running VMs become
`stopped`; interrupted installations become `created`; finalizing installations become `stopped` or `error` after
bundle validation. A paused VM remains `paused` only with a valid shutdown save, and previously booted ephemeral VMs
are deleted after inactive runtime recovery.

## Storage Layout

```
~/Library/Application Support/Jeballto/
+-- config.json              # Agent configuration (600 permissions)
+-- vms.json                 # VM definitions database
+-- images.json              # Image index
+-- VMs/
|   +-- {vm-uuid}.bundle/
|       +-- Disk.img         # VM disk image
|       +-- AuxiliaryStorage # Hardware-specific NVRAM data
|       +-- HardwareModel    # Serialized hardware model
|       +-- MachineIdentifier # Unique machine ID
|       +-- SaveFile.vzvmsave # Optional durable shutdown save, not an in-memory API pause
+-- Images/
    +-- {image-uuid}.bundle/
        +-- Disk.img         # VM disk image
        +-- AuxiliaryStorage # Hardware-specific NVRAM data
        +-- HardwareModel    # Serialized hardware model
        +-- MachineIdentifier # Unique machine ID

~/Library/Caches/Jeballto/
+-- IPSWCache/               # Downloaded macOS IPSWs reused across installs
+-- ImageWork/               # Transient image package and pull work directories

~/Library/Logs/Jeballto/
+-- agent-YYYY-MM-DD.log     # Daily rotating application logs
```

Images pulled from an OCI registry are stored under `Application Support/Jeballto/Images/` as `.bundle` directories named after the image UUID. The image UUID in `images.json` maps directly to the directory name on disk. Transient image work directories live under `~/Library/Caches/Jeballto/` and are disposable.

### Persistent Format Versions

The three persisted contracts are versioned independently:

| Contract | Current version | Selector |
|---|---:|---|
| VM database | v1 | Top-level `version` in `vms.json` |
| Local image index | v1 | Top-level `version` in `images.json` |
| Jeballto VM Bundle Format | v1 | Required `formatVersion` in the OCI config blob and local image record |

Readers require the current version and a complete current schema. Unsupported or incomplete data fails closed. A
backup is accepted only when it passes the same version and schema validation as the primary file. These version
numbers are independent of the Jeballto application version and of each other.

## Threading Model

| Component | Isolation | Why |
|-----------|-----------|-----|
| VMManager, PersistenceStore, NetworkManager, PortForwardingManager, ImageManager, ImageStore | `actor` | Thread-safe state management |
| VMInstance, GUIManager, StatusBarManager | `@MainActor` | `VZVirtualMachine` and Cocoa require main queue |
| EventBus | Concurrent state queue plus serial delivery queue | Ordered, non-blocking pub/sub |
| APIServer | Dedicated I/O queue | Non-blocking HTTP handling |
| VMStateMachine | `NSRecursiveLock` (`@unchecked Sendable`) | Lightweight transition validation |

## Architectural Constraints

**Concurrent VM limit:** Jeballto allows at most 2 capacity-consuming VMs simultaneously. This is a product policy,
not a Virtualization framework hardware limit. Installing, starting, running, pausing, paused, resuming, and in-flight
capacity reservations count toward the limit.

**Platform:** Apple Silicon only (ARM64 check on startup). macOS 26.0+.

**Image tool dependencies:** OCI image operations require `oras` and `zstd`. Both must be bundled in the app's Resources or configured via `images.orasPath` and `images.zstdPath`.

## Security

- Token auto-generated on first run and stored in the macOS Keychain
- Registry credentials are validated before storage and kept in a separate Jeballto Keychain service. Logout removes
  only that credential, and hard reset removes all Jeballto-owned API and registry secrets.
- API binds to all interfaces by default (`0.0.0.0`) and requires the bearer token for every endpoint except `/v1/health`
- SSH passwords passed via `SSH_ASKPASS` script (not in process arguments)
- OCI registry passwords passed via stdin to oras (not in process arguments)
- Entries in `images.insecureRegistries` use plain HTTP, so credentials and image artifacts are not protected in transit
- Tokens masked in logs (first 4 + last 4 chars shown)
