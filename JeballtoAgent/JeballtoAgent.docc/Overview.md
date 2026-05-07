# Jeballto Agent

A headless macOS virtual machine manager for Apple Silicon, exposing a REST API for programmatic VM lifecycle management.

## Overview

JeballtoAgent runs as a macOS menu-bar app on Apple Silicon (M1+, macOS 26.0+) and serves a REST API on `localhost:8011` by default. It writes an API token on first launch; see <doc:APIReference> for auth details.

Two primary workflows:

- **Blank VM:** create a VM, install macOS from an IPSW, start it, and interact via SSH or keystrokes.
- **OCI image:** pull a previously pushed VM bundle, create a VM from it, start immediately - no install needed.

Up to 2 VMs can run concurrently (Apple Silicon hardware limit). VM state is persisted across restarts.

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
