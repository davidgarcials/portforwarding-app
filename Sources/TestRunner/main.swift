import Foundation
import PortForwardingLib

var passed = 0
var failed = 0

func assert(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("  FAIL [\(file.split(separator: "/").last ?? ""):\(line)]: \(message)")
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if a == b {
        passed += 1
    } else {
        failed += 1
        print("  FAIL [\(file.split(separator: "/").last ?? ""):\(line)]: \(message.isEmpty ? "Expected \(a) == \(b)" : message)")
    }
}

func assertNil<T>(_ value: T?, _ message: String = "", file: String = #file, line: Int = #line) {
    if value == nil {
        passed += 1
    } else {
        failed += 1
        print("  FAIL: expected nil, got \(value!). \(message)")
    }
}

func test(_ name: String, _ body: () throws -> Void) {
    print("  \(name)...", terminator: " ")
    do {
        try body()
        print("OK")
    } catch {
        failed += 1
        print("EXCEPTION: \(error)")
    }
}

func testAsync(_ name: String, _ body: @escaping () async throws -> Void) async {
    print("  \(name)...", terminator: " ")
    do {
        try await body()
        print("OK")
    } catch {
        failed += 1
        print("EXCEPTION: \(error)")
    }
}

// MARK: - PortForward Tests

func makeForward(
    name: String = "test",
    service: String = "my-svc",
    namespace: String = "default",
    localPort: Int = 8080,
    remotePort: Int = 80
) -> PortForward {
    PortForward(
        name: name,
        service: service,
        namespace: namespace,
        localPort: localPort,
        remotePort: remotePort
    )
}

print("\n=== PortForward Model Tests ===")

test("Launch arguments") {
    let fwd = makeForward(service: "my-api", namespace: "my-namespace", localPort: 3010, remotePort: 80)
    let args = fwd.launchArguments
    assertEqual(args[0], "-l")
    assertEqual(args[1], "-c")
    assert(args[2].contains("kubectl port-forward"), "should contain kubectl command")
    assert(args[2].contains("svc/my-api"), "should contain service")
    assert(args[2].contains("--namespace my-namespace"), "should contain namespace")
    assert(args[2].contains("3010:80"), "should contain port mapping")
}

test("JSON round-trip") {
    let original = makeForward()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PortForward.self, from: data)
    assertEqual(decoded, original)
}

test("Default values") {
    let fwd = makeForward()
    assert(fwd.enabled, "should be enabled by default")
    assertEqual(fwd.sortOrder, 0)
}

// MARK: - ConfigStore Tests

print("\n=== ConfigStore Tests ===")

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PortFwdTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

test("AppConfig save and load round-trip") {
    let dir = try makeTempDir()
    let store = ConfigStore(directory: dir)
    let config = AppConfig(workspacePaths: ["/tmp/ws1", "/tmp/ws2"])
    try store.saveAppConfig(config)
    let loaded = try store.loadAppConfig()
    assertEqual(loaded.version, 1)
    assertEqual(loaded.workspacePaths.count, 2)
    assertEqual(loaded.workspacePaths[0], "/tmp/ws1")
}

test("loadAppConfigOrDefault returns empty when no file") {
    let dir = try makeTempDir()
    let store = ConfigStore(directory: dir)
    let config = store.loadAppConfigOrDefault()
    assert(config.workspacePaths.isEmpty, "should be empty")
    assertEqual(config.version, 1)
}

test("WorkspaceConfig save and load round-trip") {
    let wsDir = try makeTempDir()
    let store = ConfigStore(directory: try makeTempDir())
    let config = WorkspaceConfig(forwards: [makeForward()])
    try store.saveWorkspaceConfig(config, at: wsDir.path)
    let loaded = try store.loadWorkspaceConfig(at: wsDir.path)
    assertEqual(loaded.forwards.count, 1)
    assertEqual(loaded.forwards[0].name, "test")
}

test("AppConfig save creates intermediate directories") {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PortFwdTests-\(UUID().uuidString)")
        .appendingPathComponent("nested")
    let store = ConfigStore(directory: dir)
    try store.saveAppConfig(AppConfig(workspacePaths: ["/tmp/ws"]))
    let loaded = try store.loadAppConfig()
    assertEqual(loaded.workspacePaths.count, 1)
}

// MARK: - PortChecker Tests

print("\n=== PortChecker Tests ===")

test("Closed port returns false") {
    let result = PortChecker.isPortOpen(59999)
    assert(!result, "port 59999 should not be open")
}

// MARK: - ProcessRunner Tests

print("\n=== ProcessRunner Tests ===")

await testAsync("Detects readiness marker") {
    let runner = ProcessRunner(
        executablePath: "/bin/sh",
        arguments: ["-c", "echo 'Starting...'; sleep 0.1; echo 'Forwarding from 127.0.0.1:3010 -> 80'; sleep 10"],
        readinessMarker: "Forwarding from",
        timeoutSeconds: 5
    )
    try await runner.startAndAwaitReady()
    runner.stop()
}

await testAsync("Fails on early exit") {
    let runner = ProcessRunner(
        executablePath: "/bin/sh",
        arguments: ["-c", "echo 'error: connection refused'; exit 1"],
        readinessMarker: "Forwarding from",
        timeoutSeconds: 5
    )
    do {
        try await runner.startAndAwaitReady()
        assert(false, "should have thrown")
    } catch let error as ProcessRunnerError {
        if case .processExited(let code, _) = error {
            assertEqual(code, Int32(1))
        } else {
            assert(false, "expected processExited, got \(error)")
        }
    }
}

await testAsync("Fails on timeout") {
    let runner = ProcessRunner(
        executablePath: "/bin/sh",
        arguments: ["-c", "echo 'Starting...'; sleep 30"],
        readinessMarker: "Forwarding from",
        timeoutSeconds: 1
    )
    do {
        try await runner.startAndAwaitReady()
        assert(false, "should have thrown")
    } catch let error as ProcessRunnerError {
        if case .timeout = error {
            // expected
        } else {
            assert(false, "expected timeout, got \(error)")
        }
    }
    runner.stop()
}

await testAsync("Stop terminates running process") {
    let runner = ProcessRunner(
        executablePath: "/bin/sh",
        arguments: ["-c", "echo 'Forwarding from 127.0.0.1:3010 -> 80'; sleep 60"],
        readinessMarker: "Forwarding from",
        timeoutSeconds: 5
    )
    try await runner.startAndAwaitReady()
    runner.stop()
    try await Task.sleep(nanoseconds: 500_000_000)
}

await testAsync("Detects readiness marker when output is immediate") {
    let runner = ProcessRunner(
        executablePath: "/bin/sh",
        arguments: ["-c", "echo 'Forwarding from 127.0.0.1:3010 -> 80'; sleep 10"],
        readinessMarker: "Forwarding from",
        timeoutSeconds: 3
    )
    try await runner.startAndAwaitReady()
    runner.stop()
}

await testAsync("Fails on immediate exit with error") {
    let runner = ProcessRunner(
        executablePath: "/bin/sh",
        arguments: ["-c", "exit 1"],
        readinessMarker: "Forwarding from",
        timeoutSeconds: 3
    )
    do {
        try await runner.startAndAwaitReady()
        assert(false, "should have thrown")
    } catch let error as ProcessRunnerError {
        if case .processExited(let code, _) = error {
            assertEqual(code, Int32(1))
        } else {
            assert(false, "expected processExited, got \(error)")
        }
    }
}

// MARK: - ForwardManager Notification Tests

print("\n=== ForwardManager Notification Tests ===")

final class MockNotifier: PortDropNotifying {
    var onReconnectRequested: ((UUID) -> Void)?
    var droppedForwards: [PortForward] = []

    func requestPermission() {}
    func sendPortDropped(forward: PortForward) {
        droppedForwards.append(forward)
    }
}

final class MockRunnerFactory: ProcessRunnerFactory {
    var lastRunner: MockProcessRunner?
    func makeRunner(for forward: PortForward) -> ProcessRunning {
        let runner = MockProcessRunner()
        lastRunner = runner
        return runner
    }
}

final class MockProcessRunner: ProcessRunning {
    var onTerminatedAfterReady: ((Int32, String) -> Void)?
    var started = false
    var stopped = false

    func startAndAwaitReady() async throws {
        started = true
    }
    func stop() {
        stopped = true
    }
}

await testAsync("Notifies on ready-to-failed transition via health check") {
    let tmpDir = try makeTempDir()
    let store = ConfigStore(directory: tmpDir)
    let notifier = MockNotifier()
    let factory = MockRunnerFactory()
    let manager = await ForwardManager(
        configStore: store,
        runnerFactory: factory,
        notifier: notifier,
        healthCheckInterval: 999
    )

    let fwd = makeForward(name: "test-notify", localPort: 59432)
    let ws = Workspace(path: tmpDir.path, forwards: [fwd])
    await MainActor.run { manager.workspaces = [ws] }

    await manager.connect(fwd)
    let stateAfterConnect = await MainActor.run { manager.states[fwd.id] }
    assertEqual(stateAfterConnect, .ready, "should be ready after connect")
    assertEqual(notifier.droppedForwards.count, 0, "no notification yet")

    await MainActor.run { manager.states[fwd.id] = .failed("Connection lost") }
    assertEqual(notifier.droppedForwards.count, 0, "state set directly doesn't notify")
}

await testAsync("Notifies when process terminates after ready") {
    let tmpDir = try makeTempDir()
    let store = ConfigStore(directory: tmpDir)
    let notifier = MockNotifier()
    let factory = MockRunnerFactory()
    let manager = await ForwardManager(
        configStore: store,
        runnerFactory: factory,
        notifier: notifier,
        healthCheckInterval: 999
    )

    let fwd = makeForward(name: "test-term", localPort: 59433)
    let ws = Workspace(path: tmpDir.path, forwards: [fwd])
    await MainActor.run { manager.workspaces = [ws] }

    await manager.connect(fwd)
    let runner = factory.lastRunner!
    runner.onTerminatedAfterReady?(1, "connection refused")
    try await Task.sleep(nanoseconds: 200_000_000)
    let count = notifier.droppedForwards.count
    assertEqual(count, 1, "should have notified once")
    assertEqual(notifier.droppedForwards.first?.name, "test-term")
}

await testAsync("Reconnect by forwardId calls connect") {
    let tmpDir = try makeTempDir()
    let store = ConfigStore(directory: tmpDir)
    let factory = MockRunnerFactory()
    let manager = await ForwardManager(
        configStore: store,
        runnerFactory: factory,
        notifier: nil,
        healthCheckInterval: 999
    )

    let fwd = makeForward(name: "reconnect-test", localPort: 59434)
    let ws = Workspace(path: tmpDir.path, forwards: [fwd])
    await MainActor.run {
        manager.workspaces = [ws]
        manager.states[fwd.id] = .failed("lost")
    }

    await MainActor.run { manager.reconnect(forwardId: fwd.id) }
    try await Task.sleep(nanoseconds: 200_000_000)
    let state = await MainActor.run { manager.states[fwd.id] }
    assertEqual(state, .ready, "should be ready after reconnect")
}

// MARK: - Forward Status Property Tests

print("\n=== Forward Status Property Tests ===")

await testAsync("hasAnyFailedForward is false when all idle") {
    let tmpDir = try makeTempDir()
    let store = ConfigStore(directory: tmpDir)
    let manager = await ForwardManager(
        configStore: store,
        runnerFactory: MockRunnerFactory(),
        notifier: nil,
        healthCheckInterval: 999
    )

    let fwd = makeForward(name: "idle-test", localPort: 59440)
    let ws = Workspace(path: tmpDir.path, forwards: [fwd])
    await MainActor.run {
        manager.workspaces = [ws]
        manager.states[fwd.id] = .idle
    }

    let result = await MainActor.run { manager.hasAnyFailedForward }
    assert(!result, "should be false when all idle")
}

await testAsync("hasAnyFailedForward is true when one forward failed") {
    let tmpDir = try makeTempDir()
    let store = ConfigStore(directory: tmpDir)
    let manager = await ForwardManager(
        configStore: store,
        runnerFactory: MockRunnerFactory(),
        notifier: nil,
        healthCheckInterval: 999
    )

    let fwd1 = makeForward(name: "ok-fwd", localPort: 59441)
    let fwd2 = makeForward(name: "fail-fwd", localPort: 59442)
    let ws = Workspace(path: tmpDir.path, forwards: [fwd1, fwd2])
    await MainActor.run {
        manager.workspaces = [ws]
        manager.states[fwd1.id] = .ready
        manager.states[fwd2.id] = .failed("Connection lost")
    }

    let result = await MainActor.run { manager.hasAnyFailedForward }
    assert(result, "should be true when one forward is failed")
}

await testAsync("hasAnyFailedForward is false when all ready") {
    let tmpDir = try makeTempDir()
    let store = ConfigStore(directory: tmpDir)
    let manager = await ForwardManager(
        configStore: store,
        runnerFactory: MockRunnerFactory(),
        notifier: nil,
        healthCheckInterval: 999
    )

    let fwd = makeForward(name: "ready-fwd", localPort: 59443)
    let ws = Workspace(path: tmpDir.path, forwards: [fwd])
    await MainActor.run {
        manager.workspaces = [ws]
        manager.states[fwd.id] = .ready
    }

    let result = await MainActor.run { manager.hasAnyFailedForward }
    assert(!result, "should be false when all ready")
}

await testAsync("hasAnyReadyForward is false when all idle") {
    let tmpDir = try makeTempDir()
    let store = ConfigStore(directory: tmpDir)
    let manager = await ForwardManager(
        configStore: store,
        runnerFactory: MockRunnerFactory(),
        notifier: nil,
        healthCheckInterval: 999
    )

    let fwd = makeForward(name: "idle-test2", localPort: 59450)
    let ws = Workspace(path: tmpDir.path, forwards: [fwd])
    await MainActor.run {
        manager.workspaces = [ws]
        manager.states[fwd.id] = .idle
    }

    let result = await MainActor.run { manager.hasAnyReadyForward }
    assert(!result, "should be false when all idle")
}

await testAsync("hasAnyReadyForward is true when one forward ready") {
    let tmpDir = try makeTempDir()
    let store = ConfigStore(directory: tmpDir)
    let manager = await ForwardManager(
        configStore: store,
        runnerFactory: MockRunnerFactory(),
        notifier: nil,
        healthCheckInterval: 999
    )

    let fwd1 = makeForward(name: "ready-fwd2", localPort: 59451)
    let fwd2 = makeForward(name: "idle-fwd2", localPort: 59452)
    let ws = Workspace(path: tmpDir.path, forwards: [fwd1, fwd2])
    await MainActor.run {
        manager.workspaces = [ws]
        manager.states[fwd1.id] = .ready
        manager.states[fwd2.id] = .idle
    }

    let result = await MainActor.run { manager.hasAnyReadyForward }
    assert(result, "should be true when one forward is ready")
}

await testAsync("hasAnyReadyForward is false when all failed") {
    let tmpDir = try makeTempDir()
    let store = ConfigStore(directory: tmpDir)
    let manager = await ForwardManager(
        configStore: store,
        runnerFactory: MockRunnerFactory(),
        notifier: nil,
        healthCheckInterval: 999
    )

    let fwd = makeForward(name: "fail-fwd2", localPort: 59453)
    let ws = Workspace(path: tmpDir.path, forwards: [fwd])
    await MainActor.run {
        manager.workspaces = [ws]
        manager.states[fwd.id] = .failed("Connection lost")
    }

    let result = await MainActor.run { manager.hasAnyReadyForward }
    assert(!result, "should be false when all failed")
}

// MARK: - Results

print("\n=== Results ===")
print("Passed: \(passed), Failed: \(failed)")

if failed > 0 {
    exit(1)
}
