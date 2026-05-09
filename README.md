# Jeballto VM Agent

Headless, API-first macOS virtual machine manager for Apple Silicon.

[![Jeballto CI](https://github.com/jeballto/jeballto/actions/workflows/jeballto-ci.yml/badge.svg)](https://github.com/jeballto/jeballto/actions/workflows/jeballto-ci.yml)

> [!IMPORTANT]
> Jeballto is currently in public beta. Some functionality may be incomplete, unstable, or change in breaking ways before a stable release. Pin versions for critical workflows and review release notes before upgrading.

## Version Compatibility

Use matched beta versions unless release notes say otherwise.

| JeballtoAgent | GitHub Actions Runner | GitLab Executor | Jenkins Plugin | Python CLI |
|---|---|---|---|---|
| `1.0.0-beta.1` | `1.0.0-beta.1` | `1.0.0-beta.1` | `1.0.0-beta.1` | `1.0.0b1` |

## Features

- REST API for full VM lifecycle (create, start, stop, pause, resume, clone, delete etc.)
- OCI image management - pull, push, and share VM images via any OCI registry like AWS ECR, Azure ACR, Google Artifact Registry
- SSH and VNC access via automatic port forwarding
- Command execution inside VMs via SSH
- Jeballtofile blueprints for fully automated VM provisioning (JSON or YAML)
- Keystrokes injection - for operating on VM before SSH is enabled on the guest (for automating Setup Assistant)
- GUI window support for graphical VM interaction
- Automatic macOS installation (auto-download latest or IPSW of your choice)
- Run up to 2 VMs in parallel
- Easy screenshot capture from guest VMs
- VM state saved and restored across graceful agent restarts
- Ephemeral VMs for CI/CD and other disposable workflows - configure a VM to be deleted on the next stop or after a defined number of seconds
- Built on Apple Virtualization framework with minimal dependencies (`oras`, `Sparkle`, `Yams`)

## Requirements

- Apple Silicon Mac
- macOS 26.0 or later

### For development

- Xcode 26+ (for building)
- Optionally for full experience: taskfile, pre-commit, xcbeautify, npm, mermaid, oras

## Quick Start

1. Get ZIP from [Releases](https://github.com/jeballto/jeballto/releases)
2. Unpack .app to your /Applications
3. Run it! It should appear in your Menu Bar

### Create and run a VM

```bash

# Token can be found in "~/Library/Application\ Support/Jeballto/config.json"
# Or by clicking on Jeballto tray icon and CMD + C
export TOKEN=token-from-config

# Create VM (4 CPU, 8 GB RAM, 64 GB disk)
curl -s -X POST http://127.0.0.1:8011/v1/vms \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"dev-vm","resources":{"cpuCount":4,"memorySize":"8GB","diskSize":"64GB"}}'

# Install macOS (auto-downloads latest from Apple)
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/install \
  -H "Authorization: Bearer $TOKEN"

# Start VM
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/start \
  -H "Authorization: Bearer $TOKEN"

# Start a GUI
curl -X POST http://127.0.0.1:8011/v1/vms/$VM_ID/gui \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json"
```

## Documentation

- [JeballtoAgent DocC](JeballtoAgent/JeballtoAgent.docc)

## License

See LICENSE for licensing information.
