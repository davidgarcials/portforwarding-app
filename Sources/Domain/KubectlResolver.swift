import Foundation

public enum KubectlResolver {
    private static let lock = NSLock()
    private static var cachedPath: String?

    public static func resolve() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedPath { return cachedPath }

        let commonPaths = [
            "/usr/local/bin/kubectl",
            "/opt/homebrew/bin/kubectl",
            "/usr/bin/kubectl",
        ]

        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedPath = path
                return path
            }
        }

        if let path = resolveViaShell() {
            cachedPath = path
            return path
        }

        let fallback = "/usr/local/bin/kubectl"
        cachedPath = fallback
        return fallback
    }

    private static func resolveViaShell() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which kubectl"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }

        return path
    }
}
