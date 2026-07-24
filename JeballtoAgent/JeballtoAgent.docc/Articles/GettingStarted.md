# Getting Started

Install JeballtoAgent, verify its API, and create your first VM.

## Requirements

- Apple Silicon Mac
- macOS 26.0 or later

## Install and Launch

1. Download the latest release from [GitHub Releases](https://github.com/jeballto/jeballto/releases/latest).
2. Move `JeballtoAgent.app` to `/Applications`.
3. Open JeballtoAgent.
4. Allow Local Network access when macOS asks. SSH and VNC forwarding require it.

JeballtoAgent runs from the menu bar. Choose **Copy API Token**, then set these shell variables:

```bash
export JEBALLTO_API='http://127.0.0.1:8011'
export JEBALLTO_TOKEN='paste-token-here'
```

Verify that the agent is ready:

```bash
curl -fsS "$JEBALLTO_API/v1/health"
```

The health endpoint is the only endpoint that does not require authentication.

## Create a VM

```bash
curl -fsS -X POST "$JEBALLTO_API/v1/vms" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"dev","resources":{"cpuCount":4,"memorySize":"8GB","diskSize":"64GB"}}'
```

Copy the `id` from the response:

```bash
export VM_ID='paste-vm-id-here'
```

## Install macOS

Start an installation using the latest compatible restore image from Apple:

```bash
curl -fsS -X POST "$JEBALLTO_API/v1/vms/$VM_ID/install" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN"
```

Installation runs asynchronously. Check its status:

```bash
curl -fsS "$JEBALLTO_API/v1/vms/$VM_ID/install/status" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN"
```

Repeat the status request until `status` is `completed`. Do not start the VM while installation is still active.
If the status becomes `failed`, `cancelled`, or `interrupted`, inspect `message` and see <doc:Troubleshooting>.

To install a specific IPSW instead, pass an HTTPS URL, a `file://` URL, or an absolute local path:

```bash
curl -fsS -X POST "$JEBALLTO_API/v1/vms/$VM_ID/install" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"source":"/Users/me/Downloads/macOS.ipsw"}'
```

## Start and Open the VM

```bash
curl -fsS -X POST "$JEBALLTO_API/v1/vms/$VM_ID/start" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN"

curl -fsS -X POST "$JEBALLTO_API/v1/vms/$VM_ID/gui" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN"
```

Closing the native VM window does not stop the VM.

## Optional SSH Access

Enable Remote Login inside the guest first. Then enable or inspect host forwarding with this idempotent request:

```bash
curl -fsS -X POST "$JEBALLTO_API/v1/vms/$VM_ID/ssh" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN"
```

Copy the returned `port`, then connect with the guest username:

```bash
export SSH_PORT='paste-port-here'
ssh -p "$SSH_PORT" admin@127.0.0.1
```

`status: "ready"` means the host proxy is listening. It does not prove that Remote Login is enabled in the guest.

## Stop or Delete the VM

```bash
curl -fsS -X POST "$JEBALLTO_API/v1/vms/$VM_ID/stop" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN"

curl -fsS -X DELETE "$JEBALLTO_API/v1/vms/$VM_ID" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN"
```

Deleting a VM removes its bundle and cannot be undone.

## Next Steps

- <doc:APIReference> - Complete REST API, OCI images, VNC, screenshots, commands, and keystrokes
- <doc:JeballtofileReference> - Automated VM provisioning with JSON or YAML blueprints
- <doc:OperatingTheAgent> - Status menu, caches, permissions, updates, and shutdown behavior
- <doc:Troubleshooting> - Common errors and recovery
- <doc:DevelopmentGuide> - Build, test, storage, and architecture details
