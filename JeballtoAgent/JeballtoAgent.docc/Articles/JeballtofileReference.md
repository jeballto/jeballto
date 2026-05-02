# Jeballtofile Reference

A Jeballtofile is a YAML or JSON blueprint for automated VM creation and provisioning.

## Overview

A Jeballtofile defines a VM's name, resources, macOS source, and an ordered sequence of steps that execute automatically - from OS installation through software provisioning. Submit one API call, get a fully configured VM.

## Schema

```yaml
name: my-dev-vm
source: https://updates.cdn-apple.com/.../RestoreImage.ipsw
resources:
  cpuCount: 4
  memorySize: 8GB
  diskSize: 64GB

steps:
  - type: install
  - type: start
  - type: gui-open
  - type: keystrokes
    keystrokes:
      - "<wait30s>"
      - "English<enter>"
  - type: gui-close
  - type: wait
    seconds: 60
  - type: execute
    command: brew install git
    timeout: 300
  - type: stop
```

### Top-level fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | VM name. 1-100 characters, alphanumeric with hyphens, underscores, spaces, dots. |
| `source` | string | No | IPSW source. Required if steps include `install`. Accepts HTTPS URL, `file://` URL, or absolute path. Omit to download the latest macOS. |
| `resources` | object | No | Hardware resources. Defaults: 4 CPUs, 4 GB memory, 64 GB disk. |
| `steps` | array | Yes | Ordered list of steps to execute. Must contain at least one step. |

### Resources

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `cpuCount` | integer | 4 | Number of virtual CPUs (1-32) |
| `memorySize` | integer or string | `"4GB"` | RAM size. Accepts bytes or human-readable strings: `"8GB"`, `"512MB"`, `"1TB"` |
| `diskSize` | integer or string | `"64GB"` | Disk size. Same format as `memorySize`. |

## Step Types

### `install`

Installs macOS from the top-level `source`. The VM must be in `created` state. After installation completes, the VM transitions to `stopped`.

```yaml
- type: install
```

No additional fields. The IPSW source comes from the top-level `source` field.

### `start`

Starts the VM. Transitions from `stopped` to `running`.

```yaml
- type: start
```

### `stop`

Stops the VM. Transitions from `running` to `stopped`.

```yaml
- type: stop
```

### `gui-open`

Opens a native macOS window showing the VM's display. The VM must be `running`. Useful for monitoring setup or allowing manual interaction.

```yaml
- type: gui-open
```

### `gui-close`

Closes the GUI window. Does not stop the VM.

```yaml
- type: gui-close
```

### `keystrokes`

Sends keystroke sequences to the VM's display. Works when the VM is `running`. Primary mechanism for automating the macOS Setup Assistant.

```yaml
- type: keystrokes
  keystrokes:
    - "<wait5s>"
    - "admin<tab>admin<enter>"
    - "<leftCmdOn>a<leftCmdOff>"
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `keystrokes` | string[] | Yes | Array of keystroke DSL strings. Max 1000 sequences, max 10000 chars each. |

#### Keystroke DSL

| Token | Description |
|-------|-------------|
| Plain text | Types each character individually (uppercase handled automatically) |
| `<enter>`, `<tab>`, `<space>`, `<delete>`, `<esc>` | Common keys |
| `<left>`, `<right>`, `<up>`, `<down>` | Arrow keys |
| `<home>`, `<end>`, `<pageup>`, `<pagedown>` | Navigation keys |
| `<f1>` through `<f12>` | Function keys |
| `<leftCmdOn>` / `<leftCmdOff>` | Hold/release left Command |
| `<leftShiftOn>` / `<leftShiftOff>` | Hold/release left Shift |
| `<leftCtrlOn>` / `<leftCtrlOff>` | Hold/release left Control |
| `<leftAltOn>` / `<leftAltOff>` | Hold/release left Option |
| `<wait1s>`, `<wait5s>`, `<waitNs>` | Pause (max 300 seconds per wait) |

Right-side modifier variants are also available (e.g., `<rightCmdOn>`).

### `execute`

Runs a shell command inside the VM via SSH. The VM must be `running` with SSH enabled.

```yaml
- type: execute
  command: softwareupdate --install-rosetta --agree-to-license
  user: admin
  password: admin
  timeout: 120
```

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `command` | string | Yes | - | Shell command to run |
| `user` | string | No | `"admin"` | SSH username |
| `password` | string | No | `"admin"` | SSH password |
| `timeout` | integer | No | 30 | Timeout in seconds (max 600) |

A non-zero exit code fails the step and halts execution. Wrap with `|| true` to ignore failures.

### `wait`

Pauses execution for a fixed number of seconds.

```yaml
- type: wait
  seconds: 60
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `seconds` | integer | Yes | Wait duration (1-300 seconds) |

## Formats

Jeballtofiles are written in YAML by default. JSON is also accepted. Set the `Content-Type` header:

| Content-Type | Format |
|-------------|--------|
| `application/yaml` or `text/yaml` | YAML |
| `application/json` (or omitted) | JSON |

## API Endpoints

### Execute a Jeballtofile

```
POST /v1/jeballtofiles
```

Validates the entire blueprint upfront. If valid, creates the VM and begins asynchronous step execution. Returns **202 Accepted** immediately.

**Response (202):**

```json
{
  "id": "execution-uuid",
  "vmId": "created-vm-uuid",
  "status": "running",
  "currentStep": 0,
  "totalSteps": 6,
  "message": "Jeballtofile execution started"
}
```

### Get execution status

```
GET /v1/jeballtofiles/{executionId}
```

**Response (200):**

```json
{
  "id": "execution-uuid",
  "vmId": "vm-uuid",
  "status": "running",
  "currentStep": 3,
  "totalSteps": 6,
  "stepResults": [
    { "step": 0, "type": "install", "status": "completed", "message": "macOS installation completed" },
    { "step": 1, "type": "start", "status": "completed", "message": "VM started" },
    { "step": 2, "type": "wait", "status": "completed", "message": "Waited 60 seconds" },
    { "step": 3, "type": "execute", "status": "in_progress", "message": null }
  ],
  "error": null
}
```

Status values: `running`, `completed`, `failed`, `cancelled`.

### Other endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/v1/jeballtofiles` | List all executions |
| `POST` | `/v1/jeballtofiles/{id}/cancel` | Request cancellation |
| `DELETE` | `/v1/jeballtofiles/{id}` | Delete a finished execution |

Cancel is cooperative: async steps observe task cancellation, mark the current step as `cancelled`, and halt
execution with status `cancelled`.

## Error Handling

- **Validation errors** - returned as 400 responses before any execution begins. The entire blueprint is validated upfront.
- **Runtime errors** - halt execution immediately. Status becomes `failed` with a descriptive error message. The VM is left in its current state for inspection.
- **Cancellation** - halts execution with status `cancelled`. The current step is recorded as `cancelled`, not `failed`.
- **Non-zero exit codes** on `execute` steps are treated as failures. Wrap commands with `|| true` to ignore.

## Events

Jeballtofile execution publishes events visible via `GET /v1/vms/{vmId}/events`:

| Event Type | Data |
|------------|------|
| `JEBALLTOFILE_STARTED` | `executionId`, `vmId` |
| `JEBALLTOFILE_STEP_STARTED` | `executionId`, `step`, `stepType` |
| `JEBALLTOFILE_STEP_COMPLETED` | `executionId`, `step`, `stepType` |
| `JEBALLTOFILE_STEP_FAILED` | `executionId`, `step`, `stepType`, `error` |
| `JEBALLTOFILE_COMPLETED` | `executionId`, `vmId` |
| `JEBALLTOFILE_CANCELLED` | `executionId`, `vmId`, `step` |
| `JEBALLTOFILE_FAILED` | `executionId`, `vmId`, `step`, `error` |

## Usage Examples

```bash
# Submit a YAML blueprint
curl -X POST http://localhost:8011/v1/jeballtofiles \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/yaml" \
  --data-binary @examples/Jeballtofile/your-blueprint.Jeballtofile.yaml

# Poll status
curl http://localhost:8011/v1/jeballtofiles/$EXEC_ID \
  -H "Authorization: Bearer $TOKEN"

# Cancel a running execution
curl -X POST http://localhost:8011/v1/jeballtofiles/$EXEC_ID/cancel \
  -H "Authorization: Bearer $TOKEN"
```
