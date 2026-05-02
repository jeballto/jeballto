# ``VMManager``

## Overview

`VMManager` is the central actor for all VM operations. It maintains an in-memory registry of active `VMInstance` objects, enforces the Apple Silicon 2-VM concurrent limit, and coordinates with `PersistenceStore`, `EventBus`, `NetworkManager`, `PortForwardingManager`, and `GUIManager`.

Capacity enforcement includes active and transitional VM states plus actor-owned reservations created before
`startVM`, `resumeVM`, and `installVM` suspend. This prevents concurrent API calls from bypassing the limit while a
VM is moving toward a capacity-consuming state.

On restart, `loadPersistedVMs()` reconciles disk state with in-memory state. VMs in transitional states (`starting`, `stopping`, `pausing`, `resuming`) are reset to `stopped`. VMs that were `paused` with a save file on disk remain `paused` and can be resumed.

The `nonisolated(unsafe) var eventSubscription` pattern is used because `EventBus.subscribe` is called during `init` before the actor is fully isolated, and `deinit` must reference it from outside the actor context.

## Topics

### VM Lifecycle

- ``createVM(name:resources:ephemeral:lifetimeSeconds:)``
- ``startVM(_:)``
- ``stopVM(_:)``
- ``pauseVM(_:)``
- ``resumeVM(_:)``
- ``deleteVM(_:deleteFiles:force:)``
- ``cloneVM(_:name:resources:force:ephemeral:)``

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
