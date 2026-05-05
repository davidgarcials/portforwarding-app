import XCTest
@testable import PortForwardingLib

final class ProcessRunnerTests: XCTestCase {

    func testDetectsReadinessMarker() async throws {
        let runner = ProcessRunner(
            executablePath: "/bin/sh",
            arguments: ["-c", """
                echo "Starting session..."
                sleep 0.1
                echo "Port 5432 opened for sessionId abc123"
                echo "Waiting for connections..."
                sleep 10
                """],
            timeoutSeconds: 5
        )

        try await runner.startAndAwaitReady()
        runner.stop()
    }

    func testFailsWhenProcessExitsBeforeReadiness() async {
        let runner = ProcessRunner(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo 'error: something went wrong'; exit 1"],
            timeoutSeconds: 5
        )

        do {
            try await runner.startAndAwaitReady()
            XCTFail("Expected ProcessRunnerError")
        } catch let error as ProcessRunnerError {
            if case .processExited(let code, _) = error {
                XCTAssertEqual(code, 1)
            } else {
                XCTFail("Expected processExited but got \(error)")
            }
        }
    }

    func testFailsOnTimeout() async {
        let runner = ProcessRunner(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo 'Starting...'; sleep 30"],
            timeoutSeconds: 1
        )

        do {
            try await runner.startAndAwaitReady()
            XCTFail("Expected timeout")
        } catch let error as ProcessRunnerError {
            if case .timeout = error {
                // expected
            } else {
                XCTFail("Expected timeout but got \(error)")
            }
        }

        runner.stop()
    }

    func testStopTerminatesProcess() async throws {
        let runner = ProcessRunner(
            executablePath: "/bin/sh",
            arguments: ["-c", """
                echo "Waiting for connections..."
                sleep 60
                """],
            timeoutSeconds: 5
        )

        try await runner.startAndAwaitReady()
        runner.stop()
        try await Task.sleep(nanoseconds: 500_000_000)
    }
}
