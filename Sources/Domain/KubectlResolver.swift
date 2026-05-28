import Foundation

public enum KubectlResolver {
    private static let lock = NSLock()
    private static var cachedPath: String?

    public static func resolve() -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cachedPath { return cachedPath }

        let env = ProcessEnvironment.resolved()
        let pathDirs = env["PATH"]?.components(separatedBy: ":") ?? []

        for dir in pathDirs where !dir.isEmpty {
            let path = (dir as NSString).appendingPathComponent("kubectl")
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedPath = path
                return path
            }
        }

        let fallback = "/usr/local/bin/kubectl"
        cachedPath = fallback
        return fallback
    }
}
