import Foundation

public protocol ProcessRunning: AnyObject {
    func startAndAwaitReady() async throws
    func stop()
}

public final class ProcessRunner: ProcessRunning, @unchecked Sendable {
    private let executablePath: String
    private let arguments: [String]
    private let readinessMarker: String
    private let timeoutSeconds: Double

    private var process: Process?
    private let lock = NSLock()
    private var lastLines: [String] = []
    private let maxLastLines = 10

    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var continuationResolved = false

    public init(
        executablePath: String = "/usr/local/bin/kubectl",
        arguments: [String],
        readinessMarker: String = "Forwarding from",
        timeoutSeconds: Double = 60
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.readinessMarker = readinessMarker
        self.timeoutSeconds = timeoutSeconds
    }

    public convenience init(forward: PortForward, timeoutSeconds: Double = 60) {
        self.init(
            arguments: forward.launchArguments,
            timeoutSeconds: timeoutSeconds
        )
    }

    public func startAndAwaitReady() async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        lock.lock()
        self.process = proc
        self.continuationResolved = false
        lock.unlock()

        proc.terminationHandler = { [weak self] terminatedProc in
            self?.handleTermination(terminatedProc)
        }

        try proc.run()

        setupPipeReading(stdoutPipe)
        setupPipeReading(stderrPipe)

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.handleTimeout()
        }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + timeoutSeconds,
            execute: timeoutWorkItem
        )

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if continuationResolved {
                lock.unlock()
                return
            }
            self.readyContinuation = cont
            lock.unlock()
        }

        timeoutWorkItem.cancel()
    }

    public func stop() {
        lock.lock()
        let proc = process
        lock.unlock()

        guard let proc, proc.isRunning else { return }
        proc.terminate()

        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if proc.isRunning { proc.interrupt() }
        }
    }

    private func setupPipeReading(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            guard let self else {
                fh.readabilityHandler = nil
                return
            }
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                self.handleLine(line)
            }
        }
    }

    private func handleLine(_ line: String) {
        lock.lock()
        lastLines.append(line)
        if lastLines.count > maxLastLines {
            lastLines.removeFirst()
        }
        let isReady = line.contains(readinessMarker)
        lock.unlock()

        if isReady {
            resolveOnce { cont in
                cont.resume()
            }
        }
    }

    private func handleTermination(_ proc: Process) {
        lock.lock()
        let reason = lastLines.suffix(5).joined(separator: "\n")
        let status = proc.terminationStatus
        lock.unlock()

        resolveOnce { cont in
            cont.resume(throwing: ProcessRunnerError.processExited(
                code: status,
                output: reason.isEmpty ? "Process terminated" : reason
            ))
        }
    }

    private func handleTimeout() {
        resolveOnce { [weak self] cont in
            let seconds = self?.timeoutSeconds ?? 0
            cont.resume(throwing: ProcessRunnerError.timeout(seconds))
        }
    }

    private func resolveOnce(_ block: (CheckedContinuation<Void, Error>) -> Void) {
        lock.lock()
        guard !continuationResolved else {
            lock.unlock()
            return
        }
        continuationResolved = true
        let cont = readyContinuation
        readyContinuation = nil
        lock.unlock()

        if let cont {
            block(cont)
        }
    }
}

public enum ProcessRunnerError: LocalizedError, Equatable {
    case timeout(Double)
    case processExited(code: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let seconds):
            return "Timed out after \(Int(seconds))s waiting for tunnel"
        case .processExited(let code, let output):
            return "Process exited with code \(code): \(output)"
        }
    }
}
