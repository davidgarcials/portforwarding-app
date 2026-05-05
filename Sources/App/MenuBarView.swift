import SwiftUI
import PortForwardingLib

struct MenuBarView: View {
    @ObservedObject var manager: ForwardManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            forwardsList
            Divider()
            actionButtons
            Divider()
            bottomSection
        }
        .frame(width: 320)
    }

    private var headerSection: some View {
        HStack {
            Text("Port Forwards")
                .font(.headline)
            Spacer()
            Button(action: { openWindow(id: "settings") }) {
                Image(systemName: "gear")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var forwardsList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(manager.forwards.sorted(by: { $0.sortOrder < $1.sortOrder })) { forward in
                    ForwardRowView(
                        forward: forward,
                        state: manager.states[forward.id] ?? .idle,
                        onStart: { Task { await manager.connect(forward) } },
                        onStop: { manager.disconnect(forward) }
                    )
                }
            }
        }
        .frame(maxHeight: 400)
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
        HStack {
            statusDot
            VStack(alignment: .leading, spacing: 2) {
                Text(forward.name)
                    .font(.system(.body, design: .monospaced))
                Text(":\(forward.localPort)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actionButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
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
            }
            .buttonStyle(.borderless)
        case .starting:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Button(action: onStop) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
        }
    }
}
