# ``Config``

## Overview

`Config` holds the runtime configuration for the agent. It is loaded from
`~/Library/Application Support/Jeballto/config.json` on startup. If the file does not exist, `load(from:)`
creates it with defaults. The Bearer token is generated on first launch and stored in the macOS Keychain,
not in this file. Successful OCI registry logins are stored in a separate Jeballto Keychain service. Release builds
require the data protection Keychain and fail startup if signing does not provide
the required application identifier and access group. Debug builds without such a group use the login Keychain.
Any `api.token` value found in a config file is ignored. The signed app must preserve the `keychain-access-groups`
entry declared in `JeballtoAgent.entitlements`; its provisioning profile must authorize the expanded application
identifier group.

The config file is written with 0o600 permissions (owner read/write only). In the data protection Keychain, the API
token uses the `WhenUnlockedThisDeviceOnly` accessibility class. Registry credentials use
`AfterFirstUnlockThisDeviceOnly` so headless image operations can continue after the user has unlocked the Mac once
since boot.

Changes made via `PATCH /v1/config` are saved to the active config path atomically using `Config.save(to:)`. Logging
and image settings apply at runtime. Networking settings are accepted and persisted, then take effect after an agent
restart. A patch must contain at least one effective writable field. Empty requests, empty sections, and requests
containing only unknown or read-only fields are rejected.

Configuration validation rejects overlapping SSH and VNC ranges and an API port inside either forwarding range.
VM storage, image storage, the database, image index, and log directory must use absolute paths. Managed directories
cannot be the filesystem or home root and cannot overlap. Index files must be distinct and live outside the managed
VM, image, and log directories. Existing paths must have the expected file or directory type. Custom `orasPath` and
`zstdPath` values must name existing executable files. Registry hostnames must be lowercase, use a valid optional
port, and cannot be duplicated in `insecureRegistries`. `images.defaultRegistry` allows otherwise unqualified OCI
references; without it, a registry is required.
Entries in `insecureRegistries` use plain HTTP and do not protect registry credentials or VM image artifacts in
transit.

## Topics

### Loading and Saving

- ``load(from:)``
- ``save(to:)``
- ``default``
- ``defaultConfigPath()``

### API Server

- ``api``
- ``APIConfig``

### Storage

- ``storage``
- ``StorageConfig``

### Logging

`LoggingConfig` controls the log level, file logging, retention, and timestamp timezone. The `timezone` field accepts any IANA identifier (e.g. `"UTC"`, `"Europe/Warsaw"`). When `nil` (the default), log timestamps use the system timezone. Changes via `PATCH /v1/config` apply to new log entries immediately.
`maxTotalSize` accepts a positive whole number followed by `MB` or `GB`, for example `500MB` or `2GB`. These suffixes
use 1024-based units. Historical files are removed by the retention pass. If the active daily file reaches the
configured budget, it is truncated before the next entry is written so one day's log cannot grow without a bound.

- ``logging``
- ``LoggingConfig``

### Networking

- ``networking``
- ``NetworkingConfig``

### Image Management

- ``images``
- ``ImageConfig``
