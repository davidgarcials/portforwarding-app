import Foundation

public protocol ProcessRunning: AnyObject {
    func startAndAwaitReady() async throws
    func stop()
    var onTerminatedAfterReady: ((Int32, String) -> Void)? { get set }
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
    private var isReady = false
    private var pendingResult: Result<Void, Error>?

    public var onTerminatedAfterReady: ((Int32, String) -> Void)?

    public init(
        executablePath: String = "/bin/zsh",
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
        self.isReady = false
        self.pendingResult = nil
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
            if let result = pendingResult {
                pendingResult = nil
                lock.unlock()
                cont.resume(with: result)
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
        let matched = line.contains(readinessMarker)
        lock.unlock()

        if matched {
            resolveOnce(result: .success(()))
        }
    }

    private func handleTermination(_ proc: Process) {
        lock.lock()
        let reason = lastLines.suffix(5).joined(separator: "\n")
        let status = proc.terminationStatus
        let wasReady = isReady
        lock.unlock()

        if wasReady {
            onTerminatedAfterReady?(status, reason.isEmpty ? "Process terminated" : reason)
        } else {
            resolveOnce(result: .failure(ProcessRunnerError.processExited(
                code: status,
                output: reason.isEmpty ? "Process terminated" : reason
            )))
        }
    }

    private func handleTimeout() {
        resolveOnce(result: .failure(ProcessRunnerError.timeout(timeoutSeconds)))
    }

    private func resolveOnce(result: Result<Void, Error>) {
        lock.lock()
        guard !continuationResolved else {
            lock.unlock()
            return
        }
        continuationResolved = true
        if case .success = result { isReady = true }
        let cont = readyContinuation
        readyContinuation = nil
        if cont == nil {
            pendingResult = result
        }
        lock.unlock()

        if let cont {
            cont.resume(with: result)
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
