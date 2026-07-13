# ``VMInstance``

## Overview

`VMInstance` wraps a single `VZVirtualMachine` and is isolated to `@MainActor` because the Virtualization framework requires all `VZVirtualMachine` operations to run on the main queue.

Actor-isolated callers use `await MainActor.run { ... }` for synchronous property access. Asynchronous lifecycle
methods are called directly with `await`.

During installation, `VMInstaller` owns a separate transient `VZVirtualMachine`. Finalization detaches its delegate,
waits until that runtime releases the VM files, validates the completed bundle, and records the VM as `stopped`.
The next explicit start creates a fresh runtime in `VMInstance`.

Normal lifecycle transitions are validated by `VMStateMachine` before the operation proceeds. An invalid transition
throws rather than silently proceeding. Explicit failure and restart recovery may use `forceState(_:)` to reconcile
an observed runtime or persisted state.

## Topics

### Lifecycle

- ``start()``
- ``stop()``
- ``pause()``
- ``resume()``

### State

- ``stateMachine``
- ``currentState``

### Virtual Machine Access

- ``virtualMachine``
