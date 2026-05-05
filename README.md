# PortForwarding App

A native macOS menu bar application for managing `kubectl port-forward` connections. Start, stop, and monitor multiple port forwards from a single interface instead of juggling terminal windows.

## Features

- **Menu bar popover** with status dots (green/yellow/red/gray) and per-forward controls
- **Settings window** for adding, editing, and deleting port forward configurations
- **Connect All** launches all enabled forwards sequentially
- **Port conflict detection** prevents starting two forwards on the same local port
- **Startup detection** checks which ports are already listening and initializes state accordingly
- **Health monitoring** polls ports every 10 seconds to detect dropped connections and external changes
- **Process death detection** updates the UI immediately when a kubectl process exits unexpectedly

## Requirements

- macOS 14+
- `kubectl` available in PATH
- A configured kubeconfig with access to your clusters

## Build

```bash
# Run tests
make test

# Build the .app bundle
make bundle

# Build and launch
make run

# Clean
make clean
```

The app bundle is created at `build/PortForwarding.app`. You can copy it to `/Applications` or run it from anywhere.

## Configuration

Port forward entries are stored in:

```
~/Library/Application Support/PortForwardingApp/config.json
```

Each entry defines:

| Field | Description |
|-------|-------------|
| `name` | Human-readable label (e.g. `pf-lmta`) |
| `service` | Kubernetes service name |
| `namespace` | Kubernetes namespace |
| `localPort` | Port on localhost |
| `remotePort` | Port on the service |
| `enabled` | Included in "Connect All" |
| `sortOrder` | Launch order for sequential connect |

Example entry:

```json
{
  "name": "pf-lmta",
  "service": "lec-multitenant-api",
  "namespace": "lec-staging",
  "localPort": 3010,
  "remotePort": 80,
  "enabled": true,
  "sortOrder": 0
}
```

## Architecture

```
Sources/
├── App/            # SwiftUI views (@main, MenuBarView, SettingsView)
├── Domain/         # Business logic (ForwardManager, ConfigStore, PortForward model)
└── Process/        # Child process management (ProcessRunner)
```

- **ForwardManager** is the central `ObservableObject` — owns state, orchestrates connections, runs health checks
- **ProcessRunner** wraps `Foundation.Process`, detects readiness via stdout marker (`Forwarding from`), and reports process death
- **PortChecker** probes local ports via TCP to detect existing connections
