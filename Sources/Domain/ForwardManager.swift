import Foundation

public protocol ProcessRunnerFactory {
    func makeRunner(for forward: PortForward) -> ProcessRunning
}

public struct DefaultProcessRunnerFactory: ProcessRunnerFactory {
    public init() {}
    public func makeRunner(for forward: PortForward) -> ProcessRunning {
        ProcessRunner(forward: forward)
    }
}

@MainActor
public final class ForwardManager: ObservableObject {
    @Published public var workspaces: [Workspace] = []
    @Published public var states: [UUID: ForwardState] = [:]
    @Published public var isConnectingAll = false

    private var runners: [UUID: ProcessRunning] = [:]
    private let configStore: ConfigStore
    private let runnerFactory: ProcessRunnerFactory
    private let notifier: PortDropNotifying?
    private var connectAllTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private let healthCheckInterval: TimeInterval

    public var allForwards: [PortForward] {
        workspaces.flatMap(\.forwards)
    }

    public var hasAnyFailedForward: Bool {
        states.values.contains { if case .failed = $0 { return true } else { return false } }
    }

    public var hasAnyReadyForward: Bool {
        states.values.contains { $0 == .ready }
    }

    public init(
        configStore: ConfigStore,
        runnerFactory: ProcessRunnerFactory = DefaultProcessRunnerFactory(),
        notifier: PortDropNotifying? = nil,
        healthCheckInterval: TimeInterval = 10
    ) {
        self.configStore = configStore
        self.runnerFactory = runnerFactory
        self.notifier = notifier
        self.healthCheckInterval = healthCheckInterval
        self.workspaces = configStore.loadAllWorkspaces()
        for fwd in allForwards {
            states[fwd.id] = .idle
        }
        checkInitialPortStates()
        startHealthCheck()
    }

    // MARK: - Workspace management

    public func addWorkspace(path: String) {
        guard !workspaces.contains(where: { $0.path == path }) else { return }
        let ws = Workspace(path: path, forwards: configStore.loadWorkspaceConfigOrDefault(at: path).forwards)
        workspaces.append(ws)
        for fwd in ws.forwards {
            states[fwd.id] = .idle
        }
        checkInitialPortStates()
        saveAppConfig()
    }

    public func removeWorkspace(_ workspace: Workspace) {
        for fwd in workspace.forwards {
            disconnect(fwd)
            states.removeValue(forKey: fwd.id)
        }
        workspaces.removeAll { $0.path == workspace.path }
        saveAppConfig()
    }

    // MARK: - Connect / Disconnect

    public func connectAll() {
        guard !isConnectingAll else { return }
        isConnectingAll = true

        connectAllTask = Task {
            let enabled = allForwards
                .filter(\.enabled)
                .sorted { $0.sortOrder < $1.sortOrder }

            for fwd in enabled {
                if Task.isCancelled { break }
                if states[fwd.id] == .ready { continue }
                if hasPortConflict(fwd) {
                    states[fwd.id] = .failed("Port \(fwd.localPort) already in use by another forward")
                    continue
                }
                await connect(fwd)
            }
            isConnectingAll = false
        }
    }

    public func connectWorkspace(_ workspace: Workspace) {
        Task {
            let enabled = workspace.forwards
                .filter(\.enabled)
                .sorted { $0.sortOrder < $1.sortOrder }

            for fwd in enabled {
                if states[fwd.id] == .ready { continue }
                if hasPortConflict(fwd) {
                    states[fwd.id] = .failed("Port \(fwd.localPort) already in use by another forward")
                    continue
                }
                await connect(fwd)
            }
        }
    }

    public func disconnectWorkspace(_ workspace: Workspace) {
        for fwd in workspace.forwards {
            disconnect(fwd)
        }
    }

    public func cancelConnectAll() {
        connectAllTask?.cancel()
        isConnectingAll = false
    }

    public func connect(_ forward: PortForward) async {
        if hasPortConflict(forward) {
            states[forward.id] = .failed("Port \(forward.localPort) already in use by another forward")
            return
        }

        let runner = runnerFactory.makeRunner(for: forward)
        runners[forward.id] = runner
        states[forward.id] = .starting

        runner.onTerminatedAfterReady = { [weak self] code, reason in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.runners[forward.id] = nil
                self.states[forward.id] = .failed("Disconnected (exit \(code)): \(reason)")
                self.notifier?.sendPortDropped(forward: forward)
            }
        }

        do {
            try await runner.startAndAwaitReady()
            states[forward.id] = .ready
        } catch {
            states[forward.id] = .failed(error.localizedDescription)
        }
    }

    public func disconnect(_ forward: PortForward) {
        runners[forward.id]?.stop()
        runners[forward.id] = nil
        states[forward.id] = .stopped
    }

    public func reconnect(forwardId: UUID) {
        guard let forward = allForwards.first(where: { $0.id == forwardId }) else { return }
        Task { await connect(forward) }
    }

    public func disconnectAll() {
        cancelConnectAll()
        for fwd in allForwards {
            disconnect(fwd)
        }
    }

    // MARK: - CRUD on forwards within a workspace

    public func addForward(_ forward: PortForward, to workspace: Workspace) {
        guard let idx = workspaces.firstIndex(where: { $0.path == workspace.path }) else { return }
        workspaces[idx].forwards.append(forward)
        states[forward.id] = .idle
        saveWorkspaceConfig(workspaces[idx])
    }

    public func updateForward(_ forward: PortForward, in workspace: Workspace) {
        guard let wsIdx = workspaces.firstIndex(where: { $0.path == workspace.path }),
              let fwdIdx = workspaces[wsIdx].forwards.firstIndex(where: { $0.id == forward.id })
        else { return }
        workspaces[wsIdx].forwards[fwdIdx] = forward
        saveWorkspaceConfig(workspaces[wsIdx])
    }

    public func deleteForward(_ forward: PortForward, from workspace: Workspace) {
        guard let wsIdx = workspaces.firstIndex(where: { $0.path == workspace.path }) else { return }
        disconnect(forward)
        workspaces[wsIdx].forwards.removeAll { $0.id == forward.id }
        states.removeValue(forKey: forward.id)
        saveWorkspaceConfig(workspaces[wsIdx])
    }

    // MARK: - Persistence

    private func saveAppConfig() {
        let config = AppConfig(workspacePaths: workspaces.map(\.path))
        try? configStore.saveAppConfig(config)
    }

    private func saveWorkspaceConfig(_ workspace: Workspace) {
        let config = WorkspaceConfig(forwards: workspace.forwards)
        try? configStore.saveWorkspaceConfig(config, at: workspace.path)
    }

    // MARK: - Health checks

    private func checkInitialPortStates() {
        var seenPorts = Set<Int>()
        for fwd in allForwards.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if seenPorts.contains(fwd.localPort) { continue }
            if PortChecker.isPortOpen(fwd.localPort) {
                states[fwd.id] = .ready
            }
            seenPorts.insert(fwd.localPort)
        }
    }

    private func startHealthCheck() {
        healthCheckTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(healthCheckInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                runHealthCheck()
            }
        }
    }

    private func runHealthCheck() {
        for fwd in allForwards {
            let current = states[fwd.id] ?? .idle
            let portOpen = PortChecker.isPortOpen(fwd.localPort)

            switch current {
            case .ready:
                if !portOpen {
                    runners[fwd.id]?.stop()
                    runners[fwd.id] = nil
                    states[fwd.id] = .failed("Connection lost")
                    notifier?.sendPortDropped(forward: fwd)
                }
            case .idle, .stopped, .failed:
                if portOpen && runners[fwd.id] == nil {
                    states[fwd.id] = .ready
                }
            case .starting:
                break
            }
        }
    }

    private func hasPortConflict(_ forward: PortForward) -> Bool {
        for fwd in allForwards where fwd.id != forward.id && fwd.localPort == forward.localPort {
            if states[fwd.id] == .ready || states[fwd.id] == .starting {
                return true
            }
        }
        return false
    }
}
