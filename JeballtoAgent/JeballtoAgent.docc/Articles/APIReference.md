# REST API Reference

Complete reference for the JeballtoAgent REST API. Base URL: `http://127.0.0.1:8011`

## Authentication

All endpoints except `/v1/health` require a Bearer token:

```bash
export TOKEN=$(cat ~/Library/Application\ Support/Jeballto/config.json | grep token | cut -d'"' -f4)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8011/v1/vms
```

The token is auto-generated on first run and saved to `~/Library/Application Support/Jeballto/config.json` (permissions 0o600). See <doc:Config> for configuration details.

### Verify Token

```http
GET /v1/auth/verify
```

Returns 200 if the token is valid, 401 otherwise. Useful for quickly validating credentials without side effects.

```bash
curl http://127.0.0.1:8011/v1/auth/verify -H "Authorization: Bearer $TOKEN"
# {"status": "ok"}
```

A machine-readable OpenAPI 3.0.3 spec is available at `openapi/jeballto-api.yaml` in the project repository.

## Health Check

```http
GET /v1/health
```

No authentication required.

```bash
curl http://127.0.0.1:8011/v1/health
```

```json
{
  "status": "healthy",
  "version": "1.0.0-beta.1",
  "uptime": 3600,
  "vmsRunning": 1,
  "vmsTotal": 3
}
```

## VM Management

### Create VM

```http
POST /v1/vms
```

Two modes: **blank** (needs install) or **from OCI image** (ready to start).

**Blank VM:**

```bash
curl -X POST http://127.0.0.1:8011/v1/vms \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "my-vm",
    "resources": {
      "cpuCount": 4,
      "memorySize": "8GB",
      "diskSize": "64GB"
    }
  }'
```

Resource sizes accept human-readable strings (`"4GB"`, `"512MB"`) or raw byte values. Fractional values like `"4.5GB"` are supported.

**From OCI image (skip install):**

```bash
curl -X POST http://127.0.0.1:8011/v1/vms \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "from-image", "image": "registry.example.com/vms/dev:latest"}'
```

The `image` field takes an OCI reference. The image is pulled automatically if not already local. **`resources` cannot be set alongside `image`** - use `PATCH /v1/vms/{id}` to adjust CPU, memory, or disk after creation.

**With a lifetime (auto-stop after 1 hour):**

```bash
curl -X POST http://127.0.0.1:8011/v1/vms \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "ci-vm", "image": "registry.example.com/vms/dev:latest", "ephemeral": true, "lifetimeSeconds": 3600}'
```

**Request fields:**

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | yes | - | 1-100 chars, alphanumeric/hyphens/underscores/spaces/dots |
| `resources.cpuCount` | int | no | 4 | 1-32. Not allowed with `image`. |
| `resources.memorySize` | int or string | no | 4 GB | Min 2 GB. Not allowed with `image`. |
| `resources.diskSize` | int or string | no | 64 GB | Min 20 GB. Not allowed with `image`. |
| `image` | string | no | - | OCI image reference. Cannot be combined with `resources`. |
| `ephemeral` | bool | no | false | Auto-delete on terminal state and on agent shutdown. |
| `lifetimeSeconds` | int | no | - | Max lifetime in seconds (1-604800). Countdown starts on first RUNNING transition. VM is stopped on expiry; ephemeral VMs are also deleted. |

**Response (201):** VM object. Includes `lifetimeSeconds` and `expiresAt` (ISO 8601, null until VM first runs).

### List VMs

```http
GET /v1/vms?limit=50&offset=0
```

| Query | Type | Default | Max | Description |
|-------|------|---------|-----|-------------|
| `limit` | int | 100 | 1000 | Number of VMs to return |
| `offset` | int | 0 | - | Skip the first N results |

```bash
curl http://127.0.0.1:8011/v1/vms -H "Authorization: Bearer $TOKEN"
```

### Get VM

```http
GET /v1/vms/{id}
```

### Delete VM

```http
DELETE /v1/vms/{id}
```

VM must be stopped, or use `?force=true` to auto-stop first.

```bash
# Force delete
curl -X DELETE "http://127.0.0.1:8011/v1/vms/$VM_ID?force=true" \
  -H "Authorization: Bearer $TOKEN"
```

### Wipe All VMs

```http
DELETE /v1/vms?confirm=true
```

Requires `confirm=true`. Cancels active async image operations, force-stops each VM, then deletes all.

### Clone VM

```http
POST /v1/vms/{id}/clone
```

Creates a copy with a new UUID, MachineIdentifier, and MAC address. Source must be stopped (or `?force=true`).

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/clone \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "cloned-vm"}'
```

Optionally override resources or mark as ephemeral:

```json
{"name": "cloned-vm", "resources": {"cpuCount": 8, "memorySize": "16GB"}, "ephemeral": true}
```

Ephemeral clones auto-delete when stopped or entering error state.

### Update VM

```http
PATCH /v1/vms/{id}
```

Update name and/or resources for a VM. Name can be changed in any non-deleted state. Resource changes require the VM to be stopped or created. Disk can only be enlarged.

```bash
curl -X PATCH http://127.0.0.1:8011/v1/vms/$VM_ID \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "new-name", "resources": {"cpuCount": 8, "memorySize": "16GB"}}'
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | no | 1-100 chars, alphanumeric/hyphens/underscores/spaces/dots |
| `resources.cpuCount` | int | no | 1-32, clamped to host CPUs - 1 |
| `resources.memorySize` | int or string | no | Min 2 GB (e.g., `"8GB"` or bytes) |
| `resources.diskSize` | int or string | no | Min 20 GB, can only grow |

At least one field must be provided. Returns 409 if resource changes are requested and VM is not stopped or created.

**Response (200):** VM object with updated values.

## VM Lifecycle

### Start VM

```http
POST /v1/vms/{id}/start
```

Max 2 VMs can consume capacity concurrently (Apple Silicon hardware limit). Active states, transitional states, and
capacity reservations count. Returns `VM_LIMIT_REACHED` (409) if exceeded.

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/start \
  -H "Authorization: Bearer $TOKEN"
```

### Stop VM

```http
POST /v1/vms/{id}/stop
```

Hard stop - save work inside the VM first. Idempotent when the VM is already stopped.

### Pause VM

```http
POST /v1/vms/{id}/pause
```

Saves VM state to disk. Can resume later from exactly where it left off. Paused VMs count toward the 2-VM limit.

### Resume VM

```http
POST /v1/vms/{id}/resume
```

Restores from saved state.

## macOS Installation

### Install macOS

```http
POST /v1/vms/{id}/install
```

Returns 202 immediately. Poll the status endpoint to track progress.

**Auto-download latest:**

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/install \
  -H "Authorization: Bearer $TOKEN"
```

**From remote URL or local path:**

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/install \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"source":"/Users/me/Downloads/macOS.ipsw"}'
```

### Get Installation Status

```http
GET /v1/vms/{id}/install/status
```

```bash
watch -n 2 "curl -s http://127.0.0.1:8011/v1/vms/$VM_ID/install/status \
  -H 'Authorization: Bearer $TOKEN'"
```

```json
{
  "vmId": "550e8400-...",
  "status": "installing",
  "progress": 0.45,
  "message": "Downloading restore image"
}
```

Progress: `0.0` to `1.0`. Status values: `not_started`, `installing`, `completed`, `failed`.

## Command Execution

```http
POST /v1/vms/{id}/execute
```

Runs a shell command via SSH. VM must be `RUNNING` with Remote Login enabled in the guest.

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/execute \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"uname -a"}'
```

```json
{
  "vmId": "550e8400-...",
  "exitCode": 0,
  "stdout": "Darwin mac.local 23.1.0 Darwin Kernel Version 23.1.0 arm64\n",
  "stderr": ""
}
```

**Request fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `command` | string | - | Shell command |
| `user` | string | `"admin"` | SSH username |
| `password` | string | `"admin"` | SSH password. `null` for key-based auth |
| `timeout` | int | `30` | Seconds (1-600) |

**Limits:**

| What | Limit |
|------|-------|
| Command length | 64 KB |
| stdout/stderr capture | 5 MB each |
| SSH connect timeout | 5 seconds |
| Command timeout | 1-600 seconds |

## Keystroke Injection

```http
POST /v1/vms/{id}/keystrokes
```

Injects keystrokes via the Virtualization framework. Works in `RUNNING` or `INSTALLING` state - no SSH needed. Primary mechanism for automating the macOS Setup Assistant.

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/keystrokes \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"keystrokes":["admin<tab>admin<enter>"]}'
```

**Keystroke DSL:**

| Token | What it does |
|-------|-------------|
| plain text | Types each character individually |
| `<enter>`, `<tab>`, `<space>`, `<delete>`, `<esc>` | Common keys |
| `<left>`, `<right>`, `<up>`, `<down>` | Arrow keys |
| `<home>`, `<end>`, `<pageup>`, `<pagedown>` | Navigation keys |
| `<f1>` through `<f12>` | Function keys |
| `<leftCmdOn>` / `<leftCmdOff>` | Hold/release left Command |
| `<leftShiftOn>` / `<leftShiftOff>` | Hold/release left Shift |
| `<leftCtrlOn>` / `<leftCtrlOff>` | Hold/release left Control |
| `<leftAltOn>` / `<leftAltOff>` | Hold/release left Option |
| `<rightCmd*>`, `<rightShift*>`, `<rightCtrl*>`, `<rightAlt*>` | Right-side modifier variants |
| `<wait5s>`, `<waitNs>` | Pause N seconds (max 300 per wait) |

Keys are paced at ~75 ms apart. Use `<waitNs>` explicitly between actions that need longer settling (e.g. menu animations, app launches).

## SSH

### Get SSH Info

```http
GET /v1/vms/{id}/ssh
```

Returns the host and port for direct SSH connections. Port forwarding is set up automatically when a VM starts.

```bash
curl http://127.0.0.1:8011/v1/vms/$VM_ID/ssh -H "Authorization: Bearer $TOKEN"
```

```json
{"host": "127.0.0.1", "port": 2222, "status": "ready"}
```

Default range: 2222-2223 (configurable in `networking.sshPortRangeStart/End`).

### Enable SSH Forwarding

```http
POST /v1/vms/{id}/ssh
```

Allocates a host port and starts TCP proxy to guest port 22. Idempotent - returns existing forwarding if already active. VM must be `RUNNING`.

### Disable SSH Forwarding

```http
DELETE /v1/vms/{id}/ssh
```

Stops the TCP proxy and releases the allocated port.

## VNC

VNC forwarding creates a TCP proxy from a host port to the VM's VNC server (port 5900). Enable Screen Sharing in the guest first (System Settings - General - Sharing - Screen Sharing).

### Enable VNC Forwarding

```http
POST /v1/vms/{id}/vnc
```

Allocates a host port and starts the proxy. Idempotent. VM must be `RUNNING`.

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/vnc \
  -H "Authorization: Bearer $TOKEN"
# {"host": "127.0.0.1", "port": 5900, "status": "ready"}

open vnc://localhost:5900
```

### Disable VNC Forwarding

```http
DELETE /v1/vms/{id}/vnc
```

Stops the proxy and releases the port. Idempotent.

### Get VNC Info

```http
GET /v1/vms/{id}/vnc
```

Returns 404 if VNC forwarding is not enabled.

## GUI

### Open GUI Window

```http
POST /v1/vms/{id}/gui
```

Opens a native macOS window showing the VM display. Idempotent - brings to front if already open.

### Close GUI Window

```http
DELETE /v1/vms/{id}/gui
```

### Get GUI Status

```http
GET /v1/vms/{id}/gui
```

### Capture Screenshot

```http
GET /v1/vms/{id}/screenshot
```

Returns raw PNG bytes (`Content-Type: image/png`). Headless - no GUI window required. VM must be `RUNNING`.

```bash
curl -o screenshot.png http://127.0.0.1:8011/v1/vms/$VM_ID/screenshot \
  -H "Authorization: Bearer $TOKEN"
```

## VM State and Events

### Get VM State

```http
GET /v1/vms/{id}/state
```

```json
{"state": "RUNNING", "uptime": 1200}
```

**All states:**

| State | Meaning |
|-------|---------|
| `CREATED` | VM created, not yet installed or started |
| `INSTALLING` | macOS installation in progress |
| `STOPPED` | VM is stopped |
| `STARTING` | VM is booting |
| `RUNNING` | VM is running |
| `STOPPING` | VM is shutting down |
| `PAUSING` | VM is saving state |
| `PAUSED` | VM is paused (state saved to disk) |
| `RESUMING` | VM is restoring from saved state |
| `ERROR` | Something went wrong (check events) |
| `DELETED` | VM is marked for deletion |

See <doc:VMState> for state transition rules.

### Get Events

```http
GET /v1/vms/{id}/events?limit=100
```

Up to 1000 events retained per VM.

```json
{
  "events": [
    {
      "timestamp": "2026-02-27T10:30:00Z",
      "type": "VM_RUNNING",
      "vmId": "550e8400-...",
      "data": null
    }
  ],
  "total": 1
}
```

**Event categories:**

| Category | Event types |
|----------|------------|
| VM lifecycle | `VM_CREATED`, `VM_STARTING`, `VM_RUNNING`, `VM_STOPPING`, `VM_STOPPED`, `VM_PAUSED`, `VM_RESUMED`, `VM_DELETED`, `VM_CLONED`, `STATE_CHANGED` |
| Installation | `INSTALL_STARTED`, `INSTALL_PROGRESS`, `INSTALL_COMPLETED`, `INSTALL_FAILED` |
| GUI | `GUI_OPENED`, `GUI_CLOSED` |
| Network | `SSH_PORT_ASSIGNED`, `SSH_PORT_RELEASED`, `SSH_READY`, `VNC_PORT_ASSIGNED`, `VNC_PORT_RELEASED` |
| Images | `IMAGE_PULL_STARTED`, `IMAGE_PULLED`, `IMAGE_PULL_FAILED`, `IMAGE_PUSH_STARTED`, `IMAGE_PUSHED`, `IMAGE_PUSH_FAILED`, `IMAGE_DELETED` |
| Jeballtofile | `JEBALLTOFILE_STARTED`, `JEBALLTOFILE_STEP_STARTED`, `JEBALLTOFILE_STEP_COMPLETED`, `JEBALLTOFILE_STEP_FAILED`, `JEBALLTOFILE_COMPLETED`, `JEBALLTOFILE_CANCELLED`, `JEBALLTOFILE_FAILED` |
| Errors | `ERROR_OCCURRED` |

## OCI Image Management

Packages VM bundles as OCI artifacts using `oras`. Compatible with Docker Hub, GitHub Container Registry, AWS ECR, Harbor, and other OCI-compatible registries.

### Pull Image

```http
POST /v1/images/pull
```

Downloads and stores locally. Idempotent - returns existing record if already local.
Jeballto images use one OCI artifact format: `application/vnd.jeballto.vm.bundle`
with zstd-compressed chunk layers.

```bash
curl -X POST http://127.0.0.1:8011/v1/images/pull \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reference":"ghcr.io/myorg/vms/dev-env:latest"}'
```

Optional `timeout` field (seconds). No timeout by default.

Set `async` to `true` to return immediately with an operation ID:

```bash
curl -X POST http://127.0.0.1:8011/v1/images/pull \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reference":"ghcr.io/myorg/vms/dev-env:latest","async":true}'
```

Poll progress with:

```http
GET /v1/images/pull/{operationId}/status
```

Cancel a running async pull with:

```http
DELETE /v1/images/pull/{operationId}
```

Async pull flow:

1. Fetch the OCI manifest and validate the Jeballto artifact format.
2. Fetch the config blob and chunk blobs through the ORAS blob cache.
3. Decompress fetched chunk blobs and write the VM bundle files.
4. Validate the reconstructed VM bundle and store the local image record.

Pull work is pipelined, so there is no exclusive `stage`: blob fetches, decompression, and disk writes can overlap.
For pull status, `bytesCompleted` counts completed compressed OCI artifact bytes, including the config blob and
completed chunk blobs. `bytesTotal` is the compressed config plus compressed chunk blob total from the manifest.
`chunksCompleted` counts completed chunk blobs, and `chunksTotal` is the number of chunk layers in the manifest.
`progress` is derived from those compressed artifact bytes when totals are known.
`averageSpeedMBps` is the full artifact-flow speed for pull: completed compressed OCI artifact bytes divided by elapsed
pull operation time. It is not Activity Monitor network throughput, because it includes manifest work, cache waits,
decompression, disk writes, validation, and blob completion granularity.

After cancellation, status is `cancelling` while cleanup is still running, then `cancelled` when the operation is
fully stopped.

### Push Image

```http
POST /v1/images/push
```

Pushes a VM bundle or existing local image. Use `source` with `vm:<uuid>` or `image:<uuid>`.

**Requirements:**

- When using `vm:<uuid>`, the VM must be in `STOPPED` or `CREATED` state. Returns 409 `INVALID_STATE` if the VM is running or otherwise not stopped.
- The registry must be reachable before the push starts. A connectivity check against `<registry>/v2/` is performed upfront. Returns 503 `IMAGE_PUSH_FAILED` if the registry cannot be reached. This prevents waiting 20+ minutes for compression to complete before discovering connectivity issues.

```bash
curl -X POST http://127.0.0.1:8011/v1/images/push \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "reference": "ghcr.io/myorg/vms/dev-env:latest",
    "source": "vm:550e8400-e29b-41d4-a716-446655440000"
  }'
```

Set `async` to `true` to return immediately and poll progress:

```bash
curl -X POST http://127.0.0.1:8011/v1/images/push \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "reference": "ghcr.io/myorg/vms/dev-env:latest",
    "source": "vm:550e8400-e29b-41d4-a716-446655440000",
    "async": true
  }'
```

```http
GET /v1/images/push/{operationId}/status
```

Cancel a running async push with:

```http
DELETE /v1/images/push/{operationId}
```

Async push flow:

1. Verify registry reachability before expensive local work starts.
2. For `vm:<uuid>`, reserve the stopped VM bundle so it cannot be started, deleted, or resource-mutated mid-export.
3. For `image:<uuid>`, reserve the local source image so it cannot be deleted mid-export.
4. `compressing`: scan the VM bundle, split files into chunks, compress nonzero chunks with zstd, and build the OCI
   package metadata.
5. `uploading`: confirm or upload each config and chunk blob with ORAS, then push the OCI manifest.

Push has two mostly sequential stages, so status includes `stage` and `stageProgress`. `compressing` counts
uncompressed VM bundle bytes and chunks processed locally. When the stage switches to `uploading`, `bytesCompleted`
and `chunksCompleted` reset and then count compressed OCI blobs confirmed or uploaded to the registry. Push `progress`
is an overall value where compression contributes the first half and upload contributes the second half.
`averageSpeedMBps` is the per-stage artifact-flow speed for push: uncompressed local bundle throughput while
`compressing`, then compressed OCI artifact throughput while `uploading`. It is not raw system upload bandwidth,
because it includes blob existence checks, ORAS process overhead, registry latency, and only advances when blobs
complete.

After cancellation, status is `cancelling` while cleanup is still running, then `cancelled` when the operation is
fully stopped.

### List, Get, Delete Images

```http
GET  /v1/images
GET  /v1/images/{id}
DELETE /v1/images/{id}
DELETE /v1/images?confirm=true
```

Deleting an individual image returns 409 while that image is the source of an active push operation.
Deleting all images requires `confirm=true` and cancels active async image operations before image deletion starts.

### Image Reference Format

```
registry.example.com/repository/name:tag
registry.example.com/repository/name@sha256:abc123...
```

Registry must always be specified. References without a registry hostname are rejected.

## Registry Authentication

### Login

```http
POST /v1/registries/login
```

```bash
curl -X POST http://127.0.0.1:8011/v1/registries/login \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"registry": "ghcr.io", "username": "myuser", "password": "ghp_token_here"}'
```

Credentials are stored by `oras` in its default credential store.

### Logout

```http
POST /v1/registries/logout
```

```bash
curl -X POST http://127.0.0.1:8011/v1/registries/logout \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"registry":"ghcr.io"}'
```

### Insecure Registries

For local HTTP registries, add to `config.json`:

```json
{
  "images": {
    "insecureRegistries": ["localhost:5000"]
  }
}
```

## Configuration

### Get Config

```http
GET /v1/config
```

Returns current runtime configuration. Sensitive values (token, file paths) are excluded.

### Update Config

```http
PATCH /v1/config
```

Partial update - include only fields to change. Changes persist to disk and apply immediately, with two exceptions that require a restart: `api.port`, `api.host`, and `api.token`. Every other field hot-reloads.

```bash
# Change log level
curl -X PATCH http://127.0.0.1:8011/v1/config \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"logging": {"level": "debug"}}'
```

**Writable fields:**

| Section | Field | Constraints |
|---------|-------|-------------|
| `logging` | `level` | `debug`, `info`, `warning`, `error` |
| `logging` | `timezone` | IANA identifier (e.g. `"UTC"`, `"America/New_York"`), or `null` for system timezone |
| `networking` | `sshPortRangeStart`, `sshPortRangeEnd` | 1024-65535 |
| `networking` | `autoEnableSSHForwarding` | bool |
| `networking` | `vncPortRangeStart`, `vncPortRangeEnd` | 1024-65535 |
| `images` | `defaultRegistry`, `insecureRegistries` | - |
| `images` | `maxParallelImageBlobTransfers` | Concurrent ORAS blob fetch and push processes. Default 16, range 1-64 |
| `images` | `maxParallelImageCompressions` | Concurrent zstd compressions during image push. Default 4, range 1-32 |
| `images` | `maxParallelImageDecompressions` | Concurrent zstd decompressions during image pull. Default 2, range 1-8 |
| `images` | `maxParallelImageDiskWrites` | Concurrent output writes during image pull. Default 1, range 1-4 |

Image transfer operation data is kept only within the current agent session under `~/Library/Caches/Jeballto/ImageWork/`. Startup removes it, and successful pull or push removes the operation cache immediately.

## System Capabilities

```http
GET /v1/system/capabilities
```

Returns host facts and the Jeballto runtime capabilities available on this machine.

```json
{
  "host": {
    "architecture": "arm64",
    "macOSVersion": "26.5",
    "virtualizationSupported": true,
    "maxConcurrentVMs": 2
  },
  "features": [
    {
      "id": "macOSVirtualization",
      "status": "available",
      "enabled": true,
      "minimumOS": "11.0",
      "reason": null
    }
  ]
}
```

The capability list describes platform and runtime surfaces such as macOS installation, NAT networking, GUI display, screenshots, keystrokes, save/restore, port forwarding, and image packaging. It does not list ordinary VM actions such as create, start, stop, or delete.

`status` describes whether the host can support the capability. `enabled` describes whether Jeballto currently allows routes that depend on it.

## System Reset

```http
POST /v1/system/reset?confirm=true
```

Two modes:

- **soft** - Cancels active async image operations, deletes all VMs and images. Config and logs preserved. Agent keeps running.
- **hard** - Cancels active async image operations, deletes everything (VMs, images, config, logs) and terminates the process.

```bash
# Soft reset
curl -X POST "http://127.0.0.1:8011/v1/system/reset?confirm=true" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mode": "soft"}'
```

**Response (200):**

```json
{
  "mode": "soft",
  "vmsDeleted": 3,
  "vmsFailed": 0,
  "imagesDeleted": 2,
  "imagesFailed": 0,
  "ipswCacheCleared": true,
  "configDeleted": false,
  "logsDeleted": false,
  "willTerminate": false,
  "errors": null
}
```

| Field | Type | Description |
|-------|------|-------------|
| `mode` | string | `soft` or `hard` |
| `vmsDeleted` / `vmsFailed` | int | Counts of VM delete attempts |
| `imagesDeleted` / `imagesFailed` | int | Counts of image delete attempts |
| `ipswCacheCleared` | bool | `~/Library/Caches/Jeballto/IPSWCache/` was cleared |
| `configDeleted` / `logsDeleted` | bool | Only true in `hard` mode |
| `willTerminate` | bool | Agent is exiting after this response (hard mode) |
| `errors` | string[] or null | Per-item failure messages, if any |

## Error Responses

All errors return:

```json
{
  "error": {
    "code": "ERROR_CODE",
    "message": "Human-readable description",
    "details": {}
  }
}
```

**Error codes:**

| Code | HTTP | Meaning |
|------|------|---------|
| `UNAUTHORIZED` | 401 | Missing or invalid token |
| `NOT_FOUND` | 404 | VM or image not found |
| `INVALID_REQUEST` | 400 | Malformed request body |
| `INVALID_ID` | 400 | Invalid UUID format |
| `INVALID_STATE` | 409 | Operation not valid in current VM state |
| `VM_LIMIT_REACHED` | 409 | Max 2 active or transitioning VMs |
| `CAPABILITY_UNAVAILABLE` | 409 | Required host or runtime capability is unavailable |
| `START_FAILED` | 500 | VM start failed |
| `STOP_FAILED` | 500 | VM stop failed |
| `PAUSE_FAILED` | 500 | VM pause failed |
| `RESUME_FAILED` | 500 | VM resume failed |
| `INSTALL_FAILED` | 500 | macOS installation failed |
| `INSTALL_IN_PROGRESS` | 409 | Installation is already running for this VM |
| `EXECUTE_FAILED` | 500 | Command/keystroke execution failed |
| `EXECUTE_TIMEOUT` | 504 | Command timed out |
| `GATEWAY_TIMEOUT` | 504 | Operation timed out |
| `INVALID_JSON` | 400 | JSON parse error |
| `CONFIRMATION_REQUIRED` | 400 | Missing `?confirm=true` query parameter |
| `IMAGE_PUSH_FAILED` | 503 | Registry unreachable during pre-flight check |
