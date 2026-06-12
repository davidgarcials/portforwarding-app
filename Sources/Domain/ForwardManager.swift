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
    @Published public var autoReconnect: Bool {
        didSet {
            saveAppConfig()
            if !autoReconnect { cancelAllReconnects() }
        }
    }

    private var runners: [UUID: ProcessRunning] = [:]
    private let configStore: ConfigStore
    private let runnerFactory: ProcessRunnerFactory
    private let credentialRefresher: CredentialRefreshing
    private let notifier: PortDropNotifying?
    private var connectAllTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private let healthCheckInterval: TimeInterval
    private let maxReconnectAttempts: Int
    private let reconnectDelay: TimeInterval
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]

    private static let credentialErrorPatterns = [
        "getting credentials",
        "you must be logged in",
    ]

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
        credentialRefresher: CredentialRefreshing = KubectlCredentialRefresher(),
        notifier: PortDropNotifying? = nil,
        healthCheckInterval: TimeInterval = 10,
        maxReconnectAttempts: Int = 5,
        reconnectDelay: TimeInterval = 3
    ) {
        self.configStore = configStore
        self.runnerFactory = runnerFactory
        self.credentialRefresher = credentialRefresher
        self.notifier = notifier
        self.healthCheckInterval = healthCheckInterval
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectDelay = reconnectDelay
        self.autoReconnect = configStore.loadAppConfigOrDefault().autoReconnect
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

        states[forward.id] = .starting

        guard let error = await attemptConnect(forward) else { return }

        if isCredentialError(error) {
            states[forward.id] = .authenticating
            guard await credentialRefresher.refresh() else {
                states[forward.id] = .failed(error.localizedDescription)
                return
            }
            states[forward.id] = .starting
            if let retryError = await attemptConnect(forward) {
                states[forward.id] = .failed(retryError.localizedDescription)
            }
        } else {
            states[forward.id] = .failed(error.localizedDescription)
        }
    }

    private func attemptConnect(_ forward: PortForward) async -> Error? {
        let runner = runnerFactory.makeRunner(for: forward)
        runners[forward.id] = runner

        runner.onTerminatedAfterReady = { [weak self] code, reason in
            Task { @MainActor [weak self] in
                self?.handleDrop(forward, reason: "Disconnected (exit \(code)): \(reason)")
            }
        }

        do {
            try await runner.startAndAwaitReady()
            states[forward.id] = .ready
            return nil
        } catch {
            runners[forward.id] = nil
            return error
        }
    }

    private func isCredentialError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return Self.credentialErrorPatterns.contains { message.contains($0) }
    }

    public func disconnect(_ forward: PortForward) {
        reconnectTasks[forward.id]?.cancel()
        reconnectTasks[forward.id] = nil
        runners[forward.id]?.stop()
        runners[forward.id] = nil
        states[forward.id] = .stopped
    }

    public func reconnect(forwardId: UUID) {
        guard let forward = allForwards.first(where: { $0.id == forwardId }) else { return }
        Task { await connect(forward) }
    }

    // MARK: - Drop handling / auto-reconnect

    private func handleDrop(_ forward: PortForward, reason: String) {
        runners[forward.id]?.stop()
        runners[forward.id] = nil
        guard autoReconnect else {
            states[forward.id] = .failed(reason)
            notifier?.sendPortDropped(forward: forward)
            return
        }
        startReconnect(forward)
    }

    private func startReconnect(_ forward: PortForward) {
        guard reconnectTasks[forward.id] == nil else { return }  // dedupe simultaneous drop signals
        states[forward.id] = .starting                           // reflect "reconnecting"; health check skips it
        reconnectTasks[forward.id] = Task {
            // Runs on every exit. On cancellation (manual disconnect or auto-reconnect
            // turned off) tear down whatever this attempt produced — wherever we stopped,
            // including mid-sleep — so the forward never gets stuck showing "Connecting…".
            defer {
                reconnectTasks[forward.id] = nil
                if Task.isCancelled {
                    runners[forward.id]?.stop()
                    runners[forward.id] = nil
                    states[forward.id] = .stopped
                }
            }
            for _ in 0..<maxReconnectAttempts {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: UInt64(reconnectDelay * 1_000_000_000))
                if Task.isCancelled { return }
                await connect(forward)  // waits for the user to authenticate inside connect()
                if Task.isCancelled { return }
                if states[forward.id] == .ready { return }
            }
            states[forward.id] = .failed("Reconnect failed after \(maxReconnectAttempts) attempts")
            notifier?.sendPortDropped(forward: forward)
        }
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

    @discardableResult
    public func importForwards(_ forwards: [PortForward], to workspace: Workspace) -> Int {
        guard let wsIdx = workspaces.firstIndex(where: { $0.path == workspace.path }) else { return 0 }
        let existingPorts = Set(workspaces[wsIdx].forwards.map(\.localPort))
        var imported = 0

        for fwd in forwards {
            if existingPorts.contains(fwd.localPort) { continue }
            var newFwd = fwd
            newFwd.id = UUID()
            workspaces[wsIdx].forwards.append(newFwd)
            states[newFwd.id] = .idle
            imported += 1
        }

        if imported > 0 {
            saveWorkspaceConfig(workspaces[wsIdx])
        }
        return imported
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
        let config = AppConfig(workspacePaths: workspaces.map(\.path), autoReconnect: autoReconnect)
        try? configStore.saveAppConfig(config)
    }

    private func cancelAllReconnects() {
        for (_, task) in reconnectTasks { task.cancel() }
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
                    handleDrop(fwd, reason: "Connection lost")
                }
            case .idle, .stopped, .failed:
                if portOpen && runners[fwd.id] == nil {
                    states[fwd.id] = .ready
                }
            case .starting, .authenticating:
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
