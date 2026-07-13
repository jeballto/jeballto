# REST API Reference

Complete reference for the JeballtoAgent REST API. Base URL: `http://127.0.0.1:8011`

## Authentication

All endpoints except `/v1/health` require a Bearer token:

```bash
export TOKEN='paste-token-copied-from-the-menu-bar'
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8011/v1/vms
```

The token is auto-generated on first run and stored in the macOS Keychain. Use the menu-bar **Copy API Token**
action to retrieve it. A signed Release stores the item in the data protection Keychain, which the `security`
command-line tool cannot reliably query. See <doc:Config> for configuration details.

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

Resource sizes accept human-readable strings such as `"4GB"` and `"64GB"`, or raw byte values. Decimal fractions
such as `"4.5GB"` are supported when they resolve to a whole number of bytes. Scientific notation is rejected. RAM
must be 2-128 GB and disk size must be 20 GB-8 TB.

**From OCI image (skip install):**

```bash
curl -X POST http://127.0.0.1:8011/v1/vms \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "from-image", "image": "registry.example.com/vms/dev:latest"}'
```

The `image` field takes an OCI reference. Digest-pinned references reuse a valid matching local image. Mutable tags
are resolved against the registry on every request and reuse the local image only when its digest still matches. The
VM uses the CPU, memory, and disk resources recorded in the image. **`resources` cannot be set alongside `image`**.
Use `PATCH /v1/vms/{id}` after creation if different resources are needed.

Creating from an image performs the same validated, blocking pull used by `POST /v1/images/pull` before the VM is
created. Invalid references return `INVALID_REFERENCE` with HTTP 400. Unversioned or unsupported formats return
`UNSUPPORTED_IMAGE_FORMAT` with HTTP 400, and malformed v1 artifacts return `INVALID_IMAGE` with HTTP 400. Registry,
timeout, cancellation, capability, image-operation capacity, and image-in-use failures keep their normal pull error
codes and HTTP statuses. No VM is created when the implicit pull fails.

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
| `name` | string | yes | - | 1-100 characters. Unicode letters/numbers, hyphens, underscores, spaces, and dots. No leading or trailing whitespace. |
| `resources.cpuCount` | int | no | 4 | 1-32 and no more than the current host supports. Not allowed with `image`. |
| `resources.memorySize` | int or string | no | 4 GB | 2-128 GB. Not allowed with `image`. |
| `resources.diskSize` | int or string | no | 64 GB | 20 GB-8 TB. Not allowed with `image`. |
| `image` | string | no | - | OCI image reference, at most 1,024 UTF-8 bytes. Cannot be combined with `resources`. |
| `ephemeral` | bool | no | false | After its first successful run, auto-delete on `stopped` or `error`. Always delete on agent shutdown. |
| `lifetimeSeconds` | int | no | - | Max lifetime in seconds (1-604800). Countdown starts on the first `running` transition. VM is stopped on expiry; ephemeral VMs are also deleted. |

**Response (201):** VM object. Resource values in responses use exact byte counts for `memorySize` and `diskSize`.
The object also includes `lifetimeSeconds` and `expiresAt` (ISO 8601, null until VM first runs).

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

A VM in `created`, `stopped`, or `error` can be deleted directly. Use `?force=true` to stop an active VM before
deletion.

```bash
# Force delete
curl -X DELETE "http://127.0.0.1:8011/v1/vms/$VM_ID?force=true" \
  -H "Authorization: Bearer $TOKEN"
```

### Wipe All VMs

```http
DELETE /v1/vms?confirm=true
```

Requires `confirm=true`. Cancels active image operations and Jeballtofile executions, then attempts to force-stop and
delete every VM. A 200 response reports per-VM deletion failures through `failed` and `errors`.

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

Optionally override resources, mark the clone as ephemeral, or give it its own lifetime:

```json
{
  "name": "cloned-vm",
  "resources": {"cpuCount": 8, "memorySize": "16GB"},
  "ephemeral": true,
  "lifetimeSeconds": 3600
}
```

After an ephemeral clone first reaches `running`, it auto-deletes when it later reaches `stopped` or `error`. It is
also stopped and deleted during agent shutdown. A clone that has never run is not deleted merely because its initial
state is `stopped`. `lifetimeSeconds` accepts 1-604800. Its persisted countdown starts on the clone's first
`running` transition; expiry stops the clone, and an ephemeral clone is then deleted.

### Update VM

```http
PATCH /v1/vms/{id}
```

Update name and/or resources for a VM. Name can be changed in any non-deleted state. Resource changes require the VM
to be stopped or created. Disk can only be enlarged. For a `created` VM, the requested disk size is saved for the
installer that will create `Disk.img`. For a `stopped`, installed VM, the existing `Disk.img` is resized before the
request succeeds. Expanding the guest filesystem remains the user's responsibility.

```bash
curl -X PATCH http://127.0.0.1:8011/v1/vms/$VM_ID \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "new-name", "resources": {"cpuCount": 8, "memorySize": "16GB"}}'
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | no | 1-100 characters. Unicode letters/numbers, hyphens, underscores, spaces, and dots. No leading or trailing whitespace. |
| `resources.cpuCount` | int | no | 1-32. Rejected if the host cannot support the requested count. |
| `resources.memorySize` | int or string | no | 2-128 GB (e.g., `"8GB"` or bytes) |
| `resources.diskSize` | int or string | no | 20 GB-8 TB, can only grow |

At least one field must be provided. Returns 409 if resource changes are requested and VM is not stopped or created.

**Response (200):** VM object with updated values.

## VM Lifecycle

### Start VM

```http
POST /v1/vms/{id}/start
```

Jeballto allows at most 2 capacity-consuming VMs concurrently. Active states, transitional states, and capacity
reservations count. This is a product policy, not an Apple Virtualization framework hardware limit. Returns
`VM_LIMIT_REACHED` (409) if exceeded.

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/start \
  -H "Authorization: Bearer $TOKEN"
```

### Stop VM

```http
POST /v1/vms/{id}/stop
```

Hard stop - save work inside the VM first. Idempotent when the VM is already stopped. Calling stop in `error`
performs recovery: a complete installed VM becomes `stopped`; an incomplete installation is cleaned and becomes
`created`, ready for a new install request.

### Pause VM

```http
POST /v1/vms/{id}/pause
```

Pauses VM execution in memory. This endpoint does not immediately create a durable saved-state file. During a graceful
agent shutdown, an active non-ephemeral paused runtime is saved to disk so it remains `paused` after restart and can be
resumed explicitly. A crash or forced termination before that save can lose the in-memory pause. Paused VMs count
toward the 2-VM limit.

### Resume VM

```http
POST /v1/vms/{id}/resume
```

Resumes an in-memory paused VM, or restores a durable saved state created during graceful shutdown.

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

The source may be an HTTPS URL, a `file://` URL, or an absolute local path. The input is limited to 8,192 UTF-8
bytes, and a normalized local or `file://` path is limited to 4,096 UTF-8 bytes. HTTP URLs, embedded URL credentials,
URL fragments, remote file URL hosts, and control characters are rejected.

### Get Installation Status

```http
GET /v1/vms/{id}/install/status
```

```bash
curl -fsS "http://127.0.0.1:8011/v1/vms/$VM_ID/install/status" \
  -H "Authorization: Bearer $TOKEN"
```

Repeat this request until `status` is `completed`.

```json
{
  "vmId": "550e8400-...",
  "status": "installing",
  "progress": 0.45,
  "message": "Downloading restore image"
}
```

Progress: `0.0` to `1.0` when known. Status values are `not_started`, `started`, `installing`, `finalizing`,
`completed`, `failed`, `cancelled`, and `interrupted`. The installation state is persisted. Cancellation cleans
partial artifacts and returns the VM to `created` when the Virtualization framework has released the files. After an
agent restart, an installation interrupted before finalization is marked `interrupted`, its partial artifacts are
cleaned, and it can be retried. A persisted `finalizing` installation is instead checked for a complete VM bundle. A
complete bundle recovers as `completed` with the VM `stopped`; an incomplete bundle recovers as `failed` with the VM
in `error`.

## Command Execution

```http
POST /v1/vms/{id}/execute
```

Runs a shell command via SSH. VM must be `running` with Remote Login enabled in the guest.

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
  "stderr": "",
  "stdoutTruncated": false,
  "stderrTruncated": false
}
```

**Request fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `command` | string | - | Shell command |
| `user` | string | `"admin"` | SSH username |
| `password` | string | `null` | SSH password, max 16,384 UTF-8 bytes. NUL and line breaks are rejected. Omit or set to `null` for key-based auth |
| `timeout` | int | `30` | Seconds (1-600) |

**Limits:**

| What | Limit |
|------|-------|
| Command length | 65,536 UTF-8 bytes |
| stdout/stderr capture | 5 MiB each. The corresponding `stdoutTruncated` or `stderrTruncated` response flag is `true` when data was omitted |
| SSH connect timeout | 5 seconds |
| Command timeout | 1-600 seconds |

## Keystroke Injection

```http
POST /v1/vms/{id}/keystrokes
```

Injects keystrokes via the Virtualization framework. Works in `running` or `installing` state - no SSH needed. Primary mechanism for automating the macOS Setup Assistant.

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

Plain text uses a US ASCII keyboard map. Unsupported characters are rejected with a descriptive 400 response instead of being replaced. Escape literal token delimiters and backslashes as `\<`, `\>`, and `\\`. Keys are paced at ~75 ms apart. Use `<waitNs>` explicitly between actions that need longer settling (e.g. menu animations, app launches).

A request accepts at most 1000 sequence strings, 10,000 characters in one string, and 10,000 characters across the
complete array. The parsed action count is also capped at 10,000.

## SSH

### Get SSH Info

```http
GET /v1/vms/{id}/ssh
```

Returns the host and port for direct SSH connections. Forwarding is set up automatically on start when
`networking.autoEnableSSHForwarding` is `true` (the default). Otherwise call `POST /v1/vms/{id}/ssh` first. When no
forwarding is configured, this endpoint returns 404 `SSH_NOT_CONFIGURED`.

```bash
curl http://127.0.0.1:8011/v1/vms/$VM_ID/ssh -H "Authorization: Bearer $TOKEN"
```

```json
{"host": "127.0.0.1", "port": 2222, "status": "ready"}
```

Default range: 2222-2223 (configurable in `networking.sshPortRangeStart/End`).
`status: "ready"` confirms that the host TCP proxy is listening. It does not confirm that Remote Login is enabled or
that the guest SSH daemon is accepting connections. The `SSH_READY` event reports a successful guest SSH banner
probe.

### Enable SSH Forwarding

```http
POST /v1/vms/{id}/ssh
```

Allocates a host port and starts TCP proxy to guest port 22. Idempotent - returns existing forwarding if already active. VM must be `running`.

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

Allocates a host port and starts the proxy. Idempotent. VM must be `running`.

```bash
curl -fsS -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/vnc \
  -H "Authorization: Bearer $TOKEN"
```

Copy the returned `port`, then open the built-in Screen Sharing client:

```bash
export VNC_PORT='paste-port-here'
open "vnc://localhost:$VNC_PORT"
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

Returns raw PNG bytes (`Content-Type: image/png`). Headless - no GUI window required. VM must be `running`.

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
{"state": "running", "uptime": 1200}
```

**All states:**

| State | Meaning |
|-------|---------|
| `created` | VM created, not yet installed or started |
| `installing` | macOS installation in progress |
| `stopped` | VM is stopped |
| `starting` | VM is booting |
| `running` | VM is running |
| `stopping` | VM is shutting down |
| `pausing` | VM execution is being paused |
| `paused` | VM execution is paused in memory or has a durable shutdown save ready for restore |
| `resuming` | VM is resuming from paused execution or a shutdown recovery save |
| `error` | Something went wrong (check events) |
| `deleted` | VM is marked for deletion |

See <doc:VMState> for state transition rules.

### Get Events

```http
GET /v1/vms/{id}/events?limit=100
```

The event bus retains the latest 1000 events globally. A VM query returns the matching subset from that global
history, up to the requested `limit`.
History remains queryable for a recently deleted VM as long as at least one of its events is still retained.
`INSTALL_PROGRESS` data includes `progress`, `phaseProgress`, `message`, `phase`, and available byte counters.
`INSTALL_FAILED` data includes the installation `error`. Event-level `vmId` and `data` are encoded as JSON `null`
when absent. Optional keys inside an event's `data` object are omitted when no value is available.

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
| VM lifecycle | `VM_CREATED`, `VM_STARTING`, `VM_RUNNING`, `VM_STOPPING`, `VM_STOPPED`, `VM_PAUSED`, `VM_RESUMED`, `VM_DELETED`, `VM_CLONED`, `VM_RESOURCES_UPDATED`, `STATE_CHANGED` |
| Installation | `INSTALL_STARTED`, `INSTALL_PROGRESS`, `INSTALL_COMPLETED`, `INSTALL_CANCELLED`, `INSTALL_FAILED` |
| GUI | `GUI_OPENED`, `GUI_CLOSED` |
| Network | `SSH_PORT_ASSIGNED`, `SSH_PORT_RELEASED`, `SSH_READY`, `VNC_PORT_ASSIGNED`, `VNC_PORT_RELEASED` |
| Jeballtofile | `JEBALLTOFILE_STARTED`, `JEBALLTOFILE_STEP_STARTED`, `JEBALLTOFILE_STEP_COMPLETED`, `JEBALLTOFILE_STEP_FAILED`, `JEBALLTOFILE_COMPLETED`, `JEBALLTOFILE_CANCELLED`, `JEBALLTOFILE_FAILED` |
| Errors | `ERROR_OCCURRED` |

## OCI Image Management

Packages VM bundles as OCI artifacts using `oras`. Compatible with Docker Hub, GitHub Container Registry, AWS ECR, Harbor, and other OCI-compatible registries.

### Pull Image

```http
POST /v1/images/pull
```

Downloads and stores locally. Digest references return an existing valid local record. Mutable tags are resolved on
every pull; if the registry digest changed, the old local record and owned bundle are replaced transactionally.
Jeballto images use format version 1 with an `arm64` architecture marker, source VM resources, and zstd-compressed
chunk layers. The stable media type family is:

- Artifact type: `application/vnd.jeballto.vm.bundle`
- Config: `application/vnd.jeballto.vm.bundle.config+json`
- Chunk layer: `application/vnd.jeballto.vm.bundle.chunk+zstd`

The formal name of this contract is **Jeballto VM Bundle Format v1**. The integer `formatVersion` in the config blob
selects the artifact contract independently of the Jeballto application version. The media types identify the format
family and do not select a version. Unversioned images created before 1.0.0 are not supported. Push the source VM
again with a current agent to publish a v1 artifact. A blocking pull returns `UNSUPPORTED_IMAGE_FORMAT` with HTTP 400
for an unversioned or unsupported version. Malformed v1 artifacts return `INVALID_IMAGE` with HTTP 400.

```bash
curl -X POST http://127.0.0.1:8011/v1/images/pull \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reference":"ghcr.io/myorg/vms/dev-env:latest"}'
```

Optional `timeout` field (seconds, max 604800) sets a caller-supplied deadline across the pull until durable commit.
When omitted, there is no deadline for the operation as a whole, but registry reachability checks and short ORAS
metadata commands, including digest resolution and manifest fetch, retain bounded internal deadlines. An internal
deadline can fail earlier, cancellation cleanup can finish after the requested duration, and a durable commit wins a
concurrent timeout. The endpoint always creates a pull operation. By default it blocks until the pull reaches a
terminal status and returns an operation status response with `image` populated on success.

To return immediately with operation status, set `async` to `true`:

```bash
curl -X POST http://127.0.0.1:8011/v1/images/pull \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reference":"ghcr.io/myorg/vms/dev-env:latest","async":true}'
```

Poll progress with:

```http
GET /v1/images/pull/operations/{operationId}
```

Cancel a running pull with:

```http
DELETE /v1/images/pull/operations/{operationId}
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
While the operation is nonterminal, `progress` is capped at `0.99` because decompression, disk writes, validation,
and the local index commit can remain after all compressed bytes complete. Only `completed` reports `1.0`.
`averageSpeedMBps` is the full artifact-flow speed for pull: completed compressed OCI artifact bytes divided by elapsed
pull operation time. It is not Activity Monitor network throughput, because it includes manifest work, cache waits,
decompression, disk writes, validation, and blob completion granularity.

During cancellation, status may be `cancelling` while cleanup is still running. The DELETE endpoint waits for cleanup
and child-process termination. It normally returns `cancelled`; if the operation durably committed before cancellation
took effect, completion wins and the returned terminal status is `completed`.

Operation status has two separate failure fields. `errorCode` is stable and machine-readable, while `error` is the
human-readable diagnostic. An asynchronous request has already returned HTTP 202, so a later format failure is
reported by the polled status endpoint with HTTP 200, `status: "failed"`, and `errorCode` set to
`UNSUPPORTED_IMAGE_FORMAT` or `INVALID_IMAGE`. Timeout failures use `IMAGE_PULL_TIMEOUT` or `IMAGE_PUSH_TIMEOUT`,
and registry reachability failures use `IMAGE_PULL_REGISTRY_UNAVAILABLE` or
`IMAGE_PUSH_REGISTRY_UNAVAILABLE`. Cancelled operations use `IMAGE_PULL_CANCELLED` or `IMAGE_PUSH_CANCELLED`.
Pushes also use `IMAGE_PUSH_COMMIT_OUTCOME_UNKNOWN` when manifest publication started but its registry outcome could
not be confirmed, and `IMAGE_PUSH_PARTIALLY_COMMITTED` when the registry commit was confirmed but the local index
could not be finalized. Both statuses expose the candidate or confirmed manifest `digest`. Inspect or pull the
reference and compare that digest to reconcile either result.
Clients should branch on `errorCode`, not parse `error` text.

### Push Image

```http
POST /v1/images/push
```

Pushes a VM bundle or existing local image. Use `source` with `vm:<uuid>` or `image:<uuid>`. Optional `timeout` field
is in seconds, max 604800, and sets a caller-supplied deadline for the complete push, starting before source
reservation and continuing through durable local index finalization. When omitted, there is no deadline for the
operation as a whole, but registry preflight and short ORAS metadata commands retain bounded internal deadlines. An
internal deadline can fail earlier and cancellation cleanup can finish after the requested duration. If the caller
deadline expires before manifest publication, the operation is cancelled and reports a timeout after cleanup. Once
registry manifest publication starts, an unknown outcome wins a concurrent timeout. Once the registry manifest is
confirmed committed, completion or a partial-commit result wins a concurrent timeout.

**Requirements:**

- When using `vm:<uuid>`, the VM must be `stopped` and its installed bundle must be complete. Returns 409
  `INVALID_STATE` if the VM is not stopped.
- A connectivity check against `<registry>/v2/` runs before compression. A blocking request returns 503
  `IMAGE_PUSH_FAILED` when that check fails. An asynchronous request has already returned 202, so the same failure is
  recorded in the operation status as `failed` with `errorCode: "IMAGE_PUSH_REGISTRY_UNAVAILABLE"` and an `error`
  message.

```bash
curl -X POST http://127.0.0.1:8011/v1/images/push \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "reference": "ghcr.io/myorg/vms/dev-env:latest",
    "source": "vm:550e8400-e29b-41d4-a716-446655440000"
  }'
```

The endpoint always creates a push operation. By default it blocks until the push reaches a terminal status and
returns an operation status response with `image` populated on success. The timeout starts before source reservation
and covers registry preflight, local packaging, upload, local-copy validation, manifest publication, and local index
finalization, subject to the commit-wins rules above.

Image IDs identify local records, not artifact digests. A successful same-reference push, re-push, pull repair, or tag
replacement may return a new `ImageResponse.id` even when the manifest digest did not change.

To return immediately with operation status, set `async` to `true`:

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
GET /v1/images/push/operations/{operationId}
```

Cancel a running push with:

```http
DELETE /v1/images/push/operations/{operationId}
```

Async push flow:

1. Resolve and reserve the source. A `vm:<uuid>` reservation prevents start, deletion, and resource mutation during
   export. An `image:<uuid>` reservation prevents deletion of the local source image.
2. Verify registry reachability before expensive packaging work starts.
3. `compressing`: scan the VM bundle, split files into chunks, compress nonzero chunks with zstd, and build the OCI
   package metadata.
4. `uploading`: confirm or upload each config and chunk blob with ORAS.
5. `finalizing`: create and validate a durable local bundle snapshot, including the declared ASIF disk capacity.
   The copy uses filesystem cloning when supported and falls back to a regular copy when cloning is unavailable or
   the source and destination are on different filesystems.
6. Write a complete staged image index, then publish the OCI manifest.
7. Atomically finalize the staged local index after confirmed manifest success.

Push has three sequential stages, so status includes `stage` and `stageProgress`. `compressing` counts
uncompressed VM bundle bytes and chunks processed locally. When the stage switches to `uploading`, `bytesCompleted`
and `chunksCompleted` reset and then count compressed OCI blobs confirmed or uploaded to the registry. Push `progress`
is an overall value where compression contributes the first half and upload contributes the second half. During
`finalizing`, the byte and chunk counters reset because the local snapshot has no byte-level progress source.
`stageProgress` is `0` while that snapshot is being created and `1` after it is ready. Overall progress remains `0.99`
while snapshot validation, manifest publication, and local index finalization finish. Only `completed` reports
`progress: 1.0`.

Selected fields while finalization is active can therefore look like this:

```json
{
  "status": "running",
  "stage": "finalizing",
  "progress": 0.99,
  "stageProgress": 0,
  "chunksCompleted": 0,
  "bytesCompleted": 0
}
```

`chunksTotal`, `bytesTotal`, and `averageSpeedMBps` are omitted during finalization.

Finalization has no fixed duration. A filesystem clone can finish quickly, while a regular copy, validation,
registry publication, and the durable index commit can take longer. Poll until the operation becomes terminal. A
successful terminal response has `status: "completed"` and `progress: 1.0`; when the last stage was finalization,
`stage` remains `"finalizing"` and `stageProgress` is `1.0`.

`averageSpeedMBps` is the per-stage artifact-flow speed for push: uncompressed local bundle throughput while
`compressing`, then compressed OCI artifact throughput while `uploading`. It is not raw system upload bandwidth,
because it includes blob existence checks, ORAS process overhead, registry latency, and only advances when blobs
complete. `finalizing` does not report a byte rate.

During cancellation, status may be `cancelling` while cleanup is still running. The DELETE endpoint waits for cleanup
and child-process termination. It normally returns `cancelled`. If manifest publication already started, the result can
instead be `IMAGE_PUSH_COMMIT_OUTCOME_UNKNOWN`. After confirmed registry commit, completion or
`IMAGE_PUSH_PARTIALLY_COMMITTED` wins the cancellation race.

### Image Operations

Pull and push operation listing, status, and cancellation are scoped under each image action.

```http
POST   /v1/images/pull
GET    /v1/images/pull/operations
GET    /v1/images/pull/operations?activeOnly=false
GET    /v1/images/pull/operations/{operationId}
DELETE /v1/images/pull/operations/{operationId}
DELETE /v1/images/pull/operations

POST   /v1/images/push
GET    /v1/images/push/operations
GET    /v1/images/push/operations?activeOnly=false
GET    /v1/images/push/operations/{operationId}
DELETE /v1/images/push/operations/{operationId}
DELETE /v1/images/push/operations
```

The list endpoints return active operations by default. Use `activeOnly=false` to include completed, failed, and
cancelled operations. At most 8 pull and push operations may be active in total. A new operation returns 429
`TOO_MANY_IMAGE_OPERATIONS` when that capacity is full. The service retains the newest 100 terminal operation
records for status lookup.

`DELETE /v1/images/{pull|push}/operations/{operationId}` cancels one running operation. The collection delete
endpoints cancel all active operations of that action type. Cancellation waits for the background task and any child
processes to stop before returning terminal operation status. In the collection response, `cancelled` counts accepted
cancellation requests. A returned operation can still be `completed` if its durable commit won the cancellation race.

### List, Get, Delete Images

```http
GET  /v1/images
GET  /v1/images/{id}
DELETE /v1/images/{id}
DELETE /v1/images?confirm=true
```

Deleting an individual image returns 409 while that image is the source of an active push operation.
Deleting all images requires `confirm=true`, cancels active image operations, and then attempts every deletion. A
200 response reports per-image failures through `failed` and `errors`.

Every validated image response includes `formatVersion: 1`. This is the artifact version stored by **Local Image
Index v1**. An incompatible local index is rejected instead of being partially loaded or rewritten.

### Image Reference Format

```
registry.example.com/repository/name:tag
registry.example.com/repository/name@sha256:abc123...
```

Specify the registry unless `images.defaultRegistry` is configured. With a default registry, unqualified references
such as `team/dev:latest` are expanded before use. Without it, unqualified references are rejected. A reference is
limited to 1,024 UTF-8 bytes; repository names are limited to 255 UTF-8 bytes and tags to 128 characters. Digests use
`sha256:` followed by 64 lowercase hexadecimal characters.

## Jeballtofiles

Jeballtofiles are YAML or JSON blueprints for automated VM creation and provisioning. See <doc:JeballtofileReference>
for the full file format and step reference.

### Execute Blueprint

```http
POST /v1/jeballtofiles
```

Accepts `application/json`, `application/yaml`, `application/x-yaml`, `text/yaml`, or `text/x-yaml`, with optional
media-type parameters. The request is validated before execution and may contain at most 1000 steps.
On success, Jeballto creates a VM, starts the step executor, and returns `202 Accepted` with:

```json
{
  "id": "execution-uuid",
  "vmId": "vm-uuid",
  "status": "running",
  "currentStep": 0,
  "totalSteps": 3,
  "message": "Jeballtofile execution started"
}
```

### Manage Executions

```http
GET /v1/jeballtofiles
GET /v1/jeballtofiles/{executionId}
POST /v1/jeballtofiles/{executionId}/cancel
DELETE /v1/jeballtofiles/{executionId}
```

Status responses include `id`, `vmId`, `status`, `currentStep`, `totalSteps`, and `stepResults`. The optional `error`
and per-step `message` fields are omitted when they have no value.
Cancellation is only accepted while an execution is `running`. Deletion is only accepted after an execution has
completed, failed, or been cancelled. All active executions and the newest 100 terminal executions remain available
in memory. Older terminal status records are removed automatically.

The cancel endpoint marks the execution and its current in-progress step as `cancelled` immediately, then requests
cooperative task cancellation. The response does not wait for asynchronous work to finish unwinding. Deleting the
cancelled execution waits until its task has fully exited.

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

The registry must be a lowercase hostname with an optional valid port. Usernames are limited to 1,024 UTF-8 bytes
and cannot contain control characters. Passwords are limited to 16,384 UTF-8 bytes and cannot contain NUL, CR, or
LF because they are passed to `oras` through its line-based standard-input interface. Login first checks the registry
endpoint, then validates the credentials with `oras`. Only a successful credential is stored in Jeballto's macOS
Keychain service. Every later ORAS command uses an isolated temporary registry configuration and credentials loaded
from that service, with the password passed through standard input. Docker and standalone ORAS login state are not
read or modified.

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

Logout deletes only the matching credential stored by Jeballto. It does not contact the registry and does not alter
Docker or standalone ORAS credentials.

### Insecure Registries

For local HTTP registries, add to `config.json`:

```json
{
  "images": {
    "insecureRegistries": ["localhost:5000"]
  }
}
```

This opts the named registry into plain HTTP. Credentials and image artifacts can be observed or modified in transit,
so use it only on a trusted network.

## Configuration

### Get Config

```http
GET /v1/config
```

Returns the current configured values. Persisted networking changes may still require an agent restart. Sensitive
values (token, file paths) are excluded.

### Update Config

```http
PATCH /v1/config
```

Partial update - include only fields to change. Logging and image fields persist to disk and apply immediately.
Networking fields are persisted and take effect after an agent restart. API bind settings are returned by
`GET /v1/config`, but they are not writable through this endpoint. The API token and file paths are intentionally
excluded from the config response.

The request must contain at least one effective writable field. Empty requests, empty sections, and payloads with
only unknown or read-only fields return `400 INVALID_REQUEST`. `timezone: null` and `defaultRegistry: null` are
effective updates that clear those values. `null` for any other writable field is ignored and does not count as an
effective update.

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
| `logging` | `retentionDays` | At least 1 day |
| `logging` | `maxTotalSize` | Positive whole number followed by MB or GB, interpreted as 1024-based units, for example `500MB` or `2GB`; at least 1 MB |
| `logging` | `timezone` | IANA identifier (e.g. `"UTC"`, `"America/New_York"`), or `null` for system timezone |
| `networking` | `sshPortRangeStart`, `sshPortRangeEnd` | 1024-65535, no overlap with API/VNC ports, restart required |
| `networking` | `autoEnableSSHForwarding` | bool, restart required |
| `networking` | `vncPortRangeStart`, `vncPortRangeEnd` | 1024-65535, no overlap with API/SSH ports, restart required |
| `images` | `defaultRegistry` | Lowercase registry hostname with an optional valid port, used to expand unqualified references; `null` requires explicit registries |
| `images` | `insecureRegistries` | Unique lowercase registry hostnames with optional valid ports that use plain HTTP; credentials and artifacts are unprotected in transit |
| `images` | `maxParallelImageBlobTransfers` | Concurrent ORAS blob fetch and push processes. Default 16, range 1-64 |
| `images` | `maxParallelImageCompressions` | Concurrent zstd compressions during image push. Default 4, range 1-32 |
| `images` | `maxParallelImageDecompressions` | Concurrent zstd decompressions during image pull. Default 2, range 1-8 |
| `images` | `maxParallelImageDiskWrites` | Concurrent output writes during image pull. Default 1, range 1-4 |

Image transfer operation data is kept within a process-owned session under
`~/Library/Caches/Jeballto/ImageWork/sessions/`. The agent and each launched `oras`, `zstd`, or bundle-copy child hold
a shared advisory lease on the session. A short-lived launch marker protects the gap before the child acquires its
lease, and the child keeps that lease across `exec`. Cleanup requires an exclusive lease, so an orphaned child keeps
its work directory protected after an unexpected agent exit. Startup removes only sessions proven inactive. While
holding the global single-instance lock, it may also remove lockless old work, but preserves active or unsafe lock
targets. A successful pull or push removes its operation cache immediately. Image wipe clears only the current
process's session contents and preserves its lock files.

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
      "lifecycle": "stable",
      "minimumOS": "26.0"
    }
  ]
}
```

The capability list describes platform and runtime surfaces such as macOS installation, NAT networking, port forwarding, command execution, GUI display, screenshots, keystrokes, Jeballtofile execution, and image packaging. `minimumOS` is the effective minimum macOS version, including Jeballto's supported host baseline. It does not list ordinary VM actions such as create, start, stop, or delete.

`status` describes whether the host can support the capability. `enabled` describes whether Jeballto currently allows routes that depend on it. `lifecycle` describes the product lifecycle: `development` features are disabled by default, `stable` features are enabled by default, and `deprecated` features are disabled with deprecation details.

## System Reset

```http
POST /v1/system/reset?confirm=true
```

Two modes. Both first cancel tracked installations, image operations, and Jeballtofile executions:

- **soft** - Attempts to delete all VMs and images and clear the IPSW cache. Config and logs are preserved. It returns
  200 with failure counts and messages even when part of the cleanup fails, and the agent keeps running.
- **hard** - First requires every VM and image deletion to succeed, then attempts to delete caches, the API token,
  all Jeballto registry credentials, config, and agent log files. It terminates only after every hard-reset step succeeds. A partial failure returns 500,
  reports what was removed, and leaves the process running so the user can correct the cause and retry.

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
  "willTerminate": false
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
| `errors` | string[] | Per-item failure messages; omitted when no errors occurred |

## Error Responses

All errors return:

```json
{
  "error": {
    "code": "ERROR_CODE",
    "message": "Human-readable description"
  }
}
```

**Common error codes:**

Routes may also return operation-specific codes documented in their response examples and in the OpenAPI spec.

| Code | HTTP | Meaning |
|------|------|---------|
| `UNAUTHORIZED` | 401 | Missing or invalid token |
| `NOT_FOUND` | 404 | VM not found |
| `IMAGE_NOT_FOUND` | 404 | Local image or image push source not found |
| `IMAGE_OPERATION_NOT_FOUND` | 404 | Image pull or push operation not found |
| `INVALID_REQUEST` | 400 | Malformed request body |
| `INVALID_ID` | 400 | Invalid UUID format |
| `INVALID_STATE` | 409 | Operation not valid in current VM state |
| `VM_LIMIT_REACHED` | 409 | Max 2 active or transitioning VMs |
| `CAPABILITY_UNAVAILABLE` | 409 | Required host or runtime capability is unavailable |
| `START_FAILED` | 500 | VM start failed |
| `STOP_FAILED` | 500 | VM stop failed |
| `PAUSE_FAILED` | 500 | VM pause failed |
| `RESUME_FAILED` | 500 | VM resume failed |
| `INSTALL_FAILED` | 500 | Installation request setup failed before a 202 response. Runtime failures are reported by the persisted install status. |
| `EXECUTE_FAILED` | 500 | Command/keystroke execution failed |
| `EXECUTE_TIMEOUT` | 504 | Command timed out |
| `PAYLOAD_TOO_LARGE` | 413 | Request body exceeds 1 MiB |
| `HEADERS_TOO_LARGE` | 431 | Request headers exceed 64 KiB |
| `TOO_MANY_REQUESTS` | 429 | Maximum concurrent request limit exceeded |
| `CONFIRMATION_REQUIRED` | 400 | Missing `?confirm=true` query parameter |
| `INVALID_REFERENCE` | 400 | OCI image reference is invalid |
| `UNSUPPORTED_IMAGE_FORMAT` | 400 | Image is unversioned or uses an unsupported Jeballto VM Bundle Format version |
| `INVALID_IMAGE` | 400 | Image declares a supported format version but its metadata or layers are malformed |
| `IMAGE_PULL_FAILED` | 500, 503, or 504 | Pull failed, the registry is unavailable, or the operation timed out |
| `IMAGE_PULL_CANCELLED` | 499 | Blocking pull was cancelled; asynchronous cancellation is reported in operation status |
| `IMAGE_PUSH_FAILED` | 500, 503, or 504 | Push failed, a blocking registry preflight found the registry unavailable, or the operation timed out |
| `IMAGE_PUSH_COMMIT_OUTCOME_UNKNOWN` | 500 | Manifest publication started but the registry outcome could not be confirmed; inspect or pull the reference to reconcile it |
| `IMAGE_PUSH_PARTIALLY_COMMITTED` | 500 | The registry manifest committed but the durable local record could not be finalized; pull the reference to repair local state |
| `IMAGE_PUSH_CANCELLED` | 499 | Blocking push was cancelled; asynchronous cancellation is reported in operation status |
