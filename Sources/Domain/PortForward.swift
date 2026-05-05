import Foundation

public struct PortForward: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var awsProfile: String
    public var region: String
    public var target: String
    public var remoteHost: String?
    public var remotePort: Int
    public var localPort: Int
    public var enabled: Bool
    public var sortOrder: Int

    public init(
        id: UUID = UUID(),
        name: String,
        awsProfile: String,
        region: String,
        target: String,
        remoteHost: String? = nil,
        remotePort: Int,
        localPort: Int,
        enabled: Bool = true,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.name = name
        self.awsProfile = awsProfile
        self.region = region
        self.target = target
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.localPort = localPort
        self.enabled = enabled
        self.sortOrder = sortOrder
    }

    public var isRemoteHostMode: Bool {
        remoteHost != nil && !remoteHost!.isEmpty
    }

    public var documentName: String {
        isRemoteHostMode
            ? "AWS-StartPortForwardingSessionToRemoteHost"
            : "AWS-StartPortForwardingSession"
    }

    public var ssmParameters: [String: [String]] {
        var params: [String: [String]] = [
            "portNumber": [String(remotePort)],
            "localPortNumber": [String(localPort)],
        ]
        if isRemoteHostMode {
            params["host"] = [remoteHost!]
        }
        return params
    }

    public var launchArguments: [String] {
        let paramsData = try! JSONSerialization.data(
            withJSONObject: ssmParameters,
            options: [.sortedKeys]
        )
        let paramsJSON = String(data: paramsData, encoding: .utf8)!

        return [
            "exec", awsProfile, "--",
            "aws", "ssm", "start-session",
            "--target", target,
            "--document-name", documentName,
            "--parameters", paramsJSON,
            "--region", region,
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
