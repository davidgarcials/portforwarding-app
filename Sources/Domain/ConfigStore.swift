import Foundation

public struct AppConfig: Codable {
    public var version: Int = 1
    public var workspacePaths: [String]
    public var hotkey: HotkeyConfig?

    public init(version: Int = 1, workspacePaths: [String] = [], hotkey: HotkeyConfig? = nil) {
        self.version = version
        self.workspacePaths = workspacePaths
        self.hotkey = hotkey
    }
}

public struct HotkeyConfig: Codable, Equatable {
    public var keyCode: UInt16
    public var modifiers: UInt

    public init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct WorkspaceConfig: Codable {
    public var forwards: [PortForward]

    public init(forwards: [PortForward] = []) {
        self.forwards = forwards
    }
}

public struct Workspace: Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public var forwards: [PortForward]

    public var name: String {
        (path as NSString).lastPathComponent
    }

    public init(path: String, forwards: [PortForward] = []) {
        self.path = path
        self.forwards = forwards
    }
}

public final class ConfigStore {
    private let appConfigURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    public static let workspaceConfigFileName = ".portforwards.json"

    public init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory
        self.appConfigURL = dir.appendingPathComponent("config.json")
    }

    public static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("PortForwardingApp")
    }

    // MARK: - App Config (workspace paths)

    public func loadAppConfig() throws -> AppConfig {
        let data = try Data(contentsOf: appConfigURL)
        return try decoder.decode(AppConfig.self, from: data)
    }

    public func saveAppConfig(_ config: AppConfig) throws {
        let dir = appConfigURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(config)
        try data.write(to: appConfigURL, options: .atomic)
    }

    public func loadAppConfigOrDefault() -> AppConfig {
        (try? loadAppConfig()) ?? AppConfig()
    }

    // MARK: - Workspace Config (per-directory)

    public func loadWorkspaceConfig(at path: String) throws -> WorkspaceConfig {
        let url = URL(fileURLWithPath: path)
            .appendingPathComponent(Self.workspaceConfigFileName)
        let data = try Data(contentsOf: url)
        return try decoder.decode(WorkspaceConfig.self, from: data)
    }

    public func saveWorkspaceConfig(_ config: WorkspaceConfig, at path: String) throws {
        let url = URL(fileURLWithPath: path)
            .appendingPathComponent(Self.workspaceConfigFileName)
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }

    public func loadWorkspaceConfigOrDefault(at path: String) -> WorkspaceConfig {
        (try? loadWorkspaceConfig(at: path)) ?? WorkspaceConfig()
    }

    // MARK: - Load all workspaces

    public func loadAllWorkspaces() -> [Workspace] {
        let appConfig = loadAppConfigOrDefault()
        return appConfig.workspacePaths.map { path in
            let wsConfig = loadWorkspaceConfigOrDefault(at: path)
            return Workspace(path: path, forwards: wsConfig.forwards)
        }
    }
}
