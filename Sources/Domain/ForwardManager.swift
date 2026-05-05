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
    @Published public var forwards: [PortForward] = []
    @Published public var states: [UUID: ForwardState] = [:]
    @Published public var isConnectingAll = false

    private var runners: [UUID: ProcessRunning] = [:]
    private let configStore: ConfigStore
    private let runnerFactory: ProcessRunnerFactory
    private var connectAllTask: Task<Void, Never>?

    public init(configStore: ConfigStore, runnerFactory: ProcessRunnerFactory = DefaultProcessRunnerFactory()) {
        self.configStore = configStore
        self.runnerFactory = runnerFactory
        self.forwards = configStore.loadOrDefault().forwards
        for fwd in forwards {
            states[fwd.id] = .idle
        }
    }

    public func connectAll() {
        guard !isConnectingAll else { return }
        isConnectingAll = true

        connectAllTask = Task {
            let enabled = forwards
                .filter(\.enabled)
                .sorted { $0.sortOrder < $1.sortOrder }

            for fwd in enabled {
                if Task.isCancelled { break }
                if states[fwd.id] == .ready { continue }
                await connect(fwd)
            }
            isConnectingAll = false
        }
    }

    public func cancelConnectAll() {
        connectAllTask?.cancel()
        isConnectingAll = false
    }

    public func connect(_ forward: PortForward) async {
        let runner = runnerFactory.makeRunner(for: forward)
        runners[forward.id] = runner
        states[forward.id] = .starting

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

    public func disconnectAll() {
        cancelConnectAll()
        for fwd in forwards {
            disconnect(fwd)
        }
    }

    public func addForward(_ forward: PortForward) {
        forwards.append(forward)
        states[forward.id] = .idle
        saveConfig()
    }

    public func updateForward(_ forward: PortForward) {
        guard let index = forwards.firstIndex(where: { $0.id == forward.id }) else { return }
        forwards[index] = forward
        saveConfig()
    }

    public func deleteForward(_ forward: PortForward) {
        disconnect(forward)
        forwards.removeAll { $0.id == forward.id }
        states.removeValue(forKey: forward.id)
        saveConfig()
    }

    public func saveConfig() {
        let config = AppConfig(forwards: forwards)
        try? configStore.save(config)
    }
}
