# Troubleshooting

Common problems and how to fix them.

## Agent Won't Start

**"Jeballto VM Agent requires Apple Silicon (arm64)"**

Jeballto only runs on M1/M2/M3/M4 Macs. No Intel support.

**"Failed to create listener" (port conflict)**

```bash
# Find what's using port 8011
lsof -i :8011

# Kill it, or change port in config.json:
# "api": { "port": 9090, ... }
```

**Permission denied**

Ensure the app has virtualization entitlement and Full Disk Access if running from a non-standard location.

**Local network permission denied (PolicyDenied)**

If you see `PolicyDenied` errors in the logs, the app was denied local network access. SSH and VNC forwarding to VMs will not work without it.

Fix: System Settings > Privacy & Security > Local Network > enable JeballtoAgent, then restart the agent.

On first launch, the app prompts for this permission automatically. If the prompt was dismissed or denied, re-enable it manually from System Settings.

## VM Won't Start

**"No hardware model file found"**

The VM hasn't been installed yet. Install macOS first:

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/install \
  -H "Authorization: Bearer $TOKEN"
```

**VM_LIMIT_REACHED (409)**

Max 2 VMs can run at once. Stop one first:

```bash
# See which VMs are running
curl http://127.0.0.1:8011/v1/vms -H "Authorization: Bearer $TOKEN"

# Stop one
curl -X POST http://127.0.0.1:8011/v1/vms/$OTHER_VM_ID/stop \
  -H "Authorization: Bearer $TOKEN"
```

**Corrupted VM files**

Delete and recreate:

```bash
curl -X DELETE http://127.0.0.1:8011/v1/vms/$VM_ID -H "Authorization: Bearer $TOKEN"
```

## Installation Fails

**Remote IPSW download fails**

Verify the URL works:

```bash
curl -I https://example.com/macos.ipsw
```

Or use auto-download from Apple instead:

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/install \
  -H "Authorization: Bearer $TOKEN"
```

**Insufficient disk space**

Installation needs ~100 GB free (download + disk image). Check with `df -h`.

**Network timeout during auto-download**

Download the IPSW manually and use the local file path option.

**Reclaiming disk space used by IPSW downloads**

IPSWs are cached at `~/Library/Caches/Jeballto/IPSWCache/` (typically 12-18 GB each) and reused across installs. Clear with `POST /v1/system/reset`, or remove the directory manually while the agent is stopped.

## Command Execution Fails

**"SSH not configured"**

The VM's SSH port isn't assigned yet. Check the VM state and SSH info:

```bash
curl http://127.0.0.1:8011/v1/vms/$VM_ID/state -H "Authorization: Bearer $TOKEN"
curl http://127.0.0.1:8011/v1/vms/$VM_ID/ssh -H "Authorization: Bearer $TOKEN"
```

**Command timeout (504)**

The command took longer than the timeout (default 30s). Increase it:

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/execute \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"long-running-script.sh","timeout":300}'
```

Max timeout: 600 seconds.

**"Connection refused" or SSH errors**

1. VM must be in `RUNNING` state
2. Remote Login must be enabled in the guest: System Settings - General - Sharing - Remote Login
3. The default credentials are `admin`/`admin`. If you changed them, pass the credentials explicitly:

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/execute \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"whoami","user":"myuser","password":"mypassword"}'
```

**Keystroke injection not working**

- For `RUNNING` VMs: keystrokes go through `VZVirtualMachineView` (a hidden view is created if no GUI window is open)
- For `INSTALLING` VMs: keystrokes also work (useful for setup wizard automation)
- If nothing happens: try opening the GUI window first

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/gui -H "Authorization: Bearer $TOKEN"
```

## Image/OCI Issues

**"oras binary not found"**

The `oras` CLI is required for image operations. Either bundle it in the app's Resources directory, or set the path in config.json:

```json
{
  "images": {
    "orasPath": "/usr/local/bin/oras"
  }
}
```

Install oras: `brew install oras`.

**Image pull fails (authentication)**

Login to the registry first:

```bash
curl -X POST http://127.0.0.1:8011/v1/registries/login \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"registry":"ghcr.io","username":"myuser","password":"ghp_mytoken"}'
```

**Image pull fails (insecure registry)**

For local HTTP registries, add them to config.json:

```json
{
  "images": {
    "insecureRegistries": ["localhost:5000", "registry.local:5000"]
  }
}
```

**"Invalid image reference"**

References must include a registry. Format: `registry/repo:tag`

```
OK: ghcr.io/myorg/vm:latest
OK: localhost:5000/vms/dev:v1
NOT OK: myorg/vm:latest          (missing registry)
NOT OK: vm:latest                (missing registry and repo)
```

## SSH Connection Issues

**Connection refused**

1. Enable Remote Login in guest: System Settings - General - Sharing - Remote Login
2. Verify port forwarding: `curl http://127.0.0.1:8011/v1/vms/$VM_ID/ssh -H "Authorization: Bearer $TOKEN"`
3. Connect to the returned port: `ssh -p $PORT admin@127.0.0.1`

**Wrong port**

Each VM gets its own SSH port (from range 2222-2223). Always check the API:

```bash
curl http://127.0.0.1:8011/v1/vms/$VM_ID/ssh -H "Authorization: Bearer $TOKEN"
```

## API Authentication

**401 Unauthorized on every request**

Get the token from config:

```bash
cat ~/Library/Application\ Support/Jeballto/config.json | grep token
```

**404 Not Found**

Check the VM ID - list all VMs:

```bash
curl http://127.0.0.1:8011/v1/vms -H "Authorization: Bearer $TOKEN"
```

## State Issues

**VM stuck in STARTING/STOPPING/PAUSING/RESUMING**

Lifecycle failures now automatically transition to ERROR state. If a VM is still stuck in a transitional state (e.g. after a crash), restart the agent. On startup, transitional states are reset to STOPPED:

```bash
killall JeballtoAgent
open -a JeballtoAgent
```

**VM in ERROR state**

Check events for the error message:

```bash
curl "http://127.0.0.1:8011/v1/vms/$VM_ID/events?limit=10" \
  -H "Authorization: Bearer $TOKEN"
```

From ERROR you can stop (reach STOPPED) or delete:

```bash
curl -X DELETE http://127.0.0.1:8011/v1/vms/$VM_ID -H "Authorization: Bearer $TOKEN"
```

## Debug Mode

Enable in config.json:

```json
{
  "logging": {
    "level": "debug"
  }
}
```

Restart agent. Logs are written to `~/Library/Logs/Jeballto/agent-YYYY-MM-DD.log`.

Debug logging shows: all API requests, state transitions, event publishing, oras commands, SSH process details.

## Reset Everything

Use hard reset to wipe VMs, images, config, caches, and logs. The agent exits after the response.

```bash
curl -X POST "http://127.0.0.1:8011/v1/system/reset?confirm=true" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"mode":"hard"}'

open -a JeballtoAgent
```

## Log Errors Reference

| Log message | Meaning |
|-------------|---------|
| "Failed to transition to [state]" | Invalid state transition - check VM's current state |
| "Invalid configuration" | VZ config validation failed - check CPU/memory values |
| "Auxiliary storage creation failed" | Disk I/O error - check disk space and permissions |
| "oras command failed (exit N)" | oras CLI error - check registry auth and reference format |
| "Command timed out after Ns" | SSH command exceeded timeout - increase timeout or check guest |
| "Failed to create synthetic keyboard event" | Keystroke injection failed - try opening GUI window |
| "No virtual machine available" | VM not initialized - start the VM first |
| "Image not found" | Image ID doesn't exist locally - list images to check |
| "PolicyDenied(-65570)" | Local network access denied - enable in System Settings > Privacy & Security > Local Network |
