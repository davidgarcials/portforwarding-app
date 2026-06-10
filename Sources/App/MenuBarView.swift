import SwiftUI
import PortForwardingLib

struct MenuBarView: View {
    @ObservedObject var manager: ForwardManager
    @ObservedObject var updateChecker: UpdateChecker
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            if updateChecker.availableUpdate != nil {
                UpdateBannerView(
                    updateChecker: updateChecker,
                    compact: true,
                    onBeforeUpdate: { manager.disconnectAll() }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            Divider()
            ForEach(manager.workspaces) { workspace in
                workspaceSection(workspace)
            }
            if manager.workspaces.isEmpty {
                Text("No workspaces configured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            Divider()
            actionButtons
        }
        .frame(width: 360)
    }

    private var headerSection: some View {
        HStack {
            Text("Port Forwards")
                .font(.headline)
            Spacer()
            connectedCount
            appMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var connectedCount: some View {
        let count = manager.states.values.filter { $0 == .ready }.count
        let total = manager.allForwards.count
        return Text("\(count)/\(total)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var appMenu: some View {
        Menu {
            Section("Resources") {
                Button("View on GitHub") { openURL(updateChecker.repoURL) }
                Button("Release Notes") { openURL(updateChecker.releasesURL) }
            }
            Divider()
            Button("Check for Updates…") {
                Task { await updateChecker.checkForUpdate() }
            }
            Divider()
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }
            Divider()
            Button("Quit Port Forwarding") {
                manager.disconnectAll()
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: "gear")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
    }

    private func workspaceSection(_ workspace: Workspace) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(workspace.name)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)

            let sorted = workspace.forwards.sorted { $0.sortOrder < $1.sortOrder }
            ForEach(sorted) { forward in
                ForwardRowView(
                    forward: forward,
                    state: manager.states[forward.id] ?? .idle,
                    onStart: { Task { await manager.connect(forward) } },
                    onStop: { manager.disconnect(forward) }
                )
                if forward.id != sorted.last?.id {
                    Divider().padding(.leading, 32)
                }
            }
        }
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
                    } else if state == .authenticating {
                        Text("— Authenticating…")
                            .font(.caption2)
                            .foregroundStyle(.orange)
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
        case .starting, .authenticating: return .yellow
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
        case .starting, .authenticating:
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
