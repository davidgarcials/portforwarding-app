import Foundation

public enum ProcessEnvironment {
    private static let lock = NSLock()
    private static var cached: [String: String]?

    public static func resolved() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        var env = ProcessInfo.processInfo.environment
        var pathDirs = env["PATH"]?.components(separatedBy: ":") ?? []

        for dir in systemPathDirs() where !pathDirs.contains(dir) {
            pathDirs.append(dir)
        }

        if let shellPath = resolveShellPath() {
            for dir in shellPath.components(separatedBy: ":") where !dir.isEmpty && !pathDirs.contains(dir) {
                pathDirs.append(dir)
            }
        }

        env["PATH"] = pathDirs.joined(separator: ":")
        cached = env
        return env
    }

    private static func systemPathDirs() -> [String] {
        var dirs: [String] = []

        if let data = FileManager.default.contents(atPath: "/etc/paths"),
           let content = String(data: data, encoding: .utf8) {
            dirs.append(contentsOf: content.components(separatedBy: .newlines).filter { !$0.isEmpty })
        }

        if let entries = try? FileManager.default.contentsOfDirectory(atPath: "/etc/paths.d") {
            for entry in entries {
                if let data = FileManager.default.contents(atPath: "/etc/paths.d/\(entry)"),
                   let content = String(data: data, encoding: .utf8) {
                    dirs.append(contentsOf: content.components(separatedBy: .newlines).filter { !$0.isEmpty })
                }
            }
        }

        return dirs
    }

    private static func resolveShellPath() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-i", "-c", "echo $PATH"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
