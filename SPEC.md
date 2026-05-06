# PortForwarding App — Specification

**Date:** 2025-05-05
**Status:** Approved
**Last updated:** 2026-05-05

## Problem

Managing multiple `kubectl port-forward` connections manually is tedious: each requires a separate terminal window, connections drop silently, and there's no single view of what's running. The goal is a native macOS menu bar app that automates sequential launching and provides at-a-glance status.

## Decisions

### Tech Stack
- **Language:** Swift 5.9+
- **UI:** SwiftUI, targeting macOS 14+
- **Build:** Swift Package Manager (no Xcode project required)
- **No sandbox** — app spawns child processes (`kubectl`)

### UI Surface
- **Menu bar app** (`MenuBarExtra`) with a popover showing all forwards grouped by workspace, status dots, individual start/stop, and "Connect All" / "Disconnect All" buttons
- **Settings window** (separate `Window` scene) for workspace management and per-workspace CRUD on forward entries
- **Kubectl discovery** — add-forward form browses namespaces, services, and ports from the cluster

### Data Storage
- **App config** at `~/Library/Application Support/PortForwardingApp/config.json` — stores only workspace folder paths
- **Per-workspace config** at `<workspace>/.portforwards.json` — stores the forward entries for that workspace
- Atomic writes (`Data.write(options: .atomic)`)
- Schema versioned (`version: 1`) for future migration

### Connection Orchestration
- **Sequential "Connect All":** iterates enabled forwards in `sortOrder`, `await`s each one before starting the next
- **Per-workspace connect/disconnect:** start or stop all forwards in a single workspace
- **Readiness detection:** parse child process stdout for `"Forwarding from"` marker
- **Timeout:** 30 seconds per forward
- **Failure behavior:** log the failure, move to the next forward (don't stall the queue)
- **Port conflict detection:** prevents starting two forwards on the same local port
- **Stop:** `Process.terminate()` (SIGTERM)

### Startup & Health
- **Startup detection:** TCP probe on configured local ports to detect already-running forwards
- **Health monitoring:** polls ports every 10 seconds, updates state if connections drop or appear externally
- **Process death detection:** `onTerminatedAfterReady` callback updates UI when kubectl exits unexpectedly

## Data Model

```swift
struct PortForward: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String           // human label (e.g. "pf-my-api")
    var service: String        // Kubernetes service name
    var namespace: String      // Kubernetes namespace
    var localPort: Int
    var remotePort: Int
    var enabled: Bool          // included in "Connect All"
    var sortOrder: Int         // sequential launch order
}

struct AppConfig: Codable {
    var version: Int = 1
    var workspacePaths: [String]
}

struct WorkspaceConfig: Codable {
    var forwards: [PortForward]
}

struct Workspace: Identifiable, Hashable {
    var id: String { path }
    let path: String
    var forwards: [PortForward]
    var name: String { (path as NSString).lastPathComponent }
}
```

### Command Construction

Forwards are launched via login shell to inherit the user's PATH and kubeconfig:

```
/bin/zsh -l -c "kubectl port-forward svc/<service> --namespace <namespace> <localPort>:<remotePort>"
```

## Architecture

### Three Layers

1. **UI Layer** (SwiftUI)
   - `MenuBarExtra` with popover: forwards grouped by workspace, status dots, action buttons
   - `Window("Settings")`: workspace list with folder picker, per-workspace forward CRUD, connect/disconnect per workspace
   - Add-forward form with kubectl namespace/service/port discovery
   - Status dot colors: green (ready), yellow (starting), gray (idle), red (failed)

2. **Domain Layer**
   - `ForwardManager: ObservableObject` — source of truth
     - `@Published workspaces: [Workspace]`
     - `@Published states: [UUID: ForwardState]`
     - Workspace management: `addWorkspace(path:)`, `removeWorkspace(_:)`
     - Forward CRUD: `addForward(_:to:)`, `updateForward(_:in:)`, `deleteForward(_:from:)`
     - `connectAll()` / `disconnectAll()` — across all workspaces
     - `connectWorkspace(_:)` / `disconnectWorkspace(_:)` — per workspace
     - `connect(_:) async` / `disconnect(_:)` — per forward
   - `ConfigStore` — load/save app config and per-workspace configs
   - `KubectlDiscovery` — fetches namespaces and services from kubectl
   - `PortChecker` — TCP probe on localhost ports

3. **Process Layer**
   - `ProcessRunner` — wraps `Foundation.Process`
     - Uses `readabilityHandler` on pipes for stdout/stderr parsing
     - `startAndAwaitReady() async throws` — resolves on readiness marker or rejects on exit/timeout
     - `onTerminatedAfterReady` — callback for post-connect process death
     - `stop()` — terminates process

### Error Handling
- Process exits before readiness marker → `.failed` with exit code and last output
- Timeout → `.failed("Timed out")`
- Port conflict → `.failed("Port X already in use by another forward")`
- Connection lost (health check) → `.failed("Connection lost")`
- During "Connect All", failures don't block the queue

## Explicitly Out of Scope (YAGNI)
- Launch at login (trivial to add later via SMAppService)
- Auto-reconnect on tunnel drop
- Export/import config (it's a JSON file per workspace)
- Notifications (status dots are sufficient)
- Dark/light theme toggle (SwiftUI respects system appearance)

## Implementation Notes
- No App Store distribution — direct .app download from GitHub Releases
- Unsigned app requires `xattr -cr PortForwarding.app` after download
- LSUIElement=true — menu bar only, no Dock icon
- TDD: ProcessRunner testable with `/bin/sh` mock scripts
- ForwardManager testable with injected `ProcessRunnerFactory` protocol
- Custom TestRunner executable (XCTest unavailable without full Xcode)
