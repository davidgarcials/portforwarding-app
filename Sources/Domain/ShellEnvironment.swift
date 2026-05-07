import Foundation

public enum ShellEnvironment {

    public static func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/Applications/Docker.app/Contents/Resources/bin",
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let combined = (extraPaths + currentPath.components(separatedBy: ":"))
            .reduce(into: [String]()) { result, path in
                if !result.contains(path) { result.append(path) }
            }
        env["PATH"] = combined.joined(separator: ":")
        return env
    }
}
