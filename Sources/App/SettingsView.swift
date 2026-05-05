import SwiftUI
import PortForwardingLib

struct SettingsView: View {
    @ObservedObject var manager: ForwardManager
    @State private var showingAddSheet = false
    @State private var editingForward: PortForward?

    var body: some View {
        VStack {
            forwardList
            addButton
        }
        .frame(minWidth: 600, minHeight: 400)
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

    private var forwardList: some View {
        List {
            ForEach(manager.forwards.sorted(by: { $0.sortOrder < $1.sortOrder })) { forward in
                ForwardSettingsRow(forward: forward) {
                    editingForward = forward
                } onDelete: {
                    manager.deleteForward(forward)
                }
            }
        }
    }

    private var addButton: some View {
        HStack {
            Button("Add Forward") {
                showingAddSheet = true
            }
            Spacer()
        }
        .padding()
    }
}

struct ForwardSettingsRow: View {
    let forward: PortForward
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(forward.name).font(.headline)
                Text("svc/\(forward.service) (\(forward.namespace)) → localhost:\(forward.localPort)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
        }
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
