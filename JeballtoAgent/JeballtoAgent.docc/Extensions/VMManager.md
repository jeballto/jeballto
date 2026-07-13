# ``VMManager``

## Overview

`VMManager` is the central actor for all VM operations. It maintains an in-memory registry of active `VMInstance`
objects, enforces Jeballto's 2-VM product limit, and coordinates with `PersistenceStore`, `EventBus`,
`NetworkManager`, `PortForwardingManager`, and `GUIManager`.

Capacity enforcement includes active and transitional VM states plus actor-owned reservations created before
`startVM`, `resumeVM`, and installation entry points suspend. A reservation uses the same VM UUID, so it does not
double-count an already active VM, but it keeps that slot claimed if a runtime callback changes state while the
operation is suspended. This prevents concurrent API calls from bypassing the limit.

On restart, `loadPersistedVMs()` reconciles disk state with in-memory state. VMs in runtime transitional states
(`starting`, `stopping`, `pausing`, `resuming`) are reset to `stopped`. An interrupted installation is cleaned and
reset to `created`; installation finalization is validated as either `stopped` or `error`. A VM remains `paused` only
when graceful shutdown created a save file; after a crash or forced termination, an in-memory API pause without that
file reconciles to `stopped`.
Ephemeral VMs that had booted are deleted during recovery once their runtime is no longer active.
The first durable `running` update records `hasBooted` and any lifetime deadline in the same database commit.
If startup finds an already-booted lifetime-limited record without a deadline, it reconstructs the deadline from the
record's last durable `updatedAt` timestamp before registering the VM.

The `nonisolated(unsafe) var eventSubscription` pattern is used because `EventBus.subscribe` is called during `init` before the actor is fully isolated, and `deinit` must reference it from outside the actor context.

## Topics

### VM Lifecycle

- ``createVM(name:resources:ephemeral:lifetimeSeconds:)``
- ``startVM(_:)``
- ``stopVM(_:)``
- ``pauseVM(_:)``
- ``resumeVM(_:)``
- ``deleteVM(_:force:owningEphemeralDeletionToken:)``
- ``cloneVM(_:name:cpuCount:memorySize:diskSize:force:ephemeral:lifetimeSeconds:)``

### macOS Installation

- ``installVM(_:ipswSource:)``
- ``getInstallationStatus(_:)``

### Queries

- ``listVMs()``
- ``getVM(_:)``
- ``getVMState(_:)``
- ``vmCount()``
- ``runningVMCount()``
- ``activeVMCount()``

### Persistence

- ``loadPersistedVMs()``
- ``saveVM(_:)``

### Internal State

- ``getVMInstance(_:)``
