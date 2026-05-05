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
    remoteHost: String? = nil,
    remotePort: Int = 5432,
    localPort: Int = 5432,
    target: String = "i-0abc123",
    awsProfile: String = "prod",
    region: String = "eu-west-1"
) -> PortForward {
    PortForward(
        name: "test",
        awsProfile: awsProfile,
        region: region,
        target: target,
        remoteHost: remoteHost,
        remotePort: remotePort,
        localPort: localPort
    )
}

print("\n=== PortForward Model Tests ===")

test("Direct mode when remoteHost is nil") {
    let fwd = makeForward()
    assert(!fwd.isRemoteHostMode, "should not be remote host mode")
    assertEqual(fwd.documentName, "AWS-StartPortForwardingSession")
}

test("Direct mode when remoteHost is empty") {
    let fwd = makeForward(remoteHost: "")
    assert(!fwd.isRemoteHostMode, "empty string should be direct mode")
}

test("Remote host mode") {
    let fwd = makeForward(remoteHost: "mydb.rds.amazonaws.com")
    assert(fwd.isRemoteHostMode, "should be remote host mode")
    assertEqual(fwd.documentName, "AWS-StartPortForwardingSessionToRemoteHost")
}

test("SSM parameters direct mode") {
    let fwd = makeForward(remotePort: 3306, localPort: 3307)
    let params = fwd.ssmParameters
    assertEqual(params["portNumber"], ["3306"])
    assertEqual(params["localPortNumber"], ["3307"])
    assertNil(params["host"])
}

test("SSM parameters remote host mode") {
    let fwd = makeForward(remoteHost: "mydb.rds.amazonaws.com", remotePort: 5432, localPort: 5433)
    let params = fwd.ssmParameters
    assertEqual(params["host"], ["mydb.rds.amazonaws.com"])
    assertEqual(params["portNumber"], ["5432"])
    assertEqual(params["localPortNumber"], ["5433"])
}

test("Launch arguments direct mode") {
    let fwd = makeForward(target: "i-0abc", awsProfile: "prod", region: "eu-west-1")
    let args = fwd.launchArguments
    assertEqual(args[0], "exec")
    assertEqual(args[1], "prod")
    assertEqual(args[2], "--")
    assert(args.contains("--target"), "should contain --target")
    assert(args.contains("i-0abc"), "should contain target ID")
    assert(args.contains("AWS-StartPortForwardingSession"), "should contain document name")
}

test("Launch arguments remote host mode") {
    let fwd = makeForward(remoteHost: "mydb.rds.amazonaws.com")
    assert(fwd.launchArguments.contains("AWS-StartPortForwardingSessionToRemoteHost"), "should use remote host document")
}

test("JSON round-trip") {
    let original = makeForward(remoteHost: "mydb.rds.amazonaws.com")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(PortForward.self, from: data)
    assertEqual(decoded, original)
}

// MARK: - ConfigStore Tests

print("\n=== ConfigStore Tests ===")

func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("PortFwdTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

test("Save and load round-trip") {
    let dir = try makeTempDir()
    let store = ConfigStore(directory: dir)
    let config = AppConfig(forwards: [makeForward()])
    try store.save(config)
    let loaded = try store.load()
    assertEqual(loaded.version, 1)
    assertEqual(loaded.forwards.count, 1)
    assertEqual(loaded.forwards[0].name, "test")
}

test("loadOrDefault returns empty when no file") {
    let dir = try makeTempDir()
    let store = ConfigStore(directory: dir)
    let config = store.loadOrDefault()
    assert(config.forwards.isEmpty, "should be empty")
    assertEqual(config.version, 1)
}

test("Save creates intermediate directories") {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PortFwdTests-\(UUID().uuidString)")
        .appendingPathComponent("nested")
    let store = ConfigStore(directory: dir)
    try store.save(AppConfig(forwards: [makeForward()]))
    let loaded = try store.load()
    assertEqual(loaded.forwards.count, 1)
}

test("Overwrite preserves integrity") {
    let dir = try makeTempDir()
    let store = ConfigStore(directory: dir)
    try store.save(AppConfig(forwards: [
        PortForward(name: "first", awsProfile: "p", region: "r", target: "t", remotePort: 1, localPort: 1)
    ]))
    try store.save(AppConfig(forwards: [
        PortForward(name: "second", awsProfile: "p", region: "r", target: "t", remotePort: 1, localPort: 1),
        PortForward(name: "third", awsProfile: "p", region: "r", target: "t", remotePort: 2, localPort: 2),
    ]))
    let loaded = try store.load()
    assertEqual(loaded.forwards.count, 2)
    assertEqual(loaded.forwards[0].name, "second")
}

// MARK: - ProcessRunner Tests

print("\n=== ProcessRunner Tests ===")

await testAsync("Detects readiness marker") {
    let runner = ProcessRunner(
        executablePath: "/bin/sh",
        arguments: ["-c", "echo 'Starting...'; sleep 0.1; echo 'Waiting for connections...'; sleep 10"],
        timeoutSeconds: 5
    )
    try await runner.startAndAwaitReady()
    runner.stop()
}

await testAsync("Fails on early exit") {
    let runner = ProcessRunner(
        executablePath: "/bin/sh",
        arguments: ["-c", "echo 'error'; exit 1"],
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
        arguments: ["-c", "echo 'Waiting for connections...'; sleep 60"],
        timeoutSeconds: 5
    )
    try await runner.startAndAwaitReady()
    runner.stop()
    try await Task.sleep(nanoseconds: 500_000_000)
}

// MARK: - Results

print("\n=== Results ===")
print("Passed: \(passed), Failed: \(failed)")

if failed > 0 {
    exit(1)
}
