import SwiftUI
import PortForwardingLib

struct SettingsView: View {
    @ObservedObject var manager: ForwardManager
    @State private var showingAddSheet = false
    @State private var editingForward: PortForward?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            forwardList
        }
        .frame(minWidth: 650, minHeight: 450)
        .sheet(isPresented: $showingAddSheet) {
            ForwardFormView(title: "Add Forward") { forward in
                manager.addForward(forward)
            }
        }
        .sheet(item: $editingForward) { (forward: PortForward) in
            ForwardFormView(title: "Edit Forward", forward: forward) { updated in
                manager.updateForward(updated)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if manager.isConnectingAll {
                Button("Cancel") { manager.cancelConnectAll() }
            } else {
                Button("Connect All") { manager.connectAll() }
            }
            Button("Disconnect All") { manager.disconnectAll() }
            Spacer()
            Button("Add Forward") { showingAddSheet = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var forwardList: some View {
        List {
            ForEach(manager.forwards.sorted(by: { $0.sortOrder < $1.sortOrder })) { forward in
                ForwardSettingsRow(
                    forward: forward,
                    state: manager.states[forward.id] ?? .idle,
                    onConnect: { Task { await manager.connect(forward) } },
                    onDisconnect: { manager.disconnect(forward) },
                    onEdit: { editingForward = forward },
                    onDelete: { manager.deleteForward(forward) }
                )
            }
        }
    }
}

struct ForwardSettingsRow: View {
    let forward: PortForward
    let state: ForwardState
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statusDot
            info
            Spacer()
            stateLabel
            actionButton
            editButton
            deleteButton
        }
        .padding(.vertical, 4)
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
    }

    private var statusColor: Color {
        switch state {
        case .idle, .stopped: return .gray
        case .starting: return .yellow
        case .ready: return .green
        case .failed: return .red
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(forward.name).font(.headline)
                if !forward.enabled {
                    Text("disabled")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            Text("svc/\(forward.service) (\(forward.namespace))  localhost:\(forward.localPort) → :\(forward.remotePort)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch state {
        case .idle, .stopped:
            EmptyView()
        case .starting:
            Text("Connecting...")
                .font(.caption)
                .foregroundStyle(.orange)
        case .ready:
            Text("Connected")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let reason):
            Text(reason)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: 300, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch state {
        case .idle, .stopped, .failed:
            Button(action: onConnect) {
                Image(systemName: "play.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .help("Connect")
        case .starting:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Button(action: onDisconnect) {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Disconnect")
        }
    }

    private var editButton: some View {
        Button(action: onEdit) {
            Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .help("Edit")
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("Delete")
    }
}

struct ForwardFormView: View {
    let title: String
    var forward: PortForward?
    let onSave: (PortForward) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var service: String = ""
    @State private var namespace: String = ""
    @State private var remotePort: String = ""
    @State private var localPort: String = ""
    @State private var enabled: Bool = true
    @State private var sortOrder: String = "0"

    var body: some View {
        VStack {
            formFields
            formButtons
        }
        .padding()
        .frame(width: 400)
        .onAppear { populateFromForward() }
    }

    private var formFields: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Service (e.g. lec-multitenant-api)", text: $service)
            TextField("Namespace", text: $namespace)
            TextField("Remote Port", text: $remotePort)
            TextField("Local Port", text: $localPort)
            TextField("Sort Order", text: $sortOrder)
            Toggle("Enabled", isOn: $enabled)
        }
    }

    private var formButtons: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            Button("Save") { saveForward() }
                .disabled(name.isEmpty || service.isEmpty || namespace.isEmpty || remotePort.isEmpty || localPort.isEmpty)
        }
    }

    private func populateFromForward() {
        guard let fwd = forward else { return }
        name = fwd.name
        service = fwd.service
        namespace = fwd.namespace
        remotePort = String(fwd.remotePort)
        localPort = String(fwd.localPort)
        enabled = fwd.enabled
        sortOrder = String(fwd.sortOrder)
    }

    private func saveForward() {
        let fwd = PortForward(
            id: forward?.id ?? UUID(),
            name: name,
            service: service,
            namespace: namespace,
            localPort: Int(localPort) ?? 0,
            remotePort: Int(remotePort) ?? 0,
            enabled: enabled,
            sortOrder: Int(sortOrder) ?? 0
        )
        onSave(fwd)
        dismiss()
    }
}
