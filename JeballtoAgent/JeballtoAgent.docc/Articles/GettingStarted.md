# Getting Started

Build, run, and make your first API call in under five minutes.

## Prerequisites

- Apple Silicon Mac (M1/M2/M3/M4)
- macOS 26.0+
- Xcode 26+ (for building)

## Build and Run

```bash
git clone https://github.com/yourusername/jeballto.git
cd jeballto
xcodebuild -scheme JeballtoAgent -configuration Release
./build/Release/JeballtoAgent
```

On first launch, macOS asks for **Local Network** access. Click **Allow** - it is required for SSH and VNC port forwarding. If you miss the prompt, enable it later in System Settings > Privacy & Security > Local Network.

First run also writes `~/Library/Application Support/Jeballto/config.json` with your auth token.

```bash
# Grab the auth token (required for every API call)
export TOKEN=$(cat ~/Library/Application\ Support/Jeballto/config.json | grep token | cut -d'"' -f4)
```

## Create and Install a VM

```bash
# Create VM (4 CPU, 8GB RAM, 64GB disk)
VM_ID=$(curl -s -X POST http://127.0.0.1:8011/v1/vms \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"dev","resources":{"cpuCount":4,"memorySize":"8GB","diskSize":"64GB"}}' \
  | grep -o '"id":"[^"]*' | cut -d'"' -f4)

echo "VM ID: $VM_ID"
```

### Install macOS

Pick one of three methods:

**Auto-download latest from Apple (recommended):**

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/install \
  -H "Authorization: Bearer $TOKEN"
```

**From a URL:**

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/install \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"source":"https://example.com/macos.ipsw"}'
```

**From a local file:**

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/install \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"source":"/Users/me/Downloads/macOS.ipsw"}'
```

**Monitor progress (0.0 to 1.0):**

```bash
watch -n 2 "curl -s http://127.0.0.1:8011/v1/vms/$VM_ID/install/status \
  -H 'Authorization: Bearer $TOKEN'"
```

## Start and Access

```bash
# Start VM
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/start \
  -H "Authorization: Bearer $TOKEN"

# Get SSH port (each VM gets a unique port)
SSH_PORT=$(curl -s http://127.0.0.1:8011/v1/vms/$VM_ID/ssh \
  -H "Authorization: Bearer $TOKEN" | grep -o '"port":[0-9]*' | cut -d':' -f2)

# Connect via SSH (enable Remote Login in guest first: System Settings > Sharing)
ssh -p $SSH_PORT admin@127.0.0.1
```

## Run Commands Inside the VM

```bash
# Run a command via SSH (default: user=admin, password=admin)
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/execute \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"uname -a"}'

# Run with a longer timeout (default 30s, max 600s)
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/execute \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"brew install git","timeout":120}'
```

### Keystroke Injection

For when SSH is not available - like automating the macOS Setup Assistant or interacting with GUI apps:

```bash
# Type username, tab to password field, type password, press Enter
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/keystrokes \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"keystrokes":["admin<tab>secretpassword<enter>"]}'

# Open Spotlight, type "terminal", open it
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/keystrokes \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"keystrokes":["<leftCmdOn><space><leftCmdOff><wait2s>terminal<wait1s><enter>"]}'
```

Special tokens: `<enter>`, `<tab>`, `<space>`, `<delete>`, `<esc>`, `<left>`, `<right>`, `<up>`, `<down>`, `<f1>`-`<f12>`, `<home>`, `<end>`, modifiers with `<leftCmdOn/Off>`, `<leftShiftOn/Off>`, `<leftCtrlOn/Off>`, `<leftAltOn/Off>`, and waits with `<wait5s>`, `<waitNs>`.

Keys are sent ~75 ms apart. Add `<waitNs>` between actions that trigger animations or app launches.

## GUI Window

```bash
# Open GUI window (idempotent - brings to front if already open)
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/gui \
  -H "Authorization: Bearer $TOKEN"

# Close GUI window
curl -X DELETE http://127.0.0.1:8011/v1/vms/$VM_ID/gui \
  -H "Authorization: Bearer $TOKEN"
```

## Clone a VM

Create a copy of an existing VM (new UUID, MAC address, machine ID):

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/clone \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"dev-clone"}'
```

The source VM must be stopped (or use `?force=true`). The clone starts in `STOPPED` state.

## VNC - Remote Desktop

```bash
# Enable VNC forwarding
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/vnc \
  -H "Authorization: Bearer $TOKEN"
# -> {"host":"127.0.0.1","port":5901,"status":"ready"}

# Connect with macOS built-in VNC client
open vnc://localhost:5901

# Check VNC status
curl http://127.0.0.1:8011/v1/vms/$VM_ID/vnc \
  -H "Authorization: Bearer $TOKEN"

# Disable VNC forwarding (releases the port)
curl -X DELETE http://127.0.0.1:8011/v1/vms/$VM_ID/vnc \
  -H "Authorization: Bearer $TOKEN"
```

## OCI Images - Share VMs Across Machines

```bash
# Login to registry
curl -X POST http://127.0.0.1:8011/v1/registries/login \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"registry":"ghcr.io","username":"myuser","password":"ghp_mytoken"}'

# Push VM to registry
curl -X POST http://127.0.0.1:8011/v1/images/push \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reference":"ghcr.io/myorg/vms/dev:v1","sourceVmId":"'$VM_ID'"}'

# Pull on another machine
curl -X POST http://127.0.0.1:8011/v1/images/pull \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"reference":"ghcr.io/myorg/vms/dev:v1"}'

# Create VM from pulled image (no install needed)
curl -X POST http://127.0.0.1:8011/v1/vms \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"from-image","image":"ghcr.io/myorg/vms/dev:v1"}'
```

## Common Operations

```bash
# List all VMs
curl http://127.0.0.1:8011/v1/vms -H "Authorization: Bearer $TOKEN"

# Check VM state
curl http://127.0.0.1:8011/v1/vms/$VM_ID/state -H "Authorization: Bearer $TOKEN"

# Pause VM (saves state, can resume later)
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/pause -H "Authorization: Bearer $TOKEN"

# Resume paused VM
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/resume -H "Authorization: Bearer $TOKEN"

# Stop VM
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/stop -H "Authorization: Bearer $TOKEN"

# Delete VM and all its files
curl -X DELETE http://127.0.0.1:8011/v1/vms/$VM_ID -H "Authorization: Bearer $TOKEN"
```

## Next Steps

- <doc:APIReference> - Complete REST API reference
- <doc:Architecture> - How components interact
- <doc:JeballtofileReference> - Automate VM provisioning with blueprints
- <doc:OperatingTheAgent> - Status bar, auto-updates, login item, permissions
- <doc:DevelopmentGuide> - Building and extending the agent
- <doc:Troubleshooting> - Common issues and fixes
