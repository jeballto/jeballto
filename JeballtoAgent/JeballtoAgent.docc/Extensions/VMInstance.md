# ``VMInstance``

## Overview

`VMInstance` wraps a single `VZVirtualMachine` and is isolated to `@MainActor` because the Virtualization framework requires all `VZVirtualMachine` operations to run on the main queue.

Callers from actor-isolated contexts use `await MainActor.run { ... }` to cross the isolation boundary.

After installation completes, `VMInstaller` calls `adoptVirtualMachine(_:delegate:)` to hand off the running `VZVirtualMachine` to the `VMInstance` that was created alongside it. This avoids a stop-restart cycle immediately after installation.

State transitions are validated by `VMStateMachine` before any lifecycle operation proceeds. An invalid transition throws rather than silently proceeding.

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
- ``adoptVirtualMachine(_:delegate:)``
