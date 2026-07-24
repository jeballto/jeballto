# Troubleshooting

Common problems and how to fix them.

## Agent Won't Start

**"Jeballto VM Agent requires Apple Silicon (arm64)"**

Jeballto runs on Apple Silicon Macs. Intel Macs are not supported.

**"Failed to create listener" (port conflict)**

```bash
# Find what's using port 8011
lsof -i :8011

# Kill it, or change port in config.json:
# "api": { "port": 9090, ... }
```

**Permission denied**

Use an app signed with the virtualization entitlement. The default application support, cache, and log directories
do not require Full Disk Access. If you configured storage inside a protected location, choose a writable directory
or grant only the access that location requires.

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

At most 2 VMs can consume capacity at once. Installing, transitional, running, paused, and in-flight reserved VMs
count. Stop one first or wait for its active lifecycle operation to finish:

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

Allow space for the configured VM disk, the downloaded IPSW, and installation working data. About 100 GB free is a
reasonable starting point for the default 64 GB VM disk. Check with `df -h`.

**Network timeout during auto-download**

Download the IPSW manually and use the local file path option.

**Reclaiming disk space used by downloads**

IPSWs are cached at `~/Library/Caches/Jeballto/IPSWCache/` and reused across installs. The cache can consume
substantial space when it contains several restore images. To remove only this cache, stop the agent and delete that
directory. A soft `POST /v1/system/reset?confirm=true` also clears it, but that endpoint is destructive: it attempts
to delete every VM and local image too.

## Command Execution Fails

**"SSH not configured"**

The VM's SSH port isn't assigned yet. Check the VM state and SSH info:

```bash
curl http://127.0.0.1:8011/v1/vms/$VM_ID/state -H "Authorization: Bearer $TOKEN"
curl http://127.0.0.1:8011/v1/vms/$VM_ID/ssh -H "Authorization: Bearer $TOKEN"
```

When automatic forwarding is disabled, enable it after the VM reaches `running`:

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/ssh -H "Authorization: Bearer $TOKEN"
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

1. VM must be in `running` state
2. Remote Login must be enabled in the guest: System Settings - General - Sharing - Remote Login
3. The API defaults the username to `admin` but does not assume a password. Configure key authentication in the guest or pass its actual credentials explicitly:

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/execute \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"command":"whoami","user":"myuser","password":"mypassword"}'
```

**Keystroke injection not working**

- For `running` VMs: keystrokes go through `VZVirtualMachineView` (a hidden view is created if no GUI window is open)
- For `installing` VMs: keystrokes also work (useful for setup wizard automation)
- If nothing happens: try opening the GUI window first

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/gui -H "Authorization: Bearer $TOKEN"
```

## Image/OCI Issues

**"oras binary not found"**

The `oras` and `zstd` CLIs are required for image operations. Either bundle them in the app's Resources directory, or set paths in config.json:

```json
{
  "images": {
    "orasPath": "/usr/local/bin/oras",
    "zstdPath": "/usr/local/bin/zstd"
  }
}
```

Install both tools if needed, then set `orasPath` and `zstdPath` to their actual executable paths. A Homebrew install
is not discovered automatically unless its path is configured. Released app bundles normally contain both tools.

**Image pull fails (authentication)**

Login to the registry first:

```bash
curl -X POST http://127.0.0.1:8011/v1/registries/login \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"registry":"ghcr.io","username":"myuser","password":"ghp_mytoken"}'
```

Jeballto stores successful registry logins in its own macOS Keychain service. Docker and standalone ORAS login state
is intentionally ignored. If a credential was added with another tool, repeat the login through this API.

**Image push remains at 0.99**

Poll the operation's `statusUrl`. When it reports `status: "running"`, `stage: "finalizing"`, and `progress: 0.99`,
compression and blob upload are complete, but the push is still creating and validating its durable local snapshot,
publishing the OCI manifest, or committing the local image index. This stage has no fixed duration. Filesystem cloning
can finish quickly, while an unsupported clone or cross-filesystem destination falls back to a correct regular copy.

The byte and chunk counters reset during finalization, and byte totals and speed are omitted because the stage has no
reliable byte-level progress source. Keep polling until a terminal status appears. Success is exactly
`status: "completed"` with `progress: 1.0`. If the operation fails, use `errorCode` for recovery and `error` for the
human-readable diagnostic.

**Image pull fails (insecure registry)**

For local HTTP registries, add them to config.json:

```json
{
  "images": {
    "insecureRegistries": ["localhost:5000", "registry.local:5000"]
  }
}
```

Only do this on a trusted network. Plain HTTP exposes registry credentials and VM image artifacts in transit.

**`UNSUPPORTED_IMAGE_FORMAT` when pulling an older image**

Jeballto 1.0 requires **Jeballto VM Bundle Format v1**. Images pushed by pre-1.0 builds without a `formatVersion`
field are legacy unversioned artifacts and are not accepted. Start from the original VM and push it again with a
current agent, preferably under a new tag. A blocking pull reports HTTP 400 with `UNSUPPORTED_IMAGE_FORMAT` instead
of downloading the chunk layers. `POST /v1/vms` returns the same error when its `image` field triggers an implicit
pull.

An asynchronous pull initially returns HTTP 202. Poll its `statusUrl` and inspect `errorCode`: an unsupported format
finishes with `status: "failed"` and `errorCode: "UNSUPPORTED_IMAGE_FORMAT"`. The status lookup itself returns HTTP
200 because the lookup succeeded. Use `errorCode` for program logic and `error` only as a human-readable diagnostic.

`INVALID_IMAGE` means the artifact claims to be v1 but violates the v1 schema, chunk integrity, required bundle-file,
or ASIF disk contract. Rebuild and push the image again rather than retrying the same digest.

Pre-1.0 local image indexes without `formatVersion` and explicit managed-bundle ownership are rejected. Stop the
agent, remove the incompatible `images.json` and `images.json.bak` files plus their managed UUID-named image bundles,
then pull the images again or push them from the original VMs. There is no pre-1.0 local index migration.

**`IMAGE_PUSH_COMMIT_OUTCOME_UNKNOWN` or `IMAGE_PUSH_PARTIALLY_COMMITTED`**

These codes describe the OCI manifest commit boundary. `IMAGE_PUSH_COMMIT_OUTCOME_UNKNOWN` means manifest
publication started, but interruption or invalid tool output prevented Jeballto from confirming whether the registry
accepted it. `IMAGE_PUSH_PARTIALLY_COMMITTED` means the registry commit was confirmed, but the local image index
could not be finalized. Inspect the tag in the registry, then pull the same reference. A successful pull rebuilds the
authoritative local record. Do not treat either code as an ordinary safe-to-retry failure without reconciling the tag.

**"Invalid image reference"**

References must include a registry unless `images.defaultRegistry` is configured. Format: `registry/repo:tag`

```
OK: ghcr.io/myorg/vm:latest
OK: localhost:5000/vms/dev:latest
CONDITIONAL: myorg/vm:latest     (valid only with images.defaultRegistry)
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

Choose **Copy API Token** in the menu-bar item, then paste the full value into your shell:

```bash
export TOKEN='paste-token-here'
```

An ad hoc Debug build without an application Keychain access group uses the login Keychain, where
`security find-generic-password -s com.jeballto.vmagent.api -a bearer-token -w` also works. Do not rely on that
command for a signed Release because it uses the data protection Keychain.

If startup reports Keychain status `-34018`, inspect the entitlements of the built app. Signed distributions
need a provisioning-profile-backed `com.apple.application-identifier` to access the data protection Keychain.
The built app must also contain `keychain-access-groups` with the same expanded identifier. Unsigned development
builds automatically use the login Keychain instead.

**404 Not Found**

Check the VM ID - list all VMs:

```bash
curl http://127.0.0.1:8011/v1/vms -H "Authorization: Bearer $TOKEN"
```

## State Issues

**VM stuck in a transitional state**

Lifecycle failures automatically transition to `error`. If a VM is still stuck in `starting`, `stopping`,
`pausing`, or `resuming` after a crash, restart the agent. On startup, transitional states are reset to `stopped`:

```bash
killall JeballtoAgent
open -a JeballtoAgent
```

**VM in `error` state**

Check events for the error message:

```bash
curl "http://127.0.0.1:8011/v1/vms/$VM_ID/events?limit=10" \
  -H "Authorization: Bearer $TOKEN"
```

From `error`, use stop as the recovery action. A complete installed VM reaches `stopped`; an incomplete installation
is cleaned and reaches `created`, where installation can be retried. You can also delete it:

```bash
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/stop -H "Authorization: Bearer $TOKEN"
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

Debug logging includes API request paths, registered routes, ORAS commands, and diagnostic messages emitted by each
component. It does not produce a complete audit record of every state transition, event publication, or SSH process
detail.

## Reset Everything

Use hard reset to wipe VMs, images, config, caches, logs, the API token, and Jeballto's stored registry credentials.
The agent exits after a fully successful response.

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
