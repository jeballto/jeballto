# Jeballto Agent

A headless macOS virtual machine manager for Apple Silicon, exposing a REST API for programmatic VM lifecycle management.

## Overview

JeballtoAgent runs as a macOS menu-bar app on Apple Silicon with macOS 26.0+ and serves a REST API on port 8011, bound to all interfaces by default. It stores the API token in the macOS Keychain; see <doc:APIReference> for auth details.

Two primary workflows:

- **Blank VM:** create a VM, install macOS from an IPSW, start it, and interact via SSH or keystrokes.
- **OCI image:** pull a previously pushed VM bundle, create a VM from it, start immediately - no install needed.

Jeballto allows up to 2 capacity-consuming VMs at once. Installing, transitional, running, and paused VMs count
toward this product limit. VM state is persisted and reconciled across restarts.

## Getting Started

- <doc:GettingStarted>

## Core Concepts

- <doc:Architecture>
- <doc:APIReference>
- <doc:JeballtofileReference>

## VM Lifecycle

- <doc:VMManager>
- <doc:VMState>
- <doc:VMDefinition>

## Event System

- <doc:EventBus>

## Configuration

- <doc:Config>

## API Layer

- <doc:APIServer>

## Developer Resources

- <doc:OperatingTheAgent>
- <doc:DevelopmentGuide>
- <doc:Troubleshooting>
