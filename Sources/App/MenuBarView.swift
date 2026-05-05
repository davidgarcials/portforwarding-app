import SwiftUI
import PortForwardingLib

struct MenuBarView: View {
    @ObservedObject var manager: ForwardManager
    @Environment(\.openWindow) private var openWindow

    private var sortedForwards: [PortForward] {
        manager.forwards.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            ForEach(sortedForwards) { forward in
                ForwardRowView(
                    forward: forward,
                    state: manager.states[forward.id] ?? .idle,
                    onStart: { Task { await manager.connect(forward) } },
                    onStop: { manager.disconnect(forward) }
                )
                if forward.id != sortedForwards.last?.id {
                    Divider().padding(.leading, 32)
                }
            }
            Divider()
            actionButtons
            Divider()
            bottomSection
        }
        .frame(width: 360)
    }

    private var headerSection: some View {
        HStack {
            Text("Port Forwards")
                .font(.headline)
            Spacer()
            connectedCount
            Button(action: {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }) {
                Image(systemName: "gear")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var connectedCount: some View {
        let count = manager.states.values.filter { $0 == .ready }.count
        let total = manager.forwards.count
        return Text("\(count)/\(total)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if manager.isConnectingAll {
                Button("Cancel") {
                    manager.cancelConnectAll()
                }
            } else {
                Button("Connect All") {
                    manager.connectAll()
                }
            }

            Button("Disconnect All") {
                manager.disconnectAll()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bottomSection: some View {
        Button("Quit") {
            manager.disconnectAll()
            NSApplication.shared.terminate(nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct ForwardRowView: View {
    let forward: PortForward
    let state: ForwardState
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            statusDot
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(forward.name)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    if !forward.enabled {
                        Text("off")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    Text(":\(forward.localPort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if case .failed(let reason) = state {
                        Text("— \(reason)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            actionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch state {
        case .idle, .stopped: return .gray
        case .starting: return .yellow
        case .ready: return .green
        case .failed: return .red
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .idle, .stopped, .failed:
            Button(action: onStart) {
                Image(systemName: "play.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
        case .starting:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
        }
    }
}
