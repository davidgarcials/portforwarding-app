import Foundation

public struct PortForward: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var service: String
    public var namespace: String
    public var localPort: Int
    public var remotePort: Int
    public var enabled: Bool
    public var sortOrder: Int

    public init(
        id: UUID = UUID(),
        name: String,
        service: String,
        namespace: String,
        localPort: Int,
        remotePort: Int,
        enabled: Bool = true,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.service = service
        self.namespace = namespace
        self.localPort = localPort
        self.remotePort = remotePort
        self.enabled = enabled
        self.sortOrder = sortOrder
    }

    public var launchArguments: [String] {
        [
            "port-forward",
            "svc/\(service)",
            "--namespace", namespace,
            "\(localPort):\(remotePort)",
        ]
    }
}

public enum ForwardState: Equatable {
    case idle
    case starting
    case ready
    case failed(String)
    case stopped
}
