import Foundation

public struct KubeService {
    public let name: String
    public let ports: [KubeServicePort]
}

public struct KubeServicePort {
    public let name: String?
    public let port: Int
    public let targetPort: String
    public let protocol_: String
}

public enum KubectlDiscovery {

    public static func fetchNamespaces() async throws -> [String] {
        let output = try await run(["kubectl", "get", "namespaces", "-o", "'jsonpath={.items[*].metadata.name}'"])
        return output
            .split(separator: " ")
            .map(String.init)
            .sorted()
    }

    public static func fetchServices(namespace: String) async throws -> [KubeService] {
        let output = try await run([
            "kubectl", "get", "services", "-n", namespace,
            "-o", "json",
        ])

        guard let data = output.data(using: .utf8) else { return [] }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let items = json?["items"] as? [[String: Any]] else { return [] }

        return items.compactMap { item -> KubeService? in
            guard let metadata = item["metadata"] as? [String: Any],
                  let name = metadata["name"] as? String,
                  let spec = item["spec"] as? [String: Any],
                  let ports = spec["ports"] as? [[String: Any]]
            else { return nil }

            let kubePorts = ports.compactMap { p -> KubeServicePort? in
                guard let port = p["port"] as? Int else { return nil }
                return KubeServicePort(
                    name: p["name"] as? String,
                    port: port,
                    targetPort: "\(p["targetPort"] ?? port)",
                    protocol_: p["protocol"] as? String ?? "TCP"
                )
            }

            return KubeService(name: name, ports: kubePorts)
        }
        .sorted { $0.name < $1.name }
    }

    private static func run(_ arguments: [String]) async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", arguments.joined(separator: " ")]

        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe

        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw KubectlError.commandFailed(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public enum KubectlError: LocalizedError {
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let msg): return msg
        }
    }
}
