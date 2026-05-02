# ``Config``

## Overview

`Config` holds the complete runtime configuration for the agent. It is loaded from `~/Library/Application Support/Jeballto/config.json` on startup. If the file does not exist, `load(from:)` creates it with defaults and a freshly generated UUID for the API token.

The config file is written with 0o600 permissions (owner read/write only) because it contains the Bearer token used to authenticate all API calls.

Changes made via `PATCH /v1/config` are applied in-memory and saved to disk atomically using `Config.save(to:)`.

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

- ``logging``
- ``LoggingConfig``

### Networking

- ``networking``
- ``NetworkingConfig``

### Image Management

- ``images``
- ``ImageConfig``
