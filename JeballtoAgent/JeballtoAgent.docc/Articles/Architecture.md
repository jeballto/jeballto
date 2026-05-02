# Architecture

How JeballtoAgent is structured internally - components, concurrency model, state machine, and storage layout.

## Overview

JeballtoAgent is a headless macOS app built on Apple's Virtualization framework. It exposes a REST API for programmatic VM lifecycle management and uses a layered, actor-based architecture for thread safety.

## System Components

![System Architecture](architecture.svg)

## Component Responsibilities

### JeballtoAgent (Main)

- Application entry point (`NSApplication`-based)
- Initializes all components in this order: EventBus, PersistenceStore, NetworkManager, PortForwardingManager, GUIManager, VMManager, ImageManager, APIServer
- Signal handling (SIGTERM, SIGINT) - cleans up VMs on shutdown: ephemeral VMs are stopped and deleted, non-ephemeral running VMs are paused and saved

### APIServer

- HTTP server on configurable host:port (default `0.0.0.0:8011`)
- Bearer token authentication (checked before routing)
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
- State reconciliation on restart (transitional states reset to STOPPED)
- Lifetime expiry: schedules a background task per VM; fires `stopVM` on expiry (ephemeral VMs auto-delete via the `.vmStopped` event path)

See <doc:VMManager> for the symbol reference.

### VMInstance (@MainActor)

- Wraps a single `VZVirtualMachine`
- State machine enforcement (validates every transition)
- Lifecycle operations (start, stop, pause, resume)
- Save/restore support (saves to `SaveFile.vzvmsave`)
- Tracks uptime while running

`VZVirtualMachine` and its associated views require the main queue. `VMInstance` is `@MainActor` to enforce this. Calls from actor-isolated code go through `await MainActor.run { ... }`.

### VMInstaller

Three installation paths:

| Method | What happens |
|--------|-------------|
| Auto-download | Fetches latest macOS IPSW from Apple (retries 3x with backoff) |
| Remote URL | Downloads IPSW to temp dir, then installs |
| Local file | Loads IPSW directly from disk |

Progress events: `installStarted` - `installProgress` (with messages) - `installCompleted` or `installFailed`.

### CommandExecutor

Runs shell commands inside VMs over SSH:

```
APIServer
  -> CommandExecutor.execute(command, sshPort, user, password, timeout)
    -> Process("/usr/bin/ssh", args)
      -> SSH_ASKPASS script (password via env, not in process args)
      -> Race: command vs timeout task
    -> CommandResult { exitCode, stdout, stderr }
```

Limits: 5 MB per output stream, 64 KB command length, 5s SSH connect timeout.

### KeystrokeParser and KeystrokeInjector

Parses a DSL string (e.g. `"hello<enter><wait2s>"`) into actions, then injects them into `VZVirtualMachineView` as synthetic `NSEvent`s.

```
APIServer
  -> KeystrokeParser.parse("hello<enter>")
    -> [.keyPress(h), .keyPress(e), ..., .keyPress(enter)]
  -> KeystrokeInjector.execute(actions, vm, guiManager)
    -> ensureView() (creates hidden view if no GUI window open)
    -> view.keyDown()/keyUp() for each action
    -> 75ms delay between keys
```

Works during `INSTALLING` state - no SSH needed.

### ImageManager (actor)

OCI image operations using `oras` CLI:

| Operation | What happens |
|-----------|-------------|
| `pullImage(reference)` | Checks local cache first - `oras pull` - stores in `Images/{uuid}/` - registers in ImageStore |
| `pushImageFromVM(reference, vmBundlePath)` | Enumerates VM bundle files - `oras push` with artifact type `application/vnd.jeballto.vm.bundle.v1` |
| `pushImage(reference, imageId)` | Re-pushes existing local image to new reference |
| `deleteImage(id)` | Removes files (if owned, not a shared VM bundle) - removes from ImageStore |
| `loginRegistry` / `logoutRegistry` | Delegates to `oras login/logout` |

### OrasClient

Thin wrapper around the `oras` CLI binary. Key design choices:

- Uses `Process` with argument arrays (no shell invocation) to prevent command injection
- Passwords passed via stdin (not in process args, not visible in `ps`)
- Timeout protection: no limit for pull/push, 30s for login/logout/resolve
- Output capped at 5 MB per stream

Resolves `oras` binary: checks `config.images.orasPath` first, then `Bundle.main.resourceURL/oras`.

### EventBus

Non-blocking pub/sub event system:

- Subscribers run on background dispatch queues
- Thread-safe: concurrent queue with barriers for writes
- Retains last 1000 events (per-VM queryable)
- Subscription tokens for unsubscribe

One slow subscriber cannot block others. See <doc:EventBus>.

### NetworkManager (actor)

- Generates unique locally-administered MAC addresses per VM
- Prevents MAC collisions
- Creates `VZNATNetworkDeviceAttachment` (provides internet + DHCP)

### PortForwardingManager (actor)

- Allocates SSH ports from a configurable range (default 2222-2223)
- Allocates VNC ports from a configurable range (default 5901-5902)
- Creates TCP proxy: `localhost:port -> VM_NAT_IP:22` (SSH)
- Creates TCP proxy: `localhost:port -> VM_NAT_IP:5900` (VNC)
- Releases ports when a VM is deleted; re-registers reserved ports for persisted VMs on agent startup

### GUIManager (@MainActor)

- Creates/manages `NSWindow` + `VZVirtualMachineView` per VM
- Idempotent: open brings to front, close is safe when already closed
- Provides hidden views for keystroke injection (when no GUI window is open)

## State Machine

![VM State Machine](state-machine.svg)

See <doc:VMState> for the full transition table.

**State persistence:** Every transition is persisted immediately. On restart, transitional states (STARTING, STOPPING, PAUSING, RESUMING) are reset to STOPPED. PAUSED with a save file is preserved.

**Error recovery:** If a lifecycle operation fails (e.g. `vm.start()` throws), the VM transitions to ERROR state rather than remaining stuck in an intermediate state. This is enforced in every lifecycle method via do/catch with `forceState(.error)`.

On graceful shutdown (SIGTERM/SIGINT), the agent runs `cleanupForShutdown()` (30-second timeout):

- **Ephemeral VMs** - stopped (if running/paused) then deleted.
- **Non-ephemeral running VMs** - paused and saved to disk for restore on next launch.

On crash or forced kill, VM runtime state is lost and VMs revert to STOPPED on next startup.

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
|       +-- SaveFile.vzvmsave # Saved VM state (optional, present when paused)
+-- Images/
    +-- {image-uuid}.bundle/
        +-- Disk.img         # VM disk image
        +-- AuxiliaryStorage # Hardware-specific NVRAM data
        +-- HardwareModel    # Serialized hardware model
        +-- MachineIdentifier # Unique machine ID

~/Library/Logs/Jeballto/
+-- agent-YYYY-MM-DD.log     # Daily rotating application logs
```

Images pulled from an OCI registry are stored as `.bundle` directories named after the image UUID, matching the VM storage format. The image UUID in `images.json` maps directly to the directory name on disk.

## Threading Model

| Component | Isolation | Why |
|-----------|-----------|-----|
| VMManager, PersistenceStore, NetworkManager, PortForwardingManager, ImageManager, ImageStore | `actor` | Thread-safe state management |
| VMInstance, GUIManager | `@MainActor` | `VZVirtualMachine` and Cocoa require main queue |
| EventBus | Dispatch queue (concurrent + barriers) | High-throughput pub/sub |
| APIServer | Dedicated I/O queue | Non-blocking HTTP handling |
| VMStateMachine | `NSRecursiveLock` (`@unchecked Sendable`) | Lightweight transition validation |

## Architectural Constraints

**Concurrent VM limit:** Max 2 VMs simultaneously on Apple Silicon. This is a hardware limitation enforced by the Virtualization framework. Paused VMs do not count toward the limit.

**Platform:** Apple Silicon only (ARM64 check on startup). macOS 26.0+.

**oras dependency:** OCI image operations require the `oras` binary. It must be bundled in the app's Resources or configured via `images.orasPath`.

## Security

- Bearer token auth on all endpoints except `/v1/health`
- Token auto-generated on first run, stored in config file with 600 permissions
- API binds to localhost by default
- SSH passwords passed via `SSH_ASKPASS` script (not in process arguments)
- OCI registry passwords passed via stdin to oras (not in process arguments)
- Tokens masked in logs (first 4 + last 4 chars shown)
