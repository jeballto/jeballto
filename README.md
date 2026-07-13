# Jeballto VM Agent

Headless, API-first macOS virtual machine manager for Apple Silicon.

[![Jeballto CI](https://github.com/jeballto/jeballto/actions/workflows/jeballto-ci.yml/badge.svg)](https://github.com/jeballto/jeballto/actions/workflows/jeballto-ci.yml)

> [!IMPORTANT]
> Jeballto is currently in public beta. Some functionality may be incomplete, unstable, or change in breaking ways before a stable release. Pin versions for critical workflows and review release notes before upgrading.

## Release Set

Use components from the same release set unless release notes say otherwise.

| JeballtoAgent | GitHub Actions Runner | GitLab Executor | Jenkins Plugin | Python CLI |
|---|---|---|---|---|
| `1.0.0-beta.1` | `1.0.0-beta.1` | `1.0.0-beta.1` | `1.0.0-beta.1` | `1.0.0b1` |

## Features

- REST API for VM creation, installation, lifecycle, cloning, and deletion
- OCI image pull and push through compatible registries
- SSH access with automatic forwarding by default, plus on-demand VNC forwarding
- SSH command execution and native GUI windows
- Jeballtofile blueprints for fully automated VM provisioning (JSON or YAML)
- Keystroke injection for automation before SSH is available
- Automatic macOS installation from the latest compatible IPSW or a selected source
- Screenshot capture from guest VMs
- Up to 2 capacity-consuming VMs at once
- Non-ephemeral running and in-memory paused VMs saved across graceful agent restarts and available for explicit resume
- Ephemeral VMs for CI/CD and other disposable workflows
- Built on Apple Virtualization framework with minimal dependencies (`oras`, `zstd`, `Sparkle`, `Yams`)

## Requirements

- Apple Silicon Mac
- macOS 26.0 or later

### For development

- Xcode 26+ (for building)
- Homebrew and Task

Run `task setup` once, then use `task build`, `task test`, and `task pre-commit:all`. See the
[Development Guide](JeballtoAgent/JeballtoAgent.docc/Articles/DevelopmentGuide.md) for the complete workflow.

## Quick Start

1. Download the latest ZIP from [Releases](https://github.com/jeballto/jeballto/releases/latest).
2. Move `JeballtoAgent.app` to `/Applications` and open it.
3. Allow Local Network access when macOS asks. SSH and VNC forwarding require it.
4. Choose **Copy API Token** in the Jeballto menu-bar item.

### Create, install, and open a VM

Set the API address and paste the full token copied from the menu bar:

```bash
export JEBALLTO_API='http://127.0.0.1:8011'
export JEBALLTO_TOKEN='paste-token-here'
```

Create a VM:

```bash
curl -fsS -X POST "$JEBALLTO_API/v1/vms" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"dev-vm","resources":{"cpuCount":4,"memorySize":"8GB","diskSize":"64GB"}}'
```

Copy `id` from the response, then start the automatic macOS installation:

```bash
export VM_ID='paste-vm-id-here'

curl -fsS -X POST "$JEBALLTO_API/v1/vms/$VM_ID/install" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN"
```

Installation runs asynchronously. Check its status and wait for `status` to become `completed`:

```bash
curl -fsS "$JEBALLTO_API/v1/vms/$VM_ID/install/status" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN"
```

Start the VM and open its native window:

```bash
curl -fsS -X POST "$JEBALLTO_API/v1/vms/$VM_ID/start" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN"

curl -fsS -X POST "$JEBALLTO_API/v1/vms/$VM_ID/gui" \
  -H "Authorization: Bearer $JEBALLTO_TOKEN"
```

For image-based VMs, SSH, VNC, command execution, and automation, continue with the
[Getting Started guide](JeballtoAgent/JeballtoAgent.docc/Articles/GettingStarted.md).

## Documentation

- [Getting Started](JeballtoAgent/JeballtoAgent.docc/Articles/GettingStarted.md)
- [API Reference](JeballtoAgent/JeballtoAgent.docc/Articles/APIReference.md)
- [Jeballtofile Reference](JeballtoAgent/JeballtoAgent.docc/Articles/JeballtofileReference.md)
- [Operating the Agent](JeballtoAgent/JeballtoAgent.docc/Articles/OperatingTheAgent.md)
- [Troubleshooting](JeballtoAgent/JeballtoAgent.docc/Articles/Troubleshooting.md)
- [Architecture](JeballtoAgent/JeballtoAgent.docc/Articles/Architecture.md)

## License

See LICENSE for licensing information.
