# Operating the Agent

Running JeballtoAgent day-to-day: the status bar menu, auto-updates, start-at-login, the IPSW cache, and required macOS permissions.

## Status Bar Menu

JeballtoAgent runs as a headless macOS app with a status bar icon. Click it to open the menu:

| Item | Purpose |
|------|---------|
| `Status: Healthy / Starting...` | Reflects agent readiness |
| `VMs: N running / M total` | Live counts (refreshed when menu opens) |
| `Uptime: Xh Ym` | Time since the HTTP server came up |
| `Copy API Token` | Copies the current Bearer token to the clipboard |
| `Export API Schema` | Saves the bundled OpenAPI spec to a location you choose |
| `Open Application Support` | Opens `~/Library/Application Support/Jeballto/` in Finder |
| `Open Cache` | Opens `~/Library/Caches/Jeballto/` in Finder |
| `Open Logs` / `Export Logs` | Daily rotating log directory |
| `Check for Updates` | Triggers Sparkle immediately |
| `Beta Updates` | Toggles the Sparkle beta appcast feed |
| `Start at Login` | Toggles launch at login (see below) |
| `About Jeballto` | Version info |
| `Stop Jeballto` | Graceful shutdown (runs cleanup, paused + saved for non-ephemeral VMs) |

## Start at Login

Use the `Start at Login` menu item to toggle launch-at-login. This uses `SMAppService.mainApp` from the `ServiceManagement` framework; the menu checkmark reflects the current state.

If toggling fails silently, open `System Settings > General > Login Items & Extensions` and verify JeballtoAgent is listed.

## Automatic Updates

Updates are delivered via [Sparkle](https://sparkle-project.org/). The agent checks the configured appcast feed on a schedule and shows a notification when a new version is available. You can also trigger a check from the status bar menu (`Check for Updates`).

Use `Beta Updates` to switch between stable and beta release feeds. The choice is saved locally and applies to future Sparkle checks. Debug builds default to beta updates enabled, while Release builds default to stable updates until the user changes the setting.

Notifications are posted through the standard macOS Notification Center, so they respect System Settings > Notifications > JeballtoAgent. Ephemeral VMs run through the usual shutdown path when you install an update.

## Download Caches

Downloaded macOS IPSWs are cached at:

```
~/Library/Caches/Jeballto/IPSWCache/
```

The cache is reused across installs so repeated `POST /v1/vms/{id}/install` calls with the same source don't re-download.

**Clearing caches:**

- `POST /v1/system/reset` (either mode) clears the IPSW cache.
- Or remove the directory manually while the agent is stopped.

Typical IPSW size is 12-18 GB, so this is often the biggest user of disk space beyond the VM bundles themselves.

## Local Network Permission

macOS requires explicit user permission for apps that bind to local network addresses. JeballtoAgent needs this for SSH and VNC port forwarding.

On first launch, macOS prompts for approval. If the prompt is dismissed or denied, SSH/VNC proxies fail with `PolicyDenied(-65570)` in the logs.

**To grant it after the fact:** System Settings > Privacy & Security > Local Network > enable JeballtoAgent, then restart the agent.

See also <doc:Troubleshooting>.

## Headless vs GUI Window

The agent is headless by default: VMs run without a visible window. You can attach a window on demand:

- `POST /v1/vms/{id}/gui` - opens a native `VZVirtualMachineView` window
- `DELETE /v1/vms/{id}/gui` - closes it; the VM keeps running

A window is **not required** for `GET /v1/vms/{id}/screenshot` (which always works while the VM is RUNNING) or for keystroke injection (a hidden view is created automatically when no window is open).

## Shutdown Behavior

`Stop Jeballto` (or SIGTERM/SIGINT) runs `cleanupForShutdown()` with a 30-second budget:

- **Ephemeral VMs** are stopped, then deleted.
- **Non-ephemeral running VMs** are paused and saved to disk. They resume automatically on next launch if still PAUSED with a save file.

If the 30-second budget expires, the agent exits anyway. VMs still in a transitional state on next startup are reset to STOPPED (their runtime process is gone).
