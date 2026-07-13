# Operating the Agent

Running JeballtoAgent day-to-day: the status bar menu, auto-updates, start-at-login, the IPSW cache, and required macOS permissions.

Only one JeballtoAgent process can use a user's local state at a time. A second process exits before loading the VM
database, image index, or API credential, so it cannot reconcile or overwrite state owned by the running agent.

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

OCI image pull and push operations use a separate resumable transfer cache under
`~/Library/Caches/Jeballto/ImageWork/sessions/`. The agent and each image child process hold shared advisory leases on
their session. A launch marker protects the handoff before a child acquires its lease, and the child preserves that
lease while running `oras`, `zstd`, or the bundle-copy tool. Cleanup requires an exclusive lease. This prevents a new
agent from deleting work still used by an orphaned child after an unexpected exit.

Startup removes only sessions proven inactive. After acquiring the global single-instance lock, it may also remove
old work that has no lock. A symbolic or otherwise unsafe lock target is preserved for manual inspection. Successful
transfers delete their operation cache. Failed or cancelled transfers keep verified work until the process exits,
and a later startup removes the inactive session.

**Clearing caches:**

- `POST /v1/system/reset` (either mode) attempts to clear the IPSW cache. Hard reset reaches cache cleanup only after
  every VM and image has been removed successfully.
- Or remove the directory manually while the agent is stopped.

An image wipe clears only the current process's image work session and keeps its lock files. It does not scan foreign
session directories. The next exclusive startup removes inactive or old lockless work. Remove directories with
unsafe lock files manually only while every Jeballto process and image child is stopped.

IPSW restore images are large, so a cache containing several versions can be a major user of disk space beyond the
VM bundles themselves.

## Local Network Permission

macOS requires explicit user permission for apps that bind to local network addresses. JeballtoAgent needs this for SSH and VNC port forwarding.

On first launch, macOS prompts for approval. If the prompt is dismissed or denied, SSH/VNC proxies fail with `PolicyDenied(-65570)` in the logs.

**To grant it after the fact:** System Settings > Privacy & Security > Local Network > enable JeballtoAgent, then restart the agent.

See also <doc:Troubleshooting>.

## Headless vs GUI Window

The agent is headless by default: VMs run without a visible window. You can attach a window on demand:

- `POST /v1/vms/{id}/gui` - opens a native `VZVirtualMachineView` window
- `DELETE /v1/vms/{id}/gui` - closes it; the VM keeps running

A window is **not required** for `GET /v1/vms/{id}/screenshot` (which works while the VM is `running`) or for
keystroke injection (a hidden view is created automatically when no window is open).

## Shutdown Behavior

`Stop Jeballto` (or SIGTERM/SIGINT) runs `cleanupForShutdown()` with a 30-second budget:

- **Ephemeral VMs** are stopped, then deleted.
- **Non-ephemeral running VMs** are paused and saved to disk.
- **Non-ephemeral in-memory paused VMs** are saved without being resumed first.

On the next launch, saved VMs remain `paused` with the save file available. Resume them explicitly with
`POST /v1/vms/{id}/resume`.

If the 30-second budget expires, the agent exits anyway. On next startup, `starting`, `stopping`, `pausing`, and
`resuming` states become `stopped` because their runtime process is gone. A `paused` VM remains paused only when its
save file exists. An interrupted installation becomes retryable in `created`; finalization is recovered to `stopped`
when the bundle is complete, or to `error` when validation fails.
