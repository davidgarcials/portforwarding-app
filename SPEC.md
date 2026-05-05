# PortForwarding App — Specification

**Date:** 2025-05-05
**Status:** Approved

## Problem

Managing multiple AWS SSM port forwards manually is tedious: each requires a separate terminal, each triggers a macOS Keychain dialog (via aws-vault), and they must be launched one at a time because the Keychain prompt blocks. The goal is a native macOS app that automates sequential launching and provides at-a-glance status.

## Decisions

### Tech Stack
- **Language:** Swift 5.9+
- **UI:** SwiftUI, targeting macOS 14+
- **No sandbox** — app spawns child processes (aws-vault, aws cli, session-manager-plugin)

### UI Surface
- **Menu bar app** (`MenuBarExtra`) with a popover showing all forwards, status dots, individual start/stop, and "Connect All Enabled" / "Disconnect All" buttons
- **Settings window** (separate `Window` scene) for CRUD on forward entries

### Data Storage
- Single JSON file at `~/Library/Application Support/PortForwardingApp/config.json`
- Atomic writes (write to `.tmp`, then `rename`)
- Schema versioned (`version: 1`) for future migration

### Connection Orchestration
- **Sequential "Connect All":** iterates enabled forwards in `sortOrder`, `await`s each one before starting the next
- **Readiness detection:** parse child process stdout for `"Waiting for connections..."` marker
- **Timeout:** 60 seconds per forward; configurable later if needed
- **Failure behavior:** log the failure, move to the next forward (don't stall the queue)
- **Stop:** SIGTERM, then SIGKILL after grace period

### Auth Flow
- `aws-vault exec <profile>` triggers a macOS Keychain unlock dialog (Touch ID / password)
- The app does NOT interact with the dialog — it simply waits for the child process to proceed past the credential phase
- This is why launches must be sequential: each triggers a system dialog the user must respond to

## Data Model

```swift
struct PortForward: Codable, Identifiable {
    var id: UUID
    var name: String           // human label
    var awsProfile: String     // aws-vault profile name
    var region: String         // AWS region
    var target: String         // EC2 instance ID
    var remoteHost: String?    // nil = direct mode, set = remote-host mode
    var remotePort: Int
    var localPort: Int
    var enabled: Bool          // included in "Connect All"
    var sortOrder: Int         // sequential launch order
}

struct AppConfig: Codable {
    var version: Int = 1
    var forwards: [PortForward]
}
```

### Command Construction

**Direct mode** (`remoteHost == nil`):
```
aws-vault exec <awsProfile> -- \
  aws ssm start-session \
    --target <target> \
    --document-name AWS-StartPortForwardingSession \
    --parameters '{"portNumber":["<remotePort>"],"localPortNumber":["<localPort>"]}' \
    --region <region>
```

**Remote-host mode** (`remoteHost != nil`):
```
aws-vault exec <awsProfile> -- \
  aws ssm start-session \
    --target <target> \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters '{"host":["<remoteHost>"],"portNumber":["<remotePort>"],"localPortNumber":["<localPort>"]}' \
    --region <region>
```

## Architecture

### Three Layers

1. **UI Layer** (SwiftUI)
   - `MenuBarExtra` with popover: list of forwards, status dots, action buttons
   - `Window("Settings")`: form-based CRUD for forward entries
   - Status dot colors: green (ready), yellow (starting), gray (idle), red (failed)

2. **Domain Layer**
   - `ForwardManager: ObservableObject` — source of truth
     - `@Published forwards: [PortForward]`
     - `@Published states: [UUID: ForwardState]`
     - `connectAll() async` — sequential orchestrator
     - `connect(_:) async` / `disconnect(_:)` — per-forward control
   - `ConfigStore` — load/save JSON with atomic write

3. **Process Layer**
   - `ProcessRunner` — wraps `Foundation.Process`
     - Pipes stdout/stderr, exposes `AsyncStream<String>` of log lines
     - `startAndAwaitReady() async throws` — resolves on readiness marker or rejects on exit/timeout
     - `stop()` — SIGTERM + SIGKILL escalation

### Preflight Check
On launch, verify `aws-vault`, `aws`, and `session-manager-plugin` are installed (run `--version`). Show setup banner in settings window if any are missing.

### Error Handling
- Process exits before readiness marker → `.failed` with last 5 stderr lines
- Keychain dialog cancelled → aws-vault exits non-zero → `.failed`
- Timeout → `.failed("Timed out")`
- During "Connect All", failures don't block the queue

## Explicitly Out of Scope (YAGNI)
- Groups / profiles (flat list with sortOrder is sufficient)
- Launch at login (trivial to add later via SMAppService)
- Auto-reconnect on tunnel drop
- Export/import config (it's a JSON file)
- Notifications (status dots are sufficient)
- Dark/light theme toggle (SwiftUI respects system appearance)

## Pending
- **Seed data:** Boss to provide the current list of port forwards to populate initial config.json

## Implementation Notes
- No App Store distribution — direct .app or Homebrew cask
- TDD: ProcessRunner testable with mock executables (`/bin/sh -c 'echo "Waiting for connections..."'`)
- ForwardManager testable with injected ProcessRunner protocol
