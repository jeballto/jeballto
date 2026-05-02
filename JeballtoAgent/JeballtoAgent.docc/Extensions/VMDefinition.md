# ``VMDefinition``

## Overview

`VMDefinition` is the primary persisted value type for a VM. It is `Codable`, `Identifiable`, and `Equatable`. All VM definitions are stored as JSON in `~/Library/Application Support/Jeballto/vms.json` via `PersistenceStore`.

All `update*` mutating methods set `updatedAt` to `Date()` automatically. Callers do not need to update the timestamp manually.

`VMResources`, `VMNetwork`, and `VMPaths` are value types embedded inline. There is no separate fetch needed to access resource or network details - the full definition is loaded atomically.

## Topics

### Identity and State

- ``id``
- ``name``
- ``state``
- ``createdAt``
- ``updatedAt``

### Resources

- ``resources``
- ``VMResources``

### Network

- ``network``
- ``VMNetwork``

### File Paths

- ``paths``
- ``VMPaths``

### Mutation

- ``updateState(_:)``
- ``updateSSHPort(_:)``
- ``updateVNCPort(_:)``
- ``clearVNCPort()``
- ``updateNATIP(_:)``
- ``clearNATIP()``
- ``clearSSHPort()``

### Metadata

- ``metadata``
