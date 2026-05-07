import SwiftUI
import PortForwardingLib

struct SettingsView: View {
    @ObservedObject var manager: ForwardManager
    @ObservedObject var updateChecker: UpdateChecker
    @State private var addingToWorkspace: Workspace?
    @State private var editingForward: PortForward?

    var body: some View {
        VStack(spacing: 0) {
            if updateChecker.availableUpdate != nil {
                UpdateBannerView(updateChecker: updateChecker)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            toolbar
            Divider()
            workspaceList
            Divider()
            HStack {
                Text("v\(updateChecker.currentVersion)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 700, minHeight: 500)
        .sheet(item: $addingToWorkspace) { ws in
            ForwardFormView(title: "Add Forward") { forward in
                manager.addForward(forward, to: ws)
            }
        }
        .sheet(item: $editingForward) { (forward: PortForward) in
            if let ws = workspaceForForward(forward) {
                ForwardFormView(title: "Edit Forward", forward: forward) { updated in
                    manager.updateForward(updated, in: ws)
                }
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
            Button("Add Workspace") { addWorkspaceFolder() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var workspaceList: some View {
        List {
            ForEach(manager.workspaces) { workspace in
                Section {
                    ForEach(workspace.forwards.sorted(by: { $0.sortOrder < $1.sortOrder })) { forward in
                        ForwardSettingsRow(
                            forward: forward,
                            state: manager.states[forward.id] ?? .idle,
                            onConnect: { Task { await manager.connect(forward) } },
                            onDisconnect: { manager.disconnect(forward) },
                            onEdit: { editingForward = forward },
                            onDelete: { manager.deleteForward(forward, from: workspace) }
                        )
                    }
                } header: {
                    workspaceHeader(workspace)
                }
            }
        }
    }

    private func workspaceHeader(_ workspace: Workspace) -> some View {
        HStack {
            Image(systemName: "folder")
            Text(workspace.name)
                .font(.headline)
            Text(workspace.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(action: {
                addingToWorkspace = workspace
            }) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add forward to this workspace")

            workspaceConnectButton(workspace)

            Button(action: { manager.removeWorkspace(workspace) }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Remove workspace")
        }
    }

    @ViewBuilder
    private func workspaceConnectButton(_ workspace: Workspace) -> some View {
        let hasConnected = workspace.forwards.contains { manager.states[$0.id] == .ready }
        if hasConnected {
            Button(action: { manager.disconnectWorkspace(workspace) }) {
                Image(systemName: "stop.fill")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Disconnect workspace")
        } else {
            Button(action: { manager.connectWorkspace(workspace) }) {
                Image(systemName: "play.fill")
                    .foregroundStyle(.green)
            }
            .buttonStyle(.borderless)
            .help("Connect workspace")
        }
    }

    private func addWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a workspace folder containing .portforwards.json"
        if panel.runModal() == .OK, let url = panel.url {
            manager.addWorkspace(path: url.path)
        }
    }

    private func workspaceForForward(_ forward: PortForward) -> Workspace? {
        manager.workspaces.first { $0.forwards.contains(where: { $0.id == forward.id }) }
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

    @State private var namespaces: [String] = []
    @State private var services: [KubeService] = []
    @State private var selectedNamespace: String = ""
    @State private var selectedService: String = ""
    @State private var selectedPort: Int = 0

    @State private var name: String = ""
    @State private var localPort: String = ""
    @State private var enabled: Bool = true
    @State private var sortOrder: String = "0"

    @State private var isLoadingNamespaces = false
    @State private var isLoadingServices = false
    @State private var errorMessage: String?

    private var isEditing: Bool { forward != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2).fontWeight(.semibold)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            formContent
            formButtons
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if isEditing {
                populateFromForward()
            } else {
                loadNamespaces()
            }
        }
    }

    @ViewBuilder
    private var formContent: some View {
        Form {
            if isEditing {
                editFields
            } else {
                discoveryFields
            }
            sharedFields
        }
    }

    private var editFields: some View {
        Group {
            TextField("Namespace", text: $selectedNamespace)
            TextField("Service", text: $selectedService)
            TextField("Remote Port", text: .init(
                get: { String(selectedPort) },
                set: { selectedPort = Int($0) ?? 0 }
            ))
        }
    }

    private var discoveryFields: some View {
        Group {
            namespacePicker
            if !selectedNamespace.isEmpty {
                servicePicker
            }
            if !selectedService.isEmpty && !services.isEmpty {
                portPicker
            }
        }
    }

    private var namespacePicker: some View {
        HStack {
            Picker("Namespace", selection: $selectedNamespace) {
                Text("Select...").tag("")
                ForEach(namespaces, id: \.self) { ns in
                    Text(ns).tag(ns)
                }
            }
            if isLoadingNamespaces {
                ProgressView().controlSize(.small)
            }
            Button(action: loadNamespaces) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh namespaces")
        }
        .onChange(of: selectedNamespace) {
            selectedService = ""
            selectedPort = 0
            services = []
            if !selectedNamespace.isEmpty {
                loadServices()
            }
        }
    }

    private var servicePicker: some View {
        HStack {
            Picker("Service", selection: $selectedService) {
                Text("Select...").tag("")
                ForEach(services, id: \.name) { svc in
                    Text(svc.name).tag(svc.name)
                }
            }
            if isLoadingServices {
                ProgressView().controlSize(.small)
            }
        }
        .onChange(of: selectedService) {
            if let svc = services.first(where: { $0.name == selectedService }),
               let firstPort = svc.ports.first {
                selectedPort = firstPort.port
                localPort = String(firstPort.port)
                if name.isEmpty {
                    name = "pf-\(selectedService)"
                }
            }
        }
    }

    private var portPicker: some View {
        Group {
            if let svc = services.first(where: { $0.name == selectedService }) {
                Section("Ports") {
                    ForEach(svc.ports, id: \.port) { p in
                        HStack {
                            Image(systemName: selectedPort == p.port ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedPort == p.port ? .blue : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Port \(p.port)")
                                    .fontWeight(selectedPort == p.port ? .semibold : .regular)
                                HStack(spacing: 8) {
                                    if let name = p.name, !name.isEmpty {
                                        Label(name, systemImage: portTypeIcon(name))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(p.protocol_)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("→ \(p.targetPort)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedPort = p.port
                            localPort = String(p.port)
                        }
                    }
                }
            }
        }
    }

    private func portTypeIcon(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("grpc") { return "arrow.left.arrow.right" }
        if lower.contains("http") { return "globe" }
        if lower.contains("web") { return "globe" }
        if lower.contains("metrics") { return "chart.bar" }
        return "network"
    }

    private var sharedFields: some View {
        Group {
            TextField("Name", text: $name)
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
                .disabled(name.isEmpty || selectedService.isEmpty || selectedNamespace.isEmpty || localPort.isEmpty || selectedPort == 0)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func loadNamespaces() {
        isLoadingNamespaces = true
        errorMessage = nil
        Task {
            do {
                let ns = try await KubectlDiscovery.fetchNamespaces()
                namespaces = ns
            } catch {
                errorMessage = "Failed to load namespaces: \(error.localizedDescription)"
            }
            isLoadingNamespaces = false
        }
    }

    private func loadServices() {
        isLoadingServices = true
        errorMessage = nil
        Task {
            do {
                let svcs = try await KubectlDiscovery.fetchServices(namespace: selectedNamespace)
                services = svcs
            } catch {
                errorMessage = "Failed to load services: \(error.localizedDescription)"
            }
            isLoadingServices = false
        }
    }

    private func populateFromForward() {
        guard let fwd = forward else { return }
        name = fwd.name
        selectedNamespace = fwd.namespace
        selectedService = fwd.service
        selectedPort = fwd.remotePort
        localPort = String(fwd.localPort)
        enabled = fwd.enabled
        sortOrder = String(fwd.sortOrder)
    }

    private func saveForward() {
        let fwd = PortForward(
            id: forward?.id ?? UUID(),
            name: name,
            service: selectedService,
            namespace: selectedNamespace,
            localPort: Int(localPort) ?? 0,
            remotePort: selectedPort,
            enabled: enabled,
            sortOrder: Int(sortOrder) ?? 0
        )
        onSave(fwd)
        dismiss()
    }
}
