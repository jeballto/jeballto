# ``VMState``

## Overview

`VMState` is the complete state space for a VM instance. Every state transition is validated by `VMStateMachine` before it is applied. Attempting an invalid transition throws `VMStateMachineError.invalidTransition`.

`deleted` is the only terminal state - no further transitions are possible. `isOperational` is true when the VM is usable (`running` or `paused`).

On agent restart, transitional states (`starting`, `stopping`, `pausing`, `resuming`) are reset to `stopped` because the `VZVirtualMachine` process is gone. `paused` is preserved if `SaveFile.vzvmsave` exists on disk.

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
| `error` | `stopped`, `deleted` |
| `deleted` | (terminal - none) |

All non-terminal states can transition to `error`.

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
