# ``VMState``

## Overview

`VMState` is the complete state space for a VM instance. Normal lifecycle transitions are validated by
`VMStateMachine` before they are applied. Attempting an invalid transition throws
`VMStateMachineError.invalidTransition`. Explicit recovery reconciliation may force a state after inspecting the
runtime and persisted installation data.

`deleted` is the only terminal state - no further transitions are possible. `isOperational` is true when the VM is usable (`running` or `paused`).

On agent restart, transitional states (`starting`, `stopping`, `pausing`, `resuming`) are reset to `stopped` because
the `VZVirtualMachine` process is gone. An active `installing` record is marked `interrupted` and reset to `created`
after partial artifacts are cleaned. A `finalizing` record with a complete VM bundle recovers as `completed` and
`stopped`; an incomplete bundle recovers as `failed` and `error`. `paused` is preserved only if graceful shutdown
created `SaveFile.vzvmsave`; after a crash or forced termination, an in-memory API pause without that file reconciles
to `stopped`.

### Valid Transition Table

| From | Valid transitions |
|------|-----------------|
| `created` | `installing`, `starting`, `error`, `deleted` |
| `installing` | `stopped`, `starting`, `error`, `deleted` |
| `stopped` | `starting`, `deleted`, `error` |
| `starting` | `running`, `paused`, `error` |
| `running` | `stopping`, `pausing`, `error` |
| `stopping` | `stopped`, `error` |
| `pausing` | `paused`, `error` |
| `paused` | `resuming`, `starting`, `stopping`, `error` |
| `resuming` | `running`, `error` |
| `error` | `created`, `stopped`, `deleted` |
| `deleted` | (terminal - none) |

Every state except `error` and `deleted` can transition to `error`.

## Topics

### States

- ``created``
- ``installing``
- ``stopped``
- ``starting``
- ``running``
- ``stopping``
- ``pausing``
- ``paused``
- ``resuming``
- ``error``
- ``deleted``

### Validation

- ``canTransition(to:)``
- ``validTransitions``
- ``isTerminal``
- ``isOperational``
