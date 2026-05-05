import Foundation

public struct AppConfig: Codable {
    public var version: Int = 1
    public var forwards: [PortForward]

    public init(version: Int = 1, forwards: [PortForward]) {
        self.version = version
        self.forwards = forwards
    }
}

public final class ConfigStore {
    private let fileURL: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder = JSONDecoder()

    public init(directory: URL? = nil) {
        let dir = directory ?? Self.defaultDirectory
        self.fileURL = dir.appendingPathComponent("config.json")
    }

    public static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("PortForwardingApp")
    }

    public func load() throws -> AppConfig {
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(AppConfig.self, from: data)
    }

    public func save(_ config: AppConfig) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let data = try encoder.encode(config)
        let tmpURL = fileURL.appendingPathExtension("tmp")
        try data.write(to: tmpURL, options: .atomic)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmpURL)
    }

    public func loadOrDefault() -> AppConfig {
        (try? load()) ?? AppConfig(forwards: [])
    }
}
